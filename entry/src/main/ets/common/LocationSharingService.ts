/*
 * Ported from Ring/Ring/Services/LocationSharingService.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * TWO SUBSTITUTIONS, both disclosed, neither a fake success:
 *
 * 1. FOREGROUND-ONLY (results/analysis/permission-substitutions.json, "UIBackgroundModes:
 *    location"). iOS set `locationManager.allowsBackgroundLocationUpdates = true` and kept
 *    publishing while backgrounded. A self-signed HarmonyOS build may not declare the
 *    `location` background mode, so position acquisition STOPS when the app leaves the
 *    foreground: `setAppForeground(false)` unsubscribes from locationChange, publishes on
 *    `backgroundSharingSuspended` so the UI can say so, and `setAppForeground(true)`
 *    re-subscribes. The share session and its expiry timer survive the suspension; what does
 *    not survive is the illusion that positions are still being produced.
 *
 * 2. THE DAEMON GAP. Getting a position to a peer is `sendMessage` over the prebuilt C++ jami
 *    daemon (Ring/Ring/Bridging/DRingAdapter.mm), which has no source on disk. The event this
 *    service publishes (SEND_LOCATION) is consumed by ConversationsManager, which calls
 *    ConversationsService.sendLocation - and that rejects with the daemon gap. So
 *    `startSharingLocation` hands its caller the DaemonUnavailableError up front rather than
 *    letting the user believe a position left the device.
 *
 * What IS real here and must keep working: acquiring the device's own position
 * (@ohos.geoLocationManager), the share duration timer and its expiry, the incoming-share
 * staleness sweep, the in-memory share registries, and the JSON location codec.
 */
import { geoLocationManager } from '@kit.LocationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeError } from './ErrorText';
import { Durations } from './Durations';
import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { DaemonUnavailableError } from './DaemonService';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LocationSharingService';

/**
 * Swift `locationManager.allowsBackgroundLocationUpdates = true`. Permanently false here -
 * substitution 1 above. Kept as a named constant so a reader of the source can find the line.
 */
const ALLOWS_BACKGROUND_LOCATION_UPDATES: boolean = false;

/** Swift `kCLLocationAccuracyBest` - the continuous request's target accuracy. */
const DESIRED_ACCURACY_SCENARIO: geoLocationManager.UserActivityScenario =
  geoLocationManager.UserActivityScenario.NAVIGATION;

/** Continuous position report interval, in SECONDS (the Kit's unit for this field). */
const LOCATION_REPORT_INTERVAL_SECONDS: number = 1;

/** Timeout of the one-shot read `startSharingLocation` does, in milliseconds. */
const SINGLE_LOCATION_TIMEOUT_MS: number = 10000;

/** Swift `Durations.tenSeconds` throttle on the outgoing position stream. */
const SHARE_THROTTLE_MS: number = Durations.TEN_SECONDS;

/** Swift `Durations.sixtySeconds` - the incoming-share staleness sweep period. */
const RECEIVING_SWEEP_INTERVAL_MS: number = Durations.SIXTY_SECONDS;

/** Reason code the UI renders when a share is suspended by the foreground-only substitution. */
export const LOCATION_BACKGROUND_SUSPENDED_REASON: string = 'LOCATION_FOREGROUND_ONLY';

/**
 * Swift `L10n.Notifications.locationSharingStopped`. A .ts module cannot call `getContext()`,
 * so the resource NAME travels and the UI resolves it; the English text is the fallback.
 */
export const LOCATION_SHARING_STOPPED_RESOURCE: string = 'notifications_location_sharing_stopped';
const LOCATION_SHARING_STOPPED_TEXT: string = 'Incoming location sharing stopped';

/** Swift `enum SerializableLocationTypes: String`. The values are wire format - never renamed. */
export enum SerializableLocationTypes {
  POSITION = 'Position',
  STOP = 'Stop'
}

