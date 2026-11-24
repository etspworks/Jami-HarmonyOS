/*
 * screen_contact — "Contact Info", ported from
 *   Ring/Ring/Contact/ContactViewController.swift (+ .storyboard)
 *   Ring/Ring/Contact/ContactViewModel.swift  (ContactActions.make, ContactInfoAction)
 *   Ring/Ring/Contact/ProfileHeaderView.xib   -> comp_profile_header
 *   Ring/Ring/Contact/TitleView.swift         -> comp_title_view
 *
 * Structure, straight off the view controller:
 *   navigationItem.titleView = TitleView(avatar 36 + titleName)
 *   tableView
 *     + ProfileHeaderView (a GSKStretchyHeaderView added as a subview of the table, so it
 *       scrolls with the rows: avatar 100, displayName, userName, jamiID)
 *     + one row per ContactActions item, rowHeight 60, cell = imageView + textLabel
 *
 * The row SET is `ContactActions.make(isJamiAccount:isKnownContact:canEditProfile:)`, which is
 * why the screen's five conditional variants exist: the capture (S0022/S0024) shows ONE of
 * those combinations. The audio-call row is unconditional; every other row carries its own
 * guard, reproduced here beside the kind it belongs to.
 *
 * S3 — component tree + the controls with their Rule-12 ids. The rows are fed by svc_contacts
 * through ArrayDataSource/LazyForEach (never a literal array) and the header/title values are
 * bound to svc_profiles, ContactModel.userName and ContactModel.hash in S4. No styling.
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DaemonUnavailableError } from '../common/DaemonService';
import { DisposeBag } from '../common/Observable';
import { describeError } from '../common/ErrorText';
import { JamiUri, UriType } from '../common/JamiUri';
import { LookupNameResponse } from '../common/NameService';
// svc_audio: HarmonyOS has no system call provider for a self-signed build (svc_call_ui's
// disclosed gap), so the app activates the call's audio route itself where CallKit did.
import { AudioService } from '../common/AudioService';
import { CallDirection } from '../model/CallState';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ContactModel } from '../model/ContactModel';
import {
  ConversationModel,
  ConversationType,
  conversationTypeStringResource
} from '../model/ConversationModel';
import { ConversationPreferenceAttribute, DEFAULT_SWARM_COLOR_HEX }
  from '../model/ConversationPreferences';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';
import { AvatarView } from '../components/AvatarView';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { SettingsViewSection } from '../components/SettingsViewSection';
import { CollaborativeDocumentsSheet } from './CollaborativeDocumentsPage';
import { ProfileHeaderView } from '../components/ProfileHeader';
import { InCallScreenOverlay } from './InCallScreenPage';
import { EditConversationProfileOverlay, EDIT_CONVERSATION_KEY } from './EditConversationProfilePage';
import { TitleView } from '../components/TitleView';
import { BackChevron } from '../components/BackButton';

/** Swift `TitleView`'s avatar: `AvatarView(..., size: 36)` (ContactViewController:92). */
const TITLE_AVATAR_SIZE: number = 36;

/** Swift `enum ContactInfoAction` (ContactViewModel.swift:27). */
export enum ContactInfoAction {
  AUDIO_CALL = 'audioCall',
  VIDEO_CALL = 'videoCall',
  EDIT_PROFILE = 'editProfile',
  SEND_MESSAGE = 'sendMessage',
  LEAVE_CONVERSATION = 'leaveConversation',
  BLOCK_CONTACT = 'blockContact'
}

/**
 * Swift `struct ContactActions { kind, title, image }`. The SOURCE gives these rows no
 * accessibility identifier at all (they are RxDataSources table cells), so Rule 12's slug is
 * the `ContactInfoAction` case name itself — which is exactly what `kind` holds, so `.id()`
 * uses `kind` directly rather than carrying a second, drift-prone copy of it.
 */
export class ContactActionRow {
  kind: ContactInfoAction;
  title: ResourceStr;
  icon: Resource;

  constructor(kind: ContactInfoAction, title: ResourceStr, icon: Resource) {
    this.kind = kind;
    this.title = title;
    this.icon = icon;
  }
}

/** Swift `ContactActions.make(...)`'s six rows, with the SF Symbols resolved via icon-map.json. */
export const CONTACT_ACTION_AUDIO_CALL: ContactActionRow = new ContactActionRow(
  ContactInfoAction.AUDIO_CALL, $r('app.string.contact_page_start_audio_call'),
  $r('sys.symbol.phone'));
export const CONTACT_ACTION_VIDEO_CALL: ContactActionRow = new ContactActionRow(
  ContactInfoAction.VIDEO_CALL, $r('app.string.contact_page_start_video_call'),
  $r('sys.symbol.video'));
export const CONTACT_ACTION_EDIT_PROFILE: ContactActionRow = new ContactActionRow(
  ContactInfoAction.EDIT_PROFILE, $r('app.string.global_edit'),
  $r('sys.symbol.pencil_line'));
export const CONTACT_ACTION_SEND_MESSAGE: ContactActionRow = new ContactActionRow(
  ContactInfoAction.SEND_MESSAGE, $r('app.string.contact_page_send'),
  $r('sys.symbol.message'));
