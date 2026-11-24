/*
 * Ported from Ring/Ring/Services/Video/VideoService.swift:48-227,
 * Ring/Ring/Services/Video/VideoPipeline.swift and
 * Ring/Ring/Services/Video/FrameDistributor.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * The three Swift files are one module here because the contract declares one module.
 *
 * WHAT IS REAL AND WHAT IS A GAP
 *
 *   REAL (Camera Kit / Media Kit, no daemon involved):
 *     - camera enumeration, opening a session, live preview on a surface the UI injects,
 *       camera switching, capture quality (medium/high device) and orientation;
 *     - the media player for message attachments - a real `media.AVPlayer`, fed by fd:// for a
 *       local file and by an http(s) URL otherwise (never file://, never DASH);
 *     - the local recorder: voice messages on a real `media.AVRecorder`, video messages on libjami's
 *       recorder fed by this camera (as iOS, so the pixels come out upright, T-1619);
 *     - the codec downgrade POLICY and the camera source URIs, which are pure local logic.
 *
 *   GAP (the prebuilt C++ jami daemon, no source on disk - CLAUDE.md Rule 11):
 *     - handing captured frames to libjami's encoder (`writeOutgoingFrame`) and receiving
 *       decoded frames from its sinks. On HarmonyOS a camera or decoder writes to a SURFACE
 *       and never to JS, so there is no per-pixel path to bridge even in principle;
 *     - registering capture devices with libjami and its own media player. Each is reported
 *       through `DaemonService`, never faked.
 *
 * FRAMES BECAME GEOMETRY. iOS fanned `CMSampleBuffer`s out to renderers; HarmonyOS renders
 * through an XComponent surface. `FrameDistributor` therefore carries the frame GEOMETRY a
 * renderer needs (rotation, mirroring, size) instead of pixels, and the surface itself is
 * injected with `setPreviewSurface`. The subscribe/replay/teardown semantics are unchanged.
 *
 * Swift concurrency that does not translate: `NSLock`/`DispatchQueue` are dropped (ArkTS has
 * no shared-memory threading - harmonyos-apis.md 6); every callback arrives on the ability's
 * own thread.
 */
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { camera } from '@kit.CameraKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SinkId } from '../model/SinkId';
import { describeError } from './ErrorText';
import { PublishSubject } from './Observable';
import { PreferenceManager } from './PreferenceManager';
import { jami } from './JamiNative';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'VideoService';
/** Device-lane diagnostics of the camera and remote-video path (T-1616, T-1626): one tag to filter on. */
const F4_TAG: string = 'JamiF4';

/**
 * Swift `enum CameraDevice` (Services/Video/CameraCapturer.swift:28) - the two libjami device
 * names. Kept verbatim: they are wire identifiers, not display text.
 */
const CAMERA_DEVICE_MEDIUM: string = 'mediumCamera';
const CAMERA_DEVICE_HIGH: string = '1280_720Camera';

/** Swift's `camera://` source prefix for libjami media lists. */
const CAMERA_SOURCE_PREFIX: string = 'camera://';

/**
 * libjami's StopCapture is held this long before the camera goes: a renegotiation restarts the
 * video sender, StopCapture then StartCapture for the same input 11 ms apart on the device, and
 * reopening the camera for it cost ~0.7 s without frames (T-1616).
 */
const STOP_CAPTURE_GRACE_MS: number = 200;

/** The two hardware-accelerated codecs; anything else forces the medium capture device. */
const HARDWARE_CODEC_H264: string = 'H264';
const HARDWARE_CODEC_H265: string = 'H265';

/** Preferred preview/record geometry per quality preset (Swift's AVCaptureSession presets). */
const HIGH_WIDTH: number = 1280;
const HIGH_HEIGHT: number = 720;
const MEDIUM_WIDTH: number = 640;
const MEDIUM_HEIGHT: number = 480;

const AUDIO_BITRATE: number = 48000;
const AUDIO_SAMPLE_RATE: number = 48000;
const AUDIO_CHANNELS: number = 1;
const VIDEO_BITRATE: number = 2000000;
const VIDEO_FRAME_RATE: number = 30;
/** The chat camera's still: nearest 12 MP, the iPhone's 4032x3024 (T-0755). */
const PHOTO_AREA: number = 4032 * 3024;

/**
 * The profile with the aspect of `width`x`height` whose area is nearest `area`, else the
 * first. A video session refuses streams of different aspects ("Camera service fatal error:
 * Mismatch resolution configuration", T-0763), and a device may lack 640x480 (BRA-AL00 front).
 */
function pickProfile<T extends camera.Profile>(profiles: Array<T>, width: number, height: number,
  area: number): T | null {
  let best: T | null = null;
  for (const profile of profiles) {
    const size: camera.Size = profile.size;
    if (size.width * height !== size.height * width) {
      continue;
    }
    if (best === null || Math.abs(size.width * size.height - area) <
      Math.abs(best.size.width * best.size.height - area)) {
      best = profile;
    }
  }
  return best !== null ? best : (profiles.length > 0 ? profiles[0] : null);
}

/** Swift `AVCaptureSession.Preset` as this port uses it: two presets, nothing else. */
export enum CaptureQuality {
  HIGH = 'HIGH',
  MEDIUM = 'MEDIUM'
}

/**
 * Swift `UIDeviceOrientation` / `UIInterfaceOrientation`, reduced to the four values
 * `AVCaptureVideoOrientation.resolve` could actually produce plus the unknown input.
 */
export enum DeviceOrientation {
  UNKNOWN = 'UNKNOWN',
  PORTRAIT = 'PORTRAIT',
  PORTRAIT_UPSIDE_DOWN = 'PORTRAIT_UPSIDE_DOWN',
  LANDSCAPE_LEFT = 'LANDSCAPE_LEFT',
  LANDSCAPE_RIGHT = 'LANDSCAPE_RIGHT'
}

/** Swift `struct DeviceOrientationInput` (Helpers/DeviceOrientationMonitor.swift:21). */
export class DeviceOrientationInput {
  readonly device: DeviceOrientation;
  readonly interface: DeviceOrientation;

  constructor(device: DeviceOrientation, deviceInterface: DeviceOrientation) {
    this.device = device;
    this.interface = deviceInterface;
  }
}

/**
 * Swift `CGAffineTransform` as the preview layer used it. ArkUI has no affine-transform type
 * on an XComponent, so the transform is carried in the two terms the renderer applies:
 * `.rotate({ angle })` and, for the front camera, `.scale({ x: -1 })`.
 */
export class CameraLayerTransform {
  readonly rotationDegrees: number;
  readonly mirrored: boolean;

  constructor(rotationDegrees: number, mirrored: boolean) {
    this.rotationDegrees = rotationDegrees;
    this.mirrored = mirrored;
  }

  equals(other: CameraLayerTransform): boolean {
    return this.rotationDegrees === other.rotationDegrees && this.mirrored === other.mirrored;
  }
}

/**
 * Swift `struct CameraOrientationState` (CameraCapturer.swift:335-368) - the whole of this
 * port's `cameraOrientation` state: which way the device is held, which camera is open, and
 * the transform/angles that follow from the pair.
 */
export class CameraOrientationState {
  readonly orientation: DeviceOrientation;
  readonly cameraPosition: camera.CameraPosition;
  readonly layerTransform: CameraLayerTransform;
  /** Swift `imageOrientation` - the rotation a still image needs, in degrees. */
  readonly imageRotation: number;
  /** Swift `outgoingAngle` - the angle libjami's encoder was told about. */
  readonly outgoingAngle: number;

  private constructor(orientation: DeviceOrientation, cameraPosition: camera.CameraPosition,
                      layerTransform: CameraLayerTransform, imageRotation: number,
                      outgoingAngle: number) {
    this.orientation = orientation;
    this.cameraPosition = cameraPosition;
    this.layerTransform = layerTransform;
    this.imageRotation = imageRotation;
    this.outgoingAngle = outgoingAngle;
  }

  /** Swift `static func make(orientation:cameraPosition:)`. */
  static make(orientation: DeviceOrientation,
              cameraPosition: camera.CameraPosition): CameraOrientationState {
    const mirrored: boolean = cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT;
    const rotation: number = CameraOrientationState.previewRotation(orientation);
    return new CameraOrientationState(orientation, cameraPosition,
      new CameraLayerTransform(rotation, mirrored), rotation,
      CameraOrientationState.outgoingAngle(orientation, cameraPosition));
  }

  /**
   * Swift `AVCaptureVideoOrientation.localPreviewTransform(mirrored:)`, reduced to the
   * rotation it produced for a capture connection fixed at `.landscapeLeft`.
   */
  private static previewRotation(orientation: DeviceOrientation): number {
    if (orientation === DeviceOrientation.PORTRAIT) {
      return 90;
    }
    if (orientation === DeviceOrientation.PORTRAIT_UPSIDE_DOWN) {
      return 270;
    }
    if (orientation === DeviceOrientation.LANDSCAPE_RIGHT) {
      return 180;
    }
    return 0;
  }

  /** Swift `private static func outgoingAngle(orientation:cameraPosition:)` - verbatim. */
  private static outgoingAngle(orientation: DeviceOrientation,
                               cameraPosition: camera.CameraPosition): number {
    const front: boolean = cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT;
    if (orientation === DeviceOrientation.PORTRAIT) {
      return front ? 270 : 90;
    }
    if (orientation === DeviceOrientation.PORTRAIT_UPSIDE_DOWN) {
      return front ? 90 : 270;
    }
    if (orientation === DeviceOrientation.LANDSCAPE_LEFT) {
      return 180;
    }
    return 0;
  }

  /**
   * Swift `AVCaptureVideoOrientation.resolve(_:)` - the device orientation when it is a valid
   * interface orientation, else the interface one; null when neither is usable.
   */
  static resolve(input: DeviceOrientationInput): DeviceOrientation | null {
    if (input.device !== DeviceOrientation.UNKNOWN) {
      return input.device;
    }
    if (input.interface === DeviceOrientation.UNKNOWN) {
      return null;
    }
    // Swift `UIInterfaceOrientation.asDeviceOrientation`: landscape is inverted between the
    // two coordinate systems.
    if (input.interface === DeviceOrientation.LANDSCAPE_LEFT) {
      return DeviceOrientation.LANDSCAPE_RIGHT;
    }
    if (input.interface === DeviceOrientation.LANDSCAPE_RIGHT) {
      return DeviceOrientation.LANDSCAPE_LEFT;
    }
    return input.interface;
  }
}

/**
 * Swift `struct VideoFrame` (FrameDistributor.swift:24). Its `sampleBuffer` has no HarmonyOS
 * counterpart (see the header): what a renderer actually needs is the geometry.
 */
export class VideoFrame {
  readonly rotation: number;
  readonly width: number;
  readonly height: number;

  constructor(rotation: number, width: number, height: number) {
    this.rotation = rotation;
    this.width = width;
    this.height = height;
  }
}

/** Swift `enum FrameSource` - local camera, or one libjami sink. */
export class FrameSource {
  readonly isLocalCamera: boolean;
  readonly sinkId: SinkId | null;

  private constructor(isLocalCamera: boolean, sinkId: SinkId | null) {
    this.isLocalCamera = isLocalCamera;
    this.sinkId = sinkId;
  }

  static localCamera(): FrameSource {
    return new FrameSource(true, null);
  }

  static remote(sinkId: SinkId): FrameSource {
    return new FrameSource(false, sinkId);
  }
}

/**
 * Swift `final class FrameSubscription` - cancelled in `deinit`. ArkTS has no deinit, so the
 * holder calls `cancel()`; `DisposeBag` in `common/Observable.ts` takes the closure directly.
 */
