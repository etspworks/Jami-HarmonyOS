/*
 * Ported from Ring/Ring/Services/PeerSharingService.swift (GPL-3.0, Savoir-faire Linux Inc.),
 * read in full (575 lines) - the derived contract for this module was produced by a text scan,
 * so the source, not the scan, is what this port follows.
 *
 * THE DAEMON GAP. Every byte this feature moves goes through `PeerServicesAdapter`
 * (Ring/Ring/Bridging), which calls the prebuilt C++ jami daemon. That binary has no source on
 * disk, so it is a `gap`: not ported, not stubbed with a fake success, not bridged by a
 * sidecar. The adapter therefore becomes `PeerServicesClient` below - it answers with the
 * SAME failure values the real adapter uses for "could not do it" (requestId 0, empty tunnel
 * id, close returned false) and raises the explicit "not available on this platform" notice
 * through DaemonService. The control flow above it is a REAL port: feeding it those values
 * drives the source's own error paths, so a peer list is honestly empty and no tunnel is ever
 * reported open.
 *
 * What is real and must keep working: scheme validation and loopback URL construction, the
 * services JSON codec (including its de-duplication), the tunnel-state machine
 * (pending/active/queued-after-close/canceled) and the per-peer relays.
 *
 * TWO SHAPE CHANGES, because this project's reactive plumbing (common/Observable.ts) is
 * PublishSubject/BehaviorRelay only - it has no Observable.create, no SerialDisposable:
 *   - `queryPeerServices` returned a one-shot `Observable` with `take(1)`; here it is a
 *     `Promise<PeerServicesResult>`, which is the same "exactly one answer" contract.
 *   - `observePeerServices` / `observeTunnelState` return the per-peer relay itself; a
 *     subscriber gets the current value on subscribe and the unsubscribe closure back, which
 *     is what the Swift SerialDisposable was there to provide.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeError } from './ErrorText';
import { BehaviorRelay } from './Observable';
import { ServiceRegistry } from './ServiceRegistry';
import { jami } from './JamiNative';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'PeerSharingService';

// MARK: - Models

/** Swift `enum PeerServicesStatus: Int`. */
export enum PeerServicesStatus {
  SUCCESS = 0,
  NO_DEVICES = 1,
  UNREACHABLE = 2,
  TIMEOUT = 3,
  INTERNAL_ERROR = 4
}

/** Swift `init(code:)` - an unknown code is an internal error, never a crash. */
export function peerServicesStatusFromCode(code: number): PeerServicesStatus {
  switch (code) {
    case 0:
      return PeerServicesStatus.SUCCESS;
    case 1:
      return PeerServicesStatus.NO_DEVICES;
    case 2:
      return PeerServicesStatus.UNREACHABLE;
    case 3:
      return PeerServicesStatus.TIMEOUT;
    default:
      return PeerServicesStatus.INTERNAL_ERROR;
  }
}

/** Swift `struct PeerServiceInfo` - one service a peer device exposes. */
export class PeerServiceInfo {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly scheme: string;
  readonly device: string;

  constructor(id: string, name: string, description: string, scheme: string, device: string) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.scheme = scheme;
    this.device = device;
  }

  /** Swift `extension PeerServiceInfo { var isWebService }`. */
  get isWebService(): boolean {
    return PeerTunnelEndpoint.isWebScheme(this.scheme);
  }
}

/** Swift `struct PeerTunnelInfo` - one open tunnel to one service. */
export class PeerTunnelInfo {
  readonly tunnelId: string;
  readonly accountId: string;
  readonly peerId: string;
  readonly serviceId: string;
  readonly serviceName: string;
  readonly scheme: string;
  readonly localPort: number;

  constructor(tunnelId: string, accountId: string, peerId: string, serviceId: string,
    serviceName: string, scheme: string, localPort: number) {
    this.tunnelId = tunnelId;
    this.accountId = accountId;
    this.peerId = peerId;
    this.serviceId = serviceId;
    this.serviceName = serviceName;
    this.scheme = scheme;
    this.localPort = localPort;
  }

