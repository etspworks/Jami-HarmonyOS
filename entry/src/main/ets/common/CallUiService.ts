/*
 * Ported from Ring/Ring/Services/Calls/CallKitService.swift:23-302 and
 * Ring/Ring/Services/Calls/CallKitDirectory.swift:27-173
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * PLATFORM-CAPABILITY SUBSTITUTION, NOT A DAEMON GAP.
 *
 * CallKit has no third-party equivalent on HarmonyOS: a self-signed build cannot register a
 * system call provider, and nothing here asks for one - there is no CallKit-shaped API call and
 * no call-provider capability in `module.json5`. What replaces it works for real:
 *
 *   - an IN-APP incoming-call page, driven by the `incomingCall` relay this service publishes
 *     (the page itself is Phase-3 UI; this module is its whole service side);
 *   - a NotificationKit notification on the SOCIAL_COMMUNICATION slot, ongoing and
 *     unremovable while the call rings, carrying Answer / Decline action buttons and a tap
 *     target that deep-links to the call page;
 *   - an AVSession of type `voice_call`/`video_call`, which is what puts the call's controls
 *     on the lock screen and in the control centre, and which delivers the system's
 *     `answer` / `hangUp` / `toggleCallMute` commands back;
 *   - a BackgroundTasksKit CONTINUOUS task in VOIP mode, which is what keeps the app alive
 *     while a call is up (`ohos.permission.KEEP_BACKGROUND_RUNNING` and `backgroundModes`
 *     are already declared).
 *
 * Only the CALL itself is gapped, and `CallService` already reports that once.
 *
 * THE SEAM. `common/CallsManager.ts` is a ONE-WAY port: it imports nothing from here. Its
 * `CallUiPort` turns every Swift `callKit.report…` call into a typed `CallUiRequest` on a
 * stream; this service subscribes to that stream and feeds user decisions back through
 * `port.dispatch(action)`. Every one of `CallUiPort`, `CallUiRequest`, `CallUiRequestKind`,
 * `CallUiAction`, `CallUiActionKind` and `CallHandle` is IMPORTED from there and redeclared
 * nowhere - ArkTS is nominally typed, so a second copy would be a second type on one stream.
 *
 * WHAT ELSE DIFFERS FROM SWIFT:
 *  - `CXProvider`/`CXCallController` become the notification provider and the AVSession; the
 *    field names `provider` and `callController` are kept because that is what they are.
 *  - `CXProviderDelegate` has no counterpart: the delegate methods become `performAnswer`,
 *    `performEnd` and `performSetMuted`, invoked by the notification buttons, the AVSession
 *    commands and the in-app page. `provider(_:perform:)` could not keep its Swift name -
 *    ArkTS has neither method overloading nor a field and a method sharing one name.
 *  - `AVAudioSession` has no HarmonyOS counterpart, so the two audio-session actions carry no
 *    payload (`CallUiAction.audioSessionActivated()` already drops it) and are raised from the
 *    AVSession's activation instead.
 *  - Picture-in-picture, where the call screen offers it, is `@ohos.PiPWindow` and belongs to
 *    the Phase-3 call screen; a float window is never used.
 *  - `ServiceRegistry` deliberately does not vend this service (`svc_registry` outOfScope:
 *    callKitService). The composition root builds it: `new CallUiService()`, `setContext(...)`,
 *    then `start(registry.callsManager.callKit)`. `start()` is idempotent; `stop()` is the
 *    teardown Swift never needed.
 */
import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import {
  CallHandle, CallUiAction, CallUiPort, CallUiRequest, CallUiRequestKind
} from './CallsManager';
import { CallId, CallState } from '../model/CallState';
import { BehaviorRelay, DisposeBag } from './Observable';
import { describeError } from './ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CallUiService';

/** Swift `placeholderTimeout: TimeInterval = 15`; milliseconds here. */
const DEFAULT_PLACEHOLDER_TIMEOUT_MS: number = 15000;

/** `want.parameters` keys the ability reads to route a notification tap back into the app. */
export const CALL_UI_UUID_PARAM: string = 'callUiUuid';
export const CALL_UI_ACTION_PARAM: string = 'callUiAction';

/** Values `CALL_UI_ACTION_PARAM` carries. */
export enum CallUiNotificationAction {
  ANSWER = 'ANSWER',
  DECLINE = 'DECLINE',
  SHOW = 'SHOW'
}

const BACKGROUND_TASK_REASON: string = 'jami ongoing call';

/*
 * Notification button and badge text. They belong in `resources/base/element/string.json`;
 * adding a string resource is an orchestrator-serial edit, so they are carried here as
 * constants with the resource names the Phase-3 pass should resolve them to
 * (`call_answer`, `call_decline`, `call_video`).
 */
const ANSWER_BUTTON_LABEL: string = 'Answer';
const DECLINE_BUTTON_LABEL: string = 'Decline';
const VIDEO_CALL_LABEL: string = 'Video';

/* ------------------------------------------------------------------------------------------
 * CallKitDirectory - a pure state machine, ported verbatim
 * ---------------------------------------------------------------------------------------- */

/** Swift `CallKitDirectory.UserDecision`. */
export enum CallUiDecisionKind {
  ACCEPTED = 'ACCEPTED',
  DECLINED = 'DECLINED'
}

/** Swift's enum carried `withVideo` on `.accepted`; ArkTS enums carry no payload. */
export class CallUiDecision {
  readonly kind: CallUiDecisionKind;
  readonly withVideo: boolean;