export class FrameSubscription {
  private cancelHandler: (() => void) | null;

  constructor(cancel: () => void) {
    this.cancelHandler = cancel;
  }

  cancel(): void {
    const handler: (() => void) | null = this.cancelHandler;
    try {
      if (handler !== null) {
        handler();
      }
    } finally {
      this.cancelHandler = null;
    }
  }
}

/**
 * Swift `final class FrameDistributor` - fans one frame source out to its renderers and
 * replays the last frame to a late subscriber, so a tile scrolling back into view is sized
 * immediately.
 */
export class FrameDistributor {
  readonly source: FrameSource;

  private readonly onSubscribersChanged: (() => void) | null;
  private handlers: Map<number, (frame: VideoFrame) => void> = new Map<number,
    (frame: VideoFrame) => void>();
  private nextHandlerId: number = 0;
  private lastFrame: VideoFrame | null = null;

  constructor(source: FrameSource, onSubscribersChanged: (() => void) | null = null) {
    this.source = source;
    this.onSubscribersChanged = onSubscribersChanged;
  }

  /** Swift `func subscribe(_:) -> FrameSubscription`. */
  subscribe(handler: (frame: VideoFrame) => void): FrameSubscription {
    const id: number = this.nextHandlerId;
    this.nextHandlerId = id + 1;
    this.handlers.set(id, handler);
    const replay: VideoFrame | null = this.lastFrame;
    const changed: (() => void) | null = this.onSubscribersChanged;
    if (changed !== null) {
      changed();
    }
    if (replay !== null) {
      handler(replay);
    }
    return new FrameSubscription((): void => {
      this.remove(id);
    });
  }

  /** Swift `func distribute(_:)`. */
  distribute(frame: VideoFrame): void {
    this.lastFrame = frame;
    const current: Array<(frame: VideoFrame) => void> = [];
    this.handlers.forEach((handler: (frame: VideoFrame) => void): void => {
      current.push(handler);
    });
    for (const handler of current) {
      handler(frame);
    }
  }

  /** Swift `func clearCachedFrame()`. */
  clearCachedFrame(): void {
    this.lastFrame = null;
  }

  /** Swift `var subscriberCount: Int`. */
  get subscriberCount(): number {
    return this.handlers.size;
  }

  private remove(id: number): void {
    this.handlers.delete(id);
    const changed: (() => void) | null = this.onSubscribersChanged;
    if (changed !== null) {
      changed();
    }
  }
}

/** Swift `struct LocalFrameInfo` (Extensions/Video+Helpers.swift:25). */
export class LocalFrameInfo {
  readonly frame: VideoFrame;
  readonly layerTransform: CameraLayerTransform;
  readonly imageRotation: number;

  constructor(frame: VideoFrame, layerTransform: CameraLayerTransform, imageRotation: number) {
    this.frame = frame;
    this.layerTransform = layerTransform;
    this.imageRotation = imageRotation;
  }
}

/** Swift `struct VideoFrameInfo` (VideoService.swift:27) - a frame of one media-player sink. */
export class VideoFrameInfo {
  readonly rotation: number;
  readonly sinkId: string;
  readonly width: number;
  readonly height: number;

  constructor(rotation: number, sinkId: string, width: number, height: number) {
    this.rotation = rotation;
    this.sinkId = sinkId;
    this.width = width;
    this.height = height;
  }
}

/** Swift `struct Player` - media-player metadata. */
export class Player {
  playerId: string;
  duration: string;
  hasAudio: boolean;
  hasVideo: boolean;

  constructor(playerId: string, duration: string, hasAudio: boolean, hasVideo: boolean) {
    this.playerId = playerId;
    this.duration = duration;
    this.hasAudio = hasAudio;
    this.hasVideo = hasVideo;
  }
}

/** Swift `class FrameStream` - the incoming-frame holder for the media player. */
export class FrameStream {
  readonly frameSubject: PublishSubject<VideoFrameInfo> = new PublishSubject<VideoFrameInfo>();
}

/** How a resolved player source is delivered. DASH is absent on purpose - AVPlayer cannot play it. */
export enum MediaDelivery {
  PROGRESSIVE_HTTP = 'PROGRESSIVE_HTTP',
  HLS = 'HLS',
  LOCAL_FD = 'LOCAL_FD'
}

/** One AVPlayer-playable source: either an opened fd, or an http(s) URL. Never `file://`. */
export class MediaSource {
  readonly delivery: MediaDelivery;
  readonly url: string;
  readonly path: string;

  constructor(delivery: MediaDelivery, url: string, path: string) {
    this.delivery = delivery;
    this.url = url;
    this.path = path;
  }
}

/**
 * This is the app's MediaSourceResolver: the source-resolution tree of
 * `pipeline/reference/harmonyos-media-streaming.md` 3, applied
 * to what THIS app actually plays: a media-message attachment, which is a file on disk in
 * almost every case and a plain http(s) URL in the rest.
 *
 *   1. a local path                -> LOCAL_FD  (opened as fd://, because AVPlayer rejects file://)
 *   2. an .m3u8 URL                -> HLS
 *   3. any other http(s) URL       -> PROGRESSIVE_HTTP (one muxed file: the most reliable path)
 *   x. a .mpd URL                  -> REFUSED. AVPlayer cannot play MPEG-DASH (MS01).
 *
 * Steps 3 and 4 of the reference tree (synthesizing a local HLS manifest over loopback from
 * separate video-only + audio-only fMP4 tracks) have no input here: Jami never produces
 * separate adaptive tracks - a message attachment is one muxed file - so there is nothing to
 * synthesize and no loopback server to run.
 */
export function resolveSource(path: string): MediaSource | null {
  const lower: string = path.toLowerCase();
  if (lower.indexOf('.mpd') >= 0 || lower.indexOf('dashmanifest') >= 0) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'refusing a DASH source: AVPlayer cannot play it');
    return null;
  }
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    const delivery: MediaDelivery = lower.indexOf('.m3u8') >= 0
      ? MediaDelivery.HLS : MediaDelivery.PROGRESSIVE_HTTP;
    return new MediaSource(delivery, path, '');
  }
  // A local file. `file://` is stripped rather than passed through - AVPlayer rejects it.
  const plain: string = path.startsWith('file://') ? path.substring('file://'.length) : path;
  return new MediaSource(MediaDelivery.LOCAL_FD, '', plain);
}

/**
 * One live media player. Swift had libjami play the file and deliver frames; here it is a real
 * `media.AVPlayer`, so a message attachment genuinely plays.
 */
class MediaPlayerEntry {
  readonly playerId: string;
  player: media.AVPlayer | null = null;
  file: fs.File | null = null;
  /** Reference 3.4: intent recorded in a transient state, applied from the `prepared` callback. */
  playWhenReady: boolean = true;
  muted: boolean = false;
  lastKnownPosition: number = 0;
  closed: boolean = false;
  /** The extractor read no duration: the info is published from the player once it is prepared. */
  infoFromPlayer: boolean = false;

  constructor(playerId: string) {
    this.playerId = playerId;
  }
}

/**
 * Swift `final class VideoPipeline` - "coordinates the video path". Here: the Camera Kit
 * session, the AVRecorder and the AVPlayers, plus the frame-distributor registry that stands
 * in for libjami's sinks.
 */
export class VideoPipeline {
  /** Swift `let localFrames = FrameDistributor(source: .localCamera)`. */
  readonly localFrames: FrameDistributor = new FrameDistributor(FrameSource.localCamera());

  /** Swift `var onSourceDowngraded: ((SinkId, String) -> Void)?`. */
  onSourceDowngraded: ((sinkId: SinkId, source: string) => void) | null = null;

  /** Swift `var onFileOpened: ((String, [String: String]) -> Void)?`. */
  onFileOpened: ((playerId: string, info: Player) => void) | null = null;

  /** Swift `sinkRegistry` - one distributor per libjami sink id. */
  private readonly sinkDistributors: Map<string, FrameDistributor> =
    new Map<string, FrameDistributor>();

  /** Swift `private var orientationState = CameraOrientationState.make(...)`. */
  private orientationState: CameraOrientationState =
    CameraOrientationState.make(DeviceOrientation.PORTRAIT,
      camera.CameraPosition.CAMERA_POSITION_FRONT);

  /** Swift `private var currentDeviceId = ""`. */
  private currentDeviceId: string = '';

  /** Swift `private var codecByCallId: [String: String]`. */
  private readonly codecByCallId: Map<string, string> = new Map<string, string>();

  /** Swift `private var decodingSinks: Set<SinkId>` (keyed by raw id - ArkTS Sets are by identity). */
  private readonly decodingSinks: Set<string> = new Set<string>();

  /**
   * Swift `UserDefaults[hardareAccelerationKey]`, applied at every launch by
   * `registerCameraDevices` (`applyStoredAccelerationPreference`); the settings screen calls
   * `setHardwareAccelerated`.
   */
  private hardwareAccelerated: boolean = true;
  /** libjami is up and knows our cameras: its video settings can be written. */
  private devicesRegistered: boolean = false;

  private quality: CaptureQuality = CaptureQuality.HIGH;
  private defaultDeviceName: string = CAMERA_DEVICE_HIGH;

  private context: common.UIAbilityContext | null = null;
  private cameraManager: camera.CameraManager | null = null;
  private cameras: Array<camera.CameraDevice> = [];
  private cameraInput: camera.CameraInput | null = null;
  /** A VideoSession, or a PhotoSession while the photo screen is up. */
  private session: camera.Session | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  /** The running preview profile's size; the recorder's stream must share its aspect. */
  private previewSize: camera.Size | null = null;
  private videoOutput: camera.VideoOutput | null = null;
  private previewSurfaceId: string | null = null;
  /** The daemon input the camera feeds (libjami StartCapture), or null when it asked for none. */
  private daemonCaptureInput: string | null = null;
  /** The second preview output, writing into the native image receiver that feeds libjami. */
  private captureOutput: camera.PreviewOutput | null = null;
  private position: camera.CameraPosition = camera.CameraPosition.CAMERA_POSITION_FRONT;
  /** Swift's capture session had no "wanted but not yet possible" state; a surface can arrive late. */
  private captureRequested: boolean = false;
  private configuring: boolean = false;
  private reconfigurePending: boolean = false;
  /**
   * What the running session's camera was opened for (libjami input, quality, lens, photo). Asking
   * for the same again reopens nothing: the call screen asks on every call update, and each ask
   * closed and reopened the camera (T-1616). A camera error clears it, so the next ask rebuilds.
   */
  private sessionKey: string = '';
  /** The running session's preview surface; a new one is swapped in without reopening the camera. */
  private sessionSurface: string | null = null;
  /** The running session's stream profile, which a swapped-in preview must share. */
  private sessionProfile: camera.Profile | null = null;
  /** A held libjami StopCapture (STOP_CAPTURE_GRACE_MS), or -1. */
  private pendingStopCapture: number = -1;
  /**
   * A call is up, so the camera is libjami's: it runs between StartCapture and StopCapture, as on
   * iOS, where nothing but the call's warm-up starts the capture by itself. The call screen asks
   * for a preview on every update; while a call is up, that ask no longer opens the camera after
   * the user turned it off, nor in an audio call whose peer turned theirs on.
   */
  private callOwnsCamera: boolean = false;

  /**
   * The CAMERA/MICROPHONE user-grant, asked for once per process and shared by every entry
   * point (preview, camera switch, recorder). Only a GRANT is remembered: a refusal the user
   * later lifts in Settings has to be seen on the next attempt.
   */
  private permissionGate: Promise<boolean> | null = null;

  /** Raised when the user-grant was refused, so the recorder UI can say so out loud. */
  onMediaPermissionDenied: (() => void) | null = null;

