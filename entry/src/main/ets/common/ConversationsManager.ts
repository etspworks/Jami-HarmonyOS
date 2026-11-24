/*
 * Ported from Ring/Ring/Services/ConversationsManager.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * This class owns no data. It is the app's WIRING layer: it turns the daemon's conversation
 * signals and the other services' event streams into calls on ConversationsService,
 * RequestsService, ProfilesService, CallService and DataTransferService, and it owns the
 * account-active lifecycle (foreground/background + the post-call sync window).
 *
 * THREE THINGS DIFFER FROM SWIFT, ALL FORCED BY THE PLATFORM:
 *
 * 1. Construction. Swift's `init(with:…)` takes eleven services and does all the wiring in the
 *    initializer. `ServiceRegistry` builds with a zero-argument constructor and forbids reading
 *    the registry during construction (the import cycle is only safe while nothing runs at
 *    module-evaluation time), so the constructor is EMPTY and every service is read through a
 *    private getter inside the method that uses it. The Swift init body is `start()`, which the
 *    composition root calls once. `stop()` is the teardown Swift never needed.
 *
 * 2. App lifecycle. Swift observes UIApplication's background/foreground notifications from
 *    inside `controlAccountsState()`. A `.ts` module cannot reach the UIAbility, so the ability
 *    calls `appMovedToBackground()` / `appMovedForeground()` itself - the same two `@objc`
 *    methods Swift registered as selectors, now called directly. `applicationActive` mirrors
 *    `UIApplication.shared.applicationState != .active`, which several methods branch on.
 *
 * 3. The pending-call background task. iOS `beginBackgroundTask(withName:expirationHandler:)`
 *    maps to a BackgroundTasksKit TRANSIENT task (`requestSuspendDelay`), which is the same
 *    thing: a short grace period before suspension, with an expiration callback, and no
 *    permission on a self-signed build. `UIBackgroundTaskIdentifier.invalid` becomes -1.
 *
 * The jami daemon is a GAP on HarmonyOS (no source on disk - see common/DaemonService.ts), so
 * no swarm signal will ever arrive to drive `handle()`. That is reported by the services that
 * own the daemon surface, not faked here: this module's job is the wiring, and the wiring is
 * ported in full so it works the moment a signal source exists. The parts that need no daemon -
 * the stored updated-conversations list, the auto-accept size rule, the post-call sync timer -
 * work for real.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { DisposeBag } from './Observable';
import { describeError } from './ErrorText';
import { JamiConstants, NotificationUserInfoKey } from './JamiConstants';
import { JamiUri, UriType } from './JamiUri';
import { ServiceRegistry } from './ServiceRegistry';

import { AccountsService } from './AccountsService';
import { CallService } from './CallService';
import { CallsManager } from './CallsManager';
import { ContactsService } from './ContactsService';
import { ConversationsService, ConversationEvent, ConversationEventKind } from './ConversationsService';
import { DataTransferService, DataTransferInfo, DataTransferEventCode } from './DataTransferService';
import { LocationSharingService } from './LocationSharingService';
import { NameService } from './NameService';
import { PresenceService } from './PresenceService';
import { ProfilesService } from './ProfilesService';
import { RequestsService } from './RequestsService';
import { ServiceEvent, ServiceEventType, ServiceEventInput } from './ServiceEvent';

import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { ConfigKey } from '../model/ConfigKeyModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationType } from '../model/ConversationModel';
import { PendingPostCallSync } from '../model/CallState';
import { Profile } from '../model/Profile';
import {
  DataTransferStatus, MessageAttribute, MessageModel, MessageStatus, MessageType, SwarmMessageWrap
} from '../model/MessageModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ConversationsManager';

/** Swift `private let textPlainMIMEType`. */
const TEXT_PLAIN_MIME_TYPE: string = 'text/plain';
/** Swift `private let geoLocationMIMEType`. */
const GEO_LOCATION_MIME_TYPE: string = 'application/geo';
/** Swift `private let postCallSyncTimeout: TimeInterval = 3`, in ms (every ArkTS timer is ms). */
const POST_CALL_SYNC_TIMEOUT_MS: number = 3000;
/** Swift `beginBackgroundTask(withName: "pending-call-account")`. */
const PENDING_CALL_TASK_REASON: string = 'pending-call-account';
/** Swift `UIBackgroundTaskIdentifier.invalid`. */
const INVALID_TASK_ID: number = -1;
/** Swift `let automaticDownloadFilesKey` (Features/Settings/Me/GeneralSettings.swift:24). */
const AUTOMATIC_DOWNLOAD_FILES_KEY: string = 'AUTOMATIC_DOWNLOAD_FILES_KEY';
/** Swift `let acceptTransferLimitKey` (Features/Settings/Me/GeneralSettings.swift:25). */
const ACCEPT_TRANSFER_LIMIT_KEY: string = 'ACCEPT_TRANSFER_LIMIT_KEY';
const BYTES_PER_MB: number = 1024 * 1024;
/**
 * Swift used `UserDefaults(suiteName: Constants.appGroupIdentifier)` - a container shared with
 * the notification/share extensions. HarmonyOS runs no extension processes here (see
 * JamiConstants' note on the Darwin notification names), so one app-local preferences file
 * carries the same keys.
 */
const PREFERENCES_STORE_NAME: string = 'jami_shared';

/**
 * Swift `enum ConversationMemberEvent: Int` (Ring/Ring/Models/ConversationModel.swift:55).
 * model/ConversationModel.ts does not carry it and `conversationMemberEvent(…, event: Int)` is
 * its only reader in the whole app, so it lives with its reader rather than being a new module.
 */
export enum ConversationMemberEvent {
  ADD = 0,
  JOINS = 1,
  LEAVE = 2,
  BANNED = 3
}

/** Swift `ConversationMemberEvent(rawValue:)` - out-of-range means "drop the signal". */
function conversationMemberEventFromRaw(raw: number): ConversationMemberEvent | null {
  if (raw === 0) {
    return ConversationMemberEvent.ADD;
  }
  if (raw === 1) {
    return ConversationMemberEvent.JOINS;
  }
  if (raw === 2) {
    return ConversationMemberEvent.LEAVE;
  }
  if (raw === 3) {
    return ConversationMemberEvent.BANNED;
  }
  return null;
}

/*
 * The settings store. A `.ts` module cannot call `getContext()`, so the ability injects the
 * context once at startup - the same pattern as `model/MessageModel.ts`'s setModelResources.
 * Until it does, every read falls back to its Swift default (`UserDefaults` returns false/0 for
 * an unset key) and every write is dropped with a warning, rather than throwing into a caller
 * that has no way to recover.
 */
