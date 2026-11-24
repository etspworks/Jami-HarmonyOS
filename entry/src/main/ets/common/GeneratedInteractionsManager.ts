/*
 * Ported from Ring/Ring/Services/GeneratedInteractionsManager.swift (GPL-3.0, Savoir-faire
 * Linux Inc.).
 *
 * This class generates interactions for contact and call events. Only for non swarm
 * conversations. It owns no data and performs NO daemon operation of its own: it listens on
 * RequestsService's and CallService's event streams and turns what it hears into a row written
 * through ConversationsService. The daemon gap is therefore reported by the services that own
 * the daemon surface, not a second time here - the same rule ConversationsManager and
 * CallsManager follow. Everything this module does (the generated-message composition rules and
 * the local database write) works for real.
 *
 * TWO THINGS DIFFER FROM SWIFT, BOTH FORCED BY THE PLATFORM:
 *
 * 1. Construction. Swift's `init(accountService:requestsService:conversationService:
 *    callService:)` takes four services and subscribes in the initializer body. `ServiceRegistry`
 *    builds with a zero-argument constructor and forbids reading the registry during
 *    construction (the import cycle is only safe while nothing runs at module-evaluation time),
 *    so the constructor is EMPTY, every service is read through a getter inside the method that
 *    uses it, and the Swift init body is `start()` - which the composition root calls once.
 *    `stop()` is the teardown Swift never needed. Same shape as ConversationsManager.
 *
 * 2. The event payloads. Swift read `.date`, `.callTime` and `.callType` out of an untyped
 *    `[ServiceEventInput: Any]` bag with `as? T`. This port's ServiceEvent has TYPED buckets, so
 *    each is read from the bucket the emitting service actually filled: RequestsService sends
 *    `.date` as epoch milliseconds through `addNumber`, and CallService.emitCallEnded sends
 *    `.callType`/`.callTime` through `addNumber` too. A miss returns null, which is Swift's
 *    `as? T` returning nil, so every Swift `guard let` stays a null check.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { describeError } from './ErrorText';
import { DisposeBag } from './Observable';
import { JamiUri, UriType } from './JamiUri';
import { ServiceRegistry } from './ServiceRegistry';
import { ServiceEvent, ServiceEventType, ServiceEventInput } from './ServiceEvent';

import { AccountsService } from './AccountsService';
import { CallService, CallType } from './CallService';
import { ConversationsService, InteractionType } from './ConversationsService';
import { RequestsService } from './RequestsService';

import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { ConfigKey } from '../model/ConfigKeyModel';
import { ConversationModel } from '../model/ConversationModel';
import { MessageModel, MessageType } from '../model/MessageModel';
import { filterOutHost } from '../model/CallDetails';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'GeneratedInteractionsManager';

/*
 * Swift `enum GeneratedMessage: Int` (DBManager.swift:26) - `toString()` is `String(rawValue)`,
 * and that raw string IS the body stored on the generated row. ConversationsService declares the
 * same seven codes privately for the reverse direction (code -> display text); they are the
 * database's own values, so they are restated here rather than re-derived.
 */
const GENERATED_OUTGOING_CALL: string = '0';
const GENERATED_INCOMING_CALL: string = '1';
const GENERATED_MISSED_OUTGOING_CALL: string = '2';
const GENERATED_MISSED_INCOMING_CALL: string = '3';
const GENERATED_INVITATION_RECEIVED: string = '5';

/**
 * Swift `JamiURI(schema:infoHash:account:)` read the SIP hostname/port off `account.details`;
 * `JamiUri.fromInfoHash` takes them as values, so they are looked up here. Swift picked the
 * schema with `AccountModelHelper(withAccount:).isAccountSip()`, which reads the same
 * `Account.type` detail the model already carries as `account.type`.
 */
function peerUriString(account: AccountModel, peerId: string): string | null {
  if (account.type !== AccountType.SIP) {
    return JamiUri.fromInfoHash(UriType.RING, peerId).uriString;
  }
  let hostname: string = '';
  let port: string = '';
  const details: AccountConfigModel | null = account.details;
  if (details !== null) {
    hostname = details.getValue(ConfigKey.ACCOUNT_HOSTNAME);
    port = details.getValue(ConfigKey.LOCAL_PORT);
  }
  return JamiUri.fromInfoHash(UriType.SIP, peerId, hostname, port).uriString;
}

export class GeneratedInteractionsManager {
  /** Swift `let disposeBag = DisposeBag()`. */
  readonly disposeBag: DisposeBag = new DisposeBag();

  /** `start()` replaces the Swift initializer body, so it must be safe to call twice. */
  private started: boolean = false;

  /* Swift held the four services as `let` properties handed in by the initializer. The registry
   * forbids reading it during construction, so each is a getter with the Swift property's name. */

  private get accountService(): AccountsService {
    return ServiceRegistry.shared().accountService;
  }

  private get requestsService(): RequestsService {
    return ServiceRegistry.shared().requestsService;
  }

  private get conversationService(): ConversationsService {
    return ServiceRegistry.shared().conversationsService;
  }

  private get callService(): CallService {
    return ServiceRegistry.shared().callService;
  }

