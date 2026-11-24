/*
 * Ported from Ring/Ring/Services/ConversationsService.swift (GPL-3.0, Savoir-faire Linux Inc.),
 * with Ring/Ring/Services/ServiceEvent.swift, Ring/Ring/Services/Conversations/
 * ReplyTargetRegistry.swift and Ring/Ring/Services/Conversations/ConversationEventSource.swift
 * folded in - Swift declares those beside this service and the migration plan gives them no
 * module of their own.
 *
 * WHAT IS REAL AND WHAT IS A DISCLOSED GAP
 * ----------------------------------------
 * Swift reaches the swarm/DHT/messaging backend through `ConversationsAdapter`
 * (Ring/Ring/Bridging/ConversationsAdapter.mm), an ObjC++ bridge onto the prebuilt C++ jami
 * daemon. That daemon has no source on disk, so CLAUDE.md Rule 11 forbids porting it, stubbing
 * it with fake success, or bridging to it. Every `conversationsAdapter.*` call therefore
 * resolves through `DaemonService.reportUnavailable(...)`: it is logged, published on
 * `daemonService.unavailableEvents`, and the caller gets an empty/absent result or a rejected
 * promise - never a fabricated message and never a silent no-op.
 *
 * Everything that did NOT need the daemon stays real: the in-memory conversation list and its
 * ordering, unread bookkeeping, the reply-target registry, message insertion, and every
 * database read/write (which goes through the injected `ConversationsDb`, see below).
 *
 * TWO INJECTORS (the ServiceRegistry contract, rule 3)
 * ----------------------------------------------------
 *   setDatabase(db)  - the per-account SQLite layer (`DbManager`, plan id `svc_db`).
 *   setContext(ctx)  - the UIAbilityContext, for `filesDir` (removeSavedFiles) and
 *                      `resourceManager` (generated-message text).
 * The ability calls both once at startup, exactly as `setModelResources` is called for
 * MessageModel. Until then the DB paths report "database not attached" and do nothing - they
 * do not pretend to have stored anything.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { DaemonUnavailableError } from './DaemonService';
import { jami, toMap, toRecord } from './JamiNative';
import { StringMap } from 'libjami.so';
import { ServiceRegistry } from './ServiceRegistry';
import { JamiUri, UriType } from './JamiUri';
import { describeError } from './ErrorText';

import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { ConfigKey } from '../model/ConfigKeyModel';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import { ConversationParticipant, ParticipantRole } from '../model/ConversationParticipant';
import {
  ContactAction, DataTransferStatus, durationFormatted, MessageModel, MessageStatus, MessageType,
  SwarmMessageWrap
} from '../model/MessageModel';
import { LoadedMessages } from '../model/LoadedMessages';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ConversationsService';

/* ------------------------------------------------------------------------------------------
 * ServiceEvent (Ring/Ring/Services/ServiceEvent.swift)
 * The plan gives ServiceEvent no module; it is declared here because this is the first service
 * in the build order that publishes one. Other services import it from here.
 * ---------------------------------------------------------------------------------------- */


/* ------------------------------------------------------------------------------------------
 * ConversationEvent (Ring/Ring/Services/Conversations/ConversationEventSource.swift)
 * ---------------------------------------------------------------------------------------- */

/** The Swift enum's case names; ArkTS enums carry no payload, so the payload is on the class. */
export enum ConversationEventKind {
  INCOMING_ACCOUNT_MESSAGE = 'incomingAccountMessage',
  MESSAGE_STATUS_CHANGED = 'messageStatusChanged',
  ACTIVE_CALLS_CHANGED = 'activeCallsChanged',
  COMPOSING_STATUS_CHANGED = 'composingStatusChanged',
  SWARM_LOADED = 'swarmLoaded',
  SWARM_MESSAGE_RECEIVED = 'swarmMessageReceived',
  SWARM_MESSAGE_UPDATED = 'swarmMessageUpdated',
  REACTION_ADDED = 'reactionAdded',
  REACTION_REMOVED = 'reactionRemoved',
  CONVERSATION_READY = 'conversationReady',
  CONVERSATION_REMOVED = 'conversationRemoved',
  CONVERSATION_DECLINED = 'conversationDeclined',
  CONVERSATION_MEMBER_EVENT = 'conversationMemberEvent',
  CONVERSATION_PROFILE_UPDATED = 'conversationProfileUpdated',
  CONVERSATION_PREFERENCES_UPDATED = 'conversationPreferencesUpdated'
}

/**
 * One `ConversationEvent`. Swift's associated values become optional fields; only the ones the
 * kind defines are set. `accountId` and `conversationId` are on every case but the first pair,
 * which is why they are plain fields.
 */
export class ConversationEvent {
  readonly kind: ConversationEventKind;
  accountId: string = '';
  conversationId: string = '';
  /** `incomingAccountMessage(from:)` / `composingStatusChanged(from:)`. */
  from: string = '';
  /** `messageStatusChanged(peer:)` - the other party's URI. */
  peer: string = '';
  messageId: string = '';
  memberUri: string = '';
  reactionId: string = '';
  requestId: number = 0;
  /** `composingStatusChanged(status:)` / `conversationMemberEvent(event:)`. */
  status: number = 0;
  messageStatus: MessageStatus = MessageStatus.UNKNOWN;
  payloads: Map<string, string> = new Map<string, string>();
  reaction: Map<string, string> = new Map<string, string>();
  profile: Map<string, string> = new Map<string, string>();
  preferences: Map<string, string> = new Map<string, string>();
  calls: Array<Map<string, string>> = [];
  messages: SwarmMessageWrap[] = [];
  message: SwarmMessageWrap | null = null;

  constructor(kind: ConversationEventKind) {
    this.kind = kind;
  }

  /** Swift `ConversationEvent.isOrderedWithConversationState`. */
  get isOrderedWithConversationState(): boolean {
    return this.kind !== ConversationEventKind.ACTIVE_CALLS_CHANGED;
  }
}

/**
 * Swift `final class ConversationEventSource`. `attachToAdapter()` set itself as the
 * `ConversationsAdapter.messagesDelegate`, i.e. it subscribed to the daemon's callbacks - so
 * attaching is a daemon-backed operation and reports unavailable. The object itself stays real:
 * anything that can synthesize a `ConversationEvent` (a test, a future transport) calls
 * `deliver` and the whole downstream fan-out works unchanged.
 */
export class ConversationEventSource {
  private readonly onEvent: (event: ConversationEvent) => void;

  constructor(onEvent: (event: ConversationEvent) => void) {
    this.onEvent = onEvent;
  }

  /** Swift `attachToAdapter()`. The NAPI binding (JamiNative) routes signals into `deliver`. */
  attachToAdapter(): void {
  }

  /** Feeds one event through, exactly as the adapter delegate methods did. */
  deliver(event: ConversationEvent): void {
    this.onEvent(event);
  }
}

/* ------------------------------------------------------------------------------------------
 * ReplyTargetRegistry (Ring/Ring/Services/Conversations/ReplyTargetRegistry.swift)
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift guards `requestedIds` with an NSLock because the daemon delivers loads on its own
 * thread. An ArkTS module instance is confined to one VM thread, so there is no concurrent
 * writer and the lock has no counterpart.
 */
export class ReplyTargetRegistry {
  readonly targets: BehaviorRelay<MessageModel[]> = new BehaviorRelay<MessageModel[]>([]);
  private requestedIds: string[] = [];

  /** Returns false when this id is already being loaded - the duplicate-request guard. */
  request(messageId: string): boolean {
    if (this.requestedIds.indexOf(messageId) >= 0) {
      return false;
    }
    this.requestedIds.push(messageId);
    return true;
  }

  isRequested(messageId: string): boolean {
    return this.requestedIds.indexOf(messageId) >= 0;
  }

  target(messageId: string): MessageModel | null {
    const found: MessageModel | undefined =
      this.targets.value.find((item: MessageModel) => item.id === messageId);
    return found === undefined ? null : found;
  }

  resolve(message: MessageModel): void {
    const updated: MessageModel[] = this.targets.value.slice();
    const present: boolean = updated.some((item: MessageModel) => item.id === message.id);
    if (!present) {
      updated.push(message);
      this.targets.accept(updated);
    }
    this.requestedIds = this.requestedIds.filter((id: string) => id !== message.id);
  }
}