  /** The chat's photo screen is up: the session carries a still output (T-0755). */
  private photoRequested: boolean = false;
  private photoOutput: camera.PhotoOutput | null = null;
  /** Hears the next `photoAvailable`; given null when the session goes before the photo comes. */
  private photoWaiter: ((photo: camera.Photo | null) => void) | null = null;

  private recorder: media.AVRecorder | null = null;
  private recorderFile: fs.File | null = null;
  private recorderPath: string = '';
  /** libjami's camera input the recorder page keeps open (Swift `openVideoInput`), or null. */
  private recorderInput: string | null = null;
  /** The take libjami is writing (Swift `startLocalRecording`'s path), or null. */
  private localRecording: string | null = null;

  private readonly players: Map<string, MediaPlayerEntry> = new Map<string, MediaPlayerEntry>();
  private nextPlayerId: number = 0;

  // MARK: - Injected OS handles

  /** The ability calls this once at startup; a .ts module cannot call `getContext()`. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /**
   * The preview XComponent hands its surface id over on load (and `null` on unload). This
   * replaces iOS's per-frame delivery: HarmonyOS renders camera output straight to a surface.
   */
  setPreviewSurface(surfaceId: string | null): void {
    this.previewSurfaceId = surfaceId;
    if (surfaceId === null && this.daemonCaptureInput !== null) {
      // libjami still encodes the camera (the call screen closed under picture-in-picture):
      // only the on-screen preview goes, the peer keeps the video.
      this.configureSession()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'dropping the preview failed: %{public}s', describeError(error));
        });
      return;
    }
    if (surfaceId === null) {
      this.teardownSession();
      return;
    }
    if (this.daemonCaptureInput !== null) {
      // libjami's capture is running: the preview joins it.
      this.configureSession()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'adding the preview failed: %{public}s', describeError(error));
        });
    } else if (this.captureRequested) {
      this.startPreviewCapture();
    }
  }

  /** CallsManager: a call is up (true) or none is left (false). */
  setCallOwnsCamera(owns: boolean): void {
    this.callOwnsCamera = owns;
  }

  /** A screen asked for the camera without libjami: never the call screen once its call is up. */
  private previewOnlyAllowed(): boolean {
    return this.captureRequested && (!this.callOwnsCamera || this.photoRequested);
  }

  // MARK: - Device setup

  /**
   * Swift `func setupDevices()` - permission, then register the capture devices. The
   * permission request and the enumeration are real; only `addVideoDevice` (registering them
   * WITH libjami) is the gap.
   */
  setupDevices(): void {
    this.runSetupDevices()
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'device setup failed: %{public}s',
          describeError(error));
      });
  }

  private async runSetupDevices(): Promise<void> {
    const granted: boolean = await this.ensurePermission();
    if (!granted) {
      return;
    }
    const manager: camera.CameraManager | null = this.ensureCameraManager();
    if (manager === null) {
      return;
    }
    this.cameras = manager.getSupportedCameras();
    if (this.cameras.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no camera on this device');
      return;
    }
    // A preview already asked for keeps its quality: when the grant dialog held this setup back,
    // the record page's medium camera came first and must not reopen at HIGH (T-0763).
    const quality: CaptureQuality = this.quality;
    this.setHardwareAccelerated(this.hardwareAccelerated);
    if (this.captureRequested) {
      this.quality = quality;
    }
  }

  /**
   * Swift `capturer.ensurePermission()` - AVCaptureDevice authorization. Every path that opens
   * the camera or the microphone goes through here, so the grant is requested BEFORE the device
   * is touched rather than after the OS has already refused the open.
   */
  private ensurePermission(): Promise<boolean> {
    const pending: Promise<boolean> | null = this.permissionGate;
    if (pending !== null) {
      return pending;
    }
    const gate: Promise<boolean> = this.requestMediaPermissions()
      .then((granted: boolean): boolean => {
        if (!granted) {
          this.permissionGate = null;
          const handler: (() => void) | null = this.onMediaPermissionDenied;
          if (handler !== null) {
            handler();
          }
        }
        return granted;
      });
    this.permissionGate = gate;
    return gate;
  }

  /** Camera and microphone, for a video call. */
  ensureCameraAndMicrophonePermission(): Promise<boolean> {
    return this.ensurePermission();
  }

  /**
   * Swift `setupDevices()`' libjami half: the camera presets libjami may open. The app owns the
   * camera (as on iOS); libjami asks for frames with StartCapture.
   */
  registerCameraDevices(): void {
    jami.addVideoDevice(CAMERA_DEVICE_HIGH, [{
      format: 'NV21', width: HIGH_WIDTH.toString(), height: HIGH_HEIGHT.toString(), rate: '30'
    }]);
    jami.addVideoDevice(CAMERA_DEVICE_MEDIUM, [{
      format: 'NV21', width: MEDIUM_WIDTH.toString(), height: MEDIUM_HEIGHT.toString(), rate: '30'
    }]);
    this.devicesRegistered = true;
    // Swift `applyStoredAccelerationPreference()`: the stored switch, on when never set, reaches
    // libjami at every launch (T-1593: a cold relaunch went back to 1280x720).
    this.setHardwareAccelerated(PreferenceManager.isHardwareAccelerationEnabled());
  }

  /** libjami StartCapture: open the camera (if needed) with a second output feeding `device`. */
  daemonStartCapture(device: string): void {
    hilog.info(LOG_DOMAIN, F4_TAG, 'libjami StartCapture %{public}s', device);
    if (this.pendingStopCapture !== -1) {
      // The sender restarted: the session that feeds this input stays as it is.
      clearTimeout(this.pendingStopCapture);
      this.pendingStopCapture = -1;
      hilog.info(LOG_DOMAIN, F4_TAG, 'held StopCapture cancelled');
    }
    this.daemonCaptureInput = device;
    this.quality = device === CAMERA_DEVICE_MEDIUM ? CaptureQuality.MEDIUM : CaptureQuality.HIGH;
    this.configureSession()
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'starting capture failed: %{public}s', describeError(error));
      });
  }

  /** libjami StopCapture. */
  daemonStopCapture(device: string): void {
    hilog.info(LOG_DOMAIN, F4_TAG, 'libjami StopCapture %{public}s', device);
    if (this.daemonCaptureInput !== device || this.pendingStopCapture !== -1) {
      return;
    }
    this.pendingStopCapture = setTimeout((): void => {
      this.pendingStopCapture = -1;
      this.stopDaemonCapture(device);
    }, STOP_CAPTURE_GRACE_MS);
  }

  /** The camera stops feeding `device`; in a call (Swift `capturer.stop()`) it goes altogether. */
  private stopDaemonCapture(device: string): void {
    if (this.daemonCaptureInput !== device) {
      return;
    }
    this.daemonCaptureInput = null;
    if (this.previewOnlyAllowed() && this.previewSurfaceId !== null) {
      this.configureSession()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'restarting preview failed: %{public}s', describeError(error));
        });
    } else {
      this.teardownSession();
    }
    jami.stopCapture();
  }

  /** Microphone only — an audio call must not prompt for the camera. */
  ensureMicrophonePermission(): Promise<boolean> {
    return this.requestPermission('ohos.permission.MICROPHONE');
  }

  /**
   * Camera only — a still photo must not prompt for the microphone (iOS's picker asks for the
   * camera alone). Not remembered in `permissionGate`, which stands for both grants.
   */
  private async ensureCameraPermission(): Promise<boolean> {
    const granted: boolean = await this.requestPermission('ohos.permission.CAMERA');
    const denied: (() => void) | null = this.onMediaPermissionDenied;
    if (!granted && denied !== null) {
      denied();
    }
    return granted;
  }

  private async requestPermission(permission: Permissions): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      return false;
    }
    try {
      const result: PermissionRequestResult = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, [permission]);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s request failed: %{public}s', permission,
        describeError(error as BusinessError));
      return false;
    }
  }

  private async requestMediaPermissions(): Promise<boolean> {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no context; call setContext at startup');
      return false;
    }
    const wanted: Array<Permissions> = ['ohos.permission.CAMERA', 'ohos.permission.MICROPHONE'];
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, wanted);
      const results: Array<number> = result.authResults;
      for (const status of results) {
        if (status !== 0) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'camera/microphone permission denied');
          return false;
        }
      }
      return results.length > 0;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'permission request failed: %{public}s',
        describeError(failure));
      return false;
    }
  }

  private ensureCameraManager(): camera.CameraManager | null {
    let manager: camera.CameraManager | null = this.cameraManager;
    if (manager !== null) {
      return manager;
    }
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no context; call setContext at startup');
      return null;
    }
    try {
      manager = camera.getCameraManager(context);
      this.cameraManager = manager;
      return manager;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'getCameraManager failed: %{public}s',
        describeError(failure));
      return null;
    }
  }

  /** Swift `func setHardwareAccelerated(_:)`: libjami's decode/encode switches and default device. */
  setHardwareAccelerated(enabled: boolean): void {
    this.hardwareAccelerated = enabled;
    if (this.devicesRegistered) {
      jami.setDecodingAccelerated(enabled);
      jami.setEncodingAccelerated(enabled);
      // What libjami kept: a build without hardware acceleration reads back false for both,
      // while the encode switch still turns H.265 on or off in every account.
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'video acceleration %{public}s: libjami decoding %{public}s, encoding %{public}s', String(enabled),
        String(jami.getDecodingAccelerated()), String(jami.getEncodingAccelerated()));
    }
    this.setDefaultDevice(enabled ? CAMERA_DEVICE_HIGH : CAMERA_DEVICE_MEDIUM);
    this.quality = enabled ? CaptureQuality.HIGH : CaptureQuality.MEDIUM;
    this.setCurrentDeviceId(this.defaultDeviceName);
  }

  /** Swift `func restoreDefaultDevice()` - after a downgraded call, go back to high. */
  restoreDefaultDevice(): void {
    if (this.hardwareAccelerated && this.defaultDeviceName === CAMERA_DEVICE_MEDIUM) {
      this.setDefaultDevice(CAMERA_DEVICE_HIGH);
      this.quality = CaptureQuality.HIGH;
    }
    this.setCurrentDeviceId(this.defaultDeviceName);
  }

  // MARK: - Capture

  /** Swift `func videoSource() -> String`. */
  videoSource(): string {
    return VideoPipeline.cameraSourceURI(this.currentDeviceId);
  }

  private setCurrentDeviceId(identifier: string): void {
    this.currentDeviceId = identifier;
  }

  /**
   * Swift `video.setDefaultDevice(_:)`: libjami opens its default device for a call it answers,
   * so keeping the name here alone left answered calls at 1280x720 (T-1593).
   */
  private setDefaultDevice(name: string): void {
    this.defaultDeviceName = name;
    if (this.devicesRegistered) {
      jami.setDefaultDevice(name);
    }
  }

  /** Swift `static func cameraSourceURI(from:)`. */
  static cameraSourceURI(source: string): string {
    return source.startsWith(CAMERA_SOURCE_PREFIX) ? source : CAMERA_SOURCE_PREFIX + source;
  }

  /** Swift `func setVideoCodec(_:forCallId:)`. */
  setVideoCodec(codec: string | null, callId: string): void {
    if (codec === null || codec.length === 0) {
      this.codecByCallId.delete(callId);
      return;
    }
    this.codecByCallId.set(callId, codec);
    const sinks: Array<SinkId> = [];
    this.decodingSinks.forEach((raw: string): void => {
      const sink: SinkId = new SinkId(raw);
      if (sink.baseId === callId) {
        sinks.push(sink);
      }
    });
    for (const sink of sinks) {
      this.downgradeCaptureIfSoftwareEncoded(sink);
    }
  }

  /**
   * Swift `private func downgradeCaptureIfSoftwareEncoded(_:)`. Pure local policy, kept whole:
   * hardware acceleration only covers H264/H265, so anything else drops capture to the medium
   * device and asks the call layer to re-invite with the new source.
   */
  private downgradeCaptureIfSoftwareEncoded(sink: SinkId): void {
    const codec: string | undefined = this.codecByCallId.get(sink.baseId);
    if (codec === undefined || codec.length === 0
      || codec === HARDWARE_CODEC_H264 || codec === HARDWARE_CODEC_H265) {
      return;
    }
    if (this.quality !== CaptureQuality.HIGH) {
      return;
    }
    this.setDefaultDevice(CAMERA_DEVICE_MEDIUM);
    this.quality = CaptureQuality.MEDIUM;
    this.setCurrentDeviceId(CAMERA_DEVICE_MEDIUM);
    const handler: ((sinkId: SinkId, source: string) => void) | null = this.onSourceDowngraded;
    if (handler !== null) {
      handler(sink, VideoPipeline.cameraSourceURI(CAMERA_DEVICE_MEDIUM));
    }
  }

  /** Swift `func startPreviewCapture()`. */
  startPreviewCapture(): void {
    this.captureRequested = true;
    this.localFrames.clearCachedFrame();
    if (this.daemonCaptureInput === null && !this.previewOnlyAllowed()) {
      // The call's camera is off: libjami's StartCapture opens it, with this preview.
      return;
    }
    this.configureSession()
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'starting preview failed: %{public}s',
          describeError(error));
      });
  }

  /** Swift `func stopPreviewCapture()`. */
  stopPreviewCapture(): void {
    this.captureRequested = false;
    if (this.daemonCaptureInput !== null) {
      // libjami still encodes the camera; only the on-screen preview goes.
      return;
    }
    this.teardownSession();
    this.localFrames.clearCachedFrame();
  }

  /** Swift `func switchCamera() async` - on return the preview transform is already recomputed. */
  switchCamera(): void {
    this.position = this.position === camera.CameraPosition.CAMERA_POSITION_FRONT
      ? camera.CameraPosition.CAMERA_POSITION_BACK
      : camera.CameraPosition.CAMERA_POSITION_FRONT;
    this.applyCameraPosition();
  }

  /**
   * Swift `func resetCameraPosition() async`. Deliberately NOT async here: `CallsManager`
   * calls it bare, with no `await` and no `.catch`, so it must never return a rejecting
   * promise (an unhandled rejection would take the ability's thread with it).
   */
  resetCameraPosition(): void {
    if (this.position === camera.CameraPosition.CAMERA_POSITION_FRONT) {
      return;
    }
    this.position = camera.CameraPosition.CAMERA_POSITION_FRONT;
    this.applyCameraPosition();
  }

  private applyCameraPosition(): void {
    this.orientationState = CameraOrientationState.make(this.orientationState.orientation,
      this.position);
    this.publishLocalGeometry();
    if (this.captureRequested) {
      this.configureSession()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'camera switch failed: %{public}s',
            describeError(error));
        });
    }
  }

  /** Swift `func setOrientation(_:) -> Bool` - true when anything changed. */
  setOrientation(input: DeviceOrientationInput): boolean {
    const orientation: DeviceOrientation | null = CameraOrientationState.resolve(input);
    if (orientation === null || orientation === this.orientationState.orientation) {
      return false;
    }
    this.orientationState = CameraOrientationState.make(orientation,
      this.orientationState.cameraPosition);
    this.publishLocalGeometry();
    return true;
  }

  /** Swift `var localLayerTransform: CGAffineTransform`. */
  get localLayerTransform(): CameraLayerTransform {
    return this.orientationState.layerTransform;
  }

  /** Swift `var localImageOrientation: UIImage.Orientation`. */
  get localImageOrientation(): number {
    return this.orientationState.imageRotation;
  }

  /**
   * Swift's `handleCapturedFrame` distributed every camera frame. HarmonyOS delivers frames to
   * a surface, so what the distributor carries is the geometry, published whenever it changes.
   */
  private publishLocalGeometry(): void {
    const state: CameraOrientationState = this.orientationState;
    const width: number = this.quality === CaptureQuality.HIGH ? HIGH_WIDTH : MEDIUM_WIDTH;
    const height: number = this.quality === CaptureQuality.HIGH ? HIGH_HEIGHT : MEDIUM_HEIGHT;
    this.localFrames.distribute(new VideoFrame(state.layerTransform.rotationDegrees,
      width, height));
  }

  // MARK: - Session lifecycle

  private static sessionKeyOf(input: string | null, quality: CaptureQuality, position: camera.CameraPosition,
    photo: boolean): string {
    return `${input}|${quality}|${position}|${photo}`;
  }

  private async configureSession(): Promise<void> {
    if (this.configuring) {
      // A request that lands mid-configuration (libjami's StartCapture racing the preview)
      // runs again once the current one finishes, with whatever outputs are wanted then.
      this.reconfigurePending = true;
      return;
    }
    const surfaceId: string | null = this.previewSurfaceId;
    if (surfaceId === null && this.daemonCaptureInput === null) {
      // The UI has not offered a surface yet; `setPreviewSurface` retries when it does.
      hilog.info(LOG_DOMAIN, LOG_TAG, 'preview requested before a surface was available');
      return;
    }
    const wantsPhoto: boolean = this.photoRequested;
    const sameCamera: boolean = this.session !== null && this.sessionKey === VideoPipeline.sessionKeyOf(
      this.daemonCaptureInput, this.quality, this.position, wantsPhoto);
    if (sameCamera && this.sessionSurface === surfaceId) {
      return;
    }
    this.configuring = true;
    try {
      // Only the preview changed (the self-view tile came after libjami's StartCapture, or the
      // call screen went): swapped in place, the camera stays open. The photo output hangs on
      // the preview, so the photo screen rebuilds.
      if (sameCamera && !wantsPhoto && await this.swapPreview(surfaceId)) {
        return;
      }
      await this.buildSession(surfaceId, wantsPhoto);
    } finally {
      this.configuring = false;
      if (this.daemonCaptureInput === null && !this.previewOnlyAllowed()) {
        // Stopped while this configuration was in flight (a camera screen closed during the
        // grant dialog or the session start): the session it built is nobody's (T-0755).
        this.teardownSession();
      }
      if (this.reconfigurePending) {
        this.reconfigurePending = false;
        this.configureSession()
          .catch((error: BusinessError): void => {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'camera reconfiguration failed: %{public}s', describeError(error));
          });
      }
    }
  }

  /**
   * The running session takes `surfaceId` as its preview (null: none) without closing the camera.
   * beginConfig stops its streams (T-0763), so it is started again. False when that failed: the
   * session is gone and the caller opens a new one.
   */
  private async swapPreview(surfaceId: string | null): Promise<boolean> {
    const session: camera.Session | null = this.session;
    const manager: camera.CameraManager | null = this.ensureCameraManager();
    const profile: camera.Profile | null = this.sessionProfile;
    if (session === null || manager === null || profile === null) {
      return false;
    }
    const started: number = Date.now();
    const old: camera.PreviewOutput | null = this.previewOutput;
    let next: camera.PreviewOutput | null = null;
    try {
      next = surfaceId === null ? null : manager.createPreviewOutput(profile, surfaceId);
      session.beginConfig();
      if (old !== null) {
        session.removeOutput(old);
      }
      if (next !== null) {
        session.addOutput(next);
      }
      await session.commitConfig();
      await session.start();
    } catch (error) {
      VideoPipeline.releaseUnadopted(null, null, [next]);
      if (this.session !== session) {
        // Torn down under the swap (libjami stopped capturing): nothing left to repair.
        return true;
      }
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'swapping the preview failed: %{public}s; reopening the camera',
        describeError(error as BusinessError));
      this.teardownSession();
      return false;
    }
    if (this.session !== session) {
      // Torn down meanwhile (libjami stopped capturing): the new preview has nowhere to go.
      VideoPipeline.releaseUnadopted(null, null, [next]);
      return true;
    }
    this.previewOutput = next;
    this.sessionSurface = surfaceId;
    VideoPipeline.releaseUnadopted(null, null, [old]);
    hilog.info(LOG_DOMAIN, F4_TAG, 'camera kept open: preview %{public}s +%{public}d ms',
      surfaceId === null ? 'none' : 'on', Date.now() - started);
    return true;
  }

  /**
   * Opens the camera with the outputs wanted now. Whatever it opened and did not hand to the
   * pipeline is closed on the way out: at hang-up a commitConfig with nothing left to output
   * failed, and the camera it had opened stayed on until a force-stop (review-f-9).
   */
  private async buildSession(surfaceId: string | null, wantsPhoto: boolean): Promise<void> {
    const started: number = Date.now();
    hilog.info(LOG_DOMAIN, F4_TAG, 'camera open requested: preview %{public}s, libjami input %{public}s',
      surfaceId === null ? 'none' : 'on', this.daemonCaptureInput ?? 'none');
    // The grant comes FIRST: `input.open()` fails with "have no permission" otherwise, and
    // that failure used to be logged and swallowed, leaving a dead preview area.
    // The photo screen takes stills in the photo mode, unless libjami is encoding the camera.
    const photoMode: boolean = wantsPhoto && this.daemonCaptureInput === null;
    const granted: boolean = photoMode ? await this.ensureCameraPermission() : await this.ensurePermission();
    if (!granted) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'preview not started: the camera/microphone grant was refused');
      return;
    }
    const manager: camera.CameraManager | null = this.ensureCameraManager();
    if (manager === null) {
      return;
    }
    this.teardownSession();
    if (this.cameras.length === 0) {
      this.cameras = manager.getSupportedCameras();
    }
    // Read in the same turn as selectCamera / selectPreviewProfile, which build from them.
    const quality: CaptureQuality = this.quality;
    const position: camera.CameraPosition = this.position;
    const device: camera.CameraDevice | null = this.selectCamera();
    if (device === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no camera matches the requested position');
      return;
    }
    const mode: camera.SceneMode = photoMode ? camera.SceneMode.NORMAL_PHOTO : camera.SceneMode.NORMAL_VIDEO;
    const capability: camera.CameraOutputCapability = manager.getSupportedOutputCapability(device, mode);
    const profile: camera.Profile | null = this.selectPreviewProfile(capability);
    if (profile === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'the camera offers no preview profile');
      return;
    }
    // Every handle below is closed in `finally` unless the pipeline took it.
    let input: camera.CameraInput | null = null;
    let session: camera.Session | null = null;
    let preview: camera.PreviewOutput | null = null;
    let capture: camera.PreviewOutput | null = null;
    let photo: camera.PhotoOutput | null = null;
    try {
      const opened: camera.CameraInput = manager.createCameraInput(device);
      input = opened;
      await opened.open();
      hilog.info(LOG_DOMAIN, F4_TAG, 'camera input opened +%{public}d ms', Date.now() - started);
      opened.on('error', device, (error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'camera error %{public}d: the next request reopens it', error.code);
        if (this.cameraInput === opened) {
          this.sessionKey = '';
        }
      });
      if (surfaceId !== null) {
        preview = manager.createPreviewOutput(profile, surfaceId);
        preview.on('frameStart', (): void => {
          hilog.info(LOG_DOMAIN, F4_TAG, 'first preview frame +%{public}d ms', Date.now() - started);
        });
      }
      // The encoder half (Swift `writeOutgoingFrame`): frames go natively to libjami's input,
      // tagged with the sensor's mounting angle. Read after the open: libjami may have stopped.
      const daemonInput: string | null = this.daemonCaptureInput;
      if (daemonInput !== null) {
        // libjami keys its inputs by the camera:// resource, StartCapture names the device.
        const captureSurface: string = jami.startCapture(VideoPipeline.cameraSourceURI(daemonInput),
          profile.size.width,
          // The display matrix turns counter-clockwise; the sensor angle is clockwise.
          profile.size.height, (360 - device.cameraOrientation) % 360);
        if (captureSurface.length > 0) {
          capture = manager.createPreviewOutput(profile, captureSurface);
          capture.on('frameStart', (): void => {
            hilog.info(LOG_DOMAIN, F4_TAG, 'first camera frame toward libjami +%{public}d ms', Date.now() - started);
          });
        } else {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'no capture surface for %{public}s', daemonInput);
        }
      }
      if (preview === null && capture === null) {
        // libjami stopped capturing while the camera opened, and no screen shows a preview.
        hilog.info(LOG_DOMAIN, F4_TAG, 'camera open dropped: nothing to output');
        return;
      }
      photo = wantsPhoto && preview !== null ? this.createPhotoOutput(manager, capability, profile.size) : null;
      const built: camera.Session = manager.createSession<camera.Session>(mode);
      session = built;
      built.beginConfig();
      built.addInput(opened);
      if (preview !== null) {
        built.addOutput(preview);
      }
      if (capture !== null) {
        built.addOutput(capture);
      }
      if (photo !== null && !built.canAddOutput(photo)) {
        // The preview still runs; only the shutter has nothing to take.
        hilog.error(LOG_DOMAIN, LOG_TAG, 'the session refuses a photo output');
        VideoPipeline.releaseUnadopted(null, null, [photo]);
        photo = null;
      }
      if (photo !== null) {
        built.addOutput(photo);
      }
      await built.commitConfig();
      await built.start();
      this.cameraInput = opened;
      this.previewOutput = preview;
      this.captureOutput = capture;
      this.photoOutput = photo;
      this.session = built;
      input = null;
      session = null;
      preview = null;
      capture = null;
      photo = null;
      this.sessionKey = VideoPipeline.sessionKeyOf(daemonInput, quality, position, wantsPhoto);
      this.sessionSurface = surfaceId;
      this.sessionProfile = profile;
      this.previewSize = profile.size;
      this.setCurrentDeviceId(this.defaultDeviceName);
      this.publishLocalGeometry();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'camera preview started on %{public}s at %{public}dx%{public}d',
        device.cameraId, profile.size.width, profile.size.height);
      hilog.info(LOG_DOMAIN, F4_TAG, 'camera session started +%{public}d ms', Date.now() - started);
    } finally {
      if (input !== null) {
        hilog.info(LOG_DOMAIN, F4_TAG, 'camera closed: the open did not complete');
      }
      VideoPipeline.releaseUnadopted(input, session, [preview, capture, photo]);
    }
  }

  /** Releases camera handles a build or a swap made but never handed to the pipeline. */
  private static releaseUnadopted(input: camera.CameraInput | null, session: camera.Session | null,
    outputs: Array<camera.CameraOutput | null>): void {
    const failed = (error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing an unused camera handle failed: %{public}s', describeError(error));
    };
    try {
      for (const output of outputs) {
        if (output !== null) {
          output.release().catch(failed);
        }
      }
      if (session !== null) {
        session.release().catch(failed);
      }
      if (input !== null) {
        input.close().catch(failed);
      }
    } catch (error) {
      failed(error as BusinessError);
    }
  }

  private selectCamera(): camera.CameraDevice | null {
    for (const device of this.cameras) {
      if (device.cameraPosition === this.position) {
        return device;
      }
    }
    return this.cameras.length > 0 ? this.cameras[0] : null;
  }

  private selectPreviewProfile(capability: camera.CameraOutputCapability): camera.Profile | null {
    const wantedWidth: number = this.quality === CaptureQuality.HIGH ? HIGH_WIDTH : MEDIUM_WIDTH;
    const wantedHeight: number = this.quality === CaptureQuality.HIGH ? HIGH_HEIGHT : MEDIUM_HEIGHT;
    return pickProfile(capability.previewProfiles, wantedWidth, wantedHeight, wantedWidth * wantedHeight);
  }

  /**
   * The still output for the photo screen: a JPEG profile with the preview's aspect (a session
   * refuses mixed aspects, T-0763), nearest PHOTO_AREA. Its listener answers `capturePhoto`.
   */
  private createPhotoOutput(manager: camera.CameraManager, capability: camera.CameraOutputCapability,
    preview: camera.Size): camera.PhotoOutput | null {
    const jpeg: Array<camera.Profile> = capability.photoProfiles.filter((candidate: camera.Profile): boolean =>
      candidate.format === camera.CameraFormat.CAMERA_FORMAT_JPEG);
    const profile: camera.Profile | null = pickProfile(jpeg, preview.width, preview.height, PHOTO_AREA);
    // pickProfile falls back to any aspect; a mismatched still would take the preview down with it.
    if (profile === null || profile.size.width * preview.height !== profile.size.height * preview.width) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'the camera offers no JPEG photo profile of the preview aspect');
      return null;
    }
    const output: camera.PhotoOutput = manager.createPhotoOutput(profile);
    output.on('photoAvailable', (error: BusinessError, photo: camera.Photo): void => {
      const waiter: ((photo: camera.Photo | null) => void) | null = this.photoWaiter;
      this.photoWaiter = null;
      if (error) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'no photo: %{public}s', describeError(error));
        if (waiter !== null) {
          waiter(null);
        }
        return;
      }
      if (waiter !== null) {
        waiter(photo);
      } else {
        photo.release().catch((failure: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing a photo failed: %{public}s', describeError(failure));
        });
      }
    });
    hilog.info(LOG_DOMAIN, LOG_TAG, 'photo output at %{public}dx%{public}d', profile.size.width,
      profile.size.height);
    return output;
  }

  /**
   * Takes one still into `path` as a JPEG. False when there is no photo output, a shot is
   * already running, or the session went before the photo came.
   */
  async capturePhoto(path: string): Promise<boolean> {
    const output: camera.PhotoOutput | null = this.photoOutput;
    if (output === null || this.photoWaiter !== null) {
      return false;
    }
    const arrived: Promise<camera.Photo | null> = new Promise<camera.Photo | null>(
      (resolve: (photo: camera.Photo | null) => void): void => { this.photoWaiter = resolve; });
    try {
      // Swift `jpegData(compressionQuality: 0.5)`; the device's own rotation, as UIKit's picker.
      await output.capture({
        quality: camera.QualityLevel.QUALITY_LEVEL_MEDIUM,
        rotation: output.getPhotoRotation()
      });
    } catch (error) {
      this.photoWaiter = null;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'capture failed: %{public}s', describeError(error as BusinessError));
      return false;
    }
    const photo: camera.Photo | null = await arrived;
    if (photo === null) {
      return false;
    }
    try {
      const component: image.Component = await photo.main.getComponent(image.ComponentType.JPEG);
      const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
      try {
        fs.writeSync(file.fd, component.byteBuffer);
      } finally {
        fs.closeSync(file);
      }
      return true;
    } finally {
      // The photo's image buffer is native, as every camera handle (Rule 8).
      photo.release().catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing a photo failed: %{public}s', describeError(error));
      });
    }
  }

  /** Every camera handle is native and is not reclaimed by GC - released here (Rule 8). */
  private teardownSession(): void {
    const session: camera.Session | null = this.session;
    const preview: camera.PreviewOutput | null = this.previewOutput;
    const capture: camera.PreviewOutput | null = this.captureOutput;
    const photo: camera.PhotoOutput | null = this.photoOutput;
    const waiter: ((photo: camera.Photo | null) => void) | null = this.photoWaiter;
    const videoOutput: camera.VideoOutput | null = this.videoOutput;
    const input: camera.CameraInput | null = this.cameraInput;
    try {
      const onReleaseFailure: (error: BusinessError) => void = (error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing a camera handle failed: %{public}s',
          describeError(error));
      };
      if (session !== null) {
        session.stop()
          .then((): Promise<void> => session.release())
          .catch(onReleaseFailure);
      }
      if (preview !== null) {
        preview.release().catch(onReleaseFailure);
      }
      if (capture !== null) {
        capture.release().catch(onReleaseFailure);
      }
      if (photo !== null) {
        photo.release().catch(onReleaseFailure);
      }
      if (videoOutput !== null) {
        videoOutput.release().catch(onReleaseFailure);
      }
      if (input !== null) {
        input.close().catch(onReleaseFailure);
      }
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing the camera session failed: %{public}s',
        describeError(failure));
    } finally {
      this.session = null;
      this.previewOutput = null;
      this.captureOutput = null;
      this.photoOutput = null;
      this.videoOutput = null;
      this.cameraInput = null;
      // A shot still waiting will not come from this session.
      this.photoWaiter = null;
      if (waiter !== null) {
        waiter(null);
      }
    }
  }

  // MARK: - libjami wiring (gap)

  /** Swift `func attachToAdapter()` - installs the VideoAdapter delegates. */
  attachToAdapter(): void {
    // JamiNative routes libjami's video signals here.
  }

  /**
   * Swift `sinkRegistry.distributor(for:)`. The registry itself is real, and a renderer can
   * subscribe exactly as before - but nothing feeds a REMOTE sink: decoded frames come from
   * the daemon. Reported once per sink, at the build-only level, so a call screen full of
   * tiles does not flood the user-facing notice channel.
   */
  distributor(sinkId: SinkId): FrameDistributor {
    let distributor: FrameDistributor | undefined = this.sinkDistributors.get(sinkId.raw);
    if (distributor === undefined) {
      distributor = new FrameDistributor(FrameSource.remote(sinkId));
      this.sinkDistributors.set(sinkId.raw, distributor);
    }
    return distributor;
  }

  // MARK: - Local recorder (media messages): libjami for video, AVRecorder for voice

  /**
   * Swift `video.openVideoInput(camera://mediumCamera)`: libjami's camera input, which asks for
   * the camera with StartCapture, so the preview session also feeds libjami while the recorder
   * page is up. Only the recorder page opens it (the photo screen shares openMediumCameraInput).
   */
  openRecorderInput(): void {
    if (this.recorderInput === null) {
      this.recorderInput = jami.openVideoInput(VideoPipeline.cameraSourceURI(CAMERA_DEVICE_MEDIUM));
    }
  }

  /** Swift `video.closeVideoInput(...)`; the camera's libjami output goes with it. */
  closeRecorderInput(): void {
    const input: string | null = this.recorderInput;
    if (input === null) {
      return;
    }
    this.recorderInput = null;
    jami.closeVideoInput(input);
    // libjami's StopCapture follows as a signal; acting on it now drops the capture output
    // before the page lets go of the preview surface, instead of rebuilding a capture-only
    // session first. The late signal then finds nothing to stop.
    const capturing: string | null = this.daemonCaptureInput;
    if (capturing !== null && VideoPipeline.cameraSourceURI(capturing) === input) {
      if (this.pendingStopCapture !== -1) {
        clearTimeout(this.pendingStopCapture);
        this.pendingStopCapture = -1;
      }
      this.stopDaemonCapture(capturing);
    }
  }

  /**
   * Swift `func startLocalRecorder(audioOnly:path:) -> String?`. A video message is recorded by
   * libjami from its camera input, as iOS does (`startLocalMediaRecorder`): its MediaRecorder
   * turns the frames upright by their display matrix and writes the .webm (VP8 + Opus) iOS
   * sends. AVRecorder only tags the rotation, which iOS's player drops: the take played
   * sideways there (T-1619). A voice message stays on AVRecorder (.m4a); so does a video
   * message libjami refuses. Synchronous, as the callers expect: it returns the path written.
   */
  startLocalRecorder(audioOnly: boolean, path: string): string | null {
    if (this.recorder !== null || this.localRecording !== null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'a recording is already running');
      return null;
    }
    const input: string | null = this.recorderInput;
    if (!audioOnly && input !== null) {
      const recorded: string = jami.startLocalMediaRecorder(input, path);
      if (recorded.length > 0) {
        this.localRecording = recorded;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'libjami recording %{public}s -> %{public}s', input, recorded);
        return recorded;
      }
      hilog.error(LOG_DOMAIN, LOG_TAG, 'libjami refused to record %{public}s; recording with AVRecorder', input);
    }
    // libjami's MediaRecorder::getPath() appends its container's extension (.ogg / .webm) and
    // returns that path; AVRecorder writes MPEG-4 audio or video, so this one is .m4a / .mp4
    // (T-1698). The caller records, plays and sends whatever path comes back.
    const target: string = path + (audioOnly ? '.m4a' : '.mp4');
    this.recorderPath = target;
    this.runStartLocalRecorder(audioOnly, target)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'starting the recorder failed: %{public}s',
          describeError(error));
        this.releaseRecorder();
      });
    return target;
  }

  private async runStartLocalRecorder(audioOnly: boolean, path: string): Promise<void> {
    // Swift `recordAudio()` asks for the microphone only (ConversationViewController.swift:364);
    // a voice message must not prompt for the camera.
    const granted: boolean = audioOnly
      ? await this.ensureMicrophonePermission() : await this.ensurePermission();
    if (!granted) {
      // ensurePermission publishes its own refusal; the microphone-only ask does not.
      const denied: (() => void) | null = this.onMediaPermissionDenied;
      if (audioOnly && denied !== null) {
        denied();
      }
      return;
    }
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    this.recorderFile = file;
    const recorder: media.AVRecorder = await media.createAVRecorder();
    this.recorder = recorder;
    const profile: media.AVRecorderProfile = {
      audioBitrate: AUDIO_BITRATE,
      audioChannels: AUDIO_CHANNELS,
      audioCodec: media.CodecMimeType.AUDIO_AAC,
      audioSampleRate: AUDIO_SAMPLE_RATE,
      fileFormat: audioOnly ? media.ContainerFormatType.CFT_MPEG_4A
        : media.ContainerFormatType.CFT_MPEG_4
    };
    // The recorder is prepared at the size of the stream the camera will feed it.
    const videoProfile: camera.VideoProfile | null = audioOnly ? null : this.selectRecorderProfile();
    if (!audioOnly) {
      profile.videoBitrate = VIDEO_BITRATE;
      profile.videoCodec = media.CodecMimeType.VIDEO_AVC;
      profile.videoFrameWidth = videoProfile !== null ? videoProfile.size.width : MEDIUM_WIDTH;
      profile.videoFrameHeight = videoProfile !== null ? videoProfile.size.height : MEDIUM_HEIGHT;
      profile.videoFrameRate = VIDEO_FRAME_RATE;
    }
    // The camera writes sensor-oriented frames; the file carries the turn that makes them upright.
    // Held upright that is the lens's mounting angle (front 270, back 90 on most phones); the
    // iOS-derived 90 turned a front-camera take upside down (T-1619). Refined below, once the
    // camera output exists, for a phone held sideways.
    const lens: camera.CameraDevice | null = audioOnly ? null : this.selectCamera();
    const config: media.AVRecorderConfig = {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
      profile: profile,
      url: 'fd://' + file.fd.toString(),
      rotation: lens !== null ? lens.cameraOrientation : 0
    };
    if (!audioOnly) {
      config.videoSourceType = media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV;
    }
    await recorder.prepare(config);
    if (!audioOnly) {
      // Swift recorded the camera through libjami; here the camera writes into the recorder's
      // own input surface, which is the same session the preview uses.
      const surfaceId: string = await recorder.getInputSurface();
      await this.attachRecorderOutput(surfaceId, videoProfile);
      const output: camera.VideoOutput | null = this.videoOutput;
      if (output !== null) {
        try {
          // The camera's own answer for this lens and the way the phone is held now.
          const rotation: number = output.getVideoRotation();
          await recorder.updateRotation(rotation);
          hilog.info(LOG_DOMAIN, LOG_TAG, 'recording rotation %{public}d', rotation);
        } catch (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'recording keeps the lens angle: %{public}s',
            describeError(error as BusinessError));
        }
      }
    }
    await recorder.start();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'recording started -> %{public}s', path);
  }

  /** The video profile nearest 640x480 with the running preview's aspect, or null with no session. */
  private selectRecorderProfile(): camera.VideoProfile | null {
    const manager: camera.CameraManager | null = this.ensureCameraManager();
    const device: camera.CameraDevice | null = this.selectCamera();
    const preview: camera.Size | null = this.previewSize;
    if (manager === null || this.session === null || device === null || preview === null) {
      return null;
    }
    const capability: camera.CameraOutputCapability =
      manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_VIDEO);
    return pickProfile(capability.videoProfiles, preview.width, preview.height,
      MEDIUM_WIDTH * MEDIUM_HEIGHT);
  }

  /** Adds a VideoOutput on the recorder's surface to the live session. */
  private async attachRecorderOutput(surfaceId: string, chosen: camera.VideoProfile | null): Promise<void> {
    const manager: camera.CameraManager | null = this.ensureCameraManager();
    const session: camera.Session | null = this.session;
    if (manager === null || session === null || chosen === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no live camera session or video profile; recording audio only');
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'recording video at %{public}dx%{public}d',
      chosen.size.width, chosen.size.height);
    const output: camera.VideoOutput = manager.createVideoOutput(chosen, surfaceId);
    session.beginConfig();
    session.addOutput(output);
    await session.commitConfig();
    // beginConfig unlinks the running preview stream: nothing flows, to the preview or the
    // recorder, until the session starts again (T-0763: the preview froze, the take was empty).
    await session.start();
    await output.start();
    this.videoOutput = output;
  }

  /** Swift `func stopLocalRecorder(path:)`. */
  stopLocalRecorder(path: string): void {
    if (this.localRecording !== null && this.localRecording === path) {
      // libjami flushes the encoders and closes the file before this returns.
      this.localRecording = null;
      jami.stopLocalRecorder(path);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'libjami recording stopped -> %{public}s', path);
      return;
    }
    this.runStopLocalRecorder(path)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'stopping the recorder failed: %{public}s',
          describeError(error));
        this.releaseRecorder();
      });
  }

  private async runStopLocalRecorder(path: string): Promise<void> {
    const recorder: media.AVRecorder | null = this.recorder;
    if (recorder === null) {
      return;
    }
    try {
      const output: camera.VideoOutput | null = this.videoOutput;
      if (output !== null) {
        await output.stop();
      }
      if (recorder.state === 'started' || recorder.state === 'paused') {
        await recorder.stop();
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'recording stopped -> %{public}s', path);
      // The recorder's surface goes with it: its output leaves the session, and the preview
      // (stopped again by beginConfig) restarts, ready for another take.
      const live: camera.Session | null = this.session;
      if (output !== null && live !== null) {
        live.beginConfig();
        live.removeOutput(output);
        await live.commitConfig();
        await live.start();
        await output.release();
        this.videoOutput = null;
      }
    } finally {
      this.releaseRecorder();
    }
  }

  /** Both the recorder and the fd are native handles; neither is reclaimed by GC. */
  private releaseRecorder(): void {
    const recorder: media.AVRecorder | null = this.recorder;
    const file: fs.File | null = this.recorderFile;
    try {
      if (recorder !== null) {
        recorder.release()
          .catch((error: BusinessError): void => {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing the recorder failed: %{public}s',
              describeError(error));
          });
      }
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing the recorder failed: %{public}s',
        describeError(failure));
    } finally {
      this.recorder = null;
      if (file !== null) {
        fs.closeSync(file);
      }
      this.recorderFile = null;
      this.recorderPath = '';
    }
  }

  /** Swift `func openMediumCameraInput()`. */
  openMediumCameraInput(): void {
    this.quality = CaptureQuality.MEDIUM;
    this.setCurrentDeviceId(CAMERA_DEVICE_MEDIUM);
    this.startPreviewCapture();
  }

  /** Swift `func closeMediumCameraInput()`. */
  closeMediumCameraInput(): void {
    this.stopPreviewCapture();
    this.quality = this.hardwareAccelerated ? CaptureQuality.HIGH : CaptureQuality.MEDIUM;
    this.setCurrentDeviceId(this.defaultDeviceName);
  }

  /**
   * The chat's photo screen: the medium preview (4:3, the iPhone still's aspect) plus a still
   * output, on the rear lens (Swift `imagePicker.cameraDevice = .rear`).
   */
  openPhotoCameraInput(): void {
    this.photoRequested = true;
    if (this.position !== camera.CameraPosition.CAMERA_POSITION_BACK) {
      this.switchCamera();
    }
    this.openMediumCameraInput();
  }

  /** The photo screen closed: the camera goes and the next user starts on the front lens. */
  closePhotoCameraInput(): void {
    this.photoRequested = false;
    this.closeMediumCameraInput();
    this.resetCameraPosition();
  }

  // MARK: - Media player (real AVPlayer)

  /**
   * Swift `func createPlayer(path:) -> String?` (libjami's media player). Playing a message
   * attachment needs no daemon, so this is a real AVPlayer. Synchronous, as callers expect:
   * the id is minted here and the open runs behind it, reporting through `onFileOpened`.
   */
  createPlayer(path: string): string | null {
    const source: MediaSource | null = resolveSource(path);
    if (source === null) {
      return null;
    }
    const playerId: string = 'player_' + this.nextPlayerId.toString();
    this.nextPlayerId = this.nextPlayerId + 1;
    const entry: MediaPlayerEntry = new MediaPlayerEntry(playerId);
    this.players.set(playerId, entry);
    this.openPlayer(entry, source)
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'opening %{public}s failed: %{public}s', playerId,
          describeError(error));
        this.releasePlayer(entry);
      });
    return playerId;
  }

  private async openPlayer(entry: MediaPlayerEntry, source: MediaSource): Promise<void> {
    const player: media.AVPlayer = await media.createAVPlayer();
    entry.player = player;
    if (entry.closed) {
      // closePlayer ran while the player was being created.
      this.releasePlayer(entry);
      return;
    }
    player.on('stateChange', (state: media.AVPlayerState): void => {
      this.handlePlayerState(entry, state);
    });
    player.on('error', (error: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'player %{public}s error: %{public}s', entry.playerId,
        describeError(error));
    });
    player.on('videoSizeChange', (width: number, height: number): void => {
      // Swift delivered the player's video as a decoding sink whose id IS the playerId.
      const info: VideoFrameInfo = new VideoFrameInfo(this.orientationState.imageRotation,
        entry.playerId, width, height);
      this.distributor(new SinkId(entry.playerId))
        .distribute(new VideoFrame(0, width, height));
      const stream: FrameStream | null = this.playerFrames;
      if (stream !== null) {
        stream.frameSubject.onNext(info);
      }
    });
    player.on('timeUpdate', (time: number): void => {
      entry.lastKnownPosition = time;
    });
    // Reference 3.4 / MS12: reset before a new source.
    await player.reset();
    if (source.delivery === MediaDelivery.LOCAL_FD) {
      // MS02: AVPlayer rejects file://; an on-disk attachment is handed over as an fd.
      const file: fs.File = fs.openSync(source.path, fs.OpenMode.READ_ONLY);
      entry.file = file;
      const descriptor: media.AVFileDescriptor = { fd: file.fd };
      player.fdSrc = descriptor;
    } else {
      // MS01: only progressive or HLS ever reaches the player - never a .mpd.
      player.url = source.url;
    }
    await this.publishPlayerInfo(entry, source);
  }

  /**
   * Swift's `onFileOpened` payload (duration / audio_stream / video_stream) read from the real
   * file through AVMetadataExtractor. Released in `finally`.
   */
  private async publishPlayerInfo(entry: MediaPlayerEntry, source: MediaSource): Promise<void> {
    const handler: ((playerId: string, info: Player) => void) | null = this.onFileOpened;
    if (handler === null) {
      return;
    }
    let duration: string = '0';
    let hasAudio: boolean = true;
    let hasVideo: boolean = false;
    try {
      const metadata: media.AVMetadata = await VideoPipeline.fetchMetadata(source);
      duration = metadata.duration === undefined ? '0' : metadata.duration;
      hasAudio = metadata.hasAudio === 'yes';
      hasVideo = metadata.hasVideo === 'yes';
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'no metadata for %{public}s: %{public}s', entry.playerId,
        describeError(error as BusinessError));
    }
    if (!(Number.parseFloat(duration) > 0)) {
      // The SDK's extractor does not list WebM, the container of libjami's recordings (a video
      // message, ours or iOS's): the player's own duration and size, once it is prepared.
      entry.infoFromPlayer = true;
      this.publishInfoFromPlayer(entry);
      return;
    }
    handler(entry.playerId, new Player(entry.playerId, duration, hasAudio, hasVideo));
  }

  /** The player's duration and video size, when the extractor had none and the player is prepared. */
  private publishInfoFromPlayer(entry: MediaPlayerEntry): void {
    const handler: ((playerId: string, info: Player) => void) | null = this.onFileOpened;
    const player: media.AVPlayer | null = entry.player;
    if (handler === null || player === null || !entry.infoFromPlayer) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      return;
    }
    entry.infoFromPlayer = false;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'player %{public}s: %{public}d ms, %{public}dx%{public}d from the player',
      entry.playerId, player.duration, player.width, player.height);
    handler(entry.playerId, new Player(entry.playerId, player.duration.toString(), true, player.width > 0));
  }

  private static async fetchMetadata(source: MediaSource): Promise<media.AVMetadata> {
    const extractor: media.AVMetadataExtractor = await media.createAVMetadataExtractor();
    try {
      if (source.delivery === MediaDelivery.LOCAL_FD) {
        const file: fs.File = fs.openSync(source.path, fs.OpenMode.READ_ONLY);
        try {
          const descriptor: media.AVFileDescriptor = { fd: file.fd };
          extractor.fdSrc = descriptor;
          return await extractor.fetchMetadata();
        } finally {
          fs.closeSync(file);
        }
      }
      extractor.setUrlSource(source.url);
      return await extractor.fetchMetadata();
    } finally {
      await extractor.release();
    }
  }

  /** Reference 3.4: the whole state machine lives here, driven by the player's real state. */
  private handlePlayerState(entry: MediaPlayerEntry, state: media.AVPlayerState): void {
    const player: media.AVPlayer | null = entry.player;
    if (player === null) {
      return;
    }
    if (state === 'initialized') {
      // MS10: audioRendererInfo is settable ONLY in the 'initialized' state, before prepare().
      const rendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MOVIE,
        rendererFlags: 0
      };
      player.audioRendererInfo = rendererInfo;
      player.prepare()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'prepare failed: %{public}s', describeError(error));
        });
    } else if (state === 'prepared') {
      this.publishInfoFromPlayer(entry);
      player.setVolume(entry.muted ? 0 : 1);
      if (entry.playWhenReady) {
        player.play()
          .catch((error: BusinessError): void => {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'play failed: %{public}s', describeError(error));
          });
      }
    } else if (state === 'error') {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'player %{public}s entered the error state',
        entry.playerId);
    }
  }

  /** Swift `func pausePlayer(playerId:pause:)` - gated on the LIVE player state (MS11). */
  pausePlayer(playerId: string, pause: boolean): void {
    const entry: MediaPlayerEntry | undefined = this.players.get(playerId);
    if (entry === undefined) {
      return;
    }
    entry.playWhenReady = !pause;
    const player: media.AVPlayer | null = entry.player;
    if (player === null) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (pause) {
      if (state === 'playing') {
        player.pause()
          .catch((error: BusinessError): void => {
            hilog.error(LOG_DOMAIN, LOG_TAG, 'pause failed: %{public}s', describeError(error));
          });
      }
      return;
    }
    if (state === 'prepared' || state === 'paused' || state === 'completed') {
      player.play()
        .catch((error: BusinessError): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'play failed: %{public}s', describeError(error));
        });
    }
  }

  /** Swift `func closePlayer(playerId:)`. */
  closePlayer(playerId: string): void {
    const entry: MediaPlayerEntry | undefined = this.players.get(playerId);
    if (entry === undefined) {
      return;
    }
    this.players.delete(playerId);
    this.sinkDistributors.delete(playerId);
    this.releasePlayer(entry);
  }

  /** MS12: reset, then release, then close the fd - all in `finally` (Rule 8). */
  private releasePlayer(entry: MediaPlayerEntry): void {
    entry.closed = true;
    const player: media.AVPlayer | null = entry.player;
    const file: fs.File | null = entry.file;
    try {
      if (player !== null) {
        player.off('stateChange');
        player.off('error');
        player.off('videoSizeChange');
        player.off('timeUpdate');
        player.reset()
          .then((): Promise<void> => player.release())
          .then((): void => {
            // The fd is closed only once the player has let go of it - closing it while the
            // native player still holds it is a use-after-close, not a leak fix.
            if (file !== null) {
              fs.closeSync(file);
            }
          })
          .catch((error: BusinessError): void => {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'releasing the player failed: %{public}s',
              describeError(error));
            if (file !== null) {
              fs.closeSync(file);
            }
          });
      } else if (file !== null) {
        fs.closeSync(file);
      }
    } finally {
      entry.player = null;
      entry.file = null;
    }
  }

  /** Swift `func mutePlayerAudio(playerId:mute:)`. */
  mutePlayerAudio(playerId: string, mute: boolean): void {
    const entry: MediaPlayerEntry | undefined = this.players.get(playerId);
    if (entry === undefined) {
      return;
    }
    entry.muted = mute;
    const player: media.AVPlayer | null = entry.player;
    if (player === null) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused'
      || state === 'completed') {
      player.setVolume(mute ? 0 : 1);
    }
  }

  /** Swift `func seekPlayer(to:playerId:)`. */
  seekPlayer(time: number, playerId: string): void {
    const entry: MediaPlayerEntry | undefined = this.players.get(playerId);
    if (entry === undefined) {
      return;
    }
    const player: media.AVPlayer | null = entry.player;
    if (player === null) {
      return;
    }
    const state: media.AVPlayerState = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused'
      || state === 'completed') {
      player.seek(time);
    }
  }

  /** Swift `func playerPosition(playerId:) -> Int64`, in milliseconds. */
  playerPosition(playerId: string): number {
    const entry: MediaPlayerEntry | undefined = this.players.get(playerId);
    if (entry === undefined) {
      return 0;
    }
    const player: media.AVPlayer | null = entry.player;
    if (player === null) {
      return entry.lastKnownPosition;
    }
    const state: media.AVPlayerState = player.state;
    if (state === 'playing' || state === 'paused' || state === 'completed') {
      return player.getPlaybackPosition();
    }
    return entry.lastKnownPosition;
  }

  /** Set by `VideoService` so player frames reach its `videoInputManager`. */
  playerFrames: FrameStream | null = null;
}