  private constructor(kind: CallUiDecisionKind, withVideo: boolean) {
    this.kind = kind;
    this.withVideo = withVideo;
  }

  static accepted(withVideo: boolean): CallUiDecision {
    return new CallUiDecision(CallUiDecisionKind.ACCEPTED, withVideo);
  }

  static declined(): CallUiDecision {
    return new CallUiDecision(CallUiDecisionKind.DECLINED, false);
  }
}

/** Swift `CallKitDirectory.DecisionOutcome`. */
export enum CallUiDecisionOutcomeKind {
  STORED_ON_PLACEHOLDER = 'STORED_ON_PLACEHOLDER',
  APPLY_TO_CALL = 'APPLY_TO_CALL',
  UNKNOWN_CALL = 'UNKNOWN_CALL'
}

export class CallUiDecisionOutcome {
  readonly kind: CallUiDecisionOutcomeKind;
  /** Set only for `APPLY_TO_CALL`. */
  readonly callId: CallId | null;

  constructor(kind: CallUiDecisionOutcomeKind, callId: CallId | null) {
    this.kind = kind;
    this.callId = callId;
  }
}

/** Swift `CallKitDirectory.Placeholder` - a pushed call libjami has not reported yet. */
export class CallUiPlaceholder {
  readonly peerId: string;
  readonly accountId: string;
  readonly displayName: string;
  readonly hasVideo: boolean;
  decision: CallUiDecision | null = null;

  constructor(peerId: string, accountId: string, displayName: string, hasVideo: boolean) {
    this.peerId = peerId;
    this.accountId = accountId;
    this.displayName = displayName;
    this.hasVideo = hasVideo;
  }
}

/** Swift `match(peerId:accountId:callId:)` returns `(uuid, pendingDecision)`. */
export class CallUiMatch {
  readonly uuid: string;
  readonly pendingDecision: CallUiDecision | null;

  constructor(uuid: string, pendingDecision: CallUiDecision | null) {
    this.uuid = uuid;
    this.pendingDecision = pendingDecision;
  }
}

/**
 * Swift `struct CallKitDirectory` - the association between a presentation id and a libjami
 * call, unchanged except for the UUID type (a string here) and the `associations` enum, which
 * becomes two maps because ArkTS enums carry no payload.
 */
export class CallUiDirectory {
  private placeholders: Map<string, CallUiPlaceholder> = new Map<string, CallUiPlaceholder>();
  private liveCalls: Map<string, CallId> = new Map<string, CallId>();

  /**
   * Swift `mutating func addPlaceholder(...)` - replaces the peer's existing placeholder on
   * this account and returns the replaced id so the caller can tear its presentation down.
   */
  addPlaceholder(uuid: string, peerId: string, accountId: string, displayName: string,
                 hasVideo: boolean): string | null {
    const replaced: string | null = this.placeholderUUID(peerId, accountId);
    if (replaced !== null) {
      this.placeholders.delete(replaced);
    }
    this.placeholders.set(uuid,
      new CallUiPlaceholder(peerId, accountId, displayName, hasVideo));
    return replaced;
  }

  /** Swift `func placeholderUUID(peerId:accountId:)`. */
  placeholderUUID(peerId: string, accountId: string): string | null {
    let found: string | null = null;
    this.placeholders.forEach((placeholder: CallUiPlaceholder, uuid: string) => {
      if (found === null && placeholder.peerId === peerId
        && placeholder.accountId === accountId) {
        found = uuid;
      }
    });
    return found;
  }

  /** Swift `func placeholder(uuid:)`. */
  placeholder(uuid: string): CallUiPlaceholder | null {
    const found: CallUiPlaceholder | undefined = this.placeholders.get(uuid);
    return found === undefined ? null : found;
  }

  /** Swift `func allPlaceholderUUIDs()`. */
  allPlaceholderUUIDs(): string[] {
    const uuids: string[] = [];
    this.placeholders.forEach((placeholder: CallUiPlaceholder, uuid: string) => {
      uuids.push(uuid);
    });
    return uuids;
  }

  /** Swift `mutating func recordCallAction(uuid:_:)`. */
  recordCallAction(uuid: string, decision: CallUiDecision): CallUiDecisionOutcome {
    const placeholder: CallUiPlaceholder | undefined = this.placeholders.get(uuid);
    if (placeholder !== undefined) {
      placeholder.decision = decision;
      return new CallUiDecisionOutcome(CallUiDecisionOutcomeKind.STORED_ON_PLACEHOLDER, null);
    }
    const callId: CallId | undefined = this.liveCalls.get(uuid);
    if (callId !== undefined) {
      return new CallUiDecisionOutcome(CallUiDecisionOutcomeKind.APPLY_TO_CALL, callId);
    }
    return new CallUiDecisionOutcome(CallUiDecisionOutcomeKind.UNKNOWN_CALL, null);
  }

  /** Swift `mutating func match(peerId:accountId:callId:)`. */
  match(peerId: string, accountId: string, callId: CallId): CallUiMatch | null {
    const uuid: string | null = this.placeholderUUID(peerId, accountId);
    if (uuid === null) {
      return null;
    }
    const placeholder: CallUiPlaceholder | undefined = this.placeholders.get(uuid);
    if (placeholder === undefined) {
      return null;
    }
    this.placeholders.delete(uuid);
    this.liveCalls.set(uuid, callId);
    return new CallUiMatch(uuid, placeholder.decision);
  }

