/*
 * screen_contact_picker — "Contact Picker", ported from
 *   Ring/Ring/Calls/ContactPicker/ContactPickerView.swift
 *   Ring/Ring/Calls/ContactPicker/ContactPickerViewModel.swift
 *
 * presentation: sheet, hostScreen: screen_conversation. NOT a routed page and NOT registered
 * in main_pages.json — ConversationsCoordinator.showContactPicker presents it as a .pageSheet,
 * so it is the content of the `.bindSheet()` ConversationChatPage already mounts.
 *
 * S3 — the real tree of `ContactPickerView.body`:
 *   NavigationView { ZStack { contentList; if isLoading { loadingOverlay } } }
 *     .searchable(text: $viewModel.searchText, prompt: L10n.Smartlist.searchBarPlaceholder)
 *     .toolbar { cancellationAction: Cancel
 *                primaryAction:      if type == .forConversation { Send } }
 *
 *   contentList = if hasNoResults { emptyStateView }
 *                 else switch type { .forCall: contactList; .forConversation: conversationList }
 *
 * Two ITEM TYPES, one per picker type, each with its own row component, its own row id and its
 * own tap effect (select-and-dismiss vs toggle-selection) — never one uniform row.
 * The captured state S0093 is the EMPTY branch (the daemon supplies no contacts), which is why
 * the empty state and the bound content are mutually exclusive `if`/`else` here.
 */
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag, BehaviorRelay } from '../common/Observable';
import { PresenceStatus } from '../common/PresenceService';
import { AvatarWithPresence } from '../components/AvatarWithPresence';
import { groupTitleFor } from '../components/ExpandableAvatar';
import { ContactPickerConversationRow, ContactRowView, PickerItem } from '../components/ContactRow';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';

/**
 * Swift `ContactPickerSection(header:items:)` — `buildContactSections` emits one ("Contacts")
 * today, but the header is part of the row set the view renders, so the section is modelled
 * rather than flattened away.
 */
export class PickerSection {
  /** A stable LazyForEach key: a Resource header cannot serve as one. */
  key: string;
  header: ResourceStr;
  items: ArrayDataSource<PickerItem>;

  constructor(key: string, header: ResourceStr, items: PickerItem[]) {
    this.key = key;
    this.header = header;
    this.items = new ArrayDataSource<PickerItem>(items);
  }
}

/** Swift `emptyStateView`: `Image(systemName: "magnifyingglass").font(.system(size: 48, weight: .light))`. */
const EMPTY_GLYPH_SIZE: number = 48;
/** Swift `.fontWeight(.semibold)` on "No results". */
const EMPTY_TITLE_WEIGHT: number = 600;
/** Swift `VStack(spacing: 16)`. */
const EMPTY_STACK_GAP: number = 16;
/** Capture S0093: the search field is `[16,126][377,162]` — 36vp tall, 16vp inset. */
const SEARCH_FIELD_HEIGHT: number = 36;
/** Replay dump: the field's text starts 39vp in from the Search box, past its leading glyph. */
const SEARCH_TEXT_INSET: number = 39;
/** UISearchBar's Cancel beside the active field (the smart list capture `[324,63][377,93]`). */
const SEARCH_CANCEL_GAP: number = 11;
/** Swift `loadingOverlay`'s `Color.black.opacity(0.08)` scrim behind the spinner card. */
const LOADING_SCRIM: string = '#14000000';
/** Swift `.opacity(viewModel.selectedConversationIds.isEmpty ? 0.35 : 1.0)` on Send. */
const DISABLED_OPACITY: number = 0.35;
/** Swift `pickerRowStyle()`: `.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))`. */
const ROW_INSET_V: number = 4;
/** Measured on the iPhone 4.20 / iOS 18 picker (T-1695): toolbar top inset, header size and top gap. */
const TOOLBAR_TOP: number = 8;
const HEADER_FONT_SIZE: number = 15;
const HEADER_TOP: number = 25;

@Component
export struct ContactPickerSheet {
  /** Owned by screen_conversation; the host's @State drives the sheet. */
  @Link isPresented: boolean;

  /**
   * Swift `var type: ContactPickerType` — set by whoever PRESENTS the picker (the call screen
   * picks `.forCall` to add a participant, the conversation `.forConversation` to forward).
   * A @Prop, so a host that flips it re-binds this sheet.
   */
  @Prop pickerForConversation: boolean = false;