export const CONTACT_ACTION_LEAVE_CONVERSATION: ContactActionRow = new ContactActionRow(
  ContactInfoAction.LEAVE_CONVERSATION, $r('app.string.contact_page_leave_conversation'),
  $r('sys.symbol.arrow_right_and_square'));
export const CONTACT_ACTION_BLOCK_CONTACT: ContactActionRow = new ContactActionRow(
  ContactInfoAction.BLOCK_CONTACT, $r('app.string.global_block_contact'),
  $r('sys.symbol.nosign'));

/** Swift `tableView.rowHeight = 60.0`. */
const ACTION_ROW_HEIGHT: number = 60;

/** Capture S0022/S0024: the nav-bar band is `[0,53][393,97]` — 44vp. */
const NAV_BAR_HEIGHT: number = 44;
/** Swift `cell.imageView` — a UITableViewCell glyph, 24vp on the action rows. */
const ACTION_ICON_SIZE: number = 24;
/** Swift `cell.imageView.tintColor = UIColor.jamiSecondary` — `0x1F4971`, hardcoded in the source. */
const JAMI_SECONDARY: string = '#1F4971';
/** Swift's cell lays its imageView 16pt from the leading edge, the title 12pt after it. */
const ACTION_ICON_GAP: number = 12;
/** Capture S0022: the back chevron sits 4vp before its `Back` label. */
const BACK_GLYPH_GAP: number = 4;

/*
 * The Jami 4.20 layout (SwarmInfoView), which the iPhone shows for every swarm 1:1: Swift
 * `ConversationViewModel.showContactInfo` presents SwarmInfo for `conversation.isSwarm()` and
 * keeps ContactViewController for the rest (SIP / non-swarm). Metrics are SwarmInfoView's own,
 * the same values SwarmConversationInfoPage uses.
 */
const SECTION_SETTINGS: number = 0;
const SECTION_DOCUMENTS: number = 1;
const GENERAL_MARGIN: number = 20;
const VERTICAL_MARGIN: number = 10;
const AVATAR_TOP_GAP: number = 14;
const AVATAR_BOTTOM_GAP: number = 12;
const CALL_BUTTON_SIZE: number = 45;
const CALL_BUTTONS_MARGIN: number = 5;
const ACTION_GLYPH_SIZE: number = 20;
const ACTION_BUTTON_RADIUS: number = 10;
const TITLE_WEIGHT: number = 600;
const REGULAR_WEIGHT: number = 400;
const SEGMENT_HEIGHT: number = 32;
const SEGMENT_TRACK_INSET: number = 2;
const SEGMENT_TRACK_RADIUS: number = 8;
const SEGMENT_PILL_RADIUS: number = 7;
const SECTION_SPACING: number = 8;

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ContactInfoPage';

/**
 * Swift pushed `ContactViewController` with the conversation itself; ArkUI router params carry
 * data, not objects, so the smart list passes `ConversationViewModel.key` and this page
 * re-resolves the conversation off svc_conversations (SmartListConversationsHomePage:712).
 */
interface ContactRouteParams {
  conversationKey?: string;
}

@Entry
@Component
struct ContactInfoPage {
  /**
   * Swift `viewModel.tableSection` — the `ContactActions.make(...)` row set, published by
   * svc_contacts/svc_accounts through `applyConversation`. Never a literal array: the rows the
   * screen shows depend on the contact and on the account type.
   */
  @State contactActionListContactActionsMake: ArrayDataSource<ContactActionRow> =
    new ArrayDataSource<ContactActionRow>([CONTACT_ACTION_AUDIO_CALL]);
  /** Swift `viewModel.titleName` <- ContactModel.userName / the profile alias. */
  @State title: string = '';
  /** Swift `viewModel.displayName` — the profile alias shown in the stretchy header. */
  @State displayName: string = '';
  /** Swift `viewModel.userName` — the registered name. */
  @State userName: string = '';
  /** Swift `viewModel.profileImageData` <- svc_profiles. */
  @State avatar: string = '';
  /** Swift `conversation.hash` <- the conversation participant's jamiId. */
  @State jamiId: string = '';
  /** conditionalVariants[jami_account]: `account.type == .ring`. */
  @State isJamiAccount: boolean = false;
  /** conditionalVariants[sip_account]: `account.type == .sip` — audio call only. */
  @State isSipAccount: boolean = false;
  /** conditionalVariants[can_edit]: `ContactViewModel.canEditProfile`. */
  @State canEdit: boolean = false;
  /** conditionalVariants[known_contact]: `ContactsService.contact(withHash:) != nil`. */
  @State isKnownContact: boolean = false;
  /** conditionalVariants[known_and_jami]: a known contact on a Jami account. */
  @State isKnownAndJami: boolean = false;
  /** True while svc_contacts / svc_profiles are in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * The disclosed daemon gap raised by THIS screen's own controls (call / leave / block). A
   * visible overlay, never a silent no-op — the control must be seen to do something.
   */
  @State showDaemonNotice: boolean = false;
  /** screen_call — presentation: modal; the overlay's own presentation flag. */
  @State private showCallScreen: boolean = false;
  /** Swift `conversation.isSwarm()` — the 4.20 SwarmInfoView layout instead of the table. */
  @State isSwarmLayout: boolean = false;
  /** SwarmInfoView `selectedView`: Settings or Documents. */
  @State private selectedSection: number = SECTION_SETTINGS;
  @State private segmentedWidth: number = 0;
  /** Swift `swarmInfo.id`. */
  @State private conversationId: string = '';
  /** Swift `swarmInfo.type.value.stringValue` — always "Private" on iOS (SwarmInfo.swift). */
  @State private conversationTypeLabel: string = '';
  /** Swift `viewmodel.finalColor` / `selectedColor`. */
  @State private finalColor: string = DEFAULT_SWARM_COLOR_HEX;
  @State @Watch('onSelectedColorChanged') private selectedColor: string = '';
  /** Swift `createShareInfo(for:)`. */
  @State private shareInfo: string = '';
  /** Swift `removeConversationText` — "Remove conversation" for a dialog. */
  @State private removeConversationLabel: string = '';
  @State private showQRcode: boolean = false;
  @State private isColorPickerOpen: boolean = false;
  /** CollaborativeDocumentsSheet's @Link. */
  @State private showCollabDocuments: boolean = false;
  @State private localJamiId: string = '';
  /** The `Back` item's measured width — the table layout's title view is inset by it. */
  @State private backItemWidth: number = 0;
  /** Written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `private let disposeBag = DisposeBag()` — the profile and name-lookup subscriptions. */
  private bag: DisposeBag = new DisposeBag();

