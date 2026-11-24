/*
 * Ported from Ring/Ring/Services/Calls/CallService.swift:36-401 and
 * Ring/Ring/Services/Calls/CallStore.swift:41-1196, together with the call-domain helpers
 * that no other module owns: Ring/Ring/Services/Calls/ActiveCallsTracker.swift,
 * MediaNegotiator.swift, CallEventResolver.swift, CallEventSource.swift,
 * LibJamiCallAPI.swift and Ring/Ring/Helpers/EventBroadcaster.swift
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * THE DAEMON GAP. Every call COMMAND (place, accept, refuse, hang up, hold, media
 * renegotiation, conferencing) and every call SIGNAL rides the C++ jami daemon through
 * Ring/Ring/Bridging/CallsAdapter.mm. The daemon is a prebuilt binary
 * (xcframework/libjami-core.xcframework + PJSIP + FFmpeg + codecs) with no source on disk and
 * no HarmonyOS build, so Rule 11 forbids porting it, stubbing it with fake success, or
 * bridging to it through a sidecar/NDK/wasm shim. `DaemonCallClient` below is therefore the
 * honest `LibJamiCallAPI`: every method exists with its real signature and reports
 * `call.<op>` unavailable through `DaemonService`. A screen renders that as an explicit
 * "not available on this platform" notice on the control that asked for it.
 *
 * WHAT IS REAL HERE, and must keep working: the call/conference state machine (`CallStore`),
 * the status-transition rules, `ActiveCallsTracker`, `MediaNegotiator`, the pending-join /
 * pending-swarm / awaiting-match bookkeeping, the expiry timers, the ended-call log and the
 * event fan-out. Those are local logic, not daemon calls, and they are ported in full.
 *
 * SUBSTITUTIONS APPLIED ELSEWHERE, recorded here because this module carries their data:
 *  - CallKit has no HarmonyOS equivalent. `CallState.callKitUUID` is the id of the in-app
 *    incoming-call page / NotificationKit entry that replaces it (`svc_call_ui`). This module
 *    only passes it through - it never talks to a call provider.
 *  - Picture-in-picture is `@ohos.PiPWindow`, never a float window (a self-signed build cannot
 *    obtain SYSTEM_FLOAT_WINDOW). That lives on the call screen, not in the data layer.
 *  - Call keep-alive is KEEP_BACKGROUND_RUNNING + a BackgroundTasksKit continuous task +
 *    AVSession, owned by the ability / `svc_call_ui`; a .ts module has no UIAbilityContext.
 *
 * CONCURRENCY. Swift made `CallStore` an actor and pushed commands onto a DispatchQueue so
 * signals and user intents serialize. ArkTS runs one event loop per ability, so the
 * serialization is free: the store is a plain class and `CommandQueue` only keeps commands
 * off the current tick, which is what the Swift queue bought. `mirrorLock` is likewise
 * unnecessary and is not ported (nothing writes `stateMirror` from another thread here).
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import util from '@ohos.util';
import { BehaviorRelay, PublishSubject } from './Observable';
import { DaemonService, DaemonUnavailableError } from './DaemonService';
import { ServiceRegistry } from './ServiceRegistry';
import { jami, toMap, toRecord } from './JamiNative';
import { VideoService } from './VideoService';
import { StringMap } from 'libjami.so';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { DeviceModel } from '../model/DeviceModel';
import { AccountCallTracker, ActiveCall } from '../model/ActiveCall';
import {
  CallDirection,
  CallId,
  CallState,
  CallSystemState,
  ConferenceLayoutMode,
  ConferenceLifecycle,
  conferenceLifecycleFromLibJami,
  ConferenceState,
  ConfId,
  mediaHasNegotiatedVideo,
  mediaIsVideoMuted,
  PendingConferenceInvite
} from '../model/CallState';
import {
  CallIntent,
  CallStatus,
  CallStatusKind,
  HoldSide,
  LibJamiCallState,
  libJamiCallStateFromRaw,
  TerminationReason
} from '../model/CallStatus';
import { CallDetails, filterOutHost } from '../model/CallDetails';
import { ConferenceParticipantInfo } from '../model/ConferenceParticipantInfo';
import {
  MediaItem,
  MediaLabel,
  mediaItemsFromLibJami,
  mediaItemsToDictionaries,
  MediaType
} from '../model/MediaItem';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CallService';
/** Device-lane diagnostics of the camera/media path (T-1616, T-1626): one tag to filter on. */
const F4_TAG: string = 'JamiF4';

/** `audio_0 video_0(muted)` - a media list as one log field. */
function describeMedia(media: MediaItem[]): string {
  return media.map((m: MediaItem): string => m.label.libJamiString +
    (!m.enabled ? '(disabled)' : m.muted ? '(muted)' : '')).join(' ');
}

/**
 * Swift `VideoScalingPolicy`, the native renderer's values: AUTOMATIC draws the whole frame once
 * the frame and tile aspects differ by more than 1.3 (VideoScaling.shouldShowWholeFrame).
 */
export enum SinkScaling {
  FILL = 0,
  FIT = 1,
  AUTOMATIC = 2
}

/** Swift `MediaNegotiator.mutedCameraSource` - libjami's video-mute sentinel source. */
const MUTED_CAMERA_SOURCE: string = 'mutedCamera';

const SWARM_URI_PREFIX: string = 'swarm:';
const RDV_URI_PREFIX: string = 'rdv:';
const TEXT_PLAIN_MIME: string = 'text/plain';

/** Swift default arguments of `placeSwarmCall` / `acceptPendingCall`, in seconds. */
const SWARM_CALL_TIMEOUT_SECONDS: number = 30;
const LATE_CONFERENCE_RETENTION_SECONDS: number = 30;
const PENDING_CALL_TIMEOUT_SECONDS: number = 15;

/** Swift `EndedCallLog.limit`. */
const ENDED_CALL_LOG_LIMIT: number = 32;

const MILLISECONDS_PER_SECOND: number = 1000;

/** Swift `enum CallType: Int` - the call kind written to conversation history. */
export enum CallType {
  INCOMING = 0,
  OUTGOING = 1,
  MISSED = 2
}

/**
 * Swift `protocol CallCameraCoordinating` - implemented by `CallsManager`, which owns the
 * capture device. The call layer never touches the camera itself.
 */
export interface CallCameraCoordinating {
  currentCameraSource(): string;

  prepareCameraForOutgoingCall(audioOnly: boolean): void;

  prepareCameraForAnswerWithVideo(): void;

  cancelCameraPreparation(): void;
}

/** Swift `MediaNegotiationEvent` (Models/Calls/LibJamiCallConstants.swift) - no other owner. */
export enum MediaNegotiationEvent {
  SUCCESS = 'NEGOTIATION_SUCCESS',
  FAILURE = 'NEGOTIATION_FAIL'
}

/** Swift `MediaNegotiationEvent(rawValue:)`. */
export function mediaNegotiationEventFromRaw(raw: string): MediaNegotiationEvent | null {
  if (raw === 'NEGOTIATION_SUCCESS') {
    return MediaNegotiationEvent.SUCCESS;
  }
  if (raw === 'NEGOTIATION_FAIL') {
    return MediaNegotiationEvent.FAILURE;
  }
  return null;
}

/** Swift `enum CallStoreError: Error, Equatable`. */
export enum CallStoreErrorKind {
  PLACE_CALL_FAILED = 'PLACE_CALL_FAILED',
  CALL_NOT_FOUND = 'CALL_NOT_FOUND',
  NOT_AUTHORIZED = 'NOT_AUTHORIZED',
  SWARM_CALL_TIMED_OUT = 'SWARM_CALL_TIMED_OUT'
}

export class CallStoreError extends Error {
  readonly kind: CallStoreErrorKind;

  constructor(kind: CallStoreErrorKind) {
    super(kind as string);
    this.name = 'CallStoreError';
    this.kind = kind;
  }
}

/* ------------------------------------------------------------------------------------------
 * Events
 * ---------------------------------------------------------------------------------------- */

/** The cases of Swift's `enum CallSystemEvent: Sendable`. */
export enum CallSystemEventKind {
  CALL_ADDED = 'CALL_ADDED',
  CALL_UPDATED = 'CALL_UPDATED',
  CALL_MATCHED = 'CALL_MATCHED',
  CALL_ENDED = 'CALL_ENDED',
  CONFERENCE_UPDATED = 'CONFERENCE_UPDATED',
  CONFERENCE_ENDED = 'CONFERENCE_ENDED',
  INCOMING_MESSAGE = 'INCOMING_MESSAGE',
  ACTIVE_CALLS_CHANGED = 'ACTIVE_CALLS_CHANGED'
}

/**
 * Swift's enum carried associated values per case; ArkTS enums carry none, so this is a value
 * class with a kind plus the payload of that kind. Only the fields the kind names are set.
 */
export class CallSystemEvent {
  readonly kind: CallSystemEventKind;
  /** CALL_ADDED / CALL_UPDATED / CALL_MATCHED / CALL_ENDED. */
  call: CallState | null = null;
  /** CALL_MATCHED - the local placeholder the libjami call replaced. */
  replacedCallId: CallId | null = null;
  /** CALL_ENDED. */
  durationSeconds: number = 0;
  /** CONFERENCE_UPDATED. */
  conference: ConferenceState | null = null;
  /** CONFERENCE_ENDED. */
  conferenceId: ConfId | null = null;
  remainingCallId: CallId | null = null;
  /** INCOMING_MESSAGE. */
  messageCallId: CallId | null = null;
  fromUri: string = '';
  message: Map<string, string> = new Map<string, string>();
  /** ACTIVE_CALLS_CHANGED. */
  trackers: Map<string, AccountCallTracker> = new Map<string, AccountCallTracker>();

  private constructor(kind: CallSystemEventKind) {
    this.kind = kind;
  }

  static callAdded(call: CallState): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CALL_ADDED);
    event.call = call;
    return event;
  }

  static callUpdated(call: CallState): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CALL_UPDATED);
    event.call = call;
    return event;
  }

  static callMatched(replaced: CallId, call: CallState): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CALL_MATCHED);
    event.replacedCallId = replaced;
    event.call = call;
    return event;
  }

  static callEnded(call: CallState, durationSeconds: number): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CALL_ENDED);
    event.call = call;
    event.durationSeconds = durationSeconds;
    return event;
  }

  static conferenceUpdated(conference: ConferenceState): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CONFERENCE_UPDATED);
    event.conference = conference;
    return event;
  }

  static conferenceEnded(confId: ConfId, remainingCallId: CallId | null): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.CONFERENCE_ENDED);
    event.conferenceId = confId;
    event.remainingCallId = remainingCallId;
    return event;
  }

  static incomingMessage(callId: CallId, fromUri: string,
                         message: Map<string, string>): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.INCOMING_MESSAGE);
    event.messageCallId = callId;
    event.fromUri = fromUri;
    event.message = message;
    return event;
  }

  static activeCallsChanged(trackers: Map<string, AccountCallTracker>): CallSystemEvent {
    const event: CallSystemEvent = new CallSystemEvent(CallSystemEventKind.ACTIVE_CALLS_CHANGED);
    event.trackers = trackers;
    return event;
  }
}

/** The cases of Swift's `enum RawCallSignal` / `enum LibJamiCallEvent`. */
export enum LibJamiCallEventKind {
  CALL_STATE_CHANGED = 'CALL_STATE_CHANGED',
  INCOMING_CALL = 'INCOMING_CALL',
  MEDIA_CHANGE_REQUESTED = 'MEDIA_CHANGE_REQUESTED',
  MEDIA_NEGOTIATION_STATUS = 'MEDIA_NEGOTIATION_STATUS',
  INCOMING_MESSAGE = 'INCOMING_MESSAGE',
  PEER_HOLD = 'PEER_HOLD',
  AUDIO_MUTED = 'AUDIO_MUTED',
  VIDEO_MUTED = 'VIDEO_MUTED',
  REMOTE_RECORDING_CHANGED = 'REMOTE_RECORDING_CHANGED',
  CONFERENCE_CREATED = 'CONFERENCE_CREATED',
  CONFERENCE_CHANGED = 'CONFERENCE_CHANGED',
  CONFERENCE_REMOVED = 'CONFERENCE_REMOVED',
  CONFERENCE_INFOS_UPDATED = 'CONFERENCE_INFOS_UPDATED'
}

/**
 * Swift `enum RawCallSignal: Sendable` - a libjami callback exactly as the bridge delivers it,
 * dictionaries and raw strings included. Nothing produces one on HarmonyOS today (the daemon
 * that emits them has no build here); the type is kept so `CallEventSource` has the real shape
 * a future bridge must feed.
 */
export class RawCallSignal {
  readonly kind: LibJamiCallEventKind;
  callId: string = '';
  accountId: string = '';
  conferenceId: string = '';
  conversationId: string = '';
  peerUri: string = '';
  fromUri: string = '';
  /** Raw `CALL_STATE` / conference `STATE` string. */
  state: string = '';
  /** Raw `MediaNegotiationStatus` event string. */
  event: string = '';
  code: number = 0;
  flag: boolean = false;
  mediaDictionaries: Array<Map<string, string>> = [];
  participantDictionaries: Array<Map<string, string>> = [];
  memberCallIds: string[] = [];
  message: Map<string, string> = new Map<string, string>();

  private constructor(kind: LibJamiCallEventKind) {
    this.kind = kind;
  }

  static callStateChanged(callId: string, state: string, accountId: string,
                          code: number): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.CALL_STATE_CHANGED);
    signal.callId = callId;
    signal.state = state;
    signal.accountId = accountId;
    signal.code = code;
    return signal;
  }

  static incomingCall(accountId: string, callId: string, peerUri: string,
                      media: Array<Map<string, string>>): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.INCOMING_CALL);
    signal.accountId = accountId;
    signal.callId = callId;
    signal.peerUri = peerUri;
    signal.mediaDictionaries = media;
    return signal;
  }

  static mediaChangeRequested(accountId: string, callId: string,
                              media: Array<Map<string, string>>): RawCallSignal {
    const signal: RawCallSignal =
      new RawCallSignal(LibJamiCallEventKind.MEDIA_CHANGE_REQUESTED);
    signal.accountId = accountId;
    signal.callId = callId;
    signal.mediaDictionaries = media;
    return signal;
  }

  static mediaNegotiationStatus(callId: string, event: string,
                                media: Array<Map<string, string>>): RawCallSignal {
    const signal: RawCallSignal =
      new RawCallSignal(LibJamiCallEventKind.MEDIA_NEGOTIATION_STATUS);
    signal.callId = callId;
    signal.event = event;
    signal.mediaDictionaries = media;
    return signal;
  }

  static incomingMessage(callId: string, fromUri: string,
                         message: Map<string, string>): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.INCOMING_MESSAGE);
    signal.callId = callId;
    signal.fromUri = fromUri;
    signal.message = message;
    return signal;
  }

  static peerHold(callId: string, hold: boolean): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.PEER_HOLD);
    signal.callId = callId;
    signal.flag = hold;
    return signal;
  }

  static audioMuted(callId: string, muted: boolean): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.AUDIO_MUTED);
    signal.callId = callId;
    signal.flag = muted;
    return signal;
  }

  static videoMuted(callId: string, muted: boolean): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.VIDEO_MUTED);
    signal.callId = callId;
    signal.flag = muted;
    return signal;
  }

  static remoteRecordingChanged(callId: string, recording: boolean): RawCallSignal {
    const signal: RawCallSignal =
      new RawCallSignal(LibJamiCallEventKind.REMOTE_RECORDING_CHANGED);
    signal.callId = callId;
    signal.flag = recording;
    return signal;
  }

  static conferenceCreated(conferenceId: string, conversationId: string,
                           accountId: string): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.CONFERENCE_CREATED);
    signal.conferenceId = conferenceId;
    signal.conversationId = conversationId;
    signal.accountId = accountId;
    return signal;
  }

  static conferenceChanged(conferenceId: string, accountId: string, state: string,
                           memberCallIds: string[]): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.CONFERENCE_CHANGED);
    signal.conferenceId = conferenceId;
    signal.accountId = accountId;
    signal.state = state;
    signal.memberCallIds = memberCallIds;
    return signal;
  }

  static conferenceRemoved(conferenceId: string): RawCallSignal {
    const signal: RawCallSignal = new RawCallSignal(LibJamiCallEventKind.CONFERENCE_REMOVED);
    signal.conferenceId = conferenceId;
    return signal;
  }

  static conferenceInfosUpdated(conferenceId: string,
                                info: Array<Map<string, string>>): RawCallSignal {
    const signal: RawCallSignal =
      new RawCallSignal(LibJamiCallEventKind.CONFERENCE_INFOS_UPDATED);
    signal.conferenceId = conferenceId;
    signal.participantDictionaries = info;
    return signal;
  }
}