/* ------------------------------------------------------------------------------------------
 * Small value types the service's own signatures need
 * ---------------------------------------------------------------------------------------- */

/** Swift `struct ParticipantData` (Ring/Ring/SwarmInfo.swift:51). */
export class ParticipantData {
  jamiId: string;
  role: ParticipantRole;

  constructor(jamiId: string, role: ParticipantRole) {
    this.jamiId = jamiId;
    this.role = role;
  }
}

/** Swift `enum LoadReplyResult` - the three outcomes of asking for a reply target. */
export enum LoadReplyResultKind {
  MESSAGE_FOUND = 'messageFound',
  DUPLICATE_REQUEST = 'duplicateRequest',
  LOAD_TRIGGERED = 'loadTriggered'
}

/** `LoadReplyResult` with its one associated value. */
export class LoadReplyResult {
  readonly kind: LoadReplyResultKind;
  readonly message: MessageModel | null;

  constructor(kind: LoadReplyResultKind, message: MessageModel | null = null) {
    this.kind = kind;
    this.message = message;
  }
}

/** Swift `struct ConversationsService.TypingStatus`. */
export class TypingStatus {
  readonly from: string;
  readonly status: number;
  readonly conversationId: string;

  constructor(from: string, status: number, conversationId: string) {
    this.from = from;
    this.status = status;
    this.conversationId = conversationId;
  }
}

/**
 * Swift posted `ConversationNotifications.conversationReady` on NotificationCenter with
 * `{conversationId, accountId}`; RequestsService observes it. HarmonyOS has no
 * NotificationCenter, so the post becomes this typed stream (`conversationReadyNotifications`).
 */
export class ConversationReadyNotice {
  readonly conversationId: string;
  readonly accountId: string;

  constructor(conversationId: string, accountId: string) {
    this.conversationId = conversationId;
    this.accountId = accountId;
  }
}

/** Swift `enum InteractionType` (DBManager.swift:144) - the `interactions.type` column value. */
export enum InteractionType {
  INVALID = 'INVALID',
  TEXT = 'TEXT',
  CALL = 'CALL',
  CONTACT = 'CONTACT',
  I_TRANSFER = 'INCOMING_DATA_TRANSFER',
  O_TRANSFER = 'OUTGOING_DATA_TRANSFER'
}

/** Swift `InteractionType.toMessageType()`. */
export function interactionTypeToMessageType(type: InteractionType): MessageType {
  if (type === InteractionType.CALL) {
    return MessageType.CALL;
  }
  if (type === InteractionType.CONTACT) {
    return MessageType.CONTACT;
  }
  if (type === InteractionType.I_TRANSFER || type === InteractionType.O_TRANSFER) {
    return MessageType.FILE_TRANSFER;
  }
  return MessageType.TEXT;
}

/** Swift `typealias SavedMessageForConversation = (messageID:, conversationID:)`. */
export interface SavedMessageForConversation {
  messageID: string;
  conversationID: string;
}

/**
 * The slice of `DbManager` (plan id `svc_db`) this service uses. It is an INTERFACE, not an
 * import of that class, for one reason: `DbManager.ts` is written by a different Phase-2 batch
 * in this same wave, so its exported names cannot be read yet and guessing them would be a
 * compile error in every case but one. An interface is structurally typed, so the real
 * `DbManager` satisfies it as soon as its methods line up, and the ability injects it with
 * `setDatabase(...)`.
 *
 * Method names are the Swift ones verbatim. Swift returned RxSwift `Completable`/`Observable`;
 * the HarmonyOS DB API is promise-based, so each becomes a `Promise`.
 */
export interface ConversationsDb {
  getConversationsObservable(accountId: string): Promise<ConversationModel[]>;
  saveMessage(accountId: string, contactUri: string, message: MessageModel, incoming: boolean,
    interactionType: string, duration: number): Promise<SavedMessageForConversation>;
  deleteMessage(messagesId: number, accountId: string): Promise<void>;
  clearHistoryFor(accountId: string, participantUri: string,
    keepConversation: boolean): Promise<void>;
  updateTransferStatus(daemonID: string, transferStatus: string, accountId: string): Promise<void>;
  setMessagesAsRead(messagesIDs: string[], status: number, accountId: string): Promise<void>;
  createDatabaseForAccount(accountId: string): Promise<boolean>;
  createConversationsFor(contactUri: string, accountId: string): Promise<string>;
}

/* ------------------------------------------------------------------------------------------
 * Generated-message text (Swift `GeneratedMessage.toMessage(with:)`, DBManager.swift:26)
 * ---------------------------------------------------------------------------------------- */

const GENERATED_OUTGOING_CALL: string = '0';
const GENERATED_INCOMING_CALL: string = '1';
const GENERATED_MISSED_OUTGOING_CALL: string = '2';
const GENERATED_MISSED_INCOMING_CALL: string = '3';
const GENERATED_CONTACT_ADDED: string = '4';
const GENERATED_INVITATION_RECEIVED: string = '5';
const GENERATED_INVITATION_ACCEPTED: string = '6';

const TEXT_PLAIN_MIME_TYPE: string = 'text/plain';
const GEO_LOCATION_MIME_TYPE: string = 'application/geo';

/** Swift `Directories.downloads` / `.recorded` (DataTransferService.swift:35). */
const DIRECTORY_DOWNLOADS: string = 'downloads';
const DIRECTORY_RECORDED: string = 'recorded';

/* ------------------------------------------------------------------------------------------ */

// swiftlint-equivalent note: the Swift class carries `type_body_length`/`file_length` waivers.
export class ConversationsService {
  /**
   * Swift `private let log = SwiftyBeaver.self`. SwiftyBeaver resolves to `@ohos.hilog`
   * (inventory `dependencies[]`), which is a module rather than an object you hold - so the
   * field carries the tag every hilog call in this module logs under.
   */
  private readonly log: string = LOG_TAG;
  private readonly disposeBag: DisposeBag = new DisposeBag();
  private readonly textPlainMIMEType: string = TEXT_PLAIN_MIME_TYPE;
  private readonly geoLocationMIMEType: string = GEO_LOCATION_MIME_TYPE;

  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();
  /** Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`. */
  readonly sharedResponseStream: PublishSubject<ServiceEvent> = this.responseStream;

  readonly conversations: BehaviorRelay<ConversationModel[]> =
    new BehaviorRelay<ConversationModel[]>([]);

  /**
   * Swift `var conversationReady = BehaviorRelay(value: "")`. Renamed because Swift lets a
   * property and a method share the name `conversationReady` and ArkTS does not; the METHOD
   * keeps the source name, since that is what ConversationsManager calls. Same resolution
   * ConversationModel used for `messageUpdated`/`messageUpdatedEvents`.
   */
  readonly conversationReadyEvents: BehaviorRelay<string> = new BehaviorRelay<string>('');

  /** The NotificationCenter post Swift made from `publishNewConversation`; see the class doc. */
  readonly conversationReadyNotifications: PublishSubject<ConversationReadyNotice> =
    new PublishSubject<ConversationReadyNotice>();

  private readonly replyTargetRegistry: ReplyTargetRegistry = new ReplyTargetRegistry();

  get replyTargets(): BehaviorRelay<MessageModel[]> {
    return this.replyTargetRegistry.targets;
  }

  /** Swift `let dbManager: DBManager`, injected here (zero-arg constructor, registry rule 1). */
  private dbManager: ConversationsDb | null = null;
  private context: common.UIAbilityContext | null = null;

  /**
   * Swift `DispatchQueue(label: "com.jami.ConversationsService.operationQueue")`. ArkTS has one
   * VM thread, so a serial queue is only needed to keep ASYNC work in order: this is the tail of
   * the chain every enqueued task links onto.
   */
  private serialOperationQueue: Promise<void> = Promise.resolve();

  onEvent: ((event: ConversationEvent) => void) | null = null;

  private eventSourceValue: ConversationEventSource | null = null;

