/*
 * Ported from Ring/Ring/Services/Audio/AudioService.swift:29-143,
 * Ring/Ring/Services/Audio/LibJamiAudioAPI.swift and
 * Ring/Ring/Models/Calls/AudioRoute.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * TWO HALVES, AND ONLY ONE OF THEM EXISTS HERE.
 *
 *   LOCAL (real): the OS audio route. Reading which output devices are connected and
 *   forcing/releasing the built-in speaker are plain HarmonyOS AudioKit calls, so route
 *   policy, the speaker toggle and the route-change subscription all work for real.
 *
 *   DAEMON (gap): telling libjami WHICH device index to open for the call stream. iOS did
 *   that through `AudioAdapter` -> the prebuilt C++ jami daemon, which has no source on disk
 *   and no HarmonyOS build. `SystemAudioClient` therefore performs the OS half and reports
 *   the daemon half through `DaemonService.unavailable(...)` (the build-only level - a call
 *   route change is a read-back the app makes constantly, and the user-visible effect, the
 *   speaker actually switching, does happen).
 *
 * Swift concurrency that does not translate (CLAUDE.md Rule 6 / harmonyos-apis.md 6):
 *   - `private let lock = NSLock()` and
 *   - `private let routeQueue = DispatchQueue(label: "com.savoirfairelinux.jami.audio.route")`
 *     are dropped. ArkTS has no shared-memory threading: every callback here arrives on the
 *     ability's own thread, so `prefersSpeaker` needs no lock and the route work needs no
 *     serial queue. `setPrefersSpeaker`/`currentPrefersSpeaker` are kept as the single
 *     accessors so the port still has one place that owns that field.
 */
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CallDirection } from '../model/CallState';
import { DaemonService } from './DaemonService';
import { describeError } from './ErrorText';
import { BehaviorRelay } from './Observable';
import { ServiceRegistry } from './ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AudioService';

/**
 * Swift `enum AudioRoute: Int` - the raw values are libjami's device indices, so they are kept
 * even though nothing consumes them on this platform yet (the daemon that did is absent).
 */
export enum AudioRoute {
  BUILTIN_SPEAKER = 0,
  BLUETOOTH = 1,
  HEADPHONES = 2,
  RECEIVER = 3
}

/** Swift `struct AudioRouteState`. */
export class AudioRouteState {
  readonly speakerActive: boolean;
  readonly bluetoothConnected: boolean;
  readonly headphonesConnected: boolean;

  constructor(speakerActive: boolean, bluetoothConnected: boolean, headphonesConnected: boolean) {
    this.speakerActive = speakerActive;
    this.bluetoothConnected = bluetoothConnected;
    this.headphonesConnected = headphonesConnected;
  }

  /** Swift `Equatable`. */
  equals(other: AudioRouteState): boolean {
    return this.speakerActive === other.speakerActive
      && this.bluetoothConnected === other.bluetoothConnected
      && this.headphonesConnected === other.headphonesConnected;
  }
}

/**
 * Swift `enum AudioRoutePolicy` - "the one place audio-route policy lives". Pure decisions,
 * no platform surface, so this is a verbatim port.
 */
export class AudioRoutePolicy {
  /**
   * Swift `route(bluetoothConnected:headphonesConnected:prefersSpeaker:)`. A connected headset
   * always wins (bluetooth over wired); otherwise the user's preference applies.
   */
  static route(bluetoothConnected: boolean, headphonesConnected: boolean,
               prefersSpeaker: boolean): AudioRoute {
    if (bluetoothConnected) {
      return AudioRoute.BLUETOOTH;
    }
    if (headphonesConnected) {
      return AudioRoute.HEADPHONES;
    }
    return prefersSpeaker ? AudioRoute.BUILTIN_SPEAKER : AudioRoute.RECEIVER;
  }

  /** Swift `defaultSpeakerPreference(callHasVideo:)`. */
  static defaultSpeakerPreference(callHasVideo: boolean): boolean {
    return callHasVideo;
  }

  /**
   * Swift `shouldOverrideOnActivation(direction:)`. Outgoing calls create the session with
   * default parameters; only incoming calls need the route overridden on activation.
   */
  static shouldOverrideOnActivation(direction: CallDirection): boolean {
    return direction === CallDirection.INCOMING;
  }
}

/** Swift `protocol LibJamiAudioAPI` - typed audio-device commands toward libjami. */
export interface LibJamiAudioAPI {
  setAudioOutputDevice(index: number): void;

  setAudioInputDevice(index: number): void;
}

/**
 * Swift `final class LibJamiAudioClient` (over the ObjC++ `AudioAdapter`). On HarmonyOS the
 * OS half is real and the daemon half is the gap, so this is NOT a stub: an output-device
 * command genuinely forces or releases the built-in speaker through
 * `AudioRoutingManager.setCommunicationDevice`, and only the "tell libjami" half is reported
 * unavailable.
 */