/**
 * Swift `enum LibJamiCallEvent: Sendable` - a signal already resolved into everything
 * `CallStore` needs, so the store never reads back from libjami mid-decision.
 */
export class LibJamiCallEvent {
  readonly kind: LibJamiCallEventKind;
  callId: string = '';
  accountId: string = '';
  conferenceId: string = '';
  conversationId: string = '';
  peerUri: string = '';
  fromUri: string = '';
  /** Parsed `CALL_STATE`; null when libjami sent a state this client does not know. */
  state: LibJamiCallState | null = null;
  rawState: string = '';
  /** Conference `STATE`, raw - `ConferenceLifecycle` parses it. */
  lifecycle: string = '';
  negotiationEvent: MediaNegotiationEvent | null = null;
  code: number = 0;
  flag: boolean = false;
  media: MediaItem[] = [];
  /** libjami-confirmed media list; non-empty only when the call reached CURRENT. */
  negotiatedMedia: MediaItem[] = [];
  videoCodec: string | null = null;
  details: CallDetails | null = null;
  participants: ConferenceParticipantInfo[] = [];
  memberCallIds: string[] = [];
  message: Map<string, string> = new Map<string, string>();

  private constructor(kind: LibJamiCallEventKind) {
    this.kind = kind;
  }

  static callStateChanged(callId: string, state: LibJamiCallState | null, rawState: string,
                          accountId: string, code: number, negotiatedMedia: MediaItem[],
                          videoCodec: string | null): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.CALL_STATE_CHANGED);
    event.callId = callId;
    event.state = state;
    event.rawState = rawState;
    event.accountId = accountId;
    event.code = code;
    event.negotiatedMedia = negotiatedMedia;
    event.videoCodec = videoCodec;
    return event;
  }

  static incomingCall(accountId: string, callId: string, peerUri: string, media: MediaItem[],
                      details: CallDetails | null): LibJamiCallEvent {
    const event: LibJamiCallEvent = new LibJamiCallEvent(LibJamiCallEventKind.INCOMING_CALL);
    event.accountId = accountId;
    event.callId = callId;
    event.peerUri = peerUri;
    event.media = media;
    event.details = details;
    return event;
  }

  static mediaChangeRequested(accountId: string, callId: string,
                              media: MediaItem[]): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.MEDIA_CHANGE_REQUESTED);
    event.accountId = accountId;
    event.callId = callId;
    event.media = media;
    return event;
  }

  static mediaNegotiationStatus(callId: string, negotiationEvent: MediaNegotiationEvent | null,
                                media: MediaItem[]): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.MEDIA_NEGOTIATION_STATUS);
    event.callId = callId;
    event.negotiationEvent = negotiationEvent;
    event.media = media;
    return event;
  }

  static incomingMessage(callId: string, fromUri: string,
                         message: Map<string, string>): LibJamiCallEvent {
    const event: LibJamiCallEvent = new LibJamiCallEvent(LibJamiCallEventKind.INCOMING_MESSAGE);
    event.callId = callId;
    event.fromUri = fromUri;
    event.message = message;
    return event;
  }

  static peerHold(callId: string, hold: boolean): LibJamiCallEvent {
    const event: LibJamiCallEvent = new LibJamiCallEvent(LibJamiCallEventKind.PEER_HOLD);
    event.callId = callId;
    event.flag = hold;
    return event;
  }

  static audioMuted(callId: string, muted: boolean): LibJamiCallEvent {
    const event: LibJamiCallEvent = new LibJamiCallEvent(LibJamiCallEventKind.AUDIO_MUTED);
    event.callId = callId;
    event.flag = muted;
    return event;
  }

  static videoMuted(callId: string, muted: boolean): LibJamiCallEvent {
    const event: LibJamiCallEvent = new LibJamiCallEvent(LibJamiCallEventKind.VIDEO_MUTED);
    event.callId = callId;
    event.flag = muted;
    return event;
  }

  static remoteRecordingChanged(callId: string, recording: boolean): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.REMOTE_RECORDING_CHANGED);
    event.callId = callId;
    event.flag = recording;
    return event;
  }

  static conferenceCreated(conferenceId: string, conversationId: string, accountId: string,
                           lifecycle: string, memberCallIds: string[],
                           participants: ConferenceParticipantInfo[],
                           media: MediaItem[]): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.CONFERENCE_CREATED);
    event.conferenceId = conferenceId;
    event.conversationId = conversationId;
    event.accountId = accountId;
    event.lifecycle = lifecycle;
    event.memberCallIds = memberCallIds;
    event.participants = participants;
    event.media = media;
    return event;
  }

  static conferenceChanged(conferenceId: string, accountId: string, lifecycle: string,
                           memberCallIds: string[]): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.CONFERENCE_CHANGED);
    event.conferenceId = conferenceId;
    event.accountId = accountId;
    event.lifecycle = lifecycle;
    event.memberCallIds = memberCallIds;
    return event;
  }

  static conferenceRemoved(conferenceId: string): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.CONFERENCE_REMOVED);
    event.conferenceId = conferenceId;
    return event;
  }

  static conferenceInfosUpdated(conferenceId: string,
                                participants: ConferenceParticipantInfo[]): LibJamiCallEvent {
    const event: LibJamiCallEvent =
      new LibJamiCallEvent(LibJamiCallEventKind.CONFERENCE_INFOS_UPDATED);
    event.conferenceId = conferenceId;
    event.participants = participants;
    return event;
  }
}

/**
 * Swift `final class EventBroadcaster<Event>` - multicast fan-out. Swift needed it because
 * `AsyncStream` is single-consumer and `send` crossed threads; here it stays because the
 * replay-then-subscribe atomicity is the part `CallStore.events(for:)` depends on. A
 * subscription is the unsubscribe closure, matching `common/Observable.ts`.
 */
export class EventBroadcaster<E> {
  private subscribers: Map<string, (event: E) => void> = new Map<string, (event: E) => void>();

  /** Swift `func subscribe() -> AsyncStream<Event>`. */
  subscribe(observer: (event: E) => void): () => void {
    return this.subscribeFiltered([], (): boolean => true, observer);
  }

  /**
   * Swift `func subscribe(replaying:where:)` - registers BEFORE replaying, so a caller gets
   * current state and then live deltas with no observation gap.
   */
  subscribeFiltered(replaying: E[], isIncluded: (event: E) => boolean,
                    observer: (event: E) => void): () => void {
    const id: string = util.generateRandomUUID(true);
    this.subscribers.set(id, (event: E): void => {
      if (isIncluded(event)) {
        observer(event);
      }
    });
    for (const event of replaying) {
      if (isIncluded(event)) {
        observer(event);
      }
    }
    return (): void => {
      this.subscribers.delete(id);
    };
  }

  send(event: E): void {
    const current: Array<(event: E) => void> = [];
    this.subscribers.forEach((subscriber: (event: E) => void): void => {
      current.push(subscriber);
    });
    for (const subscriber of current) {
      subscriber(event);
    }
  }
}

/* ------------------------------------------------------------------------------------------
 * libjami surface - THE DAEMON GAP
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `protocol LibJamiCallAPI` - the calls and conference operations libjami exposes to
 * `CallStore`. Kept verbatim in shape so the store's logic is the ported logic and the gap is
 * confined to the one implementation below.
 */
export interface LibJamiCallAPI {
  /** False when no daemon backs this client, so a caller can surface the gap immediately. */
  readonly isOperational: boolean;

  placeCall(accountId: string, participantId: string, media: MediaItem[]): string | null;

  accept(callId: string, accountId: string, media: MediaItem[]): boolean;

  refuse(callId: string, accountId: string): boolean;

  hangUp(callId: string, accountId: string): boolean;

  hold(callId: string, accountId: string): boolean;

  resume(callId: string, accountId: string): boolean;

  playDTMF(code: string): void;

  requestMediaChange(callId: string, accountId: string, media: MediaItem[]): boolean;

  answerMediaChangeRequest(callId: string, accountId: string, media: MediaItem[]): void;

  currentMedia(callId: string, accountId: string): MediaItem[];

  callDetails(callId: string, accountId: string): CallDetails | null;

  callList(accountId: string): string[];

  activeCalls(conversationId: string, accountId: string): Array<Map<string, string>>;

  sendInCallMessage(callId: string, accountId: string, message: Map<string, string>,
                    jamiId: string, isMixed: boolean): void;

  joinConference(conferenceId: string, callId: string, accountId: string,
                 account2Id: string): boolean;

  joinConferences(first: string, second: string, accountId: string,
                  account2Id: string): boolean;

  joinCalls(first: string, second: string, accountId: string, account2Id: string): boolean;

  conferenceInfos(conferenceId: string, accountId: string): ConferenceParticipantInfo[];

  conferenceDetails(conferenceId: string, accountId: string): Map<string, string>;

  conferenceCalls(conferenceId: string, accountId: string): string[];

  hangUpConference(conferenceId: string, accountId: string): boolean;

  holdConference(conferenceId: string, accountId: string): boolean;

  resumeConference(conferenceId: string, accountId: string): boolean;

  setActiveParticipant(participantId: string, conferenceId: string, accountId: string): void;

  setConferenceLayout(layout: number, conferenceId: string, accountId: string): void;

  setModerator(participantId: string, conferenceId: string, accountId: string,
               active: boolean): void;

  hangUpParticipant(participantId: string, conferenceId: string, accountId: string,
                    deviceId: string): void;

  muteStream(participantId: string, conferenceId: string, accountId: string, deviceId: string,
             streamId: string, muted: boolean): void;

  raiseHand(participantId: string, conferenceId: string, accountId: string, deviceId: string,
            raised: boolean): void;
}

/**
 * Swift `final class LibJamiCallClient` forwarded to `CallsAdapter`, which calls the C++
 * daemon. GAP - NOT A PORT: the daemon has no source on disk and no HarmonyOS build.
 *
 * Every method keeps its real signature and reports the capability unavailable. Two report
 * levels, per the daemon-gap convention:
 *   - `reportUnavailable('call.<op>')` for an operation the USER asked for (place, accept,
 *     hang up, mute, conference control) - it reaches the app-wide notice channel;
 *   - `unavailable('call.<op>')` for the read-back paths the store polls (media, details,
 *     active calls, conference infos), which would otherwise drown the user-visible notices.
 */
export class DaemonCallClient implements LibJamiCallAPI {
  // One-to-one calls go to libjami through the NAPI binding; conference control is still a gap.
  readonly isOperational: boolean = true;

  private static records(media: MediaItem[]): StringMap[] {
    return mediaItemsToDictionaries(media).map((dict: Map<string, string>) => toRecord(dict));
  }

  /** Read inside methods only - the registry must not be touched during module evaluation. */
  private get daemon(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /** Swift `rejectsLocal(_:)` - a locally-minted id addresses a call libjami never reported. */
  private rejectsLocal(callId: string): boolean {
    return new CallId(callId).isLocal;
  }

  placeCall(accountId: string, participantId: string, media: MediaItem[]): string | null {
    const callId: string = jami.placeCallWithMedia(accountId, participantId, DaemonCallClient.records(media));
    return callId.length > 0 ? callId : null;
  }

  accept(callId: string, accountId: string, media: MediaItem[]): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.acceptWithMedia(accountId, callId, DaemonCallClient.records(media));
  }

  refuse(callId: string, accountId: string): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.refuse(accountId, callId);
  }

  hangUp(callId: string, accountId: string): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.hangUp(accountId, callId);
  }

  hold(callId: string, accountId: string): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.hold(accountId, callId);
  }

  resume(callId: string, accountId: string): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.resume(accountId, callId);
  }

  playDTMF(code: string): void {
    jami.playDTMF(code);
  }

  requestMediaChange(callId: string, accountId: string, media: MediaItem[]): boolean {
    if (this.rejectsLocal(callId)) {
      return false;
    }
    return jami.requestMediaChange(accountId, callId, DaemonCallClient.records(media));
  }

  answerMediaChangeRequest(callId: string, accountId: string, media: MediaItem[]): void {
    if (this.rejectsLocal(callId)) {
      return;
    }
    jami.answerMediaChangeRequest(accountId, callId, DaemonCallClient.records(media));
  }

  currentMedia(callId: string, accountId: string): MediaItem[] {
    return mediaItemsFromLibJami(jami.currentMediaList(accountId, callId).map((m: StringMap) => toMap(m)));
  }

  callDetails(callId: string, accountId: string): CallDetails | null {
    const details: Map<string, string> = toMap(jami.getCallDetails(accountId, callId));
    return details.size === 0 ? null : CallDetails.fromDict(details);
  }

  callList(accountId: string): string[] {
    return jami.getCallList(accountId);
  }

  activeCalls(conversationId: string, accountId: string): Array<Map<string, string>> {
    return jami.getActiveCalls(accountId, conversationId).map((m: StringMap) => toMap(m));
  }

  sendInCallMessage(callId: string, accountId: string, message: Map<string, string>,
                    jamiId: string, isMixed: boolean): void {
    jami.sendCallTextMessage(accountId, callId, toRecord(message), jamiId, isMixed);
  }

  joinConference(conferenceId: string, callId: string, accountId: string,
                 account2Id: string): boolean {
    return jami.addParticipant(accountId, callId, account2Id, conferenceId);
  }

  joinConferences(first: string, second: string, accountId: string,
                  account2Id: string): boolean {
    return jami.joinConference(accountId, first, account2Id, second);
  }

  joinCalls(first: string, second: string, accountId: string, account2Id: string): boolean {
    return jami.joinParticipant(accountId, first, account2Id, second);
  }

  conferenceInfos(conferenceId: string, accountId: string): ConferenceParticipantInfo[] {
    const infos: ConferenceParticipantInfo[] = [];
    for (const raw of jami.getConferenceInfos(accountId, conferenceId)) {
      const info: ConferenceParticipantInfo | null = ConferenceParticipantInfo.fromDict(toMap(raw));
      if (info !== null) {
        infos.push(info);
      }
    }
    return infos;
  }

  conferenceDetails(conferenceId: string, accountId: string): Map<string, string> {
    return toMap(jami.getConferenceDetails(accountId, conferenceId));
  }

  conferenceCalls(conferenceId: string, accountId: string): string[] {
    return jami.getParticipantList(accountId, conferenceId);
  }

  hangUpConference(conferenceId: string, accountId: string): boolean {
    return jami.hangUpConference(accountId, conferenceId);
  }

  holdConference(conferenceId: string, accountId: string): boolean {
    return jami.holdConference(accountId, conferenceId);
  }

  resumeConference(conferenceId: string, accountId: string): boolean {
    return jami.resumeConference(accountId, conferenceId);
  }

  setActiveParticipant(participantId: string, conferenceId: string, accountId: string): void {
    jami.setActiveParticipant(accountId, conferenceId, participantId);
  }

  setConferenceLayout(layout: number, conferenceId: string, accountId: string): void {
    jami.setConferenceLayout(accountId, conferenceId, layout);
  }

  setModerator(participantId: string, conferenceId: string, accountId: string,
               active: boolean): void {
    jami.setModerator(accountId, conferenceId, participantId, active);
  }

  hangUpParticipant(participantId: string, conferenceId: string, accountId: string,
                    deviceId: string): void {
    jami.hangupParticipant(accountId, conferenceId, participantId, deviceId);
  }

  muteStream(participantId: string, conferenceId: string, accountId: string, deviceId: string,
             streamId: string, muted: boolean): void {
    jami.muteStream(accountId, conferenceId, participantId, deviceId, streamId, muted);
  }

  raiseHand(participantId: string, conferenceId: string, accountId: string, deviceId: string,
            raised: boolean): void {
    jami.raiseHand(accountId, conferenceId, participantId, deviceId, raised);
  }
}