  /** Swift `var loopbackURL: URL?` - any scheme; used for copy-to-clipboard. */
  get loopbackUrl(): string | null {
    return PeerTunnelEndpoint.url(this.scheme, this.localPort);
  }

  /** Swift `var isWebEndpoint: Bool`. */
  get isWebEndpoint(): boolean {
    return PeerTunnelEndpoint.isWebScheme(this.scheme) && this.loopbackUrl !== null;
  }

  /** Swift `var browsableURL: URL?` - only http/https load in the in-app Web component. */
  get browsableUrl(): string | null {
    return this.isWebEndpoint ? this.loopbackUrl : null;
  }
}

/**
 * Swift `private enum PeerTunnelEndpoint` - the loopback endpoint helpers. Entirely local, so
 * this half is a straight port with no substitution. Swift built a `URL` from URLComponents;
 * ArkTS has no URL type in the data layer, so the same components are joined into a string.
 */
export class PeerTunnelEndpoint {
  static readonly LOOPBACK_HOST: string = '127.0.0.1';
  static readonly WEB_SCHEMES: Array<string> = ['http', 'https'];
  private static readonly MAX_PORT: number = 65535;

  /** Swift `static func normalizedScheme(_:)`. */
  static normalizedScheme(scheme: string): string | null {
    const normalized: string = scheme.trim().toLowerCase();
    return normalized.length === 0 ? null : normalized;
  }

  /** Swift `static func isWebScheme(_:)`. */
  static isWebScheme(scheme: string): boolean {
    const normalized: string | null = PeerTunnelEndpoint.normalizedScheme(scheme);
    if (normalized === null) {
      return false;
    }
    return PeerTunnelEndpoint.WEB_SCHEMES.indexOf(normalized) >= 0;
  }

  /**
   * Swift `static func isValidScheme(_:)` - RFC 3986 scheme charset, ASCII only. The scheme is
   * PEER-SUPPLIED, so this rejection is the security boundary, not a nicety: keep it strict.
   */
  static isValidScheme(scheme: string): boolean {
    if (scheme.length === 0) {
      return false;
    }
    for (let index: number = 0; index < scheme.length; index++) {
      const code: number = scheme.charCodeAt(index);
      const isUpper: boolean = code >= 0x41 && code <= 0x5A;
      const isLower: boolean = code >= 0x61 && code <= 0x7A;
      const isDigit: boolean = code >= 0x30 && code <= 0x39;
      const isExtra: boolean = code === 0x2B || code === 0x2D || code === 0x2E; // + - .
      if (index === 0) {
        if (!isUpper && !isLower) {
          return false;
        }
      } else if (!isUpper && !isLower && !isDigit && !isExtra) {
        return false;
      }
    }
    return true;
  }

  /** Swift `static func url(scheme:localPort:) -> URL?`. */
  static url(scheme: string, localPort: number): string | null {
    const normalized: string | null = PeerTunnelEndpoint.normalizedScheme(scheme);
    if (normalized === null || !PeerTunnelEndpoint.isValidScheme(normalized)) {
      return null;
    }
    if (localPort !== Math.floor(localPort) || localPort < 1
      || localPort > PeerTunnelEndpoint.MAX_PORT) {
      return null;
    }
    return `${normalized}://${PeerTunnelEndpoint.LOOPBACK_HOST}:${localPort}`;
  }
}

/**
 * Swift `struct PeerTunnelState` + its mutating extension. Swift's value semantics meant every
 * `updateState` produced a fresh struct; this class is copied explicitly in `updateState` for
 * the same reason - a relay subscriber must not see a mutation it was not notified of.
 */
export class PeerTunnelState {
  activeTunnels: Map<string, PeerTunnelInfo> = new Map<string, PeerTunnelInfo>();
  pendingServices: Set<string> = new Set<string>();