  /** Swift `var contactSelectedCB: (([ConferencableItem]) -> Void)?`. */
  onContactSelected?: (item: PickerItem) => void;
  /** Swift `var conversationSelectedCB: (([String]) -> Void)?`. */
  onConversationsSelected?: (conversationIds: string[]) => void;

  /** Swift `@Published var searchText` — filters contactSections / conversations. */
  @State searchText: string = '';
  /**
   * `.searchable`'s `isSearching` (T-1730): from the field's first focus until its own Cancel.
   * iOS 18 then hides the toolbar and draws Cancel beside the field, which ends only the search.
   */
  @State isSearching: boolean = false;
  private searchController: SearchController = new SearchController();
  /**
   * The rows the picker is currently showing, whichever branch produced them. Swift read
   * `contactSections`/`conversations` directly in `hasNoResults`; one flat list keeps the two
   * item types' emptiness answerable in one place.
   */
  @State contactConversationPickerList: PickerItem[] = [];
  /** Swift `@Published var contactSections` <- svc_contacts. */
  @State contactSections: ArrayDataSource<PickerSection> =
    new ArrayDataSource<PickerSection>([]);
  /** Swift `@Published var conversations` <- svc_conversation_source. */
  @State conversations: ArrayDataSource<PickerItem> =
    new ArrayDataSource<PickerItem>([]);
  /** Swift `@Published var selectedConversationIds: Set<String>`. */
  @State selectedConversationIds: string[] = [];
  /** conditionalVariants[for_call]: `viewModel.type == .forCall` — contact sections only. */
  @State isForCall: boolean = true;
  /** conditionalVariants[for_conversation]: `viewModel.type == .forConversation`. */
  @State isForConversation: boolean = false;
  /** conditionalVariants[empty]: Swift `hasNoResults` — the captured state S0093. */
  @State isEmpty: boolean = false;
  /** Swift `@Published var isLoading: Bool = true`. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  /** Swift `private let disposeBag = DisposeBag()` + `cancellables`. */
  private bag: DisposeBag = new DisposeBag();
  /** Swift `private var unfilteredContactSections: [ContactPickerSection]`. */
  private unfilteredContactSections: PickerSection[] = [];
  /** Swift's `bindConversationSections` local `conversations`, kept for re-filtering. */
  private unfilteredConversations: PickerItem[] = [];
  /** Swift `SwarmInfo.conversation` behind each row, by `PickerItem.id`, for the search. */
  private conversationById: Map<string, ConversationModel> = new Map<string, ConversationModel>();

  /** Swift `func bind()` — the picker type picks which of the two binders runs. */
  aboutToAppear(): void {
    this.isForConversation = this.pickerForConversation;
    this.isForCall = !this.pickerForConversation;
    if (this.isForConversation) {
      this.bindConversationSections();
    } else {
      this.bindContactSections();
    }
  }

  aboutToDisappear(): void {
    this.bag.dispose();
  }

  /** Swift `bindContactSections()` — contacts relay -> sections -> filtered by searchText. */
  private bindContactSections(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(registry.contactsService.contacts.subscribe(
      (contacts: ContactModel[]): void => {
        this.unfilteredContactSections = this.buildContactSections(contacts);
        this.applyContactFilter();
        this.isLoading = false;
        this.refreshEmptiness();
      }));
  }

  /** Swift `buildContactSections(contacts:)` + `buildContactItems(from:)`. */
  private buildContactSections(contacts: ContactModel[]): PickerSection[] {
    const sections: PickerSection[] = [];
    const items: PickerItem[] = this.buildContactItems(contacts);
    if (items.length > 0) {
      sections.push(new PickerSection('contacts',
        $r('app.string.contact_picker_contacts'), items));
    }
    return sections;
  }

  /** Swift `buildContactItems(from:excluding:)` — one item per contact with a URI. */
  private buildContactItems(contacts: ContactModel[]): PickerItem[] {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.currentAccount;
    if (account === null) {
      // Swift `guard let currentAccount ... else { return [] }`.
      return [];
    }
    const items: PickerItem[] = [];
    for (const contact of contacts) {
      const uri: string | null = contact.uriString;
      if (uri === null || uri.length === 0) {
        continue;
      }
      const item: PickerItem = new PickerItem();
      item.id = uri;
      const registered: string | null = contact.userName;
      item.displayName = registered === null || registered.length === 0
        ? contact.hash : registered;
      item.isGroup = false;
      item.isSingleContact = true;
      item.presence = this.presenceFor(contact.hash);
      this.trackProfile(item, uri, account.id);
      items.push(item);
    }
    return items;
  }