/**
 * Swift `final class VideoService` - "camera, media-player and recorder surface". Stands alone:
 * calls, media messages, the file player and settings are all consumers.
 */
export class VideoService {
  /** Swift `private let pipeline: VideoPipeline`. */
  private readonly pipeline: VideoPipeline = new VideoPipeline();

  /** Runtime microphone grant for audio calls (the pipeline holds the ability context). */
  ensureMicrophonePermission(): Promise<boolean> {
    return this.pipeline.ensureMicrophonePermission();
  }

  ensureCameraAndMicrophonePermission(): Promise<boolean> {
    return this.pipeline.ensureCameraAndMicrophonePermission();
  }

  registerCameraDevices(): void {
    this.pipeline.registerCameraDevices();
  }

  /**
   * Surfaces offered for each sink, most recent last; the last one draws. A tile rebuilt when
   * the call turns to video briefly holds two, and the one going away must not take the sink's
   * only mapping with it (T-1626: DecodingStarted then found no surface).
   */
  private readonly sinkSurfaces: Map<string, string[]> = new Map<string, string[]>();
  /** Sinks libjami is decoding into (DecodingStarted until DecodingStopped). */
  private readonly liveSinks: Set<string> = new Set<string>();

  /**
   * A renderer surface for `sinkId` came (or went). libjami only accepts a target for a sink
   * that exists, so the surface is attached once both the surface and the sink are there.
   */
  setSinkSurface(sinkId: string, surfaceId: string | null): void {
    if (surfaceId === null) {
      this.sinkSurfaces.delete(sinkId);
      jami.detachSink(sinkId);
      return;
    }
    const surfaces: string[] = (this.sinkSurfaces.get(sinkId) ?? [])
      .filter((other: string): boolean => other !== surfaceId);
    surfaces.push(surfaceId);
    this.sinkSurfaces.set(sinkId, surfaces);
    this.attachCurrentSurface(sinkId, 'renderer surface');
  }

