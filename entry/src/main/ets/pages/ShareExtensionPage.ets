/*
 * screen_share_extension — "Share Extension", ported from
 *   Ring/jamiShareExtension/ShareView.swift (ShareView, ConversationSection, ConversationsView,
 *     ConversationScrollView, ConversationSelectableRow, ShareButtonView, EmptyStateView /
 *     NoConversationsView / NoSearchResultsView, AccountNavigationButton,
 *     AccountSelectionSheet, LoadingStateView, ShareExtensionAccessibilityIdentifiers)
 *   Ring/jamiShareExtension/ShareViewModel.swift + AccountViewModel.swift + AvatarLoader.swift
 *   Ring/jamiShareExtension/ShareViewController.swift
 *   Ring/Ring/Features/Conversations/Conversation/ConversationViewModel.swift
 *
 * presentation: page (plan). On iOS this is an out-of-process share extension
 * (com.savoirfairelinux.ring.jamiShareExtension) hosted by ShareViewController. Here the share
 * panel starts EntryAbility through its `ohos.want.action.sendData` skill (module.json5), which
 * routes to this @Entry page and hands it the shared records through ShareActions, so the page
 * runs on the app's own, already started daemon and services. That is the one structural
 * departure from the source.
 *
 * NO CAPTURED STATE: the gallery declared this screen uncapturable, so every control and
 * branch below comes from the source only.
 *
 * S3 — the real tree of `ShareView.body`:
 *   NavigationView { ZStack(alignment: .top) {
 *       if let selectedId = selectedAccountId { ConversationSection(...) }
 *       if viewModel.isLoading { LoadingStateView() }
 *       if isSending { sendingOverlay() }
 *   }
 *   .toolbar { .primaryAction  -> AccountNavigationButton + its .sheet  "share_account_menu"
 *              .cancellationAction -> Button(L10n.Global.close)         "share_close_button" }
 *   .searchable(text: $searchText, prompt: L10n.ShareExtension.searchConversations)
 *   .alert(isPresented: $showUnsupportedAlert) { … dismissButton: closeAction } }
 *
 *   ConversationSection = filteredConversations.isEmpty ? EmptyStateView(searchText:)
 *                                                       : ConversationsView(...)
 *   EmptyStateView     = searchText.isEmpty ? NoConversationsView() : NoSearchResultsView()
 *   ConversationsView  = ConversationScrollView + if shouldShowShareButton { ShareButtonView }
 *   shouldShowShareButton = !selectedConversationIds.isEmpty && !isSending
 *
 * bindingContract: [conversation selection list] / [conversation rows] are
 * svc_conversation_source — `ShareViewModel.conversationsByAccount[selectedAccountId]`, which
 * on this platform is `ConversationDataSource.conversationViewModels` scoped to the selected
 * account and filtered by the search field, rendered through LazyForEach over an
 * ArrayDataSource. [account] is svc_accounts (`viewModel.accountList`). Both start EMPTY and
 * are filled by their service; no row is a literal.
 *
 * itemTypes: the contract lists TWO row kinds — ConversationSelectableRow (here) and
 * AccountSelectionRowView (comp_account_selection_sheet) — and each has its own tap effect:
 * a conversation row TOGGLES its selection, an account row SELECTS the account and closes the
 * picker. Neither routes anywhere.
 *
 * conditionalVariants, each a real `if` on its own bound selector:
 *   account_picker_open — isAccountPickerOpen, Swift `.sheet(isPresented: $showingAccountPicker)`
 *   has_selection       — hasSelection, `!selectedConversationIds.isEmpty && !isSending`
 *   sending             — isSending, the sending overlay
 *   no_conversations    — isNoConversations, NoConversationsView (empty search field)
 *   no_search_results   — isNoSearchResults, NoSearchResultsView (a query that matched nothing)
 *   unsupported         — isUnsupported, the unsupported-attachment alert
 *
 * `magnifyingglass` is an exact icon-map match; `bubble.left.and.bubble.right` resolves only
 * to a CLOSED candidate shortlist with no faithful member, so that decorative glyph is left out
 * rather than shipped wrong. `chevron.up.chevron.down` is chevron_up over chevron_down.
 *
 * ShareViewModel.sendMessage / sendFile are the app's own ConversationsService.sendSwarmMessage
 * and DataTransferService.sendFile.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics, promptAction, router, SymbolGlyphModifier } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { AccountSelectionSheet } from '../components/AccountSelectionSheet';
import { AccountsService } from '../common/AccountsService';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ConversationDataSource, ConversationViewModel } from '../common/ConversationDataSource';
import { ConversationsService } from '../common/ConversationsService';
import { DisposeBag } from '../common/Observable';
import { ShareActions } from '../common/ShareActions';
import { AvatarSwiftUIView, GroupAvatarMember, GroupAvatarSelection } from '../components/AvatarSwiftui';
import { groupAvatarFor } from '../components/ExpandableAvatar';
import { ShareButtonView } from '../components/ShareButtonView';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ConversationModel } from '../model/ConversationModel';
import { ContactModel } from '../model/ContactModel';
import { LookupNameResponse, LookupNameState } from '../common/NameService';
import { Profile } from '../model/Profile';

/** Swift `HStack(spacing: 12)` in a conversation row. */
const ROW_GAP: number = 12;
/** Swift `ConversationAvatarView(conversation: conversation, size: 45)`. */
const ROW_AVATAR: number = 45;
/** Swift `.frame(width: 20, height: 20)` on the selection check. */
const CHECK_SIZE: number = 20;
/** Swift `.padding(.vertical, 8)` on a conversation row. */
const ROW_INSET_V: number = 8;
/** Swift `VStack(spacing: 16)` in both empty states. */
const EMPTY_GAP: number = 16;
/** Swift `.font(.system(size: 48, weight: .light))` on an empty state's glyph. */
const EMPTY_GLYPH: number = 48;

