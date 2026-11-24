/*
 * screen_media_record — "Record Audio / Video Message", ported from
 *   Ring/Ring/Features/Conversations/MediaRecord/MediaRecordView.swift
 *   Ring/Ring/Features/Conversations/MediaRecord/MediaRecordViewModel.swift
 *   Ring/Ring/Features/Conversations/views/PlayerViewModel.swift (the playback half)
 *
 * presentation: modal, hostScreen: screen_conversation. `ConversationNavigation
 * .openRecordFile(conversation:audioOnly:)` presents it `.overCurrentContext`, so it is a
 * @CustomDialog mounted by ConversationChatPage — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — the REAL component tree of `MediaRecordView.body`, unstyled:
 *
 *   ZStack { VideoPreviewLayer ; contentLayer }
 *   contentLayer = VStack(0) { topBar ; Spacer
 *                              if audioOnly { audioOnlyContent }
 *                              bottomBar
 *                              if showPlayerControls { playerControlsPanel } }
 *   topBar       = VStack(8) { ZStack { HStack { cancel ; Spacer ; switchCamera|gap }
 *                                       recordingTimerBadge (isRecording) }
 *                              if isReadyToSend { sendRow } }
 *   sendRow      = HStack { waveform|video.fill ; fileDisplayName ; Spacer ; sendButton }
 *   bottomBar    = Button(triggerRecording) { RecordButtonLabel(isRecording:) }
 *   playerPanel  = VStack { MediaSeekSlider ; ZStack { playPause ; HStack { duration ;
 *                                                                          Spacer ; mute } } }
 *
 * conditionalVariants, each an ArkUI `if` on the field the plan names:
 *   video_mode -> isVideoMode   audio_mode -> isAudioMode   recording -> isRecording
 *   recorded   -> isRecorded    paused     -> isPaused
 *
 * bindingContract:
 *   preview frame <- svc_video. FRAMES BECAME A SURFACE: iOS pushed a UIImage per captured
 *     frame; HarmonyOS renders the camera into an XComponent surface, so `previewFrame` holds
 *     the surface id svc_video is rendering into (comp_video_preview_layer's header note).
 *   waveform      <- the plan says svc_audio levels; the SOURCE reads no levels (WaveformBar
 *     takes only index + isAnimating). The source wins — see comp_audio_waveform's header.
 *   seek          <- playbackPosition, driven by the svc_video player through MediaSeekSlider.
 *
 * `audioOnly` and the conversation arrive through AppStorage rather than a constructor
 * argument: a @CustomDialog's builder parameters are fixed when the controller is BUILT, and
 * the host builds one controller for both of Swift's entry points
 * (`openRecordFile(audioOnly: true)` from Record audio, `false` from Record video).
 *
 * CAPABILITY: recording is LOCAL (CameraKit preview; a video message is recorded by libjami from
 * its camera input as on iOS, .webm; a voice message by AVRecorder, .m4a; the CAMERA/MICROPHONE
 * user-grant permissions already in module.json5, requested by svc_video itself). It is
 * ported for real, not stubbed. On a device with no camera the preview stays black and the
 * recorder falls back to audio — a runtime capability outcome, not a faked control.
 *
 * DAEMON GAP: SENDING the finished recording is a DataTransferService transfer over the jami
 * daemon. Send runs, stages the file, and reports the gap; it never claims the file left.
 *
 * S4: the plan's `@Link isPresented` is owned by ConversationChatPage (the host) and lowered
 * here on every dismissal path; the injected CustomDialogController is what actually takes the
 * overlay down, which keeps it off the router stack.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AudioWaveformView } from '../components/AudioWaveform';
import { MediaSeekSlider } from '../components/MediaSeekSlider';
import { RecordButtonLabel } from '../components/RecordButtonLabel';
import { VideoPreviewLayer } from '../components/VideoPreviewLayer';
import { DaemonUnavailableError } from '../common/DaemonService';
import { DataTransferService } from '../common/DataTransferService';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { Player, VideoService } from '../common/VideoService';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { durationFormatted } from '../model/MessageModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'MediaRecord';

/** Swift `Layout.touchTargetSize`. */
const TOUCH_TARGET: number = 44;
/** Swift `Layout.screenHorizontalPadding`. */
const SCREEN_H_PADDING: number = 20;
/** Swift `Layout.innerHorizontalPadding`. */
const INNER_H_PADDING: number = 16;
/** Swift `Style.iconSize` / `largeIconSize` / `heroIconSize`. */
const ICON_SIZE: number = 20;
const LARGE_ICON_SIZE: number = 28;
const HERO_ICON_SIZE: number = 60;
/**
 * SF `arrow.triangle.2.circlepath.camera` at 20 pt inks 23.5x18.5 pt (iPhone capture); the
 * HarmonyOS glyph inks ~0.95 em wide, so 24 draws it at the iPhone's size (T-1032).
 */
const SWITCH_CAMERA_GLYPH_SIZE: number = 24;
/** Swift `Layout.primaryButtonSize`. */
const PRIMARY_BUTTON_SIZE: number = 72;
/** Swift `recordingTimerBadge`'s red dot. */
const TIMER_DOT_SIZE: number = 8;
/** Swift `VStack(spacing: 8)` in the top bar, `VStack(spacing: 24)` in the audio content. */
const TOP_BAR_GAP: number = 8;
const AUDIO_CONTENT_GAP: number = 24;
/** Swift `AudioWaveformView(...).frame(height: 80).padding(.horizontal, 40)`. */
const WAVEFORM_HEIGHT: number = 80;
const WAVEFORM_H_PADDING: number = 40;
/** Swift `durationText.frame(minWidth: 56)`. */
const DURATION_MIN_WIDTH: number = 56;
/** Swift `DispatchQueue.main.asyncAfter(deadline: .now() + 1)` before creating the player. */
const PLAYER_CREATE_DELAY_MS: number = 1000;
/** The recording timer's tick. */
const TIMER_TICK_MS: number = 1000;
/** Swift PlayerViewModel `Timer.scheduledTimer(withTimeInterval: 0.1)` — the progress poll. */
const PROGRESS_TICK_MS: number = 100;
/**
 * Swift ends on `progress >= 0.999` twice. AVPlayer parks in 'completed' at, or a hair short
 * of, the metadata duration, so a position that stopped within this much of the end is the end.
 */
const END_SLACK_MS: number = 250;

