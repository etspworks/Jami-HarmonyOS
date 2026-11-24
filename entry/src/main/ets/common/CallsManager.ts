/*
 * Ported from Ring/Ring/Services/CallsManager.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * This class owns no data. It is the WIRING between the call domain and the domains it needs
 * but must not own: system call-UI reporting, camera capture, the audio route, and
 * account/contact lookups. Every rule that spans two services lives here.
 *
 * FOUR THINGS DIFFER FROM SWIFT, ALL FORCED BY THE PLATFORM:
 *
 * 1. Construction. Swift's `init(callService:…)` takes seven services and wires everything in
 *    the initializer. `ServiceRegistry` builds every service with a zero-argument constructor
 *    and forbids reading the registry during construction (the import cycle is only safe while
 *    nothing runs at module-evaluation time), so the constructor is EMPTY, every service is
 *    read through a private getter inside the method that uses it, and the Swift init body is
 *    `start()` - which the composition root calls once, and which is idempotent. `stop()` is
 *    the teardown Swift never needed. The registry holds this object as a mutable nullable
 *    field (`callsManager`), assigned by that same composition root.
 *
 * 2. CallKit. HarmonyOS has no system call provider a self-signed build may register with, so
 *    `CallKitService` is NOT ported as a CallKit-shaped API (see
 *    results/analysis/permission-substitutions.json). The substitution is an in-app
 *    incoming-call page + a NotificationKit publish with AVSession live-view controls, built by
 *    `CallUiService` (svc_call_ui). The seam between the two is `CallUiPort` below: this class
 *    keeps calling `reportIncomingCall` / `reportOutgoingCallStarted` / … exactly as Swift did,
 *    the port turns each into a typed `CallUiRequest` on a stream, and `CallUiService`
 *    subscribes to that stream and feeds user decisions back through `dispatch(action)`. The
 *    port is deliberately the ONLY direction of coupling: this module imports nothing from
 *    `CallUiService`, so the two can be written independently.
 *
 * 3. Threading. Swift hopped every call event onto the main queue (`DispatchQueue.main.async`)
 *    because CallKit reporting and capture teardown are main-thread work. ArkTS runs this
 *    module on the ability's own thread and the callbacks already arrive there, so the hop is
 *    dropped rather than emulated.
 *
 * 4. `Task { await … }` becomes a private `async` method invoked without `await`; failures are
 *    logged rather than thrown into nowhere, which is what the Swift Task did.
 *
 * The jami daemon is a GAP on HarmonyOS (no source on disk - see common/DaemonService.ts), so
 * no libjami call signal will ever reach `handle()`. Following the precedent set by
 * ConversationsManager, this module reports that gap NOWHERE: it performs no daemon operation
 * of its own, and the services that own the daemon surface (CallService, AccountsService,
 * ContactsService, NameService) report it once each. The parts that need no daemon - the
 * call-UI state machine, the handle/display-name rules, the booth-mode cleanup rule, the
 * camera preparation rules - work for real.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { DisposeBag, PublishSubject } from './Observable';
import { describeError } from './ErrorText';
import { JamiUri, UriType } from './JamiUri';
import { ServiceRegistry } from './ServiceRegistry';
import { ContactModel } from '../model/ContactModel';

import { AccountsService } from './AccountsService';
import { AudioService } from './AudioService';
import { CallCameraCoordinating, CallService, CallSystemEvent, CallSystemEventKind } from './CallService';
import { ContactsService } from './ContactsService';
import { LookupNameResponse, LookupNameState, NameService } from './NameService';
import { VideoService } from './VideoService';

import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { CallDirection, CallId, CallState, CallSystemState, ConferenceState } from '../model/CallState';
import { CallStatus, CallStatusKind, TerminationReason } from '../model/CallStatus';
import { ConfigKey } from '../model/ConfigKeyModel';
import { MediaLabel } from '../model/MediaItem';
import { SinkId } from '../model/SinkId';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CallsManager';

/**
 * Swift `String.isPhoneNumber`, which used `NSDataDetector`. HarmonyOS ships no data detector,
 * so this is a conservative pattern: an optional '+', then digits with optional separators, at
 * least 5 digits in all, and the WHOLE string must match - the same "is this handle dialable"
 * question, decided by shape instead of by a locale-aware parser. Ceiling: it accepts a few
 * strings a locale parser would reject; it is only used to label a SIP handle.
 */