  /** Swift `var conversation: ConversationModel!` — resolved from the route param. */
  private conversation: ConversationModel | null = null;

  /**
   * screen_call — presentation: modal. InCallScreenOverlay is a @CustomDialog, not a routed
   * page (it is deliberately absent from main_pages.json), so the call is MOUNTED here the
   * same way screen_conversation mounts it.
   */
  private callDialog: CustomDialogController = new CustomDialogController({
    builder: InCallScreenOverlay({ isPresented: $showCallScreen }),
    autoCancel: false,
    // T-1731: Back with an in-call sheet open closes only the sheet, as iOS.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK && InCallScreenOverlay.closeOpenPanel()) {
        return;
      }
      action.dismiss();
    },
    customStyle: true,
    // The call screen's add-participant picker sits ON the keyboard: the default 16 vp avoid
    // distance showed a strip of this page between the two (T-1470, as T-1317).
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });

  /**
   * The conversation this page resolved from its route param, kept so the profile-editor
   * overlay can be told which conversation it is editing (a @CustomDialog's builder
   * arguments are fixed when the controller is built, so the key travels over AppStorage).
   */
  private conversationKey: string = '';

  /** screen_conversation_profile_editor — presentation: modal, as on screen_swarm_info. */
  private editProfileDialog: CustomDialogController = new CustomDialogController({
    builder: EditConversationProfileOverlay(),
    autoCancel: true,
    customStyle: true,
    // Default avoidance re-lays the full-screen editor out above the keyboard and the info
    // page showed through a strip above it (review T-1184); iOS keeps the sheet in place.
    keyboardAvoidMode: KeyboardAvoidMode.NONE
  });

  /**
   * Swift `var conversation: ConversationModel! { didSet { ... } }` — the whole body of that
   * observer, run once when the route param resolves.
   */
  aboutToAppear(): void {
    const raw: Object | undefined = router.getParams();
    const key: string = raw === undefined
      ? '' : ((raw as ContactRouteParams).conversationKey ?? '');
    this.conversationKey = key;
    this.applyConversation(this.resolveConversation(key));
  }

  aboutToDisappear(): void {
    this.bag.dispose();
  }

  /**
   * Swift had the coordinator hand the model over directly. `ConversationViewModel.key` is
   * `<accountId>|<conversationId or first participant>`, so the same split resolves it back.
   */
  private resolveConversation(key: string): ConversationModel | null {
    if (key.length === 0) {
      return null;
    }
    const separator: number = key.indexOf('|');
    if (separator < 0) {
      return null;
    }
    const accountId: string = key.substring(0, separator);
    const identity: string = key.substring(separator + 1);
    const conversations: ConversationModel[] =
      ServiceRegistry.shared().conversationsService.conversations.value;
    for (const conversation of conversations) {
      if (conversation.accountId !== accountId) {
        continue;
      }
      if (conversation.id === identity || conversation.hash === identity) {
        return conversation;
      }
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (participants.length > 0 && participants[0].jamiId === identity) {
        return conversation;
      }
    }
    // Same temporary fallback as ConversationChatPage.resolveConversation: a search result that
    // is not a conversation yet (a jami peer, or any number on a SIP account) still has a page,
    // so its name shows and Start audio call places the call (T-1381).
    if (/^[0-9a-f]{40}$/.test(identity)) {
      return ConversationModel.withParticipantUri(identity, accountId, ConversationType.ONE_TO_ONE);
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(accountId);
    if (account !== null && account.type === AccountType.SIP && identity.length > 0) {
      return ConversationModel.withParticipantUriAndHash(identity, accountId, identity, ConversationType.SIP);
    }
    return null;
  }

  /** Swift's `didSet` body, verbatim in order: guard, actions, userName, lookup, profile. */
  private applyConversation(conversation: ConversationModel | null): void {
    this.conversation = conversation;
    if (conversation === null) {
      this.isLoading = false;
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.getAccount(conversation.accountId);
    const participants: ConversationParticipant[] = conversation.getParticipants();
    if (account === null || participants.length === 0) {
      // Swift `guard ... else { return }` — nothing is published, so the table stays empty.
      this.isLoading = false;
      return;
    }
    const jamiId: string = participants[0].jamiId;
    this.jamiId = jamiId;
    const contact: ContactModel | null = registry.contactsService.contact(jamiId);

    this.isJamiAccount = account.type === AccountType.RING;
    this.isSipAccount = account.type === AccountType.SIP;
    this.isKnownContact = contact !== null;
    this.canEdit = conversation.isCoredialog() && !conversation.isOnlyLocalParticipant();
    this.isKnownAndJami = this.isKnownContact && this.isJamiAccount;
    this.contactActionListContactActionsMake.reload(this.makeActions());
    this.applySwarmInfo(conversation, account, jamiId);

    // Swift: `contact.userName ?? jamiId`, and `jamiId` when there is no contact at all.
    const contactUserName: string | null = contact === null ? null : contact.userName;
    this.setUserName(contactUserName === null || contactUserName.length === 0
      ? jamiId : contactUserName);

    if (this.isJamiAccount && this.userName === jamiId) {
      this.lookupName(account.id, jamiId);
    }

    const schema: UriType = this.isSipAccount ? UriType.SIP : UriType.RING;
    const contactUri: string | null = JamiUri.fromInfoHash(schema, jamiId).uriString;
    if (contactUri === null) {
      // Swift `guard let contactURI ... else { return }`.
      this.isLoading = false;
      return;
    }
    this.bag.add(registry.profileService.getProfile(contactUri, conversation.accountId)
      .subscribe((profile: Profile): void => {
        const alias: string | null = profile.alias;
        this.setDisplayName(alias === null ? '' : alias.trim());
        this.avatar = profile.photo === null ? '' : profile.photo;
        this.isLoading = false;
      }));
  }

  /** Swift `ContactActions.make(isJamiAccount:isKnownContact:canEditProfile:)`, verbatim order. */
  private makeActions(): ContactActionRow[] {
    const actions: ContactActionRow[] = [CONTACT_ACTION_AUDIO_CALL];
    if (this.isJamiAccount) {
      actions.push(CONTACT_ACTION_VIDEO_CALL);
    }
    if (this.canEdit) {
      actions.push(CONTACT_ACTION_EDIT_PROFILE);
    }
    if (this.isJamiAccount) {
      actions.push(CONTACT_ACTION_SEND_MESSAGE);
    }
    if (this.isKnownContact) {
      actions.push(CONTACT_ACTION_LEAVE_CONVERSATION);
      if (this.isJamiAccount) {
        actions.push(CONTACT_ACTION_BLOCK_CONTACT);
      }
    }
    return actions;
  }

  /** Swift `SwarmInfoVM.init` — the values SettingsView binds, for the 4.20 layout. */
  private applySwarmInfo(conversation: ConversationModel, account: AccountModel, jamiId: string): void {
    this.isSwarmLayout = conversation.isSwarm();
    if (!this.isSwarmLayout) {
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const manager = getContext(this).resourceManager;
    this.localJamiId = account.jamiId;
    this.conversationId = conversation.id;
    this.conversationTypeLabel =
      manager.getStringByNameSync(conversationTypeStringResource(ConversationType.ONE_TO_ONE));
    this.shareInfo = manager.getStringByNameSync('swarm_share_contact_message').replace('%1$s', jamiId);
    // ConversationRemovalPresentation: a dialog (<= 2 participants, always true here) is
    // `.remove`, never `.leave`.
    this.removeConversationLabel = manager.getStringByNameSync('swarm_remove_conversation');
    const prefs: Map<string, string> | null =
      registry.conversationsService.getConversationPreferences(conversation.accountId, conversation.id);
    const color: string | undefined = prefs === null
      ? undefined : prefs.get(ConversationPreferenceAttribute.COLOR);
    if (color !== undefined && color.length > 0) {
      this.finalColor = color;
      this.selectedColor = color;
    }
  }

  /** Swift `.onChange(of: viewmodel.selectedColor) { updateSwarmColor(selectedColor:) }`. */
  private onSelectedColorChanged(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || this.selectedColor.length === 0 ||
      this.selectedColor === this.finalColor) {
      return;
    }
    this.finalColor = this.selectedColor;
    const service = ServiceRegistry.shared().conversationsService;
    const prefs: Map<string, string> | null =
      service.getConversationPreferences(conversation.accountId, conversation.id);
    const updated: Map<string, string> = prefs === null ? new Map<string, string>() : prefs;
    updated.set(ConversationPreferenceAttribute.COLOR, this.selectedColor);
    try {
      service.updateConversationPrefs(conversation.accountId, conversation.id, updated);
    } catch (error) {
      this.reportFailure(error as Object);
    }
  }

  /** The QR / colour sheets close on hardware Back instead of popping the page. */
  onBackPress(): boolean {
    if (this.showQRcode) {
      this.showQRcode = false;
      return true;
    }
    if (this.isColorPickerOpen) {
      this.isColorPickerOpen = false;
      return true;
    }
    return false;
  }

  /**
   * Swift subscribed `nameService.usernameLookupStatus` filtered on `requestedName == jamiId`,
   * then called `lookupAddress`. The lookup itself is a daemon call and reports the gap; the
   * subscription stays, so a resolved name lands the moment one ever arrives.
   */
  private lookupName(accountId: string, jamiId: string): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(registry.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (response.requestedName !== jamiId) {
          return;
        }
        if (response.name.length > 0) {
          this.setUserName(response.name);
        } else if (response.requestedName.length > 0) {
          this.setUserName(response.requestedName);
        }
      }));
    registry.nameService.lookupAddress(accountId, '', jamiId);
  }

  /** Swift `userName.accept(_:)` + the `titleName` combineLatest that depends on it. */
  private setUserName(value: string): void {
    this.userName = value;
    this.refreshTitle();
  }

  /** Swift `displayName.accept(_:)` + the same combineLatest. */
  private setDisplayName(value: string): void {
    this.displayName = value;
    this.refreshTitle();
  }

  /** Swift `lazy var titleName` — displayName when it has one, else userName. */
  private refreshTitle(): void {
    this.title = this.displayName.length === 0 ? this.userName : this.displayName;
  }

  /** Swift `viewModel.startAudioCall()` -> ConversationState.startAudioCall. */
  private startAudioCall(): void {
    this.placeCall(true);
  }

  /** Swift `viewModel.startCall()` -> ConversationState.startCall. */
  private startVideoCall(): void {
    this.placeCall(false);
  }

  /**
   * Swift emitted the state and let the coordinator present the call screen, which then placed
   * the call. Same order here: the call is placed first, and only a call that exists opens
   * screen_call — on the daemon gap the notice is what the user sees instead.
   */
  private placeCall(audioOnly: boolean): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || this.jamiId.length === 0) {
      // No contact resolved because the daemon never supplied one — the same disclosed gap
      // the placed call itself reports, so it is reported the same way rather than silently.
      this.showDaemonNotice = true;
      return;
    }
    ServiceRegistry.shared().callService
      .placeCall(conversation.accountId, this.jamiId, audioOnly)
      .then((): void => {
        // Swift: CallKit activated the session and AudioService.callKitActivated set the
        // route. With no system provider the app does it at the same moment.
        const audio: AudioService = ServiceRegistry.shared().audioService;
        audio.callKitActivated(!audioOnly, CallDirection.OUTGOING);
        this.showCallScreen = true;
        this.callDialog.open();
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** One place decides whether a failure is the disclosed gap or a real error. */
  private reportFailure(error: Object): void {
    if (error instanceof DaemonUnavailableError) {
      this.showDaemonNotice = true;
      return;
    }
    this.errorText = describeError(error as BusinessError);
    hilog.error(LOG_DOMAIN, LOG_TAG, 'action failed: %{public}s', this.errorText);
  }

  /** Swift `viewModel.editProfile()` -> ConversationState.editConversationProfile. */
  private editProfile(): void {
    // The overlay reads this the moment it mounts; see EditConversationProfilePage's note on
    // why a @CustomDialog cannot take it as a builder argument.
    AppStorage.setOrCreate<string>(EDIT_CONVERSATION_KEY, this.conversationKey);
    this.editProfileDialog.open();
  }

  /**
   * Swift `.sendMessage: popViewController(animated: false)` — the conversation is the screen
   * this one was pushed from, so the source pops back to it rather than pushing a second copy.
   */
  private sendMessage(): void {
    router.back({ url: 'pages/ConversationChatPage' });
  }

  /**
   * Swift `deleteConversation()` -> `ConversationDestructiveActionExecutor.perform(.removeContact)`,
   * which is `contactsService.removeContact(withId:ban:false:)` followed by the conversation's
   * own removal. The contact half is a DHT write and reports the gap.
   */
  private leaveConversation(): void {
    // Swift `showDeleteConversationConfirmation()` — Cancel left, destructive Delete right,
    // as the iPhone (Jami 4.20) lays the alert out.
    this.getUIContext().showAlertDialog({
      title: $r('app.string.alerts_confirm_delete_conversation_title'),
      message: $r('app.string.alerts_confirm_delete_conversation_from_contact'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.actions_delete_action'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.performDestructive(false, false);
        }
      }
    });
  }

  /**
   * SettingsView `.removeContact` alert (Jami 4.20): "Remove contact", Cancel left, destructive
   * Remove right. SwarmInfoVM.removeContact passes removeConversationAfterContactRemoval: false.
   */
  private removeContact(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.swarm_remove_contact'),
      message: $r('app.string.alerts_confim_remove_contact'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.global_remove'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.performDestructive(false, true);
        }
      }
    });
  }

  /**
   * SettingsView `.removeConversation` alert for a 1:1 (Jami 4.20): title "Remove conversation",
   * `confirmRemoveOneToOneConversation`, Cancel left, destructive Remove right; then
   * `ConversationDestructiveActionExecutor.removeConversation` — the daemon's removeConversation.
   */
  private removeConversation(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.swarm_remove_conversation'),
      message: $r('app.string.alerts_confirm_remove_one_to_one_conversation'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.global_remove'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.performRemoveConversation();
        }
      }
    });
  }

  private performRemoveConversation(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    try {
      ServiceRegistry.shared().conversationsService
        .removeConversation(conversation.id, conversation.accountId);
    } catch (error) {
      this.reportFailure(error as Object);
      return;
    }
    // Swift `emitState(.conversationRemoved)` — back to the smart list.
    router.back({ url: 'pages/SmartListConversationsHomePage' });
  }

  /**
   * Swift `showBlockContactConfirmation()` — a "Block contact" alert whose destructive Block
   * runs `blockContact()` (the same executor with `.blockContact`, ban = true); Cancel does
   * nothing. Laid out as on the iPhone (Jami 4.20): Cancel left, Block right.
   */
  private blockContact(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.global_block_contact'),
      message: $r('app.string.alerts_confirm_block_contact'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.global_block'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.performDestructive(true, true);
        }
      }
    });
  }

  /**
   * Swift `ConversationDestructiveActionExecutor.removeContact(_:ban:removeConversationAfter...)`.
   * `keepConversation` is `!removeConversationAfterContactRemoval`: block always keeps it
   * (T-1558), and so does the 4.20 Remove contact; only the old table's leave row drops it.
   */
  private performDestructive(ban: boolean, keepConversation: boolean): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || this.jamiId.length === 0) {
      return;
    }
    ServiceRegistry.shared().contactsService
      .removeContact(this.jamiId, ban, conversation.accountId)
      .then((): Promise<void> =>
        // Kept (SwarmInfoVM block / remove contact pass removeConversationAfterContactRemoval:
        // false): the conversation stays — a blocked one is parked with the blocked ones, so an
        // unblock restores the ORIGINAL one — and `clearCustomProfile(for:)` drops the local
        // alias/photo override. Otherwise `removeConversationFromDB(keepConversation: false)`.
        keepConversation ? Promise.resolve(this.clearCustomProfile(conversation)) :
          ServiceRegistry.shared().conversationsService.removeConversationFromDB(conversation, false))
      .then((): void => {
        // Swift `completion: { emitConversationRemoved() }` -> ConversationState
        // .conversationRemoved, which pops to the smart list (the iPhone lands there, not on
        // the removed conversation's chat).
        router.back({ url: 'pages/SmartListConversationsHomePage' });
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `ConversationDestructiveActionExecutor.clearCustomProfile(for:)`. */
  private clearCustomProfile(conversation: ConversationModel): void {
    const schema: UriType = conversation.isSip() ? UriType.SIP : UriType.RING;
    const uri: string | null = JamiUri.fromInfoHash(schema, this.jamiId).uriString;
    if (uri !== null) {
      ServiceRegistry.shared().profileService.updateCustomProfile(uri, conversation.accountId, null, null);
    }
  }

  /** CollabDocumentsView opened a document: the conversation under this page opens it. */
  private leaveForDocument(documentId: string): void {
    this.showCollabDocuments = false;
    if (documentId.length > 0) {
      router.back({ url: 'pages/ConversationChatPage' });
    }
  }

  private invoke(kind: ContactInfoAction): void {
    if (kind === ContactInfoAction.AUDIO_CALL) {
      this.startAudioCall();
    } else if (kind === ContactInfoAction.VIDEO_CALL) {
      this.startVideoCall();
    } else if (kind === ContactInfoAction.EDIT_PROFILE) {
      this.editProfile();
    } else if (kind === ContactInfoAction.SEND_MESSAGE) {
      this.sendMessage();
    } else if (kind === ContactInfoAction.LEAVE_CONVERSATION) {
      this.leaveConversation();
    } else {
      this.blockContact();
    }
  }

  /** Swift `configureCell`: `cell.imageView.image` + `cell.textLabel.text`, row height 60. */
  @Builder
  private actionCell(item: ContactActionRow) {
    // S5 — a plain (not inset-grouped) UITableViewCell: white row, glyph then title, a hairline
    // separator under it. Row height 60 becomes a MINIMUM so the title can grow with the
    // system font size.
    Row({ space: ACTION_ICON_GAP }) {
      SymbolGlyph(item.icon)
        .fontSize(ACTION_ICON_SIZE)
        .fontColor([JAMI_SECONDARY])
      Text(item.title)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minHeight: ACTION_ROW_HEIGHT })
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      top: LengthMetrics.resource($r('sys.float.padding_level4')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
    })
    .backgroundColor($r('sys.color.background_primary'))
    .border({
      width: { bottom: 0.5 },
      color: { bottom: $r('sys.color.comp_divider') }
    })
    .id(item.kind)
    .onClick(() => {
      this.invoke(item.kind);
    })
  }

  /**
   * The guards are `ContactActions.make`'s own, kept beside the row they admit: the array is
   * built from the same five flags, so a flag that flips after a row was appended cannot leave
   * a stale row on screen.
   */
  @Builder
  private actionRow(item: ContactActionRow) {
    if (item.kind === ContactInfoAction.AUDIO_CALL) {
      this.actionCell(item)
    } else if (item.kind === ContactInfoAction.VIDEO_CALL &&
      this.isJamiAccount && !this.isSipAccount) {
      this.actionCell(item)
    } else if (item.kind === ContactInfoAction.EDIT_PROFILE && this.canEdit) {
      this.actionCell(item)
    } else if (item.kind === ContactInfoAction.SEND_MESSAGE && this.isJamiAccount) {
      this.actionCell(item)
    } else if (item.kind === ContactInfoAction.LEAVE_CONVERSATION && this.isKnownContact) {
      this.actionCell(item)
    } else if (item.kind === ContactInfoAction.BLOCK_CONTACT && this.isKnownAndJami) {
      this.actionCell(item)
    }
  }

  /** Swift ContactViewController:92 — `AvatarView(..., size: 36)` for the nav title. */
  @Builder
  private titleAvatar() {
    AvatarView({
      profileImageData: this.avatar,
      username: this.title,
      isGroup: false,
      diameter: TITLE_AVATAR_SIZE
    })
  }

  /** Swift ContactViewController:86 — `AvatarView(..., size: 100)` for the stretchy header. */
  @Builder
  private headerAvatar() {
    AvatarView({
      profileImageData: this.avatar,
      username: this.displayName.length > 0 ? this.displayName : this.userName,
      isGroup: false,
      diameter: AvatarSize.ACCOUNT_100
    })
  }

  /**
   * The disclosed daemon gap, rendered as a top overlay layer so a daemon-backed row visibly
   * DOES something when tapped. It carries no interactive node of its own (it would be a
   * control the source has not got) and lets touches through to the rows beneath it; the next
   * action clears it.
   */
  @Builder
  private daemonGapNotice() {
    Column() {
      Blank()
      Text($r('app.string.daemon_not_available'))
        .width('100%')
        .id('contact_daemon_notice')
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_on_primary'))
        .textAlign(TextAlign.Center)
        .padding($r('sys.float.ohos_id_card_margin_start'))
        .backgroundColor($r('app.color.jami'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    }
    .width('100%')
    .height('100%')
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** The pushed page's `< Back` bar item — one node for both layouts. */
  @Builder
  private backItem() {
    Row({ space: BACK_GLYPH_GAP }) {
      BackChevron()
      Text($r('app.string.actions_back_action'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
    }
    .id('back')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_card_margin_start'))
    })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.backItemWidth = newArea.width;
      }
    })
    .onClick(() => {
      router.back();
    })
  }

  /** Swift SwarmInfoView `profileActionButton(_:)` — a glyph tile over its caption. */
  @Builder
  private swarmActionButton(slug: string, glyph: Resource, title: ResourceStr, handler: () => void) {
    Column({ space: CALL_BUTTONS_MARGIN }) {
      // A Stack centres the glyph; a SymbolGlyph sized to the tile draws top-left (T-1093).
      Stack() {
        SymbolGlyph(glyph)
          .fontSize(ACTION_GLYPH_SIZE)
          .fontWeight(TITLE_WEIGHT)
          .fontColor([$r('app.color.jami')])
      }
      .width(CALL_BUTTON_SIZE)
      .height(CALL_BUTTON_SIZE)
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(ACTION_BUTTON_RADIUS)
      Text(title)
        .maxLines(1)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.label'))
    }
    .alignItems(HorizontalAlign.Center)
    .id(`swarm_info_action_${slug}`)
    .onClick(() => {
      handler();
    })
  }

  /** Swift SwarmInfoView `fullTopArea`: avatar 120, title, then Call / Video / Edit. */
  @Builder
  private swarmHeader() {
    Column({ space: AVATAR_BOTTOM_GAP }) {
      AvatarSwiftUIView({
        avatarData: this.avatar,
        displayText: this.title,
        isGroup: false,
        avatarSize: AvatarSize.CONVERSATION_INFO_120
      })
      Text(this.title)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
      Row({ space: GENERAL_MARGIN }) {
        if (this.jamiId.length > 0) {
          this.swarmActionButton('audioCall', $r('sys.symbol.phone'), $r('app.string.global_call'),
            (): void => {
              this.startAudioCall();
            })
          this.swarmActionButton('videoCall', $r('sys.symbol.video'), $r('app.string.global_video'),
            (): void => {
              this.startVideoCall();
            })
        }
        if (this.canEdit) {
          this.swarmActionButton('editProfile', $r('sys.symbol.square_and_pencil'),
            $r('app.string.global_edit'), (): void => {
              this.editProfile();
            })
        }
      }
      .justifyContent(FlexAlign.Center)
      .margin({ top: CALL_BUTTONS_MARGIN })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      start: LengthMetrics.vp(GENERAL_MARGIN),
      end: LengthMetrics.vp(GENERAL_MARGIN),
      top: LengthMetrics.vp(AVATAR_TOP_GAP),
      bottom: LengthMetrics.vp(VERTICAL_MARGIN)
    })
  }

  /** Swift SwarmInfoView `segmentedControlSection` — Settings | Documents for a 1:1 swarm. */
  @Builder
  private segmentedControl() {
    Row() {
      ForEach([SECTION_SETTINGS, SECTION_DOCUMENTS], (section: number) => {
        Text(section === SECTION_SETTINGS
          ? $r('app.string.swarm_settings') : $r('app.string.collab_documents'))
          .layoutWeight(1)
          .height(SEGMENT_HEIGHT)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(section === this.selectedSection ? TITLE_WEIGHT : REGULAR_WEIGHT)
          .fontColor($r('app.color.label'))
          .backgroundColor(section === this.selectedSection
            ? $r('sys.color.comp_background_list_card') : Color.Transparent)
          .borderRadius(SEGMENT_PILL_RADIUS)
      }, (section: number) => `${section}`)
    }
    .width(`calc(100% - ${GENERAL_MARGIN * 2}vp)`)
    .height(SEGMENT_HEIGHT + SEGMENT_TRACK_INSET + SEGMENT_TRACK_INSET)
    .backgroundColor($r('sys.color.comp_background_gray'))
    .borderRadius(SEGMENT_TRACK_RADIUS)
    .padding(SEGMENT_TRACK_INSET)
    .margin({ bottom: LengthMetrics.vp(SECTION_SPACING) })
    .id('swarm_info_segmented_control')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.segmentedWidth = newArea.width;
      }
    })
    .onClick((event: ClickEvent) => {
      this.selectedSection = this.segmentedWidth > 0 && event.x < this.segmentedWidth / 2
        ? SECTION_SETTINGS : SECTION_DOCUMENTS;
    })
  }

  /**
   * Jami 4.20 (SwarmInfoView / SettingsView), what the iPhone shows for a 1:1 swarm: header,
   * Settings | Documents, then the Contact section (identifier, QR, share, Remove contact,
   * Block contact) and the Conversation section (Conversation ID, type, colour, Remove
   * conversation). The destructive rows raise this page's own confirmations.
   */
  @Builder
  private swarmInfoLayout() {
    Column() {
      Row() {
        this.backItem()
      }
      .width('100%')

      this.swarmHeader()
      this.segmentedControl()

      if (this.selectedSection === SECTION_SETTINGS) {
        Scroll() {
          Column() {
            // SettingsViewSection takes the id and labels by value; keying it rebuilds the
            // section once the conversation resolves.
            ForEach([`${this.conversationId}|${this.removeConversationLabel}`], (key: string) => {
              SettingsViewSection({
                contactJamiId: this.jamiId,
                isOneToOne: true,
                conversationId: this.conversationId,
                conversationTypeLabel: this.conversationTypeLabel,
                finalColor: this.finalColor,
                selectedColor: $selectedColor,
                shareInfo: this.shareInfo,
                removeConversationLabel: this.removeConversationLabel,
                isLeave: false,
                isColorPickerOpen: $isColorPickerOpen,
                showQRcode: $showQRcode,
                onRemoveContact: (): void => {
                  this.removeContact();
                },
                onBlockContact: (): void => {
                  this.blockContact();
                },
                onRemoveConversation: (): void => {
                  this.removeConversation();
                }
              })
            }, (key: string) => key)
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      } else {
        Column() {
          CollaborativeDocumentsSheet({
            isPresented: $showCollabDocuments,
            accountId: this.conversation === null ? '' : this.conversation.accountId,
            conversationId: this.conversationId,
            localJamiId: this.localJamiId,
            onOpenDocument: (documentId: string): void => {
              this.leaveForDocument(documentId);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.warning'))
          .textAlign(TextAlign.Center)
          .padding(GENERAL_MARGIN)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isSwarmLayout) {
        this.swarmInfoLayout()
      } else {
        Column() {
          // S5 — capture S0022/S0024: the `[0,53][393,97]` nav band. The title view is centred in
          // it and the `Back` bar-button sits at the leading edge, both on the white page. The
          // back affordance is controlInventory's `implicit: true / affordance: back` entry: an
          // @Entry router page draws no system chrome, so it is composed here.
          Stack({ alignContent: Alignment.Start }) {
            // Swift `navigationItem.titleView = titleView` — avatar + name, not interactive.
            // UINavigationBar centres the title view in the room the bar items leave, so it never
            // runs under `Back`: inset it by the back item's width on both sides.
            TitleView({
              text: this.title, avatarBuilder: (): void => {
                this.titleAvatar()
              }
            })
              .padding({ start: LengthMetrics.vp(this.backItemWidth), end: LengthMetrics.vp(this.backItemWidth) })

            this.backItem()
          }
          .width('100%')
          .constraintSize({ minHeight: NAV_BAR_HEIGHT })
          .backgroundColor($r('sys.color.background_primary'))

          List() {
            // Swift `tableView.addSubview(stretchyHeader)` — the profile header scrolls with the
            // rows, which is what makes it a list header here rather than page chrome.
            ListItem() {
              ProfileHeaderView({
                avatarBuilder: (): void => {
                  this.headerAvatar()
                },
                displayName: this.displayName,
                userName: this.userName,
                jamiId: this.jamiId
              })
            }

            LazyForEach(this.contactActionListContactActionsMake, (item: ContactActionRow) => {
              ListItem() {
                this.actionRow(item)
              }
            }, (item: ContactActionRow) => item.kind)
          }
          .layoutWeight(1)
          .width('100%')
          // Capture S0022: a PLAIN table — white, edge-to-edge rows, no grouped card chrome.
          .backgroundColor($r('sys.color.background_primary'))
          .scrollBar(BarState.Auto)

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.secondary_label'))
              .textAlign(TextAlign.Center)
              .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          }
        }
        .width('100%')
        .height('100%')
      }

      if (this.showDaemonNotice) {
        this.daemonGapNotice()
      }
    }
    .width('100%')
    .height('100%')
    // Capture S0022/S0024: `systemBackground` — a plain white page; SwarmInfoView sits on
    // `systemGroupedBackground`.
    .backgroundColor(this.isSwarmLayout
      ? $r('sys.color.background_secondary') : $r('sys.color.background_primary'))
    .id('screen_contact')
  }
}