/**
 * Swift `final class CallEventResolver` - turns a raw libjami signal into an event the store
 * can apply without reading back from libjami. Real logic, ported as-is; it simply resolves
 * against a client that reports unavailable while the daemon is absent.
 */
export class CallEventResolver {
  private readonly api: LibJamiCallAPI;
  /** Swift `AsyncStream.Continuation` - the sink the resolved events go to. */
  private continuation: ((event: LibJamiCallEvent) => void) | null = null;

  constructor(api: LibJamiCallAPI) {
    this.api = api;
  }

  /** Swift `let events: AsyncStream<LibJamiCallEvent>` - one consumer, the store. */
  get events(): (observer: (event: LibJamiCallEvent) => void) => void {
    return (observer: (event: LibJamiCallEvent) => void): void => {
      this.continuation = observer;
    };
  }

  /**
   * Swift `func handle(_ signal:)` - called on a libjami thread and handed off at once. The
   * hand-off here is a microtask: ArkTS is single-threaded, so the point is only to leave the
   * caller's tick, which is what Swift's queue hop bought.
   */
  handle(signal: RawCallSignal): void {
    Promise.resolve().then((): void => {
      const sink: ((event: LibJamiCallEvent) => void) | null = this.continuation;
      if (sink !== null) {
        sink(this.resolve(signal));
      }
    });
  }

  private resolve(signal: RawCallSignal): LibJamiCallEvent {
    switch (signal.kind) {
      case LibJamiCallEventKind.CALL_STATE_CHANGED: {
        const parsed: LibJamiCallState | null = libJamiCallStateFromRaw(signal.state);
        // Only a call that just reached `current` has a negotiated list worth reading; every
        // other state would return the stale one.
        const isCurrent: boolean = parsed === LibJamiCallState.CURRENT;
        const negotiated: MediaItem[] = isCurrent
          ? this.api.currentMedia(signal.callId, signal.accountId) : [];
        const details: CallDetails | null = isCurrent
          ? this.api.callDetails(signal.callId, signal.accountId) : null;
        return LibJamiCallEvent.callStateChanged(signal.callId, parsed, signal.state,
          signal.accountId, signal.code, negotiated,
          details === null ? null : details.videoCodec);
      }
      case LibJamiCallEventKind.INCOMING_CALL:
        return LibJamiCallEvent.incomingCall(signal.accountId, signal.callId, signal.peerUri,
          mediaItemsFromLibJami(signal.mediaDictionaries),
          this.api.callDetails(signal.callId, signal.accountId));
      case LibJamiCallEventKind.CONFERENCE_CREATED: {
        const details: Map<string, string> =
          this.api.conferenceDetails(signal.conferenceId, signal.accountId);
        return LibJamiCallEvent.conferenceCreated(signal.conferenceId, signal.conversationId,
          signal.accountId, details.get('STATE') ?? '',
          this.api.conferenceCalls(signal.conferenceId, signal.accountId),
          this.api.conferenceInfos(signal.conferenceId, signal.accountId),
          this.api.currentMedia(signal.conferenceId, signal.accountId));
      }
      case LibJamiCallEventKind.CONFERENCE_CHANGED:
        return LibJamiCallEvent.conferenceChanged(signal.conferenceId, signal.accountId,
          signal.state, signal.memberCallIds);
      case LibJamiCallEventKind.MEDIA_CHANGE_REQUESTED:
        return LibJamiCallEvent.mediaChangeRequested(signal.accountId, signal.callId,
          mediaItemsFromLibJami(signal.mediaDictionaries));
      case LibJamiCallEventKind.MEDIA_NEGOTIATION_STATUS:
        return LibJamiCallEvent.mediaNegotiationStatus(signal.callId,
          mediaNegotiationEventFromRaw(signal.event),
          mediaItemsFromLibJami(signal.mediaDictionaries));
      case LibJamiCallEventKind.CONFERENCE_INFOS_UPDATED: {
        const participants: ConferenceParticipantInfo[] = [];
        for (const dict of signal.participantDictionaries) {
          const info: ConferenceParticipantInfo | null =
            ConferenceParticipantInfo.fromDict(dict);
          if (info !== null) {
            participants.push(info);
          }
        }
        return LibJamiCallEvent.conferenceInfosUpdated(signal.conferenceId, participants);
      }
      case LibJamiCallEventKind.INCOMING_MESSAGE:
        return LibJamiCallEvent.incomingMessage(signal.callId, signal.fromUri, signal.message);
      case LibJamiCallEventKind.PEER_HOLD:
        return LibJamiCallEvent.peerHold(signal.callId, signal.flag);
      case LibJamiCallEventKind.AUDIO_MUTED:
        return LibJamiCallEvent.audioMuted(signal.callId, signal.flag);
      case LibJamiCallEventKind.VIDEO_MUTED:
        return LibJamiCallEvent.videoMuted(signal.callId, signal.flag);
      case LibJamiCallEventKind.REMOTE_RECORDING_CHANGED:
        return LibJamiCallEvent.remoteRecordingChanged(signal.callId, signal.flag);
      default:
        return LibJamiCallEvent.conferenceRemoved(signal.conferenceId);
    }
  }
}

/**
 * Swift `final class CallEventSource` - the `CallsAdapterDelegate` that receives libjami's
 * callbacks and forwards them as `RawCallSignal`s.
 *
 * GAP: `attachToAdapter()` has nothing to attach to - `CallsAdapter` is the Objective-C++
 * bridge into the absent daemon. The delegate methods are kept with their real shapes so a
 * bridge, if one ever exists, feeds this object and everything downstream already works.
 */
export class CallEventSource {
  private readonly onSignal: (signal: RawCallSignal) => void;

  constructor(onSignal: (signal: RawCallSignal) => void) {
    this.onSignal = onSignal;
  }

  /** Swift `func attachToAdapter()`. The NAPI binding (JamiNative) calls the handlers below. */
  attachToAdapter(): void {
  }

  didChangeCallState(callId: string, state: string, accountId: string, stateCode: number): void {
    this.onSignal(RawCallSignal.callStateChanged(callId, state, accountId, stateCode));
  }

  receivingCall(accountId: string, callId: string, uri: string,
                media: Array<Map<string, string>>): void {
    this.onSignal(RawCallSignal.incomingCall(accountId, callId, uri, media));
  }

  didReceiveMediaChangeRequest(accountId: string, callId: string,
                               media: Array<Map<string, string>>): void {
    this.onSignal(RawCallSignal.mediaChangeRequested(accountId, callId, media));
  }

  didChangeMediaNegotiationStatus(callId: string, event: string,
                                  media: Array<Map<string, string>>): void {
    this.onSignal(RawCallSignal.mediaNegotiationStatus(callId, event, media));
  }

  didReceiveMessage(callId: string, uri: string, message: Map<string, string>): void {
    this.onSignal(RawCallSignal.incomingMessage(callId, uri, message));
  }

  callPlacedOnHold(callId: string, hold: boolean): void {
    this.onSignal(RawCallSignal.peerHold(callId, hold));
  }

  audioMuted(callId: string, mute: boolean): void {
    this.onSignal(RawCallSignal.audioMuted(callId, mute));
  }

  videoMuted(callId: string, mute: boolean): void {
    this.onSignal(RawCallSignal.videoMuted(callId, mute));
  }

  remoteRecordingChanged(callId: string, record: boolean): void {
    this.onSignal(RawCallSignal.remoteRecordingChanged(callId, record));
  }

  conferenceCreated(conferenceId: string, conversationId: string, accountId: string): void {
    this.onSignal(RawCallSignal.conferenceCreated(conferenceId, conversationId, accountId));
  }

  conferenceChanged(conferenceId: string, accountId: string, state: string,
                    memberCallIds: string[]): void {
    this.onSignal(RawCallSignal.conferenceChanged(conferenceId, accountId, state,
      memberCallIds));
  }

  conferenceRemoved(conferenceId: string): void {
    this.onSignal(RawCallSignal.conferenceRemoved(conferenceId));
  }

  conferenceInfoUpdated(conferenceId: string, info: Array<Map<string, string>>): void {
    this.onSignal(RawCallSignal.conferenceInfosUpdated(conferenceId, info));
  }
}

/* ------------------------------------------------------------------------------------------
 * Pure local logic - media negotiation and active-call tracking
 * ---------------------------------------------------------------------------------------- */

/** Swift `MediaItem` is a value type; ArkTS classes are references, so copy explicitly. */
function copyMediaItem(item: MediaItem): MediaItem {
  return new MediaItem(item.type, item.label, item.enabled, item.muted, item.source,
    item.onHold);
}

function copyMediaList(items: MediaItem[]): MediaItem[] {
  const copy: MediaItem[] = [];
  for (const item of items) {
    copy.push(copyMediaItem(item));
  }
  return copy;
}

/** Swift `!=` on `[MediaItem]` - element-wise, order significant. */
export function mediaListsEqual(left: MediaItem[], right: MediaItem[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index: number = 0; index < left.length; index++) {
    if (!left[index].equals(right[index])) {
      return false;
    }
  }
  return true;
}

/**
 * Swift `enum MediaNegotiator` - pure media-list construction. Two libjami contracts live
 * here: the answer to a media-change request mirrors the request's size and order, and video
 * mute is signalled by swapping the source between the camera URI and the "mutedCamera"
 * sentinel. Entirely local; no daemon call.
 */
export class MediaNegotiator {
  static readonly MUTED_CAMERA_SOURCE: string = MUTED_CAMERA_SOURCE;

  static answer(requested: MediaItem[], current: MediaItem[]): MediaItem[] {
    const result: MediaItem[] = [];
    for (const request of requested) {
      const answer: MediaItem = copyMediaItem(request);
      let existing: MediaItem | null = null;
      for (const item of current) {
        if (existing === null && item.label.equals(request.label)
          && item.type === request.type) {
          existing = item;
        }
      }
      if (existing !== null) {
        answer.muted = existing.muted;
        answer.enabled = existing.enabled;
      } else {
        answer.muted = request.type === MediaType.VIDEO;
        answer.enabled = true;
      }
      result.push(answer);
    }
    return result;
  }

  /**
   * Swift `togglingMute(in:label:cameraSource:)` - the media list for a re-invite that toggles
   * `label`'s mute state. Toggling a missing default video stream appends one (audio to video
   * upgrade); a missing audio label is a no-op, and the caller sends nothing when the list is
   * unchanged.
   */
  static togglingMute(media: MediaItem[], label: MediaLabel,
                      cameraSource: string): MediaItem[] {
    const result: MediaItem[] = copyMediaList(media);
    for (let index: number = 0; index < result.length; index++) {
      if (result[index].label.equals(label)) {
        const wasMuted: boolean = result[index].muted;
        result[index].enabled = true;
        result[index].muted = !wasMuted;
        if (result[index].type === MediaType.VIDEO) {
          result[index].source = wasMuted ? cameraSource : MUTED_CAMERA_SOURCE;
        }
        return result;
      }
    }
    if (label.equals(MediaLabel.DEFAULT_VIDEO)) {
      result.push(new MediaItem(MediaType.VIDEO, label, true, false, cameraSource, false));
    }
    return result;
  }

  /** Swift `defaultMediaList(audioOnly:videoSource:)` - placing/accepting a regular call. */
  static defaultMediaList(audioOnly: boolean, videoSource: string): MediaItem[] {
    const list: MediaItem[] = [MediaItem.audio()];
    if (!audioOnly) {
      list.push(new MediaItem(MediaType.VIDEO, MediaLabel.DEFAULT_VIDEO, true, false,
        videoSource, false));
    }
    return list;
  }

  /**
   * Swift `completeMediaList(videoMuted:videoSource:)` - swarm/rendezvous calls are always
   * audio+video, with video muted (and an empty source) when joining audio-only.
   */
  static completeMediaList(videoMuted: boolean, videoSource: string): MediaItem[] {
    return [
      MediaItem.audio(),
      new MediaItem(MediaType.VIDEO, MediaLabel.DEFAULT_VIDEO, true, videoMuted,
        videoMuted ? '' : videoSource, false)
    ];
  }
}

/** Swift `ActiveCallsTracker.AccountRef` - the account fields the tracker needs, decoupled. */
export class AccountRef {
  readonly id: string;
  readonly jamiId: string;
  readonly currentDeviceId: string;

  constructor(id: string, jamiId: string, currentDeviceId: string) {
    this.id = id;
    this.jamiId = jamiId;
    this.currentDeviceId = currentDeviceId;
  }
}

/**
 * Swift `struct ActiveCallsTracker` - ongoing swarm calls per account, including which the
 * user ignored or accepted. Ignore/accept propagate to sibling accounts sharing the
 * conversation so popups do not resurface. Entirely local bookkeeping over what the daemon
 * last reported.
 */
export class ActiveCallsTracker {
  private tracked: Map<string, AccountCallTracker> = new Map<string, AccountCallTracker>();

  get trackers(): Map<string, AccountCallTracker> {
    return this.tracked;
  }

  updateActiveCalls(conversationId: string, calls: Array<Map<string, string>>,
                    account: AccountRef): void {
    const parsed: ActiveCall[] = [];
    for (const dict of calls) {
      const id: string | undefined = dict.get('id');
      const uri: string | undefined = dict.get('uri');
      const device: string | undefined = dict.get('device');
      if (id === undefined || uri === undefined || device === undefined) {
        continue;
      }
      const isLocal: boolean = uri === account.jamiId && device === account.currentDeviceId;
      parsed.push(new ActiveCall(id, uri, device, conversationId, account.id, isLocal));
    }
    const tracker: AccountCallTracker =
      this.tracked.get(account.id) ?? new AccountCallTracker();
    tracker.setCalls(conversationId, parsed);
    this.tracked.set(account.id, tracker);
  }

  /**
   * Swift `mutating func ignoreCall(_:)` - ignores on the origin account first (its tracker
   * may be missing), then propagates to siblings holding the same remote call.
   */
  ignoreCall(call: ActiveCall): void {
    const originTracker: AccountCallTracker =
      this.tracked.get(call.accountId) ?? new AccountCallTracker();
    originTracker.ignoreCall(call);
    this.tracked.set(call.accountId, originTracker);

    this.applyToSiblings(call, (tracker: AccountCallTracker, ownCall: ActiveCall): void => {
      tracker.ignoreCall(ownCall);
    });
  }

  acceptCall(uri: string): void {
    const parsed: ActiveCall | null = ActiveCall.fromRaw(uri);
    if (parsed === null) {
      return;
    }
    this.applyToAllTrackersHolding(parsed,
      (tracker: AccountCallTracker, ownCall: ActiveCall): void => {
        tracker.acceptCall(ownCall);
      });
  }

  activeCallHungUp(uri: string): void {
    const parsed: ActiveCall | null = ActiveCall.fromRaw(uri);
    if (parsed === null) {
      return;
    }
    this.applyToAllTrackersHolding(parsed,
      (tracker: AccountCallTracker, ownCall: ActiveCall): void => {
        tracker.removeAcceptedCall(ownCall);
      });
  }

  activeCall(conversationId: string, accountId: string): ActiveCall | null {
    const tracker: AccountCallTracker | undefined = this.tracked.get(accountId);
    if (tracker === undefined) {
      return null;
    }
    const calls: ActiveCall[] = tracker.callsFor(conversationId);
    return calls.length === 0 ? null : calls[0];
  }

  hasRemoteActiveCalls(): boolean {
    for (const tracker of this.allTrackers()) {
      for (const conversationId of tracker.allConversationIds) {
        for (const call of tracker.notIgnoredCalls(conversationId)) {
          if (!call.isFromLocalDevice) {
            return true;
          }
        }
      }
    }
    return false;
  }

  hasUnansweredRemoteCalls(): boolean {
    for (const tracker of this.allTrackers()) {
      if (tracker.incomingNotAcceptedNotIgnoredCalls().length > 0) {
        return true;
      }
    }
    return false;
  }

  private allTrackers(): AccountCallTracker[] {
    const all: AccountCallTracker[] = [];
    this.tracked.forEach((tracker: AccountCallTracker): void => {
      all.push(tracker);
    });
    return all;
  }

