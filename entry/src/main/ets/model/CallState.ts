/*
 * Ported from Ring/Ring/Models/Calls/CallState.swift:21-209 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The value-type snapshot of one call, the conference that may own its media, and the whole
 * call system's state. Owned and mutated exclusively by the call store; everyone else receives
 * copies. Every value originates in the jami daemon.
 */

import util from '@ohos.util';
import { MediaItem, MediaType } from './MediaItem';
import { CallStatus } from './CallStatus';
import { ConferenceParticipantInfo } from './ConferenceParticipantInfo';
import { filterOutHost } from './CallDetails';
import { MessageModel, MessageType } from './MessageModel';

const CALL_ID_LOCAL_PREFIX: string = 'local:';

/** Swift `MediaLabel.defaultAudio` / `.defaultVideo`, in their libjami string form. */
export const DEFAULT_AUDIO_LABEL: string = 'audio_0';
export const DEFAULT_VIDEO_LABEL: string = 'video_0';

/** Swift `struct CallId: Hashable, Sendable`. */
export class CallId {
  readonly raw: string;

  constructor(raw: string) {
    this.raw = raw;
  }

  /**
   * Swift `static func local()` - stands for a call the user started before libjami confirmed
   * one; never valid as a libjami argument.
   */
  static local(): CallId {
    return new CallId(CALL_ID_LOCAL_PREFIX + util.generateRandomUUID(true));
  }

  get isLocal(): boolean {
    return this.raw.startsWith(CALL_ID_LOCAL_PREFIX);
  }

  get description(): string {
    return this.raw;
  }

  equals(other: CallId): boolean {
    return this.raw === other.raw;
  }

  hash(): string {
    return this.raw;
  }
}

/** Swift `struct ConfId: Hashable, Sendable`. */
export class ConfId {
  readonly raw: string;

  constructor(raw: string) {
    this.raw = raw;
  }

  get description(): string {
    return this.raw;
  }

  equals(other: ConfId): boolean {
    return this.raw === other.raw;
  }

  hash(): string {
    return this.raw;
  }
}

/** Swift `enum ConferenceLifecycle: String`. */
export enum ConferenceLifecycle {
  ACTIVE_ATTACHED = 'ACTIVE_ATTACHED',
  ACTIVE_DETACHED = 'ACTIVE_DETACHED',
  HOLD = 'HOLD',
  UNKNOWN = 'UNKNOWN'
}

/** Swift `init(libJamiState:)` - anything unrecognized is `unknown`. */
export function conferenceLifecycleFromLibJami(libJamiState: string): ConferenceLifecycle {
  if (libJamiState === 'ACTIVE_ATTACHED') {
    return ConferenceLifecycle.ACTIVE_ATTACHED;
  }
  if (libJamiState === 'ACTIVE_DETACHED') {
    return ConferenceLifecycle.ACTIVE_DETACHED;
  }
  if (libJamiState === 'HOLD') {
    return ConferenceLifecycle.HOLD;
  }
  return ConferenceLifecycle.UNKNOWN;
}

/** Swift `enum CallDirection`. */
export enum CallDirection {
  INCOMING = 'INCOMING',
  OUTGOING = 'OUTGOING'
}

/**
 * Swift `enum ConferenceLayoutMode: Int` - the values are libjami's int encoding for
 * `setConferenceLayout`. Do not renumber.
 */
export enum ConferenceLayoutMode {
  GRID = 0,
  ONE_WITH_SMALL = 1,
  ONE = 2
}

/**
 * Swift `extension Array where Element == MediaItem`. Kept local to this module: a media list
 * is only ever interpreted here and in the conference below.
 */
export function mediaIsAudioMuted(media: MediaItem[]): boolean {
  for (const item of media) {
    if (item.label.libJamiString === DEFAULT_AUDIO_LABEL) {
      return item.muted;
    }
  }
  return false;
}

export function mediaIsVideoMuted(media: MediaItem[]): boolean {
  for (const item of media) {
    if (item.label.libJamiString === DEFAULT_VIDEO_LABEL) {
      return item.muted || !item.enabled;
    }
  }
  return true;
}

export function mediaHasVideo(media: MediaItem[]): boolean {
  for (const item of media) {
    if (item.type === MediaType.VIDEO && item.enabled && !item.muted) {
      return true;
    }
  }
  return false;
}

