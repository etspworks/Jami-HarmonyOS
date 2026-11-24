/*
 * screen_smart_list_search — "Smart List Search Results", ported from
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SmartListSearchResultsView.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 *     (`JamsSearchResultView`, `TempConversationsView`, `ConversationRowView`)
 *   Ring/Ring/Features/Conversations/views/JamiSearchView/JamiSearchViewModel.swift (SearchStatus)
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/ConversationsViewModel.swift
 *
 * presentation: page (router stack) — the smart list's in-place search mode.
 *
 * Swift `SmartListSearchResultsView.body` is ONE List of five rows, and that is the S3
 * structure built here, in the same order:
 *
 *   1. accountActions        — `sipActions` for a SIP account, `newChatOptions` otherwise
 *   2. directorySection      — only `if showsDirectorySection` (= !isSipAccount ||
 *                              !searchQuery.isEmpty): the directory title, then either its hint
 *                              (empty query) or `searchResultView`, then the blocked-contact row
 *   3. conversationsSearchHeaderView — "Conversations" + the empty/no-match hint
 *   4. conversationsView     — `if !model.filteredConversations.isEmpty`
 *   5. Color.clear(minHeight: 600) `search_results_dismiss_area` — tap-to-dismiss
 *
 * `searchResultView` is a switch over `model.searchStatus`, which is what the plan records as
 * the conditionalVariants `temp_result` / `jams_results` / `blocked_hit`; `directory_hidden`
 * is `showsDirectorySection`. All four are real ArkUI `if` branches below.
 *
 * Every row set is bound to svc_conversation_source through LazyForEach over an
 * ArrayDataSource (bindingContract) — never a literal array.
 *
 * Two notes against the plan, both resolved the way THE ONE INVARIANT says (the source wins):
 *  - controlInventory records the scanner button as `SmartListSearchResultsView`, but the
 *    source DOES give it a slug: `SmartListAccessibilityIdentifiers.newContactButton`
 *    (Ring/AccessibilityIdentifiers.swift:52). The capture recorded that slug, so that is the
 *    `.id()` — an invented one is addressable but still breaks replay (CLAUDE.md rule 12).
 *  - controlInventory lists 5 controls; `accountActions` declares 2 more (New group, and for a
 *    SIP account Dialpad + Contacts). They are built, with their own source slugs.
 *
 * S5 style, read off SmartListSearchResultsView.swift + SmartListRowModifiers.swift:
 *   .listStyle(.plain)                      -> a WHITE page, edge-to-edge rows (no grouped
 *                                              card chrome) -> sys.color.background_primary
 *   smartListRowStyle(): listRowInsets leading/trailing 15, listRowBackground .clear
 *       -> ROW_INSET on the section chrome ONLY. The nested ConversationRowView already
 *          carries its own 15 (components/ConversationRow.ets ROW_INSET), and the capture
 *          puts the temporary/jams row avatar at x=15, not 30 — so the row lists get none.
 *   actionItem: Image 18 pt .foregroundColor(.jami) + Text .font(.callout),
 *       HStack default spacing 8, .padding(.horizontal) 16 / .padding(.vertical, 10),
 *       .frame(maxWidth: .infinity), Color.jamiTertiaryControl, cornerRadius 12
 *       -> app.color.jami / Body_M / app.color.jami_tertiary_control / ACTION_CORNER_RADIUS
 *   section titles .fontWeight(.semibold), no .font()   -> Body_L + FontWeight.Medium
 *   sectionHint(_:) .font(.callout).foregroundColor(.secondary) -> Body_M + secondary_label
 * The search field is the UIKit search controller's, which is chrome the source never spells
 * out: the capture gives it a 36 pt gray rounded field inset 16 (mapping-tables.md §7).
 *
 * OVERLAY HOST. `Scan QR code` lives on THIS view in the source (`isShowingScanner = true` ->
 * ScanView sheet), so screen_scan_qr is mounted here even though the plan files its hostScreen
 * as screen_smart_list. The source's contact picker (`isShowingContactPicker`) is the system
 * address book (CNContactPickerViewController), so here it is `contact.selectContacts`.
 */
import { LengthMetrics, router } from '@kit.ArkUI';
import { contact } from '@kit.ContactsKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { describeError } from '../common/ErrorText';
import { JamiUri, UriType } from '../common/JamiUri';
import { ConversationDataSource, ConversationViewModel } from '../common/ConversationDataSource';
import {
  LookupNameResponse, LookupNameState, UserSearchResponse, UserSearchState
} from '../common/NameService';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';
import { ConversationRowView, ROW_INSET, ROW_SEPARATOR_INSET } from '../components/ConversationRow';
import { TempConversationsView } from '../components/TempConversationsView';
import { ScanQRCodeOverlay } from './ScanQRCodePage';
import { showSystemAlert } from '../components/CustomAlert';
import { DialpadOverlay } from './DialpadPage';

/** Swift `JamiSearchViewModel`: a jami id lookup needs more than two characters. */
const MIN_LOOKUP_LENGTH: number = 3;
/** Swift `SmartListSearchResultsView.Layout`. */
const ACTION_ROW_SPACING: number = 12;
const SECTION_V_PADDING: number = 15;
const ACTION_ICON_SIZE: number = 18;
/** SF `person.2` at 18 pt is about 1.5x as wide as tall: two 14 vp people, 4 vp overlapped. */
const PAIR_GLYPH_SIZE: number = 14;
const PAIR_GLYPH_OVERLAP: number = -4;
/** Swift `Layout.actionCornerRadius`. */
const ACTION_CORNER_RADIUS: number = 12;
/** Swift `.padding(.horizontal)` on the action item — SwiftUI's default 16. */
const ACTION_H_PADDING: number = 16;
/** Swift `.padding(.vertical, 10)` on the action item. */
const ACTION_V_PADDING: number = 10;
/**
 * The system search field the UISearchController draws: 36 pt tall, inset 16, gray, rounded
 * (results/traversal-source/pages/SmartListView/searchBarTextField.ui.json `[16,61][313,97]`).
 */