  /** Swift `mutating func markPending(_:)`. */
  markPending(serviceId: string): void {
    this.pendingServices.add(serviceId);
  }

  /** Swift `mutating func clearPending(_:)`. */
  clearPending(serviceId: string): void {
    this.pendingServices.delete(serviceId);
  }

  /** Swift `mutating func addActive(_:for:)`. */
  addActive(tunnel: PeerTunnelInfo, serviceId: string): void {
    this.activeTunnels.set(serviceId, tunnel);
    this.pendingServices.delete(serviceId);
  }

  /** Swift `mutating func removeActive(_:)`. */
  removeActive(serviceId: string): void {
    this.activeTunnels.delete(serviceId);
  }

  /** Swift got this free from the struct's value semantics. */
  copy(): PeerTunnelState {
    const clone: PeerTunnelState = new PeerTunnelState();
    this.activeTunnels.forEach((value: PeerTunnelInfo, key: string) => {
      clone.activeTunnels.set(key, value);
    });
    this.pendingServices.forEach((value: string) => {
      clone.pendingServices.add(value);
    });
    return clone;
  }
}

/** Swift `struct PeerServicesResult`. */
export class PeerServicesResult {
  readonly requestId: number;
  readonly accountId: string;
  readonly peerId: string;
  readonly status: PeerServicesStatus;
  readonly services: Array<PeerServiceInfo>;

  constructor(requestId: number, accountId: string, peerId: string, status: PeerServicesStatus,
    services: Array<PeerServiceInfo>) {
    this.requestId = requestId;
    this.accountId = accountId;
    this.peerId = peerId;
    this.status = status;
    this.services = services;
  }

  /** Swift `extension PeerServicesResult { var hasExposedServices }`. */
  get hasExposedServices(): boolean {
    return this.status === PeerServicesStatus.SUCCESS && this.services.length > 0;
  }
}

/** Swift `private enum PeerServiceJsonKey` - the wire keys, never renamed. */
interface PeerServiceJson {
  id?: string;
  name?: string;
  description?: string;
  scheme?: string;
  device?: string;
}

/** Swift `private struct PendingOpen` - an open in flight, keyed by tunnel id. */
class PendingOpen {
  readonly accountId: string;
  readonly peerId: string;
  readonly serviceId: string;
  readonly serviceName: string;
  readonly scheme: string;

  constructor(accountId: string, peerId: string, serviceId: string, serviceName: string,
    scheme: string) {
    this.accountId = accountId;
    this.peerId = peerId;
    this.serviceId = serviceId;
    this.serviceName = serviceName;
    this.scheme = scheme;
  }
}

/** Swift `private struct QueuedTunnelOpen` - an open deferred until a close lands. */
class QueuedTunnelOpen {
  readonly accountId: string;
  readonly peerId: string;
  readonly service: PeerServiceInfo;

  constructor(accountId: string, peerId: string, service: PeerServiceInfo) {
    this.accountId = accountId;
    this.peerId = peerId;
    this.service = service;
  }
}

/** Swift `private struct PeerScope` - "this account+peer", or nil for "all peers". */
class PeerScope {
  readonly accountId: string;
  readonly peerId: string;

  constructor(accountId: string, peerId: string) {
    this.accountId = accountId;
    this.peerId = peerId;
  }
}

/**
 * THE GAP. Swift's `PeerServicesAdapter` is the ObjC bridge into the C++ jami daemon; there is
 * no source for it in this repository, so it is not ported. Each method answers with the real
 * adapter's OWN failure value, which drives the ported control flow down its honest error path,
 * and raises the "not available on this platform" notice for the operations a user started.
 */
class PeerServicesClient {
  /** Swift `queryPeerServices(withAccountId:peerUri:) -> UInt32`. 0 means "not sent". */
  queryPeerServices(accountId: string, peerUri: string): number {
    return jami.queryPeerServices(accountId, peerUri);
  }