  /**
   * `surfaceId` lets go of `sinkId`. When it was the one drawing, the sink moves to `next`, else
   * to the newest surface still offered (a tile's, picture-in-picture's), and is detached only
   * when none is left.
   */
  releaseSinkSurface(sinkId: string, surfaceId: string, next: string | null): void {
    const surfaces: string[] = this.sinkSurfaces.get(sinkId) ?? [];
    const index: number = surfaces.indexOf(surfaceId);
    if (index < 0) {
      return;
    }
    const wasCurrent: boolean = index === surfaces.length - 1;
    surfaces.splice(index, 1);
    const fallback: string = surfaces.length > 0 ? surfaces[surfaces.length - 1] : 'none';
    hilog.info(LOG_DOMAIN, F4_TAG, 'release surface %{public}s for sink %{public}s (current: %{public}s, next: %{public}s)',
      surfaceId, sinkId, wasCurrent ? 'yes' : 'no', next ?? fallback);
    if (!wasCurrent) {
      return;
    }
    if (next !== null) {
      this.setSinkSurface(sinkId, next);
    } else if (surfaces.length > 0) {
      this.attachCurrentSurface(sinkId, 'fallback surface');
    } else {
      this.setSinkSurface(sinkId, null);
    }
  }

  /** Attaches the sink's newest surface, once libjami decodes the sink. */
  private attachCurrentSurface(sinkId: string, why: string): void {
    const surfaces: string[] = this.sinkSurfaces.get(sinkId) ?? [];
    if (surfaces.length === 0) {
      hilog.info(LOG_DOMAIN, F4_TAG, '%{public}s %{public}s: no renderer surface yet', why, sinkId);
      return;
    }
    if (!this.liveSinks.has(sinkId)) {
      hilog.info(LOG_DOMAIN, F4_TAG, '%{public}s for sink %{public}s waits for DecodingStarted', why, sinkId);
      return;
    }
    const attached: boolean = jami.attachSink(sinkId, surfaces[surfaces.length - 1]);
    hilog.info(LOG_DOMAIN, F4_TAG, '%{public}s for sink %{public}s: attached %{public}s', why, sinkId,
      String(attached));
  }