const SEARCH_FIELD_HEIGHT: number = 36;
const SEARCH_FIELD_RADIUS: number = 10;
/**
 * UISearchBar's own leading magnifying glass and trailing clear button — framework chrome the
 * app never spells out, recorded by both captures inside the field: the glyph at
 * `[22,69][42,88]` (20 pt, 6 pt in from the field's leading edge) and the clear button at
 * `[287,70][307,89]` (20 pt, 6 pt in from the trailing edge).
 */
const SEARCH_GLYPH_SIZE: number = 20;
const SEARCH_GLYPH_INSET: number = 6;
/** Text clears both glyph boxes: inset + glyph + gap. */
const SEARCH_PLACEHOLDER_GAP: number = 4;
const SEARCH_TEXT_INSET: number = SEARCH_GLYPH_INSET + SEARCH_GLYPH_SIZE + SEARCH_PLACEHOLDER_GAP;
/** Swift `searchBarCancelButtonClicked` — the Cancel button beside the field (`[324,63][377,93]`). */
const SEARCH_CANCEL_GAP: number = 11;
/**
 * The search bar's vertical margin. `sys.float.margin_level2` is 24 vp, which put 39 vp between
 * the field and the action buttons; the iOS capture has 23 (8 + the actions' own 15 top pad).
 */
const SEARCH_BAR_V_MARGIN: number = 8;
/** Swift `Color.clear.frame(minHeight: 600)` — the tap-to-dismiss area under the results. */
const DISMISS_AREA_MIN_HEIGHT: number = 600;
/**
 * A row's own height (ConversationRowView: a 55 pt avatar with `.padding(.vertical, 8)`). The
 * result Lists are nested inside the page's scroll, so they cannot claim a weight — their box
 * is the row count times this, which is what SwiftUI's single List gave for free.
 */
const JAMS_ROW_HEIGHT: number = 71;

/** Swift `enum SearchStatus` (JamiSearchViewModel.swift:28). */
enum SearchStatus {
  NOT_SEARCHING = 'NOT_SEARCHING',
  FOUND_TEMPORARY = 'FOUND_TEMPORARY',
  FOUND_JAMS = 'FOUND_JAMS',
  SEARCHING = 'SEARCHING',
  NO_RESULT = 'NO_RESULT',
  INVALID_ID = 'INVALID_ID'
}

@Entry
@Component
struct SmartListSearchResultsPage {
  // ---------------------------------------------------------------- conditional variants
  /** conditionalVariants[jams_results] — Swift `searchStatus == .foundJams`. */
  @State isJamsResults: boolean = false;
  /** conditionalVariants[temp_result] — Swift `searchStatus == .foundTemporary`. */
  @State isTempResult: boolean = false;
  /** conditionalVariants[blocked_hit] — Swift `model.blockedConversation != nil`. */
  @State isBlockedHit: boolean = false;
  /** conditionalVariants[directory_hidden] — Swift `isSipAccount && searchQuery.isEmpty`. */
  @State isDirectoryHidden: boolean = false;

  /** Swift `model.isSipAccount()` — picks `sipActions` over `newChatOptions`. */
  @State isSipAccount: boolean = false;
  /** Swift `model.searchStatus` — drives `searchResultView`'s switch. */
  @State searchStatus: SearchStatus = SearchStatus.NOT_SEARCHING;

  /** True while svc_name / svc_conversation_source are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  // ---------------------------------------------------------------- bound content
  /** AppStorage['currentAccountId'], written by svc_accounts on an account switch. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /**
   * bindingContract[search result list] <- svc_conversation_source. Swift
   * `model.filteredConversations`: the data source's rows narrowed by the query. Starts EMPTY
   * and is filled by the service; `conversationsSource` mirrors it for LazyForEach.
   */
  @State searchResultListConversationsDirectorySections: ConversationViewModel[] = [];
  /** bindingContract[result rows] <- `model.jamsSearchResult`. */
  @State resultRows: ConversationViewModel[] = [];

  /** Swift `model.searchQuery`. */
  @State searchText: string = '';
  /** Swift `model.temporaryConversation` — a raw jami id typed into the field. */
  @State temporaryConversation: ConversationViewModel | null = null;
  /**
   * Swift `model.blockedConversation`. Held as a non-null row plus `isBlockedHit`, because a
   * `| null` @State cannot be narrowed inside a @Builder and ConversationRowView's `model` is
   * not nullable.
   */
  @State blockedRow: ConversationViewModel = new ConversationViewModel();
  /** Swift `model.publicDirectoryTitle` / `publicDirectoryHint` (JAMS vs the public server). */
  @State isJamsAccount: boolean = false;

  /** The temporary row's own bound values — the directory result carries the display name. */
  @State rowTitle: string = '';
  @State rowSubtitle: string = '';
  @State rowAvatar: string = '';

  /** Mirrors `resultRows.length`: an ArrayDataSource is not observable state. */
  @State jamsCount: number = 0;
  /** Mirrors `searchResultListConversationsDirectorySections.length`. */
  @State conversationCount: number = 0;

