/*
 * THE SOURCE IS ONE SCREEN. `SwarmCreationViewController` (Cancel / "Select contacts" / Create
 * bar + the navigation item's search controller) sets
 * `view = UIHostingController(SwarmCreationUI(list: model))`, so the SwiftUI body IS that
 * controller's view — one scene, confirmed by the capture: SwarmCreationViewController's and
 * SwarmCreationUI's trees are identical and BOTH carry the bar, the search field, the
 * "Customize group" row and the contact list.
 *
 * The migration had filed it as two separately-routed pages, so each route rendered half of it
 * (the host drew the bar + search, this page drew Customize + list). This file now holds the
 * WHOLE screen once, as the exported `CreateSwarmparticipants`, and BOTH routes
 * (pages/CreateSwarmHostPage = screen_swarm_creation, pages/CreateSwarmParticipantsPage =
 * screen_swarm_creation_ui) mount it — so either entry point shows the entire source screen and
 * every slug appears exactly once per page.
 *
 * screen_swarm_creation_ui / screen_swarm_creation, ported from
 *   Ring/Ring/SwarmCreation/SwarmCreationViewController.swift  (the bar, the search controller)
 *   Ring/Ring/SwarmCreation/SwarmCreationViewController.storyboard (an empty root view)
 *   Ring/Ring/SwarmCreation/SwarmCreationUI.swift      (the SwiftUI body)
 *   Ring/Ring/SwarmCreation/SwarmCreationUIModel.swift (its model, incl. the search filter)
 *   Ring/Ring/UI/CustomSearchController.swift          (comp_custom_search_controller)
 *
 * S3 — the REAL tree, source order (and the capture's, [0,53] bar -> [16,98] field ->
 * [0,149] customize row -> [0,195] collection view):
 *
 *   navigationItem.leftBarButtonItem  = "Cancel"  id `swarm_creation_cancel`  -> popViewController
 *   navigationItem.title              = L10n.Swarm.selectContacts
 *   navigationItem.rightBarButtonItem = "Create"  id `swarm_creation_create`  -> createTheSwarm()
 *   navigationItem.searchController   = CustomSearchController, id `search_for_contact`,
 *                                       `updateSearchResults(for:)` -> strSearchText.accept()
 *                                       -> SwarmCreationUIModel filters participantsRows.
 *                                       Drawn inline (searchField) with UISearchBar's chrome:
 *                                       clear control only while there is text, Cancel and a
 *                                       hidden bar while the controller is active.
 *   VStack(alignment: .center, spacing: 0) {
 *     swarmProfileButton().sheet(isPresented: $isPresentingProfile) { SwarmProfile }
 *     if !list.selections.isEmpty { Spacer(15); ScrollView(.horizontal) { HStack(spacing: 15) {
 *       ForEach(list.selections) { SelectedParticipantItem { remove } } } } }
 *     List { ForEach(list.participantsRows) { ParticipantListCell { toggle } } }
 *   }
 *
 * SEARCH DOES NOT NAVIGATE. `updateSearchResults` only relays the text; the model filters in
 * place (SwarmCreationUIModel.swift:46-54) and `hidesSearchBarWhenScrolling = false`. The
 * capture agrees: `{"type":"type","slug":"search_for_contact"}` stays on the same page
 * (S0010 -> S0012, S0016 -> S0018). The plan's `screen_swarm_creation -> screen_swarm_creation_ui`
 * push edge is an artefact of the split and is now unwireable — REPORTED, not faked with a
 * navigation the source does not perform.
 *
 * conditionalVariants, each an ArkUI `if` on the field the plan names:
 *   has_selection -> hasSelection      empty_contacts -> isEmptyContacts
 *
 * bindingContract: the contact list and the chip row come from svc_contacts through
 * LazyForEach over ArrayDataSource, the swarm avatar/name from the profile draft, the title
 * from its string resource — never a literal. The capture shows the list EMPTY because a fresh
 * account has no contacts: creating a Jami account is daemon-gated, so svc_contacts has nothing
 * to hand back. Nothing is faked to fill it.
 *
 * PLAN vs SOURCE (reported): the plan lists `comp_edit_image_icon` under this screen. The SOURCE
 * uses `EditImageIcon` only in `SwarmProfile.swift`'s `imagePickerButton()`, i.e. in
 * screen_swarm_profile — this body's own profile button draws a 20pt picture (or a person glyph
 * in a jami-stroked circle) and a separate trailing pencil. The source wins, so it is not
 * instantiated here.
 *
 * OVERLAY HOST: screen_swarm_profile (sheet) mounts on the control that flips
 * `isPresentingProfile`, exactly as Swift raises it.
 *
 * DAEMON GAP: minting the swarm (`startConversation`) and adding its members are jami-daemon
 * work, and the daemon is a Rule-11 `gap`. Create runs, states the gap and does NOT push a
 * conversation that was never created.
 *
 * S5 style — read off the source's own calls, cross-checked against the capture (393x852):
 *   configureNavigationBar(): `navigationBar.tintColor = UIColor.jami` -> both bar buttons are
 *     app.color.jami, NOT the system accent.
 *   viewWillAppear: titleTextAttributes systemFont(ofSize: 18, weight: .medium) + UIColor.label.
 *   `navigationBar.layer.shadowColor = .clear` -> no separator under the bar.
 *   SwarmCreationUI.swift hardcodes 15 / 10 / 12 / 12 / 20 / 10 / 18 / 5, copied verbatim, and
 *   its own colours: `Color.jamiTertiaryControl` behind the customize row (#D5E4EF),
 *   `Color.jami` on its two glyphs, `Color(UIColor.label)` on its title,
 *   `Color(UIColor.systemBackground)` on the page.
 *
 * The field shows this screen's own prompt, `swarmcreation_search_bar` ("Search for contact…").
 */