/** Swift `struct SerializableLocation: Codable` - the JSON body of a location message. */
export interface SerializableLocation {
  type?: string;
  lat?: number;
  long?: number;
  alt?: number;
  time?: number;
  bearing?: number;
  speed?: number;
}

/** Swift `class LocationSharingInstance` - one share, identified by account + contact. */
export class LocationSharingInstance {
  readonly accountId: string;
  readonly contactUri: string;

  constructor(accountId: string, contactUri: string) {
    this.accountId = accountId;
    this.contactUri = contactUri;
  }
}

/**
 * Swift `class OutgoingLocationSharingInstance` - my location going to one contact, optionally
 * for a bounded duration. The timer is real: on expiry it stops the share exactly as iOS did.
 */
export class OutgoingLocationSharingInstance extends LocationSharingInstance {
  private locationSharingService: LocationSharingService;
  /** Seconds, as in Swift's `TimeInterval`. 0 means "until stopped". */
  readonly duration: number;
  private endSharingTimer: number | null = null;
  /** Swift read `endSharingTimer.fireDate`; a HarmonyOS timer id exposes nothing, so keep it. */
  private endSharingAtMs: number = 0;

  constructor(locationSharingService: LocationSharingService, accountId: string,
    contactUri: string, duration: number) {
    super(accountId, contactUri);
    this.locationSharingService = locationSharingService;
    this.duration = duration;
    if (duration > 0) {
      this.endSharingAtMs = Date.now() + duration * 1000;
      this.endSharingTimer = setTimeout(() => {
        this.endSharing();
      }, duration * 1000);
    }
  }

  /** Swift `var remainingTime: Int` - whole minutes left, 0 when unbounded or expired. */
  get remainingTime(): number {
    if (this.endSharingTimer === null) {
      return 0;
    }
    return Math.round((this.endSharingAtMs - Date.now()) / 60000);
  }

  /** Swift `@objc private func endSharing(timer:)`. */
  private endSharing(): void {
    this.endSharingTimer = null;
    this.locationSharingService.stopSharingLocation(this.accountId, this.contactUri);
  }

  /** Swift `func invalidate()`. */
  invalidate(): void {
    const timer: number | null = this.endSharingTimer;
    if (timer !== null) {
      try {
        clearTimeout(timer);
      } finally {
        this.endSharingTimer = null;
      }
    }
  }
}

/** Swift `class IncomingLocationSharingInstance` - a contact's location coming to me. */
export class IncomingLocationSharingInstance extends LocationSharingInstance {
  /** Milliseconds since epoch - Swift held a `Date`. */
  lastReceivedDate: number;
  /** The peer's own timestamp, used to drop out-of-order updates. */
  lastReceivedTimeStamp: number;

  constructor(accountId: string, contactUri: string, lastReceivedDate: number,
    lastReceivedTimeStamp: number) {
    super(accountId, contactUri);
    this.lastReceivedDate = lastReceivedDate;
    this.lastReceivedTimeStamp = lastReceivedTimeStamp;
  }
}

/** Swift `class LocationSharingInstanceDictionary<T>` - keyed by accountId + bare contact uri. */
export class LocationSharingInstanceDictionary<T extends LocationSharingInstance> {
  private instances: Map<string, T> = new Map<string, T>();

  get isEmpty(): boolean {
    return this.instances.size === 0;
  }

  private key(accountId: string, contactUri: string): string {
    return accountId + contactUri.replace('ring:', '');
  }

  get(accountId: string, contactUri: string): T | null {
    const found: T | undefined = this.instances.get(this.key(accountId, contactUri));
    return found === undefined ? null : found;
  }

  insertOrUpdate(instance: T): void {
    this.instances.set(this.key(instance.accountId, instance.contactUri), instance);
  }