let settingsStore: preferences.Preferences | null = null;

/** Injector: call once from the ability's `onCreate`, before `ConversationsManager.start()`. */
export function setConversationsManagerContext(context: common.UIAbilityContext): void {
  try {
    const options: preferences.Options = { name: PREFERENCES_STORE_NAME };
    settingsStore = preferences.getPreferencesSync(context, options);
  } catch (error) {
    settingsStore = null;
    hilog.error(LOG_DOMAIN, LOG_TAG, 'settings store unavailable: %{public}s',
      describeError(error as BusinessError));
  }
}

/** Swift `UserDefaults.standard.bool(forKey:)` - an unset key is false. */
function storedBoolean(key: string, fallback: boolean): boolean {
  const store: preferences.Preferences | null = settingsStore;
  if (store === null) {
    return fallback;
  }
  try {
    return store.getSync(key, fallback) as boolean;
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'read %{public}s failed: %{public}s', key,
      describeError(error as BusinessError));
    return false;
  }
}

/** Swift `UserDefaults.standard.integer(forKey:)` - an unset key is 0. */
function storedInteger(key: string): number {
  const store: preferences.Preferences | null = settingsStore;
  if (store === null) {
    return 0;
  }
  try {
    return store.getSync(key, 0) as number;
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'read %{public}s failed: %{public}s', key,
      describeError(error as BusinessError));
    return 0;
  }
}

/**
 * The updated-conversations list Swift stored as `[[String: String]]` in the app-group
 * defaults. ArkTS preferences carry no array-of-dictionaries ValueType, so it is stored as
 * JSON - the same data, one encoding hop.
 */
function storedConversationData(): Array<Map<string, string>> | null {
  const store: preferences.Preferences | null = settingsStore;
  if (store === null) {
    return null;
  }
  let raw: string = '';
  try {
    raw = store.getSync(JamiConstants.UPDATED_CONVERSATIONS, '') as string;
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'read updatedConversations failed: %{public}s',
      describeError(error as BusinessError));
    return null;
  }
  if (raw.length === 0) {
    return null;
  }
  const decoded: Array<Map<string, string>> = [];
  try {
    const rows: Array<Record<string, string>> = JSON.parse(raw) as Array<Record<string, string>>;
    for (const row of rows) {
      const entry: Map<string, string> = new Map<string, string>();
      const keys: Array<string> = Object.keys(row);
      for (const key of keys) {
        entry.set(key, row[key]);
      }
      decoded.push(entry);
    }
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'updatedConversations is not readable JSON: %{public}s',
      describeError(error as BusinessError));
    return null;
  }
  return decoded;
}

/** Swift `userDefaults.set([[String: String]](), forKey: Constants.updatedConversations)`. */
function clearStoredConversationData(): void {
  const store: preferences.Preferences | null = settingsStore;
  if (store === null) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'no settings store; updatedConversations not cleared');
    return;
  }
  try {
    store.putSync(JamiConstants.UPDATED_CONVERSATIONS, '[]');
    // flushSync, not flush(): a fire-and-forget promise loses the write when the page/ability
    // is torn down before it settles. The outer catch reports a synchronous failure.
    store.flushSync();
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'clearing updatedConversations failed: %{public}s',
      describeError(error as BusinessError));
  }
}

/** Swift `ProfilePathHelper.jamiHash(from:)` (Ring/CommonHelpers.swift:91) - the same strip. */
function jamiHash(uri: string): string {
  const parsed: string | null = JamiUri.parse(uri).hash;
  return parsed === null ? '' : parsed;
}

/**
 * Swift `JamiURI(schema:infoHash:account:)` read the SIP hostname/port off `account.details`;
 * `JamiUri.fromInfoHash` takes them as values, so they are looked up here.
 */