  /**
   * svc_conversation_source — the smart list's own source, so these are its rows with its
   * blocked flags (T-1603). A search opened with no smart list (a deep link) runs its own.
   */
  private ownsSource: boolean = ConversationDataSource.smartList === null;
  private source: ConversationDataSource = ConversationDataSource.smartList ?? new ConversationDataSource();
  /** Swift `model.filteredConversations`, wrapped for LazyForEach. Reloaded, never replaced. */
  private conversationsSource: ArrayDataSource<ConversationViewModel> =
    new ArrayDataSource<ConversationViewModel>([]);
  /** Swift `model.jamsSearchResult`, wrapped for LazyForEach. */
  private jamsSource: ArrayDataSource<ConversationViewModel> =
    new ArrayDataSource<ConversationViewModel>([]);
  private bag: DisposeBag = new DisposeBag();

  /** screen_scan_qr — Swift `@SwiftUI.State private var isShowingScanner`. */
  @State private showScanner: boolean = false;

  private scanner: CustomDialogController = new CustomDialogController({
    builder: ScanQRCodeOverlay({ isPresented: $showScanner }),
    autoCancel: true,
    customStyle: true
  });

  /**
   * screen_dialpad — presentation: modal. Swift `stateEmitter.showDialpad` presents the dialpad
   * over the current screen; DialpadPage exports the overlay (DialpadOverlay) and registers no
   * page, so this is hosted exactly as screen_smart_list hosts it — a router push at
   * 'pages/DialpadPage' would be dead navigation.
   */
  @State private showDialpad: boolean = false;