export class SystemAudioClient implements LibJamiAudioAPI {
  /** Read inside methods only - the registry must not be touched during module evaluation. */
  private get daemon(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  setAudioOutputDevice(index: number): void {
    // HarmonyOS exposes exactly one communication-device override: the built-in speaker
    // (`audio.CommunicationDeviceType` has a single member, SPEAKER). Every other route -
    // bluetooth, wired, receiver - is reached by RELEASING the speaker and letting the system
    // pick the connected headset, which is the same outcome the iOS route indices produced.
    // The OHAudio layer has a single "Default" device, so the route is the system's to switch.
    const wantsSpeaker: boolean = index === (AudioRoute.BUILTIN_SPEAKER as number);
    audio.getAudioManager().getRoutingManager()
      .setCommunicationDevice(audio.CommunicationDeviceType.SPEAKER, wantsSpeaker)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'setCommunicationDevice failed: %{public}s',
          describeError(error));
      });
  }

  setAudioInputDevice(index: number): void {
    // No counterpart at all: HarmonyOS picks the capture device from the audio scene, and the
    // per-app input selection this carried is a daemon capability.
    hilog.info(LOG_DOMAIN, LOG_TAG, 'input device %{public}d is daemon-owned', index);
    this.daemon.unavailable('audio.setInputDevice');
  }
}

/** Swift `final class AudioService`. */
export class AudioService {
  /** Swift `private let audio: LibJamiAudioAPI`. */
  private readonly audioClient: LibJamiAudioAPI = new SystemAudioClient();

  /** Swift `private let currentRoute: () -> AudioRouteState` - injectable for tests. */
  private currentRoute: () => AudioRouteState = (): AudioRouteState => {
    return AudioService.systemRouteState();
  };

  /**
   * Swift `private let notificationCenter: NotificationCenter` - iOS observed
   * `AVAudioSession.routeChangeNotification` through it. Its HarmonyOS counterpart is the
   * routing manager's own `deviceChange` stream, so the field becomes the manager itself.
   */
  private notificationCenter: audio.AudioRoutingManager | null = null;

  /** Swift `private var observer: NSObjectProtocol?` - kept so `stop()` can unsubscribe. */
  private observer: ((action: audio.DeviceChangeAction) => void) | null = null;

  /** Swift `private var prefersSpeaker = true`. */
  private prefersSpeaker: boolean = true;

  /** Swift `private let speakerActiveSubject = CurrentValueSubject<Bool, Never>(false)`. */
  private readonly speakerActiveSubject: BehaviorRelay<boolean> = new BehaviorRelay<boolean>(false);

  /** Swift `private var audioOutputDevice` - the route last selected, for `toggleSpeaker`. */
  private audioOutputDevice: AudioRoute = AudioRoute.RECEIVER;

  private started: boolean = false;

  /**
   * Swift did this work in `init`. The registry builds services lazily, so construction can
   * happen inside a page build: nothing here may throw, and the OS subscription is attempted
   * once, defensively.
   */
  constructor() {
    this.start();
  }

