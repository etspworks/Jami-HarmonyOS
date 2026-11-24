/*
 * Ported from Ring/Ring/Models/Calls/CallStatus.swift:21-114 and the call-state half of
 * Ring/Ring/Models/Calls/LibJamiCallConstants.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The lifecycle status of a call. Swift modelled it as an enum with associated values
 * (`held(side:)`, `terminated(reason)`); ArkTS enums carry no payload, so the status is a
 * small value class over a kind plus its payload. Nothing here talks to the daemon - it maps
 * and validates the states the daemon reports.
 */

/** Swift `enum LibJamiCallState: String` - the `CALL_STATE` / `StateChange` values. */
export enum LibJamiCallState {
  INCOMING = 'INCOMING',
  CONNECTING = 'CONNECTING',
  RINGING = 'RINGING',
  CURRENT = 'CURRENT',
  HUNG_UP = 'HUNGUP',
  BUSY = 'BUSY',
  PEER_BUSY = 'PEER_BUSY',
  FAILURE = 'FAILURE',
  HOLD = 'HOLD',
  INACTIVE = 'INACTIVE',
  OVER = 'OVER'
}

/** Swift `LibJamiCallState.allCases`. */
export const ALL_LIB_JAMI_CALL_STATES: LibJamiCallState[] = [
  LibJamiCallState.INCOMING, LibJamiCallState.CONNECTING, LibJamiCallState.RINGING,
  LibJamiCallState.CURRENT, LibJamiCallState.HUNG_UP, LibJamiCallState.BUSY,
  LibJamiCallState.PEER_BUSY, LibJamiCallState.FAILURE, LibJamiCallState.HOLD,
  LibJamiCallState.INACTIVE, LibJamiCallState.OVER
];

/** Swift `LibJamiCallState(rawValue:)`. */
export function libJamiCallStateFromRaw(raw: string): LibJamiCallState | null {
  for (const state of ALL_LIB_JAMI_CALL_STATES) {
    if (String(state) === raw) {
      return state;
    }
  }
  return null;
}

/** Swift `enum HoldSide`. */
export enum HoldSide {
  LOCAL = 'LOCAL',
  PEER = 'PEER',
  BOTH = 'BOTH'
}

/** Swift `HoldSide.includesLocal`. */
export function holdSideIncludesLocal(side: HoldSide): boolean {
  return side !== HoldSide.PEER;
}

/** Swift `HoldSide.includesPeer`. */
export function holdSideIncludesPeer(side: HoldSide): boolean {
  return side !== HoldSide.LOCAL;
}

/** Swift `enum TerminationReason`. */
export enum TerminationReason {
  HUNG_UP = 'HUNG_UP',
  BUSY = 'BUSY',
  PEER_BUSY = 'PEER_BUSY',
  FAILURE = 'FAILURE',
  INACTIVE = 'INACTIVE',
  OVER = 'OVER',
  ENDED_LOCALLY = 'ENDED_LOCALLY'
}

/** Swift `enum CallIntent`. */
export enum CallIntent {
  ACCEPT = 'ACCEPT',
  REFUSE = 'REFUSE',
  HANG_UP = 'HANG_UP',
  HOLD = 'HOLD',
  RESUME = 'RESUME',
  CHANGE_MEDIA = 'CHANGE_MEDIA'
}

/** The cases of Swift's `enum CallStatus`. */
export enum CallStatusKind {
  INCOMING = 'INCOMING',
  CONNECTING = 'CONNECTING',
  RINGING = 'RINGING',
  CURRENT = 'CURRENT',
  HELD = 'HELD',
  TERMINATED = 'TERMINATED'
}

export class CallStatus {
  readonly kind: CallStatusKind;
  /** Set only for `HELD`. */
  readonly holdSide: HoldSide | null;
  /** Set only for `TERMINATED`. */
  readonly reason: TerminationReason | null;

  private constructor(kind: CallStatusKind, holdSide: HoldSide | null,
                      reason: TerminationReason | null) {
    this.kind = kind;
    this.holdSide = holdSide;
    this.reason = reason;
  }

  /** Swift `.incoming` / `.connecting` / `.ringing` / `.current`. */
  static incoming(): CallStatus {
    return new CallStatus(CallStatusKind.INCOMING, null, null);
  }