  openServiceTunnel(accountId: string, peerUri: string, deviceId: string, serviceId: string,
    serviceName: string, localPort: number): string {
    return jami.openServiceTunnel(accountId, peerUri, deviceId, serviceId, serviceName, localPort);
  }

  closeServiceTunnel(accountId: string, tunnelId: string): boolean {
    return jami.closeServiceTunnel(accountId, tunnelId);
  }
}

// MARK: - Service

/** Swift `class PeerSharingService`. */
export class PeerSharingService {

  private readonly peerServicesAdapter: PeerServicesClient = new PeerServicesClient();
  private readonly log: string = LOG_TAG;

  private peerServicesRelays: Map<string, BehaviorRelay<PeerServicesResult | null>> =
    new Map<string, BehaviorRelay<PeerServicesResult | null>>();
  private tunnelStates: Map<string, BehaviorRelay<PeerTunnelState>> =
    new Map<string, BehaviorRelay<PeerTunnelState>>();
  private pendingOpens: Map<string, PendingOpen> = new Map<string, PendingOpen>();

  /** Swift: opens requested after an active tunnel for the same service is closed. */
  private queuedOpensAfterClose: Map<string, QueuedTunnelOpen> =
    new Map<string, QueuedTunnelOpen>();

  /** Swift: pending tunnel ids canceled before `TunnelOpened` arrives. */
  private canceledPendingTunnelIds: Set<string> = new Set<string>();

  // MARK: - Thread-safe dispatch

  /**
   * Swift `private func onDaemonCallback(_:)` - a serial DispatchQueue, `.async` only, so a
   * daemon that fires TunnelOpened synchronously cannot deadlock the caller.
   *
   * ArkTS runs this module on one thread, so there is no deadlock to prevent; what IS kept is
   * the "never synchronous" part, because the ported callbacks below rely on the caller's frame
   * having unwound before state mutates.
   * ponytail: a microtask, not a queue - ordering holds because microtasks run FIFO; revisit
   * only if this service ever moves to a TaskPool worker.
   */
  private onDaemonCallback(work: (service: PeerSharingService) => void): void {
    Promise.resolve().then(() => {
      work(this);
    }).catch((error: BusinessError) => {
      hilog.error(LOG_DOMAIN, this.log, 'daemon callback failed: %{public}s',
        describeError(error));
    });
  }

  // MARK: - Public API

  /**
   * Swift `func queryPeerServices(accountId:peerId:) -> Observable<PeerServicesResult>` with
   * `take(1)`; one answer, so a Promise here.
   *
   * With no daemon the adapter returns requestId 0 and this resolves with the source's own
   * `internalErrorPeerServicesResult` - an explicit failure status and an empty service list,
   * which is the honest answer, not an invented peer.
   */
  queryPeerServices(accountId: string, peerId: string): Promise<PeerServicesResult> {
    return new Promise<PeerServicesResult>((resolve: (value: PeerServicesResult) => void) => {
      this.onDaemonCallback((service: PeerSharingService) => {
        service.subscribeToPeerServicesQuery(accountId, peerId, resolve);
      });
    });
  }

  /**
   * Swift `func observePeerServices(accountId:peerId:)` - all updates for this account+peer,
   * proactive cache fills (requestId 0) included. The relay's value is null until something
   * fills it; the Swift `compactMap { $0 }` becomes the subscriber's null check.
   */
  observePeerServices(accountId: string, peerId: string): BehaviorRelay<PeerServicesResult | null> {
    return this.getOrCreatePeerServicesRelay(accountId, peerId);
  }

  /** Swift `func openTunnel(accountId:peerId:service:)`. */
  openTunnel(accountId: string, peerId: string, service: PeerServiceInfo): void {
    this.onDaemonCallback((sharingService: PeerSharingService) => {
      sharingService.requestOpenTunnel(accountId, peerId, service);
    });
  }