  private applyToSiblings(call: ActiveCall,
                          operation: (tracker: AccountCallTracker,
                                      ownCall: ActiveCall) => void): void {
    this.tracked.forEach((tracker: AccountCallTracker, accountId: string): void => {
      if (accountId === call.accountId) {
        return;
      }
      const match: ActiveCall | null = ActiveCallsTracker.matching(tracker, call);
      if (match !== null) {
        operation(tracker, match);
        this.tracked.set(accountId, tracker);
      }
    });
  }

  private applyToAllTrackersHolding(call: ActiveCall,
                                    operation: (tracker: AccountCallTracker,
                                                ownCall: ActiveCall) => void): void {
    this.tracked.forEach((tracker: AccountCallTracker, accountId: string): void => {
      const match: ActiveCall | null = ActiveCallsTracker.matching(tracker, call);
      if (match !== null) {
        operation(tracker, match);
        this.tracked.set(accountId, tracker);
      }
    });
  }

  private static matching(tracker: AccountCallTracker, call: ActiveCall): ActiveCall | null {
    for (const own of tracker.callsFor(call.conversationId)) {
      if (own.remoteIdentity.equals(call.remoteIdentity)) {
        return own;
      }
    }
    return null;
  }
}

/** Swift `struct EndedCall: Sendable`. */
export class EndedCall {
  readonly call: CallState;
  readonly durationSeconds: number;

  constructor(call: CallState, durationSeconds: number) {
    this.call = call;
    this.durationSeconds = durationSeconds;
  }
}

/**
 * Swift `struct EndedCallLog` - the last 32 ended calls, so a screen opened just after a call
 * ended can still replay its ending instead of dismissing blank.
 */
export class EndedCallLog {
  static readonly LIMIT: number = ENDED_CALL_LOG_LIMIT;

  private calls: Map<string, EndedCall> = new Map<string, EndedCall>();
  private order: string[] = [];

  /** Swift `subscript(id:)`. */
  get(id: CallId): EndedCall | null {
    return this.calls.get(id.raw) ?? null;
  }

  record(call: CallState, durationSeconds: number): void {
    if (!this.calls.has(call.id.raw)) {
      this.order.push(call.id.raw);
    }
    this.calls.set(call.id.raw, new EndedCall(call, durationSeconds));
    while (this.order.length > EndedCallLog.LIMIT) {
      const oldest: string = this.order[0];
      this.order.splice(0, 1);
      this.calls.delete(oldest);
    }
  }

  forget(id: CallId): void {
    if (!this.calls.delete(id.raw)) {
      return;
    }
    const index: number = this.order.indexOf(id.raw);
    if (index >= 0) {
      this.order.splice(index, 1);
    }
  }
}

/* ------------------------------------------------------------------------------------------
 * Pending bookkeeping
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `struct PendingCallKey: Hashable` - account + peer hash, the key a locally-created
 * call waits under for the libjami call that replaces it. ArkTS Maps key objects by reference,
 * so the class also vends its own map key.
 */
export class PendingCallKey {
  readonly accountId: string;
  readonly peerHash: string;

  constructor(accountId: string, peerHash: string) {
    this.accountId = accountId;
    this.peerHash = peerHash;
  }

  get mapKey(): string {
    return this.accountId + '|' + this.peerHash;
  }
}

/** Swift `private struct PendingSwarmCallKey: Hashable, Sendable`. */
export class PendingSwarmCallKey {
  readonly accountId: string;
  readonly conversationId: string;

  constructor(accountId: string, conversationId: string) {
    this.accountId = accountId;
    this.conversationId = conversationId;
  }

  get mapKey(): string {
    return this.accountId + '|' + this.conversationId;
  }
}

/**
 * Swift's `CheckedContinuation<ConfId, Error>`. A Promise's resolvers, plus the
 * resume-once guard `CheckedContinuation` gave for free.
 */
class SwarmCallContinuation {
  private readonly onResolve: (confId: ConfId) => void;
  private readonly onReject: (error: Error) => void;
  private finished: boolean = false;

  constructor(onResolve: (confId: ConfId) => void, onReject: (error: Error) => void) {
    this.onResolve = onResolve;
    this.onReject = onReject;
  }

  resume(confId: ConfId): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.onResolve(confId);
  }

  resumeThrowing(error: Error): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.onReject(error);
  }
}

/**
 * Swift `private struct PendingSwarmCall` - a swarm placement waiting for its
 * ConferenceCreated. Hosting a new swarm intentionally returns no call id, so the request
 * metadata has to survive for a bounded interval while the conference signal may still supply
 * the session id.
 */
export class PendingSwarmCall {
  readonly requestId: string;
  continuation: SwarmCallContinuation | null;
  readonly accountId: string;
  readonly media: MediaItem[];
  readonly isAudioOnly: boolean;
  readonly lateConferenceRetention: number;
  callId: CallId | null = null;

  constructor(requestId: string, continuation: SwarmCallContinuation | null, accountId: string,
              media: MediaItem[], isAudioOnly: boolean, lateConferenceRetention: number) {
    this.requestId = requestId;
    this.continuation = continuation;
    this.accountId = accountId;
    this.media = media;
    this.isAudioOnly = isAudioOnly;
    this.lateConferenceRetention = lateConferenceRetention;
  }
}

/**
 * Swift `private let commandQueue: DispatchQueue` - commands are sent OFF the store so a
 * libjami call cannot re-enter it. ArkTS has one event loop, so a microtask hop gives the same
 * guarantee without a thread.
 */
export class CommandQueue {
  readonly label: string;

  constructor(label: string) {
    this.label = label;
  }

  /** Swift `commandQueue.async { ... }`. */
  enqueue(command: () => void): void {
    Promise.resolve().then(command);
  }
}

/* ------------------------------------------------------------------------------------------
 * CallStore - the single source of truth for calls and conferences
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `actor CallStore`. Signals and user intents are both methods on it, so they serialize
 * against each other; on ArkTS the event loop does that, which is why nothing here is async
 * except the two intents that genuinely wait (`placeSwarmCall`, the expiry timers).
 */
export class CallStore {
  private readonly callAPI: LibJamiCallAPI;
  /**
   * Swift comment: `placeCall` is the sole intent that calls `callAPI` directly; every other
   * command is sent off the store through this queue.
   */
  private readonly commandQueue: CommandQueue;
  /** Swift `private let callEvents: AsyncStream<LibJamiCallEvent>` - the resolver's output. */
  private readonly callEvents: (observer: (event: LibJamiCallEvent) => void) => void;
  private readonly broadcaster: EventBroadcaster<CallSystemEvent> =
    new EventBroadcaster<CallSystemEvent>();

  private state: CallSystemState = new CallSystemState();
  private activeCallsTracker: ActiveCallsTracker = new ActiveCallsTracker();
  private endedCalls: EndedCallLog = new EndedCallLog();

  /** Sub-call to host call: joins deferred until the sub-call is current. */
  private pendingJoins: Map<string, CallId> = new Map<string, CallId>();
  private pendingSwarmCalls: Map<string, PendingSwarmCall> =
    new Map<string, PendingSwarmCall>();
  /** Locally-created calls waiting for the libjami call that replaces them. */
  private awaitingMatch: Map<string, CallId> = new Map<string, CallId>();
  private pendingConferenceParticipants: Map<string, ConferenceParticipantInfo[]> =
    new Map<string, ConferenceParticipantInfo[]>();

  /** Swift `private var consumerTask: Task<Void, Never>?` - null until `start()`. */
  private consumerTask: boolean = false;

  constructor(callAPI: LibJamiCallAPI,
              callEvents: (observer: (event: LibJamiCallEvent) => void) => void,
              commandQueue: CommandQueue =
                new CommandQueue('com.savoirfairelinux.jami.calls.commands')) {
    this.callAPI = callAPI;
    this.callEvents = callEvents;
    this.commandQueue = commandQueue;
  }

  /** Swift `private func send(_ command:)`. */
  private send(command: (api: LibJamiCallAPI) => void): void {
    const api: LibJamiCallAPI = this.callAPI;
    this.commandQueue.enqueue((): void => {
      command(api);
    });
  }