  /** Swift `mutating func attach(uuid:to:)`. */
  attach(uuid: string, callId: CallId): void {
    this.placeholders.delete(uuid);
    this.liveCalls.set(uuid, callId);
  }

  /** Swift `mutating func remove(uuid:)`. */
  remove(uuid: string): void {
    this.placeholders.delete(uuid);
    this.liveCalls.delete(uuid);
  }

  /** Swift `mutating func expirePlaceholder(uuid:)` - a promoted association is left alone. */
  expirePlaceholder(uuid: string): boolean {
    if (!this.placeholders.has(uuid)) {
      return false;
    }
    this.placeholders.delete(uuid);
    return true;
  }

  /** Swift `func isTracked(_:)`. */
  isTracked(uuid: string): boolean {
    return this.placeholders.has(uuid) || this.liveCalls.has(uuid);
  }

  /** Swift `func callId(for:)`. */
  callId(uuid: string): CallId | null {
    const found: CallId | undefined = this.liveCalls.get(uuid);
    return found === undefined ? null : found;
  }

  /** Swift `func uuid(for callId:)`. */
  uuid(callId: CallId): string | null {
    let found: string | null = null;
    this.liveCalls.forEach((id: CallId, uuid: string) => {
      if (found === null && id.raw === callId.raw) {
        found = uuid;
      }
    });
    return found;
  }

  /** Swift `var isEmpty`. */
  get isEmpty(): boolean {
    return this.placeholders.size === 0 && this.liveCalls.size === 0;
  }

  /** Swift's CXCallObserver `calls`: every id currently presented. */
  get activeCalls(): string[] {
    const uuids: string[] = this.allPlaceholderUUIDs();
    this.liveCalls.forEach((id: CallId, uuid: string) => {
      uuids.push(uuid);
    });
    return uuids;
  }
}

/* ------------------------------------------------------------------------------------------
 * The presentation - what Swift handed to CXCallUpdate, and what the in-app page renders
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `CXCallUpdate`, with the fields `configure(_:callerName:hasVideo:)` sets. It is also
 * the value the Phase-3 incoming-call page binds to, which is why it carries the ids as well.
 */
export class CallUiUpdate {
  readonly uuid: string;
  readonly callId: CallId | null;
  readonly peerId: string;
  readonly accountId: string;
  readonly incoming: boolean;

  /** Swift `update.remoteHandle = CXHandle(type:value:)`. */
  remoteHandle: string = '';
  /** Swift `CXHandle(type: .phoneNumber)` vs `.generic`. */
  remoteHandleIsPhoneNumber: boolean = false;
  /** Swift `update.localizedCallerName`. */
  localizedCallerName: string = '';
  /** Swift `update.hasVideo`. */
  hasVideo: boolean = false;
  /** Swift `update.supportsGrouping = false`. */
  supportsGrouping: boolean = false;
  /** Swift `update.supportsUngrouping = false`. */
  supportsUngrouping: boolean = false;
  /** Swift `update.supportsHolding = false`. */
  supportsHolding: boolean = false;
  /** Swift `CXStartCallAction.contactIdentifier`. */
  contactIdentifier: string = '';

  constructor(uuid: string, callId: CallId | null, peerId: string, accountId: string,
              incoming: boolean) {
    this.uuid = uuid;
    this.callId = callId;
    this.peerId = peerId;
    this.accountId = accountId;
    this.incoming = incoming;
  }
}

/* ------------------------------------------------------------------------------------------
 * The notification half of the substitution
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `CXProvider` - what actually puts a ringing call in front of the user. Here that is a
 * NotificationKit publish on the SOCIAL_COMMUNICATION slot; `reportNewIncomingCall`'s
 * completion becomes the publish promise, which is what still lets a call be refused when it
 * cannot be presented.
 */