const PHONE_NUMBER_PATTERN: RegExp = new RegExp('^\\+?[0-9][0-9 ()\\-.]{3,}[0-9]$');

function isPhoneNumber(value: string): boolean {
  if (!PHONE_NUMBER_PATTERN.test(value)) {
    return false;
  }
  let digits: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code >= 0x30 && code <= 0x39) {
      digits++;
    }
  }
  return digits >= 5;
}

/** Swift `struct CallKitHandle` - the label the call UI shows for the remote party. */
export class CallHandle {
  readonly value: string;
  readonly displayName: string;
  readonly isPhoneNumber: boolean;

  constructor(value: string, displayName: string, isPhoneNumber: boolean) {
    this.value = value;
    this.displayName = displayName;
    this.isPhoneNumber = isPhoneNumber;
  }
}

/** The CallKit reporting calls Swift made, as values `CallUiService` consumes. */
export enum CallUiRequestKind {
  REPORT_INCOMING = 'REPORT_INCOMING',
  REPORT_OUTGOING_STARTED = 'REPORT_OUTGOING_STARTED',
  REPORT_OUTGOING_CONNECTING = 'REPORT_OUTGOING_CONNECTING',
  REPORT_OUTGOING_CONNECTED = 'REPORT_OUTGOING_CONNECTED',
  REPORT_CALL_ENDED = 'REPORT_CALL_ENDED',
  UPDATE_DISPLAY_NAME = 'UPDATE_DISPLAY_NAME',
  STOP_ALL_PENDING = 'STOP_ALL_PENDING',
  END_ALL_ON_TERMINATION = 'END_ALL_ON_TERMINATION'
}

/**
 * One instruction to the in-app call UI. `completion` is Swift's
 * `reportIncomingCall(_:handle:completion:)` callback: the UI calls it with the failure when it
 * could not present the call, which is what makes the incoming call get refused rather than
 * ring silently forever.
 */
export class CallUiRequest {
  readonly kind: CallUiRequestKind;
  readonly callId: CallId | null;
  readonly call: CallState | null;
  readonly handle: CallHandle | null;
  hasVideo: boolean = false;
  isRemoteEnd: boolean = false;
  completion: ((error: BusinessError | null) => void) | null = null;

  constructor(kind: CallUiRequestKind, callId: CallId | null, call: CallState | null,
              handle: CallHandle | null) {
    this.kind = kind;
    this.callId = callId;
    this.call = call;
    this.handle = handle;
  }
}

/** Swift `enum CallKitAction` - a decision the user made on the system/in-app call UI. */
export enum CallUiActionKind {
  ANSWER = 'ANSWER',
  ANSWER_PENDING = 'ANSWER_PENDING',
  END = 'END',
  DECLINE_PENDING = 'DECLINE_PENDING',
  SET_MUTED = 'SET_MUTED',
  AUDIO_SESSION_ACTIVATED = 'AUDIO_SESSION_ACTIVATED',
  AUDIO_SESSION_DEACTIVATED = 'AUDIO_SESSION_DEACTIVATED'
}

/**
 * Swift's enum carried associated values per case; ArkTS enums carry none, so this is the same
 * value class shape the ported models use (`CallStatus`, `MediaLabel`): a kind plus the payload
 * fields that kind fills. The `AVAudioSession` Swift attached to the two audio-session cases
 * has no HarmonyOS counterpart and is dropped - nothing read it.
 */
export class CallUiAction {
  readonly kind: CallUiActionKind;
  readonly callId: CallId | null;
  readonly withVideo: boolean;
  readonly peerId: string;
  readonly accountId: string;
  readonly muted: boolean;

  private constructor(kind: CallUiActionKind, callId: CallId | null, withVideo: boolean,
                      peerId: string, accountId: string, muted: boolean) {
    this.kind = kind;
    this.callId = callId;
    this.withVideo = withVideo;
    this.peerId = peerId;
    this.accountId = accountId;
    this.muted = muted;
  }