import { LengthMetrics, promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { describeError } from '../common/ErrorText';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ConversationsService } from '../common/ConversationsService';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { Profile } from '../model/Profile';
import { RequestModel } from '../model/RequestModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { ConversationAttributes } from '../model/ConversationModel';
import { ParticipantListCell } from '../components/ParticipantListCell';
import { SelectedParticipantItem } from '../components/SelectedParticipantItem';
import { SwarmProfileSheet } from './SwarmProfileNameDescriptionPicturePage';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CreateSwarmParticipantsPage';

/**
 * The page -> body "the page is up" signal. Empty = not shown yet; this value = shown with no
 * overlay asked for; anything else = the overlay screen id a deep link named. ONE prop, so the
 * body's watcher cannot run before the overlay id reached it.
 */
export const SWARM_ACTIVATION_SHOWN: string = 'shown';
/** The overlay this screen hosts (screen_swarm_profile, presentation: sheet). */
const SWARM_PROFILE_OVERLAY: string = 'screen_swarm_profile';

/** EntryAbility.routeToTarget pushes a page with the overlay a deep link asked for. */
interface SwarmParticipantsRouteParams {
  overlayScreen?: string;
}

/** `UIFont.systemFont(ofSize: 18, weight: .medium)` — the nav title the controller installs. */
const NAV_TITLE_SIZE: number = 18;
/** The nav bar's own side inset, the platform's 16 pt. */
const NAV_H_PADDING: number = 16;
/** The capture's bar row: `[0,53][393,97]` — 44 pt, the UIKit standard. */
const NAV_BAR_HEIGHT: number = 44;
/** UISearchBar: a 36 pt field, its 20 pt glyphs 8 pt in from each edge, text clearing them. */
const SEARCH_FIELD_HEIGHT: number = 36;
const SEARCH_GLYPH_SIZE: number = 20;
const SEARCH_GLYPH_INSET: number = 8;
const SEARCH_PLACEHOLDER_GAP: number = 4;
const SEARCH_TEXT_INSET: number = SEARCH_GLYPH_INSET + SEARCH_GLYPH_SIZE + SEARCH_PLACEHOLDER_GAP;
/** The field's gap to the bar above it, and UISearchBar's gap before its Cancel button. */
const SEARCH_TOP_GAP: number = 7;
const SEARCH_CANCEL_GAP: number = 11;

/** How long Create waits for the new swarm's ConversationReady before pushing anyway. */
const CONVERSATION_READY_TIMEOUT_MS: number = 5000;

/** Swift `Spacer().frame(height: 15)` above the chip row, and `HStack(spacing: 15)`. */
const CHIP_ROW_GAP: number = 15;
/** Swift `.padding(.horizontal, 15).padding(.vertical, 10)` on the profile button. */
const PROFILE_BUTTON_H_PADDING: number = 15;
const PROFILE_BUTTON_V_PADDING: number = 10;
/** Swift `Spacer().frame(width: 12)` between the profile glyph and its title. */
const PROFILE_TITLE_GAP: number = 12;
/** Swift `.cornerRadius(12)` on the profile button. */
const PROFILE_BUTTON_RADIUS: number = 12;
/** Swift `.frame(width: 20, height: 20)` for the picked image, `10` for the person glyph. */
const PROFILE_IMAGE_SIZE: number = 20;
const PROFILE_GLYPH_SIZE: number = 10;
/** Swift `Image(systemName: "pencil").frame(width: 18, height: 18)`. */
const PROFILE_PENCIL_SIZE: number = 18;
/**
 * That pencil as an outline on a 24-unit grid: a diagonal body, rounded eraser end and ferrule,
 * and no baseline (every HarmonyOS pencil symbol draws one under the pencil).
 */
const PENCIL_GRID: number = 24;
const PENCIL_COMMANDS: string =
  'M3 21L4.2 16.3L16.5 4Q17.5 3 18.5 4L20 5.5Q21 6.5 20 7.5L7.7 19.8ZM14 6.5L17.5 10';
const PENCIL_STROKE: number = 1.5;
/** Swift `.padding(.vertical, 5)` around the contact List. */
const LIST_V_PADDING: number = 5;
/** A plain list's hairline. */
const SEPARATOR_WIDTH: number = 0.5;
const ROW_INSET: number = 16;
/**
 * UIKit starts a plain cell's separator under its text: the 16 pt inset, the 55 pt avatar,
 * HStack's default 8 pt spacing and the name's `.padding(.leading, 8)` (ParticipantListCell).
 * 87 pt on the iOS reference.
 */