  /** Swift `bindConversationSections()` — SwarmInfo per conversation + its avatar/presence. */
  private bindConversationSections(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.currentAccount;
    const conversations: ConversationModel[] = registry.conversationsService.conversations.value;
    const items: PickerItem[] = [];
    this.conversationById.clear();
    for (const conversation of conversations) {
      const item: PickerItem = new PickerItem();
      item.id = conversation.id.length > 0 ? conversation.id : conversation.hash;
      this.conversationById.set(item.id, conversation);
      const participants: ConversationParticipant[] = conversation.getParticipants();
      item.displayName = this.conversationTitle(conversation, participants, item.id);
      item.isGroup = !conversation.isCoredialog();
      item.isSingleContact = !item.isGroup;
      // Swift: a presence tracker exists only for a coredialog's non-local participant.
      if (conversation.isCoredialog() && participants.length > 0) {
        item.presence = this.presenceFor(participants[0].jamiId);
        if (account !== null && participants[0].jamiId.length > 0) {
          this.trackProfile(item, participants[0].jamiId, account.id);
        }
      }
      items.push(item);
    }
    this.unfilteredConversations = items;
    this.isLoading = false;
    this.applyConversationFilter();
  }

  /**
   * Swift `SwarmInfo.title`: the swarm's own title; an untitled group is named after its members
   * ("<peer>, <me> (You)"); a dialog after its peer's registered name, else its jami id (the
   * profile alias, when there is one, replaces it in trackProfile). The conversation id was shown.
   */
  private conversationTitle(conversation: ConversationModel, participants: ConversationParticipant[],
    fallback: string): string {
    if (conversation.title.length > 0) {
      return conversation.title;
    }
    if (!conversation.isCoredialog()) {
      const members: string = groupTitleFor(conversation,
        getContext(this).resourceManager.getStringByNameSync('conversation_yourself'));
      return members.length > 0 ? members : fallback;
    }
    if (participants.length === 0) {
      return fallback;
    }
    const contact: ContactModel | null = ServiceRegistry.shared().contactsService.contact(participants[0].jamiId);
    return contact !== null && contact.userName !== null && contact.userName.length > 0
      ? contact.userName : participants[0].jamiId;
  }

  /** Swift `PresenceTracker(jamiId:presenceService:)` — the relay's current value plus updates. */
  private presenceFor(jamiId: string): PresenceStatus {
    const relay: BehaviorRelay<PresenceStatus> | null =
      ServiceRegistry.shared().presenceService.getSubscriptionsForContact(jamiId);
    return relay === null ? PresenceStatus.OFFLINE : relay.value;
  }

  /** Swift `AvatarProvider(profileService:...)` — the row's avatar and display name. */
  private trackProfile(item: PickerItem, uri: string, accountId: string): void {
    this.bag.add(ServiceRegistry.shared().profileService.getProfile(uri, accountId)
      .subscribe((profile: Profile): void => {
        const photo: string | null = profile.photo;
        if (photo !== null) {
          item.avatar = photo;
        }
        const alias: string | null = profile.alias;
        if (alias !== null && alias.trim().length > 0) {
          item.displayName = alias.trim();
        }
      }));
  }

  /** Swift `filterContactSections(_:query:)`. */
  private applyContactFilter(): void {
    const query: string = this.searchText.toLowerCase();
    const filtered: PickerSection[] = [];
    const flat: PickerItem[] = [];
    for (const section of this.unfilteredContactSections) {
      const kept: PickerItem[] = [];
      const total: number = section.items.totalCount();
      for (let index: number = 0; index < total; index++) {
        const item: PickerItem = section.items.getData(index);
        if (query.length === 0 || item.displayName.toLowerCase().includes(query) ||
          item.id.toLowerCase().includes(query)) {
          kept.push(item);
        }
      }
      if (kept.length > 0) {
        // The key carries the kept ids: LazyForEach reuses a group whose key is unchanged, so
        // with the bare section key the rows never followed the search text.
        filtered.push(new PickerSection(`${section.key}|${kept.map((item: PickerItem) => item.id).join(',')}`,
          section.header, kept));
        for (const item of kept) {
          flat.push(item);
        }
      }
    }
    this.contactSections.reload(filtered);
    this.contactConversationPickerList = flat;
    this.refreshEmptiness();
  }