/*
 * S5 — STYLE ONLY. This screen hardcodes its whole design system in Swift, so almost every
 * value below is copied verbatim out of `MediaRecordView.Layout` / `.Style` and
 * `MediaViewHelpers.swift`; nothing is measured off the PNG. The capture (S0297, 393x852 pt)
 * is the cross-check, and it agrees: Cancel [19,74]-[104,119] (a 44 pt capsule at the 20 pt
 * screen inset, 16 pt of side padding around a 17 pt label), the camera switch [328,74]-
 * [373,119] (44x44), the record button [159,704]-[234,779] (72x72).
 *
 * `glassBackground(shape:)` is UIBlurEffect(.dark) + a black 0.05..0.2 gradient at half
 * opacity, hairlined in white 0.2: GLASS_FILL below, with ArkUI's `.backdropBlur` supplying
 * the blur half.
 */
/** UIBlurEffect(.dark)'s radius, as ArkUI spells it. */
const GLASS_BLUR: number = 20;
/**
 * UIBlurEffect(.dark)'s tint. `jami_on_video_glass` (#47000000) read as a pale translucent
 * grey (TC-CHAT-375, TC-CHAT-378); the iPhone's Cancel pill over the white audio page is
 * rgb(84,84,84), i.e. 67% black (sampled off the reference capture).
 */
// UIBlurEffect(.dark) solved from the sim: rgb 19 over black, ~84 over white (both met).
const GLASS_FILL: string = '#BD1A1A1A';
/**
 * The preview's portrait aspect: svc_video records off the MEDIUM 640x480 profile
 * (VideoService.selectPreviewProfile), which the camera shows upright as 3:4.
 * ponytail: fixed aspect; read the chosen profile from svc_video if a device lacks 640x480.
 */
const PREVIEW_ASPECT: number = 3 / 4;
/** Light status-bar icons over the black camera preview (T-1723, as MediaPreviewPage T-1675). */
const LIGHT_STATUS_BAR_CONTENT: string = '#FFFFFF';
/** Swift `shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5)`. */
const GLASS_STROKE_WIDTH: number = 0.5;
const GLASS_STROKE_COLOR: string = '#33FFFFFF';
/** Swift `Layout.panelCornerRadius`. */
const PANEL_CORNER_RADIUS: number = 14;
/** Swift `Style.primaryTextSize` / `Style.secondaryTextSize`. */
const PRIMARY_TEXT_SIZE: number = 17;
const SECONDARY_TEXT_SIZE: number = 15;
/** SwiftUI `.subheadline` — the two monospaced readouts (timer, player duration). */
const READOUT_TEXT_SIZE: number = 15;
/** SwiftUI `.semibold` / `.medium`, as ArkUI numerics. */
const WEIGHT_SEMIBOLD: number = 600;
const WEIGHT_MEDIUM: number = 500;
/** Swift `sendButton`: `.background(Color.white.opacity(0.9)).clipShape(Capsule())`. */
const SEND_BUTTON_FILL: string = '#E6FFFFFF';
/** iOS `Color.red` — the timer dot and the record dot, one value for both. */
const IOS_RED: string = '#FF3B30';
/** SwiftUI `.green` — `audioWaveformView`'s hero glyph once a recording is ready to send. */
const READY_GLYPH_COLOR: string = '#34C759';
/** Swift `sendRow`'s leading glyph: `.foregroundColor(.white.opacity(0.7))`. */
const GLASS_LEADING_GLYPH_COLOR: string = '#B3FFFFFF';
/** Swift `.clipShape(Capsule())` on a row that measures ~40 pt tall (17 pt text + 8+8). */
const SEND_BUTTON_RADIUS: number = 20;
/** sys.symbol.paperplane_fill turned to SF `paperplane.fill`'s up-right heading. */
const PAPERPLANE_SF_ANGLE: number = 45;
/** Swift `playPauseButton`'s `Circle().stroke(Color.white.opacity(0.6), lineWidth: 3)` —
 *  the same ring RecordButtonLabel draws, declared once per file because a const is not
 *  shared across .ets modules. */
const RING_STROKE_WIDTH: number = 3;
const RING_STROKE_COLOR: string = '#99FFFFFF';
/** Swift `ScaleButtonStyle` — `.scaleEffect(0.92)` while pressed, over a 0.25s spring. */
const PRESSED_SCALE: number = 0.92;
const PRESS_ANIMATION_MS: number = 250;

/** AppStorage keys the host writes before it opens this overlay. */
export const MEDIA_RECORD_AUDIO_ONLY_KEY: string = 'mediaRecordAudioOnly';
export const MEDIA_RECORD_CONVERSATION_KEY: string = 'mediaRecordConversationKey';