  /** Swift `.answer(callId:withVideo:)`. */
  static answer(callId: CallId, withVideo: boolean): CallUiAction {
    return new CallUiAction(CallUiActionKind.ANSWER, callId, withVideo, '', '', false);
  }

  /** Swift `.answerPending(peerId:accountId:hasVideo:)` - accepted before libjami reported. */
  static answerPending(peerId: string, accountId: string, hasVideo: boolean): CallUiAction {
    return new CallUiAction(CallUiActionKind.ANSWER_PENDING, null, hasVideo, peerId, accountId,
      false);
  }

  /** Swift `.end(callId:)`. */
  static end(callId: CallId): CallUiAction {
    return new CallUiAction(CallUiActionKind.END, callId, false, '', '', false);
  }

  /** Swift `.declinePending(peerId:accountId:)`. */
  static declinePending(peerId: string, accountId: string): CallUiAction {
    return new CallUiAction(CallUiActionKind.DECLINE_PENDING, null, false, peerId, accountId,
      false);
  }

  /** Swift `.setMuted(callId:muted:)`. */
  static setMuted(callId: CallId, muted: boolean): CallUiAction {
    return new CallUiAction(CallUiActionKind.SET_MUTED, callId, false, '', '', muted);
  }

  /** Swift `.audioSessionActivated(_:)`. */
  static audioSessionActivated(): CallUiAction {
    return new CallUiAction(CallUiActionKind.AUDIO_SESSION_ACTIVATED, null, false, '', '', false);
  }

  /** Swift `.audioSessionDeactivated(_:)`. */
  static audioSessionDeactivated(): CallUiAction {
    return new CallUiAction(CallUiActionKind.AUDIO_SESSION_DEACTIVATED, null, false, '', '',
      false);
  }
}

/**
 * The substitution seam for Swift's `CallKitService`, reached as `callsManager.callKit`.
 *
 * It keeps the method names of the Swift service so the wiring below reads like the source, but
 * it performs no presentation of its own: each call becomes a `CallUiRequest` on `requests`,
 * which `CallUiService` (svc_call_ui) turns into the in-app incoming-call page, a
 * NotificationKit publish and the AVSession live-view controls. What the port DOES own is the
 * set of calls currently reported to that UI, which is how `hasActiveCalls()` answers without a
 * CXCallObserver.
 */
export class CallUiPort {
  /** Every instruction to the call UI. `CallUiService` is the subscriber. */
  readonly requests: PublishSubject<CallUiRequest> = new PublishSubject<CallUiRequest>();

  /** Swift `var onAction: ((CallKitAction) -> Void)?` - set by CallsManager.start(). */
  onAction: ((action: CallUiAction) => void) | null = null;

  /** Swift's `CallKitDirectory`, reduced to what this side needs: what the UI is showing. */
  private reported: Set<string> = new Set<string>();

  /** Swift `func reportIncomingCall(_:handle:completion:)`. */
  reportIncomingCall(call: CallState, handle: CallHandle,
                     completion: ((error: BusinessError | null) => void) | null): void {
    this.reported.add(call.id.raw);
    const request: CallUiRequest =
      new CallUiRequest(CallUiRequestKind.REPORT_INCOMING, call.id, call, handle);
    request.hasVideo = !call.isAudioOnly;
    request.completion = (error: BusinessError | null): void => {
      if (error !== null) {
        this.reported.delete(call.id.raw);
      }
      if (completion !== null) {
        completion(error);
      }
    };
    this.requests.onNext(request);
  }

  /** Swift `func reportOutgoingCallStarted(_:handle:)`. */
  reportOutgoingCallStarted(call: CallState, handle: CallHandle): void {
    this.reported.add(call.id.raw);
    const request: CallUiRequest =
      new CallUiRequest(CallUiRequestKind.REPORT_OUTGOING_STARTED, call.id, call, handle);
    request.hasVideo = !call.isAudioOnly;
    this.requests.onNext(request);
  }

