/*
 * Ported from Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/ConversationDataSource.swift
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * WHAT THIS IS
 * The smart list's row set. It watches the conversation list `ConversationsService` keeps,
 * turns each `ConversationModel` into a row view model, and holds the conversations of banned
 * contacts aside so they leave the list without being forgotten - so that unbanning a contact
 * puts its conversation back where it was rather than rebuilding it.
 *
 * HOW IT IS BUILT
 * `ServiceRegistry` does NOT vend this: Swift builds one per smart-list screen, from the
 * injection bag, and a second smart list would want its own. So a page owns it:
 *
 *     private source: ConversationDataSource = new ConversationDataSource();
 *     aboutToAppear() { this.source.start(); }
 *     aboutToDisappear() { this.source.stop(); }
 *
 * The Swift `init(with injectionBag:)` subscribed to four streams. Those subscriptions live in
 * `start()` instead, because the registry contract forbids reading `ServiceRegistry.shared()`
 * from a constructor (the import cycle registry -> service -> registry is only safe while
 * nothing runs during module evaluation). `injectionBag` and the three service fields are
 * getters onto the registry for the same reason.
 *
 * HOW IT RELATES TO ArrayDataSource
 * `conversationViewModels` is the array, exactly as in Swift. `dataSource` is the SAME array
 * wrapped in the shared `ArrayDataSource<T>` so a page can `LazyForEach(this.source.dataSource, ...)`.
 * It is not a second data-source abstraction: every write to `conversationViewModels` goes
 * through `publish()`, which reloads that one wrapper and is what tells `LazyForEach` to redraw.
 *
 * THE DAEMON
 * Nothing here talks to the jami daemon, so nothing here reports a daemon gap. Every
 * conversation this class shows comes from `ConversationsService.conversations`, and it is
 * that service that reports the gap and leaves the relay empty. An empty smart list with no
 * daemon is the honest result of this class working correctly - it never invents a row.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArrayDataSource } from './ArrayDataSource';
import { DisposeBag } from './Observable';
import { ServiceRegistry } from './ServiceRegistry';
import { AccountsService } from './AccountsService';
import { ContactsService } from './ContactsService';
import { ConversationsService } from './ConversationsService';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { conversationTimestamp, MessageModel, MessageType } from '../model/MessageModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ConversationDataSource';

/** String resource the smart list renders in place of a deleted last message. */
export const LAST_MESSAGE_DELETED_RESOURCE: string = 'conversation_last_message_deleted';

/**
 * One row of the smart list.
 *
 * Swift's `ConversationViewModel` (Ring/Ring/Features/Conversations/Conversation/ConversationViewModel.swift,
 * 1003 lines) is the chat screen's whole view model - calls, location sharing, file transfer,
 * message forwarding, collaborative documents - and the migration plan gives it no module of
 * its own. What the smart list actually binds to is the handful of values below
 * (`bindingContract.itemFields`: title, lastMessage, avatar, unreadCount, timestamp), so that
 * is what this carries. The chat behaviour belongs to the chat screen, not to a list row.
 *
 * Everything is derived from `conversation` rather than cached, so a row cannot drift from the
 * model the service updated.
 */
export class ConversationViewModel {
  /** Swift `var conversation: ConversationModel!` - assign through `setConversation`. */
  conversation: ConversationModel | null = null;

  /** Swift `@Published var isBlocked`. Refreshed by `updateBlockedStatus()`. */
  isBlocked: boolean = false;

  /**
   * Swift set `conversation` directly and let `didSet` re-read everything. ArkTS has no
   * property observer, so the assignment is a method and the refresh is explicit.
   */
  setConversation(conversation: ConversationModel | null): void {
    this.conversation = conversation;
    this.updateBlockedStatus();
  }

