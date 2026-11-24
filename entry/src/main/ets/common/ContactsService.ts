/*
 * Ported from Ring/Ring/Services/ContactsService.swift:34-219 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The account's contact list. Two halves, and they are NOT the same kind of thing:
 *
 *   LOCAL (real, fully working) - the SIP contact list, which Swift built from the app's own
 *   SQLite conversation table (`DBManager.conversationParticipants`), the in-memory `contacts`
 *   relay every screen binds to, the clear-history half of `removeAllContacts`, and the
 *   bookkeeping + event publishing of the two delegate callbacks.
 *
 *   DAEMON (a gap) - everything that reaches `ContactsAdapter`
 *   (Ring/Ring/Bridging/ContactsAdapter.h:30-33 -> libjami), i.e. the jami contact list, a
 *   contact's daemon details, add/remove/ban on the DHT. `ContactsAdapter` is a thin
 *   Objective-C++ shim over the PREBUILT jami daemon, whose source is not on disk, so per
 *   Rule 11 there is nothing to port: each of those paths resolves through `DaemonService`
 *   to a `DaemonUnavailableError` the caller renders as an explicit notice. No fake success,
 *   no fabricated contact, no silent no-op.
 *
 * Swift's `ContactsAdapter.delegate = self` has no counterpart: with no daemon there is no
 * push channel. `contactAdded` / `contactRemoved` stay PUBLIC so the bridge - or a test -
 * can drive them the moment one exists.
 */

import { jami, toMap } from './JamiNative';
import { StringMap } from 'libjami.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';
import { LookupNameResponse, LookupNameState, NameService } from './NameService';
import { DaemonService, DaemonUnavailableError } from './DaemonService';
import { describeError } from './ErrorText';
import { AccountModelHelper } from './AccountModelHelper';
import { JamiUri, UriType } from './JamiUri';
import { ContactModel } from '../model/ContactModel';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ContactsService';

/** Swift `enum ContactServiceError: Error` (ContactsService.swift:27-32). */
export enum ContactServiceError {
  VCARD_SERIALIZATION_FAILED = 'VCARD_SERIALIZATION_FAILED',
  LOAD_VCARD_FAILED = 'LOAD_VCARD_FAILED',
  SAVE_VCARD_FAILED = 'SAVE_VCARD_FAILED',
  REMOVE_CONTACT_FAILED = 'REMOVE_CONTACT_FAILED'
}

/**
 * The slice of `DbManager` (plan id `svc_db`) this service uses - an INTERFACE, not an import
 * of that class, for the same reason `ConversationsService.ConversationsDb` is one: `DbManager.ts`
 * is written by another batch in this same wave, so its exported names cannot be read yet.
 * An interface is structurally typed, so the real `DbManager` satisfies it once the methods line
 * up, and the ability injects it with `setDatabase(...)`.
 *
 * Swift's `conversationParticipants` was synchronous over SQLite.swift; `@ohos.data.relationalStore`
 * is promise-based, so both become `Promise`.
 */
export interface ContactsDb {
  conversationParticipants(accountId: string): Promise<string[]>;
  clearAllHistoryFor(accountId: string): Promise<void>;
}

export class ContactsService {
  /** Swift `let contacts = BehaviorRelay(value: [ContactModel]())` - what every screen binds to. */
  readonly contacts: BehaviorRelay<ContactModel[]> = new BehaviorRelay<ContactModel[]>([]);

  /** Swift `private let responseStream = PublishSubject<ServiceEvent>()`. */
  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /**
   * Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`.
   * A PublishSubject is already multicast, so the shared stream IS the response stream.
   */
  readonly sharedResponseStream: PublishSubject<ServiceEvent>;

  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /**
   * Swift `let dbManager: DBManager`, a constructor argument. The registry constructor takes no
   * arguments and does not vend the DB layer, so it arrives through `setDatabase` at startup.
   */
  private dbManager: ContactsDb | null = null;

  private trackingNames: boolean = false;

  constructor() {
    this.sharedResponseStream = this.responseStream;
  }

  /** Call once from the ability's `onCreate`, with the app's `DbManager`. */
  setDatabase(database: ContactsDb): void {
    this.dbManager = database;
  }