  /** Swift `private(set) lazy var eventSource`. */
  get eventSource(): ConversationEventSource {
    let source: ConversationEventSource | null = this.eventSourceValue;
    if (source === null) {
      source = new ConversationEventSource((event: ConversationEvent) => {
        const handler: ((event: ConversationEvent) => void) | null = this.onEvent;
        if (handler === null) {
          return;
        }
        if (!event.isOrderedWithConversationState) {
          handler(event);
          return;
        }
        this.enqueue(async () => {
          handler(event);
        });
      });
      this.eventSourceValue = source;
    }
    return source;
  }

  readonly typingStatusSubject: PublishSubject<TypingStatus> = new PublishSubject<TypingStatus>();

  get typingStatusStream(): PublishSubject<TypingStatus> {
    return this.typingStatusSubject;
  }

  // MARK: - injection (the ServiceRegistry contract, rule 3)

  /** Called once at startup with the `DbManager` the registry-less DB layer builds. */
  setDatabase(database: ConversationsDb): void {
    this.dbManager = database;
  }

  /** Called once at startup: `setContext(this.context)` from the ability's `onCreate`. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  // MARK: - internals

  /** One daemon-backed operation refused. Logged and published; never a fake success. */
  private gap(feature: string): DaemonUnavailableError {
    return ServiceRegistry.shared().daemonService.reportUnavailable(feature);
  }