  /** Swift `private func send(_ name:reporting:)` - logs when libjami rejects the command. */
  private sendReporting(name: string, command: (api: LibJamiCallAPI) => boolean): void {
    const api: LibJamiCallAPI = this.callAPI;
    this.commandQueue.enqueue((): void => {
      if (!command(api)) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'libjami rejected %{public}s', name);
      }
    });
  }

  /** Swift `private static func waitForTimeout(_:)` - false when the wait was cancelled. */
  private static async waitForTimeout(timeoutSeconds: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      setTimeout((): void => {
        resolve(true);
      }, timeoutSeconds * MILLISECONDS_PER_SECOND);
    });
  }

  /** Swift `func start()` - begins consuming libjami events exactly once. */
  start(): void {
    if (this.consumerTask) {
      return;
    }
    this.consumerTask = true;
    this.callEvents((event: LibJamiCallEvent): void => {
      this.apply(event);
    });
  }

  // MARK: - Reads

  /** Swift `func events() -> AsyncStream<CallSystemEvent>`. Returns the unsubscribe closure. */
  events(observer: (event: CallSystemEvent) => void): () => void {
    return this.broadcaster.subscribe(observer);
  }

  /**
   * Swift `func events(for:fallback:)` - every event concerning one call, replaying its
   * current lifecycle state first so the screen never opens on nothing.
   */
  eventsForCall(callId: CallId, fallback: CallState | null,
                observer: (event: CallSystemEvent) => void): () => void {
    let observedCall: CallState | null = null;
    let lifecycleEvent: CallSystemEvent | null = null;
    const live: CallState | undefined = this.state.calls.get(callId.raw);
    const ended: EndedCall | null = this.endedCalls.get(callId);
    if (live !== undefined) {
      observedCall = live;
      lifecycleEvent = CallSystemEvent.callUpdated(live);
    } else if (ended !== null) {
      observedCall = ended.call;
      lifecycleEvent = CallSystemEvent.callEnded(ended.call, ended.durationSeconds);
    } else if (fallback !== null && fallback.id.equals(callId)) {
      const terminated: CallState = this.terminating(fallback);
      observedCall = terminated;
      lifecycleEvent = CallSystemEvent.callEnded(terminated, this.callDuration(terminated));
    }

    const replay: CallSystemEvent[] = [];
    if (observedCall !== null) {
      const confId: ConfId | null = observedCall.conferenceId;
      if (confId !== null) {
        const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
        if (conference !== undefined) {
          // The conference must be known before a replayed subcall end so the screen can
          // follow a surviving member instead of dismissing.
          replay.push(CallSystemEvent.conferenceUpdated(conference));
        }
      }
    }
    if (lifecycleEvent !== null) {
      replay.push(lifecycleEvent);
    }

    return this.broadcaster.subscribeFiltered(replay, (event: CallSystemEvent): boolean => {
      switch (event.kind) {
        case CallSystemEventKind.CALL_ADDED:
        case CallSystemEventKind.CALL_UPDATED:
        case CallSystemEventKind.CALL_ENDED:
          return event.call !== null && event.call.id.equals(callId);
        case CallSystemEventKind.CALL_MATCHED:
          return event.replacedCallId !== null && event.replacedCallId.equals(callId);
        case CallSystemEventKind.CONFERENCE_UPDATED:
        case CallSystemEventKind.CONFERENCE_ENDED:
          return true;
        case CallSystemEventKind.INCOMING_MESSAGE:
          return event.messageCallId !== null && event.messageCallId.equals(callId);
        default:
          return false;
      }
    }, observer);
  }

  /** Swift `func snapshot() -> CallSystemState`. */
  snapshot(): CallSystemState {
    return this.state;
  }

  // MARK: - Call intents

  /**
   * Swift `func placeCall(accountId:to:audioOnly:videoSource:)`. `to` may be a peer URI, or a
   * swarm:/rdv: URI, which always gets the complete audio+video media list (libjami contract).
   */
  placeCall(accountId: string, peerUri: string, audioOnly: boolean,
            videoSource: string): CallState {
    const isSwarmStyle: boolean =
      peerUri.startsWith(SWARM_URI_PREFIX) || peerUri.startsWith(RDV_URI_PREFIX);
    const media: MediaItem[] = isSwarmStyle
      ? MediaNegotiator.completeMediaList(audioOnly, videoSource)
      : MediaNegotiator.defaultMediaList(audioOnly, videoSource);
    return this.placeCallWithMedia(accountId, peerUri, media, audioOnly, false);
  }

  /** Swift `private func placeCall(accountId:to:media:isAudioOnly:joinsExistingCall:)`. */
  private placeCallWithMedia(accountId: string, peerUri: string, media: MediaItem[],
                             isAudioOnly: boolean, joinsExistingCall: boolean): CallState {
    const rawId: string | null = this.callAPI.placeCall(accountId, peerUri, media);
    if (rawId === null) {
      // The daemon gap: no session exists, so the caller gets the explicit notice rather than
      // a generic failure it cannot explain to the user.
      if (!this.callAPI.isOperational) {
        throw ServiceRegistry.shared().daemonService.reportUnavailable('call.place');
      }
      throw new CallStoreError(CallStoreErrorKind.PLACE_CALL_FAILED);
    }
    return this.registerPlacedCall(rawId, accountId, peerUri, media, isAudioOnly,
      joinsExistingCall);
  }

  /**
   * A swarm call has no single peer: it is named after its conversation, so `bestName` (the
   * Home return-to-call bar, the notification) reads the group's title, not the raw swarm:/rdv:
   * URI.
   * ponytail: the swarm's own title only; an untitled group still falls back to the URI until
   * the member-name title (ExpandableAvatar groupTitleFor, .ets) is reachable from here.
   */
  private static conversationTitle(accountId: string, conversationId: string): string {
    const conversation: ConversationModel | null = ServiceRegistry.shared().conversationsService
      .getConversationForId(conversationId, accountId);
    return conversation === null ? '' : conversation.title.trim();
  }

  /** Swift `private func registerPlacedCall(...)`. */
  private registerPlacedCall(rawId: string, accountId: string, peerUri: string,
                             media: MediaItem[], isAudioOnly: boolean,
                             joinsExistingCall: boolean = false): CallState {
    const call: CallState = new CallState(new CallId(rawId), accountId,
      CallDirection.OUTGOING, CallStatus.connecting());
    call.peerUri = peerUri;
    call.media = media;
    call.isAudioOnly = isAudioOnly;
    call.joinsExistingCall = joinsExistingCall;
    if (peerUri.startsWith(SWARM_URI_PREFIX)) {
      call.conversationId = peerUri.substring(SWARM_URI_PREFIX.length);
      call.displayName = CallStore.conversationTitle(accountId, call.conversationId);
    } else if (peerUri.startsWith(RDV_URI_PREFIX)) {
      const joined: ActiveCall | null = ActiveCall.fromRaw(peerUri);
      if (joined !== null) {
        // Joining an ongoing swarm call: mark it accepted everywhere so banners dismiss and
        // sibling accounts do not re-prompt.
        call.conversationId = joined.conversationId;
        call.displayName = CallStore.conversationTitle(accountId, joined.conversationId);
        this.activeCallsTracker.acceptCall(peerUri);
        this.broadcaster.send(
          CallSystemEvent.activeCallsChanged(this.activeCallsTracker.trackers));
      }
    } else {
      CallStore.namePlacedCall(call);
    }
    this.endedCalls.forget(call.id);
    this.state.calls.set(call.id.raw, call);
    this.broadcaster.send(CallSystemEvent.callAdded(call));
    return call;
  }

  /**
   * A 1:1 call is named like the contact page names the peer: the profile alias, then the
   * registered username; `bestName` falls back to the id. The daemon names only incoming calls
   * (CallDetails), so a placed call showed the 40-character id in the header and return bar.
   * ponytail: reads the profile relay's current value; the chat and contact pages that place
   * calls already subscribe to it, so it is resolved by then.
   */
  private static namePlacedCall(call: CallState): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const alias: string | null =
      registry.profileService.getProfile(call.peerHash, call.accountId).value.alias;
    call.displayName = alias === null ? '' : alias.trim();
    const contact: ContactModel | null = registry.contactsService.contact(call.peerHash);
    call.registeredName = contact === null ? null : contact.userName;
  }

  /**
   * Swift `func placeSwarmCall(...)` - hosts a swarm call: places `swarm:<conversationId>` and
   * waits for libjami's ConferenceCreated.
   */
  placeSwarmCall(accountId: string, conversationId: string, audioOnly: boolean,
                 videoSource: string,
                 timeout: number = SWARM_CALL_TIMEOUT_SECONDS,
                 lateConferenceRetention: number =
                   LATE_CONFERENCE_RETENTION_SECONDS): Promise<ConfId> {
    const key: PendingSwarmCallKey = new PendingSwarmCallKey(accountId, conversationId);
    if (this.pendingSwarmCalls.has(key.mapKey)) {
      return Promise.reject(new CallStoreError(CallStoreErrorKind.PLACE_CALL_FAILED));
    }
    const uri: string = SWARM_URI_PREFIX + conversationId;
    const media: MediaItem[] = MediaNegotiator.completeMediaList(audioOnly, videoSource);

    return new Promise<ConfId>((resolve: (value: ConfId) => void,
                                reject: (reason: Error) => void): void => {
      const pending: PendingSwarmCall = new PendingSwarmCall(util.generateRandomUUID(true),
        new SwarmCallContinuation(resolve, reject), accountId, media, audioOnly,
        lateConferenceRetention);
      this.pendingSwarmCalls.set(key.mapKey, pending);
      this.scheduleSwarmCallExpiration(key, timeout);

      // A null id is the normal libjami result when this device hosts a new swarm;
      // ConferenceCreated completes that path. If libjami returns a sub-call id, retain the
      // ordinary outgoing-call flow.
      const rawId: string | null = this.callAPI.placeCall(accountId, uri, media);
      if (rawId === null) {
        if (!this.callAPI.isOperational) {
          // No daemon, so no ConferenceCreated will ever arrive: fail now with the explicit
          // notice instead of leaving the caller waiting out the timeout.
          this.pendingSwarmCalls.delete(key.mapKey);
          const continuation: SwarmCallContinuation | null = pending.continuation;
          pending.continuation = null;
          if (continuation !== null) {
            continuation.resumeThrowing(
              ServiceRegistry.shared().daemonService.reportUnavailable('call.placeSwarmCall'));
          }
        }
        return;
      }
      const call: CallState =
        this.registerPlacedCall(rawId, accountId, uri, media, audioOnly, false);
      const stored: PendingSwarmCall | undefined = this.pendingSwarmCalls.get(key.mapKey);
      if (stored !== undefined) {
        stored.callId = call.id;
      }
    });
  }

  private scheduleSwarmCallExpiration(key: PendingSwarmCallKey, timeout: number): void {
    CallStore.waitForTimeout(timeout).then((elapsed: boolean): void => {
      if (elapsed) {
        this.expireSwarmCall(key);
      }
    });
  }

  private expireSwarmCall(key: PendingSwarmCallKey): void {
    const pending: PendingSwarmCall | undefined = this.pendingSwarmCalls.get(key.mapKey);
    if (pending === undefined) {
      return;
    }
    const continuation: SwarmCallContinuation | null = pending.continuation;
    if (continuation === null) {
      return;
    }
    pending.continuation = null;
    if (pending.callId === null) {
      // Retain host placement metadata after resuming the caller. A delayed ConferenceCreated
      // still represents a live daemon session and must produce a controllable call screen.
      this.pendingSwarmCalls.set(key.mapKey, pending);
      this.scheduleLateConferenceMetadataCleanup(key, pending.requestId,
        pending.lateConferenceRetention);
    } else {
      this.pendingSwarmCalls.delete(key.mapKey);
    }
    continuation.resumeThrowing(new CallStoreError(CallStoreErrorKind.SWARM_CALL_TIMED_OUT));
  }

  private scheduleLateConferenceMetadataCleanup(key: PendingSwarmCallKey, requestId: string,
                                                retention: number): void {
    CallStore.waitForTimeout(retention).then((elapsed: boolean): void => {
      if (elapsed) {
        this.removeExpiredSwarmPlacement(key, requestId);
      }
    });
  }

  private removeExpiredSwarmPlacement(key: PendingSwarmCallKey, requestId: string): void {
    const pending: PendingSwarmCall | undefined = this.pendingSwarmCalls.get(key.mapKey);
    if (pending === undefined || pending.requestId !== requestId
      || pending.continuation !== null) {
      return;
    }
    this.pendingSwarmCalls.delete(key.mapKey);
  }

  /**
   * Swift `func acceptPendingCall(peerId:accountId:withVideo:timeout:)` - answers a call the
   * user accepted on the incoming-call screen before libjami reported it: the call exists from
   * the user's action, and the libjami call replaces it on arrival.
   */
  acceptPendingCall(peerId: string, accountId: string, withVideo: boolean,
                    timeout: number = PENDING_CALL_TIMEOUT_SECONDS): CallState {
    const key: PendingCallKey = new PendingCallKey(accountId, filterOutHost(peerId));
    const existingId: CallId | undefined = this.awaitingMatch.get(key.mapKey);
    if (existingId !== undefined) {
      const existing: CallState | undefined = this.state.calls.get(existingId.raw);
      if (existing !== undefined) {
        return existing;
      }
    }
    const call: CallState = new CallState(CallId.local(), accountId, CallDirection.INCOMING,
      CallStatus.connecting());
    call.peerUri = peerId;
    call.media = MediaNegotiator.defaultMediaList(!withVideo, '');
    call.isAudioOnly = !withVideo;
    this.awaitingMatch.set(key.mapKey, call.id);
    this.state.calls.set(call.id.raw, call);
    this.broadcaster.send(CallSystemEvent.callAdded(call));

    this.scheduleUnmatchedCallExpiration(call.id, timeout);
    return call;
  }

  private scheduleUnmatchedCallExpiration(id: CallId, timeout: number): void {
    CallStore.waitForTimeout(timeout).then((elapsed: boolean): void => {
      if (elapsed) {
        this.expireUnmatchedCall(id);
      }
    });
  }

  private expireUnmatchedCall(id: CallId): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !id.isLocal) {
      return;
    }
    this.forgetAwaitingMatch(id);
    call.status = CallStatus.terminated(TerminationReason.FAILURE);
    this.finishCall(call);
  }

  /** Swift `awaitingMatch = awaitingMatch.filter { $0.value != id }`. */
  private forgetAwaitingMatch(id: CallId): void {
    const stale: string[] = [];
    this.awaitingMatch.forEach((value: CallId, key: string): void => {
      if (value.equals(id)) {
        stale.push(key);
      }
    });
    for (const key of stale) {
      this.awaitingMatch.delete(key);
    }
  }

  private matchPendingCall(placeholderId: CallId, call: CallState): void {
    const matched: CallState = call;
    const placeholder: CallState | undefined = this.state.calls.get(placeholderId.raw);
    if (placeholder !== undefined) {
      matched.callKitUUID = placeholder.callKitUUID;
      matched.conversationId = matched.conversationId ?? placeholder.conversationId;
    }
    this.state.calls.delete(placeholderId.raw);
    this.forgetAwaitingMatch(placeholderId);
    this.state.calls.set(matched.id.raw, matched);
    this.broadcaster.send(CallSystemEvent.callMatched(placeholderId, matched));
    this.applyPendingConferenceInfos(matched.id);
  }

  /** Swift `func accept(_:withVideo:)`. */
  accept(id: CallId, withVideo: boolean): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !call.status.allows(CallIntent.ACCEPT)) {
      return;
    }
    const media: MediaItem[] = call.media.length === 0
      ? [MediaItem.audio()] : copyMediaList(call.media);
    if (!withVideo) {
      for (let index: number = 0; index < media.length; index++) {
        if (media[index].type === MediaType.VIDEO) {
          media[index].muted = true;
        }
      }
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    const requested: MediaItem[] = media;
    this.sendReporting('accept', (api: LibJamiCallAPI): boolean => {
      return api.accept(raw, accountId, requested);
    });
    call.media = media;
    this.state.calls.set(id.raw, call);
    this.broadcaster.send(CallSystemEvent.callUpdated(call));
  }

  refuse(id: CallId): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !call.status.allows(CallIntent.REFUSE)) {
      return;
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    this.sendReporting('refuse', (api: LibJamiCallAPI): boolean => {
      return api.refuse(raw, accountId);
    });
    call.status = CallStatus.terminated(TerminationReason.ENDED_LOCALLY);
    this.finishCall(call);
  }

  hangUp(id: CallId): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !call.status.allows(CallIntent.HANG_UP)) {
      return;
    }
    const confId: ConfId | null = call.conferenceId;
    if (confId !== null && confId.raw === id.raw) {
      const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
      if (conference !== undefined && conference.isHost) {
        this.hangUpConference(confId);
        return;
      }
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    if (!id.isLocal) {
      this.sendReporting('hangUp', (api: LibJamiCallAPI): boolean => {
        return api.hangUp(raw, accountId);
      });
    }
    this.forgetAwaitingMatch(id);
    call.status = CallStatus.terminated(TerminationReason.ENDED_LOCALLY);
    this.finishCall(call);
  }

  hangUpConference(id: ConfId): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(id.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = id.raw;
    this.sendReporting('hangUpConference', (api: LibJamiCallAPI): boolean => {
      return api.hangUpConference(raw, accountId);
    });
    // Drop the conference before its members: a member finished while the conference still
    // listed the others would look like a session that lives on, and the screen would retarget
    // onto a call about to end too.
    const memberIds: CallId[] = CallStore.memberList(conference);
    this.state.conferences.delete(id.raw);
    for (const memberId of memberIds) {
      this.updateCall(memberId, false, (call: CallState): void => {
        call.conferenceId = null;
      });
    }
    this.broadcaster.send(CallSystemEvent.conferenceEnded(id, null));
    for (const memberId of memberIds) {
      const call: CallState | undefined = this.state.calls.get(memberId.raw);
      if (call === undefined) {
        continue;
      }
      call.status = CallStatus.terminated(TerminationReason.ENDED_LOCALLY);
      this.finishCall(call);
    }
    this.finishHostedConferenceCall(id,
      CallStatus.terminated(TerminationReason.ENDED_LOCALLY));
  }

  hold(id: CallId, hold: boolean): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || call.conferenceId !== null
      || !call.status.allows(hold ? CallIntent.HOLD : CallIntent.RESUME)) {
      return;
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    this.send((api: LibJamiCallAPI): void => {
      if (hold) {
        api.hold(raw, accountId);
      } else {
        api.resume(raw, accountId);
      }
    });
  }

  holdConference(id: ConfId, hold: boolean): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(id.raw);
    if (conference === undefined || !conference.isHost) {
      return;
    }
    const allowed: boolean = hold
      ? conference.lifecycle === ConferenceLifecycle.ACTIVE_ATTACHED
      : conference.lifecycle === ConferenceLifecycle.ACTIVE_DETACHED
        || conference.lifecycle === ConferenceLifecycle.HOLD;
    if (!allowed) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = id.raw;
    this.send((api: LibJamiCallAPI): void => {
      if (hold) {
        api.holdConference(raw, accountId);
      } else {
        api.resumeConference(raw, accountId);
      }
    });
  }

  /**
   * Swift `func toggleMute(_:label:cameraSource:)` - sends the re-invite that toggles
   * `label`'s mute state. UI state flips only when libjami confirms via
   * MediaNegotiationStatus.
   */
  toggleMute(id: CallId, label: MediaLabel, cameraSource: string): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !call.status.allows(CallIntent.CHANGE_MEDIA)) {
      return;
    }
    if (label.equals(MediaLabel.DEFAULT_VIDEO)) {
      // T-1616 timeline, t0: the user's tap. libjami answers with StartCapture/StopCapture.
      hilog.info(LOG_DOMAIN, F4_TAG, 'camera toggle requested on %{public}s: video was [%{public}s]', id.raw,
        describeMedia(call.media.filter((m: MediaItem): boolean => m.type === MediaType.VIDEO)));
    }
    if (this.requestHostedConferenceMediaChange(call, (media: MediaItem[]): MediaItem[] => {
      return MediaNegotiator.togglingMute(media, label, cameraSource);
    })) {
      return;
    }
    const newList: MediaItem[] =
      MediaNegotiator.togglingMute(call.media, label, cameraSource);
    if (mediaListsEqual(newList, call.media)) {
      return;
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    this.sendReporting('toggleMute', (api: LibJamiCallAPI): boolean => {
      return api.requestMediaChange(raw, accountId, newList);
    });
    call.pendingMediaRequest = newList;
    this.state.calls.set(id.raw, call);
  }

  /**
   * Swift `func updateVideoSource(_:source:)` - libjami cannot hot-swap the capture device, so
   * a capture-quality change has to travel as a media change on every unmuted video stream.
   */
  updateVideoSource(id: CallId, source: string): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined || !call.status.allows(CallIntent.CHANGE_MEDIA)) {
      return;
    }
    if (this.requestHostedConferenceMediaChange(call, (media: MediaItem[]): MediaItem[] => {
      const updated: MediaItem[] = copyMediaList(media);
      for (let index: number = 0; index < updated.length; index++) {
        if (updated[index].type === MediaType.VIDEO && !updated[index].muted) {
          updated[index].source = source;
        }
      }
      return updated;
    })) {
      return;
    }
    const newList: MediaItem[] = copyMediaList(call.media);
    for (let index: number = 0; index < newList.length; index++) {
      if (newList[index].type === MediaType.VIDEO && !newList[index].muted) {
        newList[index].source = source;
      }
    }
    if (mediaListsEqual(newList, call.media)) {
      return;
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    const requested: MediaItem[] = newList;
    this.sendReporting('updateVideoSource', (api: LibJamiCallAPI): boolean => {
      return api.requestMediaChange(raw, accountId, requested);
    });
    call.pendingMediaRequest = requested;
    this.state.calls.set(id.raw, call);
  }

  sendInCallMessage(id: CallId, message: Map<string, string>, jamiId: string,
                    isMixed: boolean): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined) {
      return;
    }
    const accountId: string = call.accountId;
    const raw: string = id.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.sendInCallMessage(raw, accountId, message, jamiId, isMixed);
    });
  }

  playDTMF(code: string): void {
    this.send((api: LibJamiCallAPI): void => {
      api.playDTMF(code);
    });
  }

  // MARK: - Conference intents

  /**
   * Swift `func addParticipant(peerUri:toCall:requestedBy:localDeviceId:videoSource:)` - calls
   * a new participant; the actual join runs when their call becomes current.
   */
  addParticipant(peerUri: string, hostId: CallId, localJamiId: string, localDeviceId: string,
                 videoSource: string): void {
    const host: CallState | undefined = this.state.calls.get(hostId.raw);
    if (host === undefined || !host.status.isOngoing) {
      throw new CallStoreError(CallStoreErrorKind.CALL_NOT_FOUND);
    }
    const hostConferenceId: ConfId | null = host.conferenceId;
    let conference: ConferenceState | null = null;
    if (hostConferenceId !== null) {
      conference = this.state.conferences.get(hostConferenceId.raw) ?? null;
    }
    if (conference !== null && !conference.isHost) {
      let isLocalModerator: boolean = false;
      for (const participant of conference.participants) {
        if (participant.isModerator
          && participant.isLocalDevice(localJamiId, localDeviceId, conference.isHost)) {
          isLocalModerator = true;
        }
      }
      if (!isLocalModerator) {
        throw new CallStoreError(CallStoreErrorKind.NOT_AUTHORIZED);
      }
    }
    const effectiveMedia: MediaItem[] = host.effectiveMedia(conference);
    const media: MediaItem[] = mediaHasNegotiatedVideo(effectiveMedia)
      ? MediaNegotiator.completeMediaList(mediaIsVideoMuted(effectiveMedia), videoSource)
      : MediaNegotiator.defaultMediaList(true, videoSource);
    const sub: CallState = this.placeCallWithMedia(host.accountId, peerUri, media,
      !mediaHasNegotiatedVideo(effectiveMedia), true);
    this.pendingJoins.set(sub.id.raw, hostId);
    this.refreshPendingInvites(hostId);
  }

  /** Swift `private func requestHostedConferenceMediaChange(for:transform:)`. */
  private requestHostedConferenceMediaChange(call: CallState,
                                             transform: (media: MediaItem[]) => MediaItem[]
  ): boolean {
    const confId: ConfId | null = call.conferenceId;
    if (confId === null) {
      return false;
    }
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined || !conference.isHost) {
      return false;
    }
    if (!conference.hasAttachedHost) {
      return true;
    }
    if (conference.media.length === 0) {
      return true;
    }
    if (conference.pendingMediaRequest !== null) {
      return true;
    }
    const requested: MediaItem[] = transform(conference.media);
    if (mediaListsEqual(requested, conference.media)) {
      return true;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.sendReporting('requestHostedConferenceMediaChange',
      (api: LibJamiCallAPI): boolean => {
        return api.requestMediaChange(raw, accountId, requested);
      });
    conference.pendingMediaRequest = requested;
    this.state.conferences.set(confId.raw, conference);
    this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
    return true;
  }

  private refreshPendingInvites(hostId: CallId): void {
    const invites: PendingConferenceInvite[] = [];
    this.pendingJoins.forEach((host: CallId, subRaw: string): void => {
      if (!host.equals(hostId)) {
        return;
      }
      const sub: CallState | undefined = this.state.calls.get(subRaw);
      if (sub === undefined) {
        return;
      }
      invites.push(new PendingConferenceInvite(sub.id, sub.peerUri, sub.status));
    });
    invites.sort((left: PendingConferenceInvite, right: PendingConferenceInvite): number => {
      return left.callId.raw < right.callId.raw ? -1 : (left.callId.raw > right.callId.raw ? 1 : 0);
    });
    const host: CallState | undefined = this.state.calls.get(hostId.raw);
    if (host === undefined || CallStore.invitesEqual(host.pendingInvites, invites)) {
      return;
    }
    this.updateCall(hostId, true, (call: CallState): void => {
      call.pendingInvites = invites;
    });
  }

  private static invitesEqual(left: PendingConferenceInvite[],
                              right: PendingConferenceInvite[]): boolean {
    if (left.length !== right.length) {
      return false;
    }
    for (let index: number = 0; index < left.length; index++) {
      if (!left[index].callId.equals(right[index].callId)
        || left[index].peerUri !== right[index].peerUri
        || !left[index].status.equals(right[index].status)) {
        return false;
      }
    }
    return true;
  }

  setActiveParticipant(participantId: string, confId: ConfId): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.setActiveParticipant(participantId, raw, accountId);
    });
  }

  setLayout(layout: ConferenceLayoutMode, confId: ConfId): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.setConferenceLayout(layout as number, raw, accountId);
    });
    conference.layout = layout;
    this.state.conferences.set(confId.raw, conference);
    this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
  }

  setModerator(participantId: string, confId: ConfId, active: boolean): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.setModerator(participantId, raw, accountId, active);
    });
  }

  hangUpParticipant(participantId: string, confId: ConfId, deviceId: string): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.hangUpParticipant(participantId, raw, accountId, deviceId);
    });
  }

  muteStream(participantId: string, confId: ConfId, deviceId: string, streamId: string,
             muted: boolean): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.muteStream(participantId, raw, accountId, deviceId, streamId, muted);
    });
  }

  raiseHand(participantId: string, confId: ConfId, deviceId: string, raised: boolean): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    const accountId: string = conference.accountId;
    const raw: string = confId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.raiseHand(participantId, raw, accountId, deviceId, raised);
    });
  }

  // MARK: - Active swarm calls

  updateActiveCalls(conversationId: string, calls: Array<Map<string, string>>,
                    account: AccountRef): void {
    this.activeCallsTracker.updateActiveCalls(conversationId, calls, account);
    this.broadcaster.send(
      CallSystemEvent.activeCallsChanged(this.activeCallsTracker.trackers));
  }

  ignoreActiveCall(call: ActiveCall): void {
    this.activeCallsTracker.ignoreCall(call);
    this.broadcaster.send(
      CallSystemEvent.activeCallsChanged(this.activeCallsTracker.trackers));
  }

  activeCall(conversationId: string, accountId: string): ActiveCall | null {
    return this.activeCallsTracker.activeCall(conversationId, accountId);
  }

  // MARK: - libjami event application

  /** Swift `private func apply(_ event: LibJamiCallEvent)`. */
  private apply(event: LibJamiCallEvent): void {
    switch (event.kind) {
      case LibJamiCallEventKind.INCOMING_CALL:
        this.applyIncomingCall(event.accountId, event.callId, event.peerUri, event.media,
          event.details);
        break;
      case LibJamiCallEventKind.CALL_STATE_CHANGED:
        this.applyStateChange(new CallId(event.callId), event.state, event.rawState,
          event.negotiatedMedia, event.videoCodec);
        break;
      case LibJamiCallEventKind.MEDIA_CHANGE_REQUESTED:
        this.applyMediaChangeRequest(event.accountId, new CallId(event.callId), event.media);
        break;
      case LibJamiCallEventKind.MEDIA_NEGOTIATION_STATUS:
        this.applyMediaNegotiation(new CallId(event.callId), event.media);
        break;
      case LibJamiCallEventKind.PEER_HOLD:
        this.applyPeerHold(new CallId(event.callId), event.flag);
        break;
      case LibJamiCallEventKind.AUDIO_MUTED:
        this.applyMuteSignal(new CallId(event.callId), MediaType.AUDIO, event.flag);
        break;
      case LibJamiCallEventKind.VIDEO_MUTED:
        this.applyMuteSignal(new CallId(event.callId), MediaType.VIDEO, event.flag);
        break;
      case LibJamiCallEventKind.REMOTE_RECORDING_CHANGED:
        this.updateCall(new CallId(event.callId), true, (call: CallState): void => {
          call.peerIsRecording = event.flag;
        });
        break;
      case LibJamiCallEventKind.INCOMING_MESSAGE:
        this.broadcaster.send(CallSystemEvent.incomingMessage(new CallId(event.callId),
          event.fromUri, event.message));
        break;
      case LibJamiCallEventKind.CONFERENCE_CREATED:
        this.applyConferenceCreated(new ConfId(event.conferenceId), event.conversationId,
          event.accountId, event.lifecycle, event.memberCallIds, event.participants,
          event.media);
        break;
      case LibJamiCallEventKind.CONFERENCE_CHANGED:
        this.applyConferenceChanged(new ConfId(event.conferenceId), event.accountId,
          event.lifecycle, event.memberCallIds);
        break;
      case LibJamiCallEventKind.CONFERENCE_REMOVED:
        this.applyConferenceRemoved(new ConfId(event.conferenceId));
        break;
      default:
        this.applyConferenceInfos(new ConfId(event.conferenceId), event.participants);
        break;
    }
  }

  private applyIncomingCall(accountId: string, callId: string, peerUri: string,
                            media: MediaItem[], details: CallDetails | null): void {
    const id: CallId = new CallId(callId);
    if (this.state.calls.has(id.raw)) {
      return;
    }
    const call: CallState = new CallState(id, accountId, CallDirection.INCOMING,
      CallStatus.incoming());
    call.peerUri = peerUri;
    call.displayName = details === null ? '' : details.displayName;
    call.registeredName = details === null ? null : details.registeredName;
    call.media = media;
    call.isAudioOnly = details !== null ? details.isAudioOnly
      : !CallStore.hasUnmutedVideo(media);
    this.endedCalls.forget(call.id);
    const key: PendingCallKey = new PendingCallKey(accountId, call.peerHash);
    const pendingId: CallId | undefined = this.awaitingMatch.get(key.mapKey);
    if (pendingId !== undefined) {
      this.matchPendingCall(pendingId, call);
      return;
    }
    this.state.calls.set(id.raw, call);
    this.broadcaster.send(CallSystemEvent.callAdded(call));
    this.applyPendingConferenceInfos(id);
  }

  /** Swift `media.contains { $0.type == .video && !$0.muted }`. */
  private static hasUnmutedVideo(media: MediaItem[]): boolean {
    for (const item of media) {
      if (item.type === MediaType.VIDEO && !item.muted) {
        return true;
      }
    }
    return false;
  }

  private applyStateChange(callId: CallId, libJamiState: LibJamiCallState | null,
                           rawState: string, negotiatedMedia: MediaItem[],
                           videoCodec: string | null): void {
    const call: CallState | undefined = this.state.calls.get(callId.raw);
    if (call === undefined) {
      return;
    }
    if (libJamiState === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown call state %{public}s for %{public}s',
        rawState, callId.raw);
      return;
    }

    let newStatus: CallStatus = CallStatus.fromLibJami(libJamiState);
    // Merge libjami's hold notion with the separately-signalled peer hold.
    if (newStatus.kind === CallStatusKind.HELD) {
      newStatus = CallStatus.held(call.peerHolding ? HoldSide.BOTH : HoldSide.LOCAL);
    } else if (newStatus.kind === CallStatusKind.CURRENT && call.peerHolding) {
      newStatus = CallStatus.held(HoldSide.PEER);
    }

    if (!call.status.canTransition(newStatus)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'unexpected transition %{public}s -> %{public}s for %{public}s (libjami is authoritative)',
        call.status.kind as string, newStatus.kind as string, callId.raw);
    }

    if (newStatus.kind === CallStatusKind.TERMINATED) {
      call.status = newStatus;
      this.finishCall(call);
      return;
    }

    if (newStatus.kind === CallStatusKind.CURRENT) {
      if (call.startedAt === null) {
        call.startedAt = new Date();
        if (negotiatedMedia.length > 0) {
          call.media = negotiatedMedia;
        }
      }
      if (videoCodec !== null && videoCodec.length > 0) {
        call.videoCodec = videoCodec;
      }
    }
    call.status = newStatus;
    this.state.calls.set(callId.raw, call);
    this.broadcaster.send(CallSystemEvent.callUpdated(call));

    if (newStatus.kind === CallStatusKind.CURRENT) {
      this.performPendingJoinIfNeeded(callId);
    } else {
      const hostId: CallId | undefined = this.pendingJoins.get(callId.raw);
      if (hostId !== undefined) {
        this.refreshPendingInvites(hostId);
      }
    }
  }

  private finishCall(call: CallState): void {
    const duration: number = this.callDuration(call);
    this.state.calls.delete(call.id.raw);
    this.pendingConferenceParticipants.delete(call.id.raw);
    const inviteHost: CallId | undefined = this.pendingJoins.get(call.id.raw);
    this.pendingJoins.delete(call.id.raw);
    if (call.peerUri.startsWith(RDV_URI_PREFIX)) {
      this.activeCallsTracker.activeCallHungUp(call.peerUri);
      this.broadcaster.send(
        CallSystemEvent.activeCallsChanged(this.activeCallsTracker.trackers));
    }
    const confId: ConfId | null = call.conferenceId;
    if (confId !== null) {
      const isPeerHostedConference: boolean = confId.raw === call.id.raw;
      if (isPeerHostedConference) {
        this.state.conferences.delete(confId.raw);
        this.broadcaster.send(CallSystemEvent.conferenceEnded(confId, null));
      } else {
        this.updateConference(confId, true, (conference: ConferenceState): void => {
          conference.memberCallIds.delete(call.id.raw);
        });
      }
    }
    this.endedCalls.record(call, duration);
    this.broadcaster.send(CallSystemEvent.callEnded(call, duration));
    if (inviteHost !== undefined) {
      this.refreshPendingInvites(inviteHost);
    }
    this.rehostPendingInvites(call);
  }

  /** Swift `private func rehostPendingInvites(leftBy host:)`. */
  private rehostPendingInvites(host: CallState): void {
    const legs: string[] = [];
    this.pendingJoins.forEach((hostId: CallId, legRaw: string): void => {
      if (hostId.equals(host.id)) {
        legs.push(legRaw);
      }
    });
    if (legs.length === 0) {
      return;
    }
    let successor: CallId | null = null;
    const confId: ConfId | null = host.conferenceId;
    if (confId !== null) {
      const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
      if (conference !== undefined) {
        const members: CallId[] = CallStore.sortedMemberList(conference);
        for (const memberId of members) {
          if (successor === null && this.state.calls.has(memberId.raw)) {
            successor = memberId;
          }
        }
      }
    }
    for (const legRaw of legs) {
      if (successor === null) {
        this.pendingJoins.delete(legRaw);
        this.hangUp(new CallId(legRaw));
      } else {
        this.pendingJoins.set(legRaw, successor);
      }
    }
    if (successor !== null) {
      this.refreshPendingInvites(successor);
    }
  }

  private callDuration(call: CallState): number {
    const startedAt: Date | null = call.startedAt;
    if (startedAt === null) {
      return 0;
    }
    const seconds: number =
      Math.floor((Date.now() - startedAt.getTime()) / MILLISECONDS_PER_SECOND);
    return Math.max(0, seconds);
  }

  private terminating(call: CallState): CallState {
    if (call.status.isTerminal) {
      return call;
    }
    const ended: CallState = call.copy();
    ended.status = CallStatus.terminated(TerminationReason.OVER);
    return ended;
  }

  private performPendingJoinIfNeeded(subCallId: CallId): void {
    const hostId: CallId | undefined = this.pendingJoins.get(subCallId.raw);
    if (hostId === undefined) {
      return;
    }
    this.pendingJoins.delete(subCallId.raw);
    this.refreshPendingInvites(hostId);
    const host: CallState | undefined = this.state.calls.get(hostId.raw);
    const sub: CallState | undefined = this.state.calls.get(subCallId.raw);
    if (host === undefined || sub === undefined) {
      return;
    }
    const hostAccountId: string = host.accountId;
    const subAccountId: string = sub.accountId;
    const confId: ConfId | null = host.conferenceId;
    let hostsConference: boolean = false;
    if (confId !== null) {
      const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
      hostsConference = conference !== undefined && conference.isHost;
    }
    if (confId !== null && hostsConference) {
      const conferenceRaw: string = confId.raw;
      this.send((api: LibJamiCallAPI): void => {
        api.joinConference(conferenceRaw, subCallId.raw, hostAccountId, subAccountId);
      });
    } else {
      this.send((api: LibJamiCallAPI): void => {
        api.joinCalls(hostId.raw, subCallId.raw, hostAccountId, subAccountId);
      });
    }
  }

  private applyMediaChangeRequest(accountId: string, callId: CallId,
                                  requested: MediaItem[]): void {
    const call: CallState | undefined = this.state.calls.get(callId.raw);
    if (call === undefined) {
      hilog.warn(LOG_DOMAIN, F4_TAG, 'media change request for unknown call %{public}s: [%{public}s] not answered',
        callId.raw, describeMedia(requested));
      return;
    }
    const answer: MediaItem[] = MediaNegotiator.answer(requested, call.media);
    hilog.info(LOG_DOMAIN, F4_TAG, 'media change request %{public}s: peer [%{public}s], answer [%{public}s]',
      callId.raw, describeMedia(requested), describeMedia(answer));
    const raw: string = callId.raw;
    this.send((api: LibJamiCallAPI): void => {
      api.answerMediaChangeRequest(raw, accountId, answer);
    });
  }

  private applyMediaNegotiation(callId: CallId, media: MediaItem[]): void {
    // The call screen shows the peer's video once this list holds an enabled video stream.
    hilog.info(LOG_DOMAIN, F4_TAG, 'media negotiated %{public}s: [%{public}s]%{public}s', callId.raw,
      describeMedia(media), this.state.calls.has(callId.raw) ? '' : ' (not a known call)');
    const confId: ConfId = new ConfId(callId.raw);
    if (this.isHostedConferenceAlias(callId, confId)) {
      this.updateConference(confId, true, (conference: ConferenceState): void => {
        if (media.length > 0) {
          conference.media = media;
        }
        conference.pendingMediaRequest = null;
      });
      return;
    }
    if (this.state.calls.has(callId.raw)) {
      this.updateCall(callId, true, (call: CallState): void => {
        if (media.length > 0) {
          call.media = media;
        }
        call.pendingMediaRequest = null;
      });
      return;
    }
    this.updateConference(confId, true, (conference: ConferenceState): void => {
      if (media.length > 0) {
        conference.media = media;
      }
      conference.pendingMediaRequest = null;
    });
  }

  private applyPeerHold(callId: CallId, hold: boolean): void {
    this.updateCall(callId, true, (call: CallState): void => {
      call.peerHolding = hold;
      const kind: CallStatusKind = call.status.kind;
      const side: HoldSide | null = call.status.holdSide;
      if (kind === CallStatusKind.CURRENT && hold) {
        call.status = CallStatus.held(HoldSide.PEER);
      } else if (kind === CallStatusKind.HELD && hold
        && (side === HoldSide.LOCAL || side === HoldSide.BOTH)) {
        call.status = CallStatus.held(HoldSide.BOTH);
      } else if (kind === CallStatusKind.HELD && !hold && side === HoldSide.PEER) {
        call.status = CallStatus.current();
      } else if (kind === CallStatusKind.HELD && !hold && side === HoldSide.BOTH) {
        call.status = CallStatus.held(HoldSide.LOCAL);
      }
    });
  }

  private applyMuteSignal(callId: CallId, type: MediaType, muted: boolean): void {
    const confId: ConfId = new ConfId(callId.raw);
    if (this.isHostedConferenceAlias(callId, confId)) {
      this.updateConference(confId, true, (conference: ConferenceState): void => {
        CallStore.applyMuteTo(conference.media, type, muted);
      });
      return;
    }
    if (this.state.calls.has(callId.raw)) {
      this.updateCall(callId, true, (call: CallState): void => {
        CallStore.applyMuteTo(call.media, type, muted);
        // libjami confirmed the mute we asked for; when no renegotiation answer follows
        // (the peer need not re-invite), this is the only completion the request gets.
        const pending: MediaItem[] | null = call.pendingMediaRequest;
        if (pending !== null && pending.some((m: MediaItem) => m.type === type && m.muted === muted)) {
          call.pendingMediaRequest = null;
        }
      });
      return;
    }
    this.updateConference(confId, true, (conference: ConferenceState): void => {
      CallStore.applyMuteTo(conference.media, type, muted);
    });
  }

  private static applyMuteTo(media: MediaItem[], type: MediaType, muted: boolean): void {
    for (let index: number = 0; index < media.length; index++) {
      if (media[index].type === type) {
        media[index].muted = muted;
      }
    }
  }

  private isHostedConferenceAlias(callId: CallId, confId: ConfId): boolean {
    const call: CallState | undefined = this.state.calls.get(callId.raw);
    if (call === undefined) {
      return false;
    }
    const callConfId: ConfId | null = call.conferenceId;
    if (callConfId === null || !callConfId.equals(confId)) {
      return false;
    }
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    return conference !== undefined && conference.isHost;
  }

  private applyConferenceCreated(confId: ConfId, conversationId: string, accountId: string,
                                 lifecycle: string, memberCallIds: string[],
                                 participants: ConferenceParticipantInfo[],
                                 media: MediaItem[]): void {
    const memberIds: Map<string, CallId> = CallStore.memberSet(memberCallIds);
    const latest: ConferenceParticipantInfo[] =
      ConferenceParticipantInfo.latestPerStream(participants);

    const conference: ConferenceState = this.state.conferences.get(confId.raw)
      ?? new ConferenceState(confId, accountId);
    conference.memberCallIds = memberIds;
    conference.lifecycle = conferenceLifecycleFromLibJami(lifecycle);
    if (media.length > 0) {
      conference.media = media;
    }
    if (latest.length > 0) {
      conference.participants = latest;
    }
    const pendingParticipants: ConferenceParticipantInfo[] | undefined =
      this.pendingConferenceParticipants.get(confId.raw);
    if (pendingParticipants !== undefined) {
      this.pendingConferenceParticipants.delete(confId.raw);
      conference.participants = pendingParticipants;
    }
    if (conversationId.length > 0) {
      conference.conversationId = conversationId;
    }

    memberIds.forEach((memberId: CallId): void => {
      this.updateCall(memberId, false, (call: CallState): void => {
        call.conferenceId = confId;
      });
    });

    conference.isHost = true;
    this.state.conferences.set(confId.raw, conference);

    const pendingKey: PendingSwarmCallKey =
      new PendingSwarmCallKey(accountId, conversationId);
    const pending: PendingSwarmCall | undefined =
      this.pendingSwarmCalls.get(pendingKey.mapKey);
    if (pending !== undefined) {
      this.pendingSwarmCalls.delete(pendingKey.mapKey);
      const pendingCallId: CallId | null = pending.callId;
      if (pendingCallId !== null) {
        this.updateCall(pendingCallId, false, (call: CallState): void => {
          call.conferenceId = confId;
        });
      } else {
        this.addHostedConferenceCall(confId, conversationId, pending, conference.media);
      }
      const continuation: SwarmCallContinuation | null = pending.continuation;
      if (continuation !== null) {
        continuation.resume(confId);
      }
    }

    this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
  }

  /**
   * Swift `private func addHostedConferenceCall(...)` - hosting a new swarm returns no call
   * id, so the conference's own id stands in for the local leg.
   */
  private addHostedConferenceCall(confId: ConfId, conversationId: string,
                                  pending: PendingSwarmCall,
                                  conferenceMedia: MediaItem[]): void {
    const callId: CallId = new CallId(confId.raw);
    const media: MediaItem[] = conferenceMedia.length === 0 ? pending.media : conferenceMedia;
    const call: CallState = new CallState(callId, pending.accountId, CallDirection.OUTGOING,
      CallStatus.connecting());
    call.peerUri = SWARM_URI_PREFIX + conversationId;
    call.media = media;
    call.isAudioOnly = pending.isAudioOnly;
    call.conversationId = conversationId;
    call.displayName = CallStore.conversationTitle(pending.accountId, conversationId);
    call.conferenceId = confId;
    this.endedCalls.forget(callId);
    this.state.calls.set(callId.raw, call);
    this.broadcaster.send(CallSystemEvent.callAdded(call));

    call.status = CallStatus.current();
    call.startedAt = new Date();
    this.state.calls.set(callId.raw, call);
    this.broadcaster.send(CallSystemEvent.callUpdated(call));
  }

  private applyConferenceChanged(confId: ConfId, accountId: string, lifecycle: string,
                                 memberCallIds: string[]): void {
    const conference: ConferenceState = this.state.conferences.get(confId.raw)
      ?? new ConferenceState(confId, accountId);
    const previousMembers: Map<string, CallId> = conference.memberCallIds;
    const memberIds: Map<string, CallId> = CallStore.memberSet(memberCallIds);
    conference.memberCallIds = memberIds;
    conference.lifecycle = conferenceLifecycleFromLibJami(lifecycle);
    const pendingParticipants: ConferenceParticipantInfo[] | undefined =
      this.pendingConferenceParticipants.get(confId.raw);
    if (pendingParticipants !== undefined) {
      this.pendingConferenceParticipants.delete(confId.raw);
      conference.participants = pendingParticipants;
    }
    memberIds.forEach((memberId: CallId): void => {
      this.updateCall(memberId, false, (call: CallState): void => {
        call.conferenceId = confId;
      });
    });
    // Detach calls that left the conference so they do not carry a stale parent id after they
    // continue (or end) on their own.
    previousMembers.forEach((departed: CallId, raw: string): void => {
      if (!memberIds.has(raw)) {
        this.updateCall(departed, false, (call: CallState): void => {
          call.conferenceId = null;
        });
      }
    });
    this.state.conferences.set(confId.raw, conference);
    this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
  }

  private applyConferenceRemoved(confId: ConfId): void {
    this.pendingConferenceParticipants.delete(confId.raw);
    const conference: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (conference === undefined) {
      return;
    }
    this.state.conferences.delete(confId.raw);
    // The subcall the session should fall back to once the conference is gone - the last
    // participant still in a live call with us.
    let remainingCallId: CallId | null = null;
    for (const memberId of CallStore.sortedMemberList(conference)) {
      if (remainingCallId === null && this.state.calls.has(memberId.raw)) {
        remainingCallId = memberId;
      }
    }
    for (const memberId of CallStore.memberList(conference)) {
      this.updateCall(memberId, false, (call: CallState): void => {
        call.conferenceId = null;
      });
    }
    this.broadcaster.send(CallSystemEvent.conferenceEnded(confId, remainingCallId));
    if (conference.isHost) {
      this.finishHostedConferenceCall(confId,
        CallStatus.terminated(TerminationReason.OVER));
    }
  }

  private finishHostedConferenceCall(confId: ConfId, status: CallStatus): void {
    const callId: CallId = new CallId(confId.raw);
    const call: CallState | undefined = this.state.calls.get(callId.raw);
    if (call === undefined) {
      return;
    }
    const callConfId: ConfId | null = call.conferenceId;
    if (callConfId === null || !callConfId.equals(confId)) {
      return;
    }
    call.conferenceId = null;
    call.status = status;
    this.finishCall(call);
  }

  private applyConferenceInfos(confId: ConfId,
                               participants: ConferenceParticipantInfo[]): void {
    const latest: ConferenceParticipantInfo[] =
      ConferenceParticipantInfo.latestPerStream(participants);
    const existing: ConferenceState | undefined = this.state.conferences.get(confId.raw);
    if (existing !== undefined) {
      if (latest.length === 0) {
        const peerHostedCallId: CallId = new CallId(confId.raw);
        const isPeerHostedConference: boolean = existing.memberCallIds.size === 1
          && existing.memberCallIds.has(peerHostedCallId.raw);
        if (isPeerHostedConference) {
          this.collapsePeerHostedConference(confId, peerHostedCallId);
          return;
        }
        if (existing.memberCallIds.size > 0) {
          return;
        }
      }
      existing.participants = latest;
      this.state.conferences.set(confId.raw, existing);
      this.broadcaster.send(CallSystemEvent.conferenceUpdated(existing));
      return;
    }

    if (latest.length === 0) {
      return;
    }
    const callId: CallId = new CallId(confId.raw);
    const call: CallState | undefined = this.state.calls.get(callId.raw);
    if (call === undefined) {
      this.pendingConferenceParticipants.set(confId.raw, latest);
      return;
    }

    const conference: ConferenceState = new ConferenceState(confId, call.accountId);
    conference.participants = latest;
    conference.memberCallIds = CallStore.memberSet([callId.raw]);
    this.state.conferences.set(confId.raw, conference);
    this.updateCall(callId, false, (member: CallState): void => {
      member.conferenceId = confId;
    });
    this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
  }

  private collapsePeerHostedConference(confId: ConfId, callId: CallId): void {
    this.state.conferences.delete(confId.raw);
    this.updateCall(callId, false, (call: CallState): void => {
      call.conferenceId = null;
    });
    const remaining: CallId | null = this.state.calls.has(callId.raw) ? callId : null;
    this.broadcaster.send(CallSystemEvent.conferenceEnded(confId, remaining));
  }

  private applyPendingConferenceInfos(callId: CallId): void {
    const confId: ConfId = new ConfId(callId.raw);
    const participants: ConferenceParticipantInfo[] | undefined =
      this.pendingConferenceParticipants.get(confId.raw);
    if (participants === undefined) {
      return;
    }
    this.pendingConferenceParticipants.delete(confId.raw);
    this.applyConferenceInfos(confId, participants);
  }

  // MARK: - State helpers

  private updateCall(id: CallId, emit: boolean, mutate: (call: CallState) => void): void {
    const call: CallState | undefined = this.state.calls.get(id.raw);
    if (call === undefined) {
      return;
    }
    mutate(call);
    this.state.calls.set(id.raw, call);
    if (emit) {
      this.broadcaster.send(CallSystemEvent.callUpdated(call));
    }
  }

  private updateConference(id: ConfId, emit: boolean,
                           mutate: (conference: ConferenceState) => void): void {
    const conference: ConferenceState | undefined = this.state.conferences.get(id.raw);
    if (conference === undefined) {
      return;
    }
    mutate(conference);
    this.state.conferences.set(id.raw, conference);
    if (emit) {
      this.broadcaster.send(CallSystemEvent.conferenceUpdated(conference));
    }
  }

  /** Swift `Set(memberCallIds.map { CallId(raw: $0) })`. */
  private static memberSet(memberCallIds: string[]): Map<string, CallId> {
    const members: Map<string, CallId> = new Map<string, CallId>();
    for (const raw of memberCallIds) {
      members.set(raw, new CallId(raw));
    }
    return members;
  }

  private static memberList(conference: ConferenceState): CallId[] {
    const members: CallId[] = [];
    conference.memberCallIds.forEach((memberId: CallId): void => {
      members.push(memberId);
    });
    return members;
  }

  /** Swift `.sorted { $0.raw < $1.raw }`. */
  private static sortedMemberList(conference: ConferenceState): CallId[] {
    const members: CallId[] = CallStore.memberList(conference);
    members.sort((left: CallId, right: CallId): number => {
      return left.raw < right.raw ? -1 : (left.raw > right.raw ? 1 : 0);
    });
    return members;
  }
}