export function mediaHasNegotiatedVideo(media: MediaItem[]): boolean {
  for (const item of media) {
    if (item.type === MediaType.VIDEO && item.enabled) {
      return true;
    }
  }
  return false;
}

/**
 * Swift `struct PendingConferenceInvite` - a participant we invited who has not joined yet;
 * the join is deferred until their sub-call reaches `current`.
 */
export class PendingConferenceInvite {
  readonly callId: CallId;
  readonly peerUri: string;
  readonly status: CallStatus;

  constructor(callId: CallId, peerUri: string, status: CallStatus) {
    this.callId = callId;
    this.peerUri = peerUri;
    this.status = status;
  }
}

export class CallState {
  readonly id: CallId;
  readonly accountId: string;
  readonly direction: CallDirection;

  peerUri: string = '';
  displayName: string = '';
  registeredName: string | null = null;
  status: CallStatus;
  /** libjami-confirmed media list - flips only on MediaNegotiationStatus. */
  media: MediaItem[] = [];
  /** Re-invite we sent and are waiting on; cleared on negotiation result. */
  pendingMediaRequest: MediaItem[] | null = null;
  /** When the call became CURRENT (history duration counts from here). */
  startedAt: Date | null = null;
  isAudioOnly: boolean = false;
  /**
   * Swift `var callKitUUID: UUID?`. CallKit has no HarmonyOS equivalent, so this is the
   * identifier of the in-app incoming-call page / NotificationKit entry that replaces it.
   */
  callKitUUID: string | null = null;
  conferenceId: ConfId | null = null;
  peerIsRecording: boolean = false;
  videoCodec: string | null = null;
  /**
   * Tracked separately from `status` so local and peer hold can be merged into `held(side:)`
   * and correctly unwound.
   */
  peerHolding: boolean = false;
  conversationId: string | null = null;
  joinsExistingCall: boolean = false;
  pendingInvites: PendingConferenceInvite[] = [];

  constructor(id: CallId, accountId: string, direction: CallDirection, status: CallStatus) {
    this.id = id;
    this.accountId = accountId;
    this.direction = direction;
    this.status = status;
  }

  /** Swift `var bestName`. */
  get bestName(): string {
    if (this.displayName.length > 0) {
      return this.displayName;
    }
    const registeredName: string | null = this.registeredName;
    if (registeredName !== null && registeredName.length > 0) {
      return registeredName;
    }
    return this.peerHash;
  }

  /** Swift `var peerHash`. */
  get peerHash(): string {
    return filterOutHost(this.peerUri)
      .replace(new RegExp('jami:', 'g'), '')
      .replace(new RegExp('sip:', 'g'), '');
  }

  get isAudioMuted(): boolean {
    return mediaIsAudioMuted(this.media);
  }

  get isVideoMuted(): boolean {
    return mediaIsVideoMuted(this.media);
  }

  get hasVideo(): boolean {
    return mediaHasVideo(this.media);
  }

  get hasNegotiatedVideo(): boolean {
    return mediaHasNegotiatedVideo(this.media);
  }

  /** Swift `func mediaOwningHostedConference(in:)` - the attached locally hosted conference. */
  mediaOwningHostedConference(conference: ConferenceState | null): ConferenceState | null {
    if (conference === null) {
      return null;
    }
    const conferenceId: ConfId | null = this.conferenceId;
    if (conferenceId === null || !conference.id.equals(conferenceId)) {
      return null;
    }
    if (!conference.isHost || !conference.hasAttachedHost) {
      return null;
    }
    return conference;
  }

  /** Swift `func effectiveMedia(in:)` - media owned by this call, or by its hosted conference. */
  effectiveMedia(conference: ConferenceState | null): MediaItem[] {
    const owner: ConferenceState | null = this.mediaOwningHostedConference(conference);
    return owner === null ? this.media : owner.media;
  }

  /** Swift `func effectiveAudioMuted(in:)`. */
  effectiveAudioMuted(conference: ConferenceState | null): boolean {
    const owner: ConferenceState | null = this.mediaOwningHostedConference(conference);
    return owner === null ? this.isAudioMuted : owner.isAudioMuted;
  }

  /** Swift `Equatable` - the call id identifies a call. */
  equals(other: CallState): boolean {
    return this.id.equals(other.id);
  }