  static connecting(): CallStatus {
    return new CallStatus(CallStatusKind.CONNECTING, null, null);
  }

  static ringing(): CallStatus {
    return new CallStatus(CallStatusKind.RINGING, null, null);
  }

  static current(): CallStatus {
    return new CallStatus(CallStatusKind.CURRENT, null, null);
  }

  /** Swift `.held(side:)`. */
  static held(side: HoldSide): CallStatus {
    return new CallStatus(CallStatusKind.HELD, side, null);
  }

  /** Swift `.terminated(_:)`. */
  static terminated(reason: TerminationReason): CallStatus {
    return new CallStatus(CallStatusKind.TERMINATED, null, reason);
  }

  /** Swift `init(libJami:)`. */
  static fromLibJami(libJami: LibJamiCallState): CallStatus {
    switch (libJami) {
      case LibJamiCallState.INCOMING:
        return CallStatus.incoming();
      case LibJamiCallState.CONNECTING:
        return CallStatus.connecting();
      case LibJamiCallState.RINGING:
        return CallStatus.ringing();
      case LibJamiCallState.CURRENT:
        return CallStatus.current();
      case LibJamiCallState.HOLD:
        return CallStatus.held(HoldSide.LOCAL);
      case LibJamiCallState.HUNG_UP:
        return CallStatus.terminated(TerminationReason.HUNG_UP);
      case LibJamiCallState.BUSY:
        return CallStatus.terminated(TerminationReason.BUSY);
      case LibJamiCallState.PEER_BUSY:
        return CallStatus.terminated(TerminationReason.PEER_BUSY);
      case LibJamiCallState.FAILURE:
        return CallStatus.terminated(TerminationReason.FAILURE);
      case LibJamiCallState.INACTIVE:
        return CallStatus.terminated(TerminationReason.INACTIVE);
      default:
        return CallStatus.terminated(TerminationReason.OVER);
    }
  }

  /** Swift `var isTerminal: Bool`. */
  get isTerminal(): boolean {
    return this.kind === CallStatusKind.TERMINATED;
  }

  /** Swift `var isOngoing: Bool`. */
  get isOngoing(): boolean {
    return this.kind === CallStatusKind.CURRENT || this.kind === CallStatusKind.HELD;
  }

  /** Swift `Equatable` - the payload is part of the identity. */
  equals(other: CallStatus): boolean {
    return this.kind === other.kind && this.holdSide === other.holdSide
      && this.reason === other.reason;
  }

  /**
   * Swift `func canTransition(to:)`. Same status is a legal no-op, terminated is absorbing,
   * and a call may die from any live state.
   */
  canTransition(next: CallStatus): boolean {
    if (this.isTerminal) {
      return false;
    }
    if (next.equals(this)) {
      return true;
    }
    if (next.kind === CallStatusKind.TERMINATED) {
      return true;
    }
    if (this.kind === CallStatusKind.INCOMING) {
      return next.kind === CallStatusKind.CONNECTING || next.kind === CallStatusKind.RINGING
        || next.kind === CallStatusKind.CURRENT;
    }
    if (this.kind === CallStatusKind.CONNECTING) {
      return next.kind === CallStatusKind.RINGING || next.kind === CallStatusKind.CURRENT;
    }
    if (this.kind === CallStatusKind.RINGING) {
      return next.kind === CallStatusKind.CURRENT;
    }
    if (this.kind === CallStatusKind.CURRENT) {
      return next.kind === CallStatusKind.HELD;
    }
    if (this.kind === CallStatusKind.HELD) {
      return next.kind === CallStatusKind.CURRENT || next.kind === CallStatusKind.HELD;
    }
    return false;
  }

  /** Swift `func allows(_ intent:)`. */
  allows(intent: CallIntent): boolean {
    switch (intent) {
      case CallIntent.ACCEPT:
      case CallIntent.REFUSE:
        return this.kind === CallStatusKind.INCOMING;
      case CallIntent.HANG_UP:
        return !this.isTerminal;
      case CallIntent.HOLD:
        return this.kind === CallStatusKind.CURRENT;
      case CallIntent.RESUME:
        return this.kind === CallStatusKind.HELD && this.holdSide !== null
          && holdSideIncludesLocal(this.holdSide);
      default:
        return this.isOngoing;
    }
  }
}