  /** Swift `filterConversations(_:query:)` — `SwarmInfo.contains(searchQuery:)`. */
  private applyConversationFilter(): void {
    const query: string = this.searchText.toLowerCase();
    const kept: PickerItem[] = [];
    for (const item of this.unfilteredConversations) {
      if (query.length === 0 || this.conversationMatches(item, query)) {
        kept.push(item);
      }
    }
    this.conversations.reload(kept);
    this.contactConversationPickerList = kept;
    this.refreshEmptiness();
  }

  /**
   * Swift `SwarmInfo.contains(searchQuery:)`: the title, or any non-local member's registered
   * name, profile name or jami id — the same rule as SmartListSearchResultsPage.matches.
   */
  private conversationMatches(item: PickerItem, query: string): boolean {
    if (item.displayName.toLowerCase().includes(query)) {
      return true;
    }
    const conversation: ConversationModel | undefined = this.conversationById.get(item.id);
    if (conversation === undefined) {
      return false;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
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

  /** Swift `var hasNoResults` — never true while the picker is still loading. */
  private refreshEmptiness(): void {
    this.isEmpty = !this.isLoading && this.contactConversationPickerList.length === 0;
  }

  /** Swift's `$searchText.removeDuplicates().dropFirst().sink { ... }`. */
  private onSearchChanged(value: string): void {
    this.searchText = value;
    if (this.isForConversation) {
      this.applyConversationFilter();
    } else {
      this.applyContactFilter();
    }
  }

  /** Swift `viewModel.isSearchActive` — drives the second line of the empty state. */
  private isSearchActive(): boolean {
    return this.searchText.length > 0;
  }

  /** Swift: the Cancel toolbar item — dismisses the sheet (an overlay is not a stack entry). */
  private cancel(): void {
    this.isPresented = false;
  }

  /** The search field's Cancel: clears the query and closes the keyboard, the picker stays. */
  private endSearch(): void {
    this.searchController.stopEditing();
    this.onSearchChanged('');
    this.isSearching = false;
  }

  /** Swift `viewModel.selectContact(item)` then `presentationMode.dismiss()`. */
  private selectContact(item: PickerItem): void {
    const callback: ((item: PickerItem) => void) | undefined = this.onContactSelected;
    if (callback !== undefined) {
      callback(item);
    }
    this.isPresented = false;
  }

  /** Swift `viewModel.toggleConversationSelection(id)` — no dismissal, this row toggles. */
  private toggleConversation(item: PickerItem): void {
    const index: number = this.selectedConversationIds.indexOf(item.id);
    if (index >= 0) {
      this.selectedConversationIds.splice(index, 1);
    } else {
      this.selectedConversationIds.push(item.id);
    }
    // ponytail: ContactPickerConversationRow.isSelected is a plain field (set once), so the
    // row is keyed on its selection and the list reloaded to rebuild it; @Prop there is cleaner.
    const shown: PickerItem[] = [];
    for (let i = 0; i < this.conversations.totalCount(); i++) {
      shown.push(this.conversations.getData(i));
    }
    this.conversations.reload(shown);
  }

  /** Swift `viewModel.confirmConversationSelection()` then dismiss — the host forwards. */
  private sendMessage(): void {
    const callback: ((ids: string[]) => void) | undefined = this.onConversationsSelected;
    if (callback !== undefined) {
      callback(this.selectedConversationIds);
    }
    this.isPresented = false;
  }

  /** Swift `emptyStateView` — magnifyingglass + "No results" (+ the search-only second line). */
  @Builder
  private emptyState() {
    // S5 — capture S0093: a light 48pt magnifier in `.secondary` over a semibold `.body`
    // "No results", the pair centred in the content area with 16pt between them.
    Column({ space: EMPTY_STACK_GAP }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(EMPTY_GLYPH_SIZE)
        // Swift `.weight(.light)`.
        .fontWeight(FontWeight.Lighter)
        .fontColor([$r('app.color.secondary_label')])
      Text($r('app.string.smartlist_no_results'))
        .fontSize($r('sys.float.Body_L'))
        // Swift `.fontWeight(.semibold)`; FontWeight.Medium is 500 (T-1470).
        .fontWeight(EMPTY_TITLE_WEIGHT)
        // Swift `.foregroundColor(viewModel.isSearchActive ? .secondary : .primary)`.
        .fontColor(this.isSearchActive()
          ? $r('app.color.secondary_label')
          : $r('app.color.label'))
      if (this.isSearchActive()) {
        Text($r('app.string.smartlist_no_conversations_found'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    // Swift's leading/trailing `Spacer()` pair — the block sits in the middle of the area.
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // Swift `.padding(.horizontal)`.
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    })
  }

  /**
   * comp_avatar_with_presence — Swift `AvatarWithPresence(avatarSource:presenceTracker:)`, the
   * avatar every picker row carries, with svc_presence's dot on its bottom-trailing corner.
   */
  @Builder
  private pickerAvatar(item: PickerItem) {
    AvatarWithPresence({
      avatarData: item.avatar,
      displayName: item.displayName,
      isGroup: item.isGroup,
      presence: item.presence
    })
  }

  /** Swift `contactList` — sections with a header, rows selecting a contact. */
  @Builder
  private contactList() {
    List() {
      LazyForEach(this.contactSections, (section: PickerSection) => {
        ListItemGroup({ header: this.sectionHeader(section.header) }) {
          LazyForEach(section.items, (item: PickerItem) => {
            ListItem() {
              ContactRowView({
                item: item,
                avatarBuilder: (): void => {
                  this.pickerAvatar(item)
                }
              })
            }
            .id('contact_picker_contact_itemroot')
            .padding({ top: ROW_INSET_V, bottom: ROW_INSET_V })
            .onClick(() => {
              this.selectContact(item);
            })
          }, (item: PickerItem) => item.id)
        }
      }, (section: PickerSection) => section.key)
    }
    // Swift `.listStyle(.plain)` — white, edge-to-edge rows, no grouped card chrome.
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .divider({
      strokeWidth: 0.5,
      color: $r('sys.color.comp_divider'),
      startMargin: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  @Builder
  private sectionHeader(header: ResourceStr) {
    // iOS plain-List section header: gray caption indented to the rows' content edge.
    Text(header)
      .width('100%')
      // iPhone 4.20 / iOS 18 plain-List header: semibold 15 pt, cap 45 pt under the search field.
      .fontSize(HEADER_FONT_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.secondary_label'))
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        top: LengthMetrics.vp(HEADER_TOP),
        bottom: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
      })
      .backgroundColor($r('sys.color.background_primary'))
  }

  /** Swift `conversationList` — rows toggling their id in the selection. */
  @Builder
  private conversationList() {
    List() {
      LazyForEach(this.conversations, (item: PickerItem) => {
        ListItem() {
          ContactPickerConversationRow({
            item: item,
            avatarBuilder: (): void => {
              this.pickerAvatar(item)
            },
            isSelected: this.selectedConversationIds.indexOf(item.id) >= 0
          })
        }
        .id('contact_picker_conversation_itemroot')
        .padding({ top: ROW_INSET_V, bottom: ROW_INSET_V })
        .onClick(() => {
          this.toggleConversation(item);
        })
      }, (item: PickerItem) => item.id + (this.selectedConversationIds.indexOf(item.id) >= 0 ? '#1' : '#0'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .divider({
      strokeWidth: 0.5,
      color: $r('sys.color.comp_divider'),
      startMargin: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  build() {
    Column() {
      // Swift `.toolbar { cancellationAction / primaryAction }`, and `.accentColor(.jami)` on
      // the whole picker — capture S0093: `Cancel` at `[15,83]`, `Send` at `[328,83]`, both
      // plain text bar-buttons on the white sheet, not filled capsules.
      // T-1730: an active search hides this bar (iOS 18 collapses the toolbar).
      if (!this.isSearching) {
        Row() {
          Button($r('app.string.global_cancel'))
            .id('contact_picker_cancel')
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
            .padding(0)
            .onClick(() => {
              this.cancel();
            })

          Blank()

          // Swift: the Send item exists ONLY for .forConversation.
          if (this.isForConversation) {
            Button($r('app.string.data_transfer_send_message'))
              .id('contact_picker_send_message')
              .type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .fontSize($r('sys.float.Body_L'))
              // Swift `.font(.body.weight(.semibold))`.
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.jami'))
              .padding(0)
              // Swift `.opacity(selectedConversationIds.isEmpty ? 0.35 : 1.0)` — capture S0093
              // shows the greyed-out `Send`, which is this opacity, not a second colour.
              .opacity(this.selectedConversationIds.length > 0 ? 1.0 : DISABLED_OPACITY)
              // Swift `.disabled(viewModel.selectedConversationIds.isEmpty)`.
              .enabled(this.selectedConversationIds.length > 0)
              .onClick(() => {
                this.sendMessage();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          // iPhone 4.20 picker (T-1695 review): Cancel cap 22 pt and the field 57 pt below the sheet top.
          top: LengthMetrics.vp(TOOLBAR_TOP),
          bottom: LengthMetrics.vp(0)
        })
      }

      // Swift `.searchable(text:prompt:)` — the SOURCE gives the field no identifier, so the
      // slug is the capture's (batch brief), and the prompt is L10n.Smartlist.searchBarPlaceholder.
      // Capture S0093: a gray rounded pill inset 16vp, 36vp tall, leading magnifier.
      // The prompt is rendered as a REAL Text over the field rather than as the Search's own
      // `placeholder`: ArkUI does not emit a placeholder as a text node in the uitest dump, so
      // the string the user actually sees ("Enter name…") was invisible to the state contract.
      // Same string resource, same size/colour as the placeholder it replaces.
      Row() {
        Stack({ alignContent: Alignment.Start }) {
          Search({ value: this.searchText, controller: this.searchController })
            .id('contact_picker_search')
            .width('100%')
            .height(SEARCH_FIELD_HEIGHT)
            .backgroundColor($r('sys.color.comp_background_gray'))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            .textFont({ size: $r('sys.float.Body_L') })
            // UISearchBar's clear button is xmark.circle.fill in systemGray while the field has
            // text, not ArkUI's bare cross (T-1470; as ShareExtensionPage).
            .cancelButton({
              style: CancelButtonStyle.INPUT,
              icon: new SymbolGlyphModifier($r('sys.symbol.xmark_circle_fill'))
                .fontColor([$r('sys.color.icon_secondary')])
            })
            .onChange((value: string) => {
              this.onSearchChanged(value);
            })
            // Search starts on focus and stays on when the keyboard closes, as UISearchBar.
            .onEditChange((editing: boolean) => {
              if (editing) {
                this.isSearching = true;
              }
            })

          if (this.searchText.length === 0) {
            Text($r('app.string.smartlist_search_bar_placeholder'))
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.secondary_label'))
              .padding({ start: LengthMetrics.vp(SEARCH_TEXT_INSET) })
              // Non-interactive: taps fall through to the field underneath.
              .hitTestBehavior(HitTestMode.Transparent)
          }
        }
        .layoutWeight(1)

        // T-1730: iOS 18's search Cancel, beside the field while searching; it ends the search
        // only. The picker's own Cancel is the toolbar one above.
        if (this.isSearching) {
          Text($r('app.string.global_cancel'))
            .id('contact_picker_search_cancel')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
            .maxLines(1)
            .margin({ start: LengthMetrics.vp(SEARCH_CANCEL_GAP) })
            .onClick(() => {
              this.endSearch();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // Padding, not margin: a 100%-wide row with side margins overflows, and the field ran
      // edge to edge instead of the iPhone's 16 pt inset.
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .margin({
        // With the toolbar gone the field moves up to just under the sheet's top edge.
        top: this.isSearching ? LengthMetrics.resource($r('sys.float.padding_level4')) : LengthMetrics.vp(0),
        bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
      })

      // Swift `ZStack { contentList; if viewModel.isLoading { loadingOverlay } }`.
      Stack() {
        if (this.isEmpty) {
          this.emptyState()
        } else if (this.isForCall) {
          this.contactList()
        } else if (this.isForConversation) {
          this.conversationList()
        }

        if (this.isLoading) {
          // Swift `loadingOverlay`: a ProgressView on a 12 pt rounded systemBackground card
          // over a black 8% scrim. S6 — the scrim is what makes the list read as BUSY rather
          // than as a spinner floating over live rows; without it the loading state is
          // indistinguishable from the loaded one.
          Column() {
            LoadingProgress()
              .width(EMPTY_GLYPH_SIZE)
              .height(EMPTY_GLYPH_SIZE)
              .color($r('app.color.jami'))
              .padding($r('sys.float.margin_level2'))
              .backgroundColor($r('sys.color.background_primary'))
              .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(LOADING_SCRIM)
        }
      }
      .layoutWeight(1)
      .width('100%')

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
    // Swift `.background(Color(.systemBackground))` on the picker's own ZStack.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_contact_picker')
  }
}