export class CallNotificationProvider {
  private context: common.UIAbilityContext | null = null;
  /** Notification ids are numeric; one per presented call, assigned on publish. */
  private ids: Map<string, number> = new Map<string, number>();
  private nextId: number = 1;
  private enablementRequested: boolean = false;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** Swift `provider.reportNewIncomingCall(with:update:completion:)`. */
  async present(update: CallUiUpdate): Promise<void> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      throw new Error('CallUiService has no context (call setContext at startup)');
    }
    let id: number | undefined = this.ids.get(update.uuid);
    if (id === undefined) {
      id = this.nextId;
      this.nextId += 1;
      this.ids.set(update.uuid, id);
    }
    const basic: notificationManager.NotificationBasicContent = {
      title: update.localizedCallerName.length > 0
        ? update.localizedCallerName : update.remoteHandle,
      text: update.remoteHandle
    };
    // Empty optional fields are rejected with 401, so they are only set when they carry text.
    if (update.hasVideo) {
      basic.additionalText = VIDEO_CALL_LABEL;
    }
    // publish() answers 401 when the content type is missing, whatever `normal` carries.
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: basic
    };
    const buttons: notificationManager.NotificationActionButton[] = [];
    if (update.incoming) {
      const answer: notificationManager.NotificationActionButton = {
        title: ANSWER_BUTTON_LABEL,
        wantAgent: await this.callWantAgent(context, update.uuid, id,
          CallUiNotificationAction.ANSWER)
      };
      const decline: notificationManager.NotificationActionButton = {
        title: DECLINE_BUTTON_LABEL,
        wantAgent: await this.callWantAgent(context, update.uuid, id,
          CallUiNotificationAction.DECLINE)
      };
      buttons.push(answer);
      buttons.push(decline);
    }
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: content,
      // A ringing call must survive the app backgrounding. (`isUnremovable` is a system API.)
      isOngoing: true,
      tapDismissed: false,
      wantAgent: await this.callWantAgent(context, update.uuid, id, CallUiNotificationAction.SHOW)
    };
    if (buttons.length > 0) {
      request.actionButtons = buttons;
    }
    await notificationManager.publish(request);
  }

  /** Swift `provider.reportCall(with:updated:)` - the same publish, which replaces by id. */
  async update(update: CallUiUpdate): Promise<void> {
    await this.present(update);
  }

  /** Swift `provider.reportCall(with:endedAt:reason:)`. */
  dismiss(uuid: string): void {
    const id: number | undefined = this.ids.get(uuid);
    if (id === undefined) {
      return;
    }
    this.ids.delete(uuid);
    notificationManager.cancel(id).catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cancel notification failed: %{public}s',
        describeError(error));
    });
  }

  /** Swift `provider.invalidate()` - ends every presented call at once. */
  dismissAll(): void {
    this.ids.clear();
    notificationManager.cancelAll().catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cancelAll failed: %{public}s', describeError(error));
    });
  }

  /**
   * The system "Allow Jami to send you notifications?" prompt, asked once. Never from `present()`:
   * raised in the call path, the prompt is in front of the app as the call screen opens and that
   * screen never appears (T-1602). The ability asks when an account exists instead.
   */
  async ensureEnabled(): Promise<void> {
    const context: common.UIAbilityContext | null = this.context;
    if (this.enablementRequested || context === null) {
      return;
    }
    this.enablementRequested = true;
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (error) {
      // A refusal is the user's decision; the in-app page still presents the call.
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'notifications not enabled: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /** The deep link back into the app: the call page plus what the button decided. */
  private async callWantAgent(context: common.UIAbilityContext, uuid: string, id: number,
                              action: CallUiNotificationAction): Promise<WantAgent> {
    const parameters: Record<string, string> = {};
    parameters[CALL_UI_UUID_PARAM] = uuid;
    parameters[CALL_UI_ACTION_PARAM] = action as string;
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      parameters: parameters
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      // Distinct per call and action: agents sharing a request code are one agent whatever their
      // parameters, so one call's buttons could carry another call's uuid (T-1636).
      requestCode: id * 3 + CallNotificationProvider.requestCodeFor(action)
    };
    return await wantAgent.getWantAgent(info);
  }

  /** A stable, distinct request code per notification action. */
  private static requestCodeFor(action: CallUiNotificationAction): number {
    if (action === CallUiNotificationAction.ANSWER) {
      return 1;
    }
    if (action === CallUiNotificationAction.DECLINE) {
      return 2;
    }
    return 0;
  }
}

/* ------------------------------------------------------------------------------------------
 * The service
 * ---------------------------------------------------------------------------------------- */

/** Swift `final class CallKitService: NSObject`. */
export class CallUiService {
  /** Swift `private let provider: CXProvider` - the notification channel. */
  private readonly provider: CallNotificationProvider = new CallNotificationProvider();

  /**
   * Swift `private let callController: CXCallController` - the system's call-control surface.
   * Here that is the AVSession: it carries the lock-screen / control-centre controls and
   * delivers `answer` / `hangUp` / `toggleCallMute` back.
   */
  private callController: avSession.AVSession | null = null;

  /** Swift `private(set) var directory = CallKitDirectory()`. */
  private readonly directoryState: CallUiDirectory = new CallUiDirectory();

  get directory(): CallUiDirectory {
    return this.directoryState;
  }

  /** Swift `private let placeholderTimeout: TimeInterval`. */
  private readonly placeholderTimeout: number = DEFAULT_PLACEHOLDER_TIMEOUT_MS;

  /**
   * Swift `var onAction: ((CallKitAction) -> Void)?` - "set by the facade; receives every
   * CallKit-initiated action". `start()` points it at `CallUiPort.dispatch`, which is the
   * facade here; a caller may replace it (the Swift contract) and the port still works.
   */
  onAction: ((action: CallUiAction) => void) | null = null;

  /** Swift's CXCallUpdate `muted` - whether the user muted from the call controls. */
  private muted: boolean = false;

  /** Whether the AVSession is currently activated (Swift's CXProvider `active`). */
  private active: boolean = false;

  /**
   * The newest call handed to the AVSession and the state it was given. Swift's CXActions carry
   * their call's UUID; the one session here does not, so its commands resolve the call when they
   * fire (T-1636: a second call used to leave them bound to the first call's id).
   */
  private sessionUuid: string = '';
  private sessionState: avSession.CallState = avSession.CallState.CALL_STATE_IDLE;
  /** createAVSession is in flight: a second call only retargets it instead of making another. */
  private sessionPending: boolean = false;

  /**
   * What the Phase-3 incoming-call page binds to: the call being presented, or null when none
   * is. This is the in-app half of the substitution, and the reason the user still sees a
   * ringing call without a system provider.
   */
  readonly incomingCall: BehaviorRelay<CallUiUpdate | null> = new BehaviorRelay<CallUiUpdate | null>(null);

  private readonly presentations: Map<string, CallUiUpdate> = new Map<string, CallUiUpdate>();
  private readonly expiryTimers: Map<string, number> = new Map<string, number>();
  private readonly disposeBag: DisposeBag = new DisposeBag();