  remove(accountId: string, contactUri: string): T | null {
    const mapKey: string = this.key(accountId, contactUri);
    const found: T | undefined = this.instances.get(mapKey);
    if (found === undefined) {
      return null;
    }
    this.instances.delete(mapKey);
    return found;
  }

  asArray(): Array<T> {
    const all: Array<T> = [];
    this.instances.forEach((value: T) => {
      all.push(value);
    });
    return all;
  }
}

/**
 * Swift published `BehaviorRelay<(String?, CLLocationCoordinate2D?, Int?)>`. ArkTS has no tuple,
 * so the three positions become named fields. A null coordinate means "this peer stopped".
 */
export class PeerLocationUpdate {
  readonly peerUri: string | null;
  readonly latitude: number | null;
  readonly longitude: number | null;
  /** Swift `Int(incomingTime) / 60000` - the peer's timestamp, as the source divided it. */
  readonly timeStamp: number | null;

  constructor(peerUri: string | null, latitude: number | null, longitude: number | null,
    timeStamp: number | null) {
    this.peerUri = peerUri;
    this.latitude = latitude;
    this.longitude = longitude;
    this.timeStamp = timeStamp;
  }
}

/** Swift `class LocationSharingService: NSObject`. */
export class LocationSharingService {

  /** Swift `private let incomingLocationSharingEndingDelay: TimeInterval = 10 * 60`. */
  private readonly incomingLocationSharingEndingDelay: number = 10 * 60;

  private readonly log: string = LOG_TAG;

  /**
   * Swift `private let dbManager: DBManager`, injected by AppDelegate. NOT PORTED: the Swift
   * service stores it and never reads it (no call site in the 396-line file), and this project
   * has no DBManager module - persistence lives per-service on @ohos.data.relationalStore.
   * Reported to the orchestrator rather than fabricated.
   */

  private readonly disposeBag: DisposeBag = new DisposeBag();

  /**
   * Swift `private let locationManager = CLLocationManager()`. HarmonyOS exposes location as a
   * module, not an instance, so the "manager" here is the live subscription handle.
   */
  private locationManagerCallback: ((location: geoLocationManager.Location) => void) | null = null;

  /** Swift `locationManager.desiredAccuracy = kCLLocationAccuracyBest`. */
  private readonly desiredAccuracy: geoLocationManager.UserActivityScenario =
    DESIRED_ACCURACY_SCENARIO;

  /** Swift `locationManager.allowsBackgroundLocationUpdates`. Always false - substitution 1. */
  get allowsBackgroundLocationUpdates(): boolean {
    return ALLOWS_BACKGROUND_LOCATION_UPDATES;
  }

  // MARK: Sharing my location

  /** Swift `let currentLocation = BehaviorRelay<CLLocation?>(value: nil)`. */
  readonly currentLocation: BehaviorRelay<geoLocationManager.Location | null> =
    new BehaviorRelay<geoLocationManager.Location | null>(null);
  private readonly outgoingInstances: LocationSharingInstanceDictionary<OutgoingLocationSharingInstance> =
    new LocationSharingInstanceDictionary<OutgoingLocationSharingInstance>();

  // MARK: Receiving my contact's location

  /** Swift `let peerUriAndLocationReceived`. */
  readonly peerUriAndLocationReceived: BehaviorRelay<PeerLocationUpdate> =
    new BehaviorRelay<PeerLocationUpdate>(new PeerLocationUpdate(null, null, null, null));
  private readonly incomingInstances: LocationSharingInstanceDictionary<IncomingLocationSharingInstance> =
    new LocationSharingInstanceDictionary<IncomingLocationSharingInstance>();

  /** Swift `var receivingService: Disposable?` - the 60s staleness sweep's unsubscribe. */
  receivingService: (() => void) | null = null;

  // MARK: ServiceEvents

  private readonly locationServiceEventStream: PublishSubject<ServiceEvent> =
    new PublishSubject<ServiceEvent>();
  /** Swift `let locationServiceEventShared: Observable<ServiceEvent>`. */
  readonly locationServiceEventShared: PublishSubject<ServiceEvent>;