  /**
   * Stable identity for `LazyForEach`'s key function. A non-swarm conversation has no id
   * until the daemon assigns one, so the first participant stands in for it.
   */
  get key(): string {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return '';
    }
    if (conversation.id.length > 0) {
      return `${conversation.accountId}|${conversation.id}`;
    }
    return `${conversation.accountId}|${this.firstParticipantJamiId()}`;
  }

  /** Row title. Swift took `bestName`; `title` is what the model carries for both kinds. */
  get title(): string {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return '';
    }
    if (conversation.title.length > 0) {
      return conversation.title;
    }
    return conversation.hash.length > 0 ? conversation.hash : this.firstParticipantJamiId();
  }

  /**
   * Row subtitle: the last message's text. Empty while the conversation has no messages.
   * Swift `ConversationRowVM.showLastMessage`: an incoming member event shows its generated
   * line ("<name> has joined…") named the way the chat names it (memberEventName); an
   * outgoing one shows `content`, which the source leaves empty.
   */
  get lastMessage(): string {
    const message: MessageModel | null = this.lastMessageModel();
    const conversation: ConversationModel | null = this.conversation;
    if (message === null || conversation === null || message.isMessageDeleted()) {
      return '';
    }
    if (message.type !== MessageType.CONTACT || !message.incoming) {
      return message.content;
    }
    const jamiId: string = message.uri.length > 0 ? message.uri : message.authorId;
    return message.getContactInteractionString(memberEventName(jamiId, conversation.accountId)) ?? '';
  }

  /**
   * True when the last message was deleted. Swift substituted
   * `L10n.Conversation.lastMessageDeleted` here; a .ts module cannot resolve an app string
   * (no `getContext()`), so the row renders `$r('app.string.conversation_last_message_deleted')`
   * on this flag instead of this module taking a second ResourceManager injector.
   */
  get lastMessageDeleted(): boolean {
    const message: MessageModel | null = this.lastMessageModel();
    return message !== null && message.isMessageDeleted();
  }

  /** Row timestamp: Swift `MessagesListVM` sets it from `receivedDate.conversationTimestamp()`. */
  get lastMessageDate(): string {
    const message: MessageModel | null = this.lastMessageModel();
    return message === null ? '' : conversationTimestamp(message.receivedDate);
  }

  /** Raw date, for sorting or an accessibility label. `null` while there are no messages. */
  get lastMessageTime(): Date | null {
    const message: MessageModel | null = this.lastMessageModel();
    return message === null ? null : message.receivedDate;
  }

  /** The conversation's own avatar; a page may still prefer the profile from `svc_profiles`. */
  get avatar(): string {
    return this.conversation === null ? '' : this.conversation.avatar;
  }

  /**
   * Unread badge. Swift added the unread collaborative-document count to this
   * (`ConversationViewModel.subscribeUnreadDocuments`); that half needs `CollaborationService`
   * and is left to the chat screen - see the module report.
   */
  get unreadCount(): number {
    return this.conversation === null ? 0 : this.conversation.numberOfUnreadMessages.value;
  }

  /**
   * Swift `isConversationForBlockedContact()` - re-read, then published on `isBlocked`. Swift
   * gates on `isDialog()` (at most 2 participants, self included), so the physical iPhone marks
   * a 2-member group with a banned peer as blocked while a 3+ member group never is (T-1568).
   */
  updateBlockedStatus(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || !conversation.isDialog()) {
      this.isBlocked = false;
      return;
    }
    const jamiId: string = this.firstParticipantJamiId();
    if (jamiId.length === 0) {
      this.isBlocked = false;
      return;
    }
    const contact: ContactModel | null = findContact(jamiId);
    this.isBlocked = contact !== null && contact.banned;
  }

  /** Swift `isCoreConversationWith(jamiId:)`. */
  isCoreConversationWith(jamiId: string): boolean {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || !conversation.isCoredialog()) {
      return false;
    }
    return this.firstParticipantJamiId() === jamiId;
  }

  /** Swift `static func == ` - two row models are the same when their conversations are. */
  isFor(conversation: ConversationModel): boolean {
    return this.conversation !== null && this.conversation.equals(conversation);
  }

  private firstParticipantJamiId(): string {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return '';
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    return participants.length > 0 ? participants[0].jamiId : '';
  }

  private lastMessageModel(): MessageModel | null {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return null;
    }
    if (conversation.lastMessage !== null) {
      return conversation.lastMessage;
    }
    const messages: MessageModel[] = conversation.messages;
    return messages.length > 0 ? messages[messages.length - 1] : null;
  }
}