  /** Links `task` onto the serial chain, keeping ordering even when a predecessor rejects. */
  private enqueue(task: () => Promise<void>): Promise<void> {
    const next: Promise<void> = this.serialOperationQueue.then(task, task);
    this.serialOperationQueue = next.then(() => {
    }, (err: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'queued task failed: %{public}s', err.message);
    });
    return next;
  }

  private requireDatabase(operation: string): ConversationsDb | null {
    const database: ConversationsDb | null = this.dbManager;
    if (database === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'no database attached; %{public}s skipped (call setDatabase at startup)', operation);
    }
    return database;
  }

  private resources(): resourceManager.ResourceManager | null {
    const context: common.UIAbilityContext | null = this.context;
    return context === null ? null : context.resourceManager;
  }

  private localized(name: string): string {
    const manager: resourceManager.ResourceManager | null = this.resources();
    if (manager === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager; %{public}s unresolved', name);
      return '';
    }
    try {
      return manager.getStringByNameSync(name);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'string %{public}s failed: %{public}s', name,
        describeError(err as BusinessError));
      return '';
    }
  }

  /**
   * Swift `GeneratedMessage(from: content).toMessage(with: duration)`. The legacy non-swarm
   * rows store the case index as their body; this turns it back into display text.
   */
  private generatedMessageText(code: string, durationSeconds: number): string {
    const time: string = durationFormatted(durationSeconds);
    if (code === GENERATED_CONTACT_ADDED) {
      return this.localized('generated_message_contact_added');
    }
    if (code === GENERATED_INVITATION_RECEIVED) {
      return this.localized('generated_message_non_swarm_invitation_received');
    }
    if (code === GENERATED_INVITATION_ACCEPTED) {
      return this.localized('generated_message_non_swarm_invitation_accepted');
    }
    if (code === GENERATED_MISSED_OUTGOING_CALL) {
      return this.localized('generated_message_missed_outgoing_call');
    }
    if (code === GENERATED_MISSED_INCOMING_CALL) {
      return this.localized('generated_message_missed_incoming_call');
    }
    if (code === GENERATED_OUTGOING_CALL) {
      return this.localized('generated_message_outgoing_call') + ' - ' + time;
    }
    if (code === GENERATED_INCOMING_CALL) {
      // Swift takes this one from L10n.Global, not L10n.GeneratedMessage.
      return this.localized('global_incoming_call') + ' - ' + time;
    }
    // Swift's `default: return ""` - an unrecognized code has no text.
    return '';
  }

  /** Swift's `(message.type.isContact || message.type == .call) ? generated : content`. */
  private displayContent(message: MessageModel, durationSeconds: number): string {
    if (message.type === MessageType.CONTACT || message.type === MessageType.CALL) {
      return this.generatedMessageText(message.content, durationSeconds);
    }
    return message.content;
  }

  private firstParticipantJamiId(conversation: ConversationModel): string | null {
    const first: ConversationParticipant | undefined = conversation.getParticipants()[0];
    return first === undefined ? null : first.jamiId;
  }

  // MARK: - events

  /** Swift `startEvents()` - subscribes the event source to the daemon. Disclosed gap. */
  startEvents(): void {
    this.eventSource.attachToAdapter();
  }

  // MARK: - initial loading

  /**
   * Swift `getConversationsForAccount(accountId:accountURI:)` - called at app start and on
   * account change. The swarm half needs the daemon (gap); the database half is real.
   */
  getConversationsForAccount(accountId: string, accountURI: string): void {
    this.enqueue(async () => {
      // Swift `loadConversations(accountId:accountURI:)` keeps `previousRecords` so the models
      // rows and view models hold stay the ones that receive the new messages.
      const previous: ConversationModel[] = this.conversations.value;
      let currentConversations: ConversationModel[] = [];
      this.conversations.accept(currentConversations);

      // Swift: conversationsAdapter.getSwarmConversations(forAccount:).
      const conversationToLoad: string[] = jami.getConversations(accountId);
      for (const swarmId of conversationToLoad) {
        this.addSwarm(swarmId, accountId, accountURI, currentConversations, previous);
      }

      const database: ConversationsDb | null = this.requireDatabase('getConversationsForAccount');
      if (database === null) {
        currentConversations = this.sortAndUpdate(currentConversations);
        return;
      }
      try {
        const fromDatabase: ConversationModel[] =
          await database.getConversationsObservable(accountId);
        const oneToOne: Array<string | null> = currentConversations
          .filter((conversation: ConversationModel) => conversation.isCoredialog())
          .map((conversation: ConversationModel) => this.firstParticipantJamiId(conversation));
        const invitationText: string =
          this.localized('generated_message_non_swarm_invitation_received');
        const kept: ConversationModel[] = fromDatabase
          // Swift filters out the bare contact-request placeholder conversations.
          .filter((conversation: ConversationModel) => {
            const only: MessageModel | undefined = conversation.messages[0];
            const isPlaceholder: boolean = conversation.messages.length === 1 &&
              only !== undefined && invitationText.length > 0 && only.content === invitationText;
            return !isPlaceholder;
          })
          // and any conversation already present as a swarm.
          .filter((conversation: ConversationModel) => {
            const jamiId: string | null = this.firstParticipantJamiId(conversation);
            return jamiId === null ? true : oneToOne.indexOf(jamiId) < 0;
          });
        currentConversations = currentConversations.concat(kept);
        currentConversations = this.sortAndUpdate(currentConversations);
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'loading conversations failed: %{public}s',
          describeError(err as BusinessError));
        this.conversations.accept(currentConversations);
      }
      this.loadLatestMessages(conversationToLoad, accountId);
      this.scheduleUnreadCounts(currentConversations, accountId);
    });
  }

  /**
   * Swift `clearConversationsData(accountId:)` - clears the daemon's per-conversation cache of
   * the account being left. The daemon never re-sends a message it already loaded, so without
   * this a later reload of that account gets an older message or nothing as the last one (T-1613).
   */
  clearConversationsData(accountId: string): void {
    this.enqueue(async () => {
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'clearConversationsData %{public}s', accountId);
      for (const conversation of this.conversations.value) {
        jami.clearCache(accountId, conversation.id);
      }
    });
  }

  /** Swift `getSwarmMembers(...)` - the member list lives in the daemon. */
  getSwarmMembers(conversationId: string, accountId: string, accountURI: string): ParticipantData[] {
    const members: ParticipantData[] = [];
    for (const info of jami.getConversationMembers(accountId, conversationId)) {
      const jamiId: string | undefined = info['uri'];
      const roleText: string | undefined = info['role'];
      if (jamiId !== undefined && roleText !== undefined) {
        const role: ParticipantRole = Object.values(ParticipantRole).indexOf(roleText as ParticipantRole) >= 0
          ? roleText as ParticipantRole : ParticipantRole.MEMBER;
        members.push(new ParticipantData(jamiId, role));
      }
    }
    return members;
  }

  /** Swift `updateConversationMessages(conversationId:)` - local clear, daemon reload. */
  updateConversationMessages(conversationId: string): void {
    for (const conversation of this.conversations.value) {
      if (conversation.id === conversationId) {
        conversation.clearMessages();
        this.loadConversationMessages(conversationId, conversation.accountId, '', 40);
      }
    }
  }

  /** Swift `reloadConversationsAndRequests(accountId:)`. */
  reloadConversationsAndRequests(accountId: string): void {
    this.getConversationsForAccount(accountId,
      ServiceRegistry.shared().accountService.getAccount(accountId)?.jamiId ?? '');
  }

  /**
   * Swift `private func addSwarm(...)`. Both values it needs (`getConversationInfo`,
   * `getConversationMembers`) come from the daemon, so nothing can be appended.
   */
  private addSwarm(conversationId: string, accountId: string, accountURI: string,
    conversations: ConversationModel[], reusing: ConversationModel[] = []): void {
    const info: Map<string, string> = toMap(jami.conversationInfos(accountId, conversationId));
    const participantsInfo: Array<Map<string, string>> = this.membersOf(accountId, conversationId);
    // Swift `makeRecord(id:accountId:info:reusing:)`.
    const existing: ConversationModel | undefined = reusing.find((candidate: ConversationModel) =>
      candidate.id === conversationId && candidate.accountId === accountId);
    let conversation: ConversationModel;
    if (existing !== undefined) {
      conversation = existing;
      conversation.updateInfo(info);
    } else {
      // A new model holds no message, but the daemon never re-sends one it cached. A commit that
      // reached this account while another one was current was cached and dropped here (no
      // model to insert into), so it showed only after a relaunch: the join line of a member who
      // joined from the other local account (T-1598). Start the daemon's cache empty as well.
      jami.clearCache(accountId, conversationId);
      conversation = ConversationModel.withInfo(conversationId, accountId, info);
    }
    this.configureConversation(conversation, accountId, conversationId, participantsInfo, accountURI);
    conversations.push(conversation);
  }

  private membersOf(accountId: string, conversationId: string): Array<Map<string, string>> {
    return jami.getConversationMembers(accountId, conversationId).map((m: StringMap) => toMap(m));
  }

  /**
   * Swift `addConversationFromAcceptedRequest(...)`. Swift itself returns early when the
   * adapter has no data yet and lets `conversationReady` pick it up later; with no daemon that
   * early return is the only path.
   */
  addConversationFromAcceptedRequest(conversationId: string, accountId: string, accountURI: string,
    type: ConversationType): void {
    this.enqueue(async () => {
      if (this.getConversationForId(conversationId, accountId) !== null) {
        return;
      }
      const info: Map<string, string> = toMap(jami.conversationInfos(accountId, conversationId));
      const participantsInfo: Array<Map<string, string>> = this.membersOf(accountId, conversationId);
      if (info.size === 0 || participantsInfo.length === 0) {
        // Adapter data not ready yet; the daemon's conversationReady will handle it later.
        return;
      }
      const conversation: ConversationModel = ConversationModel.withId(conversationId, accountId, type);
      conversation.updateInfo(info);
      conversation.updateProfile(info);
      this.configureConversation(conversation, accountId, conversationId, participantsInfo, accountURI);
      const current: ConversationModel[] = this.conversations.value.slice();
      current.push(conversation);
      this.publishNewConversation(conversationId, accountId, current);
    });
  }

  /** Swift `private func configureConversation(...)` - preferences, participants, last seen. */
  private configureConversation(conversation: ConversationModel, accountId: string,
    conversationId: string, participantsInfo: Array<Map<string, string>>,
    accountURI: string): void {
    const prefsInfo: Map<string, string> | null =
      this.getConversationPreferences(accountId, conversationId);
    if (prefsInfo !== null) {
      conversation.updatePreferences(prefsInfo);
    }
    conversation.addParticipantsFromArray(participantsInfo, accountURI);
    conversation.updateLastDisplayedMessage(participantsInfo);
  }

  /** Swift `private func publishNewConversation(...)`. Returns the sorted list Swift wrote back. */
  private publishNewConversation(conversationId: string, accountId: string,
    conversations: ConversationModel[]): ConversationModel[] {
    const sorted: ConversationModel[] = this.sortAndUpdate(conversations);

    const created: ConversationModel | undefined =
      sorted.find((conversation: ConversationModel) => conversation.id === conversationId);
    if (created !== undefined) {
      this.scheduleUnreadCount(created, accountId);
    }

    this.conversationReadyNotifications.onNext(
      new ConversationReadyNotice(conversationId, accountId));

    this.loadConversationMessages(conversationId, accountId, '', 2);
    this.sortIfNeeded();
    this.conversationReadyEvents.accept(conversationId);
    return sorted;
  }

  /** Swift `private func sortAndUpdate(conversations:)` - newest last message first. */
  private sortAndUpdate(conversations: ConversationModel[]): ConversationModel[] {
    const sorted: ConversationModel[] = conversations.slice().sort(
      (first: ConversationModel, second: ConversationModel) => {
        const firstLast: MessageModel | null = first.lastMessage;
        const secondLast: MessageModel | null = second.lastMessage;
        if (firstLast === null || secondLast === null) {
          // Swift: `conversation1.messages.count > conversations2.messages.count`
          return second.messages.length - first.messages.length;
        }
        return secondLast.receivedDate.getTime() - firstLast.receivedDate.getTime();
      });
    this.conversations.accept(sorted);
    return sorted;
  }

  /** Swift `private func loadLatestMessages(swarmIds:accountId:)`. */
  private loadLatestMessages(swarmIds: string[], accountId: string): void {
    for (const swarmId of swarmIds) {
      this.loadConversationMessages(swarmId, accountId, '', 1);
    }
  }

  /** Swift `private func scheduleUnreadCounts(for:accountId:)`. */
  private scheduleUnreadCounts(conversations: ConversationModel[], accountId: string): void {
    for (const conversation of conversations) {
      if (conversation.isSwarm()) {
        this.scheduleUnreadCount(conversation, accountId);
      }
    }
  }

  /** Swift `private func scheduleUnreadCount(for:accountId:)`. */
  private scheduleUnreadCount(conversation: ConversationModel, accountId: string): void {
    this.enqueue(async () => {
      this.updateUnreadMessages(conversation, accountId);
    });
  }

  /**
   * Swift `private func updateUnreadMessages(...)` - the count itself is
   * `conversationsAdapter.countInteractions`, a daemon call. The local half (is there a last
   * read message at all) still runs, so the relay keeps whatever count the DB gave it rather
   * than being overwritten with a made-up number.
   */
  private updateUnreadMessages(conversation: ConversationModel, accountId: string): void {
    const lastRead: string | null = conversation.getLastReadMessage();
    const local: ConversationParticipant | null = conversation.getLocalParticipants();
    if (lastRead === null || local === null) {
      return;
    }
    // Swift `countUnreadMessages`' `lastRead != record.lastReadMarkedAsRead` guard (T-1631).
    if (lastRead === conversation.lastReadMarkedAsRead) {
      hilog.info(LOG_DOMAIN, 'JamiF5', 'chat %{public}s recount skipped: last read %{public}s already marked read',
        conversation.id, lastRead);
      return;
    }
    const unread: number = jami.countInteractions(accountId, conversation.id, lastRead, '', local.jamiId);
    conversation.numberOfUnreadMessages.accept(unread);
  }

  /** Swift `private func sortIfNeeded()` - re-sorts only when the order actually broke. */
  private sortIfNeeded(): void {
    this.enqueue(async () => {
      const dates: number[] = this.conversations.value.map((conversation: ConversationModel) => {
        const last: MessageModel | null = conversation.lastMessage;
        return last === null ? Date.now() : last.receivedDate.getTime();
      });
      // Swift `Array.isDescending()`.
      let descending: boolean = true;
      for (let index: number = 1; index < dates.length; index++) {
        if (dates[index - 1] < dates[index]) {
          descending = false;
          break;
        }
      }
      if (!descending) {
        this.sortAndUpdate(this.conversations.value);
      }
    });
  }

  // MARK: - swarm interactions management

  /** Swift `loadConversationMessages(...)` - the daemon owns swarm history. */
  loadConversationMessages(conversationId: string, accountId: string, from: string,
    size: number = 40): void {
    jami.loadConversation(accountId, conversationId, from, size);
  }

  /** Swift `loadMessagesUntil(...)`. */
  loadMessagesUntil(messageId: string, conversationId: string, accountId: string,
    from: string): void {
    jami.loadConversationUntil(accountId, conversationId, from, messageId);
  }

  /**
   * Swift `loadTargetReply(...)`. The registry half is real: a duplicate request is still
   * rejected and an already-loaded target is still returned. Only the load itself is a gap.
   */
  loadTargetReply(conversationId: string, accountId: string, target: string): LoadReplyResult {
    if (!this.replyTargetRegistry.request(target)) {
      return new LoadReplyResult(LoadReplyResultKind.DUPLICATE_REQUEST);
    }
    const message: MessageModel | null = this.replyTargetRegistry.target(target);
    if (message !== null) {
      return new LoadReplyResult(LoadReplyResultKind.MESSAGE_FOUND, message);
    }
    this.triggerConversationLoad(accountId, conversationId, target);
    return new LoadReplyResult(LoadReplyResultKind.LOAD_TRIGGERED);
  }

  /**
   * Swift `private func triggerConversationLoad(...)`: `loadConversation(from: replyToId,
   * until: replyToId)`. A size-1 `loadConversation` marks the target as loaded in the daemon,
   * so the history page that later covers it skips it and the message vanishes from the chat.
   */
  private triggerConversationLoad(accountId: string, conversationId: string,
    replyToId: string): void {
    jami.loadConversationUntil(accountId, conversationId, replyToId, replyToId);
  }

  /** Swift `getReplyMessage(...)`. */
  getReplyMessage(conversationId: string, accountId: string, id: string): void {
    jami.loadConversation(accountId, conversationId, id, 1);
  }

  /** Swift `editSwarmMessage(...)` - `sendSwarmMessage(flag: 1)`. */
  editSwarmMessage(conversationId: string, accountId: string, message: string,
    parentId: string): void {
    jami.sendMessage(accountId, conversationId, message, parentId, 1);
  }

  /** Swift `sendEmojiReactionMessage(...)` - `sendSwarmMessage(flag: 2)`. */
  sendEmojiReactionMessage(conversationId: string, accountId: string, message: string,
    parentId: string): void {
    jami.sendMessage(accountId, conversationId, message, parentId, 2);
  }

  /** Swift `sendSwarmMessage(...)` - `sendSwarmMessage(flag: 0)`. */
  sendSwarmMessage(conversationId: string, accountId: string, message: string,
    parentId: string): void {
    jami.sendMessage(accountId, conversationId, message, parentId, 0);
  }

  /**
   * CONTRACT `outOfScope`: in-call text messages ride the daemon's call channel, which is part
   * of the libjami gap. The member exists with the source's shape and reports unavailable; it is
   * deliberately not implemented. (Swift declares it on CallService; the module contract
   * attributes it here.)
   */
  sendInCallMessage(callId: string, message: string, account: AccountModel): DaemonUnavailableError {
    return this.gap('conversation.sendInCallMessage');
  }

  // MARK: - actions for ConversationsManager

  /**
   * Swift `insertMessages(...)`. Entirely in-memory, so it is a real port: dedupe, the
   * merge/profile/vote filter, the "nothing new, load further back" continuation, last-message and
   * unread bookkeeping, and the `newMessages` emission.
   * @returns true if at least one message was inserted.
   */
  insertMessages(messages: MessageModel[], accountId: string, localJamiId: string,
    conversationId: string, fromLoaded: boolean): boolean {
    const conversation: ConversationModel | undefined = this.conversations.value
      .find((item: ConversationModel) => item.id === conversationId &&
        item.accountId === accountId);
    if (conversation === undefined) {
      return false;
    }

    if (this.isTargetReply(messages)) {
      this.processReplyTargetMessage(messages.length > 0 ? messages[0] : null);
      return true;
    }

    const filtered: MessageModel[] = messages.filter((newMessage: MessageModel) => {
      const isNoise: boolean = newMessage.type === MessageType.MERGE ||
        newMessage.type === MessageType.PROFILE || newMessage.type === MessageType.VOTE;
      const known: boolean = conversation.messages
        .some((message: MessageModel) => message.id === newMessage.id);
      return !isNoise && !known;
    });

    if (fromLoaded && filtered.length === 0) {
      const last: MessageModel | undefined = messages[messages.length - 1];
      if (last !== undefined) {
        this.loadConversationMessages(conversationId, accountId, last.id, 40);
      }
      return false;
    }

    const newMessages: MessageModel[] = [];
    for (const newMessage of filtered) {
      newMessages.push(newMessage);
      const last: MessageModel | null = conversation.lastMessage;
      if (last === null || last.receivedDate.getTime() <= newMessage.receivedDate.getTime()) {
        conversation.lastMessage = newMessage;
      }
    }

    if (fromLoaded) {
      conversation.messages = conversation.messages.concat(newMessages);
    } else {
      conversation.messages = newMessages.concat(conversation.messages);
    }

    this.sortIfNeeded();

    if (!fromLoaded) {
      const incoming: MessageModel[] = newMessages.filter((message: MessageModel) =>
        message.authorId !== localJamiId && message.authorId.length > 0);
      conversation.updateUnreadMessages(incoming.length);
    }

    conversation.newMessages.accept(new LoadedMessages(newMessages, fromLoaded));
    return true;
  }

  /** Swift `private func isTargetReply(messages:)`. */
  private isTargetReply(messages: MessageModel[]): boolean {
    const target: MessageModel | undefined = messages[0];
    return messages.length === 1 && target !== undefined &&
      this.replyTargetRegistry.isRequested(target.id);
  }

  /** Swift `private func processReplyTargetMessage(with:)`. */
  private processReplyTargetMessage(message: MessageModel | null): void {
    if (message === null) {
      return;
    }
    this.replyTargetRegistry.resolve(message);
  }

  /**
   * Swift `conversationReady(conversationId:accountId:accountURI:)`. The refresh reads
   * `getConversationInfo`/`getConversationMembers` from the daemon, so an existing conversation
   * cannot be re-synced; the relay still fires, which is what the UI waits on.
   */
  conversationReady(conversationId: string, accountId: string, accountURI: string): void {
    const conversation: ConversationModel | null =
      this.getConversationForId(conversationId, accountId);
    if (conversation === null) {
      const current: ConversationModel[] = this.conversations.value.slice();
      this.addSwarm(conversationId, accountId, accountURI, current);
      this.publishNewConversation(conversationId, accountId, current);
      return;
    }
    const info: Map<string, string> = toMap(jami.conversationInfos(accountId, conversationId));
    const participantsInfo: Array<Map<string, string>> = this.membersOf(accountId, conversationId);
    conversation.updateInfo(info);
    const prefsInfo: Map<string, string> | null = this.getConversationPreferences(accountId, conversationId);
    if (prefsInfo !== null) {
      conversation.updatePreferences(prefsInfo);
    }
    conversation.addParticipantsFromArray(participantsInfo, accountURI);
    this.scheduleUnreadCount(conversation, accountId);
    this.loadConversationMessages(conversationId, accountId, '', 2);
    this.sortIfNeeded();
    this.conversationReadyEvents.accept(conversationId);
  }

  /** Swift `getConversationInfo(conversationId:accountId:)`. */
  getConversationInfo(conversationId: string, accountId: string): Map<string, string> {
    return toMap(jami.conversationInfos(accountId, conversationId));
  }

  /** Swift `conversationRemoved(conversationId:accountId:)` - in-memory removal + event. */
  conversationRemoved(conversationId: string, accountId: string): void {
    const remaining: ConversationModel[] = this.conversations.value
      .filter((conversation: ConversationModel) =>
        !(conversation.id === conversationId && conversation.accountId === accountId));
    if (remaining.length === this.conversations.value.length) {
      return;
    }
    this.conversations.accept(remaining);
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONVERSATION_REMOVED);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  /**
   * Swift `conversationMemberEvent(...)`. The refreshed member list is a daemon read, and Swift
   * emits the event only once it has one, so the gap stops before the emission rather than
   * publishing an event that says nothing changed.
   */
  conversationMemberEvent(conversationId: string, accountId: string, accountURI: string): void {
    const conversation: ConversationModel | null = this.getConversationForId(conversationId, accountId);
    if (conversation === null) {
      return;
    }
    conversation.addParticipantsFromArray(this.membersOf(accountId, conversationId), accountURI);
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONVERSATION_MEMBER_EVENT);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  /** Swift `reactionAdded(...)` - the reaction is already in hand; purely local. */
  reactionAdded(conversationId: string, accountId: string, messageId: string,
    reaction: Map<string, string>): void {
    const conversation: ConversationModel | null =
      this.getConversationForId(conversationId, accountId);
    if (conversation === null) {
      return;
    }
    conversation.reactionAdded(messageId, reaction);
  }

  /** Swift `reactionRemoved(...)`. */
  reactionRemoved(conversationId: string, accountId: string, messageId: string,
    reactionId: string): void {
    const conversation: ConversationModel | null =
      this.getConversationForId(conversationId, accountId);
    if (conversation === null) {
      return;
    }
    conversation.reactionRemoved(messageId, reactionId);
  }

  /** Swift `composingStatusChanged(...)` - the typing indicator. */
  composingStatusChanged(accountId: string, conversationId: string, from: string,
    status: number): void {
    if (this.getConversationForId(conversationId, accountId) === null) {
      return;
    }
    this.typingStatusSubject.onNext(new TypingStatus(from, status, conversationId));
  }

  /** Swift `messageUpdated(...)`. */
  messageUpdated(conversationId: string, accountId: string, message: SwarmMessageWrap,
    localJamiId: string): void {
    const conversation: ConversationModel | null =
      this.getConversationForId(conversationId, accountId);
    if (conversation === null) {
      return;
    }
    conversation.messageUpdated(message, localJamiId);
  }

  // MARK: - conversations management

  /** Swift `removeConversation(conversationId:accountId:)`. */
  removeConversation(conversationId: string, accountId: string): void {
    jami.removeConversation(accountId, conversationId);
  }

  /** Swift `startConversation(accountId:) -> String` - the daemon mints the swarm id. */
  startConversation(accountId: string): string {
    return jami.startConversation(accountId);
  }

  // MARK: - legacy support for non swarm conversations

  /**
   * Swift `private func saveMessageModelToDb(...)`. Fully real: the row is written, the saved
   * id is copied back onto the model, and the in-memory conversation is updated so a status
   * update arriving before the list reloads still finds the message.
   */
  private async saveMessageModelToDb(message: MessageModel, recipientURI: string,
    toAccountId: string, duration: number, shouldRefreshConversations: boolean,
    interactionType: InteractionType = InteractionType.TEXT): Promise<void> {
    const database: ConversationsDb | null = this.requireDatabase('saveMessage');
    if (database === null) {
      return;
    }
    const saved: SavedMessageForConversation = await database.saveMessage(toAccountId,
      recipientURI, message, message.incoming, interactionType as string, duration);
    const hash: string | null = JamiUri.parse(recipientURI).hash;
    if (!shouldRefreshConversations || hash === null) {
      return;
    }
    const conversation: ConversationModel | undefined = this.conversations.value
      .find((item: ConversationModel) => this.firstParticipantJamiId(item) === hash &&
        item.accountId === toAccountId);
    if (conversation === undefined) {
      return;
    }
    message.content = this.displayContent(message, duration);
    message.id = saved.messageID;
    conversation.appendNonSwarm(message);
    const last: MessageModel | null = conversation.lastMessage;
    if (last === null || last.receivedDate.getTime() < message.receivedDate.getTime()) {
      conversation.lastMessage = message;
    }
    this.sortIfNeeded();
  }

  /**
   * Swift `sendNonSwarmMessage(withContent:from:jamiId:)`: `conversationsAdapter.sendMessage`
   * (libjami `sendAccountTextMessage`, flag 0) to the peer, then the message is saved under the
   * peer's URI - for SIP with the account's host and port, as incoming SIP messages are (T-0892).
   */
  sendNonSwarmMessage(content: string, senderAccount: AccountModel,
    jamiId: string): Promise<void> {
    const payload: Record<string, string> = {};
    payload[this.textPlainMIMEType] = content;
    const messageId: string = String(jami.sendAccountTextMessage(senderAccount.id, jamiId, payload, 0));
    const isSip: boolean = senderAccount.type === AccountType.SIP;
    const details: AccountConfigModel | null = senderAccount.details;
    const contactUri: string | null = JamiUri.fromInfoHash(isSip ? UriType.SIP : UriType.RING, jamiId,
      isSip && details !== null ? details.getValue(ConfigKey.ACCOUNT_HOSTNAME) : '',
      isSip && details !== null ? details.getValue(ConfigKey.LOCAL_PORT) : '').uriString;
    if (contactUri === null) {
      return Promise.resolve();
    }
    const message: MessageModel =
      this.createMessage(messageId, content, senderAccount.jamiId, MessageType.TEXT, false);
    // A first message to a new number creates the database conversation, which only a reload
    // brings into the list (and the open temporary chat onto it).
    const known: boolean = this.getConversationForParticipant(jamiId, senderAccount.id) !== null;
    return this.saveMessage(message, contactUri, senderAccount.id, true).then((): void => {
      if (!known) {
        this.reloadConversationsAndRequests(senderAccount.id);
      }
    });
  }

  /** Swift `createMessage(withId:withContent:byAuthor:type:incoming:)`. */
  createMessage(messageId: string, content: string, author: string, type: MessageType,
    incoming: boolean): MessageModel {
    const message: MessageModel = new MessageModel(messageId, new Date(), content, author,
      incoming);
    message.type = type;
    return message;
  }

  /** Swift `saveMessage(message:toConversationWith:toAccountId:shouldRefreshConversations:)`. */
  saveMessage(message: MessageModel, jamiId: string, toAccountId: string,
    shouldRefreshConversations: boolean): Promise<void> {
    return this.saveMessageModelToDb(message, jamiId, toAccountId, 0,
      shouldRefreshConversations, InteractionType.TEXT);
  }

  /**
   * Swift declares `generateMessage` twice - a 6-parameter form whose only extra job is the
   * "do not add the same contact interaction twice" guard, and a 7-parameter form taking a
   * duration. ArkTS has no overloads, so this is the single method: the guard runs, then the
   * row is written with `duration` (0 by default, which is what the short form passed).
   */
  generateMessage(messageContent: string, contactUri: string, accountId: string, date: Date,
    interactionType: InteractionType, shouldUpdateConversation: boolean,
    duration: number = 0): void {
    const hash: string | null = JamiUri.parse(contactUri).hash;
    if (hash !== null && interactionType === InteractionType.CONTACT) {
      const conversation: ConversationModel | null =
        this.getConversationForParticipant(hash, accountId);
      if (conversation !== null && conversation.messages
        .some((message: MessageModel) => message.content === messageContent)) {
        return;
      }
    }
    const message: MessageModel = new MessageModel('', date, messageContent, '', false);
    message.type = interactionTypeToMessageType(interactionType);
    if (interactionType === InteractionType.CONTACT) {
      // Swift `InteractionType.contact -> MessageType.contact(.add)`; ArkTS carries the payload
      // on the model, so the action is set beside the type.
      message.contactAction = ContactAction.ADD;
    }
    this.saveMessageModelToDb(message, contactUri, accountId, duration,
      shouldUpdateConversation, interactionType)
      .catch((err: Error) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'generateMessage failed: %{public}s', err.message);
      });
  }

  /** Swift `deleteMessage(messagesId:accountId:)`. Real - the row is in the local database. */
  async deleteMessage(messagesId: number, accountId: string): Promise<void> {
    const database: ConversationsDb | null = this.requireDatabase('deleteMessage');
    if (database === null) {
      return;
    }
    await database.deleteMessage(messagesId, accountId);
  }

  /**
   * Swift `removeConversationFromDB(conversation:keepConversation:)`. Real: history is cleared,
   * the downloaded/recorded files are deleted, the conversation leaves the list, and - unless
   * it is being kept - the removal event is published. Swift runs the same `finish` closure on
   * success and on error, so the cleanup happens either way.
   */
  async removeConversationFromDB(conversation: ConversationModel,
    keepConversation: boolean): Promise<void> {
    const jamiId: string | null = this.firstParticipantJamiId(conversation);
    if (jamiId === null) {
      return;
    }
    const schema: UriType = conversation.isSip() ? UriType.SIP : UriType.RING;
    const uri: string | null = JamiUri.fromInfoHash(schema, jamiId).uriString;
    if (uri === null) {
      return;
    }
    const database: ConversationsDb | null = this.requireDatabase('removeConversationFromDB');
    if (database !== null) {
      try {
        await database.clearHistoryFor(conversation.accountId, uri, keepConversation);
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'clearHistoryFor failed: %{public}s',
          describeError(err as BusinessError));
      }
    }
    this.removeSavedFiles(conversation.accountId, conversation.id);
    const remaining: ConversationModel[] = this.conversations.value
      .filter((item: ConversationModel) => !item.equals(conversation));
    if (remaining.length !== this.conversations.value.length) {
      this.conversations.accept(remaining);
    }
    if (!keepConversation) {
      const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONVERSATION_REMOVED);
      event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversation.id);
      event.addEventInput(ServiceEventInput.ACCOUNT_ID, conversation.accountId);
      event.addEventInput(ServiceEventInput.PEER_URI, uri);
      this.responseStream.onNext(event);
    }
  }

  /**
   * Swift `private func removeSavedFiles(accountId:conversationId:)`. Swift used
   * `Constants.documentsPath`; the HarmonyOS equivalent is the ability's `filesDir`. Swift's
   * `try?` swallows a missing directory, so both removals are individually guarded.
   */
  private removeSavedFiles(accountId: string, conversationId: string): void {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'no context; saved files kept (call setContext at startup)');
      return;
    }
    const root: string = context.filesDir;
    const directories: string[] = [
      `${root}/${DIRECTORY_DOWNLOADS}/${accountId}/${conversationId}`,
      `${root}/${DIRECTORY_RECORDED}/${accountId}/${conversationId}`
    ];
    for (const directory of directories) {
      try {
        fs.rmdirSync(directory);
      } catch (err) {
        hilog.debug(LOG_DOMAIN, LOG_TAG, 'nothing to remove at %{public}s: %{public}s', directory,
          describeError(err as BusinessError));
      }
    }
  }

  /**
   * Swift `createSipConversation(uri:accountId:)`. Purely local: create the account database if
   * it is not there, insert the conversation, and reload the list if it is genuinely new.
   */
  async createSipConversation(uri: string, accountId: string): Promise<void> {
    const database: ConversationsDb | null = this.requireDatabase('createSipConversation');
    if (database === null) {
      return;
    }
    try {
      // Swift: `if try !dbManager.createDatabaseForAccount(...) { return }`; a throw there means
      // the tables already exist, which is not an error.
      const created: boolean = await database.createDatabaseForAccount(accountId);
      if (!created) {
        return;
      }
    } catch (err) {
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'database already present: %{public}s',
        describeError(err as BusinessError));
    }
    const conversationId: string = await database.createConversationsFor(uri, accountId);
    const known: boolean = this.conversations.value
      .some((conversation: ConversationModel) => conversation.id === conversationId);
    if (known) {
      return;
    }
    try {
      const reloaded: ConversationModel[] = await database.getConversationsObservable(accountId);
      this.conversations.accept(reloaded);
      this.sortIfNeeded();
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'reloading conversations failed: %{public}s',
        describeError(err as BusinessError));
    }
  }

  // MARK: - helpers

  /** Swift `getConversationForParticipant(jamiId:accountId:)`. */
  getConversationForParticipant(jamiId: string, accountId: string): ConversationModel | null {
    const found: ConversationModel | undefined = this.conversations.value
      .find((conversation: ConversationModel) =>
        this.firstParticipantJamiId(conversation) === jamiId && conversation.isCoredialog() &&
        conversation.accountId === accountId);
    return found === undefined ? null : found;
  }

  /** Swift `getConversationForId(conversationId:accountId:)`. */
  getConversationForId(conversationId: string, accountId: string): ConversationModel | null {
    const found: ConversationModel | undefined = this.conversations.value
      .find((conversation: ConversationModel) => conversation.id === conversationId &&
        conversation.accountId === accountId);
    return found === undefined ? null : found;
  }

  /** Swift `addSwarmConversationId(conversationId:accountId:jamiId:)` - in-memory placeholder. */
  addSwarmConversationId(conversationId: string, accountId: string, jamiId: string): void {
    this.enqueue(async () => {
      if (this.getConversationForId(conversationId, accountId) !== null) {
        return;
      }
      const conversation: ConversationModel =
        ConversationModel.withId(conversationId, accountId, ConversationType.ONE_TO_ONE);
      conversation.addParticipant(jamiId);
      const updated: ConversationModel[] = this.conversations.value.slice();
      updated.push(conversation);
      this.conversations.accept(updated);
    });
  }

  // MARK: - file transfer

  /**
   * Swift `generateDataTransferMessage(...)`. Real: the transfer row is written to the local
   * database and the `dataTransferMessageUpdated` event is published. The transfer itself is
   * DataTransferService's business; this only records it.
   */
  async generateDataTransferMessage(transferId: string, transferInfo: DataTransferInfo,
    accountId: string, photoIdentifier: string | null, updateConversation: boolean,
    conversationId: string, messageId: string): Promise<void> {
    const database: ConversationsDb | null = this.requireDatabase('generateDataTransferMessage');
    if (database === null) {
      return;
    }
    const fileSizeWithUnit: string = formatFileSize(transferInfo.totalSize);
    let messageContent: string = `${transferInfo.displayName}\n${fileSizeWithUnit}`;
    if (photoIdentifier !== null) {
      messageContent = `${transferInfo.displayName}\n${fileSizeWithUnit}\n${photoIdentifier}`;
    }
    const isIncoming: boolean = transferInfo.flags === 1;
    const interactionType: InteractionType =
      isIncoming ? InteractionType.I_TRANSFER : InteractionType.O_TRANSFER;
    const contactUri: string | null =
      JamiUri.fromInfoHash(UriType.RING, transferInfo.peer).uriString;
    if (contactUri === null) {
      return;
    }
    const author: string = isIncoming ? contactUri : '';
    const message: MessageModel =
      new MessageModel(transferId, new Date(), messageContent, author, isIncoming);
    message.transferStatus = isIncoming ? DataTransferStatus.AWAITING : DataTransferStatus.CREATED;
    message.type = MessageType.FILE_TRANSFER;

    const saved: SavedMessageForConversation = await database.saveMessage(accountId, contactUri,
      message, isIncoming, interactionType as string, 0);
    const hash: string | null = JamiUri.parse(contactUri).hash;
    if (updateConversation && hash !== null) {
      const conversation: ConversationModel | undefined = this.conversations.value
        .find((item: ConversationModel) => this.firstParticipantJamiId(item) === hash &&
          item.accountId === accountId);
      if (conversation !== undefined) {
        message.content = this.displayContent(message, 0);
        message.id = saved.messageID;
        message.daemonId = transferId;
        conversation.appendNonSwarm(message);
        this.sortIfNeeded();
      }
    }
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.DATA_TRANSFER_MESSAGE_UPDATED);
    event.addEventInput(ServiceEventInput.TRANSFER_ID, transferId);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    event.addEventInput(ServiceEventInput.STATE, DataTransferStatus.CREATED as string);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.MESSAGE_ID, messageId);
    this.responseStream.onNext(event);
  }

  /**
   * Swift `transferStatusChanged(...)`. Real end to end: the in-memory message, the published
   * event, and - for a non-swarm conversation - the database row.
   */
  transferStatusChanged(transferStatus: DataTransferStatus, transferId: string,
    conversationId: string, interactionId: string, accountId: string, jamiId: string): void {
    this.enqueue(async () => {
      const conversation: ConversationModel | null = conversationId.length > 0
        ? this.getConversationForId(conversationId, accountId)
        : this.getConversationForParticipant(jamiId, accountId);
      if (conversation === null) {
        return;
      }
      const message: MessageModel | undefined = conversation.messages
        .find((item: MessageModel) => item.id === interactionId);
      if (message !== undefined) {
        message.transferStatus = transferStatus;
      }
      const event: ServiceEvent = new ServiceEvent(ServiceEventType.DATA_TRANSFER_MESSAGE_UPDATED);
      event.addEventInput(ServiceEventInput.TRANSFER_ID, transferId);
      event.addEventInput(ServiceEventInput.STATE, transferStatus as string);
      this.responseStream.onNext(event);

      if (conversation.isSwarm()) {
        return;
      }
      const database: ConversationsDb | null = this.requireDatabase('updateTransferStatus');
      if (database === null) {
        return;
      }
      try {
        await database.updateTransferStatus(transferId, transferStatus as string, accountId);
      } catch (err) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'updateTransferStatus failed: %{public}s',
          describeError(err as BusinessError));
      }
    });
  }

  /**
   * Swift `setMessagesAsRead(forConversation:accountId:accountURI:)`. The local half is real -
   * non-swarm rows are marked read in the database and every message is marked read in memory.
   * Telling the PEER (`setMessageDisplayedFrom`) is a daemon call, so the read receipt does not
   * leave the device.
   */
  async setMessagesAsRead(conversation: ConversationModel, accountId: string,
    accountURI: string): Promise<void> {
    const conversationURI: string | null = conversation.getConversationURI();
    if (conversationURI === null) {
      return;
    }
    let lastUnreadMessageId: string | null = null;

    if (conversation.isSwarm()) {
      const first: MessageModel | undefined = conversation.messages[0];
      lastUnreadMessageId = first === undefined ? null : first.id;
    } else {
      const unread: MessageModel[] = conversation.messages
        .filter((message: MessageModel) => message.status !== MessageStatus.DISPLAYED &&
          message.incoming && message.type === MessageType.TEXT);
      const ids: string[] = unread
        .map((message: MessageModel) => message.id)
        .filter((id: string) => id.length > 0);
      const database: ConversationsDb | null = this.requireDatabase('setMessagesAsRead');
      if (database !== null && ids.length > 0) {
        try {
          await database.setMessagesAsRead(ids, MessageStatus.DISPLAYED as number, accountId);
        } catch (err) {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'setMessagesAsRead failed: %{public}s',
            describeError(err as BusinessError));
        }
      }
      const last: MessageModel | undefined = unread[unread.length - 1];
      lastUnreadMessageId = last === undefined ? null : last.id;
    }

    conversation.setAllMessagesAsRead();

    if (lastUnreadMessageId !== null) {
      jami.setMessageDisplayed(accountId, conversationURI, lastUnreadMessageId, MessageStatus.DISPLAYED as number);
    }
  }

  /** Swift `messageStatusChanged(_:for:from:to:in:)` - purely local. */
  messageStatusChanged(status: MessageStatus, messageId: string, accountId: string,
    jamiId: string, conversationId: string): void {
    const conversation: ConversationModel | undefined = this.conversations.value
      .find((item: ConversationModel) => {
        if (conversationId.length > 0) {
          return item.id === conversationId && item.accountId === accountId;
        }
        return this.firstParticipantJamiId(item) === jamiId && item.accountId === accountId;
      });
    if (conversation === undefined) {
      return;
    }
    conversation.messageStatusUpdated(status, messageId, jamiId);
  }

  /** Swift `conversationProfileUpdated(...)` - the profile arrives with the event; local. */
  conversationProfileUpdated(conversationId: string, accountId: string,
    profile: Map<string, string>): void {
    const conversation: ConversationModel | undefined = this.conversations.value
      .find((item: ConversationModel) => item.id === conversationId &&
        item.accountId === accountId);
    if (conversation === undefined) {
      // T-1617: a document is a repository of its own (mode 4, daemon ConversationMode::DOCUMENT).
      // A rename fetched from another member is announced here (Conversation::pull, profile.vcf
      // changed); the daemon's CollaborativeDocumentRenamed only follows when this device has
      // the document open since the daemon started, so without this the chat card kept the old
      // name until the chat was rebuilt.
      const title: string | undefined = profile.get('title');
      if (profile.get('mode') === '4' && title !== undefined && title.length > 0) {
        hilog.info(LOG_DOMAIN, 'JamiF4', 'document %{public}s renamed by a sync', conversationId);
        ServiceRegistry.shared().collaborationService.documentRenamed(accountId, '', conversationId,
          title);
      }
      return;
    }
    conversation.updateProfile(profile);
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONVERSATION_PROFILE_UPDATED);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  /** Swift `conversationPreferencesUpdated(...)` - local. */
  conversationPreferencesUpdated(conversationId: string, accountId: string,
    preferences: Map<string, string>): void {
    const conversation: ConversationModel | undefined = this.conversations.value
      .find((item: ConversationModel) => item.id === conversationId &&
        item.accountId === accountId);
    if (conversation === undefined) {
      return;
    }
    conversation.updatePreferences(preferences);
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONVERSATION_PREFERENCES_UPDATED);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  /** Swift `getConversationPreferences(accountId:conversationId:)` - the daemon stores them. */
  getConversationPreferences(accountId: string, conversationId: string): Map<string, string> | null {
    return toMap(jami.getConversationPreferences(accountId, conversationId));
  }

  /** Swift `updateConversationInfos(accountId:conversationId:infos:)`. */
  updateConversationInfos(accountId: string, conversationId: string,
    infos: Map<string, string>): void {
    jami.updateConversationInfos(accountId, conversationId, toRecord(infos));
  }

  /** Swift `updateConversationPrefs(accountId:conversationId:prefs:)`. */
  updateConversationPrefs(accountId: string, conversationId: string,
    prefs: Map<string, string>): void {
    jami.setConversationPreferences(accountId, conversationId, toRecord(prefs));
  }

  /** Swift `addConversationMember(accountId:conversationId:memberId:)`. */
  addConversationMember(accountId: string, conversationId: string, memberId: string): void {
    jami.addConversationMember(accountId, conversationId, memberId);
  }

  /** Swift `removeConversationMember(accountId:conversationId:memberId:)`. */
  removeConversationMember(accountId: string, conversationId: string, memberId: string): void {
    jami.removeConversationMember(accountId, conversationId, memberId);
  }

  // MARK: - typing indicator

  /** Swift `setIsComposingMsg(to:from:isComposing:)` - the peer is told over the daemon. */
  setIsComposingMsg(conversationUri: string, accountId: string, isComposing: boolean): void {
    jami.setIsComposing(accountId, conversationUri, isComposing);
  }

  // MARK: - Location (Swift `extension ConversationsService`)

  /**
   * Swift `sendLocation(...)` - `sendMessage(flag: 1)` with the `application/geo` MIME type.
   * Entirely a daemon send, so it rejects rather than reporting a location that never left.
   */
  sendLocation(content: string, senderAccount: AccountModel, recipientUri: string,
    shouldRefreshConversations: boolean, shouldTryToSave: boolean): Promise<void> {
    const payload: Record<string, string> = {};
    payload[this.geoLocationMIMEType] = content;
    jami.sendAccountTextMessage(senderAccount.id, recipientUri, payload, 1);
    return Promise.resolve();
  }
}

/**
 * ObjC `NSDataTransferInfo` (Ring/CommonObjc/ObjcTypes.h:58) - only the fields
 * `generateDataTransferMessage` reads. An interface, not a class, so DataTransferService's own
 * transfer-info object satisfies it structurally.
 */
export interface DataTransferInfo {
  totalSize: number;
  peer: string;
  displayName: string;
  /** 1 = incoming, as the daemon sets it. */
  flags: number;
}

/**
 * Swift `ByteCountFormatter.string(fromByteCount:countStyle: .file)`. `.file` is base-1000 with
 * the SI unit names, which is what the source displays beside a transfer.
 */
function formatFileSize(bytes: number): string {
  if (bytes < 1000) {
    return `${bytes} bytes`;
  }
  const units: string[] = ['KB', 'MB', 'GB', 'TB', 'PB'];
  let value: number = bytes / 1000;
  let unitIndex: number = 0;
  while (value >= 1000 && unitIndex < units.length - 1) {
    value = value / 1000;
    unitIndex++;
  }
  const rounded: string = value >= 100 ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${units[unitIndex]}`;
}