  /** A copy, so the store can hand out snapshots of its value type. */
  copy(): CallState {
    const clone: CallState = new CallState(this.id, this.accountId, this.direction, this.status);
    clone.peerUri = this.peerUri;
    clone.displayName = this.displayName;
    clone.registeredName = this.registeredName;
    clone.media = this.media.slice();
    clone.pendingMediaRequest =
      this.pendingMediaRequest === null ? null : this.pendingMediaRequest.slice();
    clone.startedAt = this.startedAt;
    clone.isAudioOnly = this.isAudioOnly;
    clone.callKitUUID = this.callKitUUID;
    clone.conferenceId = this.conferenceId;
    clone.peerIsRecording = this.peerIsRecording;
    clone.videoCodec = this.videoCodec;
    clone.peerHolding = this.peerHolding;
    clone.conversationId = this.conversationId;
    clone.joinsExistingCall = this.joinsExistingCall;
    clone.pendingInvites = this.pendingInvites.slice();
    return clone;
  }
}

/** Swift `struct ConferenceState`. */
export class ConferenceState {
  readonly id: ConfId;
  readonly accountId: string;

  /** libjami-confirmed media owned by the local conference host. */
  media: MediaItem[] = [];
  /** Host media re-invite awaiting MediaNegotiationStatus. */
  pendingMediaRequest: MediaItem[] | null = null;
  participants: ConferenceParticipantInfo[] = [];
  memberCallIds: Map<string, CallId> = new Map<string, CallId>();
  layout: ConferenceLayoutMode = ConferenceLayoutMode.GRID;
  isHost: boolean = false;
  lifecycle: ConferenceLifecycle = ConferenceLifecycle.UNKNOWN;
  conversationId: string | null = null;

  constructor(id: ConfId, accountId: string) {
    this.id = id;
    this.accountId = accountId;
  }

  get hasAttachedHost(): boolean {
    return this.lifecycle === ConferenceLifecycle.ACTIVE_ATTACHED;
  }

  get isAudioMuted(): boolean {
    return mediaIsAudioMuted(this.media);
  }

  get isVideoMuted(): boolean {
    return mediaIsVideoMuted(this.media);
  }

  get hasVideo(): boolean {
    return mediaHasVideo(this.media);
  }
}

/**
 * Swift `struct CallSystemState`. Swift keyed its dictionaries by `CallId`/`ConfId`; ArkTS Maps
 * key objects by reference, so the raw id string is the key.
 */
export class CallSystemState {
  calls: Map<string, CallState> = new Map<string, CallState>();
  conferences: Map<string, ConferenceState> = new Map<string, ConferenceState>();

  /** Every call not yet terminated - ringing and connecting included (the call screen's view). */
  get liveCalls(): CallState[] {
    const result: CallState[] = [];
    this.calls.forEach((call: CallState): void => {
      if (!call.status.isTerminal) {
        result.push(call);
      }
    });
    return result;
  }

  get ongoingCalls(): CallState[] {
    const result: CallState[] = [];
    this.calls.forEach((call: CallState): void => {
      if (call.status.isOngoing) {
        result.push(call);
      }
    });
    return result;
  }

  /** Swift `func call(_ id: CallId)`. */
  call(id: CallId): CallState | null {
    const found: CallState | undefined = this.calls.get(id.raw);
    return found === undefined ? null : found;
  }

  /** Swift `func call(withPeer:accountId:)`. */
  callWithPeer(peerHash: string, accountId: string): CallState | null {
    let found: CallState | null = null;
    this.calls.forEach((call: CallState): void => {
      if (found === null && call.accountId === accountId && !call.status.isTerminal
        && call.peerHash === peerHash) {
        found = call;
      }
    });
    return found;
  }
}

/** Swift `struct PendingPostCallSync`. */
export class PendingPostCallSync {
  readonly accountId: string;
  readonly peerHash: string;

  constructor(accountId: string, peerHash: string) {
    this.accountId = accountId;
    this.peerHash = peerHash;
  }

  /** Swift `func isConfirmed(by:from:)`. */
  isConfirmed(message: MessageModel, accountId: string): boolean {
    if (message.type !== MessageType.CALL) {
      return false;
    }
    return accountId === this.accountId && message.authorId === this.peerHash;
  }
}