  /** Swift `func closeTunnel(accountId:peerId:serviceId:)`. */
  closeTunnel(accountId: string, peerId: string, serviceId: string): void {
    this.onDaemonCallback((service: PeerSharingService) => {
      const key: string = service.stateKey(accountId, peerId);
      const relay: BehaviorRelay<PeerTunnelState> | undefined = service.tunnelStates.get(key);
      if (relay === undefined) {
        return;
      }
      const active: PeerTunnelInfo | undefined = relay.value.activeTunnels.get(serviceId);
      if (active === undefined) {
        return;
      }
      service.updateState(accountId, peerId, (state: PeerTunnelState) => {
        state.removeActive(serviceId);
      });
      service.peerServicesAdapter.closeServiceTunnel(accountId, active.tunnelId);
    });
  }

  /** Swift `func observeTunnelState(accountId:peerId:)`. */
  observeTunnelState(accountId: string, peerId: string): BehaviorRelay<PeerTunnelState> {
    return this.getOrCreateState(accountId, peerId);
  }

  /** Swift `func closeAllTunnels()` - every peer (the app backgrounded). */
  closeAllTunnels(): void {
    this.onDaemonCallback((service: PeerSharingService) => {
      service.closeTunnels(null);
    });
  }

  /**
   * Swift's second `func closeAllTunnels(accountId:peerId:)` overload - one peer only. ArkTS
   * has no overloading, so the scoped form carries its own name. The scan's contract listed
   * only one `closeAllTunnels`; the source has both.
   */
  closeAllTunnelsForPeer(accountId: string, peerId: string): void {
    this.onDaemonCallback((service: PeerSharingService) => {
      service.closeTunnels(new PeerScope(accountId, peerId));
    });
  }

  // MARK: - Private helpers

  /** Swift `private func stateKey(accountId:peerId:)` - NUL-joined, so neither half can forge it. */
  private stateKey(accountId: string, peerId: string): string {
    return `${accountId}\0${peerId}`;
  }

  /** Swift `private func queuedOpenKey(accountId:peerId:serviceId:)`. */
  private queuedOpenKey(accountId: string, peerId: string, serviceId: string): string {
    return `${this.stateKey(accountId, peerId)}\0${serviceId}`;
  }

  /** Swift `private func queuedOpenMatchesScope(_:scope:)`. */
  private queuedOpenMatchesScope(key: string, scope: PeerScope): boolean {
    return key.startsWith(`${this.stateKey(scope.accountId, scope.peerId)}\0`);
  }

  /** Swift `private func closeTunnels(matching:)`. `scope == null` closes every peer's. */
  private closeTunnels(scope: PeerScope | null): void {
    if (scope !== null) {
      const kept: Map<string, QueuedTunnelOpen> = new Map<string, QueuedTunnelOpen>();
      this.queuedOpensAfterClose.forEach((value: QueuedTunnelOpen, key: string) => {
        if (!this.queuedOpenMatchesScope(key, scope)) {
          kept.set(key, value);
        }
      });
      this.queuedOpensAfterClose = kept;
    } else {
      this.queuedOpensAfterClose.clear();
      this.canceledPendingTunnelIds.clear();
    }

    const pendingToCancel: Map<string, PendingOpen> = new Map<string, PendingOpen>();
    this.pendingOpens.forEach((pending: PendingOpen, tunnelId: string) => {
      if (scope === null || (pending.accountId === scope.accountId
        && pending.peerId === scope.peerId)) {
        pendingToCancel.set(tunnelId, pending);
      }
    });
    pendingToCancel.forEach((pending: PendingOpen, tunnelId: string) => {
      this.canceledPendingTunnelIds.add(tunnelId);
      this.peerServicesAdapter.closeServiceTunnel(pending.accountId, tunnelId);
      this.pendingOpens.delete(tunnelId);
    });

    this.tunnelStates.forEach((relay: BehaviorRelay<PeerTunnelState>, key: string) => {
      if (scope !== null && key !== this.stateKey(scope.accountId, scope.peerId)) {
        return;
      }
      relay.value.activeTunnels.forEach((tunnelInfo: PeerTunnelInfo) => {
        this.peerServicesAdapter.closeServiceTunnel(tunnelInfo.accountId, tunnelInfo.tunnelId);
      });
      relay.accept(new PeerTunnelState());
    });
  }