/* ------------------------------------------------------------------------------------------
 * CallService - the app-facing facade over the store
 * ---------------------------------------------------------------------------------------- */

/**
 * Swift `final class CallService`. Vended by `ServiceRegistry` as `callService`, so the
 * constructor takes no arguments: it builds the whole call chain (gap client -> resolver ->
 * event source -> store) exactly as Swift's `convenience init` did.
 */
export class CallService {
  private readonly store: CallStore;
  private readonly eventSource: CallEventSource | null;
  private readonly callClient: LibJamiCallAPI;
  /** Swift's `client` / `resolver` / `source` locals of the convenience initializer. */
  private readonly client: LibJamiCallAPI;
  private readonly resolver: CallEventResolver;
  private readonly source: CallEventSource;
  /** Swift `private let callAPI` on the store; kept here too, same object. */
  private readonly callAPI: LibJamiCallAPI;

  /**
   * Swift `private var mirrorStorage` behind `mirrorLock`. The lock is not ported: ArkTS runs
   * one event loop, so there is no other thread to race with.
   */
  private mirrorStorage: CallSystemState = new CallSystemState();

  /** Swift `private(set) var stateMirror: CallSystemState`. */
  get stateMirror(): CallSystemState {
    return this.mirrorStorage;
  }

  // MARK: - Rx surface