/* ── S5 (NO CAPTURE — the source's own, plus the iOS defaults it inherits) ────────────
 * ShareView is a NavigationView over a plain conversation list with a `.searchable` field;
 * the toolbar is `.inline`. The extension's `accentColor` is its own AccentColor asset
 * (#005599 / dark #007BCF), `app.color.jami_button_primary`, not `jami`.
 */
/** iOS inline navigation-bar height, and a row's minimum hit target. */
const NAV_BAR_HEIGHT: number = 44;
/** The standard screen side margin. */
const PAGE_INSET: number = 16;
/** The iOS nav-bar hairline and the plain list's row separator. */
const HAIRLINE: number = 0.5;
/** `.searchable` renders a rounded grey search field, UISearchBar's 36 pt tall. */
const SEARCH_RADIUS: number = 10;
const SEARCH_HEIGHT: number = 36;
/** UISearchBar's Cancel beside the active field. */
const SEARCH_CANCEL_GAP: number = 11;
/** Swift `ProgressView().scaleEffect(1.5)` — the iOS medium indicator, enlarged. */
const LOADING_SIZE: number = 48;
/** Swift `.frame(maxWidth: 150)` on the account button's name. */
const ACCOUNT_NAME_MAX_WIDTH: number = 150;
/**
 * Swift `chevron.up.chevron.down` at `.system(size: 12, weight: .medium)`, drawn as chevron_up
 * over chevron_down (the SDK has no combined glyph). ponytail: size and overlap are eyeballed
 * from the iOS capture; tune on device if the pair reads taller or looser than iOS's.
 */
const CHEVRON_SIZE: number = 10;
const CHEVRON_OVERLAP: number = -4;
/** Swift AccountSelectionView `HStack(spacing: 8)` and `AccountAvatarView(account:size: 30)`. */
const ACCOUNT_GAP: number = 8;
const ACCOUNT_AVATAR: number = 30;
/** Swift `AccountSelectionView(...).padding(.horizontal, 4)` inside the account button. */
const ACCOUNT_INSET_H: number = 4;
/** The iOS system alert's own content width and action-row height. */
const ALERT_WIDTH: number = 270;
const ALERT_ACTION_HEIGHT: number = 44;
const ALERT_RADIUS: number = 12;
/* ── S6: the two things the source presents OVER the page, not inside it ───────────── */
/** Swift `sendingOverlay()` — `Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)`. */
const SENDING_SCRIM: string = '#66000000';
/** Swift the overlay's card — `RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.8))`. */
const SENDING_CARD: string = '#CC000000';
const SENDING_CARD_RADIUS: number = 10;
/** Swift `ProgressView(_ title:)` — the label sits under the ring, both tinted white. */
const SENDING_GAP: number = 12;
const SENDING_RING: number = 32;
/**
 * How long the overlay is up before the items are handed over. Staging a file copies it on the
 * UI thread, so without a few frames first the overlay never draws. ponytail: a fixed yield;
 * Swift keeps the overlay until the daemon reports every item sent (transmissionStatus), the
 * upgrade if the overlay must track the real transfer.
 */
const SENDING_YIELD_MS: number = 100;
/** Swift `.alert(...)` — the iOS system alert dims what is behind it. */
const ALERT_SCRIM: string = '#66000000';

/**
 * One row of the conversation list, carrying its OWN avatar inputs.
 *
 * Swift `ConversationAvatarView(conversation:size:)`: the conversation's photo, else a group's
 * member composite (`groupAvatarImage`), else `UnifiedAvatarView`'s monogram on
 * `avatarBackgroundColor(for: name)` — the app's own AvatarSwiftUIView draws all three
 * (T-1191: the share-only avatar drew every row as a grey disc, never a colour or composite).
 *
 * The bindingContract lists a second item type for this site, AccountSelectionRowView; that
 * row belongs to the ACCOUNT PICKER's own list (comp_account_selection_sheet), which renders
 * it there, and it is never one of these rows.
 */
class ShareConversationRow {
  readonly model: ConversationViewModel;
  readonly isGroup: boolean;
  /** Swift `ConversationViewModel.name` — resolved by the page (rowName), not the raw title. */
  readonly name: string;
  /** Swift `ConversationViewModel.avatar` — resolved by the page (rowPhoto). '' = none. */
  readonly photo: string;
  /** Swift `groupAvatarImage`'s members; empty for a dialog or a group with its own photo. */
  readonly group: GroupAvatarSelection;