/**
 * Swift `ContactsService.contact(withHash:)`, which is itself
 * `contacts.value.filter { $0.hash == hash }.first`. Read off the relay rather than through
 * the service method: the relay's name is fixed by the module contract, the method's ArkTS
 * spelling is not, and `ContactsService` is generated in the same wave as this file.
 */
function findContact(hash: string): ContactModel | null {
  const contacts: ContactModel[] = ServiceRegistry.shared().contactsService.contacts.value;
  for (const contact of contacts) {
    if (contact.hash === hash) {
      return contact;
    }
  }
  return null;
}

/**
 * Swift `MessagesListVM.getName` -> `getInformationForContact` / `nameLookup`: the name a
 * member line ("<name> was invited…") and its home preview give the member. A contact: the
 * profile alias, else the registered name, else the Jami ID. Anyone else is never named by a
 * vCard, only by the registered name a lookup found, else the Jami ID (T-1625).
 */
export function memberEventName(jamiId: string, accountId: string): string {
  const registry: ServiceRegistry = ServiceRegistry.shared();
  const contact: ContactModel | null = findContact(jamiId);
  if (contact !== null) {
    const alias: string | null = registry.profileService.getProfile(jamiId, accountId).value.alias;
    if (alias !== null && alias.length > 0) {
      return alias;
    }
  }
  const registered: string = contact !== null && contact.userName !== null &&
    contact.userName.length > 0 ? contact.userName : registry.nameService.cachedName(jamiId) ?? '';
  return registered.length > 0 ? registered : jamiId;
}

export class ConversationDataSource {
  /**
   * The smart list's own source, set while its page is alive. Swift's coordinator hands that
   * one source to the search model too (`JamiSearchViewModel(source:)`), so search shows the
   * smart list's very rows, blocked flags included (T-1603).
   */
  static smartList: ConversationDataSource | null = null;

  /** Swift `@Published var conversationViewModels`. The rows the smart list shows. */
  conversationViewModels: ConversationViewModel[] = [];

  /** Swift `var blockedConversation` - out of the list, not thrown away. */
  blockedConversation: ConversationViewModel[] = [];

  /** Swift `var disposeBag` - holds the four subscriptions `start()` opens. */
  disposeBag: DisposeBag = new DisposeBag();

  /**
   * `conversationViewModels` wrapped for `LazyForEach`. Never assigned a different array:
   * `publish()` reloads it in place, which is what notifies the list.
   */
  readonly dataSource: ArrayDataSource<ConversationViewModel> =
    new ArrayDataSource<ConversationViewModel>([]);

  /** Swift `var onNewConversationViewModelCreated: ((ConversationModel) -> Void)?`. */
  onNewConversationViewModelCreated: ((conversation: ConversationModel) => void) | null = null;

  /** Swift `var onConversationRestored: ((ConversationModel) -> Void)?`. */
  onConversationRestored: ((conversation: ConversationModel) => void) | null = null;

  /** Swift `var getTemporaryConversation: ((ConversationModel) -> ConversationViewModel?)?`. */
  getTemporaryConversation: ((conversation: ConversationModel) => ConversationViewModel | null) | null = null;

  private started: boolean = false;

  /** Swift `let injectionBag: InjectionBag`. A getter, per the registry contract. */
  get injectionBag(): ServiceRegistry {
    return ServiceRegistry.shared();
  }

  /** Swift `let conversationsService: ConversationsService`. */
  get conversationsService(): ConversationsService {
    return ServiceRegistry.shared().conversationsService;
  }

  /** Swift `let contactsService: ContactsService`. */
  get contactsService(): ContactsService {
    return ServiceRegistry.shared().contactsService;
  }

  /** Swift `let accountsService: AccountsService`. */
  get accountsService(): AccountsService {
    return ServiceRegistry.shared().accountService;
  }