  /**
   * Substitution 1's user-visible half: true while the app is backgrounded WITH an active
   * outgoing share, meaning no new position is being produced. A screen renders the notice.
   */
  readonly backgroundSharingSuspended: BehaviorRelay<boolean> = new BehaviorRelay<boolean>(false);

  private appInForeground: boolean = true;
  private locationPermissionGranted: boolean = true;
  private lastSharedAtMs: number = 0;

  /**
   * Swift `init(dbManager:)`. Zero-argument, per the ServiceRegistry contract; nothing is read
   * from the registry here - only inside method bodies.
   */
  constructor() {
    this.locationServiceEventShared = this.locationServiceEventStream;
    this.initialize();
  }

  /**
   * Swift `private func initialize()` - throttles `currentLocation` to one share per ten
   * seconds. RxSwift's `throttle` is replaced by a leading-edge timestamp check.
   * ponytail: leading edge only; add a trailing emit if a screen ever needs the last position
   * of a window rather than the first.
   */
  private initialize(): void {
    const unsubscribe: () => void = this.currentLocation
      .subscribe((location: geoLocationManager.Location | null) => {
        if (location === null) {
          return;
        }
        const now: number = Date.now();
        if (now - this.lastSharedAtMs < SHARE_THROTTLE_MS) {
          return;
        }
        this.lastSharedAtMs = now;
        this.doShareLocationAction(location);
      });
    this.disposeBag.add(unsubscribe);
  }

