/*
 * Ported from Ring/Ring/Services/DaemonService.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * GAP - NOT A PORT. The iOS DaemonService is a thin shell over `DRingAdapter`
 * (Ring/Ring/Bridging/DRingAdapter.mm), which calls into the prebuilt C++ jami daemon
 * (`xcframework/libjami-core.xcframework` + ~45 native frameworks: OpenDHT, PJSIP, FFmpeg,
 * libgit2, libyrs, codecs). None of that has source on disk in this repository, so there is
 * nothing to port and Rule 11 forbids writing it from memory, stubbing it with fake success,
 * or bridging to it through a sidecar/NDK/wasm shim.
 *
 * What this module therefore is: the honest daemon surface. Every daemon-backed capability
 * (accounts, calls, messaging, swarm, DHT, presence, file transfer, collaborative documents)
 * resolves through here to a `DaemonUnavailableError`, which a caller renders as an explicit
 * "not available on this platform" notice. `daemonStarted` is false for the life of the app.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PublishSubject } from './Observable';
import { jami, startJami } from './JamiNative';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'DaemonService';

/** The single reason code every daemon-backed gap carries. */
export const DAEMON_UNAVAILABLE_REASON: string = 'DAEMON_NATIVE_LIBRARY_ABSENT';

/**
 * Fallback English text. The app has no `daemon_not_available` string resource yet - a .ts
 * module cannot call `getContext()`, and adding a resource is an orchestrator-serial edit -
 * so a caller that wants localized text resolves `messageResource` itself and falls back to
 * `message`.
 */
const DAEMON_UNAVAILABLE_TEXT: string =
  'This feature needs the Jami daemon, which is not available on this platform.';

/** Resource name a UI layer may resolve once the string is added; see the note above. */
export const DAEMON_UNAVAILABLE_RESOURCE: string = 'daemon_not_available';

/**
 * One shape, usable two ways: `throw`/reject it from an async service method, or hand it to
 * the UI as the notice to render. Never a silent no-op and never a faked success.
 */
export class DaemonUnavailableError extends Error {
  /** The capability the caller asked for, e.g. `'account.create'`, `'call.place'`. */
  readonly feature: string;
  readonly reason: string = DAEMON_UNAVAILABLE_REASON;
  /** Resource name for the localized notice, when the app carries one. */
  readonly messageResource: string = DAEMON_UNAVAILABLE_RESOURCE;

  constructor(feature: string) {
    super(DAEMON_UNAVAILABLE_TEXT);
    this.name = 'DaemonUnavailableError';
    this.feature = feature;
  }
}

/**
 * The daemon surface. Method-for-method with the Swift class; every one reports unavailable.
 */
export class DaemonService {
  /**
   * App-wide channel of gaps hit at runtime, so a screen can surface the notice without every
   * call site wiring its own catch. Fed by `reportUnavailable`.
   */
  readonly unavailableEvents: PublishSubject<DaemonUnavailableError> =
    new PublishSubject<DaemonUnavailableError>();

  /** Swift `internal private(set) var daemonStarted`. Never becomes true: there is no daemon. */
  private started: boolean = false;

  get daemonStarted(): boolean {
    return this.started;
  }

  /**
   * Swift `dRingAdaptor: DRingAdapter` - the C++ bridge. It has no HarmonyOS counterpart, so
   * the field is replaced by this factory, which every daemon-backed service in `common/`
   * calls instead of inventing its own unavailable shape.
   */
  unavailable(feature: string): DaemonUnavailableError {
    return new DaemonUnavailableError(feature);
  }

  /** Build the gap, log it, publish it, and hand it back for the caller to throw or render. */
  reportUnavailable(feature: string): DaemonUnavailableError {
    const error: DaemonUnavailableError = new DaemonUnavailableError(feature);
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'daemon unavailable for %{public}s', feature);
    this.unavailableEvents.onNext(error);
    return error;
  }

  /**
   * Swift `startDaemon() throws`. Returns the gap instead of throwing: this runs during app
   * bootstrap, where a throw would take the whole app down rather than leave it running with
   * the daemon-backed screens showing their notice.
   */
  startDaemon(filesDir: string): boolean {
    if (!this.started) {
      this.started = startJami(filesDir);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'daemon started: %{public}s', String(this.started));
    }
    return this.started;
  }

  /** Swift `stopDaemon() throws`. Nothing was started, so this reports rather than stopping. */
  stopDaemon(): DaemonUnavailableError {
    this.started = false;
    return this.reportUnavailable('daemon.stop');
  }

  /**
   * Swift forwarded this to `dRingAdaptor.connectivityChanged()`: libjami re-checks every peer
   * channel, re-bootstraps the DHT and reconnects each swarm. Raises no user-facing notice,
   * because a network change is not something the user asked for.
   */
  connectivityChanged(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'connectivityChanged (daemon started: %{public}s)',
      String(this.started));
    if (this.started) {
      jami.connectivityChanged();
    }
  }
}