  /** Ongoing swarm calls per account (banners, active-calls list). */
  readonly activeCalls: BehaviorRelay<Map<string, AccountCallTracker>> =
    new BehaviorRelay<Map<string, AccountCallTracker>>(new Map<string, AccountCallTracker>());

  readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /** Swift `var sharedResponseStream: Observable<ServiceEvent>`. */
  get sharedResponseStream(): PublishSubject<ServiceEvent> {
    return this.responseStream;
  }

  /** Swift `var newMessage: Observable<ServiceEvent>` - the same stream, by its other name. */
  get newMessage(): PublishSubject<ServiceEvent> {
    return this.responseStream;
  }

  /**
   * Swift `let callsUpdated = PublishSubject<Void>()`. ArkTS has no `void` type argument, so
   * the tick carries a `true` - subscribers only care that it fired.
   */
  readonly callsUpdated: PublishSubject<boolean> = new PublishSubject<boolean>();

  // MARK: - CallsManager wiring

  /** Every store event, after `stateMirror` has been updated. */
  onSystemEvent: ((event: CallSystemEvent) => void) | null = null;
  /** Swift `weak var camera` - owned by CallsManager; the call layer never captures. */
  camera: CallCameraCoordinating | null = null;

  constructor() {
    // Swift `convenience init(callsAdapter:)`: CallsAdapter is the bridge into the absent
    // daemon, so the client is the gap client and the source has nothing to attach to.
    const client: LibJamiCallAPI = new DaemonCallClient();
    const resolver: CallEventResolver = new CallEventResolver(client);
    const source: CallEventSource = new CallEventSource((signal: RawCallSignal): void => {
      resolver.handle(signal);
    });
    this.client = client;
    this.resolver = resolver;
    this.source = source;
    this.callClient = client;
    this.callAPI = client;
    this.eventSource = source;
    this.store = new CallStore(client, resolver.events);
  }

  /** The libjami call-signal sink JamiNative delivers to (Swift: the CallsAdapter delegate). */
  get callEvents(): CallEventSource {
    return this.source;
  }