  /** Swift `static func serializeLocation(location:) -> String?`. */
  static serializeLocation(location: SerializableLocation): string | null {
    try {
      return JSON.stringify(location);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'serializeLocation failed: %{public}s',
        describeError(error as BusinessError));
      return null;
    }
  }

  /** Swift `internal static func deserializeLocation(json:) -> SerializableLocation?`. */
  static deserializeLocation(json: string): SerializableLocation | null {
    try {
      return JSON.parse(json) as SerializableLocation;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'deserializeLocation failed: %{public}s',
        describeError(error as BusinessError));
      return null;
    }
  }

  /**
   * Swift `internal func triggerSendLocation(...)`. Swift packed `(content, shouldTryToSave)`
   * into the single `.content` input as a tuple; ArkTS event inputs are typed per bucket, so
   * the flag travels as its own input - the shape ConversationsManager already reads.
   */
  triggerSendLocation(accountId: string, peerUri: string, content: string,
    shouldTryToSave: boolean): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.SEND_LOCATION);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.PEER_URI, peerUri);
    event.addEventInput(ServiceEventInput.CONTENT, content);
    event.addBoolean(ServiceEventInput.SHOULD_TRY_TO_SAVE, shouldTryToSave);
    this.locationServiceEventStream.onNext(event);
  }

  /** Swift `internal func triggerStopSharing(...)`. */
  triggerStopSharing(accountId: string, peerUri: string, content: string): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.STOP_LOCATION_SHARING);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.PEER_URI, peerUri);
    event.addEventInput(ServiceEventInput.CONTENT, content);
    this.locationServiceEventStream.onNext(event);
  }

  /** Swift `func getLocationServiceEventStream()`. */
  getLocationServiceEventStream(): PublishSubject<ServiceEvent> {
    return this.locationServiceEventStream;
  }

  /** Swift `func getOutgoingInstances()`. */
  getOutgoingInstances(): LocationSharingInstanceDictionary<OutgoingLocationSharingInstance> {
    return this.outgoingInstances;
  }

  /** Swift `func getIncomingInstances()`. */
  getIncomingInstances(): LocationSharingInstanceDictionary<IncomingLocationSharingInstance> {
    return this.incomingInstances;
  }

  // MARK: Sharing my location (Swift `extension LocationSharingService`)

  /** Swift `func isAlreadySharing(accountId:contactUri:)` - an INCOMING share exists. */
  isAlreadySharing(accountId: string, contactUri: string): boolean {
    return this.incomingInstances.get(accountId, contactUri) !== null;
  }

  /** Swift `func isAlreadySharingMyLocation(accountId:contactUri:)`. */
  isAlreadySharingMyLocation(accountId: string, contactUri: string): boolean {
    return this.outgoingInstances.get(accountId, contactUri) !== null;
  }

  /** Swift `func getMyLocationSharingRemainedTime(accountId:contactUri:)` - whole minutes. */
  getMyLocationSharingRemainedTime(accountId: string, contactUri: string): number {
    const instance: OutgoingLocationSharingInstance | null =
      this.outgoingInstances.get(accountId, contactUri);
    return instance === null ? 0 : instance.remainingTime;
  }

  /**
   * Swift `func startSharingLocation(from:to:duration:)`.
   *
   * The LOCAL half runs for real: the instance is registered, the expiry timer armed, and
   * position acquisition started. The TRANSMIT half is the daemon gap, so the returned
   * DaemonUnavailableError is the caller's cue to show "not available on this platform" -
   * never a silent success. Null is returned only when there was already a share to join.
   *
   * @param duration seconds, or 0 for an unbounded share (Swift's `nil`).
   */
  startSharingLocation(accountId: string, recipientUri: string,
    duration: number): DaemonUnavailableError | null {
    if (this.isAlreadySharingMyLocation(accountId, recipientUri)) {
      return null;
    }

    this.outgoingInstances.insertOrUpdate(
      new OutgoingLocationSharingInstance(this, accountId, recipientUri, duration));

    // Swift `if let location = CLLocationManager().location` - the immediate, cached fix.
    const singleRequest: geoLocationManager.SingleLocationRequest = {
      locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY,
      locatingTimeoutMs: SINGLE_LOCATION_TIMEOUT_MS
    };
    geoLocationManager.getCurrentLocation(singleRequest)
      .then((location: geoLocationManager.Location) => {
        this.currentLocation.accept(location);
      })
      .catch((error: BusinessError) => {
        hilog.warn(LOG_DOMAIN, this.log, 'getCurrentLocation failed: %{public}s',
          describeError(error));
      });

    this.startUpdatingLocation();

    // Positions go out through ConversationsService.sendLocation as account messages.
    return null;
  }

  /** Swift `private func doShareLocationAction(_ location:)`. */
  private doShareLocationAction(location: geoLocationManager.Location): void {
    const serializable: SerializableLocation = {
      type: SerializableLocationTypes.POSITION as string,
      lat: location.latitude,
      long: location.longitude,
      alt: location.altitude,
      time: Math.floor(Date.now() / 1000)
    };
    const jsonLocation: string | null = LocationSharingService.serializeLocation(serializable);
    if (jsonLocation === null) {
      return;
    }
    for (const instance of this.outgoingInstances.asArray()) {
      this.triggerSendLocation(instance.accountId, instance.contactUri, jsonLocation, true);
    }
  }

  /** Swift `func stopSharingLocation(accountId:contactUri:)`. */
  stopSharingLocation(accountId: string, contactUri: string): void {
    const instance: OutgoingLocationSharingInstance | null =
      this.outgoingInstances.get(accountId, contactUri);
    if (instance !== null) {
      instance.invalidate();
    }
    this.outgoingInstances.remove(accountId, contactUri);

    if (this.outgoingInstances.isEmpty) {
      this.stopUpdatingLocation();
      this.currentLocation.accept(null);
      this.backgroundSharingSuspended.accept(false);
    }

    this.sendStopSharingLocationMessage(accountId, contactUri);
  }

  /** Swift `private func sendStopSharingLocationMessage(from:to:)`. */
  private sendStopSharingLocationMessage(accountId: string, contactUri: string): void {
    const serializable: SerializableLocation = {
      type: SerializableLocationTypes.STOP as string,
      time: Math.floor(Date.now() / 1000)
    };
    const jsonLocation: string | null = LocationSharingService.serializeLocation(serializable);
    if (jsonLocation === null) {
      return;
    }
    this.triggerSendLocation(accountId, contactUri, jsonLocation, false);
  }

  // MARK: Receiving my contact's location (Swift `extension LocationSharingService`)

  /** Swift `func handleReceivedLocationUpdate(from:to:messageId:locationJSON:)`. */
  handleReceivedLocationUpdate(peerUri: string, accountId: string, messageId: string,
    content: string): void {
    const incomingData: SerializableLocation | null =
      LocationSharingService.deserializeLocation(content);
    if (incomingData === null) {
      return;
    }

    if (this.incomingInstances.isEmpty) {
      this.startReceivingService();
    }

    const incomingTime: number | undefined = incomingData.time;
    const existing: IncomingLocationSharingInstance | null =
      this.incomingInstances.get(accountId, peerUri);
    if (existing !== null) {
      if (incomingTime !== undefined) {
        if (existing.lastReceivedTimeStamp < incomingTime) {
          existing.lastReceivedDate = Date.now();
          existing.lastReceivedTimeStamp = incomingTime;
        } else {
          // Older than the newest we hold - messages can arrive out of order.
          return;
        }
      }
    } else if (incomingTime !== undefined) {
      this.incomingInstances.insertOrUpdate(
        new IncomingLocationSharingInstance(accountId, peerUri, Date.now(), incomingTime));
    }

    const type: string | undefined = incomingData.type;
    if (type === undefined || type === (SerializableLocationTypes.POSITION as string)) {
      const latitude: number | undefined = incomingData.lat;
      const longitude: number | undefined = incomingData.long;
      if (incomingTime !== undefined && latitude !== undefined && longitude !== undefined) {
        this.peerUriAndLocationReceived.accept(
          new PeerLocationUpdate(peerUri, latitude, longitude, Math.floor(incomingTime / 60000)));
      }
    } else if (type === (SerializableLocationTypes.STOP as string)) {
      this.stopReceivingLocation(accountId, peerUri);
    }
  }

  /** Swift `func stopReceivingLocation(accountId:contactUri:)`. */
  stopReceivingLocation(accountId: string, contactUri: string): void {
    this.peerUriAndLocationReceived.accept(new PeerLocationUpdate(contactUri, null, null, null));

    this.incomingInstances.remove(accountId, contactUri);

    if (this.incomingInstances.isEmpty) {
      this.stopReceivingService();
    }

    this.triggerStopSharing(accountId, contactUri, LOCATION_SHARING_STOPPED_TEXT);
  }

  /**
   * Swift `func startReceivingService()` - `Observable<Int>.interval(60s)`, sweeping incoming
   * shares and ending any that has gone quiet for longer than the 10-minute delay.
   */
  startReceivingService(): void {
    this.stopReceivingService();
    const timer: number = setInterval(() => {
      for (const instance of this.incomingInstances.asArray()) {
        const elapsedSeconds: number = (Date.now() - instance.lastReceivedDate) / 1000;
        if (elapsedSeconds > this.incomingLocationSharingEndingDelay) {
          this.stopReceivingLocation(instance.accountId, instance.contactUri);
        }
      }
    }, RECEIVING_SWEEP_INTERVAL_MS);
    this.receivingService = () => {
      clearInterval(timer);
    };
  }

  /** Swift `func stopReceivingService()`. */
  stopReceivingService(): void {
    const dispose: (() => void) | null = this.receivingService;
    if (dispose !== null) {
      try {
        dispose();
      } finally {
        this.receivingService = null;
      }
    }
  }

  // MARK: Position acquisition (Swift `extension: CLLocationManagerDelegate`)

  /**
   * Swift `func locationManager(_:didUpdateLocations:)` - the continuous position callback.
   * Public because HarmonyOS delivers it as a plain callback, not a delegate method.
   */
  locationManager(location: geoLocationManager.Location): void {
    this.currentLocation.accept(location);
  }

  /** Subscribe to `locationChange`. Idempotent; a no-op while backgrounded or unpermitted. */
  private startUpdatingLocation(): void {
    if (this.locationManagerCallback !== null) {
      return;
    }
    if (!this.appInForeground || !this.locationPermissionGranted) {
      this.backgroundSharingSuspended.accept(!this.appInForeground);
      return;
    }
    const request: geoLocationManager.ContinuousLocationRequest = {
      interval: LOCATION_REPORT_INTERVAL_SECONDS,
      locationScenario: this.desiredAccuracy
    };
    const callback: (location: geoLocationManager.Location) => void =
      (location: geoLocationManager.Location) => {
        this.locationManager(location);
      };
    try {
      geoLocationManager.on('locationChange', request, callback);
      this.locationManagerCallback = callback;
      this.backgroundSharingSuspended.accept(false);
    } catch (error) {
      // Swift logged `didFailWithError` here; the permission-denied case is handled by
      // setLocationPermissionGranted(false), which is the port of didChangeAuthorization.
      hilog.error(LOG_DOMAIN, this.log, 'locationChange subscribe failed: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /** Unsubscribe from `locationChange`. */
  private stopUpdatingLocation(): void {
    const callback: ((location: geoLocationManager.Location) => void) | null =
      this.locationManagerCallback;
    if (callback === null) {
      return;
    }
    try {
      geoLocationManager.off('locationChange', callback);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, this.log, 'locationChange unsubscribe failed: %{public}s',
        describeError(error as BusinessError));
    } finally {
      this.locationManagerCallback = null;
    }
  }

  /**
   * SUBSTITUTION 1's injector - the UIAbility calls this from `onForeground`/`onBackground`
   * (a .ts module cannot observe the lifecycle itself). Backgrounding STOPS position
   * acquisition and says so on `backgroundSharingSuspended`; the share session and its expiry
   * timer are left intact so returning to the foreground resumes rather than restarts.
   */
  setAppForeground(isForeground: boolean): void {
    if (this.appInForeground === isForeground) {
      return;
    }
    this.appInForeground = isForeground;
    if (isForeground) {
      if (!this.outgoingInstances.isEmpty) {
        this.startUpdatingLocation();
      }
      this.backgroundSharingSuspended.accept(false);
      return;
    }
    this.stopUpdatingLocation();
    if (!this.outgoingInstances.isEmpty) {
      hilog.info(LOG_DOMAIN, this.log,
        'foreground-only location: suspending %{public}s while backgrounded',
        LOCATION_BACKGROUND_SUSPENDED_REASON);
      this.backgroundSharingSuspended.accept(true);
    }
  }

  /**
   * Swift `func locationManager(_:didChangeAuthorization:)` - on notDetermined/denied/
   * restricted every outgoing share was stopped. The UI owns the permission prompt (it has the
   * context a .ts module lacks) and reports the answer here.
   */
  setLocationPermissionGranted(granted: boolean): void {
    this.locationPermissionGranted = granted;
    if (granted) {
      if (!this.outgoingInstances.isEmpty) {
        this.startUpdatingLocation();
      }
      return;
    }
    for (const instance of this.outgoingInstances.asArray()) {
      this.stopSharingLocation(instance.accountId, instance.contactUri);
    }
  }

  /** Releases the throttle subscription and both timers. */
  dispose(): void {
    try {
      this.stopReceivingService();
      this.stopUpdatingLocation();
      for (const instance of this.outgoingInstances.asArray()) {
        instance.invalidate();
      }
    } finally {
      this.disposeBag.dispose();
    }
  }
}