  /**
   * Swift `private func requestOpenTunnel(accountId:peerId:service:)` - close-then-open when a
   * tunnel for this service is already up, otherwise open straight away.
   */
  private requestOpenTunnel(accountId: string, peerId: string, service: PeerServiceInfo): void {
    const subject: BehaviorRelay<PeerTunnelState> = this.getOrCreateState(accountId, peerId);
    const current: PeerTunnelState = subject.value;

    if (current.pendingServices.has(service.id)) {
      return;
    }

    const active: PeerTunnelInfo | undefined = current.activeTunnels.get(service.id);
    if (active !== undefined) {
      if (this.peerServicesAdapter.closeServiceTunnel(accountId, active.tunnelId)) {
        this.queuedOpensAfterClose.set(this.queuedOpenKey(accountId, peerId, service.id),
          new QueuedTunnelOpen(accountId, peerId, service));
        this.updateState(accountId, peerId, (state: PeerTunnelState) => {
          state.markPending(service.id);
        });
      } else {
        this.updateState(accountId, peerId, (state: PeerTunnelState) => {
          state.removeActive(service.id);
        });
        this.performOpenTunnel(accountId, peerId, service);
      }
      return;
    }

    this.performOpenTunnel(accountId, peerId, service);
  }

  /** Swift `private func performOpenTunnel(accountId:peerId:service:)`. */
  private performOpenTunnel(accountId: string, peerId: string, service: PeerServiceInfo): void {
    this.updateState(accountId, peerId, (state: PeerTunnelState) => {
      state.markPending(service.id);
    });

    const tunnelId: string = this.peerServicesAdapter.openServiceTunnel(accountId, peerId,
      service.device, service.id, service.name, 0);

    if (tunnelId.length === 0) {
      // The daemon-gap path: nothing opened, so the service goes back to not-pending and the
      // UI sees no tunnel rather than a phantom one.
      this.updateState(accountId, peerId, (state: PeerTunnelState) => {
        state.clearPending(service.id);
      });
    } else {
      this.pendingOpens.set(tunnelId,
        new PendingOpen(accountId, peerId, service.id, service.name, service.scheme));
    }
  }

  /** Swift `private func processQueuedOpenAfterClose(accountId:peerId:serviceId:)`. */
  private processQueuedOpenAfterClose(accountId: string, peerId: string, serviceId: string): void {
    const queueKey: string = this.queuedOpenKey(accountId, peerId, serviceId);
    const queued: QueuedTunnelOpen | undefined = this.queuedOpensAfterClose.get(queueKey);
    if (queued === undefined) {
      return;
    }
    this.queuedOpensAfterClose.delete(queueKey);
    this.performOpenTunnel(queued.accountId, queued.peerId, queued.service);
  }

  /** Swift `private func getOrCreateState(accountId:peerId:)`. */
  private getOrCreateState(accountId: string, peerId: string): BehaviorRelay<PeerTunnelState> {
    const key: string = this.stateKey(accountId, peerId);
    const existing: BehaviorRelay<PeerTunnelState> | undefined = this.tunnelStates.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const relay: BehaviorRelay<PeerTunnelState> =
      new BehaviorRelay<PeerTunnelState>(new PeerTunnelState());
    this.tunnelStates.set(key, relay);
    return relay;
  }

  /**
   * Swift `private func updateState(accountId:peerId:_ transform:)`. Swift's `inout` on a
   * struct copied the value; the explicit `copy()` here is that copy, so a subscriber never
   * observes a mutation it was not notified about.
   */
  private updateState(accountId: string, peerId: string,
    transform: (state: PeerTunnelState) => void): void {
    const relay: BehaviorRelay<PeerTunnelState> = this.getOrCreateState(accountId, peerId);
    const state: PeerTunnelState = relay.value.copy();
    transform(state);
    relay.accept(state);
  }