  /** Swift `func start()` - begins consuming libjami events and pumping them to subscribers. */
  start(): void {
    // Swift attached the delegate in its convenience init; here it is deferred to `start()` so
    // the "call events unavailable" notice fires once, when the call domain is actually
    // started, rather than whenever the registry happens to build this service.
    const source: CallEventSource | null = this.eventSource;
    if (source !== null) {
      source.attachToAdapter();
    }
    this.store.start();
    this.pumpStoreEvents();
  }

  // MARK: - Store event pump

  private pumpStoreEvents(): void {
    this.store.events((event: CallSystemEvent): void => {
      this.handle(event);
    });
  }

  /** Swift `func handle(_ event: CallSystemEvent)` - mirror first, then fan out. */
  handle(event: CallSystemEvent): void {
    switch (event.kind) {
      case CallSystemEventKind.CALL_ADDED:
      case CallSystemEventKind.CALL_UPDATED:
        if (event.call !== null) {
          this.mirrorStorage.calls.set(event.call.id.raw, event.call);
          this.callsUpdated.onNext(true);
        }
        break;
      case CallSystemEventKind.CALL_MATCHED:
        if (event.call !== null && event.replacedCallId !== null) {
          this.mirrorStorage.calls.delete(event.replacedCallId.raw);
          this.mirrorStorage.calls.set(event.call.id.raw, event.call);
          this.callsUpdated.onNext(true);
        }
        break;
      case CallSystemEventKind.CALL_ENDED:
        if (event.call !== null) {
          this.mirrorStorage.calls.delete(event.call.id.raw);
          this.callsUpdated.onNext(true);
          this.emitCallEnded(event.call, event.durationSeconds);
        }
        break;
      case CallSystemEventKind.CONFERENCE_UPDATED:
        if (event.conference !== null) {
          this.mirrorStorage.conferences.set(event.conference.id.raw, event.conference);
          // The call screen renders the roster and tiles off the mirror; it listens here.
          this.callsUpdated.onNext(true);
        }
        break;
      case CallSystemEventKind.CONFERENCE_ENDED:
        if (event.conferenceId !== null) {
          this.mirrorStorage.conferences.delete(event.conferenceId.raw);
          this.callsUpdated.onNext(true);
        }
        break;
      case CallSystemEventKind.INCOMING_MESSAGE:
        if (event.messageCallId !== null) {
          this.emitIncomingMessage(event.messageCallId, event.fromUri, event.message);
        }
        break;
      default:
        this.activeCalls.accept(event.trackers);
        break;
    }
    const listener: ((event: CallSystemEvent) => void) | null = this.onSystemEvent;
    if (listener !== null) {
      listener(event);
    }
  }

  // MARK: - Outgoing calls

  /** Swift `func startOutgoingCall(uri:account:isAudioOnly:)`. */
  startOutgoingCall(uri: string, account: AccountModel, isAudioOnly: boolean): void {
    const camera: CallCameraCoordinating | null = this.camera;
    if (camera !== null) {
      camera.prepareCameraForOutgoingCall(isAudioOnly);
    }
    const videoSource: string = camera === null ? '' : camera.currentCameraSource();
    if (uri.startsWith(SWARM_URI_PREFIX)) {
      const conversationId: string = uri.substring(SWARM_URI_PREFIX.length);
      this.store.placeSwarmCall(account.id, conversationId, isAudioOnly, videoSource)
        .catch((error: Error): void => {
          this.reportOutgoingCallFailure(error);
        });
      return;
    }
    try {
      this.store.placeCall(account.id, uri, isAudioOnly, videoSource);
    } catch (error) {
      this.reportOutgoingCallFailure(error as Error);
    }
  }

  private reportOutgoingCallFailure(error: Error): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'placing call failed: %{public}s', error.message);
    const camera: CallCameraCoordinating | null = this.camera;
    if (camera !== null) {
      camera.cancelCameraPreparation();
    }
  }

  /** Swift `func placeCall(accountId:to:audioOnly:)` - throws the daemon gap on this platform. */
  async placeCall(accountId: string, peerUri: string, audioOnly: boolean): Promise<CallState> {
    // HarmonyOS grants the microphone (and camera) at runtime; libjami's capture needs them.
    const video: VideoService = ServiceRegistry.shared().videoService;
    await (audioOnly ? video.ensureMicrophonePermission() : video.ensureCameraAndMicrophonePermission());
    const camera: CallCameraCoordinating | null = this.camera;
    const videoSource: string = camera === null ? '' : camera.currentCameraSource();
    if (!peerUri.startsWith(SWARM_URI_PREFIX)) {
      return this.store.placeCall(accountId, peerUri, audioOnly, videoSource);
    }
    // Swift `startOutgoingCall` sends swarm: through `placeSwarmCall`. Hosting a new swarm call
    // returns no call id, so `store.placeCall` reported PLACE_CALL_FAILED while the conference
    // ran on with no call screen and nothing to hang it up.
    const conversationId: string = peerUri.substring(SWARM_URI_PREFIX.length);
    const hosted: Promise<ConfId> =
      this.store.placeSwarmCall(accountId, conversationId, audioOnly, videoSource);
    // libjami joined a call already running instead: that sub-call is registered by now.
    const joined: CallState | undefined = this.store.snapshot().liveCalls
      .find((call: CallState): boolean => call.peerUri === peerUri);
    if (joined !== undefined) {
      hosted.catch((error: Error): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'swarm join: %{public}s', error.message);
      });
      return joined;
    }
    const confId: ConfId = await hosted;
    const call: CallState | undefined = this.store.snapshot().liveCalls
      .find((candidate: CallState): boolean =>
        candidate.conferenceId !== null && candidate.conferenceId.equals(confId));
    if (call === undefined) {
      throw new CallStoreError(CallStoreErrorKind.PLACE_CALL_FAILED);
    }
    return call;
  }

  /**
   * Swift `func placeSwarmCall(...)` on the store, reached through the service for the hosted
   * swarm path.
   */
  async placeSwarmCall(accountId: string, conversationId: string, audioOnly: boolean,
                       videoSource: string,
                       timeout: number = SWARM_CALL_TIMEOUT_SECONDS,
                       lateConferenceRetention: number =
                         LATE_CONFERENCE_RETENTION_SECONDS): Promise<ConfId> {
    return this.store.placeSwarmCall(accountId, conversationId, audioOnly, videoSource,
      timeout, lateConferenceRetention);
  }

  // MARK: - Synchronous queries

  get hasOngoingCalls(): boolean {
    return this.stateMirror.ongoingCalls.length > 0;
  }

  /** Swift `func call(participantId:accountId:) -> CallId?`. */
  call(participantId: string, accountId: string): CallId | null {
    const found: CallState | null =
      this.stateMirror.callWithPeer(filterOutHost(participantId), accountId);
    return found === null ? null : found.id;
  }

  getActiveCall(accountId: string, conversationId: string): ActiveCall | null {
    const tracker: AccountCallTracker | undefined = this.activeCalls.value.get(accountId);
    if (tracker === undefined) {
      return null;
    }
    const calls: ActiveCall[] = tracker.callsFor(conversationId);
    return calls.length === 0 ? null : calls[0];
  }

  /** Swift `func activeCall(conversationId:accountId:)` on the store. */
  activeCall(conversationId: string, accountId: string): ActiveCall | null {
    return this.store.activeCall(conversationId, accountId);
  }

  /**
   * Swift `func outgoingCallURI(for:)` - resolves a conversation's direct, swarm, or active
   * rendezvous call URI.
   */
  outgoingCallURI(conversation: ConversationModel): string | null {
    if (conversation.isCoredialog()) {
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (participants.length > 0) {
        return participants[0].jamiId;
      }
      const local: ConversationParticipant | null = conversation.getLocalParticipants();
      return local === null ? null : local.jamiId;
    }

    if (!conversation.isSwarm() || conversation.id.length === 0
      || conversation.getParticipants().length === 0) {
      return null;
    }

    const active: ActiveCall | null =
      this.getActiveCall(conversation.accountId, conversation.id);
    return active !== null ? active.constructURI() : SWARM_URI_PREFIX + conversation.id;
  }

  // MARK: - Intents from conversation features

  /**
   * Swift `RendererLayerView.scalingPolicy` (ParticipantCanvas.applyVideoScalingPolicies): the
   * sink's video cropped to its tile (aspectFill, the default), drawn whole (aspectFit), or
   * automatic. The native renderer keeps the choice when the sink moves to another surface.
   */
  setSinkScaling(sinkId: string, policy: SinkScaling): void {
    jami.setSinkScaling(sinkId, policy);
  }

  /** Swift `func sendInCallMessage(callId:message:accountId:)`. */
  sendInCallMessage(callId: CallId, message: string, account: AccountModel): void {
    const payload: Map<string, string> = new Map<string, string>();
    payload.set(TEXT_PLAIN_MIME, message);
    this.store.sendInCallMessage(callId, payload, account.jamiId,
      account.type === AccountType.SIP);
  }

  /** Swift `func addParticipant(uri:toCall:requestedBy:localDeviceId:)`. */
  addParticipant(uri: string, callId: CallId, localJamiId: string,
                 localDeviceId: string): void {
    const camera: CallCameraCoordinating | null = this.camera;
    try {
      this.store.addParticipant(uri, callId, localJamiId, localDeviceId,
        camera === null ? '' : camera.currentCameraSource());
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'failed to add call participant: %{public}s',
        (error as Error).message);
    }
  }

  ignoreCall(call: ActiveCall): void {
    this.store.ignoreActiveCall(call);
  }

  /** Swift `func ignoreActiveCall(_:)` on the store. */
  ignoreActiveCall(call: ActiveCall): void {
    this.store.ignoreActiveCall(call);
  }

  // MARK: - Active swarm-call discovery

  updateActiveCalls(conversationId: string, account: AccountModel): void {
    const raw: Array<Map<string, string>> =
      this.callClient.activeCalls(conversationId, account.id);
    this.store.updateActiveCalls(conversationId, raw, CallService.accountRef(account));
  }

  activeCallsChanged(conversationId: string, calls: Array<Map<string, string>>,
                     account: AccountModel): void {
    this.store.updateActiveCalls(conversationId, calls, CallService.accountRef(account));
  }

  private static accountRef(account: AccountModel): AccountRef {
    let deviceId: string = '';
    for (const device of account.devices as DeviceModel[]) {
      if (deviceId.length === 0 && device.isCurrent) {
        deviceId = device.deviceId;
      }
    }
    return new AccountRef(account.id, account.jamiId, deviceId);
  }

  // MARK: - Store forwarding (in-call screen)

  async snapshot(): Promise<CallSystemState> {
    return this.store.snapshot();
  }

  /** Swift `func events(for:fallback:)`. Returns the unsubscribe closure. */
  events(callId: CallId, fallback: CallState | null,
         observer: (event: CallSystemEvent) => void): () => void {
    return this.store.eventsForCall(callId, fallback, observer);
  }

  /** Swift `func acceptPendingCall(peerId:accountId:withVideo:)`. */
  async acceptPendingCall(peerId: string, accountId: string,
                          withVideo: boolean): Promise<CallState> {
    const camera: CallCameraCoordinating | null = this.camera;
    if (withVideo && camera !== null) {
      camera.prepareCameraForAnswerWithVideo();
    }
    return this.store.acceptPendingCall(peerId, accountId, withVideo);
  }

  async accept(id: CallId, withVideo: boolean): Promise<void> {
    const video: VideoService = ServiceRegistry.shared().videoService;
    await (withVideo ? video.ensureCameraAndMicrophonePermission() : video.ensureMicrophonePermission());
    const camera: CallCameraCoordinating | null = this.camera;
    if (withVideo && camera !== null) {
      camera.prepareCameraForAnswerWithVideo();
    }
    this.store.accept(id, withVideo);
  }

  async refuse(id: CallId): Promise<void> {
    this.store.refuse(id);
  }

  async hangUp(id: CallId): Promise<void> {
    this.store.hangUp(id);
  }

  async hangUpConference(id: ConfId): Promise<void> {
    this.store.hangUpConference(id);
  }

  async hold(id: CallId, hold: boolean): Promise<void> {
    this.store.hold(id, hold);
  }

  async holdConference(id: ConfId, hold: boolean): Promise<void> {
    this.store.holdConference(id, hold);
  }

  async toggleMute(id: CallId, label: MediaLabel): Promise<void> {
    const camera: CallCameraCoordinating | null = this.camera;
    this.store.toggleMute(id, label, camera === null ? '' : camera.currentCameraSource());
  }

  playDTMF(code: string): void {
    this.store.playDTMF(code);
  }

  async updateVideoSource(id: CallId, source: string): Promise<void> {
    this.store.updateVideoSource(id, source);
  }

  async setLayout(layout: ConferenceLayoutMode, confId: ConfId): Promise<void> {
    this.store.setLayout(layout, confId);
  }

  async setActiveParticipant(participantId: string, confId: ConfId): Promise<void> {
    this.store.setActiveParticipant(participantId, confId);
  }

  async setModerator(participantId: string, confId: ConfId, active: boolean): Promise<void> {
    this.store.setModerator(participantId, confId, active);
  }

  async hangUpParticipant(participantId: string, confId: ConfId,
                          deviceId: string): Promise<void> {
    this.store.hangUpParticipant(participantId, confId, deviceId);
  }

  async muteStream(participantId: string, confId: ConfId, deviceId: string, streamId: string,
                   muted: boolean): Promise<void> {
    this.store.muteStream(participantId, confId, deviceId, streamId, muted);
  }

  async raiseHand(participantId: string, confId: ConfId, deviceId: string,
                  raised: boolean): Promise<void> {
    this.store.raiseHand(participantId, confId, deviceId, raised);
  }

  // MARK: - Outbound service events

  /**
   * Swift `private func emitCallEnded(call:duration:)` - the event conversation history is
   * written from. `callUUID` carries the in-app incoming-call page id that replaces CallKit's
   * UUID; the numeric inputs use the typed `addNumber` accessors, since `ServiceEvent`'s
   * string bag cannot hold them.
   */
  private emitCallEnded(call: CallState, duration: number): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.CALL_ENDED);
    event.addEventInput(ServiceEventInput.PEER_URI, call.peerUri);
    event.addEventInput(ServiceEventInput.CALL_UUID, call.callKitUUID ?? '');
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, call.accountId);
    event.addEventInput(ServiceEventInput.CALL_ID, call.id.raw);
    event.addEventInput(ServiceEventInput.NAME, call.displayName);
    event.addNumber(ServiceEventInput.CALL_TYPE,
      (call.direction === CallDirection.INCOMING ? CallType.INCOMING : CallType.OUTGOING) as number);
    event.addNumber(ServiceEventInput.CALL_TIME, duration);
    this.responseStream.onNext(event);
  }

  private emitIncomingMessage(callId: CallId, fromUri: string,
                              message: Map<string, string>): void {
    // Only plain text reaches conversations; vCard chunks and other MIME payloads in call
    // messages are intentionally ignored.
    const call: CallState | undefined = this.stateMirror.calls.get(callId.raw);
    if (call === undefined) {
      return;
    }
    const keys: string[] = [];
    message.forEach((value: string, key: string): void => {
      keys.push(key);
    });
    let content: string = '';
    for (const key of keys) {
      if (content.length === 0 && key.includes(TEXT_PLAIN_MIME)) {
        content = message.get(key) ?? '';
      }
    }
    if (content.length === 0) {
      return;
    }
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.NEW_INCOMING_MESSAGE);
    event.addEventInput(ServiceEventInput.CONTENT, content);
    event.addEventInput(ServiceEventInput.PEER_URI, filterOutHost(fromUri));
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, call.accountId);
    event.addEventInput(ServiceEventInput.NAME, call.bestName);
    this.responseStream.onNext(event);
  }

  /** Swift `func emitPendingCallPreview(pushNotificationPayload:)`. */
  emitPendingCallPreview(pushNotificationPayload: Map<string, string>): void {
    const event: ServiceEvent =
      new ServiceEvent(ServiceEventType.CALL_PROVIDER_PREVIEW_PENDING_CALL);
    event.addMap(ServiceEventInput.CONTENT, pushNotificationPayload);
    this.responseStream.onNext(event);
  }
}