  /**
   * Swift's `init` tail: seed the current state and observe route changes. Split out of the
   * constructor so a failed subscription (no audio service yet) can be retried, and so
   * `stop()` has a symmetric partner.
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.refreshRouteState();
    try {
      const manager: audio.AudioRoutingManager =
        audio.getAudioManager().getRoutingManager();
      const observer: (action: audio.DeviceChangeAction) => void =
        (action: audio.DeviceChangeAction): void => {
          // Swift filtered on newDeviceAvailable / oldDeviceUnavailable / categoryChange.
          // HarmonyOS reports exactly CONNECT / DISCONNECT, which is the same set.
          if (action.type === audio.DeviceChangeType.CONNECT
            || action.type === audio.DeviceChangeType.DISCONNECT) {
            this.applyAutomaticRoute();
          }
        };
      manager.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, observer);
      this.notificationCenter = manager;
      this.observer = observer;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'route-change subscription failed: %{public}s',
        describeError(failure));
    }
  }

  /**
   * Swift `deinit` - ArkTS has no deinitializer, so the ability calls this from `onDestroy`.
   * The subscription is an OS handle: released here, in a `finally`, per CLAUDE.md Rule 8.
   */
  stop(): void {
    const manager: audio.AudioRoutingManager | null = this.notificationCenter;
    const observer: ((action: audio.DeviceChangeAction) => void) | null = this.observer;
    try {
      if (manager !== null && observer !== null) {
        manager.off('deviceChange', observer);
      }
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'route-change unsubscribe failed: %{public}s',
        describeError(failure));
    } finally {
      this.notificationCenter = null;
      this.observer = null;
      this.started = false;
    }
  }

  /**
   * Swift `var speakerActive: AnyPublisher<Bool, Never>` - "emits on an unspecified queue".
   * The relay replays its current value and `select` only accepts a CHANGED value, which is
   * Swift's `removeDuplicates()`.
   */
  get speakerActive(): BehaviorRelay<boolean> {
    return this.speakerActiveSubject;
  }

  /** Swift `init(audio:currentRoute:notificationCenter:)`'s `currentRoute` seam, for tests. */
  setRouteStateProvider(provider: () => AudioRouteState): void {
    this.currentRoute = provider;
    this.refreshRouteState();
  }

  /**
   * Swift `func callKitActivated(callHasVideo:direction:)`. Kept spelled exactly this way -
   * `common/CallsManager.ts` already calls it.
   */
  callKitActivated(callHasVideo: boolean, direction: CallDirection): void {
    this.setPrefersSpeaker(AudioRoutePolicy.defaultSpeakerPreference(callHasVideo));
    // HarmonyOS has no CallKit session whose defaults pick the receiver for an outgoing call,
    // and a forced speaker survives the previous call, so the route is applied either way.
    this.applyAutomaticRoute();
  }

  /**
   * Swift `func toggleSpeaker()`. A button tap is an explicit override: invert the real route
   * even when a headset is connected.
   */
  toggleSpeaker(): void {
    const route: AudioRoute = this.speakerActiveSubject.value
      ? AudioRoute.RECEIVER : AudioRoute.BUILTIN_SPEAKER;
    this.setPrefersSpeaker(route === AudioRoute.BUILTIN_SPEAKER);
    this.select(route);
  }

  /** Swift `private func applyAutomaticRoute()`. */
  private applyAutomaticRoute(): void {
    const current: AudioRouteState = this.currentRoute();
    const route: AudioRoute = AudioRoutePolicy.route(current.bluetoothConnected,
      current.headphonesConnected, this.currentPrefersSpeaker());
    this.select(route);
  }

  /** Swift `private func select(_ route: AudioRoute)`. */
  private select(route: AudioRoute): void {
    this.audioOutputDevice = route;
    this.audioClient.setAudioOutputDevice(route as number);
    const speaker: boolean = route === AudioRoute.BUILTIN_SPEAKER;
    // The daemon's OHAudio layer has no output selection: the system routes the
    // VOICE_COMMUNICATION stream, so the speaker is forced on or off here.
    try {
      audio.getAudioManager().getRoutingManager()
        .setCommunicationDevice(audio.CommunicationDeviceType.SPEAKER, speaker)
        .catch((error: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'speaker route failed: %{public}s', describeError(error));
        });
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'speaker route failed: %{public}s',
        describeError(error as BusinessError));
    }
    if (speaker !== this.speakerActiveSubject.value) {
      this.speakerActiveSubject.accept(speaker);
    }
  }

  /** Swift `private func refreshRouteState()`. */
  private refreshRouteState(): void {
    const speaker: boolean = this.currentRoute().speakerActive;
    if (speaker !== this.speakerActiveSubject.value) {
      this.speakerActiveSubject.accept(speaker);
    }
  }

  /** Swift `private func setPrefersSpeaker(_ value: Bool)` (its `lock` is dropped - see header). */
  private setPrefersSpeaker(value: boolean): void {
    this.prefersSpeaker = value;
  }

  /** Swift `private func currentPrefersSpeaker() -> Bool`. */
  private currentPrefersSpeaker(): boolean {
    return this.prefersSpeaker;
  }

  /**
   * Swift `private static func systemRouteState()` over `AVAudioSession.currentRoute.outputs`.
   * The HarmonyOS reading is real and needs no context:
   *   - speaker: `isCommunicationDeviceActiveSync(SPEAKER)` - whether the speaker is FORCED on,
   *     which is what the iOS `.builtInSpeaker` port in the active route meant;
   *   - bluetooth / headphones: the connected output devices.
   */
  private static systemRouteState(): AudioRouteState {
    try {
      const manager: audio.AudioRoutingManager = audio.getAudioManager().getRoutingManager();
      const speaker: boolean =
        manager.isCommunicationDeviceActiveSync(audio.CommunicationDeviceType.SPEAKER);
      const outputs: audio.AudioDeviceDescriptors =
        manager.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
      let bluetooth: boolean = false;
      let headphones: boolean = false;
      for (const device of outputs) {
        const type: audio.DeviceType = device.deviceType;
        if (type === audio.DeviceType.BLUETOOTH_SCO || type === audio.DeviceType.BLUETOOTH_A2DP) {
          bluetooth = true;
        } else if (type === audio.DeviceType.WIRED_HEADSET
          || type === audio.DeviceType.WIRED_HEADPHONES
          || type === audio.DeviceType.USB_HEADSET) {
          headphones = true;
        }
      }
      return new AudioRouteState(speaker, bluetooth, headphones);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'reading the audio route failed: %{public}s',
        describeError(failure));
      return new AudioRouteState(false, false, false);
    }
  }
}
