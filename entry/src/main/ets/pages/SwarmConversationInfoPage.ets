/*
 * screen_swarm_info — "Swarm / Conversation Info", ported from
 *   Ring/Ring/SwarmInfo/View/SwarmInfoView.swift + SettingsView.swift + MembersList.swift
 *   Ring/Ring/SwarmInfo/View/ExpandableAvatar.swift
 *   Ring/Ring/SwarmInfo/SwarmInfoVM.swift
 *   Ring/Ring/Features/Collab/CollabDocumentsView.swift (the documents tab)
 *
 * presentation: page. `ConversationsCoordinator.presentSwarmInfo` pushes it with `.show`, so it
 * is an @Entry page reached by router.pushUrl from screen_conversation.
 *
 * S3 — the REAL component tree of `SwarmInfoView.body`, unstyled:
 *
 *   ZStack(bottomTrailing) { systemGroupedBackground ; mainContent ; floatingActionButton ;
 *                            documentNamePrompt }
 *   mainContent = List { topArea ; segmentedControlSection ; contentArea }
 *   topArea     = VStack { avatarView ; if !isAvatarExpanded { infoStack } }
 *   avatarView  = provider.canExpand ? ExpandableAvatar(...) { scrimmedInfo }
 *                                    : AvatarSwiftUIView(source:)
 *   infoStack   = VStack { titleLabel ; descriptionView ; if !profileActions.isEmpty {
 *                            profileActionButtons } }
 *   contentArea = switch selectedView { .about -> SettingsView
 *                                       .memberList -> MemberList
 *                                       .documents -> CollabDocumentsView }
 *
 * conditionalVariants, each an ArkUI `if` on the field the plan names:
 *   about_tab -> isAboutTab   members_tab -> isMembersTab   documents_tab -> isDocumentsTab
 *   can_call  -> canCall      can_edit    -> canEdit        can_add      -> canAdd
 *   one_to_one-> isOneToOne   group       -> isGroup        is_admin     -> isAdmin
 *   avatar_expandable -> isAvatarExpandable   color_picker_open -> isColorPickerOpen
 *
 * bindingContract: title <- ConversationModel.title, description <- .description, avatar <-
 * svc_profiles, member rows <- ConversationModel.participants, documents <- svc_collaboration,
 * and the section list itself <- svc_conversations (Swift's `swarmViews`, which depends on
 * whether the conversation is a coredialog and whether it is a swarm). All of them are read
 * off the services in `applyConversation()`; nothing here is a literal from a capture.
 *
 * SEEDED EMPTY: creating a Jami account is daemon-gated, so on this build the conversation
 * resolves to nothing, the member list is empty and `svc_collaboration` can list no documents
 * (it has no list call — every documents read is the daemon gap). The source's own empty
 * state (`collab_no_documents`) is what shows. Nothing is faked to fill the screen.
 *
 * OVERLAY HOST. screen_conversation_profile_editor (@CustomDialog),
 * screen_collab_documents (sheet) and screen_invite_participants (sheet) mount here — ArkUI
 * binds ONE sheet per component, so each sheet hangs off its own trigger control, exactly as
 * Swift hangs each `.sheet` off the view that raises it. `Call`/`Video` present screen_call
 * (@CustomDialog, mounted here as on ContactInfoPage); the contact QR sheet is mounted by
 * comp_settings_view_section, which is where SettingsView.swift puts it.
 *
 * DAEMON GAP: placing a call, removing/blocking a contact, removing a conversation, changing
 * the swarm colour and listing documents are all jami-daemon work. Each control keeps its
 * place, runs, and states the ceiling; none of them returns silently.
 *
 * S5/S6 style this tree against S0032, S0098-S0105, S0107.
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics, router } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AudioService } from '../common/AudioService';
import { AvatarSize } from '../common/JamiConstants';
import { DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { JamiUri, UriType } from '../common/JamiUri';
import { DisposeBag } from '../common/Observable';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { CallDirection } from '../model/CallState';
import {
  ConversationAttributes,
  ConversationModel,
  ConversationType,
  conversationTypeStringResource
} from '../model/ConversationModel';
import { ConversationParticipant, ParticipantRole } from '../model/ConversationParticipant';
import { ConversationPreferenceAttribute, DEFAULT_SWARM_COLOR_HEX }
  from '../model/ConversationPreferences';
import { Profile } from '../model/Profile';
import { AvatarSwiftUIView, GroupAvatarSelection } from '../components/AvatarSwiftui';
import {
  ExpandableAvatar, groupAvatarFor, groupMember, groupTitleFor, swarmMembers
} from '../components/ExpandableAvatar';
import { MemberList } from '../components/MemberList';
import { SettingsViewSection } from '../components/SettingsViewSection';
import {
  EDIT_CONVERSATION_KEY,
  EditConversationProfileOverlay
} from './EditConversationProfilePage';
import { CollaborativeDocumentsSheet } from './CollaborativeDocumentsPage';
import { InviteParticipantsSheet } from './InviteParticipantsPage';
import { InCallScreenOverlay } from './InCallScreenPage';
import { BackChevron } from '../components/BackButton';

/** Swift `SwarmSettingView` — the three sections the segmented control switches between. */
const SECTION_ABOUT: string = 'about';
const SECTION_MEMBERS: string = 'memberList';
const SECTION_DOCUMENTS: string = 'documents';

/**
 * Swift `SwarmSettingView.allCases` — the picker's full vocabulary. Used only when no
 * conversation resolved (see applyConversation), a state the source never reaches.
 */
const ALL_SECTIONS: string[] = [SECTION_ABOUT, SECTION_MEMBERS, SECTION_DOCUMENTS];

/** Swift `SwarmProfileAction` — the four profile-row actions, in the source's own order. */
const ACTION_AUDIO_CALL: string = 'audioCall';
const ACTION_VIDEO_CALL: string = 'videoCall';
const ACTION_EDIT_PROFILE: string = 'editProfile';
const ACTION_ADD_PARTICIPANT: string = 'addParticipant';

/** Swift `Layout.generalMargin` / `verticalMargin` / `callButtonSize` / `callButtonsMargin`. */
const GENERAL_MARGIN: number = 20;
const VERTICAL_MARGIN: number = 10;
const CALL_BUTTON_SIZE: number = 45;
const CALL_BUTTONS_MARGIN: number = 5;
/** Swift `Layout.avatarBottomGap` / `titleDescriptionSpacing`. */
const AVATAR_BOTTOM_GAP: number = 12;
const TITLE_DESCRIPTION_SPACING: number = 14;
/**
 * Swift `.font(.system(size: 20, weight: .semibold))` on a profile-action glyph. HM symbols draw
 * inside a wider em box than SF Symbols: at 20 the glyph read ~17vp against the iPhone's ~22pt
 * (TC-INFO-002 captures), so this is a calibration knob, not Swift's literal.
 */
const ACTION_GLYPH_SIZE: number = 24;
/** The composed nav bar of a pushed page. */
const NAV_BAR_HEIGHT: number = 44;
const BACK_GLYPH_GAP: number = 4;

