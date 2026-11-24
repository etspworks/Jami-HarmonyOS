/*
 * Ported from Ring/Ring/Services/NetworkService.swift:27-96 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * NOT A GAP - network reachability is a real HarmonyOS capability and this works for real.
 * Swift watched `NWPathMonitor`; the HarmonyOS equivalent is a `connection.NetConnection`
 * registered for `netAvailable` / `netLost` / `netUnavailable`
 * (`ohos.permission.GET_NETWORK_INFO`, already requested).
 *
 * THE BEHAVIOUR THAT MATTERS, carried over verbatim from the source's own comment: the FIRST
 * path evaluation is never reported as a connectivity CHANGE. Both monitors deliver the current
 * state as soon as they start, and that state is the one the daemon already registered with, so
 * reporting it as a change makes the daemon unregister and re-register for nothing - tearing
 * the DHT down and losing every in-flight peer connection attempt. Hence two streams:
 *   `connectionState`    - the current state, replayed to every new subscriber (initial included);
 *   `connectivityChanges`- real transitions only, never the first evaluation.
 *
 * NOT CARRIED OVER: `Ring/Ring/Helpers/DeviceOrientationMonitor.swift` is listed among this
 * module's source files because both are "watch an OS signal" helpers, but it contributes no
 * member of this contract - it is device/interface orientation, which `common/VideoService.ts`
 * already handles for the camera. Nothing from it is duplicated here.
 */
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { BehaviorRelay, PublishSubject } from './Observable';
import { describeError } from './ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'NetworkService';

/** Swift `enum ConnectionType` (NetworkService.swift:27-30). */
export enum ConnectionType {
  NONE = 'NONE',
  CONNECTED = 'CONNECTED'
}

/**
 * Swift `NWPath.Status`, reduced to the two cases `handle(status:)` actually acts on
 * (`.satisfied` -> connected; `.unsatisfied`/`.requiresConnection` -> none). HarmonyOS reports
 * the same two through separate callbacks rather than one status value.
 */
export enum NetworkStatus {
  SATISFIED = 'SATISFIED',
  UNSATISFIED = 'UNSATISFIED'
}

export class NetworkService {
  /** Swift `var connectionState = BehaviorRelay<ConnectionType>(value: .none)`. */
  readonly connectionState: BehaviorRelay<ConnectionType> =
    new BehaviorRelay<ConnectionType>(ConnectionType.NONE);

  /**
   * Swift `private let connectivityChanges = PublishRelay<ConnectionType>()` - real transitions
   * only. A PublishSubject is exactly a PublishRelay here: multicast, no replay.
   */
  private readonly connectivityChanges: PublishSubject<ConnectionType> =
    new PublishSubject<ConnectionType>();

  /** Swift `private var monitor: NWPathMonitor?`. */
  private monitor: connection.NetConnection | null = null;

  /** Swift `private var lastStatus: NWPath.Status?` - null until the first evaluation arrives. */
  private lastStatus: NetworkStatus | null = null;

  /** Swift `lazy var connectionStateObservable` - `connectionState.asObservable()`. */
  get connectionStateObservable(): BehaviorRelay<ConnectionType> {
    return this.connectionState;
  }

  /** Swift `lazy var connectivityChangedObservable` - `connectivityChanges.asObservable()`. */
  get connectivityChangedObservable(): PublishSubject<ConnectionType> {
    return this.connectivityChanges;
  }

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /**
   * Swift `func monitorNetworkType()` - `monitor.pathUpdateHandler = ...; monitor.start(queue:)`.
   * Idempotent: a second call while already monitoring is ignored rather than leaking a second
   * registration (Swift's re-assignment of the handler was harmless; a second `register()` is not).
   */
  monitorNetworkType(): void {
    if (this.monitor !== null) {
      return;
    }
    const monitor: connection.NetConnection = connection.createNetConnection();
    this.monitor = monitor;
    monitor.on('netAvailable', () => {
      this.handle(NetworkStatus.SATISFIED);
    });
    monitor.on('netLost', () => {
      this.handle(NetworkStatus.UNSATISFIED);
    });
    monitor.on('netUnavailable', () => {
      this.handle(NetworkStatus.UNSATISFIED);
    });

    // EAGER first evaluation, before `register()`. `register()`'s own first callback is tens of
    // milliseconds away, and until it lands `connectionState` still reads its NONE default - the
    // first paint of every connectivity-branching screen would show the DISCONNECTED variant and
    // the "no network" banner on a perfectly connected device. `hasDefaultNetSync()` is the same
    // `ohos.permission.GET_NETWORK_INFO` this monitor already needs. It is the FIRST path
    // (`lastStatus === null`), so it is never reported as a CHANGE, and the monitor's matching
    // first callback is swallowed by `handle`'s same-status guard.
    try {
      this.handle(connection.hasDefaultNetSync()
        ? NetworkStatus.SATISFIED : NetworkStatus.UNSATISFIED);
    } catch (error) {
      this.log('initial network state unreadable: ' + describeError(error as BusinessError));
    }

    monitor.register((error: BusinessError) => {
      if (error !== undefined && error !== null) {
        this.log('monitorNetworkType: ' + describeError(error));
      }
    });
  }

  /**
   * Swift `func handle(status: NWPath.Status)`. Public in the source and public here: it is what
   * the monitor drives, and the only way to test the transition rule without a device radio.
   */
  handle(status: NetworkStatus): void {
    const isInitialPath: boolean = this.lastStatus === null;
    if (this.lastStatus === status) {
      return;
    }
    this.lastStatus = status;

    const state: ConnectionType =
      status === NetworkStatus.SATISFIED ? ConnectionType.CONNECTED : ConnectionType.NONE;
    this.log(status === NetworkStatus.SATISFIED
      ? 'Connected to a network' : 'Disconnected from a network');

    this.connectionState.accept(state);
    if (!isInitialPath) {
      // PublishSubject.onNext IS PublishRelay.accept - multicast, no replay (common/Observable.ts).
      this.connectivityChanges.onNext(state);
    }
  }

  /**
   * No Swift counterpart (`NWPathMonitor` was released with the service). A registered
   * NetConnection is a held OS resource, so the ability releases it on destroy.
   */
  dispose(): void {
    const monitor: connection.NetConnection | null = this.monitor;
    if (monitor === null) {
      return;
    }
    try {
      monitor.unregister((error: BusinessError) => {
        if (error !== undefined && error !== null) {
          this.log('dispose: ' + describeError(error));
        }
      });
    } finally {
      this.monitor = null;
      this.lastStatus = null;
    }
  }
}