  /** libjami VideoSignal::DecodingStarted. */
  decodingStarted(sinkId: string): void {
    this.liveSinks.add(sinkId);
    this.attachCurrentSurface(sinkId, 'DecodingStarted');
  }

  /** libjami VideoSignal::DecodingStopped. */
  decodingStopped(sinkId: string): void {
    hilog.info(LOG_DOMAIN, F4_TAG, 'DecodingStopped %{public}s', sinkId);
    this.liveSinks.delete(sinkId);
    this.shownSizes.delete(sinkId);
    // Swift `handleDecodingStopped` sends an empty frame: the tile drops its image and shows the
    // avatar. The surface here keeps the last frame, so the tile hears 0x0 (T-1627: frozen peer).
    this.shownSizeChanged.onNext(new VideoFrameInfo(0, sinkId, 0, 0));
  }

  /** Each sink's frame size as shown, the sender's rotation applied, by sink id. */
  private readonly shownSizes: Map<string, VideoFrameInfo> = new Map<string, VideoFrameInfo>();
  /**
   * A sink's shown frame size changed: picture-in-picture takes its aspect (T-1592). 0x0 when
   * the sink stopped decoding: the tile has no video until the next frame (Swift `hasVideoContent`).
   */
  readonly shownSizeChanged: PublishSubject<VideoFrameInfo> = new PublishSubject<VideoFrameInfo>();