/*
 * S5 — STYLE ONLY. Swift's `SwarmInfoView.Layout` supplies most of it verbatim
 * (verticalMargin 10, generalMargin 20, callButtonSize 45, callButtonsMargin 5,
 * avatarTopGap 14, avatarBottomGap 12, titleDescriptionSpacing 14, sectionSpacing 8,
 * expandedInfoBackdropStrength 0.9), and the source names its own colours per state:
 *   headerForeground     = isAvatarExpanded ? .white : .label
 *   buttonTint           = isAvatarExpanded ? .white : Color.jami
 *   callButtonBackground = isAvatarExpanded ? white 0.2 : secondarySystemGroupedBackground
 *   the page itself      = Color(UIColor.systemGroupedBackground)
 * mapped to the HarmonyOS token whose role matches. The capture (S0098, 393x852 pt) is the
 * cross-check: the nav band is [0,53]-[393,97], the avatar 121 pt square centred at
 * [136,107]-[257,228], and the grouped rows below run edge to edge.
 */
/** Swift `Layout.avatarTopGap` and `Layout.sectionSpacing`. */
const AVATAR_TOP_GAP: number = 14;
const SECTION_SPACING: number = 8;
/** Swift `titleLabel`: `.font(.title3.weight(.semibold))`. */
const TITLE_WEIGHT: number = 600;
/** The unselected segment's weight — spelled as a number so the ternary has ONE type. */
const REGULAR_WEIGHT: number = 400;
/** Swift `profileActionButton`: `RoundedRectangle(cornerRadius: Layout.verticalMargin)`. */
const ACTION_BUTTON_RADIUS: number = 10;
/** Swift `callButtonBackground` while the avatar is expanded: `Color.white.opacity(0.2)`. */
const EXPANDED_BUTTON_BACKGROUND: string = '#33FFFFFF';
/** Swift `scrim` = `Color.jamiOnVideoScrim.opacity(Layout.expandedInfoBackdropStrength)`. */
const SCRIM_STRONG: string = '#8A000000';
const SCRIM_MID: string = '#4D000000';
const SCRIM_SOFT: string = '#17000000';
const SCRIM_CLEAR: string = '#00000000';
/** Swift `scrimmedInfo`: `.padding(.top, 60)` above the gradient's own top. */
const SCRIM_TOP_PADDING: number = 60;
/** The segmented control's own metrics. */
const SEGMENT_TRACK_RADIUS: number = 8;
const SEGMENT_TRACK_FILL: string = '#1F767680';
const SEGMENT_PILL_RADIUS: number = 7;
const SEGMENT_TRACK_INSET: number = 2;
/** The pill; with the 2vp inset the track is UISegmentedControl's 32pt (iPhone captures). */
const SEGMENT_HEIGHT: number = 28;

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SwarmConversationInfoPage';

/** Swift's coordinator handed the model over; a routed page gets the conversation's key. */
interface SwarmInfoRouteParams {
  conversationKey?: string;
  /** The overlay this page hosts that a deep link asked for (EntryAbility.routeToTarget). */
  overlayScreen?: string;
}

@Entry
@Component
struct SwarmConversationInfoPage {
  /** bindingContract: title <- ConversationModel.title (Swift `viewModel.title`). */
  @State @Watch('splitTitle') title: string = '';
  /**
   * Swift `titleLabel` is `.lineLimit(2).truncationMode(.middle)`: a long name wraps once and
   * its SECOND line keeps the head and tail of the rest. ArkUI elides in the middle on one line
   * only, so the first line is measured off (`splitTitle`) and the rest is a one-line CENTER
   * ellipsis (T-1075). An empty tail means the whole name is the head.
   */
  @State private titleHead: string = '';
  @State private titleTail: string = '';
  @State @Watch('splitTitle') private titleWidth: number = 0;
  /** bindingContract: description <- ConversationModel.description. */
  @State description: string = '';
  /** bindingContract: avatar <- svc_profiles / ConversationModel.avatar. */
  @State avatar: string = '';
  /** Swift `groupAvatarSnapshot` — the member composite when the swarm has no picture. */
  @State groupAvatar: GroupAvatarSelection = new GroupAvatarSelection();
  /** bindingContract: member rows <- ConversationModel.participants. */
  @State memberRows: ArrayDataSource<ConversationParticipant> =
    new ArrayDataSource<ConversationParticipant>([]);
  /** Swift `viewModel.members.count` — the count the Members segment is titled with. */
  @State memberCount: number = 0;
  /** Swift `swarmInfo.id` — @State so the settings section is rebuilt once it resolves. */
  @State conversationId: string = '';

  /** conditionalVariants[about_tab]: Swift `selectedView == .about`. */
  @State isAboutTab: boolean = true;
  /** conditionalVariants[members_tab]: Swift `selectedView == .memberList`. */
  @State isMembersTab: boolean = false;
  /** conditionalVariants[documents_tab]: Swift `selectedView == .documents`. */
  @State isDocumentsTab: boolean = false;
  /** conditionalVariants[can_call]: Swift `viewModel.callTarget != nil`. */
  @State canCall: boolean = false;
  /** conditionalVariants[can_edit]: Swift `viewModel.canEditProfile`. */
  @State canEdit: boolean = false;
  /** conditionalVariants[can_add]: Swift `viewModel.canAddParticipants`. */
  @State canAdd: boolean = false;
  /** conditionalVariants[one_to_one]: Swift `getContactJamiId() != nil` (a coredialog). */
  @State isOneToOne: boolean = false;
  /** conditionalVariants[group]: Swift `isGroupProfile` — no contact section. */
  @State isGroup: boolean = false;
  /** conditionalVariants[avatar_expandable]: Swift `viewModel.provider.canExpand`. */
  @State isAvatarExpandable: boolean = false;
  /** conditionalVariants[color_picker_open]: Swift `showColorPicker == true`. */
  @State isColorPickerOpen: boolean = false;
  /** conditionalVariants[is_admin]: Swift `viewModel.isAdmin`. */
  @State isAdmin: boolean = false;

  /** True while svc_conversations / svc_profiles / svc_collaboration are in flight. */
  @State isLoading: boolean = true;
  /** The failure text this screen shows; empty when there is no failure. */
  @State errorText: string = '';
  /** Written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `@State private var selectedView: SwarmSettingView = .about`. */
  @State private selectedView: string = SECTION_ABOUT;
  /** Swift `@State private var isAvatarExpanded = false`. */
  @State private isAvatarExpanded: boolean = false;
  /** CollaborativeDocumentsSheet's @Link; it lowers this when it opens a document. */
  @State private showCollabDocuments: boolean = false;
  /** Swift `isInvitingParticipants` — raises screen_invite_participants. */
  @State private showInviteParticipants: boolean = false;
  /**
   * Lifted out of SettingsViewSection (Swift `@SwiftUI.State private var showQRcode`) so
   * this page's onBackPress can see and close it — same @Link shape as isColorPickerOpen.
   */
  @State private showQRcode: boolean = false;
  /** Tracks the profile-editor CustomDialogController's open state for onBackPress. */
  @State private isEditProfileOpen: boolean = false;
  /** The disclosed daemon gap raised by this screen's own destructive rows. */
  @State private showDaemonNotice: boolean = false;
  /** Swift `viewModel.finalColor` <- ConversationPreferences.color. */
  @State private finalColor: string = DEFAULT_SWARM_COLOR_HEX;
  /** Swift `@Published var selectedColor` — written by the picker, persisted on change. */
  @State @Watch('onSelectedColorChanged') private selectedColor: string = '';
  /** Swift `viewModel.swarmInfo.type.value.stringValue`, resolved to text. */
  @State private conversationTypeLabel: string = '';
  /** Swift `viewModel.getContactJamiId()`. */
  @State private contactJamiId: string = '';
  /** Swift `viewModel.createShareInfo(for:)`. */
  @State private shareInfo: string = '';
  /** Swift `viewModel.removeConversationText`. */
  @State private removeConversationLabel: string = '';
  /** Swift `ConversationRemovalPresentation == .leave` (SettingsView's leave icon). */
  @State private isLeave: boolean = false;
  /** Swift `viewModel.removeConversationConfirmation`. */
  @State private removeConversationMessage: string = '';