  private dialpad: CustomDialogController = new CustomDialogController({
    builder: DialpadOverlay({ isPresented: $showDialpad }),
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // svc_conversation_source — Swift's ConversationDataSource, started by the coordinator that
    // owns the search flow. Its rows are what `filteredConversations` narrows. Idempotent.
    this.source.start();
    this.applyAccount(registry.accountService.currentAccount);
    // Swift `observeSearchModelUpdates()` — JamiSearchViewModel.performLookup's two streams.
    this.bag.add(registry.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        this.applyLookupResult(response);
      }));
    this.bag.add(registry.nameService.userSearchResponseShared.subscribe(
      (response: UserSearchResponse): void => {
        this.applyJamsResult(response);
      }));
    this.bag.add(registry.accountService.currentAccountChanged.subscribe(
      (account: AccountModel | null): void => {
        this.applyAccount(account);
      }));
    // Swift `setupFilteredConversations` re-ran on every data-source change, not once.
    this.bag.add(registry.conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        this.applyConversations();
      }));
    // Block and unblock re-emit the contacts relay; the source (subscribed first, in start())
    // has already moved the 1:1 in or out of its rows, so the results follow live (T-1603).
    // The temporary row is this page's own: its Blocked label follows the peer here.
    this.bag.add(registry.contactsService.contacts.subscribe(
      (contacts: ContactModel[]): void => {
        this.temporaryConversation?.updateBlockedStatus();
        this.applyConversations();
      }));
    this.applyConversations();
  }

  aboutToDisappear(): void {
    try {
      this.bag.dispose();
    } finally {
      if (this.ownsSource) {
        this.source.stop();
      }
    }
  }

  /** Swift `model.isSipAccount()` / `updateDirectoryStrings(isJams:)`. */
  private applyAccount(account: AccountModel | null): void {
    this.isSipAccount = account !== null && account.type === AccountType.SIP;
    this.isJamsAccount = account !== null && account.isJams;
    this.updateDirectoryVisibility();
  }

  /** Swift `showsDirectorySection = !isSipAccount || !model.searchQuery.isEmpty`. */
  private updateDirectoryVisibility(): void {
    this.isDirectoryHidden = this.isSipAccount && this.searchText.trim().length === 0;
  }

  /** Swift `setupFilteredConversations` — svc_conversation_source narrowed by the query. */
  private applyConversations(): void {
    const query: string = this.searchText.trim().toLowerCase();
    const rows: ConversationViewModel[] = [];
    for (const row of this.source.conversationViewModels) {
      if (query.length === 0 || SmartListSearchResultsPage.matches(row, query)) {
        rows.push(row);
      }
    }
    this.searchResultListConversationsDirectorySections = rows;
    this.conversationsSource.reload(rows);
    this.conversationCount = rows.length;
    // Swift `dataSource.onConversationRestored`: an unblocked peer leaves the blocked list, so
    // its row goes too. By key — the @State blockedRow is a proxy, never the same object.
    if (this.isBlockedHit && !this.source.blockedConversation.some(
      (row: ConversationViewModel): boolean => row.key === this.blockedRow.key)) {
      this.isBlockedHit = false;
    }
  }

  /**
   * Swift `ConversationRowVM.matches(_:)` -> `SwarmInfo.contains(searchQuery:)`: the title, or
   * any non-local member's registered name, profile name or jami id. `row.title` alone is the
   * peer's 40-hex id for a dialog, and a group's title names no member, so a typed member NAME
   * matched neither a conversation nor the blocked contact.
   */
  private static matches(row: ConversationViewModel, query: string): boolean {
    const conversation: ConversationModel | null = row.conversation;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // Swift `isOnlyLocalParticipant()`: a swarm with no one else in it matches on the local
    // jami id or the account's registered name, never on its title.
    if (conversation !== null && conversation.isOnlyLocalParticipant()) {
      const local: ConversationParticipant | null = conversation.getLocalParticipants();
      const account: AccountModel | null = registry.accountService.getAccount(conversation.accountId);
      const registeredName: string = account === null ? '' : account.registeredName;
      return (local !== null && local.jamiId.toLowerCase().includes(query)) ||
        (registeredName.length > 0 && registeredName.toLowerCase().includes(query));
    }
    if (row.title.toLowerCase().includes(query)) {
      return true;
    }
    if (conversation === null) {
      return false;
    }
    return conversation.getParticipants().some((participant: ConversationParticipant): boolean => {
      const jamiId: string = participant.jamiId;
      const contact: ContactModel | null = registry.contactsService.contact(jamiId);
      const profile: Profile = registry.profileService.getProfile(jamiId, conversation.accountId).value;
      const names: string[] = [jamiId,
        contact === null || contact.userName === null ? '' : contact.userName,
        profile.alias === null ? '' : profile.alias];
      return names.some((name: string): boolean => name.toLowerCase().includes(query));
    });
  }

  /**
   * Swift `JamiSearchViewModel.isConversationExists(for:)`: a one-to-one on the list whose peer
   * is this jami id, or whose registered name is this query. Without it an existing contact
   * also got a temporary Results row, titled and coloured from the lookup, not the list.
   */
  private conversationExists(query: string): boolean {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const name: string = query.toLowerCase();
    return this.source.conversationViewModels.some((row: ConversationViewModel): boolean => {
      if (row.isCoreConversationWith(query)) {
        return true;
      }
      const conversation: ConversationModel | null = row.conversation;
      if (conversation === null || !conversation.isCoredialog() ||
        conversation.getParticipants().length === 0) {
        return false;
      }
      const contact: ContactModel | null =
        registry.contactsService.contact(conversation.getParticipants()[0].jamiId);
      return contact !== null && contact.userName !== null && contact.userName.toLowerCase() === name;
    });
  }

  /**
   * Swift `searchBlocked(searchQuery:)` + `blockedConversationExists(for:)`: a blocked one-to-one
   * with this peer is shown as the Blocked contacts row INSTEAD of a directory result. Matched
   * by jami id — a dialog's title is the peer's 40-hex id, never the name that was typed.
   */
  private applyBlockedHit(jamiId: string): boolean {
    for (const row of this.source.blockedConversation) {
      if (row.isCoreConversationWith(jamiId)) {
        this.blockedRow = row;
        this.isBlockedHit = true;
        this.clearDirectoryResults();
        this.searchStatus = SearchStatus.NOT_SEARCHING;
        return true;
      }
    }
    return false;
  }

  /**
   * Swift `JamiSearchViewModel.performLookup` — the field's text. A SIP account dials straight
   * away; a jami account needs three characters; a JAMS account searches the directory.
   */
  private performSearch(value: string): void {
    this.searchText = value;
    this.errorText = '';
    this.updateDirectoryVisibility();
    this.applyConversations();
    // Swift `cleanUpPreviousSearch()`.
    this.isBlockedHit = false;
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      this.clearDirectoryResults();
      this.searchStatus = SearchStatus.NOT_SEARCHING;
      return;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    // Swift: a SIP query, or a jami id (SHA1) on a jami account, is a temporary conversation
    // straight away; only a user name needs the name-server lookup.
    if (account.type === AccountType.SIP || /^[0-9a-fA-F]{40}$/.test(trimmed)) {
      const hash: string = account.type === AccountType.SIP ? trimmed : trimmed.toLowerCase();
      if (this.applyBlockedHit(hash)) {
        return;
      }
      if (this.conversationExists(hash)) {
        this.searchStatus = SearchStatus.NOT_SEARCHING;
        return;
      }
      this.setTemporaryConversation(this.makeTemporaryConversation(hash, account, trimmed));
      return;
    }
    if (trimmed.length < MIN_LOOKUP_LENGTH) {
      // Swift `searchStatus = .invalidId` for a query too short to be a jami id.
      this.searchStatus = SearchStatus.INVALID_ID;
      return;
    }
    // Swift `searchBlocked(searchQuery:)` matches the blocked rows on the exact jami id only (the
    // branch above); a name hits once the lookup resolves it (applyLookupResult). No substring
    // match: iPhone 4.20 shows no Blocked contacts row for part of an id or a display name (T-1610).
    // Swift `isConversationExists(for:)`: a contact already on the list by its registered name
    // gets no Results row — its own Conversations row (same name and avatar) is the hit.
    if (!account.isJams && this.conversationExists(trimmed)) {
      this.searchStatus = SearchStatus.NOT_SEARCHING;
      return;
    }
    this.searchStatus = SearchStatus.SEARCHING;
    this.isLoading = true;
    if (account.isJams) {
      ServiceRegistry.shared().nameService.searchUser(account.id, trimmed);
      return;
    }
    ServiceRegistry.shared().nameService.lookupName(account.id, '', trimmed);
  }

  private clearDirectoryResults(): void {
    this.temporaryConversation = null;
    this.isTempResult = false;
    this.resultRows = [];
    this.jamsSource.reload([]);
    this.jamsCount = 0;
    this.isJamsResults = false;
    this.isLoading = false;
  }

  private setTemporaryConversation(row: ConversationViewModel): void {
    this.temporaryConversation = row;
    this.isTempResult = true;
    this.searchStatus = SearchStatus.FOUND_TEMPORARY;
    this.isLoading = false;
  }

  /** Swift `createTemporarySwarmConversation` / `createTemporarySipConversation`. */
  private makeTemporaryConversation(hash: string, account: AccountModel,
    displayName: string): ConversationViewModel {
    const isSip: boolean = account.type === AccountType.SIP;
    const uri: JamiUri = JamiUri.fromInfoHash(isSip ? UriType.SIP : UriType.RING, hash);
    const participant: string = uri.userInfo.length > 0 ? uri.userInfo : hash;
    const conversation: ConversationModel = isSip
      ? ConversationModel.withParticipantUriAndHash(participant, account.id, hash,
        ConversationType.SIP)
      : ConversationModel.withParticipantUri(participant, account.id, ConversationType.ONE_TO_ONE,
        account.jamiId === hash);
    const row: ConversationViewModel = new ConversationViewModel();
    row.setConversation(conversation);
    // bindingContract row title/subtitle/avatar for the ONE row this page owns: the directory
    // result carries the name, so the row cannot derive it from the (empty) conversation.
    this.rowTitle = displayName;
    this.rowSubtitle = '';
    this.rowAvatar = this.avatarFor(participant, account.id);
    return row;
  }

  /** bindingContract[row avatar] <- svc_profiles. */
  private avatarFor(jamiId: string, accountId: string): string {
    const profile: Profile =
      ServiceRegistry.shared().profileService.getProfile(jamiId, accountId).value;
    return profile.photo === null ? '' : profile.photo;
  }

  /** Swift `performLookup`'s `usernameLookupStatus` subscription. */
  private applyLookupResult(response: LookupNameResponse): void {
    const query: string = this.searchText.trim();
    // A jami id is never looked up as a name here; a response for it is a row's address
    // lookup (same daemon signal) and must not replace the temporary conversation.
    if (response.requestedName !== query || /^[0-9a-fA-F]{40}$/.test(query)) {
      return;
    }
    this.isLoading = false;
    if (response.state === LookupNameState.FOUND) {
      const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
      // Swift: `searchBlocked(searchQuery: address)`; a blocked peer gets no Results row.
      if (account !== null && this.conversationExists(response.address)) {
        // The resolved peer already has a conversation: Swift never lists it twice.
        this.clearDirectoryResults();
        this.searchStatus = SearchStatus.NOT_SEARCHING;
        return;
      }
      if (account !== null && !this.applyBlockedHit(response.address)) {
        this.setTemporaryConversation(
          this.makeTemporaryConversation(response.address, account, response.name));
        this.errorText = '';
      }
      return;
    }
    if (response.state === LookupNameState.ERROR) {
      // The libjami name server is the daemon gap: say so rather than reporting "no result".
      this.showDaemonNotice();
      return;
    }
    // Swift `searchStatus = .noResult` — "Username not found" (a literal in the source too).
    this.temporaryConversation = null;
    this.isTempResult = false;
    this.searchStatus = SearchStatus.NO_RESULT;
  }

  /** Swift `performLookup`'s `userSearchResponseShared` subscription (the JAMS directory). */
  private applyJamsResult(response: UserSearchResponse): void {
    this.isLoading = false;
    if (response.state === UserSearchState.ERROR) {
      this.clearDirectoryResults();
      this.showDaemonNotice();
      return;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    const rows: ConversationViewModel[] = [];
    for (const result of response.results) {
      const jamiId: string | undefined = result.get('id');
      if (jamiId === undefined || jamiId.length === 0) {
        continue;
      }
      const conversation: ConversationModel = ConversationModel.withParticipantUri(
        jamiId, account.id, ConversationType.ONE_TO_ONE, account.jamiId === jamiId);
      const row: ConversationViewModel = new ConversationViewModel();
      row.setConversation(conversation);
      rows.push(row);
    }
    this.resultRows = rows;
    this.jamsSource.reload(rows);
    this.jamsCount = rows.length;
    this.isJamsResults = rows.length > 0;
    this.searchStatus = rows.length > 0 ? SearchStatus.FOUND_JAMS : SearchStatus.NO_RESULT;
    this.errorText = '';
  }

  /** The Rule-11 `gap` disclosure: an explicit notice, never a fake success. */
  private showDaemonNotice(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      this.errorText = context.resourceManager.getStringByNameSync('daemon_not_available');
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    }
  }

  // ---------------------------------------------------------------- control effects
  /** Swift `isShowingScanner.toggle()` -> the ScanView sheet. */
  private openScanner(): void {
    this.showScanner = true;
    this.scanner.open();
  }

  /** Swift `model.startSwarmCreation()` -> SwarmCreationViewController. */
  private startSwarmCreation(): void {
    router.pushUrl({ url: 'pages/CreateSwarmHostPage' })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /** Swift `stateEmitter.showDialpad` (the SIP branch of `accountActions`). */
  private openDialpad(): void {
    this.showDialpad = true;
    this.dialpad.open();
  }

  /**
   * Swift `isShowingContactPicker = true` -> `ContactPicker` (CNContactPickerViewController, the
   * device address book) -> `model.showSipConversation(withNumber:publisher:)`. The system
   * picker needs no contacts permission, exactly as the smart list's book button uses it.
   */
  private openContactPicker(): void {
    // CNContactPickerViewController lists contacts by name and returns all their numbers; the
    // HarmonyOS picker defaults to one row per number.
    contact.selectContacts({ isMultiSelect: false, isDisplayedByName: true })
      .then((selected: contact.Contact[]): void => {
        if (selected.length === 0) {
          return; // cancelled
        }
        const numbers: contact.PhoneNumber[] | undefined = selected[0].phoneNumbers;
        if (numbers === undefined || numbers.length === 0) {
          this.showNoNumberAlert();
        } else if (numbers.length === 1) {
          this.showSipConversation(numbers[0].phoneNumber);
        } else {
          this.presentNumberSelection(numbers);
        }
      })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /**
   * Swift ContactPicker `presentNumberSelection(from:with:)`: an alert titled
   * L10n.Smartlist.selectOneNumber, one button per number, then Cancel — stacked, as UIKit
   * lays out an alert with more than two actions.
   */
  private presentNumberSelection(numbers: contact.PhoneNumber[]): void {
    const buttons: AlertDialogButtonOptions[] = numbers.map(
      (number: contact.PhoneNumber): AlertDialogButtonOptions => ({
        value: number.phoneNumber,
        action: (): void => {
          this.showSipConversation(number.phoneNumber);
        }
      }));
    buttons.push({ value: $r('app.string.global_cancel'), action: (): void => {} });
    this.getUIContext().showAlertDialog({
      title: $r('app.string.smartlist_select_one_number'),
      message: '',
      autoCancel: false,
      buttons: buttons,
      buttonDirection: DialogButtonDirection.VERTICAL
    });
  }

  /** Swift ContactPicker: `UIAlertController(title: L10n.Smartlist.noNumber)` with one OK. */
  private showNoNumberAlert(): void {
    showSystemAlert(this.getUIContext(), $r('app.string.smartlist_no_number'));
  }

  /** Swift `ConversationsViewModel.showSipConversation(withNumber:publisher:)`. */
  private showSipConversation(number: string): void {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account !== null) {
      this.openConversation(this.makeTemporaryConversation(number, account, number));
    }
  }

  /** Swift `model.showConversation(withConversationViewModel:publisher:)`. */
  private openConversation(conversation: ConversationViewModel): void {
    router.pushUrl({
      url: 'pages/ConversationChatPage',
      params: { conversationKey: conversation.key }
    }).catch((error: BusinessError): void => {
      this.errorText = describeError(error);
    });
  }

  /**
   * Swift `onDismissEmptyArea()` -> `dismissSearch(clearText: true)` — the field resigns, so the
   * keyboard drops, and search mode ends with a pop back to the smart list. The query dies with
   * this page.
   */
  private dismissSearch(): void {
    this.getUIContext().getFocusController().clearFocus();
    router.back();
  }

  // ---------------------------------------------------------------- builders
  /** Swift `actionItem(icon:title:identifier:fillWidth:action:)`. */
  @Builder
  actionItem(glyph: Resource, title: Resource, slug: string, action: () => void,
    doubled?: boolean) {
    Button({ type: ButtonType.Normal }) {
      Row() {
        // Swift `.foregroundColor(.jami)` on an 18 pt glyph.
        SymbolGlyph(glyph)
          .fontSize(doubled ? PAIR_GLYPH_SIZE : ACTION_ICON_SIZE)
          .fontColor([$r('app.color.jami')])
        if (doubled) {
          // SF `person.2` is two equal people side by side; HarmonyOS `person_2` puts the
          // second one behind the first, so the pair is two `person` glyphs, slightly overlapped.
          SymbolGlyph(glyph)
            .fontSize(PAIR_GLYPH_SIZE)
            .fontColor([$r('app.color.jami')])
            .margin({ left: PAIR_GLYPH_OVERLAP })
        }
        // Swift `.font(.callout)`; the HStack's default spacing is 8.
        Text(title)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ start: LengthMetrics.vp(8) })
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .id(slug)
    .layoutWeight(1)
    // Swift `.padding(.horizontal).padding(.vertical, 10)` — a text row, so a min height.
    .padding({
      left: ACTION_H_PADDING, right: ACTION_H_PADDING,
      top: ACTION_V_PADDING, bottom: ACTION_V_PADDING
    })
    // Swift `.background(Color.jamiTertiaryControl).cornerRadius(12)`.
    .backgroundColor($r('app.color.jami_tertiary_control'))
    .borderRadius(ACTION_CORNER_RADIUS)
    .onClick(() => {
      action();
    })
  }

  /**
   * Swift `accountActions` — `sipActions` for a SIP account, `newChatOptions` otherwise.
   * conditionalVariants has no entry for this branch, but the source's own `@ViewBuilder`
   * switch is real structure, so it is a real `if` (THE ONE INVARIANT: the source wins).
   */
  @Builder
  accountActions() {
    Row({ space: ACTION_ROW_SPACING }) {
      if (this.isSipAccount) {
        // Swift `sipActions`.
        this.actionItem($r('sys.symbol.dial'), $r('app.string.smartlist_dialpad'),
          'dialpadButton', (): void => {
            this.openDialpad();
          })
        this.actionItem($r('sys.symbol.person_crop_circle_fill'),
          $r('app.string.contact_picker_contacts'), 'contactsButton',
          (): void => {
            this.openContactPicker();
          })
      } else {
        // Swift `newChatOptions` — the **Scan QR code** control is the "New contact" item
        // (`icon: "qrcode"`, `identifier: newContactButton`, `action: isShowingScanner.toggle()`).
        this.actionItem($r('sys.symbol.qrcode'), $r('app.string.smartlist_new_contact'),
          'newContactButton', (): void => {
            this.openScanner();
          })
        this.actionItem($r('sys.symbol.person'), $r('app.string.smartlist_new_group'),
          'newGroupButton', (): void => {
            this.startSwarmCreation();
          }, true)
      }
    }
    .width('100%')
    // Swift `.padding(.vertical, 15).padding(.bottom, 10)` + smartListRowStyle's 15 inset.
    .padding({
      top: SECTION_V_PADDING, bottom: SECTION_V_PADDING + ACTION_V_PADDING,
      left: ROW_INSET, right: ROW_INSET
    })
  }

  /** Swift `searchResultView` — the switch over `model.searchStatus`. */
  @Builder
  searchResultView() {
    Column() {
      if (this.isTempResult) {
        // conditionalVariants[temp_result] — the **Temporary conversation row**. Its members are
        // plain (set once on mount), so key it on the row: every keystroke that makes a new
        // temporary conversation rebuilds it (T-1607: a SIP '5678' kept the row for '5').
        ForEach([`${this.temporaryConversation?.key}|${this.rowTitle}`], (_key: string) => {
          TempConversationsView({
            conversation: this.temporaryConversation,
            titleOverride: this.rowTitle,
            subtitleOverride: this.rowSubtitle,
            avatarOverride: this.rowAvatar,
            onSelect: (conversation: ConversationViewModel): void => {
              this.openConversation(conversation);
            }
          })
        }, (key: string) => key)
      } else if (this.isJamsResults) {
        // conditionalVariants[jams_results] — Swift `JamsSearchResultView`: the **Search result
        // row** set, off svc_conversation_source through LazyForEach.
        List() {
          LazyForEach(this.jamsSource, (conversation: ConversationViewModel) => {
            ListItem() {
              ConversationRowView({ model: conversation, withSeparator: true })
            }
            .id('jamsSearchResultItemroot')
            .onClick(() => {
              this.openConversation(conversation);
            })
          }, (conversation: ConversationViewModel) => conversation.key)
        }
        .width('100%')
        .height(this.jamsCount * JAMS_ROW_HEIGHT)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        // S6: no List divider here. Swift `JamsSearchResultView` passes `withSeparator: true`,
        // so ConversationRowView draws the row's own separator - a List divider as well drew
        // every line twice. (The conversations list below is the opposite case:
        // `withSeparator: false`, separator drawn by the List.)
      } else if (this.searchStatus === SearchStatus.SEARCHING) {
        // Swift `case .searching: HStack { Spacer(); ProgressView(); Spacer() }`.
        Row() {
          LoadingProgress()
            .width(ACTION_ICON_SIZE)
            .height(ACTION_ICON_SIZE)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.searchStatus === SearchStatus.NO_RESULT) {
        // Swift `sectionHint(model.searchStatus.toString())` — a literal in the source too.
        Text('Username not found')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .padding({ left: ROW_INSET, right: ROW_INSET })
      } else if (this.searchStatus === SearchStatus.INVALID_ID) {
        Text('Invalid id')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .padding({ left: ROW_INSET, right: ROW_INSET })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `directorySection`. */
  @Builder
  directorySection() {
    Column({ space: SECTION_V_PADDING }) {
      if (!this.isSipAccount) {
        // Swift `Text(model.publicDirectoryTitle)` — JAMS results vs the public name server.
        Text(this.isJamsAccount
          ? $r('app.string.smartlist_jams_results') : $r('app.string.smartlist_results'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          .padding({ left: ROW_INSET, right: ROW_INSET })
      }
      if (this.searchText.trim().length === 0) {
        // Swift `sectionHint(model.publicDirectoryHint)`.
        Text(this.isJamsAccount
          ? $r('app.string.smartlist_jams_directory_hint')
          : $r('app.string.smartlist_public_directory_hint'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .padding({ left: ROW_INSET, right: ROW_INSET })
      } else {
        this.searchResultView()
      }
      if (this.isBlockedHit) {
        // conditionalVariants[blocked_hit] — Swift `blockedContactsView(conversation:)`.
        this.blockedContactsView()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: SECTION_V_PADDING })
  }

  /** Swift `blockedContactsView(conversation:)` — the **Blocked contact row**. */
  @Builder
  blockedContactsView() {
    Column({ space: SECTION_V_PADDING }) {
      Text($r('app.string.account_page_blocked_contacts'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .padding({ left: ROW_INSET, right: ROW_INSET })
      ConversationRowView({ model: this.blockedRow, withSeparator: false })
        .id('searchBlockedContactRow')
        .onClick(() => {
          this.openConversation(this.blockedRow);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `conversationsSearchHeaderView`. */
  @Builder
  conversationsSearchHeaderView() {
    Column({ space: SECTION_V_PADDING }) {
      Text($r('app.string.smartlist_conversations'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .padding({ left: ROW_INSET, right: ROW_INSET })
      if (this.conversationCount === 0) {
        if (this.searchText.trim().length === 0) {
          Text($r('app.string.smartlist_conversations_search_hint'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .padding({ left: ROW_INSET, right: ROW_INSET })
        } else {
          Text($r('app.string.smartlist_no_conversations_found'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .padding({ left: ROW_INSET, right: ROW_INSET })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      // Swift: the search controller's field stays over the results while search mode is on,
      // and UIKit draws three things around it that the app never writes a line for (both
      // captures record all three): the leading magnifying glass, the trailing clear button
      // (`clearButtonMode` default `.whileEditing` — only while the field holds text), and the
      // Cancel button, shown for as long as the search controller is active. This page IS that
      // active controller, so Cancel has no condition — S0079 (query "test") and S0080 (empty
      // query) both show it, and only S0079 shows the clear button.
      Row() {
        Stack() {
          TextInput({ text: $$this.searchText })
            .id('searchBarTextField')
            // Swift `SearchBar.Coordinator.activateSearch()` -> `becomeFirstResponder()`: the
            // field takes focus as search mode opens, which raises the keyboard.
            .defaultFocus(true)
            // The UISearchController's own chrome — a 36 pt gray rounded field
            // (mapping-tables.md §7: what UIKit renders with no line of code).
            .width('100%')
            .height(SEARCH_FIELD_HEIGHT)
            .borderRadius(SEARCH_FIELD_RADIUS)
            .backgroundColor($r('sys.color.comp_background_gray'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            // Both glyph boxes are reserved whether or not the clear button is drawn, so the
            // text never reflows as it appears (UISearchBar does the same).
            .padding({ left: SEARCH_TEXT_INSET, right: SEARCH_TEXT_INSET })
            .onChange((value: string) => {
              this.performSearch(value);
            })

          Row() {
            // Decorative: `magnifyingglass` is what the capture records inside the field
            // (resource-id `magnifyingglass`; icon-map exact -> sys.symbol.magnifyingglass).
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(SEARCH_GLYPH_SIZE)
              .fontColor([$r('app.color.secondary_label')])
            // The UISearchController's prompt — `smartlist.searchBar` = "Search" is what it shows
            // (and what S0079/S0080/S0081 captured); `smartlist.searchBarPlaceholder` is the
            // ContactPicker's. It is a real Text rather than TextInput's own `placeholder`
            // because `uitest dumpLayout` reports a TextInput's VALUE and never its placeholder
            // (no attribute in text_input.d.ts surfaces it), so the built-in one leaves the
            // field's prompt absent from the dumped tree. It sits in the chrome row, so its left
            // edge is glyph inset + glyph + gap = SEARCH_TEXT_INSET, the field's own text inset.
            if (this.searchText.length === 0) {
              Text($r('app.string.smartlist_search_bar'))
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('sys.color.font_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: SEARCH_PLACEHOLDER_GAP })
            }
            Blank()
            // UISearchBar's clear button — shown only while the field holds text, and its tap
            // empties the field, which runs the same lookup path as typing it empty.
            if (this.searchText.length > 0) {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .id('clear_text')
                .fontSize(SEARCH_GLYPH_SIZE)
                .fontColor([$r('sys.color.icon_secondary')])
                // The source control is UIKit's own, so it carries no accessibilityIdentifier
                // and no app string resource: the capture addresses it by its accessibilityLabel
                // ("Clear text"), which is also the slug this `.id()` is taken from.
                .accessibilityText('Clear text')
                .onClick(() => {
                  this.performSearch('');
                })
            }
          }
          .width('100%')
          .height(SEARCH_FIELD_HEIGHT)
          .padding({ left: SEARCH_GLYPH_INSET, right: SEARCH_GLYPH_INSET })
          .alignItems(VerticalAlign.Center)
          // Chrome laid over the field: the taps it does not own belong to the TextInput beneath.
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .layoutWeight(1)
        .height(SEARCH_FIELD_HEIGHT)

        // Swift `searchBarCancelButtonClicked` -> `dismissSearch(clearText: true, animated: false)`:
        // the query is cleared AND search mode ends, which on the router is a pop back to the
        // smart list. Tinted, like every UIKit bar button.
        Text($r('app.string.global_cancel'))
          .id('cancel')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
          .margin({ left: SEARCH_CANCEL_GAP })
          .onClick(() => {
            this.performSearch('');
            this.dismissSearch();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })
      .margin({ top: SEARCH_BAR_V_MARGIN, bottom: SEARCH_BAR_V_MARGIN })

      Scroll() {
        Column() {
          // 1. Swift `accountActions`.
          this.accountActions()

          // 2. Swift `if showsDirectorySection { directorySection }` —
          //    conditionalVariants[directory_hidden] is its inverse.
          if (!this.isDirectoryHidden) {
            this.directorySection()
          }

          // 3. Swift `conversationsSearchHeaderView`.
          this.conversationsSearchHeaderView()

          // 4. Swift `if !model.filteredConversations.isEmpty { conversationsView }` — the
          //    **Conversation row** set, off svc_conversation_source through LazyForEach.
          if (this.conversationCount > 0) {
            List() {
              LazyForEach(this.conversationsSource, (conversation: ConversationViewModel) => {
                ListItem() {
                  ConversationRowView({ model: conversation, withSeparator: false })
                }
                .id('conversationsItemroot')
                .onClick(() => {
                  this.openConversation(conversation);
                })
              }, (conversation: ConversationViewModel) => conversation.key)
            }
            .width('100%')
            .height(this.conversationCount * JAMS_ROW_HEIGHT)
            // The List is as tall as its rows, so a swipe that starts on a row must scroll the
            // page's Scroll; by default the List kept it and the rows below the fold were unreachable.
            .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
            .divider({
              strokeWidth: 0.5,
              color: $r('sys.color.comp_divider'),
              startMargin: ROW_SEPARATOR_INSET,
              endMargin: 0
            })
          }

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.secondary_label'))
              .padding({ left: ROW_INSET, right: ROW_INSET })
          }

          // 5. Swift `Color.clear.frame(minHeight: 600).onTapGesture(perform: onDismissEmptyArea)`.
          Column()
            .id('search_results_dismiss_area')
            .width('100%')
            .height(DISMISS_AREA_MIN_HEIGHT)
            .onClick(() => {
              this.dismissSearch();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    // Swift `.listStyle(.plain)` — a white page with edge-to-edge rows, no grouped chrome.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_smart_list_search')
  }
}