  /** Drops every subscription this service took out. */
  dispose(): void {
    this.disposeBag.dispose();
  }

  /**
   * Swift `private let contactsAdapter: ContactsAdapter` - the Objective-C++ daemon bridge.
   * It has no HarmonyOS counterpart, so every call that went through it goes through here.
   */
  private get contactsAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  // MARK: initial loading

  /**
   * Swift `func loadContacts(withAccount account: AccountModel)` - called at app start and on
   * every account change. SIP accounts load for real from the local database; jami accounts
   * need the daemon's contact list and are a gap.
   */
  async loadContacts(account: AccountModel): Promise<void> {
    if (this.helperFor(account).isAccountSip()) {
      await this.loadSipContacts(account);
      return;
    }
    this.loadJamiContacts(account.id);
  }

  /**
   * Swift `private func loadSipContacts(withAccount:)`. LOCAL - the participants of the account's
   * own conversations, one contact each, deduplicated by URI exactly as the Swift did
   * (`values.firstIndex(of: contact) == nil`, and `ContactModel.==` compares `uriString`).
   */
  private async loadSipContacts(account: AccountModel): Promise<void> {
    const database: ContactsDb | null = this.dbManager;
    if (database === null) {
      this.log('loadSipContacts: no database injected; contact list left as it was');
      return;
    }
    this.contacts.accept([]);
    const values: ContactModel[] = [];
    try {
      const participants: string[] = await database.conversationParticipants(account.id);
      for (const participant of participants) {
        const contact: ContactModel =
          ContactModel.fromUri(JamiUri.fromInfoHash(UriType.SIP, participant));
        if (values.findIndex((existing: ContactModel) => existing.equals(contact)) === -1) {
          values.push(contact);
        }
      }
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'loadSipContacts failed: %{public}s',
        describeError(err as BusinessError));
    } finally {
      this.contacts.accept(values);
    }
  }

  /**
   * Swift `private func loadJamiContacts(withAccountId:)` - `contactsAdapter.contacts(withAccountId:)`.
   * GAP: the jami contact list lives on the DHT behind the daemon. Swift left the relay untouched
   * when the adapter returned nil, and that is exactly what happens here - an empty list would
   * claim the account has no contacts, which is not something this build can know.
   */
  private loadJamiContacts(accountId: string): void {
    const contacts: ContactModel[] = jami.getContacts(accountId)
      .map((dictionary: StringMap) => ContactModel.fromDictionary(toMap(dictionary)));
    this.contacts.accept([]);
    const values: ContactModel[] = [];
    for (const contact of contacts) {
      if (!values.some((existing: ContactModel) => existing.equals(contact))) {
        values.push(contact);
      }
    }
    this.contacts.accept(values);
    this.resolveRegisteredNames(accountId, values);
  }

  /**
   * Swift fills `contact.userName` lazily from name lookups (ConversationRowVM). Done once here
   * for the whole list, so pickers and call rosters show registered names instead of ids.
   */
  private resolveRegisteredNames(accountId: string, contacts: ContactModel[]): void {
    const names: NameService = ServiceRegistry.shared().nameService;
    if (!this.trackingNames) {
      this.trackingNames = true;
      this.disposeBag.add(names.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
        if (response.state !== LookupNameState.FOUND || response.name.length === 0) {
          return;
        }
        const contact: ContactModel | null = this.contact(response.address);
        if (contact !== null && contact.userName !== response.name) {
          contact.userName = response.name;
          this.contacts.accept(this.contacts.value.slice());
        }
      }));
    }
    for (const contact of contacts) {
      if (contact.userName === null || contact.userName.length === 0) {
        names.lookupAddress(accountId, '', contact.hash);
      }
    }
  }

  private contactDetails(uri: string, accountId: string): Map<string, string> | null {
    const details: Map<string, string> = toMap(jami.getContactDetails(accountId, uri));
    return details.size === 0 ? null : details;
  }

  // MARK: contact getter

  /**
   * Swift `func contact(withHash hash: String) -> ContactModel?`.
   * `ConversationsManager` and `ConversationDataSource` both call this spelling.
   */
  contact(hash: string): ContactModel | null {
    const found: ContactModel | undefined =
      this.contacts.value.find((candidate: ContactModel) => candidate.hash === hash);
    return found === undefined ? null : found;
  }

  /**
   * Swift `func contact(withUri uri: String) -> ContactModel?` - matches the URI, then falls back
   * to the hash. Swift told the two apart by argument label; ArkTS has no overloading, so the URI
   * form keeps its own name.
   */
  contactByUri(uri: string): ContactModel | null {
    const found: ContactModel | undefined =
      this.contacts.value.find((candidate: ContactModel) => candidate.uriString === uri);
    return found === undefined ? this.contact(uri) : found;
  }

  /**
   * Swift `func isContact(hash:accountId:) -> Bool` - `added > removed` from the daemon's contact
   * details. Those timestamps are daemon-only, so this answers from the local list instead: a
   * contact that is loaded and not banned IS a contact. That is a narrower answer than Swift's,
   * never a wider one - it can only be true for a contact this app already holds.
   *
   * Build-only gap (`unavailable`, not `reportUnavailable`): this runs per contact row and would
   * otherwise drown the user in notices.
   */
  isContact(hash: string, accountId: string): boolean {
    const details: Map<string, string> | null = this.contactDetails(hash, accountId);
    if (details === null) {
      return false;
    }
    const added: number = Number(details.get('added') ?? 'NaN');
    const removed: number = Number(details.get('removed') ?? 'NaN');
    if (isNaN(added) || isNaN(removed)) {
      return false;
    }
    return added > removed;
  }

  /**
   * Swift `func contactExists(withHash:accountId:) -> Bool` - reloads the jami list, then reports
   * whether the contact is present and unbanned. The reload is the gap; the check is local and
   * real.
   */
  contactExists(hash: string, accountId: string): boolean {
    this.loadJamiContacts(accountId);
    const contact: ContactModel | null = this.contact(hash);
    if (contact !== null) {
      return !contact.banned;
    }
    return false;
  }

  // MARK: contacts management unban/remove

  /**
   * Swift `func removeContact(withId:ban:withAccountId:) -> Observable<Void>` -
   * `contactsAdapter.removeContact(...)`. GAP: removing or banning a contact is a DHT write.
   * Rejects with the notice rather than completing, which is what Swift's observable did on
   * success and must not do here.
   */
  async removeContact(jamiId: string, ban: boolean, accountId: string): Promise<void> {
    jami.removeContact(accountId, jamiId, ban);
  }

  /**
   * Swift `func unbanContact(contact:account:)` - `contactsAdapter.addContact(...)`, then the
   * local unban. `libjami::addContact` returns void, so there is no failure to hand back.
   *
   * Swift flips `banned` in place and BlockedContactsVM re-reads the relay on `.contactAdded`;
   * the relay is re-emitted here instead so every banned-list binding drops the row at once.
   */
  unbanContact(contact: ContactModel, account: AccountModel): void {
    jami.addContact(account.id, contact.hash);
    const existing: ContactModel | null = this.contactByUri(contact.uriString ?? '');
    if (existing !== null) {
      existing.banned = false;
      this.contacts.accept(this.contacts.value);
    } else {
      this.contacts.accept(this.contacts.value.concat([contact]));
    }
    this.reemitConversations();
  }

  /**
   * The smart list re-filters only when the conversations relay emits, so a ban or unban
   * re-emits it: the data source re-partitions blocked rows and the list drops or restores
   * the contact's conversation at once (Swift's list reacted to `.contactRemoved/.contactAdded`).
   */
  private reemitConversations(): void {
    const conversations = ServiceRegistry.shared().conversationsService.conversations;
    conversations.accept(conversations.value);
  }

  /**
   * Swift `func removeAllContacts(for accountId: String)` - remove each contact from the daemon,
   * clear the relay, clear the account's history, publish `.allContactsRemoved`.
   *
   * SPLIT: the daemon removals are a gap and are reported ONCE (not per contact). Everything
   * local - the relay and the account's own message history - is cleared for real, because that
   * is data this app owns and the user asked to remove.
   */
  async removeAllContacts(accountId: string): Promise<void> {
    for (const contact of this.contacts.value) {
      jami.removeContact(accountId, contact.hash, false);
    }
    this.contacts.accept([]);

    const database: ContactsDb | null = this.dbManager;
    if (database === null) {
      this.log('removeAllContacts: no database injected; history left in place');
    } else {
      try {
        await database.clearAllHistoryFor(accountId);
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'clearAllHistoryFor failed: %{public}s',
          describeError(err as BusinessError));
      }
    }

    const event: ServiceEvent = new ServiceEvent(ServiceEventType.ALL_CONTACTS_REMOVED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  // MARK: ContactsAdapterDelegate

  /**
   * Swift `func contactAdded(contact uri:withAccountId:confirmed:)`. The daemon pushed this; with
   * no daemon nothing calls it yet, but the bookkeeping and the event are real and the bridge
   * needs the entry point.
   *
   * The one daemon read here is the details fetch for a contact this app does not yet hold - a
   * build-only gap, since fabricating the contact is the failure this must not produce.
   */
  contactAdded(uri: string, accountId: string, confirmed: boolean): void {
    let conversationId: string = '';
    // The relay holds the current account's contacts only: another local account's contact
    // must not land in it (T-1741). The event still goes out for that account.
    const current: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    const isCurrent: boolean = current === null || current.id === accountId;
    const known: ContactModel | null = isCurrent ? this.contactByUri(uri) : null;
    if (known !== null) {
      if (known.confirmed !== confirmed) {
        known.confirmed = confirmed;
      }
      conversationId = known.conversationId;
    } else {
      const details: Map<string, string> | null = this.contactDetails(uri, accountId);
      if (details !== null) {
        const contact: ContactModel = ContactModel.fromDictionary(details);
        conversationId = contact.conversationId;
        if (isCurrent) {
          this.contacts.accept(this.contacts.value.concat([contact]));
        }
      }
    }

    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_ADDED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.PEER_URI, uri);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    this.responseStream.onNext(event);
    this.log('Contact added: ' + uri);
  }

  /**
   * Swift `func contactRemoved(contact uri:withAccountId:banned:)`. Swift resolved an unknown
   * banned contact through the daemon's details so it could be tracked; that read is the gap, and
   * without it there is nothing to mark, so the callback returns exactly as Swift's `guard` did.
   */
  contactRemoved(uri: string, accountId: string, banned: boolean): void {
    // As contactAdded: another local account's removal must not touch the current account's
    // contacts (T-1741). Its contact is read from the daemon and the event still goes out.
    const current: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    const isCurrent: boolean = current === null || current.id === accountId;
    let contactToRemove: ContactModel | null = isCurrent ? this.contact(uri) : null;
    if (contactToRemove === null && (banned || !isCurrent)) {
      // Track a banned contact this app did not hold yet.
      const details: Map<string, string> | null = this.contactDetails(uri, accountId);
      contactToRemove = details === null ? null : ContactModel.fromDictionary(details);
    }
    if (contactToRemove === null) {
      return;
    }
    const removed: ContactModel = contactToRemove;
    removed.banned = banned;

    if (!isCurrent) {
      // The current account's relay is left as it is.
    } else if (!banned) {
      const values: ContactModel[] =
        this.contacts.value.filter((candidate: ContactModel) => !candidate.equals(removed));
      this.contacts.accept(values);
    } else {
      // Re-emit so relay readers (ConversationDataSource.observeContactRemoved, the Blocked
      // contacts list) see the ban now; Swift's readers took `.contactRemoved` off the stream.
      const known: boolean = this.contacts.value.some((c: ContactModel) => c.equals(removed));
      this.contacts.accept(known ? this.contacts.value : this.contacts.value.concat([removed]));
      this.reemitConversations();
    }

    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_REMOVED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.PEER_URI, uri);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, removed.conversationId);
    this.responseStream.onNext(event);
    this.log('Contact removed: ' + uri);
  }

  /**
   * Swift `AccountModelHelper(withAccount: account)`. The ported helper reads the two raw daemon
   * maps rather than an AccountModel, so it is built from the account's config models - same
   * construction `AccountsService.helperFor` uses.
   */
  private helperFor(account: AccountModel): AccountModelHelper {
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    return new AccountModelHelper(details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
  }
}