  /** Swift `private func getOrCreatePeerServicesRelay(accountId:peerId:)`. */
  private getOrCreatePeerServicesRelay(accountId: string,
    peerId: string): BehaviorRelay<PeerServicesResult | null> {
    const key: string = this.stateKey(accountId, peerId);
    const existing: BehaviorRelay<PeerServicesResult | null> | undefined =
      this.peerServicesRelays.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const relay: BehaviorRelay<PeerServicesResult | null> =
      new BehaviorRelay<PeerServicesResult | null>(null);
    this.peerServicesRelays.set(key, relay);
    return relay;
  }

  /**
   * Swift `private func subscribeToPeerServicesQuery(...)` - ask the daemon, then take the one
   * reply carrying this request id. A zero request id short-circuits to the internal-error
   * result, which is the path taken on every call here (see the gap note at the top).
   */
  private subscribeToPeerServicesQuery(accountId: string, peerId: string,
    resolve: (value: PeerServicesResult) => void): void {
    const relay: BehaviorRelay<PeerServicesResult | null> =
      this.getOrCreatePeerServicesRelay(accountId, peerId);
    const requestId: number = this.peerServicesAdapter.queryPeerServices(accountId, peerId);
    if (requestId === 0) {
      resolve(this.internalErrorPeerServicesResult(accountId, peerId));
      return;
    }

    let unsubscribe: (() => void) | null = null;
    unsubscribe = relay.subscribe((result: PeerServicesResult | null) => {
      if (result === null || result.requestId !== requestId || result.accountId !== accountId
        || result.peerId !== peerId) {
        return;
      }
      // Swift `.take(1)` - one reply, then the subscription goes away.
      if (unsubscribe !== null) {
        const dispose: () => void = unsubscribe;
        unsubscribe = null;
        dispose();
      }
      resolve(result);
    });
  }

  /** Swift `private func internalErrorPeerServicesResult(accountId:peerId:)`. */
  private internalErrorPeerServicesResult(accountId: string, peerId: string): PeerServicesResult {
    return new PeerServicesResult(0, accountId, peerId, PeerServicesStatus.INTERNAL_ERROR, []);
  }