  /** Swift `func reportOutgoingCallConnecting(_:)`. */
  reportOutgoingCallConnecting(callId: CallId): void {
    if (!this.reported.has(callId.raw)) {
      return;
    }
    this.requests.onNext(
      new CallUiRequest(CallUiRequestKind.REPORT_OUTGOING_CONNECTING, callId, null, null));
  }

  /** Swift `func reportOutgoingCallConnected(_:)`. */
  reportOutgoingCallConnected(callId: CallId): void {
    if (!this.reported.has(callId.raw)) {
      return;
    }
    this.requests.onNext(
      new CallUiRequest(CallUiRequestKind.REPORT_OUTGOING_CONNECTED, callId, null, null));
  }

  /** Swift `func reportCallEnded(_:isRemoteEnd:)` - a call the UI never showed is not ended. */
  reportCallEnded(callId: CallId, isRemoteEnd: boolean): void {
    if (!this.reported.delete(callId.raw)) {
      return;
    }
    const request: CallUiRequest =
      new CallUiRequest(CallUiRequestKind.REPORT_CALL_ENDED, callId, null, null);
    request.isRemoteEnd = isRemoteEnd;
    this.requests.onNext(request);
  }

  /** Swift `func updateDisplayName(_:handle:hasVideo:)`. */
  updateDisplayName(callId: CallId, handle: CallHandle, hasVideo: boolean): void {
    if (!this.reported.has(callId.raw)) {
      return;
    }
    const request: CallUiRequest =
      new CallUiRequest(CallUiRequestKind.UPDATE_DISPLAY_NAME, callId, null, handle);
    request.hasVideo = hasVideo;
    this.requests.onNext(request);
  }

  /** Swift `func hasActiveCalls()`. */
  hasActiveCalls(): boolean {
    return this.reported.size > 0;
  }

  /** Swift `func stopAllPendingCalls()` - the push placeholders are CallUiService's to drop. */
  stopAllPendingCalls(): void {
    this.requests.onNext(
      new CallUiRequest(CallUiRequestKind.STOP_ALL_PENDING, null, null, null));
  }

  /** Swift `func endAllCallsOnTermination()`. */
  endAllCallsOnTermination(): void {
    this.reported.clear();
    this.requests.onNext(
      new CallUiRequest(CallUiRequestKind.END_ALL_ON_TERMINATION, null, null, null));
  }

  /**
   * Swift called `onAction?(…)` from inside the CXProvider delegate. Here the in-app call UI
   * calls this instead; the handler is CallsManager's.
   */
  dispatch(action: CallUiAction): void {
    const handler: ((action: CallUiAction) => void) | null = this.onAction;
    if (handler !== null) {
      handler(action);
    }
  }
}

export class CallsManager implements CallCameraCoordinating {
  /** Swift `let callToPresent = PublishSubject<CallState>()` - the in-call screen's trigger. */
  readonly callToPresent: PublishSubject<CallState> = new PublishSubject<CallState>();

  /**
   * Swift `private let callKit: CallKitService`. Public here: the substitute call UI
   * (`CallUiService`, svc_call_ui) must reach the port to subscribe and to feed actions back,
   * and the registry does not vend a CallKit service for it to share.
   */
  readonly callKit: CallUiPort = new CallUiPort();

  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /** No Swift counterpart - `start()` is called by the composition root and is idempotent. */
  private started: boolean = false;

  // MARK: services (read through the registry, never in the constructor)

  /** Swift `private let callService: CallService`. */
  private get callService(): CallService {
    return ServiceRegistry.shared().callService;
  }

  /** Swift `private let videoService: VideoService`. */
  private get videoService(): VideoService {
    return ServiceRegistry.shared().videoService;
  }

  /** Swift `private let audioService: AudioService`. */
  private get audioService(): AudioService {
    return ServiceRegistry.shared().audioService;
  }

  /** Swift `private let accountsService: AccountsService`. */
  private get accountsService(): AccountsService {
    return ServiceRegistry.shared().accountService;
  }

  /** Swift `private let contactsService: ContactsService`. */
  private get contactsService(): ContactsService {
    return ServiceRegistry.shared().contactsService;
  }

  /** Swift `private let nameService: NameService`. */
  private get nameService(): NameService {
    return ServiceRegistry.shared().nameService;
  }