  /** Swift `init(...)` - the subscriptions its body set up. Idempotent; the root calls it once. */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.subscribeToContactEvents();
    this.subscribeToCallEvents();
  }

  /** No Swift counterpart - the iOS object lived for the whole process. */
  stop(): void {
    try {
      this.started = false;
    } finally {
      this.disposeBag.dispose();
    }
  }

  private subscribeToContactEvents(): void {
    const unsubscribe: () => void = this.requestsService.sharedResponseStream
      .subscribe((contactRequestEvent: ServiceEvent) => {
        if (this.accountService.boothMode()) {
          return;
        }
        const accountID: string | null =
          contactRequestEvent.getEventInput(ServiceEventInput.ACCOUNT_ID);
        if (accountID === null) {
          return;
        }
        const jamiId: string | null = contactRequestEvent.getEventInput(ServiceEventInput.URI);
        if (jamiId === null) {
          return;
        }
        const account: AccountModel | null = this.accountService.getAccount(accountID);
        if (account === null) {
          return;
        }
        const uriString: string | null = peerUriString(account, jamiId);
        if (uriString === null) {
          return;
        }
        let shouldUpdateConversations: boolean = false;
        const currentAccount: AccountModel | null = this.accountService.currentAccount;
        if (currentAccount !== null && currentAccount.id === account.id) {
          shouldUpdateConversations = true;
        }
        // Swift read a `Date` straight out of the untyped bag; RequestsService emits it as epoch
        // milliseconds, since ServiceEvent has no date bucket.
        let date: Date = new Date();
        const receivedDate: number | null =
          contactRequestEvent.getNumber(ServiceEventInput.DATE);
        if (receivedDate !== null) {
          date = new Date(receivedDate);
        }
        if (contactRequestEvent.eventType === ServiceEventType.CONTACT_REQUEST_DISCARDED) {
          this.removeConversation(account.id, uriString, shouldUpdateConversations);
          return;
        }
        if (contactRequestEvent.eventType !== ServiceEventType.CONTACT_REQUEST_RECEIVED) {
          // Swift's `default: return` - every other event on this stream is someone else's.
          return;
        }
        this.conversationService.generateMessage(GENERATED_INVITATION_RECEIVED, uriString,
          account.id, date, InteractionType.CONTACT, shouldUpdateConversations);
      });
    this.disposeBag.add(unsubscribe);
  }

  /**
   * Swift `removeConversation(accountId:contactRingId:shouldUpdateConversation:)`. The third
   * parameter is unused in the Swift body too - the removal always passes
   * `keepConversation: false` - and is kept so the signature still reads as the source's.
   */
  private removeConversation(accountId: string, contactRingId: string,
    shouldUpdateConversation: boolean): void {
    const conversation: ConversationModel | null =
      this.conversationService.getConversationForParticipant(contactRingId, accountId);
    if (conversation === null) {
      return;
    }
    // remove conversation if it contain only contact messages
    const messages: MessageModel[] = conversation.messages
      .filter((message: MessageModel) => message.type !== MessageType.CONTACT);
    if (messages.length > 0) {
      return;
    }
    this.conversationService.removeConversationFromDB(conversation, false)
      .catch((error: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'removeConversationFromDB failed: %{public}s',
          describeError(error));
      });
  }

  private subscribeToCallEvents(): void {
    const unsubscribe: () => void = this.callService.sharedResponseStream
      .subscribe((callEvent: ServiceEvent) => {
        if (this.accountService.boothMode()) {
          return;
        }
        const accountID: string | null = callEvent.getEventInput(ServiceEventInput.ACCOUNT_ID);
        if (accountID === null) {
          return;
        }
        const jamiId: string | null = callEvent.getEventInput(ServiceEventInput.PEER_URI);
        if (jamiId === null) {
          return;
        }
        const account: AccountModel | null = this.accountService.getAccount(accountID);
        if (account === null) {
          return;
        }
        if (account.type !== AccountType.SIP) {
          // we should generate messages only for non swarm conversations
          const conversation: ConversationModel | null = this.conversationService
            .getConversationForParticipant(filterOutHost(jamiId), accountID);
          if (conversation === null || conversation.isSwarm()) {
            return;
          }
        } else {
          // ensure sip conversation exists
          const uri: string | null = peerUriString(account, jamiId);
          if (uri === null) {
            return;
          }
          this.conversationService.createSipConversation(uri, accountID)
            .catch((error: BusinessError) => {
              hilog.error(LOG_DOMAIN, LOG_TAG, 'createSipConversation failed: %{public}s',
                describeError(error));
            });
        }
        // CallService.emitCallEnded fills both through `addNumber`; no other call event carries
        // them, which is what confines this handler to call ends - as in Swift.
        const time: number | null = callEvent.getNumber(ServiceEventInput.CALL_TIME);
        if (time === null) {
          return;
        }
        const callType: number | null = callEvent.getNumber(ServiceEventInput.CALL_TYPE);
        if (callType === null) {
          return;
        }
        const stringUri: string | null = peerUriString(account, jamiId);
        if (stringUri === null) {
          return;
        }
        let shouldUpdateConversations: boolean = false;
        const currentAccount: AccountModel | null = this.accountService.currentAccount;
        if (currentAccount !== null && currentAccount.id === account.id) {
          shouldUpdateConversations = true;
        }
        let message: string;
        if (callType === (CallType.INCOMING as number)) {
          message = time > 0 ? GENERATED_INCOMING_CALL : GENERATED_MISSED_INCOMING_CALL;
        } else {
          message = time > 0 ? GENERATED_OUTGOING_CALL : GENERATED_MISSED_OUTGOING_CALL;
        }
        this.conversationService.generateMessage(message, stringUri, account.id, new Date(),
          InteractionType.CALL, shouldUpdateConversations, time);
      });
    this.disposeBag.add(unsubscribe);
  }
}