  /** The native renderer's SinkFrameSize: `sinkId`'s frames are now shown at width x height. */
  frameSizeChanged(sinkId: string, width: number, height: number): void {
    // Sent with the first frame drawn after each attach, then on every size change.
    hilog.info(LOG_DOMAIN, F4_TAG, 'renderer frame %{public}dx%{public}d on sink %{public}s', width, height, sinkId);
    const info: VideoFrameInfo = new VideoFrameInfo(0, sinkId, width, height);
    this.shownSizes.set(sinkId, info);
    this.shownSizeChanged.onNext(info);
  }

  /** The size `sinkId`'s frames are shown at, or null before its first frame. */
  shownSize(sinkId: string): VideoFrameInfo | null {
    return this.shownSizes.get(sinkId) ?? null;
  }

  /** libjami VideoSignal::StartCapture / StopCapture. */
  startCapture(device: string): void {
    this.pipeline.daemonStartCapture(device);
  }

  stopCapture(device: string): void {
    this.pipeline.daemonStopCapture(device);
  }

  /** Swift `let videoInputManager = FrameStream()`. */
  readonly videoInputManager: FrameStream = new FrameStream();

  /** Swift `let capturedVideoFrame = PublishSubject<LocalFrameInfo?>()`. */
  readonly capturedVideoFrame: PublishSubject<LocalFrameInfo | null> =
    new PublishSubject<LocalFrameInfo | null>();