  // MARK: lifecycle

  /**
   * Swift `init(callService:…)`. The initializer body, verbatim in order: the three
   * subscriptions first, then `callService.start()` LAST - the store only begins consuming once
   * every domain above is wired, so no call event can be handled unwired.
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.subscribeCallEvents();
    this.subscribeCallKitActions();
    this.subscribeCaptureQuality();
    this.callService.start();
  }

  /**
   * No Swift counterpart - the iOS object lived for the whole process. Drops the three
   * callbacks it installed on other services so a torn-down ability leaves nothing calling in.
   */
  stop(): void {
    if (!this.started) {
      return;
    }
    try {
      this.callService.camera = null;
      this.callService.onSystemEvent = null;
      this.callKit.onAction = null;
      this.videoService.onSourceDowngraded = null;
    } finally {
      this.disposeBag.dispose();
      this.started = false;
    }
  }

  /**
   * Swift `private func subscribeCallEvents()`. Swift hopped onto the main queue here because
   * CallKit reporting and capture teardown are main-thread work; the ArkTS callback already
   * arrives on the ability's thread, so the hop is dropped.
   */
  private subscribeCallEvents(): void {
    this.callService.camera = this;
    this.callService.onSystemEvent = (event: CallSystemEvent): void => {
      this.handle(event);
    };
  }

  /** Swift `private func subscribeCallKitActions()`. */
  private subscribeCallKitActions(): void {
    this.callKit.onAction = (action: CallUiAction): void => {
      this.handleCallKitAction(action);
    };
  }

  /** Swift `private func subscribeCaptureQuality()`. */
  private subscribeCaptureQuality(): void {
    this.videoService.onSourceDowngraded = (sinkId: SinkId, source: string): void => {
      this.reinviteWithDowngradedSource(sinkId, source);
    };
  }

  // MARK: - Call events -> call UI, camera, contacts

  /** Swift `private func handle(_ event: CallSystemEvent)`. */
  private handle(event: CallSystemEvent): void {
    const call: CallState | null = event.call;
    if (call === null) {
      return;
    }
    switch (event.kind) {
      case CallSystemEventKind.CALL_MATCHED:
        this.reportIncoming(call);
        break;
      case CallSystemEventKind.CALL_ADDED:
        this.handleCallAdded(call);
        break;
      case CallSystemEventKind.CALL_UPDATED:
        this.handleCallUpdated(call);
        break;
      case CallSystemEventKind.CALL_ENDED:
        this.handleCallEnded(call);
        break;
      default:
        break;
    }
  }

  /** Swift `case let .callAdded(call)`. */
  private handleCallAdded(call: CallState): void {
    if (call.id.isLocal) {
      // Answered on the call-UI screen: the UI already knows this call, so only the in-call
      // screen is missing.
      this.callToPresent.onNext(call);
    } else if (call.direction === CallDirection.INCOMING) {
      this.reportIncoming(call);
    } else if (!call.joinsExistingCall) {
      this.callKit.reportOutgoingCallStarted(call, this.callHandle(call));
      this.callToPresent.onNext(call);
    }
  }

  /** Swift `case let .callUpdated(call)`. */
  private handleCallUpdated(call: CallState): void {
    this.videoService.setVideoCodec(call.videoCodec, call.id.raw);
    if (call.status.isOngoing) {
      // Swift: past the warm-up, only libjami's StartCapture / StopCapture move the camera.
      this.videoService.setCallOwnsCamera(true);
    }
    if (call.direction !== CallDirection.OUTGOING) {
      // Answered in the app (call screen, banner): the call UI stops ringing it (T-1636).
      if (call.status.kind === CallStatusKind.CURRENT) {
        this.callKit.reportOutgoingCallConnected(call.id);
      }
      return;
    }
    if (call.status.kind === CallStatusKind.RINGING) {
      this.callKit.reportOutgoingCallConnecting(call.id);
    } else if (call.status.kind === CallStatusKind.CURRENT) {
      this.callKit.reportOutgoingCallConnected(call.id);
    }
  }