  constructor(model: ConversationViewModel, name: string, photo: string) {
    this.model = model;
    this.name = name;
    this.photo = photo;
    const conversation: ConversationModel | null = model.conversation;
    this.isGroup = conversation !== null && !conversation.isCoredialog();
    this.group = this.isGroup && photo.length === 0 ? groupAvatarFor(conversation) : new GroupAvatarSelection();
  }

  /** LazyForEach key: a name, photo or member that resolves later must rebuild the row. */
  key(): string {
    return `${this.model.key}|${this.name}|${this.photo.length}|${this.group.overflowCount}|` +
      this.group.members.map((member: GroupAvatarMember) => `${member.name}:${member.photo.length}`).join(',');
  }
}

@Entry
@Component
struct ShareExtensionPage {
  /** conditionalVariants[account_picker_open]: Swift `@State private var showingAccountPicker`. */
  @State isAccountPickerOpen: boolean = false;
  /** conditionalVariants[has_selection]: Swift `!selectedConversationIds.isEmpty`. */
  @State hasSelection: boolean = false;
  /** conditionalVariants[sending]: Swift `@State private var isSending`. */
  @State isSending: boolean = false;
  /** conditionalVariants[no_conversations]: Swift EmptyStateView -> NoConversationsView. */
  @State isNoConversations: boolean = true;
  /** conditionalVariants[no_search_results]: Swift EmptyStateView -> NoSearchResultsView. */
  @State isNoSearchResults: boolean = false;
  /** conditionalVariants[unsupported]: Swift `@State private var showUnsupportedAlert`. */
  @State isUnsupported: boolean = false;
  /** Swift `@State private var searchText`. */
  @State searchText: string = '';
  /** `.searchable`'s `isSearching`: from the field's first focus until its own Cancel. */
  @State isSearching: boolean = false;
  private searchController: SearchController = new SearchController();
  /** bindingContract[account]: svc_accounts <- `viewModel.accountList`. */
  @State @Watch('onAccountSelected') account: string = '';
  /** Swift `viewModel.accountList` — the rows the picker shows. */
  @State accounts: AccountModel[] = [];
  /** The selected account's own profile name and photo ('' = none), followed in followAccountProfile. */
  @State accountAlias: string = '';
  @State accountPhoto: string = '';
  /** bindingContract[conversation selection list] / [conversation rows]: svc_conversation_source. */
  @State conversationSelectionListAccountPickerList: ConversationViewModel[] = [];
  @State conversationRows: ConversationViewModel[] = [];
  /** Swift `@State private var selectedConversationIds: Set<String>`. */
  @State selectedConversationIds: string[] = [];
  /** Swift `viewModel.isLoading` — LoadingStateView. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** LazyForEach's source (CLAUDE.md rule 7) — the filtered conversations of this account. */
  private rows: ArrayDataSource<ShareConversationRow> =
    new ArrayDataSource<ShareConversationRow>([]);
  /** Swift `viewModel.conversationsByAccount` before the search filter. */
  private unfilteredConversations: ConversationViewModel[] = [];
  /**
   * svc_conversation_source — Swift's `ShareViewModel.conversationsByAccount`. The data source
   * subscribes to ConversationsService itself, exactly as the smart list's own copy does.
   */
  private source: ConversationDataSource = new ConversationDataSource();
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** The selected account's profile subscription, replaced when the account changes. */
  private profileBag: DisposeBag = new DisposeBag();
  /** Swift `let items: [NSExtensionItem]` — what the share panel handed in. */
  private sharedRecords: systemShare.SharedRecord[] = [];
  /** True when the share panel opened this page, so closing returns to the app that shared. */
  private openedBySharePanel: boolean = false;
  /** Registered names found for one-to-one peers (Swift lookupUsername), by Jami id. */
  private peerNames: Map<string, string> = new Map<string, string>();
  /** Peers whose profile and name lookup are already followed. */
  private followedPeers: Set<string> = new Set<string>();