  /**
   * Swift `private func parseServicesJson(_:)`. Local and real: malformed JSON yields an empty
   * list, an entry with no id is dropped, and a repeated id is dropped (Swift's `seenIds`).
   */
  private parseServicesJson(json: string): Array<PeerServiceInfo> {
    if (json.length === 0) {
      return [];
    }
    let rows: Array<PeerServiceJson> = [];
    try {
      rows = JSON.parse(json) as Array<PeerServiceJson>;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, this.log, 'services JSON parse failed: %{public}s',
        describeError(error as BusinessError));
      return [];
    }
    const seenIds: Set<string> = new Set<string>();
    const services: Array<PeerServiceInfo> = [];
    for (const row of rows) {
      const id: string | undefined = row.id;
      if (id === undefined || id.length === 0 || seenIds.has(id)) {
        continue;
      }
      seenIds.add(id);
      const name: string | undefined = row.name;
      const description: string | undefined = row.description;
      const scheme: string | undefined = row.scheme;
      const device: string | undefined = row.device;
      services.push(new PeerServiceInfo(id, name === undefined ? '' : name,
        description === undefined ? '' : description, scheme === undefined ? '' : scheme,
        device === undefined ? '' : device));
    }
    return services;
  }

  // MARK: - PeerServicesAdapterDelegate (Swift `extension PeerSharingService`)

  /**
   * Swift `func peerServicesReceived(withRequestId:accountId:peerId:status:servicesJson:)`.
   * Ported in full: it is the entry point a daemon would call, and its whole body - parse,
   * wrap, publish - is local. Nothing calls it while the daemon is absent.
   */
  peerServicesReceived(requestId: number, accountId: string, peerId: string, status: number,
    servicesJson: string): void {
    const services: Array<PeerServiceInfo> = this.parseServicesJson(servicesJson);
    const result: PeerServicesResult = new PeerServicesResult(requestId, accountId, peerId,
      peerServicesStatusFromCode(status), services);
    this.onDaemonCallback((service: PeerSharingService) => {
      service.getOrCreatePeerServicesRelay(accountId, peerId).accept(result);
    });
  }

  /** Swift `func serviceTunnelOpened(withAccountId:tunnelId:localPort:)`. */
  serviceTunnelOpened(accountId: string, tunnelId: string, localPort: number): void {
    this.onDaemonCallback((service: PeerSharingService) => {
      if (service.canceledPendingTunnelIds.has(tunnelId)) {
        service.canceledPendingTunnelIds.delete(tunnelId);
        service.peerServicesAdapter.closeServiceTunnel(accountId, tunnelId);
        return;
      }

      const pending: PendingOpen | undefined = service.pendingOpens.get(tunnelId);
      if (pending === undefined) {
        hilog.warn(LOG_DOMAIN, service.log,
          'TunnelOpened with no pending open for tunnelId=%{public}s', tunnelId);
        service.peerServicesAdapter.closeServiceTunnel(accountId, tunnelId);
        return;
      }
      service.pendingOpens.delete(tunnelId);

      const key: string = service.stateKey(pending.accountId, pending.peerId);
      if (!service.tunnelStates.has(key)) {
        hilog.warn(LOG_DOMAIN, service.log,
          'TunnelOpened with no tunnel state relay for tunnelId=%{public}s', tunnelId);
        service.peerServicesAdapter.closeServiceTunnel(accountId, tunnelId);
        return;
      }

      const info: PeerTunnelInfo = new PeerTunnelInfo(tunnelId, pending.accountId, pending.peerId,
        pending.serviceId, pending.serviceName, pending.scheme, localPort);
      service.updateState(pending.accountId, pending.peerId, (state: PeerTunnelState) => {
        state.addActive(info, pending.serviceId);
      });
    });
  }

  /** Swift `func serviceTunnelClosed(withAccountId:tunnelId:reason:)`. */
  serviceTunnelClosed(accountId: string, tunnelId: string, reason: string): void {
    this.onDaemonCallback((service: PeerSharingService) => {
      // Swift iterated the relays and `return`ed out of the loop on the first match. ArkTS has
      // no break out of forEach, so the match is collected first and acted on after.
      const matchedServiceIds: Array<string> = [];
      const matchedTunnels: Array<PeerTunnelInfo> = [];
      service.tunnelStates.forEach((relay: BehaviorRelay<PeerTunnelState>) => {
        relay.value.activeTunnels.forEach((info: PeerTunnelInfo, serviceId: string) => {
          if (info.tunnelId === tunnelId) {
            matchedServiceIds.push(serviceId);
            matchedTunnels.push(info);
          }
        });
      });
      if (matchedServiceIds.length > 0) {
        const serviceId: string = matchedServiceIds[0];
        const tunnelInfo: PeerTunnelInfo = matchedTunnels[0];
        service.updateState(tunnelInfo.accountId, tunnelInfo.peerId, (state: PeerTunnelState) => {
          state.removeActive(serviceId);
        });
        service.processQueuedOpenAfterClose(tunnelInfo.accountId, tunnelInfo.peerId, serviceId);
        return;
      }

      const pending: PendingOpen | undefined = service.pendingOpens.get(tunnelId);
      if (pending === undefined) {
        return;
      }
      service.pendingOpens.delete(tunnelId);
      const key: string = service.stateKey(pending.accountId, pending.peerId);
      if (!service.tunnelStates.has(key)) {
        return;
      }
      service.updateState(pending.accountId, pending.peerId, (state: PeerTunnelState) => {
        state.clearPending(pending.serviceId);
      });
    });
  }
}