function peerUriString(account: AccountModel, peerId: string): string | null {
  const isSip: boolean = account.type === AccountType.SIP;
  if (!isSip) {
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

export class ConversationsManager {
  /** Swift `let log = SwiftyBeaver.self` - hilog is the resolved substitution (inventory). */
  private readonly log: string = LOG_TAG;

  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /**
   * Swift `private let appState = PublishRelay<ServiceEventType>()`. Swift needed a relay to
   * hop the UIApplication notification onto its own subscription; here the ability already
   * calls appMovedToBackground/appMovedForeground on this instance, so the relay would be a
   * one-subscriber indirection with no second producer. The two methods call the handler the
   * relay's subscription called, and `applicationActive` is the state the relay carried.
   */
  private applicationActive: boolean = true;

  /** Swift `private var pendingCallBackgroundTask: UIBackgroundTaskIdentifier = .invalid`. */
  private pendingCallBackgroundTask: number = INVALID_TASK_ID;

  /** Swift `private let postCallSyncTimeout: TimeInterval = 3`. */
  private readonly postCallSyncTimeout: number = POST_CALL_SYNC_TIMEOUT_MS;

  /** Swift `private var pendingPostCallSync: PendingPostCallSync?`. */
  private pendingPostCallSync: PendingPostCallSync | null = null;

  /** Swift `private var postCallSyncTimeoutWork: DispatchWorkItem?` - a setTimeout handle. */
  private postCallSyncTimeoutWork: number = INVALID_TASK_ID;

  /** Swift `private let textPlainMIMEType`. */
  private readonly textPlainMIMEType: string = TEXT_PLAIN_MIME_TYPE;

  /** Swift `private let geoLocationMIMEType`. */
  private readonly geoLocationMIMEType: string = GEO_LOCATION_MIME_TYPE;

  /**
   * Swift AppDelegate's `presentingCallScreen`, set through `updateCallScreenState(presenting:)`.
   * It existed so the notification extension could tell whether the app still owned the call
   * screen; HarmonyOS has no extension process, so the flag stays local and `releaseAccount()`
   * clears it exactly where Swift did.
   */
  private presentingCallScreen: boolean = false;

  /*
   * Swift held eleven `private let` service references, injected by AppDelegate. ServiceRegistry
   * builds with no arguments and forbids reading it during construction, so each one is a getter
   * that resolves on use. Same names, same types, no construction-time cycle.
   */

  private get conversationService(): ConversationsService {
    return ServiceRegistry.shared().conversationsService;
  }

  private get contactsService(): ContactsService {
    return ServiceRegistry.shared().contactsService;
  }

  private get accountsService(): AccountsService {
    return ServiceRegistry.shared().accountService;
  }

  private get nameService(): NameService {
    return ServiceRegistry.shared().nameService;
  }

  private get dataTransferService(): DataTransferService {
    return ServiceRegistry.shared().dataTransferService;
  }

  private get callService(): CallService {
    return ServiceRegistry.shared().callService;
  }

  /** Swift `private let callsManager: CallsManager`; the registry field is assigned by the root. */
  private get callsManager(): CallsManager | null {
    return ServiceRegistry.shared().callsManager;
  }

  private get locationSharingService(): LocationSharingService {
    return ServiceRegistry.shared().locationSharingService;
  }

  private get requestService(): RequestsService {
    return ServiceRegistry.shared().requestsService;
  }

  private get profileService(): ProfilesService {
    return ServiceRegistry.shared().profileService;
  }

  private get presenceService(): PresenceService {
    return ServiceRegistry.shared().presenceService;
  }

  /** Swift `private var maxSizeForAutoaccept: Int` - the stored MB limit, in bytes. */
  private get maxSizeForAutoaccept(): number {
    return storedInteger(ACCEPT_TRANSFER_LIMIT_KEY) * BYTES_PER_MB;
  }

  /**
   * Swift `init(with:…)`. ArkTS constructors run under the registry's no-work rule, so the whole
   * initializer body lives here and the composition root calls it once, after the services are
   * reachable. Swift also assigned `ProfilesAdapter.delegate = self` and
   * `RequestsAdapter.delegate = self`: both adapters are ObjC bridges into the daemon, which has
   * no source on disk, so the two delegate callbacks (`profileReceived`,
   * `incomingTrustRequestReceived` / `conversationRequestReceived`) stay public methods for a
   * future signal source to call and are not wired to a fabricated one.
   */
  start(): void {
    this.startConversationEventPipeline();
    /*
     * When the application starts, all conversations will be loaded. Conversation data should be
     * cleaned to prevent reloading conversations that were updated from notifications.
     */
    this.cleanConversationData();
    this.subscribeFileTransferEvents();
    this.subscribeCallsEvents();
    this.subscribeContactsEvents();
    this.subscribeLocationSharingEvent();
    this.subscribeRequestEvents();
    this.subscribeProfileEvents();
    this.controlAccountsState();
  }

  /**
   * No Swift counterpart - the iOS object lived for the whole process. Releases every
   * subscription and both timers so a torn-down ability leaves nothing running.
   */
  stop(): void {
    try {
      this.cancelPostCallSync();
      this.endPendingCallBackgroundTask();
    } finally {
      this.disposeBag.dispose();
    }
  }

  // MARK: libjami conversation signals

  private startConversationEventPipeline(): void {
    this.conversationService.onEvent = (event: ConversationEvent) => {
      this.handle(event);
    };
    this.conversationService.startEvents();
  }

  /**
   * Swift `private func handle(_ event: ConversationEvent)` - a switch over the enum's cases.
   * ArkTS forbids `switch` nowhere but `build()`, yet an `if` ladder reads the same here and
   * keeps the payload reads beside their branch.
   */
  private handle(event: ConversationEvent): void {
    const kind: ConversationEventKind = event.kind;
    if (kind === ConversationEventKind.INCOMING_ACCOUNT_MESSAGE) {
      this.didReceiveMessage(event.payloads, event.from, event.messageId, event.accountId);
    } else if (kind === ConversationEventKind.MESSAGE_STATUS_CHANGED) {
      this.messageStatusChanged(event.messageStatus, event.messageId, event.accountId, event.peer,
        event.conversationId);
    } else if (kind === ConversationEventKind.ACTIVE_CALLS_CHANGED) {
      this.activeCallsChanged(event.conversationId, event.accountId, event.calls);
    } else if (kind === ConversationEventKind.COMPOSING_STATUS_CHANGED) {
      this.composingStatusChanged(event.accountId, event.conversationId, event.from,
        event.status);
    } else if (kind === ConversationEventKind.SWARM_LOADED) {
      this.conversationLoaded(event.conversationId, event.accountId, event.messages,
        event.requestId);
    } else if (kind === ConversationEventKind.SWARM_MESSAGE_RECEIVED) {
      const message: SwarmMessageWrap | null = event.message;
      if (message !== null) {
        this.newInteraction(event.conversationId, event.accountId, message);
      }
    } else if (kind === ConversationEventKind.SWARM_MESSAGE_UPDATED) {
      const message: SwarmMessageWrap | null = event.message;
      if (message !== null) {
        this.messageUpdated(event.conversationId, event.accountId, message);
      }
    } else if (kind === ConversationEventKind.REACTION_ADDED) {
      this.reactionAdded(event.conversationId, event.accountId, event.messageId, event.reaction);
    } else if (kind === ConversationEventKind.REACTION_REMOVED) {
      this.reactionRemoved(event.conversationId, event.accountId, event.messageId,
        event.reactionId);
    } else if (kind === ConversationEventKind.CONVERSATION_READY) {
      this.conversationReady(event.conversationId, event.accountId);
    } else if (kind === ConversationEventKind.CONVERSATION_REMOVED) {
      this.conversationRemoved(event.conversationId, event.accountId);
    } else if (kind === ConversationEventKind.CONVERSATION_DECLINED) {
      this.conversationDeclined(event.conversationId, event.accountId);
    } else if (kind === ConversationEventKind.CONVERSATION_MEMBER_EVENT) {
      this.conversationMemberEvent(event.conversationId, event.accountId, event.memberUri,
        event.status);
    } else if (kind === ConversationEventKind.CONVERSATION_PROFILE_UPDATED) {
      this.conversationProfileUpdated(event.conversationId, event.accountId, event.profile);
    } else if (kind === ConversationEventKind.CONVERSATION_PREFERENCES_UPDATED) {
      this.conversationPreferencesUpdated(event.conversationId, event.accountId,
        event.preferences);
    }
  }

  /**
   * When the application is inactive, the accounts should also be inactive - except while
   * handling an incoming call.
   *
   * Swift registered two NotificationCenter observers here; on HarmonyOS the ability calls
   * `appMovedToBackground()` / `appMovedForeground()` directly, so only the call-event half of
   * the Swift body is a subscription.
   */
  private controlAccountsState(): void {
    const unsubscribe: () => void = this.callService.sharedResponseStream
      .subscribe((serviceEvent: ServiceEvent) => {
        if (serviceEvent.eventType === ServiceEventType.CALL_PROVIDER_PREVIEW_PENDING_CALL) {
          this.handlePendingCallPreview(serviceEvent);
        } else if (serviceEvent.eventType === ServiceEventType.CALL_ENDED) {
          this.handleCallEndedForAccountState(serviceEvent);
        }
      });
    this.disposeBag.add(unsubscribe);
  }

  /**
   * The `.callProviderPreviewPendingCall` arm of Swift's merged call-event subscription. Split
   * out only because ArkTS has no `switch` in an arrow body worth the nesting.
   */
  private handlePendingCallPreview(serviceEvent: ServiceEvent): void {
    // Prevent the previous timeout from deactivating the new call.
    this.cancelPostCallSync();
    this.accountsService.setAccountsActive(true);
    this.beginPendingCallBackgroundTask();
    const payload: Map<string, string> | null = serviceEvent.getMap(ServiceEventInput.CONTENT);
    if (payload !== null && payload.size > 0) {
      this.accountsService.pushNotificationReceived(payload);
    }
    // Reload conversations updated in the background if required.
    const updatedConversations: Array<Map<string, string>> | null = this.getConversationData();
    if (updatedConversations === null) {
      return;
    }
    this.cleanConversationData();
    this.reloadConversationsAndRequests(this.extractAccountIds(updatedConversations));
  }

  /** The `.callEnded` arm of the same Swift subscription. */
  private handleCallEndedForAccountState(serviceEvent: ServiceEvent): void {
    if (this.applicationActive) {
      this.endPendingCallBackgroundTask();
      return;
    }
    const peerUri: string | null = serviceEvent.getString(ServiceEventInput.PEER_URI);
    const accountId: string | null = serviceEvent.getString(ServiceEventInput.ACCOUNT_ID);
    this.awaitPostCallSync(accountId === null ? '' : accountId,
      jamiHash(peerUri === null ? '' : peerUri));
  }

  /*
   * When the app is in the background the account should not be active, and the notification
   * extension should handle incoming notifications - unless there is a pending call.
   */
  updateBackgroundState(): void {
    const manager: CallsManager | null = this.callsManager;
    if (manager !== null && manager.hasActiveCalls()) {
      return;
    }
    if (this.pendingPostCallSync !== null) {
      return;
    }
    this.releaseAccount();
  }

  /**
   * The call-screen state has to be reset with the account, otherwise the extension keeps
   * deferring to an app that no longer owns the account. (HarmonyOS has no extension; the flag
   * is kept because the ordering against `setAccountsActive` is the behaviour, not the reader.)
   */
  private releaseAccount(): void {
    this.presentingCallScreen = false;
    this.accountsService.setAccountsActive(false);
  }

  /**
   * A push activates the account while the app is in the background. If the OS suspends the app
   * before the pending call is resolved, the account would be carried over as active into the
   * suspended state: the next foreground `setAccountsActive(true)` would then be a no-op in the
   * daemon (no re-registration, stale connectivity). Keep the app alive briefly so the account
   * can be released before suspension.
   *
   * `requestSuspendDelay` is the HarmonyOS transient task - the direct counterpart of
   * `beginBackgroundTask(withName:expirationHandler:)`, and permission-free.
   */
  private beginPendingCallBackgroundTask(): void {
    if (this.pendingCallBackgroundTask !== INVALID_TASK_ID) {
      this.endPendingCallBackgroundTask();
    }
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(PENDING_CALL_TASK_REASON, () => {
          this.handlePendingCallTaskExpiration();
        });
      this.pendingCallBackgroundTask = info.requestId;
    } catch (error) {
      this.pendingCallBackgroundTask = INVALID_TASK_ID;
      hilog.warn(LOG_DOMAIN, this.log, 'pending-call task refused: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /**
   * A call-provider placeholder must not block the handoff, but an ongoing call confirmed by the
   * daemon still needs the account.
   */
  private handlePendingCallTaskExpiration(): void {
    this.onMain(() => {
      this.cancelPostCallSync();
      if (!this.callService.hasOngoingCalls) {
        this.releaseAccount();
      }
      this.endPendingCallBackgroundTask();
    });
  }

  private endPendingCallBackgroundTask(): void {
    const requestId: number = this.pendingCallBackgroundTask;
    if (requestId === INVALID_TASK_ID) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(requestId);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, this.log, 'cancelling pending-call task failed: %{public}s',
        describeError(error as BusinessError));
    } finally {
      this.pendingCallBackgroundTask = INVALID_TASK_ID;
    }
  }

  /**
   * The peer sends the final call-history commit over the call connection, so keep the account
   * alive until the commit arrives (`confirmPostCallSyncIfNeeded`) or the wait expires.
   */
  private awaitPostCallSync(accountId: string, peerHash: string): void {
    this.onMain(() => {
      this.beginPendingCallBackgroundTask();
      this.clearPostCallSyncTimer();
      this.pendingPostCallSync = new PendingPostCallSync(accountId, peerHash);
      this.postCallSyncTimeoutWork = setTimeout(() => {
        this.finishPostCallSync();
      }, this.postCallSyncTimeout);
    });
  }

  private finishPostCallSync(): void {
    this.onMain(() => {
      this.clearPostCallSyncTimer();
      this.pendingPostCallSync = null;
      if (!this.applicationActive) {
        this.updateBackgroundState();
      }
      this.endPendingCallBackgroundTask();
    });
  }

  private cancelPostCallSync(): void {
    this.onMain(() => {
      this.clearPostCallSyncTimer();
      this.pendingPostCallSync = null;
    });
  }

  /** Swift `postCallSyncTimeoutWork?.cancel(); postCallSyncTimeoutWork = nil`. */
  private clearPostCallSyncTimer(): void {
    if (this.postCallSyncTimeoutWork === INVALID_TASK_ID) {
      return;
    }
    clearTimeout(this.postCallSyncTimeoutWork);
    this.postCallSyncTimeoutWork = INVALID_TASK_ID;
  }

  private confirmPostCallSyncIfNeeded(accountId: string, message: MessageModel): void {
    this.onMain(() => {
      const pending: PendingPostCallSync | null = this.pendingPostCallSync;
      if (pending === null || !pending.isConfirmed(message, accountId)) {
        return;
      }
      this.finishPostCallSync();
    });
  }

  /**
   * Swift hopped to the main queue to preserve ordering between a cancellation and an
   * already-due timeout. An ArkTS module instance is confined to one VM thread and `setTimeout`
   * callbacks run on that same thread, so the ordering Swift bought with the hop already holds
   * and the block runs directly. The method is kept so every call site reads as it did.
   */
  private onMain(block: () => void): void {
    block();
  }

  /** Swift `func cleanConversationData()`. */
  cleanConversationData(): void {
    clearStoredConversationData();
  }

  /** Swift `func getConversationData() -> [[String: String]]?`. */
  getConversationData(): Array<Map<string, string>> | null {
    return storedConversationData();
  }

  /** Swift `func updateForegroundState()`. */
  updateForegroundState(): void {
    this.endPendingCallBackgroundTask();
    const updatedConversations: Array<Map<string, string>> | null = this.getConversationData();
    if (updatedConversations === null) {
      this.accountsService.setAccountsActive(true);
      return;
    }
    this.cleanConversationData();
    // ask daemon to reload conversations and requests from file
    const accountIds: Set<string> = this.extractAccountIds(updatedConversations);
    this.reloadConversationsAndRequests(accountIds);
    this.accountsService.setAccountsActive(true);
    // get requests from the daemon
    this.updateRequests(accountIds);
    // get interactions from the daemon
    this.reloadConversationMessages(updatedConversations);
  }

  /** Swift `func extractAccountIds(from:) -> Set<String>`. */
  extractAccountIds(conversations: Array<Map<string, string>>): Set<string> {
    const accountIds: Set<string> = new Set<string>();
    for (const conversationData of conversations) {
      const accountId: string | undefined =
        conversationData.get(NotificationUserInfoKey.ACCOUNT_ID);
      if (accountId !== undefined) {
        accountIds.add(accountId);
      }
    }
    return accountIds;
  }

  /** Swift `func reloadConversationsAndRequests(accountIds:)`. */
  reloadConversationsAndRequests(accountIds: Set<string>): void {
    for (const accountId of accountIds) {
      this.conversationService.reloadConversationsAndRequests(accountId);
    }
  }

  /** Swift `func updateRequests(accountIds:)`. */
  updateRequests(accountIds: Set<string>): void {
    for (const accountId of accountIds) {
      this.requestService.updateConversationsRequests(accountId);
    }
  }

  /** Swift `func reloadConversationMessages(updatedConversations:)`. */
  reloadConversationMessages(updatedConversations: Array<Map<string, string>>): void {
    const currentAccount: AccountModel | null = this.accountsService.currentAccount;
    if (currentAccount === null) {
      return;
    }
    for (const conversationData of updatedConversations) {
      const accountId: string | undefined =
        conversationData.get(NotificationUserInfoKey.ACCOUNT_ID);
      const conversationId: string | undefined =
        conversationData.get(NotificationUserInfoKey.CONVERSATION_ID);
      if (accountId !== undefined && conversationId !== undefined
        && accountId === currentAccount.id) {
        this.conversationService.updateConversationMessages(conversationId);
      }
    }
  }

  /**
   * Swift `@objc func appMovedToBackground()`, registered for
   * `UIApplication.didEnterBackgroundNotification`. The ability's `onBackground()` calls it.
   */
  appMovedToBackground(): void {
    this.applicationActive = false;
    this.updateBackgroundState();
  }

  /**
   * Swift `@objc func appMovedForeground()`, registered for
   * `UIApplication.willEnterForegroundNotification`. The ability's `onForeground()` calls it.
   */
  appMovedForeground(): void {
    this.applicationActive = true;
    // Cancel before the hop so the timeout cannot deactivate the foreground account.
    this.cancelPostCallSync();
    this.updateForegroundState();
  }

  private subscribeRequestEvents(): void {
    const unsubscribe: () => void = this.requestService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.REQUEST_ACCEPTED) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const conversationId: string | null = event.getString(ServiceEventInput.CONVERSATION_ID);
        if (accountId === null || conversationId === null) {
          return;
        }
        const account: AccountModel | null = this.accountsService.getAccount(accountId);
        if (account === null) {
          return;
        }
        const rawType: number | null = event.getNumber(ServiceEventInput.CONVERSATION_TYPE);
        const type: ConversationType =
          rawType === null ? ConversationType.INVITES_ONLY : rawType as ConversationType;
        this.conversationService.addConversationFromAcceptedRequest(conversationId, accountId,
          account.jamiId, type);
      });
    this.disposeBag.add(unsubscribe);
  }

  private subscribeProfileEvents(): void {
    const onRequestEvent: () => void = this.requestService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        if (accountId === null || peerUri === null) {
          return;
        }
        if (event.eventType === ServiceEventType.CONTACT_REQUEST_SENT) {
          const profile: Profile | null = event.getProfile(ServiceEventInput.PROFILE);
          if (profile !== null) {
            this.profileService.invitationSent(profile, accountId);
          }
        } else if (event.eventType === ServiceEventType.CONTACT_REQUEST_ACCEPTED) {
          const profile: Profile | null = event.getProfile(ServiceEventInput.PROFILE);
          if (profile !== null) {
            this.profileService.invitationAccepted(profile, accountId);
          }
        } else if (event.eventType === ServiceEventType.CONTACT_REQUEST_REMOVED) {
          this.profileService.peerDiscarded(peerUri, accountId);
        }
      });
    this.disposeBag.add(onRequestEvent);

    const onContactsCleared: () => void = this.contactsService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.ALL_CONTACTS_REMOVED) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        if (accountId === null) {
          return;
        }
        this.profileService.accountContactsCleared(accountId);
      });
    this.disposeBag.add(onContactsCleared);

    const onConversationRemoved: () => void = this.conversationService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.CONVERSATION_REMOVED) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        if (accountId === null || peerUri === null) {
          return;
        }
        this.profileService.conversationDeleted(peerUri, accountId);
      });
    this.disposeBag.add(onConversationRemoved);

    const onSipCallEnded: () => void = this.callService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.CALL_ENDED) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        const displayName: string | null = event.getString(ServiceEventInput.NAME);
        if (accountId === null || peerUri === null || displayName === null
          || displayName.length === 0) {
          return;
        }
        const account: AccountModel | null = this.accountsService.getAccount(accountId);
        if (account === null || account.type !== AccountType.SIP) {
          return;
        }
        const uri: string | null =
          ProfilesService.profileUriString(JamiUri.fromInfoHash(UriType.SIP, peerUri));
        if (uri === null) {
          return;
        }
        this.profileService.sipPeerNameReceived(displayName, uri, accountId);
      });
    this.disposeBag.add(onSipCallEnded);
  }

  private subscribeContactsEvents(): void {
    const unsubscribe: () => void = this.contactsService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.CONTACT_ADDED) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const jamiId: string | null = event.getString(ServiceEventInput.PEER_URI);
        if (accountId === null || jamiId === null) {
          return;
        }
        const account: AccountModel | null = this.accountsService.getAccount(accountId);
        const currentAccount: AccountModel | null = this.accountsService.currentAccount;
        if (account === null || currentAccount === null || !account.equals(currentAccount)) {
          return;
        }
        const contact: ContactModel | null = this.contactsService.contact(jamiId);
        if (contact === null) {
          return;
        }
        if (!contact.banned) {
          this.presenceService.subscribeBuddy(accountId, jamiId, true);
        }
        if (!account.isJams || contact.conversationId.length === 0) {
          return;
        }
        this.conversationService.addSwarmConversationId(contact.conversationId, accountId, jamiId);
      });
    this.disposeBag.add(unsubscribe);
  }

  private subscribeLocationSharingEvent(): void {
    const unsubscribe: () => void = this.locationSharingService.locationServiceEventShared
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.SEND_LOCATION) {
          return;
        }
        const currentAccount: AccountModel | null = this.accountsService.currentAccount;
        const content: string | null = event.getString(ServiceEventInput.CONTENT);
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        if (currentAccount === null || content === null || accountId === null
          || peerUri === null) {
          return;
        }
        const account: AccountModel | null = this.accountsService.getAccount(accountId);
        if (account === null) {
          return;
        }
        /*
         * Swift packed `(content, shouldTryToSave)` into the single `.content` input as a tuple.
         * ArkTS event inputs are typed per bucket, so the flag travels as its own input; a
         * producer that does not set it means "try to save", which is the Swift default path.
         */
        const storedFlag: boolean | null =
          event.getBoolean(ServiceEventInput.SHOULD_TRY_TO_SAVE);
        const shouldTryToSave: boolean = storedFlag === null ? true : storedFlag;
        const shouldRefresh: boolean = currentAccount.id === accountId;

        this.conversationService
          .sendLocation(content, account, peerUri, shouldRefresh, shouldTryToSave)
          .then(() => {
            hilog.debug(LOG_DOMAIN, this.log, '[LocationSharingService] Location sent');
          })
          .catch((error: BusinessError) => {
            hilog.error(LOG_DOMAIN, this.log, 'sending location failed: %{public}s',
              describeError(error));
          });
      });
    this.disposeBag.add(unsubscribe);
  }

  private subscribeCallsEvents(): void {
    /*
     * Call teardown on call end is owned by the call layer; only in-call messages are handled
     * here.
     */
    const onIncoming: () => void = this.callService.newMessage
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.NEW_INCOMING_MESSAGE) {
          return;
        }
        if (this.accountsService.boothMode()) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        const messageContent: string | null = event.getString(ServiceEventInput.CONTENT);
        if (accountId === null || peerUri === null || messageContent === null) {
          return;
        }
        this.handleNewMessage(peerUri, accountId, '', messageContent,
          event.getString(ServiceEventInput.NAME));
      });
    this.disposeBag.add(onIncoming);

    const onOutgoing: () => void = this.callService.newMessage
      .subscribe((event: ServiceEvent) => {
        if (event.eventType !== ServiceEventType.NEW_OUTGOING_MESSAGE) {
          return;
        }
        if (this.accountsService.boothMode()) {
          return;
        }
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const messageContent: string | null = event.getString(ServiceEventInput.CONTENT);
        const peerUri: string | null = event.getString(ServiceEventInput.PEER_URI);
        const accountUri: string | null = event.getString(ServiceEventInput.ACCOUNT_URI);
        if (accountId === null || messageContent === null || peerUri === null
          || accountUri === null) {
          return;
        }
        const message: MessageModel = this.conversationService.createMessage('', messageContent,
          accountUri, MessageType.TEXT, false);
        this.conversationService.saveMessage(message, peerUri, accountId, true)
          .catch((error: BusinessError) => {
            hilog.error(LOG_DOMAIN, this.log, 'saving outgoing in-call message failed: %{public}s',
              describeError(error));
          });
      });
    this.disposeBag.add(onOutgoing);
  }

  private subscribeFileTransferEvents(): void {
    const unsubscribe: () => void = this.dataTransferService.sharedResponseStream
      .subscribe((event: ServiceEvent) => {
        const isCreated: boolean = event.eventType === ServiceEventType.DATA_TRANSFER_CREATED;
        const isChanged: boolean = event.eventType === ServiceEventType.DATA_TRANSFER_CHANGED;
        if (!isCreated && !isChanged) {
          return;
        }
        if (this.accountsService.boothMode()) {
          return;
        }
        const transferId: string | null = event.getString(ServiceEventInput.TRANSFER_ID);
        const accountId: string | null = event.getString(ServiceEventInput.ACCOUNT_ID);
        const conversationId: string | null = event.getString(ServiceEventInput.CONVERSATION_ID);
        const messageId: string | null = event.getString(ServiceEventInput.MESSAGE_ID);
        if (transferId === null || accountId === null || conversationId === null
          || messageId === null) {
          hilog.error(LOG_DOMAIN, this.log, 'unable to find transferInfo');
          return;
        }
        const transferInfo: DataTransferInfo | null = this.dataTransferService
          .dataTransferInfo(transferId, accountId, conversationId, conversationId.length > 0);
        const currentAccount: AccountModel | null = this.accountsService.currentAccount;
        if (transferInfo === null || currentAccount === null) {
          hilog.error(LOG_DOMAIN, this.log, 'unable to find transferInfo');
          return;
        }
        if (isCreated) {
          this.onDataTransferCreated(event, transferId, transferInfo, conversationId, messageId,
            currentAccount);
        } else {
          this.onDataTransferChanged(event, transferId, transferInfo, accountId, conversationId,
            messageId);
        }
      });
    this.disposeBag.add(unsubscribe);
  }

  /** The `.dataTransferCreated` arm of Swift's file-transfer subscription. */
  private onDataTransferCreated(event: ServiceEvent, transferId: string,
    transferInfo: DataTransferInfo, conversationId: string, messageId: string,
    currentAccount: AccountModel): void {
    const photoIdentifier: string | null = event.getString(ServiceEventInput.LOCAL_PHOTO_ID);
    this.conversationService
      .generateDataTransferMessage(transferId, transferInfo, transferInfo.accountId,
        photoIdentifier, currentAccount.id === transferInfo.accountId, conversationId, messageId)
      .catch((error: BusinessError) => {
        hilog.error(LOG_DOMAIN, this.log, 'generating transfer message failed: %{public}s',
          describeError(error));
      });
  }

  /** The `.dataTransferChanged` arm, including Swift's event-code to DataTransferStatus map. */
  private onDataTransferChanged(event: ServiceEvent, transferId: string,
    transferInfo: DataTransferInfo, accountId: string, conversationId: string,
    messageId: string): void {
    const rawEventCode: number | null = event.getNumber(ServiceEventInput.STATE);
    if (rawEventCode === null) {
      return;
    }
    let transferEvent: DataTransferEventCode = rawEventCode as DataTransferEventCode;
    if (conversationId.length === 0) {
      transferEvent = transferInfo.lastEvent;
    }
    const eventCodeForLog: number = transferEvent.valueOf();
    hilog.debug(LOG_DOMAIN, this.log, 'dataTransferChanged - id:%{public}s status:%{public}d',
      transferId, eventCodeForLog);

    let status: DataTransferStatus = DataTransferStatus.UNKNOWN;
    if (transferEvent === DataTransferEventCode.CLOSED_BY_HOST
      || transferEvent === DataTransferEventCode.CLOSED_BY_PEER) {
      status = DataTransferStatus.CANCELED;
    } else if (transferEvent === DataTransferEventCode.INVALID
      || transferEvent === DataTransferEventCode.UNSUPPORTED
      || transferEvent === DataTransferEventCode.INVALID_PATHNAME
      || transferEvent === DataTransferEventCode.UNJOINABLE_PEER) {
      status = DataTransferStatus.ERROR;
    } else if (transferEvent === DataTransferEventCode.WAIT_PEER_ACCEPTANCE
      || transferEvent === DataTransferEventCode.WAIT_HOST_ACCEPTANCE) {
      status = DataTransferStatus.AWAITING;
    } else if (transferEvent === DataTransferEventCode.ONGOING) {
      status = DataTransferStatus.ONGOING;
    } else if (transferEvent === DataTransferEventCode.FINISHED) {
      status = DataTransferStatus.SUCCESS;
    }
    // `.created` and anything unknown keep DataTransferStatus.UNKNOWN, as in Swift.

    const peer: string = conversationId.length > 0 ? '' : transferInfo.peer;
    this.conversationService.transferStatusChanged(status, transferId, conversationId, messageId,
      accountId, peer);
  }

  /** Swift `func prepareConversationsForAccount(accountId:accountURI:)`. */
  prepareConversationsForAccount(accountId: string, accountURI: string): void {
    this.conversationService.getConversationsForAccount(accountId, accountURI);
  }

  // MARK: Message adapter delegate

  private handleReceivedLocationUpdate(peerId: string, accountId: string, messageId: string,
    locationJSON: string): void {
    const accountForMessage: AccountModel | null = this.accountsService.getAccount(accountId);
    if (accountForMessage === null) {
      return;
    }
    const peerUri: string | null = peerUriString(accountForMessage, peerId);
    if (peerUri === null) {
      return;
    }
    // Tell the location sharing service
    this.locationSharingService.handleReceivedLocationUpdate(peerUri, accountId, messageId,
      locationJSON);
  }

  /** Swift `func handleNewMessage(from:to:messageId:message:peerName:)`. */
  handleNewMessage(peerUri: string, accountId: string, messageId: string, content: string,
    peerName: string | null): void {
    const currentAccount: AccountModel | null = this.accountsService.currentAccount;
    const accountForMessage: AccountModel | null = this.accountsService.getAccount(accountId);
    if (currentAccount === null || accountForMessage === null) {
      return;
    }
    const shouldUpdateConversationsList: boolean = currentAccount.id === accountForMessage.id;
    const uriString: string | null = peerUriString(accountForMessage, peerUri);
    if (uriString === null) {
      return;
    }
    const message: MessageModel = this.conversationService.createMessage(messageId, content,
      uriString, MessageType.TEXT, true);
    this.conversationService
      .saveMessage(message, uriString, accountId, shouldUpdateConversationsList)
      .catch((error: BusinessError) => {
        hilog.error(LOG_DOMAIN, this.log, 'saving incoming message failed: %{public}s',
          describeError(error));
      });
  }

  /** Swift `func messageStatusChanged(_:for:from:to:in:)`. */
  messageStatusChanged(status: MessageStatus, messageId: string, accountId: string,
    jamiId: string, conversationId: string): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    if (account.jamiId === jamiId) {
      return;
    }
    this.conversationService.messageStatusChanged(status, messageId, accountId, jamiId,
      conversationId);
  }

  /** Swift `func conversationProfileUpdated(conversationId:accountId:profile:)`. */
  conversationProfileUpdated(conversationId: string, accountId: string,
    profile: Map<string, string>): void {
    this.conversationService.conversationProfileUpdated(conversationId, accountId, profile);
  }

  /** Swift `func conversationPreferencesUpdated(conversationId:accountId:preferences:)`. */
  conversationPreferencesUpdated(conversationId: string, accountId: string,
    conversationPreferences: Map<string, string>): void {
    this.conversationService.conversationPreferencesUpdated(conversationId, accountId,
      conversationPreferences);
  }

  // MARK: extension ConversationsManager (the conversation signal handlers)

  /** Swift `func conversationMemberEvent(conversationId:accountId:memberUri:event:)`. */
  conversationMemberEvent(conversationId: string, accountId: string, memberUri: string,
    event: number): void {
    const conversationEvent: ConversationMemberEvent | null =
      conversationMemberEventFromRaw(event);
    if (conversationEvent === null) {
      return;
    }
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    // Check if we left the conversation on another device. In that case remove the conversation.
    if (conversationEvent === ConversationMemberEvent.LEAVE && account.jamiId === memberUri) {
      this.conversationService.conversationRemoved(conversationId, accountId);
      return;
    }
    this.conversationService.conversationMemberEvent(conversationId, accountId, account.jamiId);
  }

  /** Swift `func didReceiveMessage(_:from:messageId:to:)`. */
  didReceiveMessage(message: Map<string, string>, senderAccount: string, messageId: string,
    receiverAccountId: string): void {
    if (this.accountsService.boothMode()) {
      return;
    }
    const textContent: string | undefined = message.get(this.textPlainMIMEType);
    if (textContent !== undefined) {
      this.handleNewMessage(senderAccount, receiverAccountId, messageId, textContent, null);
      return;
    }
    const locationContent: string | undefined = message.get(this.geoLocationMIMEType);
    if (locationContent !== undefined) {
      this.handleReceivedLocationUpdate(senderAccount, receiverAccountId, messageId,
        locationContent);
    }
  }

  /** Swift `func conversationReady(conversationId:accountId:)`. */
  conversationReady(conversationId: string, accountId: string): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    const currentAccount: AccountModel | null = this.accountsService.currentAccount;
    if (account === null || currentAccount === null) {
      return;
    }
    if (account.equals(currentAccount)) {
      this.conversationService.conversationReady(conversationId, accountId, account.jamiId);
    }
  }

  /** Swift `func updateTransferInfoIfNeed(newMessage:conversationId:accountId:)`. */
  updateTransferInfoIfNeed(newMessage: MessageModel, conversationId: string,
    accountId: string): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    if (newMessage.type !== MessageType.FILE_TRANSFER) {
      return;
    }
    const progress: number = this.dataTransferService
      .getTransferProgress(newMessage.daemonId, accountId, conversationId, true);
    if (progress === 0) {
      newMessage.transferStatus = DataTransferStatus.AWAITING;
    } else if (progress === newMessage.totalSize) {
      newMessage.transferStatus = DataTransferStatus.SUCCESS;
    } else {
      newMessage.transferStatus = DataTransferStatus.ONGOING;
    }
    const shouldDownload: boolean = newMessage.transferStatus === DataTransferStatus.AWAITING
      && (this.isDownloadingEnabled(newMessage.totalSize)
        || newMessage.authorId === account.jamiId);
    if (shouldDownload) {
      this.dataTransferService.downloadFile(newMessage.daemonId, newMessage.id, accountId,
        conversationId);
    }
  }

  /** Swift `func conversationLoaded(conversationId:accountId:messages:requestId:)`. */
  conversationLoaded(conversationId: string, accountId: string,
    messages: Array<SwarmMessageWrap>, requestId: number): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    // Convert array of dictionaries to messages.
    const messagesModels: Array<MessageModel> = [];
    for (const wrapInfo of messages) {
      const newMessage: MessageModel = MessageModel.fromSwarmMessage(wrapInfo, account.jamiId);
      this.updateTransferInfoIfNeed(newMessage, conversationId, accountId);
      messagesModels.push(newMessage);
    }
    this.conversationService.insertMessages(messagesModels, accountId, account.jamiId,
      conversationId, true);
  }

  /** Swift `func reactionAdded(conversationId:accountId:messageId:reaction:)`. */
  reactionAdded(conversationId: string, accountId: string, messageId: string,
    reaction: Map<string, string>): void {
    this.conversationService.reactionAdded(conversationId, accountId, messageId, reaction);
  }

  /** Swift `func composingStatusChanged(accountId:conversationId:from:status:)`. */
  composingStatusChanged(accountId: string, conversationId: string, from: string,
    status: number): void {
    this.conversationService.composingStatusChanged(accountId, conversationId, from, status);
  }

  /** Swift `func reactionRemoved(conversationId:accountId:messageId:reactionId:)`. */
  reactionRemoved(conversationId: string, accountId: string, messageId: string,
    reactionId: string): void {
    this.conversationService.reactionRemoved(conversationId, accountId, messageId, reactionId);
  }

  /** Swift `func messageUpdated(conversationId:accountId:message:)`. */
  messageUpdated(conversationId: string, accountId: string, message: SwarmMessageWrap): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    this.conversationService.messageUpdated(conversationId, accountId, message, account.jamiId);
  }

  /** Swift `func isDownloadingEnabled(for size: Int) -> Bool`. */
  isDownloadingEnabled(size: number): boolean {
    // Swift's AppDelegate seeds this to true on first launch.
    if (!storedBoolean(AUTOMATIC_DOWNLOAD_FILES_KEY, true)) {
      return false;
    }
    const limit: number = this.maxSizeForAutoaccept;
    if (limit === 0) {
      return true;
    }
    return size <= limit;
  }

  /** Swift `func newInteraction(conversationId:accountId:message:)`. */
  newInteraction(conversationId: string, accountId: string, message: SwarmMessageWrap): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    const newMessage: MessageModel = MessageModel.fromSwarmMessage(message, account.jamiId);
    this.confirmPostCallSyncIfNeeded(accountId, newMessage);
    if (newMessage.type === MessageType.FILE_TRANSFER) {
      newMessage.transferStatus =
        newMessage.incoming ? DataTransferStatus.AWAITING : DataTransferStatus.SUCCESS;
    }
    const inserted: boolean = this.conversationService.insertMessages([newMessage], accountId,
      account.jamiId, conversationId, false);
    if (!inserted) {
      return;
    }
    const author: string | undefined = message.body.get(MessageAttribute.AUTHOR);
    const incoming: boolean = author !== account.jamiId;
    if (incoming) {
      if (newMessage.transferStatus !== DataTransferStatus.AWAITING
        || !this.isDownloadingEnabled(newMessage.totalSize)) {
        return;
      }
    } else if (newMessage.transferStatus !== DataTransferStatus.AWAITING
      && newMessage.transferStatus !== DataTransferStatus.SUCCESS) {
      return;
    }
    this.dataTransferService.downloadFile(newMessage.daemonId, newMessage.id, accountId,
      conversationId);
  }

  /** Swift `func conversationRemoved(conversationId:accountId:)`. */
  conversationRemoved(conversationId: string, accountId: string): void {
    this.requestService.conversationRemoved(conversationId, accountId);
    this.conversationService.conversationRemoved(conversationId, accountId);
  }

  /** Swift `func conversationDeclined(conversationId:accountId:)`. */
  conversationDeclined(conversationId: string, accountId: string): void {
    this.requestService.conversationRemoved(conversationId, accountId);
    this.conversationService.conversationRemoved(conversationId, accountId);
  }

  /** Swift `func activeCallsChanged(conversationId:accountId:calls:)`. */
  activeCallsChanged(conversationId: string, accountId: string,
    calls: Array<Map<string, string>>): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    this.callService.activeCallsChanged(conversationId, calls, account);
  }

  // MARK: extension ConversationsManager: RequestsAdapterDelegate

  /**
   * Swift `func incomingTrustRequestReceived(from:to:conversationId:withPayload:receivedDate:)`.
   * `Data` is a `Uint8Array` here - the vCard payload the daemon hands over.
   */
  incomingTrustRequestReceived(jamiId: string, accountId: string, conversationId: string,
    payload: Uint8Array, receivedDate: Date): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      return;
    }
    if (account.jamiId === jamiId) {
      // This is a request from self. Should not display.
      return;
    }
    this.requestService.incomingTrustRequestReceived(jamiId, accountId, conversationId, payload,
      receivedDate);
  }

  /** Swift `func conversationRequestReceived(conversationId:accountId:metadata:)`. */
  conversationRequestReceived(conversationId: string, accountId: string,
    metadata: Map<string, string>): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    const peerUri: string | undefined = metadata.get('from');
    if (account === null || peerUri === undefined) {
      return;
    }
    if (account.jamiId === peerUri) {
      // This is a request from self. Should not display.
      return;
    }
    this.requestService.conversationRequestReceived(conversationId, accountId, metadata);
  }

  // MARK: extension ConversationsManager: ProfilesAdapterDelegate

  /** Swift `func profileReceived(contact uri:withAccountId:path:)`. */
  profileReceived(uri: string, accountId: string, path: string): void {
    const account: AccountModel | null = this.accountsService.getAccount(accountId);
    if (account === null) {
      this.profileService.profileReceived(uri, accountId, path);
      return;
    }
    if (uri.length === 0 || account.jamiId === uri) {
      this.profileService.accountProfileUpdated(accountId);
      return;
    }
    this.profileService.profileReceived(uri, accountId, path);
  }
}