@CustomDialog
export struct RecordAudioVideoMessageOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /**
   * Swift's `.overCurrentContext` presentation flag, owned by screen_conversation
   * (ConversationChatPage). The overlay lowers it as it dismisses, so the host's own state
   * always says whether the recorder is up — the CustomDialogController alone cannot be read.
   */
  @Link isPresented: boolean;

  /**
   * Written by the host from the media-action row it was tapped on (Record audio vs Record
   * video). A @CustomDialog's builder arguments are fixed when the CONTROLLER is built and
   * the host builds one controller for both entry points, so the flag travels in AppStorage.
   */
  @StorageProp('mediaRecordAudioOnly') @Watch('onModeChanged') private audioOnlyPref: boolean =
    false;
  /** conditionalVariants[audio_mode]: Swift `viewModel.audioOnly == true`. */
  @State isAudioMode: boolean = false;
  /** conditionalVariants[video_mode]: Swift `viewModel.audioOnly == false`. */
  @State isVideoMode: boolean = true;
  /** `<accountId>|<conversationId or first participant>`, written by the host. */
  @StorageProp('mediaRecordConversationKey') conversationKey: string = '';

  /** bindingContract: preview frame <- svc_video (the surface it renders into). */
  @State previewFrame: string = '';
  /** bindingContract: waveform — animating while the recorder runs. */
  @State waveform: boolean = false;
  /** bindingContract: seek <- playbackPosition, 0..1. */
  @State seek: number = 0;

  /** conditionalVariants[recording]: Swift `viewModel.isRecording`. */
  @State isRecording: boolean = false;
  /** conditionalVariants[recorded]: Swift `viewModel.isReadyToSend`. */
  @State isRecorded: boolean = false;
  /** conditionalVariants[paused]: Swift `viewModel.isPaused`. */
  @State isPaused: boolean = true;

  /** Swift `viewModel.showPlayerControls` — raised once the player reports ready. */
  @State private showPlayerControls: boolean = false;
  /** Swift `viewModel.isAudioMuted`. */
  @State private isAudioMuted: boolean = true;
  /** Swift `viewModel.hideInfo`. */
  @State private hideInfo: boolean = false;
  /** Swift `viewModel.recordDuration` — "mm:ss" while recording. */
  @State private recordDuration: string = '';
  /**
   * Swift `viewModel.playerDuration`, in the player's own unit: AVMetadata's duration is
   * milliseconds (Swift's libjami value is microseconds), the unit `seekToTime` takes back.
   */
  @State private playerDuration: number = 0;
  /** Swift `viewModel.fileDisplayName`. */
  @State private fileDisplayName: string = '';

  /** True while svc_video / svc_data_transfer are in flight. */
  @State isLoading: boolean = false;
  /** The failure text this screen shows; empty when there is no failure. */
  @State errorText: string = '';
  /** The disclosed daemon gap raised by this screen's own Send. */
  @State showDaemonNotice: boolean = false;
  /** The recorder could not start (no camera/microphone grant, or no writable path). */
  @State private showRecordFailure: boolean = false;
  /**
   * The status bar's height (vp). Swift lays `contentLayer` out inside the safe area; this
   * dialog spans the whole window, so the top bar is pushed below the bar by hand.
   */
  @State private topInset: number = 0;
  /** The window under the dialog and its status-bar content colour before the video preview. */
  private win: window.Window | null = null;
  private savedStatusBarContent: string | undefined = undefined;
  /** Swift `.scaledToFill()` — the preview's size, covering the screen at PREVIEW_ASPECT. */
  @State private previewWidth: number = 0;
  @State private previewHeight: number = 0;

  // --- Swift VM members that are not render inputs -------------------------------------
  /** Swift `private(set) var fileName`. */
  private fileName: string = '';
  /** Swift `private(set) var player: PlayerViewModel?` — its id in svc_video's registry. */
  private playerId: string = '';
  /** Swift `private var recordingTimer: Timer?` / `recordingSeconds`. */
  private recordingTimer: number = -1;
  private recordingSeconds: number = 0;
  /** Swift `DispatchQueue.main.asyncAfter` handle, cancelled on the way out. */
  private playerCreateTimer: number = -1;
  /** Swift `viewModel.conversation`. */
  private conversation: ConversationModel | null = null;
  /** Swift `private var cameraStarted`. */
  private cameraStarted: boolean = false;
  /** Swift `coordinator.isSeeking` — the player's pushes are dropped mid-seek. */
  private isSeeking: boolean = false;
  /** Swift PlayerViewModel `progressTimer` / `currentTime` / `state == .finished`. */
  private progressTimer: number = -1;
  private lastPosition: number = 0;
  private isFinished: boolean = false;
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /** Swift `setup()` + the coordinator's `conversation` / `audioOnly` assignment. */
  aboutToAppear(): void {
    this.onModeChanged();
    this.conversation = RecordAudioVideoMessageOverlay.resolveConversation(this.conversationKey);
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // The gap THIS overlay's own Send raises.
    this.bag.add(registry.daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'transfer.send') {
          this.showDaemonNotice = true;
          this.errorText = error.message;
        }
      }));
    // Swift `PlayerViewModel` subscribed `videoService.playerInfo` for the duration.
    this.bag.add(registry.videoService.playerInfo.subscribe((info: Player): void => {
      if (info.playerId !== this.playerId) {
        return;
      }
      const millis: number = Number.parseFloat(info.duration);
      this.playerDuration = Number.isNaN(millis) ? 0 : millis;
      // Swift raised showPlayerControls on the first `playerReady`.
      this.showPlayerControls = true;
      this.isPaused = true;
      // Swift PlayerViewModel.createPlayer: an audio-only file plays unmuted
      // (`audioMuted.accept(false)`), a video starts muted (`setMuted(true)`). Always muted,
      // a voice recording played silent and Mute read inverted (TC-CHAT-388).
      this.isAudioMuted = info.hasVideo;
      registry.videoService.mutePlayerAudio(this.playerId, this.isAudioMuted);
    }));
    // The CAMERA/MICROPHONE grant is svc_video's to ask for; its REFUSAL is this screen's to
    // show. Without this the preview area just stays black and the record button does nothing.
    this.bag.add(registry.videoService.mediaPermissionDenied.subscribe((_denied: boolean): void => {
      this.reportPermissionRefused();
    }));
    // Swift `setup()` -> `subscribeCameraFrames()`; the camera devices are set up here so the
    // CAMERA/MICROPHONE grant is asked for once, as the view appears.
    if (this.isVideoMode) {
      registry.videoService.setupInputs();
    }
    // Swift `transition(to: .initial)`.
    this.hideInfo = !this.isAudioMode;
    this.resolveTopInset();
  }

  /** The window's own top avoid area — never a hardcoded status-bar height. */
  private resolveTopInset(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = px2vp(area.topRect.height);
      // The video preview is black, the audio page is systemBackground: light icons only over
      // the camera; the old colour comes back on close.
      // ponytail: restores an explicit colour, so a dark-mode switch while recording keeps it.
      if (this.isVideoMode) {
        this.win = win;
        this.savedStatusBarContent = win.getWindowSystemBarProperties().statusBarContentColor;
        this.setStatusBarContent(win, LIGHT_STATUS_BAR_CONTENT);
      }
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'top avoid area unavailable: %{public}d', error.code);
    });
  }

  /**
   * Swift `Image(uiImage:).resizable().scaledToFill().frame(geo.size).clipped()`. The camera
   * surface stretches its frames to the XComponent's box, so a full-screen box squeezed the
   * 3:4 frame (TC-CHAT-375). The box keeps the frame's aspect, turned with the screen, and
   * covers the screen; the overflow is clipped.
   */
  private fitPreview(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    const aspect: number = width > height ? 1 / PREVIEW_ASPECT : PREVIEW_ASPECT;
    if (width / height < aspect) {
      this.previewHeight = height;
      this.previewWidth = height * aspect;
    } else {
      this.previewWidth = width;
      this.previewHeight = width / aspect;
    }
  }

  /** Swift `previewDisappeared()` + `deinit` — every resource this screen opened. */
  aboutToDisappear(): void {
    try {
      this.stopTimer();
      this.cancelPlayerCreate();
      this.releasePlayer();
      if (this.isRecording) {
        ServiceRegistry.shared().videoService.stopLocalRecorder(this.fileName);
      }
    } finally {
      // ArkTS rule 8: the camera session, the surface and the subscriptions go whatever
      // happened above.
      const video: VideoService = ServiceRegistry.shared().videoService;
      // libjami's camera input first: with it still open, dropping the surface rebuilt the
      // session for libjami alone, only for the input's close to tear it down again.
      video.videRecordingFinished();
      video.setPreviewSurface(null);
      video.stopPreviewCapture();
      this.bag.dispose();
      if (this.win !== null && this.savedStatusBarContent !== undefined) {
        this.setStatusBarContent(this.win, this.savedStatusBarContent);
      }
    }
  }

  private setStatusBarContent(win: window.Window, color: string): void {
    win.setWindowSystemBarProperties({ statusBarContentColor: color })
      .catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'status bar colour not set: %{public}d', error.code);
      });
  }

  /** Swift `viewModel.audioOnly` is the single switch; isVideoMode is its complement. */
  private onModeChanged(): void {
    this.isAudioMode = this.audioOnlyPref;
    this.isVideoMode = !this.isAudioMode;
  }

  /** The same key split ContactInfoPage and the smart list use. */
  private static resolveConversation(key: string): ConversationModel | null {
    const separator: number = key.indexOf('|');
    if (key.length === 0 || separator < 0) {
      return null;
    }
    const accountId: string = key.substring(0, separator);
    const identity: string = key.substring(separator + 1);
    const conversations: ConversationModel[] =
      ServiceRegistry.shared().conversationsService.conversations.value;
    for (const conversation of conversations) {
      if (conversation.accountId !== accountId) {
        continue;
      }
      if (conversation.id === identity || conversation.hash === identity) {
        return conversation;
      }
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (participants.length > 0 && participants[0].jamiId === identity) {
        return conversation;
      }
    }
    return null;
  }

  /**
   * Swift `previewAppeared()` — `guard !audioOnly`, then start the medium camera once. The
   * surface is HarmonyOS's replacement for the per-frame UIImage push.
   */
  private previewAppeared(surfaceId: string): void {
    this.previewFrame = surfaceId;
    const video: VideoService = ServiceRegistry.shared().videoService;
    video.setPreviewSurface(surfaceId);
    if (this.cameraStarted) {
      return;
    }
    this.cameraStarted = true;
    video.startMediumCamera();
    video.startPreviewCapture();
  }

  /** The surface is gone; svc_video must stop rendering into it. */
  private previewReleased(): void {
    this.previewFrame = '';
    ServiceRegistry.shared().videoService.setPreviewSurface(null);
  }

  /** Swift `func triggerRecording()`. */
  private triggerRecording(): void {
    if (this.isRecording) {
      this.stopRecording();
    } else {
      this.startRecording();
    }
  }

  /** Swift `private static let recordingDateFormatter` — "yyyy-MM-dd_HH:mm:ss". */
  private recordingFileName(): string {
    const now: Date = new Date();
    const pad: (value: number) => string = (value: number): string =>
      value < 10 ? `0${value}` : `${value}`;
    const stamp: string = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-` +
      `${pad(now.getDate())}_${pad(now.getHours())}:${pad(now.getMinutes())}:` +
      `${pad(now.getSeconds())}`;
    return `${stamp}_${Math.floor(Math.random() * 10000)}`;
  }

  /** Swift `func startRecording()`. */
  private startRecording(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    this.showRecordFailure = false;
    this.releasePlayer();
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      // No conversation to record into: the same disclosed gap one step earlier, said out
      // loud rather than returned from silently.
      this.showDaemonNotice = true;
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const transfer: DataTransferService = registry.dataTransferService;
    const path: string | null = transfer.getFilePathForRecordings(this.recordingFileName(),
      conversation.accountId, conversation.id, conversation.isSwarm());
    if (path === null) {
      // Swift `guard let url ... else { return }` — a silent return there; here the control
      // must be seen to do something, so the failure is shown.
      this.reportRecordFailure();
      return;
    }
    const started: string | null =
      registry.videoService.startLocalRecorder(this.isAudioMode, path);
    if (started === null) {
      this.reportRecordFailure();
      return;
    }
    this.fileName = started;
    this.fileDisplayName = RecordAudioVideoMessageOverlay.lastPathComponent(started);
    this.transitionToRecording();
  }

  /** Swift `URL(fileURLWithPath: name).lastPathComponent`. */
  private static lastPathComponent(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /** The recorder could not start — no camera/microphone grant, or no writable path. */
  private reportRecordFailure(): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'the recorder could not be started');
    this.showRecordFailure = true;
  }

  /**
   * The camera/microphone grant was refused. `startLocalRecorder` returns its path
   * synchronously and the recorder only fails behind it, so the recording state raised by the
   * tap is rolled back here — otherwise the timer keeps counting over a recording that never
   * started.
   */
  private reportPermissionRefused(): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'the camera/microphone grant was refused');
    this.showRecordFailure = true;
    if (this.isRecording) {
      this.isRecording = false;
      this.waveform = false;
      this.stopTimer();
      this.recordDuration = '';
      ServiceRegistry.shared().videoService.stopLocalRecorder(this.fileName);
      this.fileName = '';
    }
  }

  /** Swift `func stopRecording()`. */
  private stopRecording(): void {
    ServiceRegistry.shared().videoService.stopLocalRecorder(this.fileName);
    this.transitionToRecorded();
    // Swift: "Allow the recording file to finish writing before creating the player."
    this.cancelPlayerCreate();
    this.playerCreateTimer = setTimeout((): void => {
      this.playerCreateTimer = -1;
      this.createPlayer();
    }, PLAYER_CREATE_DELAY_MS);
  }

  /** Swift `private func createPlayer()` — the svc_video half of PlayerViewModel. */
  private createPlayer(): void {
    if (this.fileName.length === 0) {
      return;
    }
    const video: VideoService = ServiceRegistry.shared().videoService;
    this.playerId = video.createPlayer(this.fileName);
    if (this.playerId.length === 0) {
      // No player for this file: the panel stays hidden rather than showing dead controls.
      this.showPlayerControls = false;
      return;
    }
    video.pausePlayer(this.playerId, true);
    this.isPaused = true;
    // Swift `playerPosition.onNext(0)` for the new player.
    this.seek = 0;
    this.lastPosition = 0;
    this.isFinished = false;
  }

  private releasePlayer(): void {
    this.stopProgress();
    if (this.playerId.length === 0) {
      return;
    }
    ServiceRegistry.shared().videoService.closePlayer(this.playerId);
    this.playerId = '';
    this.showPlayerControls = false;
  }

  private cancelPlayerCreate(): void {
    if (this.playerCreateTimer !== -1) {
      clearTimeout(this.playerCreateTimer);
      this.playerCreateTimer = -1;
    }
  }

  /** Swift `transition(to: .recording)`. */
  private transitionToRecording(): void {
    this.isRecording = true;
    this.waveform = true;
    this.isRecorded = false;
    this.hideInfo = true;
    this.showPlayerControls = false;
    this.startTimer();
  }

  /** Swift `transition(to: .recorded)`. */
  private transitionToRecorded(): void {
    this.isRecording = false;
    this.waveform = false;
    this.isRecorded = true;
    this.hideInfo = true;
    this.stopTimer();
    this.recordDuration = '';
  }

  /** Swift `private func startTimer()`. */
  private startTimer(): void {
    this.recordingSeconds = 0;
    this.recordDuration = durationFormatted(0);
    this.stopTimer();
    this.recordingTimer = setInterval((): void => {
      this.recordingSeconds = this.recordingSeconds + 1;
      this.recordDuration = durationFormatted(this.recordingSeconds);
    }, TIMER_TICK_MS);
  }

  /** Swift `private func stopTimer()`. */
  private stopTimer(): void {
    if (this.recordingTimer !== -1) {
      clearInterval(this.recordingTimer);
      this.recordingTimer = -1;
    }
  }

  /** Swift `func sendFile()`. */
  private sendFile(): void {
    if (this.fileName.length === 0) {
      return;
    }
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      this.showDaemonNotice = true;
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const name: string = RecordAudioVideoMessageOverlay.lastPathComponent(this.fileName);
    this.releasePlayer();
    // Staging the file into the conversation's directory is real; the SEND itself is the
    // daemon gap, which the subscription above turns into the visible notice.
    registry.dataTransferService.sendFile(conversation, this.fileName, name, null);
    registry.videoService.videRecordingFinished();
    if (!registry.daemonService.daemonStarted) {
      // The recording did NOT leave the device. Swift dismissed here; dismissing on a send
      // that never happened would read as success, so the overlay stays with the notice.
      this.showDaemonNotice = true;
      return;
    }
    this.dismiss();
  }

  /** Swift `func cancel()`. */
  private cancel(): void {
    if (this.isRecording) {
      this.stopRecording();
    }
    this.cancelPlayerCreate();
    this.releasePlayer();
    const registry: ServiceRegistry = ServiceRegistry.shared();
    registry.videoService.videRecordingFinished();
    if (this.fileName.length > 0) {
      // Swift `try? FileManager.default.removeItem(atPath: fileName)`.
      registry.dataTransferService.removeFile(this.fileName);
      this.fileName = '';
    }
    this.dismiss();
  }

  /** Swift `dismissHandler.dismissView()` — an overlay, so no page is popped. */
  private dismiss(): void {
    // The host's presentation state goes down first: it is what tells screen_conversation
    // the recorder is no longer up, whichever control closed it.
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** Swift `func switchCamera()`. */
  private switchCamera(): void {
    ServiceRegistry.shared().videoService.switchCamera();
  }

  /** Swift `func togglePause()` -> `player?.togglePause()`. */
  private togglePause(): void {
    if (this.playerId.length === 0) {
      return;
    }
    const video: VideoService = ServiceRegistry.shared().videoService;
    if (this.isFinished) {
      // Swift `case .finished: seekToTime(time: 0); transition(to: .playing)`.
      this.isFinished = false;
      video.seekToTime(0, this.playerId);
    }
    this.isPaused = !this.isPaused;
    video.pausePlayer(this.playerId, this.isPaused);
    if (this.isPaused) {
      this.stopProgress();
    } else {
      this.startProgress();
    }
  }

  /** Swift `transition(to: .playing)` -> `startTimer()`. */
  private startProgress(): void {
    this.stopProgress();
    this.lastPosition = 0;
    this.progressTimer = setInterval((): void => {
      this.pollPosition();
    }, PROGRESS_TICK_MS);
  }

  /** Swift `invalidateTimer()`. */
  private stopProgress(): void {
    if (this.progressTimer !== -1) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /**
   * Swift `timerFired()` — the slider follows the position, and the end is detected: libjami
   * rewinds to 0, AVPlayer instead parks in 'completed', so the position stops near the end.
   */
  private pollPosition(): void {
    if (this.isSeeking || this.playerDuration <= 0 || this.playerId.length === 0) {
      return;
    }
    const time: number = ServiceRegistry.shared().videoService.getPlayerPosition(this.playerId);
    if (time < 0) {
      return;
    }
    this.seek = Math.min(time / this.playerDuration, 1);
    const rewound: boolean = time === 0 && this.lastPosition > 0;
    const parked: boolean = time > 0 && time === this.lastPosition &&
      this.playerDuration - time <= END_SLACK_MS;
    this.lastPosition = time;
    if (rewound || parked) {
      this.finishPlayback();
    }
  }

  /** Swift `transition(to: .finished)` — the play glyph again, the slider back at 0. */
  private finishPlayback(): void {
    this.stopProgress();
    this.isFinished = true;
    this.isPaused = true;
    ServiceRegistry.shared().videoService.pausePlayer(this.playerId, true);
    this.seek = 0;
  }

  /** Swift `func muteAudio()` -> `player?.muteAudio()`. */
  private muteAudio(): void {
    this.isAudioMuted = !this.isAudioMuted;
    if (this.playerId.length === 0) {
      return;
    }
    ServiceRegistry.shared().videoService.mutePlayerAudio(this.playerId, this.isAudioMuted);
  }

  /** Swift `func userStartSeeking()`. */
  private userStartSeeking(): void {
    this.isSeeking = true;
  }

  /** Swift `func seek(to:)` -> `player?.seekTimeVariable.accept(value)`. */
  private seekTo(value: number): void {
    this.seek = value;
  }

  /** Swift `func userStopSeeking()` -> `seekToTime(Int(playerDuration * seekTime))`. */
  private userStopSeeking(): void {
    this.isSeeking = false;
    if (this.playerId.length === 0) {
      return;
    }
    const time: number = Math.round(this.playerDuration * this.seek);
    ServiceRegistry.shared().videoService.seekToTime(time, this.playerId);
    // Swift `currentTime = Int64(time)`; a seek away from the end is no longer `.finished`.
    this.lastPosition = time;
    this.isFinished = false;
  }

  /* ── builders ───────────────────────────────────────────────────────────────────── */

  /** Swift `ScaleButtonStyle` at rest. @Styles takes no parameters, so it is two members. */
  @Styles
  private restingControl() {
    .scale({ x: 1, y: 1 })
  }

  /** Swift `ScaleButtonStyle` pressed — `.scaleEffect(0.92)`. */
  @Styles
  private pressedControl() {
    .scale({ x: PRESSED_SCALE, y: PRESSED_SCALE })
  }

  /** Swift `private var cancelButton` — `glassLabelButton(text: L10n.Global.cancel)`. */
  @Builder
  private cancelButton() {
    Text($r('app.string.global_cancel'))
      .constraintSize({ minHeight: TOUCH_TARGET })
      .padding({
        start: LengthMetrics.vp(INNER_H_PADDING),
        end: LengthMetrics.vp(INNER_H_PADDING)
      })
      // Swift `glassLabelButton(text:)` — 17 pt regular white on a glass CAPSULE, so the
      // radius is half the 44 pt height rather than a fixed corner.
      .fontSize(PRIMARY_TEXT_SIZE)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .backgroundColor(GLASS_FILL)
      .backdropBlur(GLASS_BLUR)
      .borderRadius(TOUCH_TARGET / 2)
      .borderWidth(GLASS_STROKE_WIDTH)
      .borderColor(GLASS_STROKE_COLOR)
      .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .id('mediaRecordCancel')
      .onClick(() => {
        this.cancel();
      })
  }

  /** Swift `private var switchCameraButton` — arrow.triangle.2.circlepath.camera. */
  @Builder
  private switchCameraButton() {
    // The glyph sits in a centring Stack: a SymbolGlyph sized to 44 draws its glyph at the
    // start edge, so it sat off-centre in the disc (T-1032).
    Stack() {
      SymbolGlyph($r('sys.symbol.arrow_triangle_2_circlepath_camera'))
        .fontSize(SWITCH_CAMERA_GLYPH_SIZE)
        // Swift `glassIconButton(... size: 20)` — `.font(.system(size:weight: .semibold))`.
        .fontWeight(WEIGHT_SEMIBOLD)
        .fontColor([Color.White])
    }
    .width(TOUCH_TARGET)
    .height(TOUCH_TARGET)
    .backgroundColor(GLASS_FILL)
    .backdropBlur(GLASS_BLUR)
    .borderRadius(TOUCH_TARGET / 2)
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE_COLOR)
    .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
    .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
    .id('mediaRecordSwitchCamera')
    // Swift `accessibilityLabel: L10n.Accessibility.Calls.Default.switchCamera` — the
    // control is icon-only, so this is its only readable name.
    .accessibilityText($r('app.string.accessibility_calls_default_switch_camera'))
    .onClick(() => {
      this.switchCamera();
    })
  }

  /** Swift `private var recordingTimerBadge`. */
  @Builder
  private recordingTimerBadge() {
    Row({ space: 6 }) {
      Column()
        .width(TIMER_DOT_SIZE)
        .height(TIMER_DOT_SIZE)
        .borderRadius(TIMER_DOT_SIZE / 2)
        .backgroundColor(IOS_RED)
      // Swift `.font(.system(.subheadline, design: .monospaced).weight(.semibold))` — the
      // monospaced family is what stops the elapsed time jittering as its digits change.
      Text(this.recordDuration)
        .constraintSize({ minWidth: TOUCH_TARGET })
        .fontSize(READOUT_TEXT_SIZE)
        .fontWeight(WEIGHT_SEMIBOLD)
        .fontFamily('HarmonyOS Sans Mono')
        .fontColor(Color.White)
    }
    .constraintSize({ minHeight: TOUCH_TARGET })
    .padding({ start: LengthMetrics.vp(14), end: LengthMetrics.vp(14) })
    .alignItems(VerticalAlign.Center)
    // Swift `.glassCapsuleBackground()`.
    .backgroundColor(GLASS_FILL)
    .backdropBlur(GLASS_BLUR)
    .borderRadius(TOUCH_TARGET / 2)
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE_COLOR)
  }

  /** Swift `private var sendRow` + `private var sendButton`. */
  @Builder
  private sendRow() {
    Row({ space: 12 }) {
      SymbolGlyph(this.isAudioMode
        ? $r('sys.symbol.waveform_1') : $r('sys.symbol.video_fill'))
        .fontSize(ICON_SIZE)
        .fontWeight(WEIGHT_SEMIBOLD)
        // Swift `.foregroundColor(.white.opacity(0.7))` — the leading glyph is quieter than
        // the file name beside it.
        .fontColor([GLASS_LEADING_GLYPH_COLOR])
      // The recorded file's own name — data from svc_data_transfer's path, not a literal.
      Text(this.fileDisplayName)
        .maxLines(1)
        // Swift `.truncationMode(.middle)`: a long name keeps its head and its extension (T-1722).
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        .fontSize(SECONDARY_TEXT_SIZE)
        .fontWeight(WEIGHT_MEDIUM)
        .fontColor(Color.White)
      Blank()
      Row({ space: 6 }) {
        Text($r('app.string.data_transfer_send_message'))
          .fontSize(PRIMARY_TEXT_SIZE)
          .fontColor(Color.Black)
        SymbolGlyph($r('sys.symbol.paperplane_fill'))
          .fontSize(PRIMARY_TEXT_SIZE)
          .fontWeight(WEIGHT_SEMIBOLD)
          .fontColor([Color.Black])
          // The HarmonyOS paperplane points straight up; SF `paperplane.fill` points up-right.
          .rotate({ angle: PAPERPLANE_SF_ANGLE })
      }
      .alignItems(VerticalAlign.Center)
      .padding({
        start: LengthMetrics.vp(INNER_H_PADDING),
        end: LengthMetrics.vp(INNER_H_PADDING),
        top: LengthMetrics.vp(8), bottom: LengthMetrics.vp(8)
      })
      // Swift `.background(Color.white.opacity(0.9)).clipShape(Capsule())` — the one solid
      // control on the screen, which is what makes Send read as the primary action.
      .backgroundColor(SEND_BUTTON_FILL)
      .borderRadius(SEND_BUTTON_RADIUS)
      .clip(true)
      .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
      .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
      .id('mediaRecordSend')
      .onClick(() => {
        this.sendFile();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(INNER_H_PADDING),
      end: LengthMetrics.vp(INNER_H_PADDING),
      top: LengthMetrics.vp(10), bottom: LengthMetrics.vp(10)
    })
    // Swift `.glassRoundedBackground(cornerRadius: Layout.panelCornerRadius)`.
    .backgroundColor(GLASS_FILL)
    .backdropBlur(GLASS_BLUR)
    .borderRadius(PANEL_CORNER_RADIUS)
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE_COLOR)
  }

  /** Swift `private var topBar`. */
  @Builder
  private topBar() {
    Column({ space: TOP_BAR_GAP }) {
      Stack() {
        Row() {
          this.cancelButton()
          Blank()
          // conditionalVariants[video_mode]: the camera switch exists only with a camera.
          if (this.isVideoMode) {
            this.switchCameraButton()
          } else {
            // Swift `Color.clear.frame(44)` — the badge stays centred without it.
            Column()
              .width(TOUCH_TARGET)
              .height(TOUCH_TARGET)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // conditionalVariants[recording]: the elapsed-time badge.
        if (this.isRecording) {
          this.recordingTimerBadge()
        }
      }
      .width('100%')

      // conditionalVariants[recorded]: the send row appears once a recording exists.
      if (this.isRecorded) {
        this.sendRow()
      }
    }
    .width('100%')
    .padding({
      start: LengthMetrics.vp(SCREEN_H_PADDING),
      end: LengthMetrics.vp(SCREEN_H_PADDING),
      top: LengthMetrics.vp(this.topInset + INNER_H_PADDING),
      bottom: LengthMetrics.vp(8)
    })
  }

  /** Swift `private var audioOnlyContent` + `audioWaveformView`. */
  @Builder
  private audioOnlyContent() {
    Column({ space: AUDIO_CONTENT_GAP }) {
      if (!this.hideInfo) {
        // Swift `.font(.body).foregroundColor(.secondary)` — this is the ONE branch drawn
        // over `systemBackground` rather than over video, so it takes the page's own
        // secondary text colour, not white.
        Text($r('app.string.data_transfer_info_message'))
          .textAlign(TextAlign.Center)
          .padding({ start: LengthMetrics.vp(32), end: LengthMetrics.vp(32) })
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.secondary_label'))
      }
      Stack() {
        // conditionalVariants[recording]: live bars while the recorder runs, the hero
        // waveform glyph otherwise.
        if (this.isRecording) {
          // Swift `.frame(height: 80).padding(.horizontal, 40)`: a fixed box, so the bars
          // rise and fall about a still centre instead of resizing the column.
          Column() {
            AudioWaveformView({ isAnimating: this.waveform })
          }
          .height(WAVEFORM_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .padding({
            start: LengthMetrics.vp(WAVEFORM_H_PADDING),
            end: LengthMetrics.vp(WAVEFORM_H_PADDING)
          })
        } else {
          // SF `waveform` is vertical bars: that is HarmonyOS `waveform_1`; `waveform` is a
          // sine squiggle (TC-CHAT-378).
          SymbolGlyph($r('sys.symbol.waveform_1'))
            .fontSize(HERO_ICON_SIZE)
            // Swift `.weight(.ultraLight)` — ArkUI's lightest is FontWeight.Lighter.
            .fontWeight(FontWeight.Lighter)
            // Swift `.foregroundColor(viewModel.isReadyToSend ? .green : .secondary)`.
            // `isReadyToSend` is this port's `isRecorded` — the same gate the send row uses.
            .fontColor([this.isRecorded
              ? READY_GLYPH_COLOR : $r('app.color.secondary_label')])
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: LengthMetrics.vp(40), bottom: LengthMetrics.vp(40) })
  }

  /** comp_media_seek_slider — Swift's `MediaSeekSlider(onRegister:onSeekStart:…)`. */
  @Builder
  private seekSlider() {
    MediaSeekSlider({
      positionRatio: this.seek,
      onSeekStart: (): void => {
        this.userStartSeeking();
      },
      onSeekChange: (value: number): void => {
        this.seekTo(value);
      },
      onSeekEnd: (): void => {
        this.userStopSeeking();
      }
    })
  }

  /** Swift `private var playerControlsPanel`. */
  @Builder
  private playerControlsPanel() {
    Column({ space: INNER_H_PADDING }) {
      this.seekSlider()

      Stack() {
        // Swift `playPauseButton` — conditionalVariants[paused] picks the glyph.
        Stack() {
          SymbolGlyph(this.isPaused ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'))
            .fontSize(LARGE_ICON_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor([Color.White])
        }
        .width(PRIMARY_BUTTON_SIZE)
        .height(PRIMARY_BUTTON_SIZE)
        // Swift `Circle().stroke(Color.white.opacity(0.6), lineWidth: 3)` over
        // `.glassCircleBackground()` — the ring is the stroke, the fill is the glass.
        .backgroundColor(GLASS_FILL)
        .backdropBlur(GLASS_BLUR)
        .borderRadius(PRIMARY_BUTTON_SIZE / 2)
        .borderWidth(RING_STROKE_WIDTH)
        .borderColor(RING_STROKE_COLOR)
        .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
        .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
        .id('mediaRecordPlayPause')
        .accessibilityText(this.isPaused
          ? $r('app.string.accessibility_audio_player_play')
          : $r('app.string.accessibility_audio_player_pause'))
        // The player only exists once a recording has been made — the source's own guard.
        .enabled(this.showPlayerControls)
        .onClick(() => {
          this.togglePause();
        })

        Row() {
          // Swift `durationText` — viewModel.playerDuration.durationString, which divides its
          // microseconds down to seconds; milliseconds read as seconds showed 04:36:38.
          Text(durationFormatted(this.playerDuration / 1000))
            .constraintSize({ minWidth: DURATION_MIN_WIDTH })
            // Swift `.font(.system(.subheadline, design: .monospaced)).fontWeight(.medium)`.
            .fontSize(READOUT_TEXT_SIZE)
            .fontWeight(WEIGHT_MEDIUM)
            .fontFamily('HarmonyOS Sans Mono')
            .fontColor(Color.White)
            .padding({ start: LengthMetrics.vp(4) })
          Blank()
          // A centring Stack, as switchCameraButton (T-1032): a SymbolGlyph sized to 44 draws its
          // glyph at the start edge of the disc.
          Stack() {
            SymbolGlyph(this.isAudioMuted
              ? $r('sys.symbol.speaker_slash_fill') : $r('sys.symbol.speaker_wave_2_fill'))
              .fontSize(ICON_SIZE)
              .fontWeight(WEIGHT_SEMIBOLD)
              .fontColor([Color.White])
          }
          .width(TOUCH_TARGET)
          .height(TOUCH_TARGET)
          // Swift `.glassCircleBackground()`.
          .backgroundColor(GLASS_FILL)
          .backdropBlur(GLASS_BLUR)
          .borderRadius(TOUCH_TARGET / 2)
          .borderWidth(GLASS_STROKE_WIDTH)
          .borderColor(GLASS_STROKE_COLOR)
          .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
          .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
          .id('mediaRecordMute')
          .accessibilityText(this.isAudioMuted
            ? $r('app.string.accessibility_conference_unmute_audio')
            : $r('app.string.accessibility_conference_mute_audio'))
          .enabled(this.showPlayerControls)
          .onClick(() => {
            this.muteAudio();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // Full-width and drawn above playPause (ArkUI hits the topmost target): without this
        // its Blank swallowed every Play/Pause tap and the pause icon never showed.
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
    }
    .width('100%')
    .padding({
      start: LengthMetrics.vp(INNER_H_PADDING),
      end: LengthMetrics.vp(INNER_H_PADDING),
      top: LengthMetrics.vp(12), bottom: LengthMetrics.vp(12)
    })
    // Swift `.glassRoundedBackground(cornerRadius: Layout.panelCornerRadius)`, then the
    // screen inset OUTSIDE it — the panel is a card, not a full-bleed bar.
    .backgroundColor(GLASS_FILL)
    .backdropBlur(GLASS_BLUR)
    .borderRadius(PANEL_CORNER_RADIUS)
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE_COLOR)
    .margin({
      start: LengthMetrics.vp(SCREEN_H_PADDING),
      end: LengthMetrics.vp(SCREEN_H_PADDING),
      bottom: LengthMetrics.vp(INNER_H_PADDING)
    })
  }

  /** Swift `private var bottomBar` — the record/stop Button around RecordButtonLabel. */
  @Builder
  private bottomBar() {
    Row() {
      Blank()
      RecordButtonLabel({ isRecording: this.isRecording })
      Blank()
    }
    .width('100%')
    .padding({ top: LengthMetrics.vp(24), bottom: LengthMetrics.vp(40) })
    // The whole bar is Swift's Button (`frame(maxWidth: .infinity)`), so the slug and the
    // handler sit here and not on the label inside it.
    // Swift `.buttonStyle(ScaleButtonStyle())` on the Button, i.e. on this whole bar.
    .stateStyles({ normal: this.restingControl, pressed: this.pressedControl })
    .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
    .id('mediaRecordToggleRecording')
    .accessibilityText($r('app.string.accessibility_conference_recording'))
    .onClick(() => {
      this.triggerRecording();
    })
  }

  build() {
    // Swift `ZStack { VideoPreviewLayer().ignoresSafeArea() ; contentLayer }`.
    Stack() {
      // Swift `.ignoresSafeArea()` + `.scaledToFill()`: the box overflows the screen and the
      // outer Stack clips it (see fitPreview).
      Stack() {
        VideoPreviewLayer({
          audioOnly: this.isAudioMode,
          onSurfaceReady: (surfaceId: string): void => {
            this.previewAppeared(surfaceId);
          },
          onSurfaceReleased: (): void => {
            this.previewReleased();
          }
        })
      }
      .width(this.previewWidth)
      .height(this.previewHeight)

      // Swift `contentLayer` — VStack(spacing: 0).
      Column() {
        this.topBar()
        Blank()
        // conditionalVariants[audio_mode]: the waveform replaces the camera preview.
        if (this.isAudioMode) {
          this.audioOnlyContent()
        }
        this.bottomBar()
        // conditionalVariants[recorded]: Swift gates the panel on `showPlayerControls`,
        // which is only ever raised once a recording exists.
        if (this.isRecorded && this.showPlayerControls) {
          this.playerControlsPanel()
        }
        /*
         * S6 — the three things that can go wrong, all drawn in the screen's own glass
         * vocabulary so they read as part of the overlay rather than as a system alert
         * laid over it. They never replace the preview or the record button: the capture's
         * chrome stays put and the message appears under it.
         */
        if (this.showRecordFailure) {
          Text($r('app.string.alerts_no_media_permissions_title'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize(SECONDARY_TEXT_SIZE)
            .fontColor(Color.White)
            .padding(INNER_H_PADDING)
            .backgroundColor(GLASS_FILL)
            .backdropBlur(GLASS_BLUR)
            .borderRadius(PANEL_CORNER_RADIUS)
            .margin({
              start: LengthMetrics.vp(SCREEN_H_PADDING),
              end: LengthMetrics.vp(SCREEN_H_PADDING),
              bottom: LengthMetrics.vp(INNER_H_PADDING)
            })
            .id('media_record_permission_notice')
        }
        if (this.showDaemonNotice) {
          Text($r('app.string.daemon_not_available'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize(SECONDARY_TEXT_SIZE)
            .fontColor(Color.White)
            .padding(INNER_H_PADDING)
            .backgroundColor(GLASS_FILL)
            .backdropBlur(GLASS_BLUR)
            .borderRadius(PANEL_CORNER_RADIUS)
            .margin({
              start: LengthMetrics.vp(SCREEN_H_PADDING),
              end: LengthMetrics.vp(SCREEN_H_PADDING),
              bottom: LengthMetrics.vp(INNER_H_PADDING)
            })
            .id('media_record_daemon_notice')
        }
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize(SECONDARY_TEXT_SIZE)
            .fontColor(IOS_RED)
            .padding(INNER_H_PADDING)
            .margin({
              start: LengthMetrics.vp(SCREEN_H_PADDING),
              end: LengthMetrics.vp(SCREEN_H_PADDING),
              bottom: LengthMetrics.vp(INNER_H_PADDING)
            })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((_old: Area, area: Area): void => {
      this.fitPreview(area);
    })
    .id('screen_media_record')
  }
}