  private context: common.UIAbilityContext | null = null;
  private port: CallUiPort | null = null;
  private started: boolean = false;
  private backgroundTaskRunning: boolean = false;

  /** CALL ONCE at startup, before `start(...)`. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
    this.provider.setContext(context);
  }

  /** Swift AppDelegate `requestNotificationAuthorization()`; the ability decides when. */
  requestNotificationPermission(): void {
    this.provider.ensureEnabled();
  }

  /**
   * Subscribe to the port's request stream and route decisions back to it. Idempotent
   * (the `ConversationsManager.start()` precedent), so the composition root may call it twice.
   */
  start(port: CallUiPort): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.port = port;
    this.onAction = (action: CallUiAction): void => {
      port.dispatch(action);
    };
    const unsubscribe: () => void = port.requests.subscribe((request: CallUiRequest) => {
      this.handleRequest(request);
    });
    this.disposeBag.add(unsubscribe);
  }

  /** Teardown Swift never needed: drop the subscription and every presentation. */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.disposeBag.dispose();
    this.endAllCallsOnTermination();
    this.port = null;
    this.onAction = null;
  }

  /** Every `CallUiPort` instruction, mapped onto the Swift method that answers it. */
  private handleRequest(request: CallUiRequest): void {
    const call: CallState | null = request.call;
    const handle: CallHandle | null = request.handle;
    const callId: CallId | null = request.callId;
    switch (request.kind) {
      case CallUiRequestKind.REPORT_INCOMING:
        if (call !== null && handle !== null) {
          this.reportIncomingCall(call, handle, request.completion);
        }
        break;
      case CallUiRequestKind.REPORT_OUTGOING_STARTED:
        if (call !== null && handle !== null) {
          this.reportOutgoingCallStarted(call, handle);
        }
        break;
      case CallUiRequestKind.REPORT_OUTGOING_CONNECTING:
        if (callId !== null) {
          this.reportOutgoingCallConnecting(callId);
        }
        break;
      case CallUiRequestKind.REPORT_OUTGOING_CONNECTED:
        if (callId !== null) {
          this.reportOutgoingCallConnected(callId);
        }
        break;
      case CallUiRequestKind.REPORT_CALL_ENDED:
        if (callId !== null) {
          this.reportCallEnded(callId, request.isRemoteEnd);
        }
        break;
      case CallUiRequestKind.UPDATE_DISPLAY_NAME:
        if (callId !== null && handle !== null) {
          this.updateDisplayName(callId, handle, request.hasVideo);
        }
        break;
      case CallUiRequestKind.STOP_ALL_PENDING:
        this.stopAllPendingCalls();
        break;
      case CallUiRequestKind.END_ALL_ON_TERMINATION:
        this.endAllCallsOnTermination();
        break;
      default:
        break;
    }
  }

  // MARK: - Push placeholder path

  /**
   * Swift `func previewPendingCall(peerId:accountId:displayName:hasVideo:completion:)` -
   * presents the call for a VoIP push before libjami knows about it. An existing placeholder
   * for the peer is replaced.
   */
  previewPendingCall(peerId: string, accountId: string, displayName: string, hasVideo: boolean,
                     completion: ((error: BusinessError | null) => void) | null): void {
    const uuid: string = util.generateRandomUUID(true);
    const replaced: string | null = this.directoryState.addPlaceholder(uuid, peerId, accountId,
      displayName, hasVideo);
    if (replaced !== null) {
      this.endCallKitCall(replaced, false);
    }
    this.scheduleExpiry(uuid);

    const update: CallUiUpdate = new CallUiUpdate(uuid, null, peerId, accountId, true);
    update.remoteHandle = peerId;
    update.remoteHandleIsPhoneNumber = true;
    this.configure(update, displayName, hasVideo);
    this.presentIncoming(update, completion);
  }

  /** Swift `private func scheduleExpiry(uuid:)` - libjami never reported the pushed call. */
  private scheduleExpiry(uuid: string): void {
    const timer: number = setTimeout(() => {
      this.expiryTimers.delete(uuid);
      if (!this.directoryState.expirePlaceholder(uuid)) {
        return;
      }
      // Swift `provider.reportCall(with:endedAt:reason: .failed)`.
      this.tearDownPresentation(uuid);
    }, this.placeholderTimeout);
    this.expiryTimers.set(uuid, timer);
  }

  // MARK: - libjami-call reporting

  /**
   * Swift `func reportIncomingCall(_:handle:completion:)` - reuse the placeholder's
   * presentation when there is one (replaying any decision the user already took), otherwise
   * present a fresh incoming call.
   */
  reportIncomingCall(call: CallState, handle: CallHandle,
                     completion: ((error: BusinessError | null) => void) | null): void {
    const matched: CallUiMatch | null =
      this.directoryState.match(call.peerHash, call.accountId, call.id);
    if (matched !== null) {
      const decision: CallUiDecision | null = matched.pendingDecision;
      if (decision !== null) {
        if (decision.kind === CallUiDecisionKind.ACCEPTED) {
          this.emit(CallUiAction.answer(call.id, decision.withVideo));
        } else {
          this.emit(CallUiAction.end(call.id));
        }
      }
      if (completion !== null) {
        completion(null);
      }
      return;
    }

    const uuid: string = util.generateRandomUUID(true);
    this.directoryState.attach(uuid, call.id);
    const update: CallUiUpdate =
      new CallUiUpdate(uuid, call.id, call.peerHash, call.accountId, true);
    update.remoteHandle = handle.value;
    update.remoteHandleIsPhoneNumber = handle.isPhoneNumber;
    this.configure(update, handle.displayName, !call.isAudioOnly);
    this.presentIncoming(update, completion);
  }

  /** Swift `func reportOutgoingCallStarted(_:handle:)`. */
  reportOutgoingCallStarted(call: CallState, handle: CallHandle): void {
    const uuid: string = util.generateRandomUUID(true);
    this.directoryState.attach(uuid, call.id);
    const update: CallUiUpdate =
      new CallUiUpdate(uuid, call.id, call.peerHash, call.accountId, false);
    update.remoteHandle = handle.value;
    update.remoteHandleIsPhoneNumber = handle.isPhoneNumber;
    update.contactIdentifier = handle.displayName;
    this.configure(update, handle.displayName, !call.isAudioOnly);
    this.presentations.set(uuid, update);
    this.publish(update);
    this.startCallSession(update, avSession.CallState.CALL_STATE_DIALING);
  }

  /**
   * Swift `func reportOutgoingCallConnecting(_:)`. The one AVSession is not moved off a call that
   * is ringing: a call to another account on this phone rings back as that call arrives (T-1636).
   */
  reportOutgoingCallConnecting(callId: CallId): void {
    const uuid: string | null = this.directoryState.uuid(callId);
    if (uuid === null || this.incomingCall.value !== null) {
      return;
    }
    this.setCallState(avSession.CallState.CALL_STATE_DIALING);
  }

  /** Swift `func reportOutgoingCallConnected(_:)`; a connected call no longer rings. */
  reportOutgoingCallConnected(callId: CallId): void {
    const uuid: string | null = this.directoryState.uuid(callId);
    if (uuid === null) {
      return;
    }
    this.dismissIncomingPresentation(uuid);
    this.setCallState(avSession.CallState.CALL_STATE_ACTIVE);
  }

  /** Swift `func reportCallEnded(_:isRemoteEnd:)`. */
  reportCallEnded(callId: CallId, isRemoteEnd: boolean): void {
    const uuid: string | null = this.directoryState.uuid(callId);
    if (uuid === null) {
      return;
    }
    this.directoryState.remove(uuid);
    this.endCallKitCall(uuid, isRemoteEnd);
  }

  /** Swift `func updateDisplayName(_:handle:hasVideo:)`. */
  updateDisplayName(callId: CallId, handle: CallHandle, hasVideo: boolean): void {
    const uuid: string | null = this.directoryState.uuid(callId);
    if (uuid === null) {
      return;
    }
    const previous: CallUiUpdate | undefined = this.presentations.get(uuid);
    const update: CallUiUpdate = new CallUiUpdate(uuid, callId, handle.value,
      previous === undefined ? '' : previous.accountId,
      previous === undefined ? true : previous.incoming);
    update.remoteHandle = handle.value;
    update.remoteHandleIsPhoneNumber = handle.isPhoneNumber;
    this.configure(update, handle.displayName, hasVideo);
    this.presentations.set(uuid, update);
    if (update.incoming && this.incomingCall.value !== null
      && this.incomingCall.value?.uuid === uuid) {
      this.incomingCall.accept(update);
    }
    this.publish(update);
    this.updateCallMetadata(update);
  }

  // MARK: - Queries

  /** Swift `func hasActiveCalls()`. */
  hasActiveCalls(): boolean {
    return !this.directoryState.isEmpty;
  }

  /** Swift `func stopAllPendingCalls()` - drop every placeholder libjami never claimed. */
  stopAllPendingCalls(): void {
    for (const uuid of this.directoryState.allPlaceholderUUIDs()) {
      this.directoryState.remove(uuid);
      this.endCallKitCall(uuid, false);
    }
  }

  /**
   * Swift `func endAllCallsOnTermination()` - "ends every call reported to CallKit before the
   * process goes away". `provider.invalidate()` becomes cancelling every notification and
   * destroying the AVSession, which are the two things that would otherwise outlive the app.
   */
  endAllCallsOnTermination(): void {
    this.stopAllPendingCalls();
    this.expiryTimers.forEach((timer: number) => {
      clearTimeout(timer);
    });
    this.expiryTimers.clear();
    this.presentations.clear();
    this.incomingCall.accept(null);
    this.provider.dismissAll();
    this.destroyCallSession();
    this.stopBackgroundTask();
  }

  // MARK: - Decisions coming back from the presentation

  /**
   * Swift `func provider(_:perform action: CXAnswerCallAction)`. Renamed: ArkTS has neither
   * method overloading nor a field and a method sharing the name `provider`. Called by the
   * notification's Answer button, the AVSession `answer` command and the in-app page.
   */
  performAnswer(uuid: string, withVideo: boolean): void {
    const outcome: CallUiDecisionOutcome =
      this.directoryState.recordCallAction(uuid, CallUiDecision.accepted(withVideo));
    if (outcome.kind === CallUiDecisionOutcomeKind.APPLY_TO_CALL && outcome.callId !== null) {
      this.dismissIncomingPresentation(uuid);
      this.setCallState(avSession.CallState.CALL_STATE_ACTIVE);
      this.emit(CallUiAction.answer(outcome.callId, withVideo));
      return;
    }
    if (outcome.kind === CallUiDecisionOutcomeKind.STORED_ON_PLACEHOLDER) {
      const placeholder: CallUiPlaceholder | null = this.directoryState.placeholder(uuid);
      if (placeholder !== null) {
        this.dismissIncomingPresentation(uuid);
        this.emit(CallUiAction.answerPending(placeholder.peerId, placeholder.accountId,
          placeholder.hasVideo));
      }
    }
    // `UNKNOWN_CALL`: Swift's `break` - the presentation is gone, there is nothing to answer.
  }

  /**
   * A notification tap or button relaunched the ability. The in-app call screen is already
   * up for a ringing call, so only Answer / Decline act here.
   */
  handleWant(parameters: Record<string, Object> | undefined): void {
    if (parameters === undefined) {
      return;
    }
    const uuid: Object | undefined = parameters[CALL_UI_UUID_PARAM];
    const action: Object | undefined = parameters[CALL_UI_ACTION_PARAM];
    if (typeof uuid !== 'string' || typeof action !== 'string') {
      return;
    }
    const callId: CallId | null = this.directoryState.callId(uuid as string);
    hilog.info(LOG_DOMAIN, 'JamiF5', 'notification %{public}s -> call %{public}s',
      action as string, callId === null ? 'none' : callId.raw);
    if (action === CallUiNotificationAction.ANSWER) {
      this.performAnswer(uuid as string, false);
    } else if (action === CallUiNotificationAction.DECLINE) {
      this.performEnd(uuid as string);
    }
  }

  /** Swift `func provider(_:perform action: CXEndCallAction)`. */
  performEnd(uuid: string): void {
    const outcome: CallUiDecisionOutcome =
      this.directoryState.recordCallAction(uuid, CallUiDecision.declined());
    if (outcome.kind === CallUiDecisionOutcomeKind.APPLY_TO_CALL && outcome.callId !== null) {
      this.directoryState.remove(uuid);
      this.tearDownPresentation(uuid);
      this.emit(CallUiAction.end(outcome.callId));
      return;
    }
    if (outcome.kind === CallUiDecisionOutcomeKind.STORED_ON_PLACEHOLDER) {
      const placeholder: CallUiPlaceholder | null = this.directoryState.placeholder(uuid);
      if (placeholder !== null) {
        this.tearDownPresentation(uuid);
        this.emit(CallUiAction.declinePending(placeholder.peerId, placeholder.accountId));
      }
    }
  }

  /** Swift `func provider(_:perform action: CXSetMutedCallAction)`. */
  performSetMuted(uuid: string, muted: boolean): void {
    const callId: CallId | null = this.directoryState.callId(uuid);
    if (callId === null) {
      return;
    }
    this.muted = muted;
    this.setCallState(avSession.CallState.CALL_STATE_ACTIVE);
    this.emit(CallUiAction.setMuted(callId, muted));
  }

  /**
   * Swift `func providerDidReset(_:)` was empty - CallKit had already torn its own calls down.
   * The substitution has no such guarantee: the notification channel and the AVSession are
   * ours, so a reset means dropping every association and the presentation with it.
   */
  providerDidReset(): void {
    this.directoryState.activeCalls.forEach((uuid: string) => {
      this.directoryState.remove(uuid);
    });
    this.endAllCallsOnTermination();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'call presentation was reset; every call dropped');
  }

  // MARK: - Private

  /** Swift `private func configure(_ update:callerName:hasVideo:)`. */
  private configure(update: CallUiUpdate, callerName: string, hasVideo: boolean): void {
    update.localizedCallerName = callerName;
    update.hasVideo = hasVideo;
    update.supportsGrouping = false;
    update.supportsUngrouping = false;
    update.supportsHolding = false;
  }

  /**
   * Swift `private func endCallKitCall(uuid:isRemoteEnd:)`. The Swift branched on whether the
   * call was outgoing to choose between reporting the end and requesting a CXEndCallAction;
   * both branches tear the presentation down here, and the remote-end case additionally makes
   * sure the in-app page stops ringing.
   */
  private endCallKitCall(uuid: string, isRemoteEnd: boolean): void {
    this.tearDownPresentation(uuid);
    if (isRemoteEnd) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'call %{public}s ended remotely', uuid);
    }
  }

  /** Publish the incoming presentation, in-app and as a notification. */
  private presentIncoming(update: CallUiUpdate,
                          completion: ((error: BusinessError | null) => void) | null): void {
    this.presentations.set(update.uuid, update);
    this.incomingCall.accept(update);
    this.startCallSession(update, avSession.CallState.CALL_STATE_INCOMING);
    this.provider.present(update)
      .catch((error: BusinessError) => {
        // The in-app page above is what rings; the notification only adds to it. So a refused
        // publish (1600004 while notifications are denied) neither declines the call nor reports
        // a failed presentation, as CallKit rings on iOS whatever the notification permission.
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'incoming call notification unavailable: %{public}s',
          describeError(error));
      })
      .then(() => {
        if (completion !== null) {
          completion(null);
        }
      });
  }

  private publish(update: CallUiUpdate): void {
    this.provider.update(update).catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unable to update call notification: %{public}s',
        describeError(error));
    });
  }

  /** The in-app page stops ringing but the call stays up (it was answered). */
  private dismissIncomingPresentation(uuid: string): void {
    this.clearExpiry(uuid);
    if (this.incomingCall.value !== null && this.incomingCall.value?.uuid === uuid) {
      this.incomingCall.accept(null);
    }
  }

  /** The call is over: page, notification, AVSession and keep-alive all go. */
  private tearDownPresentation(uuid: string): void {
    this.clearExpiry(uuid);
    this.presentations.delete(uuid);
    if (this.incomingCall.value !== null && this.incomingCall.value?.uuid === uuid) {
      this.incomingCall.accept(null);
    }
    this.provider.dismiss(uuid);
    if (this.directoryState.isEmpty) {
      this.destroyCallSession();
      this.stopBackgroundTask();
    }
  }

  private clearExpiry(uuid: string): void {
    const timer: number | undefined = this.expiryTimers.get(uuid);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.expiryTimers.delete(uuid);
    }
  }

  /** Swift `onAction?(…)`, called from every delegate method. */
  private emit(action: CallUiAction): void {
    const handler: ((action: CallUiAction) => void) | null = this.onAction;
    if (handler === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no action handler; %{public}s dropped',
        action.kind as string);
      return;
    }
    handler(action);
  }

  // MARK: - AVSession + keep-alive (the system call-controls half of the substitution)

  private startCallSession(update: CallUiUpdate, state: avSession.CallState): void {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no context: call controls unavailable');
      return;
    }
    this.startBackgroundTask(context);
    this.sessionUuid = update.uuid;
    this.sessionState = state;
    if (this.callController !== null) {
      this.updateCallMetadata(update);
      this.setCallState(state);
      return;
    }
    if (this.sessionPending) {
      return;
    }
    this.sessionPending = true;
    const type: avSession.AVSessionType = update.hasVideo ? 'video_call' : 'voice_call';
    avSession.createAVSession(context, LOG_TAG, type)
      .then((session: avSession.AVSession) => {
        this.sessionPending = false;
        this.callController = session;
        session.on('answer', () => {
          this.onCallControl('answer');
        });
        session.on('hangUp', () => {
          this.onCallControl('hangUp');
        });
        session.on('toggleCallMute', () => {
          this.onCallControl('toggleCallMute');
        });
        const current: CallUiUpdate | undefined = this.presentations.get(this.sessionUuid);
        if (current !== undefined) {
          this.updateCallMetadata(current);
        }
        this.setCallState(this.sessionState);
        return session.activate();
      })
      .then(() => {
        this.active = true;
        // Swift's `provider(_:didActivate:)` - the audio route is now the call's.
        this.emit(CallUiAction.audioSessionActivated());
      })
      .catch((error: BusinessError) => {
        this.sessionPending = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'call session unavailable: %{public}s',
          describeError(error));
      });
  }

  /** An AVSession command acts on the ringing call, else the newest live one. */
  private onCallControl(command: string): void {
    const target: CallUiUpdate | null = this.incomingCall.value ??
      this.presentations.get(this.sessionUuid) ?? Array.from(this.presentations.values()).pop() ?? null;
    hilog.info(LOG_DOMAIN, 'JamiF5',
      'call control %{public}s -> call %{public}s (account %{public}s, %{public}d live)',
      command, target?.callId?.raw ?? 'none', target?.accountId ?? '', this.presentations.size);
    if (target === null) {
      return;
    }
    if (command === 'answer') {
      this.performAnswer(target.uuid, target.hasVideo);
    } else if (command === 'hangUp') {
      this.performEnd(target.uuid);
    } else {
      this.performSetMuted(target.uuid, !this.muted);
    }
  }

  private updateCallMetadata(update: CallUiUpdate): void {
    const session: avSession.AVSession | null = this.callController;
    if (session === null) {
      return;
    }
    const metadata: avSession.CallMetadata = {
      name: update.localizedCallerName,
      phoneNumber: update.remoteHandle
    };
    session.setCallMetadata(metadata).catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setCallMetadata failed: %{public}s', describeError(error));
    });
  }

  private setCallState(state: avSession.CallState): void {
    const session: avSession.AVSession | null = this.callController;
    if (session === null) {
      return;
    }
    const callState: avSession.AVCallState = { state: state, muted: this.muted };
    session.setAVCallState(callState).catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setAVCallState failed: %{public}s', describeError(error));
    });
  }

  private destroyCallSession(): void {
    const session: avSession.AVSession | null = this.callController;
    if (session === null) {
      return;
    }
    this.callController = null;
    this.sessionUuid = '';
    const wasActive: boolean = this.active;
    this.active = false;
    this.muted = false;
    session.deactivate()
      .then(() => session.destroy())
      .catch((error: BusinessError) => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'destroying call session failed: %{public}s',
          describeError(error));
      });
    if (wasActive) {
      // Swift's `provider(_:didDeactivate:)`.
      this.emit(CallUiAction.audioSessionDeactivated());
    }
  }

  /** VOIP continuous task: what keeps the app alive while a call is up. */
  private startBackgroundTask(context: common.UIAbilityContext): void {
    if (this.backgroundTaskRunning) {
      return;
    }
    this.backgroundTaskRunning = true;
    const parameters: Record<string, string> = {};
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      parameters: parameters
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent) => backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.VOIP, agent))
      .catch((error: BusinessError) => {
        this.backgroundTaskRunning = false;
        hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s: keep-alive unavailable: %{public}s',
          BACKGROUND_TASK_REASON, describeError(error));
      });
  }

  private stopBackgroundTask(): void {
    const context: common.UIAbilityContext | null = this.context;
    if (!this.backgroundTaskRunning || context === null) {
      return;
    }
    this.backgroundTaskRunning = false;
    backgroundTaskManager.stopBackgroundRunning(context).catch((error: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopBackgroundRunning failed: %{public}s',
        describeError(error));
    });
  }
}