  aboutToAppear(): void {
    const shared: Promise<systemShare.SharedRecord[]> | null = ShareActions.takeSharedRecords();
    if (shared !== null) {
      this.openedBySharePanel = true;
      shared.then((records: systemShare.SharedRecord[]): void => {
        this.sharedRecords = records;
        this.handleOnAppear();
      });
    }
    // The data source fills conversationViewModels only once started, and it must subscribe
    // before the page does, so its list is current when the subscription below reloads the rows.
    this.source.start();
    this.bag.add(ServiceRegistry.shared().nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (response.state === LookupNameState.FOUND && response.name.length > 0 &&
          this.followedPeers.has(response.address) && this.peerNames.get(response.address) !== response.name) {
          this.peerNames.set(response.address, response.name);
          this.applyFilter();
        }
      }));
    this.loadAccounts();
    this.loadConversations();
    this.bag.add(ServiceRegistry.shared().conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        console.debug('ShareExtensionPage: ' + conversations.length + ' conversations');
        this.loadConversations();
      }));
    this.handleOnAppear();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscriptions go whatever happens on the way out.
    try {
      this.source.stop();
    } finally {
      this.bag.dispose();
      this.profileBag.dispose();
    }
  }

  /**
   * Swift `AccountNavigationButton.onAppear` — the first account is selected when none is.
   * `viewModel.accountList` is svc_accounts' own list, never a literal.
   */
  private loadAccounts(): void {
    // A copy: making an account current (onAccountSelected) moves it to the head of the
    // service's own list, and the picker keeps the order it opened with, as Swift's does.
    const accounts: AccountModel[] = ServiceRegistry.shared().accountService.accountList.slice();
    this.accounts = accounts;
    if (this.account.length === 0) {
      if (this.currentAccountId.length > 0) {
        this.account = this.currentAccountId;
      } else if (accounts.length > 0) {
        this.account = accounts[0].id;
      }
    }
    this.followAccountProfile();
  }

  /**
   * Swift `AccountViewModel.fetchAccountDetails`: follow the selected account's own profile. The
   * relay starts empty and fills ~100 ms later, so a single read at build time kept the username.
   */
  private followAccountProfile(): void {
    this.profileBag.dispose();
    this.accountAlias = '';
    this.accountPhoto = '';
    if (this.account.length === 0) {
      return;
    }
    this.profileBag.add(ServiceRegistry.shared().profileService.getAccountProfile(this.account)
      .subscribe((profile: Profile): void => {
        this.accountAlias = profile.alias === null ? '' : profile.alias;
        this.accountPhoto = profile.photo === null ? '' : profile.photo;
      }));
  }

  /**
   * Swift `AccountSelectionSheet` setting `selectedAccountId`. Swift reads every account's
   * conversations up front; this app's ConversationsService holds the current account's only,
   * so the picked account is made current, which reloads its conversations
   * (EntryAbility.reloadDataFor) into the subscription below. A selection made in the other
   * account's list does not carry over.
   */
  private onAccountSelected(): void {
    const service: AccountsService = ServiceRegistry.shared().accountService;
    const picked: AccountModel | null = service.getAccount(this.account);
    const current: AccountModel | null = service.currentAccount;
    if (picked !== null && (current === null || current.id !== picked.id)) {
      service.currentAccount = picked;
    }
    this.followAccountProfile();
    this.selectedConversationIds = [];
    this.hasSelection = false;
    this.loadConversations();
  }

  /**
   * Swift `viewModel.conversationsByAccount[selectedAccountId]` — on this platform the app's
   * own conversation source, scoped to the selected account.
   */
  private loadConversations(): void {
    this.isLoading = true;
    const scoped: ConversationViewModel[] = this.source.conversationViewModels
      .filter((model: ConversationViewModel) => {
        const conversation: ConversationModel | null = model.conversation;
        return conversation !== null && conversation.accountId === this.account;
      });
    this.unfilteredConversations = scoped;
    this.conversationSelectionListAccountPickerList = scoped;
    scoped.forEach((model: ConversationViewModel): void => {
      this.followPeer(model);
    });
    this.applyFilter();
    this.isLoading = false;
  }

  /** The one-to-one peer of a row, '' for a group. */
  private peerOf(model: ConversationViewModel): string {
    const conversation: ConversationModel | null = model.conversation;
    if (conversation === null || !conversation.isCoredialog() || conversation.getParticipants().length === 0) {
      return '';
    }
    return conversation.getParticipants()[0].jamiId;
  }

  /**
   * Swift `AdapterService.buildCoreDialogName`: a one-to-one row is named after the peer's
   * profile name, else its registered name, else its Jami id (T-1005 review: the rows showed
   * raw ids where iOS shows 'qa_ycwfyx', 'QA R6 Alias'). A group keeps its title.
   */
  private rowName(model: ConversationViewModel): string {
    const peer: string = this.peerOf(model);
    const conversation: ConversationModel | null = model.conversation;
    if (peer.length === 0 || conversation === null) {
      return model.title;
    }
    const alias: string | null =
      ServiceRegistry.shared().profileService.getProfile(peer, conversation.accountId).value.alias;
    if (alias !== null && alias.trim().length > 0) {
      return alias;
    }
    const registered: string | undefined = this.peerNames.get(peer);
    return registered !== undefined ? registered : model.title;
  }

  /** Swift `getConversationAvatar`: the conversation's own photo, else the dialog peer's. */
  private rowPhoto(model: ConversationViewModel): string {
    const peer: string = this.peerOf(model);
    const conversation: ConversationModel | null = model.conversation;
    if (model.avatar.length > 0 || peer.length === 0 || conversation === null) {
      return model.avatar;
    }
    return ServiceRegistry.shared().profileService.getProfile(peer, conversation.accountId).value.photo ?? '';
  }

  /** Follows a peer's profile (it resolves after the first read) and looks its name up once. */
  private followPeer(model: ConversationViewModel): void {
    const peer: string = this.peerOf(model);
    const conversation: ConversationModel | null = model.conversation;
    if (peer.length === 0 || conversation === null || this.followedPeers.has(peer)) {
      return;
    }
    this.followedPeers.add(peer);
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(registry.profileService.getProfile(peer, conversation.accountId)
      .subscribe((): void => {
        this.applyFilter();
      }));
    const contact: ContactModel | null = registry.contactsService.contact(peer);
    if (contact !== null && contact.userName !== null && contact.userName.length > 0) {
      this.peerNames.set(peer, contact.userName);
      return;
    }
    registry.nameService.lookupAddress(conversation.accountId, '', peer);
  }

  /**
   * Swift `ConversationSection.filteredConversations` — the search text filters by name, and
   * which empty state is shown depends on whether a query was typed at all.
   */
  private applyFilter(): void {
    const query: string = this.searchText.trim().toLowerCase();
    const filtered: ConversationViewModel[] = query.length === 0
      ? this.unfilteredConversations
      : this.unfilteredConversations.filter((model: ConversationViewModel) =>
        this.rowName(model).toLowerCase().includes(query));
    this.conversationRows = filtered;
    // Each row carries its own avatar inputs (photo, group members), so the @Builder draws
    // each item from its own data instead of one uniform row.
    this.rows.reload(filtered.map((model: ConversationViewModel) =>
      new ShareConversationRow(model, this.rowName(model), this.rowPhoto(model))));
    // Swift `EmptyStateView(searchText:)`: no query -> NoConversationsView, a query that
    // matched nothing -> NoSearchResultsView. Exclusive, and neither shows beside the list.
    this.isNoConversations = filtered.length === 0 && query.length === 0;
    this.isNoSearchResults = filtered.length === 0 && query.length > 0;
  }

  /**
   * Swift `ShareView.handleOnAppear()` — walks the incoming attachments and raises
   * showUnsupportedAlert for the first provider outside `supportedTypes`. Swift's types are a
   * file (image, movie, audio, pdf, zip, fileURL), sent with sendFile, or text (plainText, url,
   * html), sent as a message; a record that is neither is unsupported. So is a share whose
   * data could not be read (systemShare.getSharedData failed, or handed over no record): it has
   * nothing this page can send.
   */
  private handleOnAppear(): void {
    this.isUnsupported = this.sharedRecords.length === 0 ||
      this.sharedRecords.some((record: systemShare.SharedRecord): boolean =>
        ShareExtensionPage.sharedFileUri(record).length === 0 &&
        ShareExtensionPage.sharedText(record).length === 0);
  }

  /** A record's file, Swift `handleFileURL` — '' when it carries none. */
  private static sharedFileUri(record: systemShare.SharedRecord): string {
    const uri: string = record.uri ?? '';
    return uri.startsWith('file://') ? uri : '';
  }

  /**
   * A record's text, Swift's plainText / url / html handlers: its content, else a link that is
   * not a file. '' when it carries none.
   */
  private static sharedText(record: systemShare.SharedRecord): string {
    const content: string = record.content ?? '';
    if (content.length > 0) {
      return content;
    }
    const uri: string = record.uri ?? '';
    return uri.startsWith('file://') ? '' : uri;
  }

  /** `.searchable`'s Cancel: the keyboard closes, the query clears and the toolbar returns. */
  private endSearch(): void {
    this.searchController.stopEditing();
    this.searchText = '';
    this.applyFilter();
    this.isSearching = false;
  }

  /** Swift `AccountNavigationButton`'s action — `showingAccountPicker = true`. */
  private openAccountPicker(): void {
    this.isAccountPickerOpen = true;
  }

  /** Swift `ConversationScrollView.toggleSelection(for:)` — insert/remove the id. */
  private toggleConversation(model: ConversationViewModel): void {
    const next: string[] = this.selectedConversationIds.slice();
    const index: number = next.indexOf(model.key);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(model.key);
    }
    this.selectedConversationIds = next;
    this.hasSelection = next.length > 0;
  }

  private isSelected(model: ConversationViewModel): boolean {
    return this.selectedConversationIds.includes(model.key);
  }

  /**
   * Swift `sendSelected()` -> `sendAllItems(to:accountId:)` -> `ShareViewModel.sendMessage` /
   * `sendFile` for every selected room, then `closeAction()` once the items are handed over.
   */
  private sendSelected(): void {
    if (this.isSending) {
      // A second tap before the button is gone must not send everything twice.
      return;
    }
    if (this.account.length === 0) {
      // Never a silent return: with no account there is nothing to send from, and the control
      // has to say so rather than look broken.
      this.errorText = this.resolve('daemon_not_available');
      promptAction.showToast({ message: $r('app.string.daemon_not_available') });
      return;
    }
    this.errorText = '';
    this.isSending = true;
    setTimeout((): void => {
      this.sendAllItems();
      this.isSending = false;
      this.close();
    }, SENDING_YIELD_MS);
  }

  /**
   * Swift `sendAllItems(to:accountId:)` for every selected id. The selection is walked over the
   * account's whole list, not the search-filtered rows, as Swift walks selectedConversationIds.
   * Swift sends the EXTENSION'S items, never anything typed on this screen: the search field is
   * a filter and is never sent.
   */
  private sendAllItems(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const service: ConversationsService = registry.conversationsService;
    for (const model of this.unfilteredConversations) {
      const conversation: ConversationModel | null = model.conversation;
      if (conversation === null || !this.isSelected(model)) {
        continue;
      }
      for (const record of this.sharedRecords) {
        const uri: string = ShareExtensionPage.sharedFileUri(record);
        if (uri.length > 0) {
          // Swift `handleFileURL`: `url.lastPathComponent` names the file; sendFile stages a copy
          // before the share panel's read grant lapses.
          registry.dataTransferService.sendFile(conversation, uri,
            uri.substring(uri.lastIndexOf('/') + 1), null);
          continue;
        }
        const text: string = ShareExtensionPage.sharedText(record);
        if (text.length > 0) {
          service.sendSwarmMessage(conversation.id, this.account, text, '');
        }
      }
    }
  }

  /** A localized string resolved to plain text — the inline failure slot shows a message. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  /**
   * Swift `closeAction()` — completes the extension request. On the router stack that is back,
   * and a cold deep link that landed here as the only entry goes to the app's root instead of
   * popping the last page and dropping the app. Opened by the share panel, Jami then goes behind
   * the app that shared, as `completeRequest()` returns to it on iOS.
   */
  private close(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    if (router.getLength() === '1') {
      router.replaceUrl({ url: 'pages/SmartListConversationsHomePage' })
        .catch((error: Error): void => {
          console.error('ShareExtensionPage: replaceUrl failed: ' + error.message);
        });
    } else {
      router.back();
    }
    if (this.openedBySharePanel) {
      context.moveAbilityToBackground()
        .catch((error: BusinessError): void => {
          console.error('ShareExtensionPage: moveAbilityToBackground failed: ' + error.message);
        });
    }
  }

  /**
   * Swift `AdapterService.resolveLocalAccountName(from:)` — the account's profile name, else the
   * registered name, else the Jami id.
   */
  private accountName(): string {
    if (this.accountAlias.length > 0) {
      return this.accountAlias;
    }
    for (const account of this.accounts) {
      if (account.id === this.account) {
        return account.registeredName.length > 0 ? account.registeredName : account.jamiId;
      }
    }
    return '';
  }

  /**
   * bindingContract[account]: svc_accounts/svc_profiles — Swift `AccountAvatarView(account:)`
   * reads `profileService.getAccountProfile(accountId:)`. Never an empty placeholder.
   */
  private accountAvatar(): string {
    return this.accountPhoto;
  }

  /** Swift `ConversationSelectableRow(conversation:isSelected:toggleAction:)`. */
  @Builder
  private conversationRow(row: ShareConversationRow) {
    Row({ space: ROW_GAP }) {
      // Swift `ConversationAvatarView(conversation:size: 45)`: photo, group composite, or the
      // coloured monogram (person.fill for a peer still named by its id).
      AvatarSwiftUIView({
        avatarData: row.photo,
        displayText: row.name,
        isGroup: row.isGroup,
        avatarSize: ROW_AVATAR,
        groupAvatar: row.group
      })

      Text(row.name)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Swift `.truncationMode(.middle)`.
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        // Swift `.foregroundColor(.primary)` at SwiftUI's default body size.
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))

      Blank()

      // Swift `if isSelected { "checkmark.circle.fill" } else { "circle" }`.
      if (this.isSelected(row.model)) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(CHECK_SIZE)
          // Swift `.foregroundColor(.accentColor)` — the extension's AccentColor.
          .fontColor([$r('app.color.jami_button_primary')])
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize(CHECK_SIZE)
          // Swift `.foregroundColor(.secondary)`.
          .fontColor([$r('app.color.secondary_label')])
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .padding({
      start: LengthMetrics.vp(PAGE_INSET),
      end: LengthMetrics.vp(PAGE_INSET),
      top: LengthMetrics.vp(ROW_INSET_V),
      bottom: LengthMetrics.vp(ROW_INSET_V)
    })
    // The WHOLE row is Swift's tap target (`contentShape(Rectangle()).onTapGesture`).
    .id('share_conversation_itemroot')
    .accessibilityText($r('app.string.share_extension_accessibility_select_conversation'))
    .onClick(() => {
      this.toggleConversation(row.model);
    })
  }

  /** Swift `AccountSelectionSheet(accounts:selectedAccountId:isPresented:)`. */
  @Builder
  accountPickerSheet() {
    AccountSelectionSheet({
      accounts: this.accounts,
      selectedAccountId: $account,
      isPresented: $isAccountPickerOpen
    })
  }

  build() {
    /*
     * S6: `sendingOverlay()` and `.alert(isPresented: $showUnsupportedAlert)` are both
     * presented OVER the page in the source — the first is literally a full-bleed
     * `Color.black.opacity(0.4)` with a centred card, the second the iOS system alert. S3/S4
     * had them inline at the foot of the content Column, where they pushed the list instead
     * of covering it. Same two branches on the same two selectors, each moved onto its own
     * layer of the root Stack: a layout move only.
     */
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // Swift the toolbar: cancellationAction then primaryAction. An active `.searchable`
        // hides it (T-1196): iOS collapses the bar and shows Cancel beside the field.
        if (!this.isSearching) {
          Row() {
            Button($r('app.string.global_close'))
              .id('share_close_button')
              // The extension's `.accentColor` — its AccentColor asset.
              .type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .padding(0)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.jami_button_primary'))
              .constraintSize({ minHeight: NAV_BAR_HEIGHT })
              .onClick(() => {
                this.close();
              })

            Blank()

            // Swift `AccountNavigationButton` — the selected account, tapped to swap it.
            Row({ space: ACCOUNT_GAP }) {
              // Swift `AccountAvatarView(account:size: 30)`: photo, else the coloured monogram.
              AvatarSwiftUIView({
                avatarData: this.accountAvatar(),
                displayText: this.accountName(),
                avatarSize: ACCOUNT_AVATAR
              })

              // Swift `.font(.callout).foregroundColor(.primary).truncationMode(.middle)
              // .lineLimit(1).frame(maxWidth: 150)`.
              Text(this.accountName())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: ACCOUNT_NAME_MAX_WIDTH })
                .fontSize($r('sys.float.Body_M'))
                .fontColor($r('app.color.label'))

              // Swift `Image(systemName: "chevron.up.chevron.down")
              // .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)`.
              Column() {
                SymbolGlyph($r('sys.symbol.chevron_up'))
                  .fontSize(CHEVRON_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor([$r('app.color.secondary_label')])
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(CHEVRON_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor([$r('app.color.secondary_label')])
                  .margin({ top: CHEVRON_OVERLAP })
              }
            }
            .padding({ start: LengthMetrics.vp(ACCOUNT_INSET_H), end: LengthMetrics.vp(ACCOUNT_INSET_H) })
            .id('share_account_menu')
            .accessibilityText($r('app.string.share_extension_accessibility_select_account'))
            .onClick(() => {
              this.openAccountPicker();
            })
            // conditionalVariants[account_picker_open]: Swift `.sheet(isPresented:)`.
            .bindSheet($$this.isAccountPickerOpen, this.accountPickerSheet(),
              { detents: [SheetSize.LARGE], showClose: false })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .constraintSize({ minHeight: NAV_BAR_HEIGHT })
          .padding({ start: LengthMetrics.vp(PAGE_INSET), end: LengthMetrics.vp(PAGE_INSET) })
          .backgroundColor($r('sys.color.background_primary'))
          .border({ width: { bottom: HAIRLINE }, color: { bottom: $r('sys.color.comp_divider') } })
        }

        // Swift `.searchable(text: $searchText, prompt: …)` — UISearchBar: the rounded grey field
        // with its leading magnifier and xmark.circle.fill clear button, and Cancel beside it
        // while search is active.
        Row() {
          Search({
            value: this.searchText,
            placeholder: $r('app.string.share_extension_search_conversations'),
            controller: this.searchController
          })
            .id('share_conversation_search')
            .layoutWeight(1)
            .height(SEARCH_HEIGHT)
            .textFont({ size: $r('sys.float.Body_M') })
            .fontColor($r('app.color.label'))
            .placeholderColor($r('sys.color.font_tertiary'))
            .backgroundColor($r('sys.color.comp_background_gray'))
            .borderRadius(SEARCH_RADIUS)
            // UISearchBar's clear button is xmark.circle.fill in systemGray, shown while the
            // field has text.
            .cancelButton({
              style: CancelButtonStyle.INPUT,
              icon: new SymbolGlyphModifier($r('sys.symbol.xmark_circle_fill'))
                .fontColor([$r('sys.color.icon_secondary')])
            })
            .onChange((value: string) => {
              this.searchText = value;
              this.applyFilter();
            })
            // Search starts on focus and stays on when the keyboard closes, as UISearchBar.
            .onEditChange((editing: boolean) => {
              if (editing) {
                this.isSearching = true;
              }
            })

          if (this.isSearching) {
            Text($r('app.string.global_cancel'))
              .id('share_search_cancel')
              .fontSize($r('sys.float.Body_L'))
              // The extension's `.accentColor`, as Close.
              .fontColor($r('app.color.jami_button_primary'))
              .maxLines(1)
              .margin({ start: LengthMetrics.vp(SEARCH_CANCEL_GAP) })
              .onClick(() => {
                this.endSearch();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ start: LengthMetrics.vp(PAGE_INSET), end: LengthMetrics.vp(PAGE_INSET) })
        .margin({
          top: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s')),
          bottom: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
        })

        // Swift `LoadingStateView()` while the conversations are being read.
        if (this.isLoading) {
          // Swift `LoadingStateView()` — ProgressView at `.scaleEffect(1.5)`, centred.
          LoadingProgress()
            .id('share_loading_view')
            .width(LOADING_SIZE)
            .height(LOADING_SIZE)
            .color($r('sys.color.font_secondary'))
            .margin({ top: $r('sys.float.padding_level16') })
        }

        /*
         * Swift `ConversationSection` — the list and the two empty states are exclusive
         * branches of the same bound row set, so content never renders beside an empty state.
         */
        if (this.isNoConversations) {
          Column({ space: EMPTY_GAP }) {
            /*
             * Swift's leading `Image(systemName: "bubble.left.and.bubble.right")` is still
             * ABSENT. S5 re-checked the DevEco SDK's own symbol table: it carries no `bubble.*`
             * speech-bubble glyph at all (only `bubble_min_mum_height`, a layout constant), and
             * results/plan/icon-map.json's shortlist for this name holds radio-wave and
             * sweep glyphs — none of them a pair of speech bubbles. The decorative glyph stays
             * out rather than shipping the wrong meaning.
             */
            // Swift `.font(.body).fontWeight(.semibold).foregroundColor(.primary)`.
            Text($r('app.string.smartlist_no_conversation'))
              .fontWeight(FontWeight.Medium)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.label'))
              .textAlign(TextAlign.Center)
          }
          .id('share_no_conversations_view')
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({
            start: LengthMetrics.vp(PAGE_INSET),
            end: LengthMetrics.vp(PAGE_INSET),
            // Swift `.padding(.bottom, 80)` lifts the block off the vertical centre.
            bottom: LengthMetrics.vp(80)
          })
        } else if (this.isNoSearchResults) {
          Column({ space: EMPTY_GAP }) {
            // Swift `.font(.system(size: 48, weight: .light)).foregroundColor(.secondary)`.
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(EMPTY_GLYPH)
              .fontWeight(FontWeight.Lighter)
              .fontColor([$r('app.color.secondary_label')])

            // Swift `.font(.body).fontWeight(.semibold).foregroundColor(.secondary)`.
            Text($r('app.string.share_extension_no_search_results'))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.secondary_label'))

            // Swift `.font(.subheadline).foregroundColor(.secondary)`.
            Text($r('app.string.share_extension_try_different_filter'))
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.secondary_label'))
          }
          .id('share_no_search_results_view')
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .padding({ start: LengthMetrics.vp(PAGE_INSET), end: LengthMetrics.vp(PAGE_INSET) })
        } else {
          // Swift `ConversationScrollView` — one ConversationSelectableRow per conversation, in a
          // ScrollView + LazyVStack, so no row separators.
          List() {
            LazyForEach(this.rows, (row: ShareConversationRow) => {
              ListItem() {
                this.conversationRow(row)
              }
            }, (row: ShareConversationRow) => row.key())
          }
          .id('share_conversation_list')
          .width('100%')
          .layoutWeight(1)
        }

        // Swift `if shouldShowShareButton { ShareButtonView(...) }` —
        // conditionalVariants[has_selection]: absent without a selection, not disabled.
        if (this.hasSelection && !this.isSending) {
          ShareButtonView({
            selectedCount: this.selectedConversationIds.length,
            isSending: this.isSending,
            onSend: (): void => {
              this.sendSelected();
            }
          })
        }

        // The disclosed ceiling, in place, once a send has been attempted.
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .id('share_send_error')
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .padding({
              start: LengthMetrics.vp(PAGE_INSET),
              end: LengthMetrics.vp(PAGE_INSET),
              bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
            })
        }

      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      // A plain list on `systemBackground`, not the grouped grey page.
      .backgroundColor($r('sys.color.background_primary'))

      // Swift `if isSending { sendingOverlay() }` — conditionalVariants[sending].
      if (this.isSending) {
        /*
         * Swift `sendingOverlay()`: a full-bleed `Color.black.opacity(0.4)` carrying a
         * centred `ProgressView(L10n.ShareExtension.sending)` in white, on a
         * `RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.8))` card.
         */
        Column() {
          Column({ space: SENDING_GAP }) {
            LoadingProgress()
              .width(SENDING_RING)
              .height(SENDING_RING)
              // Swift `CircularProgressViewStyle(tint: .white)`.
              .color(Color.White)
            Text($r('app.string.share_extension_sending'))
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor(Color.White)
          }
          .alignItems(HorizontalAlign.Center)
          // Swift `.padding()` inside the card.
          .padding(PAGE_INSET)
          .backgroundColor(SENDING_CARD)
          .borderRadius(SENDING_CARD_RADIUS)
        }
        .id('share_sending_overlay')
        // Swift `.accessibilityLabel(Text(L10n.ShareExtension.sending))` on the card.
        .accessibilityText($r('app.string.share_extension_sending'))
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(SENDING_SCRIM)
      }

      // Swift `.alert(isPresented: $showUnsupportedAlert)` — conditionalVariants[unsupported].
      if (this.isUnsupported) {
        // Swift `.alert(isPresented: $showUnsupportedAlert)` — the iOS system alert card.
        Column() {
          Column() {
            Text($r('app.string.share_extension_unsupported_type_title'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_L'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.label'))
            Text($r('app.string.share_extension_unsupported_type_description'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_secondary'))
              .margin({ top: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
            Button($r('app.string.global_ok'))
              .id('share_unsupported_ok')
              .type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.jami_button_primary'))
              .width('100%')
              .constraintSize({ minHeight: ALERT_ACTION_HEIGHT })
              .margin({ top: $r('sys.float.padding_level4') })
              // Swift `dismissButton: .default(Text(L10n.Global.ok), action: closeAction)`.
              .onClick(() => {
                this.close();
              })
          }
          .width(ALERT_WIDTH)
          .padding(PAGE_INSET)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(ALERT_RADIUS)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(ALERT_SCRIM)
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_share_extension')
  }
}