  /** Swift `viewModel.conversation`. */
  private conversation: ConversationModel | null = null;
  /** The route param, kept so the profile-editor overlay can be told what it is editing. */
  private conversationKey: string = '';
  /** Swift `localJamiId` for MemberList. */
  private localJamiId: string = '';
  /**
   * bindingContract `swarm sections list` <- svc_conversations. Swift's `swarmViews`: About
   * always, Members when it is not a coredialog, Documents when it is a swarm. Also what the
   * segmented control's tap hit-test resolves against (Swift's Picker is ONE control).
   */
  @State private sectionList: string[] = [SECTION_ABOUT];
  /** The segmented control's measured width, for that same hit test. */
  private segmentedWidth: number = 0;
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /**
   * screen_conversation_profile_editor — presentation: modal, hostScreen: screen_swarm_info.
   * Swift: `viewModel.editProfile(stateEmitter:)` -> ConversationProfileEditorView presented.
   */
  /** A deep link is delivered once per arrival; the overlay it names is opened once. */
  private deepLinkOverlayOpened: boolean = false;
  /**
   * screen_call — presentation: modal. Swift's coordinator presents the call over this view on
   * `.startAudioCall`/`.startCall`; the overlay is mounted here as ContactInfoPage does.
   */
  @State private showCallScreen: boolean = false;
  private callDialog: CustomDialogController = new CustomDialogController({
    builder: InCallScreenOverlay({ isPresented: $showCallScreen }),
    autoCancel: false,
    // Back closes the call screen; the call goes on (the home page offers the way back).
    cancel: (): void => {
      this.showCallScreen = false;
    },
    // T-1731: Back with an in-call sheet open closes only the sheet, as iOS.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK && InCallScreenOverlay.closeOpenPanel()) {
        return;
      }
      this.showCallScreen = false;
      action.dismiss();
    },
    customStyle: true,
    // The call screen's add-participant picker sits ON the keyboard: the default 16 vp avoid
    // distance showed a strip of this page between the two (T-1470, as T-1317).
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });
  private editProfileDialog: CustomDialogController = new CustomDialogController({
    builder: EditConversationProfileOverlay(),
    autoCancel: true,
    customStyle: true,
    // Default avoidance re-lays the full-screen editor out above the keyboard and the info
    // page showed through a strip above it (review T-1184); iOS keeps the sheet in place.
    keyboardAvoidMode: KeyboardAvoidMode.NONE
  });

  /** The load below runs once, off the first frame — see `onPageShow`. */
  private loaded: boolean = false;

  /*
   * NOTHING in aboutToAppear. Every cold deep link to this page lands here BEFORE the first
   * frame is drawn, so service subscriptions, the conversation resolution and — above all —
   * opening the profile-editor CustomDialog used to run with no layout yet: the page's
   * `.id('screen_swarm_info')` marker reached the screen late (the drivers read the smart
   * list under it) and the dialog measured its own toolbar against a viewport that did not
   * exist, collapsing Cancel/Save out of the tree. `onPageShow` fires once the page is on
   * screen, which is where ConversationChatPage already does the same work correctly.
   */
  onPageShow(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.load();
  }

  private load(): void {
    // The gaps THIS screen's own controls raise.
    this.bag.add(ServiceRegistry.shared().daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'contact.remove' || error.feature === 'contact.ban' ||
          error.feature === 'conversation.updatePreferences') {
          this.showDaemonNotice = true;
          this.errorText = error.message;
        }
      }));
    const raw: Object | undefined = router.getParams();
    const key: string = raw === undefined
      ? '' : ((raw as SwarmInfoRouteParams).conversationKey ?? '');
    this.conversationKey = key;
    this.applyConversation(this.resolveConversation(key));
    // EntryAbility.routeToTarget deep-links an overlay by pushing THIS page with the overlay's
    // screen id; the coordinator presented it on top of the same view in Swift. The overlay
    // opens whether or not a conversation resolved — on a daemon-less build none does, and the
    // overlay's own empty state is what the source shows there.
    this.openDeepLinkOverlay(raw === undefined
      ? '' : ((raw as SwarmInfoRouteParams).overlayScreen ?? ''));
    // svc_db fills `conversations` from the per-account store after startup, so a conversation
    // can land AFTER this page opened.
    this.bag.add(ServiceRegistry.shared().conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        if (this.conversation !== null || conversations.length === 0) {
          return;
        }
        this.applyConversation(this.resolveConversation(key));
      }));
    // Swift `swarmInfo.finalTitle` follows `conversationProfileUpdated`: an Edit > Save shows
    // the new name, description and picture here at once (T-1586). SwarmInfo
    // `subscribeConversationEvents` also re-reads the members on `conversationMemberEvent`, so
    // a removed member leaves the Members tab and a new invitee joins it (T-1135).
    this.bag.add(ServiceRegistry.shared().conversationsService.sharedResponseStream.subscribe(
      (event: ServiceEvent): void => {
        const current: ConversationModel | null = this.conversation;
        if (current !== null &&
          (event.eventType === ServiceEventType.CONVERSATION_PROFILE_UPDATED ||
            event.eventType === ServiceEventType.CONVERSATION_MEMBER_EVENT) &&
          event.getEventInput(ServiceEventInput.CONVERSATION_ID) === current.id) {
          this.applyConversation(current);
        }
      }));
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscriptions go whatever happened above.
    try {
      this.bag.dispose();
    } finally {
      // A CustomDialog outlives the page that opened it: popped with the profile editor up,
      // its own full-screen mask stays on top of whatever page comes next and eats every tap
      // there (the symptom is a gesture that lands with a byte-identical UI tree after).
      // onBackPress already does this for hardware Back; every other way off the page needs it
      // too. The system alerts (`confirm`) close on their own with the page.
      this.isEditProfileOpen = false;
      this.editProfileDialog.close();
      this.callDialog.close();
    }
  }

  /** The same key split ContactInfoPage and the smart list use. */
  private resolveConversation(key: string): ConversationModel | null {
    const conversations: ConversationModel[] =
      ServiceRegistry.shared().conversationsService.conversations.value;
    const separator: number = key.indexOf('|');
    if (key.length === 0 || separator < 0) {
      // Swift got the conversation handed to it; with no route param there is nothing to
      // resolve, and the screen stays empty rather than guessing a conversation.
      return null;
    }
    const accountId: string = key.substring(0, separator);
    const identity: string = key.substring(separator + 1);
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
    return null;
  }

  /** Swift `SwarmInfoVM.init` + `setupBindings()`, in the source's own order. */
  private applyConversation(conversation: ConversationModel | null): void {
    this.conversation = conversation;
    if (conversation === null) {
      // No conversation resolved — creating a Jami account is daemon-gated, so the router
      // param names nothing. Swift never reaches this state and its `swarmViews` therefore
      // says nothing about it, so the picker falls back to the SwarmSettingView enum's own
      // full case list instead of collapsing to one dead segment. The rows behind each
      // section stay empty: only the section vocabulary is restored, never any content.
      this.applySections(ALL_SECTIONS);
      this.isLoading = false;
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.getAccount(conversation.accountId);
    this.localJamiId = account === null ? '' : account.jamiId;

    // Swift `isGroupProfile` / `canAddParticipants` / `getContactJamiId()`.
    const coredialog: boolean = conversation.isCoredialog();
    this.isGroup = !coredialog;
    this.isOneToOne = coredialog;
    this.canAdd = !coredialog;

    // Swift `currentUserIsAdmin(in:)` — an admin entry whose jamiId is this account's. The
    // local member is the one being looked for, so it is searched among ALL participants.
    const participants: ConversationParticipant[] = conversation.getParticipants();
    this.isAdmin = !coredialog && this.localJamiId.length > 0 &&
      conversation.getAllParticipants().some((participant: ConversationParticipant) =>
        participant.role === ParticipantRole.ADMIN && participant.jamiId === this.localJamiId);

    // Swift `canEditProfile` -> `profileEditingAllowed(isCoreDialog:hasRemoteParticipant:isAdmin:)`.
    this.canEdit = coredialog ? !conversation.isOnlyLocalParticipant() : this.isAdmin;
    // Swift `callTarget` — `callService.outgoingCallURI(for:)`: the peer for a 1:1, the active
    // call or `swarm:<id>` for a group with members.
    this.canCall = registry.callService.outgoingCallURI(conversation) !== null;

    // Swift `getContactJamiId()`: the first remote participant, else the local one.
    if (coredialog) {
      const local: ConversationParticipant | null = conversation.getLocalParticipants();
      this.contactJamiId = participants.length > 0
        ? participants[0].jamiId : (local === null ? '' : local.jamiId);
      // Swift `createShareInfo(for:)` — L10n.Swarm.shareContactMessage(jamiId): the id is
      // INTERPOLATED into the invite sentence, so the bare id is not the share payload.
      this.shareInfo = this.contactJamiId.length === 0 ? '' : getContext(this)
        .resourceManager
        .getStringByNameSync('swarm_share_contact_message')
        .replace('%1$s', this.contactJamiId);
    } else {
      this.contactJamiId = '';
      this.shareInfo = '';
    }

    // Swift `swarmInfo.finalTitle` / `.description` / `.color`.
    const info: Map<string, string> = registry.conversationsService
      .getConversationInfo(conversation.id, conversation.accountId);
    const infoTitle: string | undefined = info.get(ConversationAttributes.TITLE);
    const infoDescription: string | undefined = info.get(ConversationAttributes.DESCRIPTION);
    this.title = infoTitle === undefined || infoTitle.length === 0
      ? conversation.title : infoTitle;
    if (this.title.length === 0 && coredialog && this.contactJamiId.length > 0) {
      // Swift `finalTitle` for a 1:1 is the peer's best name (alias, registered name, id); an
      // empty title also left the avatar disc on its default colour instead of the peer's.
      this.title = groupMember(new ConversationParticipant(this.contactJamiId),
        conversation.accountId).name;
    }
    if (this.title.length === 0 && !coredialog) {
      // Swift `buildTitleFrom(names:)`: an untitled swarm is named after its members.
      this.title = groupTitleFor(conversation,
        getContext(this).resourceManager.getStringByNameSync('conversation_yourself'));
    }
    this.description = infoDescription === undefined || infoDescription.length === 0
      ? conversation.description : infoDescription;
    this.conversationTypeLabel = this.resolveTypeLabel();

    // Swift `AvatarProvider.from(swarmInfo:profileService:size:supportsExpansion:)`.
    this.avatar = conversation.avatar;
    this.groupAvatar = groupAvatarFor(conversation);
    if (coredialog && this.contactJamiId.length > 0) {
      this.bag.add(registry.profileService
        .getProfile(this.contactJamiId, conversation.accountId)
        .subscribe((profile: Profile): void => {
          // Every emission is authoritative: after "Use original name and picture" + Save the
          // custom profile is gone and the peer's own (maybe empty) alias and photo come back,
          // so an empty one falls back instead of keeping the edited value (T-1240).
          const photo: string | null = profile.photo;
          this.avatar = photo !== null && photo.length > 0 ? photo : conversation.avatar;
          this.isAvatarExpandable = this.avatar.length > 0;
          if (infoTitle === undefined || infoTitle.length === 0) {
            const alias: string = profile.alias === null ? '' : profile.alias.trim();
            this.title = alias.length > 0 ? alias : groupMember(
              new ConversationParticipant(this.contactJamiId), conversation.accountId).name;
          }
        }));
    }
    // Swift `provider.canExpand` — only a real picture can be expanded.
    this.isAvatarExpandable = this.avatar.length > 0;

    // Swift `swarmInfo.color` -> ConversationPreferences.color.
    const prefs: Map<string, string> | null = registry.conversationsService
      .getConversationPreferences(conversation.accountId, conversation.id);
    const color: string | undefined = prefs === null
      ? undefined : prefs.get(ConversationPreferenceAttribute.COLOR);
    // Swift ConversationPreferences.color defaults to defaultSwarmColorHex, so with nothing
    // stored the picker still rings the default cyan (review T-1687).
    const effectiveColor: string = color !== undefined && color.length > 0
      ? color : DEFAULT_SWARM_COLOR_HEX;
    this.finalColor = effectiveColor;
    this.selectedColor = effectiveColor;

    // Swift `removeConversationText` — ConversationDestructiveAction.removeConversation
    // .title(for:): `.leave` unless SIP, a dialog or note-to-self (ConversationRemovalPresentation).
    const leave: boolean = !(conversation.isSip() || conversation.isDialog() ||
      conversation.isOnlyLocalParticipant());
    this.isLeave = leave;
    this.removeConversationLabel = getContext(this).resourceManager
      .getStringByNameSync(leave ? 'swarm_leave_conversation' : 'swarm_remove_conversation');
    // Swift `confirmationMessage(for:)`: a coredialog gets the one-to-one text, else leave/remove.
    this.removeConversationMessage = getContext(this).resourceManager.getStringByNameSync(
      conversation.isCoredialog() && !conversation.isSip()
        ? 'alerts_confirm_remove_one_to_one_conversation'
        : (leave ? 'alerts_confirm_leave_conversation' : 'alerts_confirm_delete_conversation'));

    // bindingContract: the sections and the members, all from the services. The documents
    // section loads its own list (CollaborativeDocumentsSheet.reload, Swift `.onAppear`).
    this.applySections(this.swarmViews(conversation));
    const members: ConversationParticipant[] = swarmMembers(conversation);
    this.memberRows.reload(members);
    this.memberCount = members.length;
    this.conversationId = conversation.id;
    this.isLoading = false;
  }

  /** One writer for the bound section list. */
  private applySections(views: string[]): void {
    this.sectionList = views;
    if (views.indexOf(this.selectedView) < 0) {
      this.selectSection(views.length > 0 ? views[0] : SECTION_ABOUT);
    }
  }

  /**
   * Swift `swarmViews`: About always; Members when it is not a coredialog; Documents when it
   * is a swarm (a document lives in the conversation's repository).
   */
  private swarmViews(conversation: ConversationModel): string[] {
    const views: string[] = [SECTION_ABOUT];
    if (!conversation.isCoredialog()) {
      views.push(SECTION_MEMBERS);
    }
    if (conversation.isSwarm()) {
      views.push(SECTION_DOCUMENTS);
    }
    return views;
  }

  /**
   * Swift `swarmInfo.type.value.stringValue`. SwarmInfo.swift declares
   * `let type = BehaviorRelay(value: ConversationType.oneToOne)` and never accepts another
   * value, so iOS reads "Private" for every conversation, group or not. Matched as-is.
   */
  private resolveTypeLabel(): string {
    return getContext(this).resourceManager
      .getStringByNameSync(conversationTypeStringResource(ConversationType.ONE_TO_ONE));
  }

  /** Swift `Picker("", selection: $selectedView)`. */
  private selectSection(section: string): void {
    this.selectedView = section;
    this.isAboutTab = section === SECTION_ABOUT;
    this.isMembersTab = section === SECTION_MEMBERS;
    this.isDocumentsTab = section === SECTION_DOCUMENTS;
  }

  /** Swift: the `.documents` segment — CollabDocumentsView, inline in the content area. */
  private openCollabDocuments(): void {
    this.selectSection(SECTION_DOCUMENTS);
  }

  /** The overlays this page hosts, opened through the same paths their own controls use. */
  private openDeepLinkOverlay(overlay: string): void {
    if (overlay.length === 0 || this.deepLinkOverlayOpened) {
      return;
    }
    this.deepLinkOverlayOpened = true;
    if (overlay === 'screen_conversation_profile_editor') {
      this.openProfileEditor();
    } else if (overlay === 'screen_collab_documents') {
      this.openCollabDocuments();
    } else if (overlay === 'screen_invite_participants') {
      this.inviteParticipants();
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'deep link named an overlay this page does not host: %{public}s', overlay);
    }
  }

  /** Swift `SwarmProfileAction.editProfile` -> `editProfile()`. */
  private openProfileEditor(): void {
    // The overlay reads this the moment it mounts; see EditConversationProfilePage's note on
    // why a @CustomDialog cannot take it as a builder argument.
    AppStorage.setOrCreate<string>(EDIT_CONVERSATION_KEY, this.conversationKey);
    this.isEditProfileOpen = true;
    this.editProfileDialog.open();
  }

  /**
   * Hardware Back closes whichever overlay THIS screen owns instead of popping the whole
   * page out from under it — every one of these was a `.sheet`/`.alert`/CustomDialog on the
   * same Swift view, so system Back dismisses the topmost overlay there and never leaves
   * the screen. Order follows what a user opens on top of what: the two full-screen sheets
   * and the colour-picker sheet first (the system alerts close on Back themselves), the
   * profile editor last since it is reachable only via a deep link or a menu action that
   * closes any of the above first.
   */
  onBackPress(): boolean {
    if (this.showInviteParticipants) {
      this.showInviteParticipants = false;
      return true;
    }
    if (this.showQRcode) {
      this.showQRcode = false;
      return true;
    }
    if (this.isColorPickerOpen) {
      this.isColorPickerOpen = false;
      return true;
    }
    if (this.isEditProfileOpen) {
      this.isEditProfileOpen = false;
      this.editProfileDialog.close();
      return true;
    }
    return false;
  }

  /**
   * Swift `placeAudioCall()` / `placeVideoCall()`:
   *   guard let target = viewModel.callTarget else { return }
   *   stateEmitter.emitState(.startAudioCall(contactRingId: target.uri, userName:))
   * The coordinator then placed the call. Same order here: svc_calls places it and svc_audio
   * takes the route CallKit used to set, exactly as ContactInfoPage does for the same two
   * controls. The SIP/DHT transport is the disclosed libjami gap, so a call that cannot be
   * placed shows the notice — never a silent return, and never a bare toast standing in for
   * the call itself.
   */
  private startCall(audioOnly: boolean): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    // Swift `guard let target = viewModel.callTarget` — for a group that is the swarm call
    // (`swarm:<id>`), never its first member (T-1094).
    const target: string | null = conversation === null
      ? null : ServiceRegistry.shared().callService.outgoingCallURI(conversation);
    if (conversation === null || target === null) {
      this.showDaemonNotice = true;
      return;
    }
    ServiceRegistry.shared().callService
      .placeCall(conversation.accountId, target, audioOnly)
      .then((): void => {
        // Swift: CallKit activated the session and AudioService.callKitActivated set the
        // route. With no system call provider the app does it at the same moment.
        const audio: AudioService = ServiceRegistry.shared().audioService;
        audio.callKitActivated(!audioOnly, CallDirection.OUTGOING);
        this.showCallScreen = true;
        this.callDialog.open();
      })
      .catch((error: Object): void => {
        if (error instanceof DaemonUnavailableError) {
          this.showDaemonNotice = true;
          return;
        }
        this.errorText = describeError(error as BusinessError);
      });
  }

  /** Swift `SwarmProfileAction.addParticipant` -> `isInvitingParticipants = true`. */
  private inviteParticipants(): void {
    this.showInviteParticipants = true;
  }

  /** Swift `setAvatarExpanded(!isAvatarExpanded)`. */
  private toggleAvatarExpanded(): void {
    this.isAvatarExpanded = !this.isAvatarExpanded;
  }

  /** Swift `.onChange(of: viewmodel.selectedColor) { updateSwarmColor(selectedColor:) }`. */
  private onSelectedColorChanged(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (this.selectedColor.length === 0 || conversation === null) {
      return;
    }
    if (this.selectedColor === this.finalColor) {
      // The load path seeds both from the stored preference; only a PICK is a write.
      return;
    }
    this.finalColor = this.selectedColor;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const prefs: Map<string, string> | null = registry.conversationsService
      .getConversationPreferences(conversation.accountId, conversation.id);
    const updated: Map<string, string> = prefs === null ? new Map<string, string>() : prefs;
    updated.set(ConversationPreferenceAttribute.COLOR, this.selectedColor);
    // The daemon owns the preference store, so the write reports the gap through the
    // subscription in aboutToAppear rather than silently doing nothing.
    registry.conversationsService
      .updateConversationPrefs(conversation.accountId, conversation.id, updated);
  }

  /** Swift `viewModel.removeMember(indexOffset:)`. */
  private removeMember(jamiId: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      this.showDaemonNotice = true;
      return;
    }
    // Swift calls removeConversationMember and nothing else; the row goes when the daemon's
    // conversationMemberEvent re-reads the members (load()).
    ServiceRegistry.shared().conversationsService
      .removeConversationMember(conversation.accountId, conversation.id, jamiId);
  }

  /** Swift `viewModel.removeConversation(stateEmitter:)`. */
  private removeConversation(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      this.showDaemonNotice = true;
      return;
    }
    ServiceRegistry.shared().conversationsService
      .removeConversation(conversation.id, conversation.accountId);
    // Swift `stateEmitter.emitState(.conversationRemoved)` -> ConversationsCoordinator
    // `popToSmartList()`: the iPhone lands on the list, not on the removed chat (T-1589).
    router.back({ url: 'pages/SmartListConversationsHomePage' });
  }

  /** Swift `viewModel.blockContact(stateEmitter:)`. */
  private blockContact(): void {
    this.performContactRemoval(true);
  }

  /** Swift `viewModel.removeContact(stateEmitter:)`. */
  private removeContact(): void {
    this.performContactRemoval(false);
  }

  /** Swift `ConversationDestructiveActionExecutor.perform(.removeContact/.blockContact)`. */
  private performContactRemoval(ban: boolean): void {
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || this.contactJamiId.length === 0) {
      this.showDaemonNotice = true;
      return;
    }
    const jamiId: string = this.contactJamiId;
    ServiceRegistry.shared().contactsService
      .removeContact(jamiId, ban, conversation.accountId)
      .then((): void => {
        // SwarmInfoVM passes `removeConversationAfterContactRemoval: false`: the conversation is
        // KEPT (a blocked one is parked, so an unblock brings the original back, T-1558) and only
        // `clearCustomProfile(for:)` runs. No DB removal, no daemon removeConversation.
        const uri: string | null = JamiUri.fromInfoHash(
          conversation.isSip() ? UriType.SIP : UriType.RING, jamiId).uriString;
        if (uri !== null) {
          ServiceRegistry.shared().profileService
            .updateCustomProfile(uri, conversation.accountId, null, null);
        }
        // The iPhone lands on the smart list: the chat behind this page is gone (as T-1559).
        router.back({ url: 'pages/SmartListConversationsHomePage' });
      })
      .catch((error: Object): void => {
        if (error instanceof DaemonUnavailableError) {
          this.showDaemonNotice = true;
          this.errorText = error.message;
          return;
        }
        // The local DB removal can fail too; say so rather than staying silently.
        this.errorText = describeError(error as BusinessError);
      });
  }

  /**
   * Swift `swarmInfo.contacts` already excludes the swarm's own members, so the invite sheet
   * is handed who is in it rather than filtering the contact list a second time. Swift's
   * members are `swarmInfo.participants` (invited, member, admin, left): a removed (banned)
   * member is not one of them and stays invitable.
   */
  private memberIds(): string[] {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return [];
    }
    return swarmMembers(conversation)
      .map((participant: ConversationParticipant) => participant.jamiId);
  }

  /* ── builders ───────────────────────────────────────────────────────────────────── */

  /** screen_invite_participants — presentation: sheet, hostScreen: screen_swarm_info. */
  @Builder
  inviteParticipantsSheet() {
    InviteParticipantsSheet({
      isPresented: $showInviteParticipants,
      accountId: this.conversation === null ? '' : this.conversation.accountId,
      conversationId: this.conversation === null ? '' : this.conversation.id,
      existingMembers: this.memberIds()
    })
  }

  /** Swift `contentArea` case `.documents` — CollabDocumentsView, rendered in place. */
  @Builder
  collabDocumentsSheet() {
    CollaborativeDocumentsSheet({
      isPresented: $showCollabDocuments,
      accountId: this.conversation === null ? '' : this.conversation.accountId,
      conversationId: this.conversation === null ? '' : this.conversation.id,
      localJamiId: this.localJamiId,
      onOpenDocument: (documentId: string): void => {
        this.leaveForDocument(documentId);
      }
    })
  }

  /**
   * Swift: `stateEmitter.openDocument(...)` is handled by the CONVERSATION coordinator, which
   * presents CollabEditorViewController after this screen goes away. The sheet has already
   * published the document; this screen only has to return to the conversation, which opens
   * the editor from `pendingCollabDocumentId` on arrival.
   */
  private leaveForDocument(documentId: string): void {
    this.showCollabDocuments = false;
    if (documentId.length === 0) {
      return;
    }
    // Never pop the last page — this screen is pushed from the conversation, but a cold
    // deep link can land on it directly, and popping that would close the app.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: 'pages/ConversationChatPage' });
      return;
    }
    router.back();
  }

  /**
   * Splits `title` at the end of its first wrapped line at `titleWidth`: the longest prefix
   * that measures within the line, backed up to its last space as word wrapping does (a single
   * over-long word breaks mid-word). Code points, so an emoji is never cut in half.
   */
  private splitTitle(): void {
    const chars: string[] = Array.from(this.title);
    const ui: UIContext = this.getUIContext();
    const fits = (count: number): boolean => ui.px2vp(Number(ui.getMeasureUtils().measureText({
      textContent: chars.slice(0, count).join(''),
      fontSize: $r('sys.float.Title_S'),
      fontWeight: TITLE_WEIGHT
    }))) <= this.titleWidth;
    if (this.titleWidth <= 0 || fits(chars.length)) {
      this.titleHead = this.title;
      this.titleTail = '';
      return;
    }
    let low: number = 0;
    let high: number = chars.length - 1;
    while (low < high) {
      const mid: number = Math.ceil((low + high) / 2);
      if (fits(mid)) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    const space: number = chars.lastIndexOf(' ', low);
    const end: number = space > 0 ? space : Math.max(low, 1);
    this.titleHead = chars.slice(0, end).join('');
    this.titleTail = chars.slice(end).join('').trim();
  }

  /** Swift `profileActionButton(_:)` — a glyph over its title, the whole cell tappable. */
  @Builder
  private profileActionButton(action: string, glyph: Resource, title: ResourceStr,
    handler: () => void) {
    Column({ space: CALL_BUTTONS_MARGIN }) {
      // Swift `.font(.system(size: 20, weight: .semibold)).foregroundStyle(buttonTint)` on a
      // `RoundedRectangle(cornerRadius: 10).fill(callButtonBackground)` — both colours are
      // the source's own, and both flip while the avatar is expanded over its own picture.
      // The tile is a Stack so the glyph is centred: a SymbolGlyph sized to the tile draws
      // its symbol at the top-left of that box (review T-1093).
      Stack() {
        SymbolGlyph(glyph)
          .fontSize(ACTION_GLYPH_SIZE)
          .fontWeight(TITLE_WEIGHT)
          .fontColor([this.isAvatarExpanded ? Color.White : $r('app.color.jami')])
          // SF `person.badge.plus` draws its plus badge bottom-LEFT; HarmonyOS
          // `person_badge_plus` draws it bottom-right, so Invite's glyph is mirrored (T-1048).
          .scale({ x: action === ACTION_ADD_PARTICIPANT ? -1 : 1 })
      }
      .width(CALL_BUTTON_SIZE)
      .height(CALL_BUTTON_SIZE)
      .backgroundColor(this.isAvatarExpanded
        ? EXPANDED_BUTTON_BACKGROUND : $r('sys.color.comp_background_list_card'))
      .borderRadius(ACTION_BUTTON_RADIUS)
      // Swift `.font(.caption).foregroundStyle(headerForeground)`.
      Text(title)
        .maxLines(1)
        .fontSize($r('sys.float.Body_S'))
        .fontColor(this.isAvatarExpanded ? Color.White : $r('app.color.label'))
    }
    .alignItems(HorizontalAlign.Center)
    // Swift builds the identifier as "swarm_info_action_\(action)".
    .id(`swarm_info_action_${action}`)
    .onClick(() => {
      handler();
    })
  }

  /** Swift `profileActionButtons` — `SwarmProfileAction.available(canCall:canEdit:canAdd:)`. */
  @Builder
  private profileActionButtons() {
    Row({ space: GENERAL_MARGIN }) {
      // conditionalVariants[can_call]: both call buttons exist only with a call target.
      if (this.canCall) {
        this.profileActionButton(ACTION_AUDIO_CALL, $r('sys.symbol.phone'),
          $r('app.string.global_call'), (): void => {
            this.startCall(true);
          })
        this.profileActionButton(ACTION_VIDEO_CALL, $r('sys.symbol.video'),
          $r('app.string.global_video'), (): void => {
            this.startCall(false);
          })
      }
      // conditionalVariants[can_edit].
      if (this.canEdit) {
        this.profileActionButton(ACTION_EDIT_PROFILE, $r('sys.symbol.square_and_pencil'),
          $r('app.string.global_edit'), (): void => {
            this.openProfileEditor();
          })
      }
      // conditionalVariants[can_add].
      if (this.canAdd) {
        this.profileActionButton(ACTION_ADD_PARTICIPANT, $r('sys.symbol.person_badge_plus'),
          $r('app.string.swarm_invite'), (): void => {
            this.inviteParticipants();
          })
      }
    }
    .justifyContent(FlexAlign.Center)
    // Swift `profileActionButtons.padding(.top, Layout.generalMargin)` in infoStack on top of
    // the row's own `.padding(.top, Layout.callButtonsMargin)`.
    .margin({ top: GENERAL_MARGIN + CALL_BUTTONS_MARGIN })
    // One component binds one sheet. An attribute cannot be chained onto a @Builder call, so
    // the invite sheet mounts on the row that carries the Invite button.
    // S5: Swift `.sheet(isPresented: $isInvitingParticipants)` presents at the full detent on
    // iPhone, so the invite sheet takes SheetSize.LARGE rather than ArkUI's MEDIUM default.
    .bindSheet($$this.showInviteParticipants, this.inviteParticipantsSheet(),
      { detents: [SheetSize.LARGE], showClose: false })
  }

  /** Swift `infoStack` — title, description, then the profile actions. */
  @Builder
  private infoStack() {
    Column() {
      // Swift `titleLabel` — `.font(.title3.weight(.semibold))`, in `headerForeground`.
      Column() {
        Text(this.titleTail.length > 0 ? this.titleHead : this.title)
          .maxLines(this.titleTail.length > 0 ? 1 : 2)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Title_S'))
          .fontWeight(TITLE_WEIGHT)
          .fontColor(this.isAvatarExpanded ? Color.White : $r('app.color.label'))
        if (this.titleTail.length > 0) {
          Text(this.titleTail)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
            .fontSize($r('sys.float.Title_S'))
            .fontWeight(TITLE_WEIGHT)
            .fontColor(this.isAvatarExpanded ? Color.White : $r('app.color.label'))
        }
      }
      .width('100%')
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.titleWidth = Number(newArea.width);
      })
      // Swift `descriptionView` — rendered only when the trimmed description is non-empty.
      if (this.description.trim().length > 0) {
        Text(this.description.trim())
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .margin({ top: TITLE_DESCRIPTION_SPACING, bottom: VERTICAL_MARGIN })
          .fontSize($r('sys.float.Body_L'))
          .fontColor(this.isAvatarExpanded ? Color.White : $r('app.color.label'))
      }
      // Swift `if !profileActions.isEmpty { profileActionButtons }`.
      if (this.canCall || this.canEdit || this.canAdd) {
        this.profileActionButtons()
      }
    }
    .width('100%')
    // Swift `infoStack.padding(.horizontal, Layout.generalMargin)`.
    .padding({
      start: LengthMetrics.vp(GENERAL_MARGIN),
      end: LengthMetrics.vp(GENERAL_MARGIN)
    })
  }

  /** Swift `scrimmedInfo` — the same info stack, over the expanded avatar. */
  @Builder
  private scrimmedInfo() {
    Column() {
      this.infoStack()
    }
    .width('100%')
    .padding(GENERAL_MARGIN)
    // Swift `.padding(.top, 60).background(infoBackdrop)` — a four-stop vertical gradient
    // from clear to `jamiOnVideoScrim` at 0.9, so the white title stays legible over whatever
    // the picture happens to be. 180 degrees is ArkUI's top-to-bottom.
    .padding({ top: LengthMetrics.vp(SCRIM_TOP_PADDING) })
    .linearGradient({
      angle: 180,
      colors: [[SCRIM_CLEAR, 0.0], [SCRIM_SOFT, 0.3], [SCRIM_MID, 0.62], [SCRIM_STRONG, 1.0]]
    })
    // The gradient is decoration; the avatar underneath keeps its own tap.
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** Swift `avatarView` — expandable when the provider has a picture to expand. */
  @Builder
  private avatarView() {
    // The capture records a tap on the avatar as its own action (slug `person_2_fill` from the
    // source Image's `person.2.fill` identifier, S0105). ExpandableAvatar already carries
    // `swarm_info_avatar_toggle` on its own root, and the non-expandable branch carries no id
    // at all — so the slug goes on a content-sized wrapper that is present in BOTH branches
    // rather than on either instance, where it would override the child's own id.
    Stack() {
      // conditionalVariants[avatar_expandable]: Swift `provider.canExpand`.
      if (this.isAvatarExpandable) {
        ExpandableAvatar({
          avatarData: this.avatar,
          displayText: this.title,
          isExpanded: this.isAvatarExpanded,
          isGroup: this.isGroup,
          collapsedSide: AvatarSize.CONVERSATION_INFO_120,
          groupAvatar: this.groupAvatar,
          onToggle: (): void => {
            this.toggleAvatarExpanded();
          },
          bottomOverlay: (): void => {
            this.scrimmedInfo()
          }
        })
      } else {
        AvatarSwiftUIView({
          avatarData: this.avatar,
          displayText: this.title,
          isGroup: this.isGroup,
          avatarSize: AvatarSize.CONVERSATION_INFO_120,
          groupAvatar: this.groupAvatar
        })
      }
    }
    .id('person_2_fill')
  }

  /** Swift `fullTopArea`. */
  @Builder
  private topArea() {
    Column({ space: AVATAR_BOTTOM_GAP }) {
      this.avatarView()
      // Swift `if !isAvatarExpanded { infoStack }` — expanded, the info moves into the scrim.
      if (!this.isAvatarExpanded) {
        this.infoStack()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.padding(.top, isAvatarExpanded ? 0 : collapsedTopInset)` /
    // `.padding(.bottom, isAvatarExpanded ? 0 : Layout.verticalMargin)`.
    .padding({
      top: LengthMetrics.vp(this.isAvatarExpanded ? 0 : AVATAR_TOP_GAP),
      bottom: LengthMetrics.vp(this.isAvatarExpanded ? 0 : VERTICAL_MARGIN)
    })
  }

  /** Swift `Text(view == .memberList ? "\(viewModel.members.count) \(view.title)" : view.title)`. */
  private sectionTitle(section: string): string {
    const manager = getContext(this).resourceManager;
    if (section === SECTION_MEMBERS) {
      return `${this.memberCount} ${manager.getStringByNameSync('swarm_members')}`;
    }
    return manager.getStringByNameSync(section === SECTION_DOCUMENTS ? 'collab_documents' : 'swarm_settings');
  }

  /**
   * Swift `segmentedControlSection` — `Picker` over `swarmViews`, rendered only when there is
   * more than one section. The segments are the bound `swarm sections list`, so they come
   * from the conversation and are never a hardcoded three.
   */
  @Builder
  private segmentedControl() {
    Row() {
      ForEach(this.sectionList, (section: string) => {
        // No per-segment slug or handler: the SOURCE gives the Picker ONE identifier and
        // its segments none, so the whole control is one tappable node (Rule 12) and the
        // tapped segment is resolved from the x position below, exactly as a segmented
        // picker does. `.pickerStyle(.segmented)`: a grey track with a white pill under the
        // selected segment, equal-width segments.
        Text(this.sectionTitle(section))
          .layoutWeight(1)
          .height(SEGMENT_HEIGHT)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(section === this.selectedView ? TITLE_WEIGHT : REGULAR_WEIGHT)
          .fontColor($r('app.color.label'))
          .backgroundColor(section === this.selectedView
            ? $r('sys.color.comp_background_list_card') : Color.Transparent)
          .borderRadius(SEGMENT_PILL_RADIUS)
      }, (section: string) => `${section}_${this.memberCount}`)
    }
    // Full width less Swift's horizontal padding; a width('100%') plus a margin overflows.
    .width(`calc(100% - ${GENERAL_MARGIN * 2}vp)`)
    .height(SEGMENT_HEIGHT + SEGMENT_TRACK_INSET + SEGMENT_TRACK_INSET)
    // iOS segmented track = tertiarySystemFill (rgba(118,118,128,0.12)), (227,227,232) on the
    // grouped page; comp_background_gray equals the page grey here, so the track vanished.
    // ponytail: one alpha for both themes (iOS dark uses 0.24); add a dark resource if it reads faint.
    .backgroundColor(SEGMENT_TRACK_FILL)
    .borderRadius(SEGMENT_TRACK_RADIUS)
    .padding(SEGMENT_TRACK_INSET)
    .margin({ bottom: LengthMetrics.vp(SECTION_SPACING) })
    // Swift `.accessibilityIdentifier("swarm_info_segmented_control")` — on the Picker, not
    // on a segment.
    .id('swarm_info_segmented_control')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const measured: Length = newArea.width;
      if (typeof measured === 'number') {
        this.segmentedWidth = measured;
      }
    })
    .onClick((event: ClickEvent) => {
      this.onSegmentedControlTap(event.x);
    })
  }

  /**
   * The Picker's own segment hit test: the segments are equal-weight cells, so the tapped one
   * is the x position scaled by their count. A tap before the control has been measured falls
   * to the last section — the Documents view the plan's `Segmented control` edge records.
   */
  private onSegmentedControlTap(x: number): void {
    const sections: string[] = this.sectionList;
    if (sections.length === 0) {
      return;
    }
    let index: number = sections.length - 1;
    if (this.segmentedWidth > 0) {
      index = Math.floor((x / this.segmentedWidth) * sections.length);
      if (index < 0) {
        index = 0;
      }
      if (index > sections.length - 1) {
        index = sections.length - 1;
      }
    }
    this.selectSection(sections[index]);
  }

  /**
   * Swift `SettingsView.createAlert(for:)` — a SYSTEM `Alert`, which the iPhone (4.20) centres
   * with Cancel left and the destructive action right. Same call ContactInfoPage makes (T-1559).
   */
  private confirm(title: ResourceStr, message: ResourceStr, action: ResourceStr,
    onConfirm: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: action,
        fontColor: $r('sys.color.warning'),
        action: onConfirm
      }
    });
  }

  build() {
    // Swift `ZStack(alignment: .bottomTrailing) { background ; mainContent ; ... }`.
    Stack() {
      Column() {
        // An @Entry router page draws no system chrome, so the pushed page's back item —
        // controlInventory's `implicit: true / affordance: back` entry — is composed here.
        Row({ space: BACK_GLYPH_GAP }) {
          // A UIKit back item is chevron + label in the accent the source sets on this
          // hierarchy (`Color.jami`), 17 pt. The capture puts it at [0,53]-[68,97].
          BackChevron()
          Text($r('app.string.actions_back_action'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: NAV_BAR_HEIGHT })
        .padding({
          start: LengthMetrics.vp(VERTICAL_MARGIN),
          end: LengthMetrics.vp(VERTICAL_MARGIN)
        })
        .id('back')
        .onClick(() => {
          router.back();
        })

        // Swift kept the whole screen in ONE List, so the header scrolled with the section.
        // The Members and Documents sections are themselves scrolling Lists, and a List nested
        // in a Scroll gets no height and collapses, so the header is a fixed band here and the
        // selected section owns the scroll. Same controls, same order.
        this.topArea()
        // Swift `if swarmViews.count > 1`.
        if (this.sectionList.length > 1) {
          this.segmentedControl()
        }

        Column() {
          // conditionalVariants[about_tab].
          if (this.isAboutTab) {
            Scroll() {
              Column() {
                // SettingsViewSection hands the id and the remove title to @Builder rows BY
                // VALUE, which never refresh; keying the section on them rebuilds it once the
                // conversation resolves, so the row shows the real values and not the first ''.
                ForEach([`${this.conversationId}|${this.removeConversationLabel}`], (key: string) => {
                  SettingsViewSection({
                    contactJamiId: this.contactJamiId,
                    isOneToOne: this.isOneToOne,
                    conversationId: this.conversationId,
                    conversationTypeLabel: this.conversationTypeLabel,
                    finalColor: this.finalColor,
                    selectedColor: $selectedColor,
                    shareInfo: this.shareInfo,
                    removeConversationLabel: this.removeConversationLabel,
                    isLeave: this.isLeave,
                    isColorPickerOpen: $isColorPickerOpen,
                    showQRcode: $showQRcode,
                    onRemoveContact: (): void => {
                      this.confirm($r('app.string.swarm_remove_contact'),
                        $r('app.string.alerts_confim_remove_contact'), $r('app.string.global_remove'),
                        (): void => {
                          this.removeContact();
                        });
                    },
                    onBlockContact: (): void => {
                      this.confirm($r('app.string.global_block_contact'),
                        $r('app.string.alerts_confirm_block_contact'), $r('app.string.global_block'),
                        (): void => {
                          this.blockContact();
                        });
                    },
                    onRemoveConversation: (): void => {
                      this.confirm(this.removeConversationLabel, this.removeConversationMessage,
                        this.isLeave ? $r('app.string.global_leave') : $r('app.string.global_remove'),
                        (): void => {
                          this.removeConversation();
                        });
                    }
                  })
                }, (key: string) => key)
              }
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
            // A short section starts under the segmented control, as the iOS List does,
            // instead of floating in the middle of the Scroll.
            .align(Alignment.Top)
          }
          // conditionalVariants[members_tab].
          if (this.isMembersTab) {
            MemberList({
              members: this.memberRows,
              accountId: this.conversation === null ? '' : this.conversation.accountId,
              localJamiId: this.localJamiId,
              isAdmin: this.isAdmin,
              onDeleteMember: (jamiId: string): void => {
                this.removeMember(jamiId);
              }
            })
              .width('100%')
              .layoutWeight(1)
          }
          // conditionalVariants[documents_tab]: CollabDocumentsView, empty state and all.
          if (this.isDocumentsTab) {
            Column() {
              this.collabDocumentsSheet()
            }
            .width('100%')
            .layoutWeight(1)
          }

          /*
           * S6 — the disclosed gap and the failure slot. Both are grouped rows under the
           * section, never a panel that replaces it: the header, the segmented control and
           * the section the capture shows all stay on screen behind them.
           */
          if (this.showDaemonNotice) {
            Text($r('app.string.daemon_not_available'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.secondary_label'))
              .padding(GENERAL_MARGIN)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .id('swarm_info_daemon_notice')
          }
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.warning'))
              .padding(GENERAL_MARGIN)
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // Swift `ZStack { Color(UIColor.systemGroupedBackground) ; mainContent ; ... }`.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_swarm_info')
  }
}