  /**
   * The body of Swift's `init(with injectionBag:)`, moved out of the constructor. Idempotent,
   * so a page that re-appears does not open a second set of subscriptions.
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.subscribeToConversations();
    this.subscribeToConversationRemovals();
    this.observeContactAdded();
    this.observeContactRemoved();
  }

  /** Swift relied on ARC releasing the DisposeBag; an ArkUI page calls this from `aboutToDisappear`. */
  stop(): void {
    try {
      this.disposeBag.dispose();
    } finally {
      this.started = false;
    }
  }

  /**
   * Swift subscribed to `conversationsService.conversations`, mapped on a background queue and
   * assigned on the main one. ArkTS UI code is already on the UI thread and the mapping is a
   * list walk, so the scheduler hops have no counterpart; the subscription itself is the same.
   */
  private subscribeToConversations(): void {
    const dispose: () => void = this.conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        this.conversationViewModels = this.mapConversationsToViewModels(conversations);
        this.publish();
      });
    this.disposeBag.add(dispose);
  }

  /** Swift `mapConversationsToViewModels` - a compactMap that also partitions off the blocked. */
  private mapConversationsToViewModels(conversations: ConversationModel[]): ConversationViewModel[] {
    const mapped: ConversationViewModel[] = [];
    for (const conversationModel of conversations) {
      const isBlocked: boolean = this.isConversationWithBlockedContact(conversationModel);
      const newViewModel: ConversationViewModel | null =
        this.createOrRetrieveViewModel(conversationModel, isBlocked);
      if (newViewModel === null) {
        continue;
      }
      if (isBlocked) {
        newViewModel.updateBlockedStatus();
        // Swift appended unconditionally. This relay re-emits the whole list on every change,
        // and a blocked row is never in `conversationViewModels` to be found again, so an
        // unconditional append grows `blockedConversation` without bound.
        if (!this.isAlreadyBlocked(newViewModel)) {
          this.blockedConversation.push(newViewModel);
        }
        continue;
      }
      const created: ((conversation: ConversationModel) => void) | null =
        this.onNewConversationViewModelCreated;
      if (created !== null) {
        created(conversationModel);
      }
      mapped.push(newViewModel);
    }
    return mapped;
  }

  /**
   * Swift `createOrRetrieveViewModel(for:isBlocked:)`. Four ways to get a row, in order: one
   * already on screen, one coming back from the blocked list, the temporary row the search
   * field made, or a new one.
   */
  private createOrRetrieveViewModel(conversationModel: ConversationModel,
    isBlocked: boolean): ConversationViewModel | null {
    for (const viewModel of this.conversationViewModels) {
      if (viewModel.isFor(conversationModel)) {
        return viewModel;
      }
    }

    // Only a one-to-one takes back a blocked row. Swift tried any conversation by its first
    // member, so a group with that peer that had no row yet (a source started while the peer
    // was blocked, as search's was) took the blocked one-to-one's row and left the list (T-1603).
    if (!isBlocked && conversationModel.isCoredialog()) {
      const participants: ConversationParticipant[] = conversationModel.getParticipants();
      if (participants.length > 0) {
        const jamiId: string = participants[0].jamiId;
        const restored: ConversationViewModel | null = this.restoreBlockedConversation(jamiId);
        if (restored !== null) {
          return restored;
        }
      }
    }

    const temporary: ((conversation: ConversationModel) => ConversationViewModel | null) | null =
      this.getTemporaryConversation;
    if (temporary !== null) {
      const tempConversation: ConversationViewModel | null = temporary(conversationModel);
      if (tempConversation !== null) {
        tempConversation.setConversation(conversationModel);
        return tempConversation;
      }
    }

    const newViewModel: ConversationViewModel = new ConversationViewModel();
    newViewModel.setConversation(conversationModel);
    return newViewModel;
  }

  /**
   * Swift `restoreBlockedConversation(jamiId:)` - takes the row out of the blocked list, makes
   * it re-read its conversation (Swift reset the property to fire `didSet`), and announces it.
   */
  restoreBlockedConversation(jamiId: string): ConversationViewModel | null {
    let blockedIndex: number = -1;
    for (let index: number = 0; index < this.blockedConversation.length; index++) {
      if (this.blockedConversation[index].isCoreConversationWith(jamiId)) {
        blockedIndex = index;
        break;
      }
    }
    if (blockedIndex < 0) {
      return null;
    }
    const viewModel: ConversationViewModel = this.blockedConversation[blockedIndex];
    this.blockedConversation.splice(blockedIndex, 1);

    const conversation: ConversationModel | null = viewModel.conversation;
    viewModel.setConversation(conversation);

    const restored: ((conversation: ConversationModel) => void) | null = this.onConversationRestored;
    if (restored !== null && conversation !== null) {
      restored(conversation);
    }
    return viewModel;
  }

  /**
   * Swift `observeContactAdded()`. Swift filtered `ContactsService.sharedResponseStream` for
   * `.contactAdded`; that stream carries `ServiceEvent`, a type no module in the plan owns
   * (eleven services declare it and none is its home - reported to the orchestrator). The
   * `contacts` relay is the same service's own record of the same fact and its name IS fixed
   * by the module contract, so the trigger is read from there: a contact that is present and
   * not banned is a contact whose conversation may come back out of the blocked list.
   * `restoreConversation` returns at once for anything not actually blocked.
   */
  private observeContactAdded(): void {
    const dispose: () => void = this.contactsService.contacts.subscribe(
      (contacts: ContactModel[]): void => {
        const accountId: string = this.currentAccountId();
        if (accountId.length === 0) {
          return;
        }
        for (const contact of contacts) {
          if (!contact.banned) {
            this.restoreConversation(contact.hash, accountId);
          }
        }
      });
    this.disposeBag.add(dispose);
  }

  /**
   * Swift `restoreConversation(jamiId:accountId:)` - puts a restored row back at the position
   * its conversation holds in the service's ordering, so the list does not jump.
   */
  private restoreConversation(jamiId: string, accountId: string): void {
    const viewModel: ConversationViewModel | null = this.restoreBlockedConversation(jamiId);
    if (viewModel === null) {
      return;
    }
    const conversation: ConversationModel | null = viewModel.conversation;
    if (conversation === null) {
      return;
    }
    const conversations: ConversationModel[] = this.conversationsService.conversations.value;
    let targetIndex: number = -1;
    for (let index: number = 0; index < conversations.length; index++) {
      if (conversations[index].equals(conversation)) {
        targetIndex = index;
        break;
      }
    }
    if (targetIndex < 0) {
      return;
    }
    const safeIndex: number = Math.min(targetIndex, this.conversationViewModels.length);
    this.conversationViewModels.splice(safeIndex, 0, viewModel);
    this.publish();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'restored conversation for account %{public}s', accountId);
  }

  /**
   * Swift `observeContactRemoved()` - a banned contact's conversation leaves the list. Read
   * from the `contacts` relay for the reason given on `observeContactAdded`.
   */
  private observeContactRemoved(): void {
    const dispose: () => void = this.contactsService.contacts.subscribe(
      (contacts: ContactModel[]): void => {
        const accountId: string = this.currentAccountId();
        if (accountId.length === 0) {
          return;
        }
        for (const contact of contacts) {
          if (contact.banned) {
            this.moveOrAddConversationToBanned(contact.hash, accountId);
          }
        }
      });
    this.disposeBag.add(dispose);
  }

  /** Swift `moveOrAddConversationToBanned(jamiId:accountId:)`. */
  private moveOrAddConversationToBanned(jamiId: string, accountId: string): void {
    let index: number = -1;
    for (let position: number = 0; position < this.conversationViewModels.length; position++) {
      if (this.conversationViewModels[position].isCoreConversationWith(jamiId)) {
        index = position;
        break;
      }
    }
    if (index >= 0) {
      const conversationViewModel: ConversationViewModel = this.conversationViewModels[index];
      this.conversationViewModels.splice(index, 1);
      conversationViewModel.updateBlockedStatus();
      this.blockedConversation.push(conversationViewModel);
      this.publish();
      return;
    }

    for (const blocked of this.blockedConversation) {
      if (blocked.isCoreConversationWith(jamiId)) {
        return;
      }
    }

    const conversationModel: ConversationModel | null =
      this.conversationsService.getConversationForParticipant(jamiId, accountId);
    if (conversationModel === null) {
      return;
    }
    const newViewModel: ConversationViewModel = new ConversationViewModel();
    newViewModel.setConversation(conversationModel);
    this.blockedConversation.push(newViewModel);
  }

  /**
   * Swift `subscribeToConversationRemovals()` filtered `ConversationsService.sharedResponseStream`
   * for `.conversationRemoved` - the same `ServiceEvent` gap as above. The service removes the
   * conversation from its `conversations` relay BEFORE it emits that event
   * (`ConversationsService.conversationRemoved`), so the relay carries the same fact one step
   * earlier: anything no longer in it, for this account, is gone.
   *
   * Not redundant with `subscribeToConversations`, which rebuilds only the visible list: this
   * also drops the removed conversation from `blockedConversation`, which Swift's removal path
   * left behind.
   */
  private subscribeToConversationRemovals(): void {
    const dispose: () => void = this.conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        const accountId: string = this.currentAccountId();
        if (accountId.length === 0) {
          return;
        }
        const before: number = this.conversationViewModels.length;
        this.conversationViewModels = this.conversationViewModels.filter(
          (viewModel: ConversationViewModel): boolean =>
            ConversationDataSource.stillPresent(viewModel, conversations, accountId));
        this.blockedConversation = this.blockedConversation.filter(
          (viewModel: ConversationViewModel): boolean =>
            ConversationDataSource.stillPresent(viewModel, conversations, accountId));
        if (this.conversationViewModels.length !== before) {
          this.publish();
        }
      });
    this.disposeBag.add(dispose);
  }

  /** Swift `isConversationWithBlockedContact(_:)`. */
  private isConversationWithBlockedContact(conversation: ConversationModel): boolean {
    if (!conversation.isCoredialog()) {
      return false;
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    if (participants.length === 0) {
      return false;
    }
    const jamiId: string = participants[0].jamiId;
    const contact: ContactModel | null = findContact(jamiId);
    return contact !== null && contact.banned;
  }

  /** A conversation belonging to another account is not this list's to remove. */
  private static stillPresent(viewModel: ConversationViewModel,
    conversations: ConversationModel[], accountId: string): boolean {
    const conversation: ConversationModel | null = viewModel.conversation;
    if (conversation === null || conversation.accountId !== accountId) {
      return true;
    }
    for (const candidate of conversations) {
      if (candidate.equals(conversation)) {
        return true;
      }
    }
    return false;
  }

  private isAlreadyBlocked(viewModel: ConversationViewModel): boolean {
    const conversation: ConversationModel | null = viewModel.conversation;
    if (conversation === null) {
      return false;
    }
    for (const blocked of this.blockedConversation) {
      if (blocked.isFor(conversation)) {
        return true;
      }
    }
    return false;
  }

  private currentAccountId(): string {
    const account: AccountModel | null = this.accountsService.currentAccount;
    return account === null ? '' : account.id;
  }

  /**
   * The one place `dataSource` is refreshed; every mutation of the row array ends here.
   *
   * Rows go newest first by last-message date. A row with no last message (a just-accepted
   * swarm that is still syncing) goes last, keeping the service's order (the sort is stable):
   * the physical iPhone 4.20 shows such a conversation at the bottom of the list, also after a
   * relaunch, until it syncs and its first message moves it to the top (T-1585).
   */
  private publish(): void {
    const times: Map<ConversationViewModel, number> = new Map<ConversationViewModel, number>();
    for (const row of this.conversationViewModels) {
      const last: Date | null = row.lastMessageTime;
      times.set(row, last === null ? 0 : last.getTime());
    }
    this.conversationViewModels.sort((first: ConversationViewModel, second: ConversationViewModel): number =>
      (times.get(second) ?? 0) - (times.get(first) ?? 0));
    this.dataSource.reload(this.conversationViewModels);
  }
}