const SEPARATOR_START: number = ROW_INSET + AvatarSize.DEFAULT_55 + 8 + 8;
/** Swift's person glyph is `.overlay(Circle().stroke(Color.jami, lineWidth: 1)).padding(4)`. */
const PROFILE_GLYPH_RING_WIDTH: number = 1;
const PROFILE_GLYPH_PADDING: number = 4;

/**
 * The WHOLE source screen — `SwarmCreationViewController` plus the `SwarmCreationUI` it hosts.
 * Mounted by both routes, so neither entry point renders half a screen.
 *
 * NAMED for the screen the plan declares it as: `screen_swarm_creation_ui` / "Create Swarm
 * (participants)", whose `hostedBy` is screen_swarm_creation. This component IS that child —
 * after the merge there is no second page body — and `containment_guard.py`'s
 * `unwired-declared-child` contract resolves the child by the identifier its plan NAME yields,
 * so the mount in CreateSwarmHostPage has to carry that identifier rather than a private one.
 */
@Component
export struct CreateSwarmparticipants {
  /**
   * The hosting page's "I am on screen" signal — see SWARM_ACTIVATION_SHOWN. The subscription
   * runs from here rather than from `aboutToAppear` because a cold deep link lands on the page
   * BEFORE its first frame, and svc_contacts replays its current value synchronously: two
   * ArrayDataSource reloads on the first frame delayed the page's `.id()` marker past the
   * drivers' settle window, leaving the previous page on screen.
   */
  @Prop @Watch('onActivationChange') activation: string = '';

  /** bindingContract[title] <- L10n.Swarm.selectContacts (a static string resource). */
  @State title: ResourceStr = $r('app.string.swarm_select_contacts');
  /** Swift `SwarmCreationViewController.strSearchText`, relayed to SwarmCreationUIModel. */
  @State searchText: string = '';
  /**
   * The search controller is presented (`hidesNavigationBarDuringPresentation = true`): the
   * bar gives way to the field and UISearchBar shows its Cancel button.
   */
  @State searchActive: boolean = false;
  /**
   * bindingContract `contact picker list + selected-participant chip row` <- svc_contacts.
   * The row set the two sub-lists below are drawn from, reloaded from the service — never a
   * literal array.
   */
  @State contactPickerListSelectedParticipantChipRow: ArrayDataSource<ContactModel> =
    new ArrayDataSource<ContactModel>([]);
  /** bindingContract `contact rows` <- svc_contacts (Swift `list.participantsRows`). */
  @State contactRows: ArrayDataSource<ContactModel> = new ArrayDataSource<ContactModel>([]);
  /** bindingContract `chips` <- selectedParticipants (Swift `list.selections`). */
  @State chips: ArrayDataSource<ContactModel> = new ArrayDataSource<ContactModel>([]);
  /** bindingContract `swarm avatar/name` <- swarmProfileDraft (SwarmCreationUIModel.image). */
  @State swarmAvatarName: string = '';
  /**
   * Swift `SwarmCreationUIModel.swarmName` / `.swarmDescription` — the other two fields of the
   * ONE shared draft `SwarmProfile` edits.
   */
  @State swarmNameDraft: string = '';
  @State swarmDescriptionDraft: string = '';

  /** conditionalVariants[has_selection]: Swift `!list.selections.isEmpty`. */
  @State hasSelection: boolean = false;
  /** conditionalVariants[empty_contacts]: Swift `list.participantsRows` is empty. */
  @State isEmptyContacts: boolean = true;

  /**
   * True while svc_conversations is minting the swarm. NOT raised for the contacts load: the
   * source shows no spinner there, and svc_contacts is daemon-gated so a load-time spinner would
   * never clear.
   */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The daemon gap Create hits, stated in place rather than only as a toast. */
  @State showDaemonNotice: boolean = false;

  /** Swift `@State private var isPresentingProfile` — raises the SwarmProfile sheet. */
  @State private showSwarmProfileSheet: boolean = false;
  /** Swift `list.selections` — the selected contacts' ids, in selection order. */
  @State private selections: string[] = [];
  /** Bumped when a listed contact's profile lands, so rows and chips re-read name and picture. */
  @State private profileTick: number = 0;
  /** Contact URIs whose profile this page already follows. */
  private followedProfiles: Set<string> = new Set<string>();