  /** Swift `let playerInfo = PublishSubject<Player>()`. */
  readonly playerInfo: PublishSubject<Player> = new PublishSubject<Player>();

  /**
   * No Swift counterpart - iOS refuses `.camera` presentation itself. Here the CAMERA /
   * MICROPHONE user-grant is this service's to ask for, so its refusal is published and the
   * screen that asked for the camera shows its own notice instead of a dead preview.
   */
  readonly mediaPermissionDenied: PublishSubject<boolean> = new PublishSubject<boolean>();

  /** Swift `private var localSubscription: FrameSubscription?`. */
  private localSubscription: FrameSubscription | null = null;

  /** Swift `private var playerSinkSubscriptions: [String: FrameSubscription]`. */
  private readonly playerSinkSubscriptions: Map<string, FrameSubscription> =
    new Map<string, FrameSubscription>();

  /** Swift's `convenience init` did both: wire the file-opened bridge, attach to the adapter. */
  constructor() {
    this.pipeline.playerFrames = this.videoInputManager;
    this.pipeline.onFileOpened = (playerId: string, info: Player): void => {
      this.playerInfo.onNext(info);
    };
    this.pipeline.onMediaPermissionDenied = (): void => {
      this.mediaPermissionDenied.onNext(true);
    };
    // Swift's convenience init also called `attachToAdapter()` here. It is deferred to
    // `setContext`: the registry contract forbids reading another service from a constructor,
    // and attaching reports through `DaemonService`.
  }

  // MARK: - Injected OS handles (no Swift counterpart - a .ts module has no getContext())

  /** The ability calls this once at startup, before any camera use. */
  setContext(context: common.UIAbilityContext): void {
    this.pipeline.setContext(context);
    this.attachToAdapter();
  }

  /** The preview XComponent offers its surface on load and `null` on unload. */
  setPreviewSurface(surfaceId: string | null): void {
    this.pipeline.setPreviewSurface(surfaceId);
  }

  // MARK: - libjami wiring

  /** Swift `private func attachToAdapter()` - called once from `setContext`. */
  private attachToAdapter(): void {
    this.pipeline.attachToAdapter();
  }

  /** Swift `func setVideoCodec(_:forCallId:)`. */
  setVideoCodec(codec: string | null, callId: string): void {
    this.pipeline.setVideoCodec(codec, callId);
  }

  /**
   * Swift `var onSourceDowngraded: ((SinkId, String) -> Void)?` - settable, forwarded to the
   * pipeline. `common/CallsManager.ts` both assigns a handler and clears it with `null`.
   */
  get onSourceDowngraded(): ((sinkId: SinkId, source: string) => void) | null {
    return this.pipeline.onSourceDowngraded;
  }

  set onSourceDowngraded(handler: ((sinkId: SinkId, source: string) => void) | null) {
    this.pipeline.onSourceDowngraded = handler;
  }

  // MARK: - Frame sources

  /** Swift `var localFrames: FrameDistributor` - camera frames, for local preview tiles. */
  get localFrames(): FrameDistributor {
    return this.pipeline.localFrames;
  }

  /** Swift `var localLayerTransform: CGAffineTransform`. */
  get localLayerTransform(): CameraLayerTransform {
    return this.pipeline.localLayerTransform;
  }

  /** Swift `func distributor(for sinkId: SinkId) -> FrameDistributor`. */
  distributor(sinkId: SinkId): FrameDistributor {
    return this.pipeline.distributor(sinkId);
  }

  // MARK: - Capture

  /** Swift `func videoSource() -> String` - the current camera URI for libjami media lists. */
  videoSource(): string {
    return this.pipeline.videoSource();
  }

  /** Swift `func startPreviewCapture()`. */
  startPreviewCapture(): void {
    this.pipeline.startPreviewCapture();
  }

  /** Swift `func stopPreviewCapture()`. */
  stopPreviewCapture(): void {
    this.pipeline.stopPreviewCapture();
  }

  /** CallsManager: a call is up, so the camera runs only when libjami asks for it (iOS parity). */
  setCallOwnsCamera(owns: boolean): void {
    this.pipeline.setCallOwnsCamera(owns);
  }

  /**
   * Swift `func resetCameraPosition() async`. Kept SYNCHRONOUS on purpose: `CallsManager`
   * calls it bare, with no `await` and no `.catch`.
   */
  resetCameraPosition(): void {
    this.pipeline.resetCameraPosition();
  }

  /** Swift `func restoreDefaultDevice()`. */
  restoreDefaultDevice(): void {
    this.pipeline.restoreDefaultDevice();
  }

  // MARK: - Camera (media-message recording UI)

  /**
   * Swift `func setupInputs()` - set the devices up, then feed the record-preview stream from
   * the shared local distributor.
   */
  setupInputs(): void {
    this.pipeline.setupDevices();
    const previous: FrameSubscription | null = this.localSubscription;
    if (previous !== null) {
      previous.cancel();
    }
    this.localSubscription = this.pipeline.localFrames.subscribe((frame: VideoFrame): void => {
      this.capturedVideoFrame.onNext(new LocalFrameInfo(frame,
        this.pipeline.localLayerTransform, this.pipeline.localImageOrientation));
    });
  }

  /** Swift `func startMediumCamera()`. */
  startMediumCamera(): void {
    this.pipeline.openMediumCameraInput();
    // Swift's openMediumCameraInput also opens libjami's input, which the recorder records.
    this.pipeline.openRecorderInput();
  }

  /** Swift `func switchCamera() async` - the transform is recomputed before it returns. */
  switchCamera(): void {
    this.pipeline.switchCamera();
  }

  /** Swift `func setCameraOrientation(_:) -> Bool` - true when the caller must refresh transforms. */
  setCameraOrientation(input: DeviceOrientationInput): boolean {
    return this.pipeline.setOrientation(input);
  }

  // MARK: - Hardware acceleration

  /** Swift `func setHardwareAccelerated(withState:)`. */
  setHardwareAccelerated(state: boolean): void {
    this.pipeline.setHardwareAccelerated(state);
  }

  // MARK: - Local recorder (media messages)

  /** Swift `func startLocalRecorder(audioOnly:path:) -> String?`. */
  startLocalRecorder(audioOnly: boolean, path: string): string | null {
    return this.pipeline.startLocalRecorder(audioOnly, path);
  }

  /** Swift `func stopLocalRecorder(path:)`. */
  stopLocalRecorder(path: string): void {
    this.pipeline.stopLocalRecorder(path);
  }

  // MARK: - Camera (the chat's Send photo, T-0755)

  /** UIImagePickerController's camera: the rear preview with a still output. */
  startPhotoCamera(): void {
    this.pipeline.openPhotoCameraInput();
  }

  /** The shutter: one JPEG into `path`; false when no photo came. */
  capturePhoto(path: string): Promise<boolean> {
    return this.pipeline.capturePhoto(path);
  }

  /** Every exit from the photo screen. */
  stopPhotoCamera(): void {
    this.pipeline.closePhotoCameraInput();
  }

  /** Swift `func videRecordingFinished()` (the source's own spelling). */
  videRecordingFinished(): void {
    this.pipeline.closeMediumCameraInput();
    this.pipeline.resetCameraPosition();
    this.pipeline.closeRecorderInput();
  }

  // MARK: - Media player

  /**
   * Swift `func createPlayer(path:) -> String`. Player video arrives as a sink whose id IS the
   * playerId, so the subscription is registered here exactly as the source did it.
   */
  createPlayer(path: string): string {
    const playerId: string | null = this.pipeline.createPlayer(path);
    if (playerId === null) {
      return '';
    }
    const sink: SinkId = new SinkId(playerId);
    const subscription: FrameSubscription = this.pipeline.distributor(sink)
      .subscribe((frame: VideoFrame): void => {
        this.videoInputManager.frameSubject.onNext(new VideoFrameInfo(frame.rotation, playerId,
          frame.width, frame.height));
      });
    this.playerSinkSubscriptions.set(playerId, subscription);
    return playerId;
  }

  /** Swift `func pausePlayer(playerId:pause:)`. */
  pausePlayer(playerId: string, pause: boolean): void {
    this.pipeline.pausePlayer(playerId, pause);
  }

  /** Swift `func closePlayer(playerId:)`. */
  closePlayer(playerId: string): void {
    const subscription: FrameSubscription | undefined =
      this.playerSinkSubscriptions.get(playerId);
    if (subscription !== undefined) {
      subscription.cancel();
      this.playerSinkSubscriptions.delete(playerId);
    }
    this.pipeline.closePlayer(playerId);
  }

  /** Swift `func mutePlayerAudio(playerId:mute:)`. */
  mutePlayerAudio(playerId: string, mute: boolean): void {
    this.pipeline.mutePlayerAudio(playerId, mute);
  }

  /** Swift `func seekToTime(time:playerId:)`. */
  seekToTime(time: number, playerId: string): void {
    this.pipeline.seekPlayer(time, playerId);
  }

  /** Swift `func getPlayerPosition(playerId:) -> Int64`. */
  getPlayerPosition(playerId: string): number {
    return this.pipeline.playerPosition(playerId);
  }
}