  /** Swift `case let .callEnded(call, _)`. */
  private handleCallEnded(call: CallState): void {
    if (!this.hasLiveCall()) {
      // No call left to take the capture over - stop a warm-up libjami never claimed (normal
      // ends go through libjami's StopCapture signal as well; stop is idempotent).
      this.videoService.setCallOwnsCamera(false);
      this.videoService.stopPreviewCapture();
      this.videoService.resetCameraPosition();
    }
    const endedLocally: CallStatus = CallStatus.terminated(TerminationReason.ENDED_LOCALLY);
    this.callKit.reportCallEnded(call.id, !call.status.equals(endedLocally));
    this.performBoothModeCleanup(call.accountId);
    this.videoService.restoreDefaultDevice();
  }

  /** Swift `private func reportIncoming(_ call: CallState)`. */
  private reportIncoming(call: CallState): void {
    this.callKit.reportIncomingCall(call, this.callHandle(call),
      (error: BusinessError | null): void => {
        if (error !== null) {
          // The call UI refused to present - refuse the call rather than ring into nothing.
          // (A missing notification permission is not a refusal: the in-app page still rings.)
          this.refuseCall(call.id);
        }
      });
    this.resolveRegisteredName(call);
  }

  /**
   * Swift `private func resolveRegisteredName(for call: CallState)`.
   *
   * The call-UI label is reported from what libjami knew at call setup, which for an unknown
   * peer is the bare hash. A registered name that resolves afterwards replaces it.
   *
   * Swift wrote `.filter { … }.take(1).observe(on: MainScheduler.instance).subscribe(…)`. The
   * ported `PublishSubject` has no operators, so the filter is the guard at the top of the
   * observer and `take(1)` is the unsubscribe on first match; the scheduler hop is not needed
   * (see subscribeCallEvents).
   */
  private resolveRegisteredName(call: CallState): void {
    const account: AccountModel | null = this.accountsService.getAccount(call.accountId);
    if (call.bestName !== call.peerHash || account === null || account.type !== AccountType.RING) {
      return;
    }
    const hash: string = call.peerHash;
    let unsubscribe: (() => void) | null = null;
    let resolved: boolean = false;
    unsubscribe = this.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (resolved || response.state !== LookupNameState.FOUND || response.name.length === 0) {
          return;
        }
        if (response.address !== hash && response.requestedName !== hash) {
          return;
        }
        resolved = true;
        const named: CallState = call.copy();
        named.registeredName = response.name;
        this.callKit.updateDisplayName(call.id, this.callHandle(named), !call.isAudioOnly);
        if (unsubscribe !== null) {
          unsubscribe();
        }
      });
    this.disposeBag.add(unsubscribe);
    this.nameService.lookupAddress(call.accountId, '', hash);
  }

  // MARK: - Call-UI actions -> calls, camera, audio

  /** Swift `private func handleCallKitAction(_ action: CallKitAction)`. */
  private handleCallKitAction(action: CallUiAction): void {
    switch (action.kind) {
      case CallUiActionKind.ANSWER:
        this.performAnswer(action);
        break;
      case CallUiActionKind.ANSWER_PENDING:
        // The decision replays on match; the call it creates presents through `.callAdded` like
        // any other.
        this.performAnswerPending(action);
        break;
      case CallUiActionKind.END:
        this.performEnd(action);
        break;
      case CallUiActionKind.DECLINE_PENDING:
        break;
      case CallUiActionKind.SET_MUTED:
        this.performSetMuted(action);
        break;
      case CallUiActionKind.AUDIO_SESSION_ACTIVATED:
        this.performAudioSessionActivated();
        break;
      case CallUiActionKind.AUDIO_SESSION_DEACTIVATED:
        break;
      default:
        break;
    }
  }

  /** Swift `case let .answer(callId, withVideo)`. */
  private performAnswer(action: CallUiAction): void {
    const callId: CallId | null = action.callId;
    if (callId === null) {
      return;
    }
    this.runAnswer(callId, action.withVideo)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'answering call failed: %{public}s',
          describeError(error));
      });
  }

  private async runAnswer(callId: CallId, withVideo: boolean): Promise<void> {
    await this.callService.accept(callId, withVideo);
    const snapshot: CallSystemState = await this.callService.snapshot();
    const call: CallState | null = snapshot.call(callId);
    if (call !== null) {
      this.callToPresent.onNext(call);
    }
  }

  /** Swift `case let .answerPending(peerId, accountId, hasVideo)`. */
  private performAnswerPending(action: CallUiAction): void {
    this.callService.acceptPendingCall(action.peerId, action.accountId, action.withVideo)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'answering pending call failed: %{public}s',
          describeError(error));
      });
  }

  /** Swift `case let .end(callId)`. */
  private performEnd(action: CallUiAction): void {
    const callId: CallId | null = action.callId;
    if (callId === null) {
      return;
    }
    this.callService.hangUp(callId)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'hanging up failed: %{public}s', describeError(error));
      });
  }

  /** Swift `case let .setMuted(callId, muted)` - a no-op when the call is already in that state. */
  private performSetMuted(action: CallUiAction): void {
    const callId: CallId | null = action.callId;
    if (callId === null) {
      return;
    }
    this.runSetMuted(callId, action.muted)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'muting failed: %{public}s', describeError(error));
      });
  }

  private async runSetMuted(callId: CallId, muted: boolean): Promise<void> {
    const snapshot: CallSystemState = await this.callService.snapshot();
    const call: CallState | null = snapshot.call(callId);
    if (call === null) {
      return;
    }
    let conference: ConferenceState | null = null;
    if (call.conferenceId !== null) {
      const found: ConferenceState | undefined = snapshot.conferences.get(call.conferenceId.raw);
      conference = found === undefined ? null : found;
    }
    if (call.effectiveAudioMuted(conference) === muted) {
      return;
    }
    await this.callService.toggleMute(callId, MediaLabel.DEFAULT_AUDIO);
  }

  /** Swift `case .audioSessionActivated`. */
  private performAudioSessionActivated(): void {
    this.runAudioSessionActivated()
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'applying the audio route failed: %{public}s',
          describeError(error));
      });
  }

  private async runAudioSessionActivated(): Promise<void> {
    const snapshot: CallSystemState = await this.callService.snapshot();
    const call: CallState | null = CallsManager.callToRoute(snapshot);
    const hasVideo: boolean = call === null ? false : (!call.isAudioOnly || call.hasVideo);
    const direction: CallDirection = call === null ? CallDirection.OUTGOING : call.direction;
    this.audioService.callKitActivated(hasVideo, direction);
  }

  /**
   * Swift `snapshot.ongoingCalls.first ?? snapshot.calls.values.first { !$0.status.isTerminal }`
   * - the call whose media decides the route.
   */
  private static callToRoute(snapshot: CallSystemState): CallState | null {
    const ongoing: CallState[] = snapshot.ongoingCalls;
    if (ongoing.length > 0) {
      return ongoing[0];
    }
    const candidates: CallState[] = [];
    snapshot.calls.forEach((candidate: CallState): void => {
      candidates.push(candidate);
    });
    for (const candidate of candidates) {
      if (!candidate.status.isTerminal) {
        return candidate;
      }
    }
    return null;
  }

  // MARK: - Camera (CallCameraCoordinating)

  /** Swift `func currentCameraSource() -> String`. */
  currentCameraSource(): string {
    return this.videoService.videoSource();
  }

  /** Swift `func prepareCameraForOutgoingCall(audioOnly:)`. */
  prepareCameraForOutgoingCall(audioOnly: boolean): void {
    if (audioOnly) {
      return;
    }
    this.videoService.startPreviewCapture();
  }

  /** Swift `func prepareCameraForAnswerWithVideo()`. */
  prepareCameraForAnswerWithVideo(): void {
    this.videoService.startPreviewCapture();
  }

  /** Swift `func cancelCameraPreparation()` - keeps the capture if a call is still live. */
  cancelCameraPreparation(): void {
    if (this.hasLiveCall()) {
      return;
    }
    this.videoService.stopPreviewCapture();
    this.videoService.resetCameraPosition();
  }

  // MARK: - Capture quality

  /**
   * Swift `private func reinviteWithDowngradedSource(sinkId:source:)`. Hardware acceleration
   * only covers H264/H265; the pipeline drops to the medium camera for anything else, and
   * libjami cannot hot-swap the capture device, so a downgraded call has to be re-invited with
   * the new source. A sink id is the call id it renders.
   */
  private reinviteWithDowngradedSource(sinkId: SinkId, source: string): void {
    const callId: CallId = new CallId(sinkId.raw);
    this.callService.updateVideoSource(callId, source)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'updating the video source failed: %{public}s',
          describeError(error));
      });
  }

  // MARK: - Push placeholders

  /** Swift `func stopAllUnhandeledCalls()`. */
  stopAllUnhandeledCalls(): void {
    this.callKit.stopAllPendingCalls();
  }

  /** Swift `func endAllCallsOnTermination()` - ends every reported call before the app goes away. */
  endAllCallsOnTermination(): void {
    this.callKit.endAllCallsOnTermination();
  }

  /** Swift `func hasActiveCalls() -> Bool`. */
  hasActiveCalls(): boolean {
    return this.callKit.hasActiveCalls() || this.callService.hasOngoingCalls;
  }

  // MARK: - Booth mode

  /** Swift `private func performBoothModeCleanup(accountId:)`. */
  private performBoothModeCleanup(accountId: string): void {
    if (!this.accountsService.boothMode()) {
      return;
    }
    this.contactsService.removeAllContacts(accountId);
  }

  // MARK: - Call-UI handles

  /** Swift `callService.stateMirror.calls.contains { !$0.value.status.isTerminal }`. */
  private hasLiveCall(): boolean {
    let live: boolean = false;
    this.callService.stateMirror.calls.forEach((call: CallState): void => {
      if (!call.status.isTerminal) {
        live = true;
      }
    });
    return live;
  }

  /**
   * Swift `private func handle(for call: CallState) -> CallKitHandle` (renamed: ArkTS has no
   * overloading, and `handle` is the event handler above). SIP handles keep foreign hosts;
   * registered names win for Jami accounts.
   */
  private callHandle(call: CallState): CallHandle {
    const account: AccountModel | null = this.accountsService.getAccount(call.accountId);
    if (account === null) {
      return new CallHandle(call.peerHash, call.bestName, false);
    }
    const details: AccountConfigModel | null = account.details;
    const accountHostname: string =
      details === null ? '' : details.getValue(ConfigKey.ACCOUNT_HOSTNAME);
    const localPort: string = details === null ? '' : details.getValue(ConfigKey.LOCAL_PORT);
    const isSip: boolean = account.type === AccountType.SIP;
    const uri: JamiUri = JamiUri.fromInfoHash(isSip ? UriType.SIP : UriType.RING, call.peerUri,
      accountHostname, localPort);
    const parsed: string | null = uri.hash;
    let handleValue: string = parsed === null ? call.peerHash : parsed;
    if (isSip && uri.hostname !== accountHostname) {
      handleValue = uri.userInfo + ':' + uri.hostname;
    }
    // libjami's call details rarely carry the registered name. The contact list has it, but it
    // holds the current account's contacts only; a call to another local account reads the
    // names lookups resolved (T-1636).
    const current: AccountModel | null = this.accountsService.currentAccount;
    const contact: ContactModel | null = current !== null && current.id === call.accountId
      ? this.contactsService.contact(call.peerHash) : null;
    const known: string = contact !== null && contact.userName !== null && contact.userName.length > 0
      ? contact.userName : this.nameService.cachedName(call.peerHash) ?? '';
    const registered: string = call.registeredName !== null && call.registeredName.length > 0
      ? call.registeredName : known;
    let name: string = handleValue;
    if (call.displayName.length > 0) {
      name = call.displayName;
    } else if (registered.length > 0) {
      name = registered;
    }
    const contactHandle: string = (isSip || registered.length === 0) ? handleValue : registered;
    return new CallHandle(contactHandle, name === contactHandle ? '' : name,
      isSip && isPhoneNumber(handleValue));
  }

  /** Swift `Task { await self?.callService.refuse(call.id) }`. */
  private refuseCall(callId: CallId): void {
    this.callService.refuse(callId)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'refusing call failed: %{public}s',
          describeError(error));
      });
  }
}