  /** Swift `list.filteredArray` — the unfiltered contact set the search filters. */
  private allContacts: ContactModel[] = [];
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** The subscription below runs once. */
  private loaded: boolean = false;
  /** Re-entry guard on Cancel — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /** The hosting page reported it is up: subscribe, then raise any deep-linked overlay. */
  private onActivationChange(): void {
    if (this.activation.length === 0 || this.loaded) {
      return;
    }
    this.loaded = true;
    // Swift `injectionBag.contactsService.contacts.subscribe { swarmInfo.addContacts(...) }`,
    // whose result lands back in `participantsRows`.
    this.bag.add(ServiceRegistry.shared().contactsService.contacts
      .subscribe((contacts: ContactModel[]): void => {
        this.applyContacts(contacts);
      }));
    if (this.activation === SWARM_PROFILE_OVERLAY) {
      // Same path the swarmProfileButton tap takes, so the sheet opens with the live drafts.
      this.openSwarmProfile();
    } else if (this.activation !== SWARM_ACTIVATION_SHOWN) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'deep link named an overlay this page does not host: %{public}s', this.activation);
    }
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription goes whatever happened above.
    this.bag.dispose();
  }

  /** Swift's contacts subscription body — rebuild the rows, then refresh what depends on them. */
  private applyContacts(contacts: ContactModel[]): void {
    // Swift lists the account's contacts; the account itself is never one of them (T-1741).
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    const ownId: string = account === null ? '' : account.jamiId;
    // Swift `SwarmInfo.addContacts`: "filter out banned and pending contacts".
    const requests: RequestModel[] = ServiceRegistry.shared().requestsService.requests.value;
    this.allContacts = contacts.filter((contact: ContactModel) => !contact.banned && contact.hash !== ownId &&
      !requests.some((request: RequestModel) => request.participants
        .some((participant: ConversationParticipant) => participant.jamiId === contact.hash)));
    this.followProfiles(this.allContacts);
    this.applySearchFilter();
    this.refreshSelection();
    this.isLoading = false;
  }

  /**
   * Swift `SwarmCreationUIModel.init`'s `strSearchText.subscribe`: a non-empty query filters
   * `filteredArray` by `item.match(string:)`, an empty one restores the whole set.
   */
  private applySearchFilter(): void {
    const query: string = this.searchText.trim().toLowerCase();
    const rows: ContactModel[] = query.length === 0
      ? this.allContacts
      : this.allContacts.filter((contact: ContactModel) =>
        this.contactName(contact).toLowerCase().includes(query) ||
        contact.hash.toLowerCase().includes(query));
    this.contactPickerListSelectedParticipantChipRow.reload(rows);
    this.contactRows.reload(rows);
    this.isEmptyContacts = rows.length === 0;
  }

  /** Swift `list.getParticipant(id:)`, applied to the whole selection. */
  private refreshSelection(): void {
    const selected: ContactModel[] = [];
    for (const id of this.selections) {
      const found: ContactModel | undefined =
        this.allContacts.find((contact: ContactModel) => contact.hash === id);
      if (found !== undefined) {
        selected.push(found);
      }
    }
    this.chips.reload(selected);
    this.hasSelection = selected.length > 0;
  }

  /**
   * Swift `SwarmInfo.createParticipant` follows each contact's profile. getProfile starts empty
   * and resolves 100 ms later, so rows read once kept the Jami ID (T-1741).
   */
  private followProfiles(contacts: ContactModel[]): void {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    for (const contact of contacts) {
      const uri: string | null = contact.uriString;
      if (uri === null || uri.length === 0 || this.followedProfiles.has(uri)) {
        continue;
      }
      this.followedProfiles.add(uri);
      this.bag.add(ServiceRegistry.shared().profileService.getProfile(uri, account.id)
        .subscribe((): void => {
          this.profileTick++;
        }));
    }
  }

  /**
   * The contact's PROFILE (svc_profiles owns it; ContactModel itself carries none), null when
   * there is no account. Reading profileTick re-renders the rows when a profile lands.
   */
  private profileFor(contact: ContactModel): Profile | null {
    const uri: string | null = contact.uriString;
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.currentAccount;
    if (this.profileTick < 0 || uri === null || uri.length === 0 || account === null) {
      return null;
    }
    return ServiceRegistry.shared().profileService.getProfile(uri, account.id).value;
  }

  /**
   * Swift `ParticipantRow(participantData:)` — a row's picture is the contact's PROFILE picture.
   * Empty is the honest answer on a fresh account: svc_profiles has nothing cached for that uri.
   */
  private avatarFor(contact: ContactModel): string {
    const profile: Profile | null = this.profileFor(contact);
    return profile === null || profile.photo === null ? '' : profile.photo;
  }

  /**
   * Swift `participant.name` = `ParticipantInfo.finalName` (`ContactsUtils.getFinalNameFrom`):
   * the profile name, else the registered name, else the hash.
   */
  private contactName(contact: ContactModel): string {
    const profile: Profile | null = this.profileFor(contact);
    const alias: string = profile === null || profile.alias === null ? '' : profile.alias.trim();
    if (alias.length > 0) {
      return alias;
    }
    const userName: string | null = contact.userName;
    return userName === null || userName.length === 0 ? contact.hash : userName;
  }

  /** Swift `updateSearchResults(for:)` -> `strSearchText.accept(searchText)` -> the filter. */
  private relaySearchText(value: string): void {
    this.searchText = value;
    this.applySearchFilter();
  }

  /** UISearchBar's clear control — empty the field and restore the unfiltered rows. */
  private clearSearchText(): void {
    this.searchText = '';
    this.applySearchFilter();
  }

  /** UISearchBar's Cancel — clear the query, end search mode, bring the bar back. */
  private cancelSearch(): void {
    this.clearSearchText();
    this.searchActive = false;
    this.getUIContext().getFocusController().clearFocus();
  }

  /** Swift: ParticipantListCell's action — append or remove the id in `list.selections`. */
  private toggleParticipant(contact: ContactModel): void {
    const index: number = this.selections.indexOf(contact.hash);
    const next: string[] = this.selections.slice();
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(contact.hash);
    }
    this.selections = next;
    this.refreshSelection();
  }

  /** Swift: SelectedParticipantItem's action — `selections.removeAll(where:)`. */
  private removeSelectedParticipant(contact: ContactModel): void {
    this.selections = this.selections.filter((id: string) => id !== contact.hash);
    this.refreshSelection();
  }

  /** Swift: `list.selections.contains(contact.id)`. */
  private isSelected(contact: ContactModel): boolean {
    return this.selections.indexOf(contact.hash) >= 0;
  }

  /** PENCIL_COMMANDS scaled from its grid to PROFILE_PENCIL_SIZE, in the px a Path draws in. */
  private pencilCommands(): string {
    const scale: number = this.getUIContext().vp2px(PROFILE_PENCIL_SIZE) / PENCIL_GRID;
    return PENCIL_COMMANDS.replace(/\d+(\.\d+)?/g, (n: string): string => `${Number(n) * scale}`);
  }

  /** Swift: swarmProfileButton's action — `isPresentingProfile = true` (edge: present). */
  private openSwarmProfile(): void {
    this.showSwarmProfileSheet = true;
  }

  /** screen_swarm_profile — presentation: sheet, hostScreen: this screen. */
  @Builder
  swarmProfileSheet() {
    SwarmProfileSheet({
      isPresented: $showSwarmProfileSheet,
      name: $swarmNameDraft,
      description: $swarmDescriptionDraft,
      avatar: $swarmAvatarName
    })
  }

  /**
   * Swift `SwarmCreationUIModel.createTheSwarm()`, in its own order: mint the conversation,
   * write the profile info, add every selected member, then hand the new id to `swarmCreated`.
   */
  private createTheSwarm(): void {
    if (this.isLoading) {
      // A second tap while the first swarm is still on its way must not mint another one.
      return;
    }
    this.errorText = '';
    this.showDaemonNotice = false;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // Swift `SwarmCreationUIModel.accountId`, injected from the coordinator's current account.
    const account: AccountModel | null = registry.accountService.currentAccount;
    if (account === null) {
      // No account exists because creating one is daemon-gated; the ceiling, not silence. The
      // in-body slot carries it too — a toast is gone before anything can read it.
      this.showDaemonNotice = true;
      promptAction.showToast({ message: $r('app.string.daemon_not_available') });
      return;
    }
    const accountId: string = account.id;
    this.isLoading = true;
    try {
      const conversationId: string = registry.conversationsService.startConversation(accountId);
      if (conversationId.length === 0) {
        // Minting the swarm is the daemon's job. Swift went on to push the conversation; with
        // no conversation there is nothing to push, so the ceiling is stated instead.
        this.isLoading = false;
        this.showDaemonNotice = true;
        promptAction.showToast({ message: $r('app.string.daemon_not_available') });
        return;
      }
      // Swift `createTheSwarm()` writes all three fields of the profile draft the sheet edits.
      const info: Map<string, string> = new Map<string, string>();
      if (this.swarmAvatarName.length > 0) {
        info.set(ConversationAttributes.AVATAR, this.swarmAvatarName);
      }
      if (this.swarmNameDraft.length > 0) {
        info.set(ConversationAttributes.TITLE, this.swarmNameDraft);
      }
      if (this.swarmDescriptionDraft.length > 0) {
        info.set(ConversationAttributes.DESCRIPTION, this.swarmDescriptionDraft);
      }
      if (info.size > 0) {
        registry.conversationsService.updateConversationInfos(accountId, conversationId, info);
      }
      for (const participant of this.selections) {
        registry.conversationsService
          .addConversationMember(accountId, conversationId, participant);
      }
      this.openCreatedConversation(accountId, conversationId);
    } catch (error) {
      this.isLoading = false;
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'createTheSwarm failed: %{public}s', this.errorText);
    }
  }

  /**
   * Swift `swarmCreated(conversationId, accountId)` -> `showConversation(withConversationId:)`
   * (plan edge -> screen_conversation, kind: push).
   *
   * The daemon's ConversationReady for the new swarm reaches svc_conversations only after this
   * JS task, through the napi threadsafe function. Pushed before that, ConversationChatPage
   * cannot find the id and opens a temporary one-to-one with the swarm id as its peer. Swift
   * waits 0.1 s (`DispatchQueue.main.asyncAfter`); this waits for the swarm itself instead.
   */
  private openCreatedConversation(accountId: string, conversationId: string): void {
    const service: ConversationsService = ServiceRegistry.shared().conversationsService;
    let opened: boolean = false;
    let stop: () => void = (): void => {};
    let timer: number = -1;
    const open = (): void => {
      if (opened) {
        return;
      }
      opened = true;
      stop();
      clearTimeout(timer);
      this.isLoading = false;
      this.showConversation(accountId, conversationId);
    };
    stop = service.conversations.subscribe((): void => {
      if (service.getConversationForId(conversationId, accountId) !== null) {
        open();
      }
    });
    // The relay replays synchronously, so the swarm may already have been found above, before
    // `stop` held the real unsubscribe.
    if (opened) {
      stop();
      return;
    }
    // ConversationReady normally lands a task later. If it never does, open it anyway as Swift
    // does rather than leave Create spinning.
    timer = setTimeout(open, CONVERSATION_READY_TIMEOUT_MS);
    this.bag.add(stop);
    this.bag.add((): void => {
      clearTimeout(timer);
    });
  }

  /**
   * Swift `ConversationsCoordinator.openConversation(shouldOpenSmarList: false)` shows the
   * conversation and removes SwarmCreationViewController from the stack, so the creation screen
   * closes and Back does not return to it (where a second Create would mint another swarm).
   */
  private showConversation(accountId: string, conversationId: string): void {
    router.replaceUrl({
      url: 'pages/ConversationChatPage',
      params: { conversationKey: `${accountId}|${conversationId}` }
    }).catch((error: BusinessError): void => {
      // A navigation that never happened must say so rather than leaving the user on a screen
      // that looks like it did nothing.
      this.errorText = describeError(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl conversation failed: %{public}s', error.message);
    });
  }

  /**
   * Swift `@objc func backButtonTapped()` -> `navigationController.popViewController`. A cold
   * deep link can land here as the only entry on the stack, where `back()` would drop the app.
   */
  private cancel(): void {
    if (this.isNavigating) {
      return;
    }
    this.isNavigating = true;
    if (router.getLength() === '1') {
      router.replaceUrl({ url: 'pages/SmartListConversationsHomePage' }).catch((error: Error): void => {
        this.isNavigating = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl home failed: %{public}s', error.message);
      });
      return;
    }
    router.back();
    this.isNavigating = false;
  }

  /* ── builders ───────────────────────────────────────────────────────────────────── */

  /** Swift: the navigation item — Cancel | title | Create. */
  @Builder
  private navigationBar() {
    Row() {
      // `UIBarButtonItem(title: L10n.Global.cancel)`, accessibilityIdentifier
      // = "swarm_creation_cancel".
      Button($r('app.string.global_cancel'), { type: ButtonType.Normal })
        .id('swarm_creation_cancel')
        .backgroundColor(Color.Transparent)
        // `navigationBar.tintColor = UIColor.jami`.
        .fontColor($r('app.color.jami'))
        .fontSize($r('sys.float.Body_L'))
        .padding(0)
        .onClick(() => {
          this.cancel();
        })

      // bindingContract[title] — `navigationItem.title = L10n.Swarm.selectContacts`.
      Text(this.title)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .fontSize(NAV_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        // `NSAttributedString.Key.foregroundColor: UIColor.label`.
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // `UIBarButtonItem(title: L10n.Global.create)`, accessibilityIdentifier
      // = "swarm_creation_create"; `continueButton.rx.tap -> model.createTheSwarm()`.
      Button($r('app.string.global_create'), { type: ButtonType.Normal })
        .id('swarm_creation_create')
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.jami'))
        .fontSize($r('sys.float.Body_L'))
        .padding(0)
        .onClick(() => {
          this.createTheSwarm();
        })
    }
    .width('100%')
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('sys.color.background_primary'))
    .padding({ left: NAV_H_PADDING, right: NAV_H_PADDING })
  }

  /**
   * `navigationItem.searchController = CustomSearchController`, drawn inline with UISearchBar's
   * own chrome: the magnifier, the prompt while empty, the clear control only while the field
   * holds text (`clearButtonMode = .whileEditing`), and Cancel while the controller is active.
   */
  @Builder
  private searchField() {
    Row() {
      Stack() {
        TextInput({ text: $$this.searchText })
          .id('searchBarTextField')
          .width('100%')
          .height(SEARCH_FIELD_HEIGHT)
          .backgroundColor($r('sys.color.comp_background_gray'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .caretColor($r('app.color.jami'))
          // The clear control's box is reserved on the right too, so long text and the caret
          // stop short of the X instead of running under it (and never reflow as it appears).
          .padding({ left: SEARCH_TEXT_INSET, right: SEARCH_TEXT_INSET })
          .onChange((value: string) => {
            this.relaySearchText(value);
          })
          .onClick(() => {
            this.searchActive = true;
          })

        // Chrome over the field; taps it does not own fall through to the TextInput.
        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(SEARCH_GLYPH_SIZE)
            .fontColor([$r('app.color.secondary_label')])
          // Swift `searchBar.placeholder = L10n.Swarmcreation.searchBar`, a real Text so
          // `uitest dumpLayout` sees it (it never reports a TextInput's placeholder).
          if (this.searchText.length === 0) {
            Text($r('app.string.swarmcreation_search_bar'))
              .layoutWeight(1)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.secondary_label'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: SEARCH_PLACEHOLDER_GAP })
          } else {
            Blank()
            // Captured as `Button txt='Clear text'` with no identifier of its own; the slug is
            // its accessibility label (CLAUDE.md rule 12, iOS row).
            // UISearchBar's clear button is xmark.circle.fill in systemGray.
            SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
              .id('clear_text')
              .fontSize(SEARCH_GLYPH_SIZE)
              .fontColor([$r('sys.color.icon_secondary')])
              .accessibilityText('Clear text')
              .onClick(() => {
                this.clearSearchText();
              })
          }
        }
        .width('100%')
        .height(SEARCH_FIELD_HEIGHT)
        .padding({ left: SEARCH_GLYPH_INSET, right: SEARCH_GLYPH_INSET })
        .alignItems(VerticalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .layoutWeight(1)
      .height(SEARCH_FIELD_HEIGHT)
      // CLAUDE.md rule 12: the SOURCE slug for the field is `search_for_contact` — the capture
      // drives S0010 -> S0012 and S0016 -> S0018 with `{"type":"type","slug":"search_for_contact"}`.
      // The on-device gate asks whether the slug node or an ANCESTOR of the TextInput is
      // clickable, so the wrapper carries a handler too.
      .id('search_for_contact')
      .onClick(() => {
        this.searchActive = true;
      })

      // UISearchBar's Cancel, tinted like every bar button.
      if (this.searchActive) {
        Text($r('app.string.global_cancel'))
          .id('cancel')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
          .margin({ left: SEARCH_CANCEL_GAP })
          .onClick(() => {
            this.cancelSearch();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
    .margin({
      top: SEARCH_TOP_GAP,
      bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  /**
   * Swift `swarmProfileButton()` — the action contract's required `Customize profile` control.
   * The whole row is the source's Button, so its slug (`swarm_creation_customize_profile`) and
   * its handler sit on the row itself; the title it SHOWS is `L10n.Swarm.customize`
   * ("Customize group"), the source's own label.
   */
  @Builder
  private swarmProfileButton() {
    Row() {
      // Swift `if let image = list.image { Image(uiImage:) } else { person glyph }`.
      if (this.swarmAvatarName.length > 0) {
        Image(this.swarmAvatarName)
          .width(PROFILE_IMAGE_SIZE)
          .height(PROFILE_IMAGE_SIZE)
          .borderRadius(PROFILE_IMAGE_SIZE / 2)
          .clip(true)
          .objectFit(ImageFit.Cover)
      } else {
        // Swift: a 10 pt `person` glyph, padded 4, inside a 1 pt jami-stroked circle.
        // icon-map.json: person -> sys.symbol.person (exact).
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(PROFILE_GLYPH_SIZE)
          .fontColor([$r('app.color.jami')])
          .padding(PROFILE_GLYPH_PADDING)
          .borderWidth(PROFILE_GLYPH_RING_WIDTH)
          .borderColor($r('app.color.jami'))
          .borderRadius(PROFILE_GLYPH_SIZE / 2 + PROFILE_GLYPH_PADDING)
      }
      // Swift `.foregroundColor(Color(UIColor.label))` — the title is NOT tinted.
      Text($r('app.string.swarm_customize'))
        .margin({ start: LengthMetrics.vp(PROFILE_TITLE_GAP) })
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
      Blank()
      // Swift `Image(systemName: "pencil")` in Color.jami. Drawn as a Path: sys.symbol has no
      // plain pencil (pencil_line and pencil_line_1 add a baseline, pencil_tip is a nib).
      Path()
        .width(PROFILE_PENCIL_SIZE)
        .height(PROFILE_PENCIL_SIZE)
        .commands(this.pencilCommands())
        .fill(Color.Transparent)
        .stroke($r('app.color.jami'))
        .strokeWidth(PENCIL_STROKE)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeLineCap(LineCapStyle.Round)
    }
    // Swift `.frame(maxWidth: .infinity) ... .padding(.horizontal)`: full width less the 16 pt
    // default inset each side. A width('100%') plus a margin overflows, so the inset is in
    // the width itself.
    .width(`calc(100% - ${ROW_INSET * 2}vp)`)
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(PROFILE_BUTTON_H_PADDING),
      end: LengthMetrics.vp(PROFILE_BUTTON_H_PADDING),
      top: LengthMetrics.vp(PROFILE_BUTTON_V_PADDING),
      bottom: LengthMetrics.vp(PROFILE_BUTTON_V_PADDING)
    })
    // Swift `.background(Color.jamiTertiaryControl).cornerRadius(12)` — the app's own resource,
    // not a colour sampled off the capture.
    .backgroundColor($r('app.color.jami_tertiary_control'))
    .borderRadius(PROFILE_BUTTON_RADIUS)
    .id('swarm_creation_customize_profile')
    .onClick(() => {
      this.openSwarmProfile();
    })
    // The source sheet carries its own Save / Cancel, so the system close is suppressed.
    .bindSheet($$this.showSwarmProfileSheet, this.swarmProfileSheet(), { showClose: false })
  }

  /** Swift's horizontal `ScrollView` of SelectedParticipantItem chips. */
  @Builder
  private chipRow() {
    List() {
      LazyForEach(this.chips, (contact: ContactModel) => {
        ListItem() {
          SelectedParticipantItem({
            participantName: this.contactName(contact),
            avatarData: this.avatarFor(contact),
            onTap: (): void => {
              this.removeSelectedParticipant(contact);
            }
          })
        }
        .margin({
          start: LengthMetrics.vp(CHIP_ROW_GAP / 2),
          end: LengthMetrics.vp(CHIP_ROW_GAP / 2)
        })
      }, (contact: ContactModel) => contact.hash)
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(AvatarSize.CONVERSATION_INFO_80)
    .scrollBar(BarState.Off)
    .margin({ top: CHIP_ROW_GAP })
    .padding({
      start: LengthMetrics.vp(CHIP_ROW_GAP),
      end: LengthMetrics.vp(CHIP_ROW_GAP)
    })
  }

  /**
   * Swift's `List { ForEach(list.participantsRows) { ParticipantListCell } }` — each cell is the
   * action contract's required `Participant row`. Rule 12's list-row exception applies: every row
   * carries the ONE shared slug `swarm_creation_participant_itemroot` (on the cell itself, in
   * comp_participant_list_cell) and the replay resolves a row by index.
   */
  @Builder
  private contactList() {
    List() {
      LazyForEach(this.contactRows,
        (contact: ContactModel) => {
          ListItem() {
            ParticipantListCell({
              participantName: this.contactName(contact),
              avatarData: this.avatarFor(contact),
              isSelected: this.isSelected(contact),
              onTap: (): void => {
                this.toggleParticipant(contact);
              }
            })
          }
        }, (contact: ContactModel) => contact.hash)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({
      top: LengthMetrics.vp(LIST_V_PADDING),
      bottom: LengthMetrics.vp(LIST_V_PADDING)
    })
    // Swift `.listStyle(PlainListStyle())`: a plain list draws its rows edge to edge on the page
    // background with a hairline between them, inset to the text.
    .divider({
      strokeWidth: SEPARATOR_WIDTH,
      color: $r('sys.color.comp_divider'),
      startMargin: SEPARATOR_START
    })
    .scrollBar(BarState.Off)
  }

  build() {
    // Swift `VStack(alignment: .center, spacing: 0)`, under the controller's navigation item.
    Column() {
      // `hidesNavigationBarDuringPresentation = true`: the bar is gone while searching.
      if (!this.searchActive) {
        this.navigationBar()
      }
      this.searchField()
      this.swarmProfileButton()

      // conditionalVariants[has_selection]: Swift renders the chip strip only when something is
      // selected — there is no empty chip row in the source.
      if (this.hasSelection) {
        this.chipRow()
      }

      // conditionalVariants[empty_contacts]: the captured state. Swift has NO empty view here —
      // the same List simply has no rows — so nothing is invented to fill it.
      if (this.isEmptyContacts) {
        Column()
          .width('100%')
          .layoutWeight(1)
      } else {
        this.contactList()
      }

      /*
       * S6 — the failure slot. It sits under the list rather than replacing it, so the customize
       * row and the picker the capture shows stay on screen behind it.
       */
      if (this.showDaemonNotice) {
        Text($r('app.string.daemon_not_available'))
          .width('100%')
          .id('swarm_creation_daemon_notice')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.warning'))
          .padding(PROFILE_BUTTON_H_PADDING)
      }
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.warning'))
          .padding(PROFILE_BUTTON_H_PADDING)
      }
      if (this.isLoading) {
        LoadingProgress()
          .width(NAV_TITLE_SIZE)
          .height(NAV_TITLE_SIZE)
          .margin({ top: $r('sys.float.margin_level2') })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.background(Color(UIColor.systemBackground))` — a PLAIN page, not the grouped grey
    // the swarm-info screen sits on.
    .backgroundColor($r('sys.color.background_primary'))
  }
}

/**
 * screen_swarm_creation_ui — the route `SwarmCreationUI` / `screen_swarm_profile` resolve to.
 *
 * PAGE IDENTITY = `screen_swarm_creation`, not this screen's own id: the on-device page-identity
 * ladder folds a state's screen to its outermost non-hosted host (screen_swarm_profile ->
 * hostScreen screen_swarm_creation_ui -> hostedBy screen_swarm_creation), so every state whose
 * path ends on this page expects `screen_swarm_creation` on screen. The host relation also
 * exempts this screen from the S2 page-marker check, so this is the only marker it needs.
 */
@Entry
@Component
struct CreateSwarmParticipantsPage {
  /** Empty until the page is up — see SWARM_ACTIVATION_SHOWN. */
  @State private activation: string = '';

  onPageShow(): void {
    if (this.activation.length > 0) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    const overlay: string = raw === undefined
      ? '' : ((raw as SwarmParticipantsRouteParams).overlayScreen ?? '');
    this.activation = overlay.length > 0 ? overlay : SWARM_ACTIVATION_SHOWN;
  }

  build() {
    Column() {
      CreateSwarmparticipants({ activation: this.activation })
    }
    .width('100%')
    .height('100%')
    .id('screen_swarm_creation')
  }
}
