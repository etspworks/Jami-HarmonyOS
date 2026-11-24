/*
 * comp_player_view — ported from Ring/Ring/Features/Conversations/views/PlayerView.swift
 * `struct PlayerView` (line 228):
 *
 *   ZStack { backgroundColor
 *            VideoLayerView(displayLayer:)            // the decoded frames
 *            videoTapLayer                             // tap -> media preview, long press -> menu
 *            if sizeMode == .fullScreen { transparent tap layer "playerToggleControls" }
 *            if withControls { controlsOverlay } }
 *
 *   controlsOverlay = sizeMode == .fullScreen
 *       ? 4.21 VideoPreviewContent.playButton("playerPlayPause"), shown with the preview's chrome
 *         (its mute / time / scrubber capsule is the preview's own bottom chrome, T-1624)
 *       : messageControls
 *
 *   videoMessageControls = videoMessagePlayButton("videoMessagePlayPause") +
 *                          videoMessageBottomBar { duration | "videoMessageMute" | slider }
 *   audioMessageControls = HStack { waveform | "audioMessagePlayPause" | duration + slider }
 *
 * THREE presentation modes with different control sets — one flattened player would ship the
 * wrong controls in two of the three. The video surface itself is an XComponent in S4 (AVPlayer
 * via @ohos.multimedia.media); S3 places it.
 */

import { media } from '@kit.MediaKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describeError } from '../common/ErrorText';
import { durationFormatted } from '../model/MessageModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'PlayerView';

/* ── S5 metrics, the source's own (PlayerView.swift:300-520) ──────────────────────── */
/** Swift `backgroundColor` — black full-screen, `placeholderText` behind a message player. */
const PLAYER_BG_FULLSCREEN: string = '#FF000000';
const PLAYER_BG_MESSAGE: string = '#4D3C3C43';
/** 4.21 `VideoPreviewContent`: `playIconSize = 34` (medium) in a `playButtonSize = 84` glass disc. */
const CENTER_PLAY_GLYPH: number = 34;
const CENTER_PLAY_DISC: number = 84;
/** Swift `videoMessagePlayButton`: 28pt glyph in a 52pt disc; its bar glyph 14pt in 36pt. */
const VIDEO_MSG_PLAY_GLYPH: number = 28;
const VIDEO_MSG_PLAY_DISC: number = 52;
const VIDEO_MSG_MUTE_GLYPH: number = 14;
const VIDEO_MSG_MUTE_TAP: number = 36;
/** Swift `videoMessageBottomBar`: `VStack(spacing: 2)`, `.padding(.horizontal, 10).padding(.bottom, 6)`. */
const VIDEO_MSG_BAR_GAP: number = 2;
const VIDEO_MSG_BAR_PADDING: number = 10;
const VIDEO_MSG_BAR_BOTTOM: number = 6;
/**
 * Swift `videoMessageGradient`: `VStack { Spacer(); LinearGradient(black 0 -> 0.75) }`, so the
 * gradient fills the lower half. One full-size gradient, clear down to its middle.
 */
const VIDEO_MSG_GRADIENT: Array<[ResourceColor, number]> = [['#00000000', 0.5], ['#BF000000', 1]];
/** Swift `audioMessageControls`: `HStack(spacing: 10)`, waveform 20 in 28, play 20 in 40. */
const AUDIO_GAP: number = 10;
const AUDIO_WAVEFORM_GLYPH: number = 20;
const AUDIO_WAVEFORM_WIDTH: number = 28;
const AUDIO_PLAY_GLYPH: number = 20;
const AUDIO_PLAY_DISC: number = 40;
const AUDIO_H_PADDING: number = 12;
/**
 * Swift `.applyGlassButtonBackground()` / `.applyControlsBarBackground()` = `glassBackground`:
 * UIBlurEffect(.dark) + a white 0.2 hairline, the media preview's own glass
 * (MediaPreviewBottomBar). A 35% black scrim read as a pale grey disc over a light video (T-1618).
 */
const GLASS_TINT: string = '#BC1A1A1A';
const GLASS_BLUR: number = 40;
const GLASS_STROKE: string = '#33FFFFFF';
const GLASS_STROKE_WIDTH: number = 0.5;
/** Swift `.foregroundColor(.white.opacity(0.5))` on the waveform. */
const WAVEFORM_OPACITY: number = 0.5;
/** Swift `.buttonStyle(ScaleButtonStyle())` on centerPlayButton — `.scaleEffect(0.92)` pressed. */
const PRESS_EFFECT: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.92 };

/**
 * Swift `.font(.system(.caption, design: .monospaced))` on every player duration: caption 12,
 * SF Mono. `monospace` is the system's Noto Sans Mono (fontconfig), monospaced like SF Mono.
 */
@Extend(Text)
  function durationFont() {
  .fontSize($r('sys.float.Body_S'))
    .fontFamily('monospace')
}

/** Swift `VStack(alignment: .trailing, spacing: 4)` in the audio controls. */
const REPLY_GAP: number = 4;
/** 4.21 `MediaPreviewLayout.chromeAnimation` — `.easeInOut(duration: 0.2)` on the play button. */
const CONTROLS_FADE_MS: number = 200;

/** Swift `enum PlayerMode` — the three shapes this player takes. */
export enum PlayerMode {
  FULL_SCREEN = 'fullScreen',
  VIDEO_MESSAGE = 'videoMessage',
  AUDIO_MESSAGE = 'audioMessage'
}

/**
 * Swift `PlayerCoordinator` + `PlayerViewModel`, flattened to what the view reads.
 * @Observed so the AVPlayer's callbacks re-render the controls that read it.
 */
@Observed
export class PlayerModel {
  /** Swift `coordinator.isPaused`. */
  isPaused: boolean = true;
  /** Swift `coordinator.isMuted`. */
  isMuted: boolean = false;
  /** Swift `coordinator.hasVideo` — no mute button on an audio-only track in full screen. */
  hasVideo: boolean = false;
  /** Swift `coordinator.duration.durationString`. */
  durationText: string = '';
  /** The media's length in seconds — 4.21 `elapsedTimeString` is `position` of it. */
  durationSeconds: number = 0;
  /** Swift the slider's 0..1 position. */
  position: number = 0;
  /** Swift `coordinator.controlsVisible`. */
  controlsVisible: boolean = true;
  /** The media this player renders <- MessageModel.content (the transfer's local path). */
  path: string = '';
  /** ArkUI XComponent surface id, handed to the AVPlayer in S4. */
  surfaceId: string = '';
}

@Component
export struct PlayerView {
  /** Swift `coordinator` — two-way, so a state change inside the player repaints its controls. */
  @ObjectLink @Watch('onModelChange') model: PlayerModel;
  /** Swift `var sizeMode: PlayerMode`. */
  sizeMode: PlayerMode = PlayerMode.VIDEO_MESSAGE;
  /** Swift `var withControls: Bool`. */
  withControls: boolean = true;
  /** Swift `viewModel.togglePause()`. */
  onTogglePause?: () => void;
  /** Swift `viewModel.muteAudio()`. */
  onToggleMute?: () => void;
  /** Swift `onVideoTap` — raises the media preview over the conversation. */
  onVideoTap?: () => void;
  /** Swift `onVideoLongPress` — raises the message context menu. */
  onVideoLongPress?: () => void;
  /** Swift `toggleControls()` — full screen only. */
  onToggleControls?: () => void;
  /** Swift `updatePlayer(player:)`: the shown video's width / height, rotation applied. */
  onVideoRatio?: (ratio: number) => void;
  /** comp_media_seek_slider — Swift `seekSlider(autoHide:)`, declared by the page. */
  @BuilderParam seekBuilder: () => void;

  /**
   * Swift `PlayerCoordinator`'s AVPlayer. Built on the first play and released in
   * `aboutToDisappear`'s finally (rule 8) — one player per media message, as iOS had one
   * coordinator per message.
   */
  private avPlayer: media.AVPlayer | null = null;
  /** The local transfer opened for the AVPlayer, closed with it. */
  private file: fileIo.File | null = null;
  /** The ratio the AVPlayer last reported; any other `model.position` is a seek request. */
  private reportedPosition: number = 0;
  /** The mute the AVPlayer last got; any other `model.isMuted` is a mute request. */
  private appliedMuted: boolean = false;
  private surfaceController: XComponentController = new XComponentController();
  /** False while the full-screen player is only prepared for its first frame (Swift setupPlayer). */
  private autoPlay: boolean = true;
  /** Video width / height and the player's box, for Swift's full-screen aspect fill. */
  @State private videoRatio: number = 0;
  @State private boxWidth: number = 0;
  @State private boxHeight: number = 0;
  /** True while this player holds the audioPlayback continuous task. */
  private backgroundTaskRunning: boolean = false;

  aboutToDisappear(): void {
    this.stopBackgroundTask();
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      player.release();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'release failed: %{public}s',
        describeError(error as BusinessError));
    } finally {
      this.avPlayer = null;
      this.closeFile();
    }
  }

  private closeFile(): void {
    const file: fileIo.File | null = this.file;
    this.file = null;
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'close failed: %{public}s',
          describeError(error as BusinessError));
      }
    }
  }

  /**
   * Swift `viewModel.seek(to:)` — the slider moved `model.position`, the AVPlayer follows; and
   * `viewModel.muteAudio()` from the preview's own mute button (4.21 VideoPreviewControls),
   * which flips `model.isMuted` from outside this view.
   */
  private onModelChange(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.model.isMuted !== this.appliedMuted) {
      this.appliedMuted = this.model.isMuted;
      player.setVolume(this.appliedMuted ? 0 : 1);
    }
    if (player.duration <= 0 || this.model.position === this.reportedPosition) {
      return;
    }
    this.reportedPosition = this.model.position;
    player.seek(this.model.position * player.duration, media.SeekMode.SEEK_CLOSEST);
  }

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  private hostContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /**
   * Swift `viewModel.togglePause()`. Builds the AVPlayer the first time, points it at the
   * message's own local file and the XComponent's surface, then plays or pauses.
   */
  private togglePause(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      this.startPlayback();
    } else if (this.model.isPaused) {
      // A tap before `prepared` plays from the prepared handler instead.
      this.autoPlay = true;
      player.play()
        .then((): void => {
          this.model.isPaused = false;
          this.startBackgroundTask();
        })
        .catch((error: BusinessError): void => {
          this.reportFailure(error);
        });
    } else {
      player.pause()
        .then((): void => {
          this.model.isPaused = true;
          this.stopBackgroundTask();
        })
        .catch((error: BusinessError): void => {
          this.reportFailure(error);
        });
    }
    // The page still owns the coordinator-level bookkeeping (which message is playing).
    this.fire(this.onTogglePause);
  }

  /** Swift `PlayerCoordinator.setupPlayer(path:)` + `play()`. */
  private startPlayback(autoPlay: boolean = true): void {
    if (this.model.path.length === 0) {
      return;
    }
    this.autoPlay = autoPlay;
    // Swift PlayerViewModel.createPlayer: a video starts muted (`setMuted(true)`), an
    // audio-only file unmuted (`audioMuted.accept(false)`). The prepared handler applies it.
    // Only for a player set up on appear: one first built by a tap keeps the mute already
    // chosen on the bubble.
    if (!autoPlay) {
      this.model.isMuted = this.model.hasVideo;
    }
    media.createAVPlayer()
      .then((player: media.AVPlayer): void => {
        let configured: boolean = false;
        try {
          player.on('stateChange', (state: string): void => {
            this.onStateChange(state);
          });
          player.on('timeUpdate', (time: number): void => {
            this.onTimeUpdate(time);
          });
          player.on('videoSizeChange', (width: number, height: number): void => {
            this.videoRatio = width > 0 && height > 0 ? width / height : 0;
            const report: ((ratio: number) => void) | undefined = this.onVideoRatio;
            if (report !== undefined && this.videoRatio > 0) {
              report(this.videoRatio);
            }
          });
          // AVPlayer takes no file path: the local transfer goes in as its descriptor, which
          // moves the player to `initialized`; `prepare` happens there.
          this.file = fileIo.openSync(this.model.path, fileIo.OpenMode.READ_ONLY);
          player.fdSrc = { fd: this.file.fd };
          this.avPlayer = player;
          configured = true;
        } finally {
          // Rule 8: a player that could not be configured is released here, not leaked until
          // the component disappears (which may never happen for an off-screen row).
          if (!configured) {
            this.avPlayer = null;
            this.closeFile();
            player.release();
          }
        }
      })
      .catch((error: BusinessError): void => {
        this.reportFailure(error);
      });
  }

  /** The AVPlayer state machine: initialized -> prepared -> playing, and completion. */
  private onStateChange(state: string): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    if (state === 'initialized') {
      // SurfaceID is accepted only in `initialized` (5400102 when set while idle, so the
      // picture never showed).
      if (this.model.surfaceId.length > 0) {
        player.surfaceId = this.model.surfaceId;
      }
      const prepare = (): void => {
        player.prepare().catch((error: BusinessError): void => {
          this.reportFailure(error);
        });
      };
      // Swift's AVPlayerLayer shows the first frame before play.
      player.setPlaybackStrategy({ showFirstFrameOnPrepare: true })
        .then(prepare, (error: BusinessError): void => {
          this.reportFailure(error);
          prepare();
        });
    } else if (state === 'prepared') {
      // Swift `coordinator.duration.durationString` (AVPlayer.duration is in ms).
      this.model.durationText = durationFormatted(player.duration / 1000);
      this.model.durationSeconds = player.duration / 1000;
      this.appliedMuted = this.model.isMuted;
      player.setVolume(this.appliedMuted ? 0 : 1);
      if (!this.autoPlay) {
        return;
      }
      player.play()
        .then((): void => {
          this.model.isPaused = false;
          this.startBackgroundTask();
        })
        .catch((error: BusinessError): void => {
          this.reportFailure(error);
        });
    } else if (state === 'completed') {
      // Swift: the coordinator rewinds to the start and shows the play button again.
      this.model.isPaused = true;
      this.reportedPosition = 0;
      this.model.position = 0;
      this.stopBackgroundTask();
    }
  }

  /** Swift `coordinator.progress` — the slider's 0..1 position. */
  private onTimeUpdate(time: number): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || player.duration <= 0) {
      return;
    }
    this.reportedPosition = time / player.duration;
    this.model.position = this.reportedPosition;
  }

  /** Swift `viewModel.muteAudio()`. */
  private toggleMute(): void {
    const muted: boolean = !this.model.isMuted;
    this.model.isMuted = muted;
    const player: media.AVPlayer | null = this.avPlayer;
    if (player !== null) {
      this.appliedMuted = muted;
      player.setVolume(muted ? 0 : 1);
    }
    this.fire(this.onToggleMute);
  }

  /**
   * feat_background: a media message keeps playing while the app is backgrounded, which on
   * HarmonyOS is an `audioPlayback` continuous task (module.json5 declares the mode and
   * KEEP_BACKGROUND_RUNNING). A refusal is reported, never fatal — playback simply stops with
   * the app, as it would with no task at all.
   */
  private startBackgroundTask(): void {
    if (this.backgroundTaskRunning) {
      return;
    }
    const context: common.UIAbilityContext = this.hostContext();
    this.backgroundTaskRunning = true;
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    };
    wantAgent.getWantAgent(info)
      .then((agent: WantAgent) => backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent))
      .catch((error: BusinessError): void => {
        this.backgroundTaskRunning = false;
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'audioPlayback keep-alive unavailable: %{public}s',
          describeError(error));
      });
  }

  private stopBackgroundTask(): void {
    if (!this.backgroundTaskRunning) {
      return;
    }
    this.backgroundTaskRunning = false;
    backgroundTaskManager.stopBackgroundRunning(this.hostContext())
      .catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopBackgroundRunning failed: %{public}s',
          describeError(error));
      });
  }

  private reportFailure(error: BusinessError): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'player failed: %{public}s', describeError(error));
  }

  /**
   * Swift `.resizeAspectFill` on the full-screen layer: the surface keeps the video's aspect,
   * covers the box and is clipped. A surface stretched to the box distorted the picture.
   */
  private surfaceSize(isWidth: boolean): Length {
    if (this.sizeMode !== PlayerMode.FULL_SCREEN || this.videoRatio <= 0 || this.boxHeight <= 0) {
      return '100%';
    }
    const byHeight: boolean = this.boxWidth / this.boxHeight < this.videoRatio;
    const width: number = byHeight ? this.boxHeight * this.videoRatio : this.boxWidth;
    return isWidth ? width : width / this.videoRatio;
  }

  /**
   * Swift `Button { Image(systemName: isPaused ? "play.fill" : "pause.fill")
   * .font(.system(size: glyph, weight: .medium)).frame(width: disc, height: disc) }
   * .applyGlassButtonBackground()` — every play disc (centerPlayButton, videoMessagePlayButton,
   * the audio one). A centring Stack, as T-1612 / T-1032: a SymbolGlyph framed wider than its
   * glyph draws the glyph at the disc's start edge (T-1618).
   */
  @Builder
  private playButton(id: string, glyph: number, disc: number, pressEffect: ClickEffect | null = null) {
    Stack() {
      SymbolGlyph(this.model.isPaused ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'))
        .fontSize(glyph)
        .fontWeight(FontWeight.Medium)
        .fontColor([Color.White])
    }
    .id(id)
    .accessibilityText($r('app.string.accessibility_audio_player_play'))
    .width(disc)
    .height(disc)
    .backgroundColor(GLASS_TINT)
    .backdropBlur(GLASS_BLUR)
    .borderRadius(disc / 2)
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE)
    .clip(true)
    .clickEffect(pressEffect)
    .onClick(() => {
      this.togglePause();
    })
  }

  /** Swift's mute `Button { Image(...).frame(width: tap, height: tap) }`, centred the same way. */
  @Builder
  private muteButton(id: string, glyph: number, tap: number) {
    Stack() {
      SymbolGlyph(this.model.isMuted
        ? $r('sys.symbol.speaker_slash_fill')
        : $r('sys.symbol.speaker_wave_2_fill'))
        .fontSize(glyph)
        .fontWeight(FontWeight.Medium)
        .fontColor([Color.White])
    }
    .id(id)
    .accessibilityText($r('app.string.accessibility_calls_default_toggle_speaker'))
    .width(tap)
    .height(tap)
    .onClick(() => {
      this.toggleMute();
    })
  }

  /** 4.21 `VideoPreviewContent.playButton` (4.20 `centerPlayButton`). */
  @Builder
  private centerPlayButton() {
    this.playButton('playerPlayPause', CENTER_PLAY_GLYPH, CENTER_PLAY_DISC, PRESS_EFFECT)
  }

  /** Swift `videoMessageControls` = play button + bottom bar. */
  @Builder
  private videoMessageControls() {
    Stack({ alignContent: Alignment.Center }) {
      // Swift `videoMessageGradient` — under the controls, `.allowsHitTesting(false)`.
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ direction: GradientDirection.Bottom, colors: VIDEO_MSG_GRADIENT })
        .hitTestBehavior(HitTestMode.None)

      this.playButton('videoMessagePlayPause', VIDEO_MSG_PLAY_GLYPH, VIDEO_MSG_PLAY_DISC)

      Column({ space: VIDEO_MSG_BAR_GAP }) {
        Blank()
        Row() {
          Text(this.model.durationText)
            .durationFont()
            .fontColor(Color.White)
          Blank()
          this.muteButton('videoMessageMute', VIDEO_MSG_MUTE_GLYPH, VIDEO_MSG_MUTE_TAP)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.seekBuilder()
      }
      .padding({ left: VIDEO_MSG_BAR_PADDING, right: VIDEO_MSG_BAR_PADDING, bottom: VIDEO_MSG_BAR_BOTTOM })
      .width('100%')
      .height('100%')
      // ArkUI hits the TOPMOST target: without this the full-size Column covers
      // `videoMessagePlayPause` beneath it and the play button never fires.
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    // The full-size Stack is the topmost sibling of `videoTapLayer`: left at Default it took
    // every tap off the picture, so a video message never opened the full-screen player.
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** Swift `audioMessageControls` — a waveform glyph, play/pause, duration over the slider. */
  @Builder
  private audioMessageControls() {
    // Swift `HStack(spacing: 10)`: a half-opacity waveform, the play disc, then the duration
    // over the seek slider, right-aligned. SF `waveform` is level bars: HM `waveform_1`; the HM
    // `waveform` is a wavy line (T-1599).
    Row({ space: AUDIO_GAP }) {
      SymbolGlyph($r('sys.symbol.waveform_1'))
        .fontSize(AUDIO_WAVEFORM_GLYPH)
        .fontWeight(FontWeight.Medium)
        .fontColor([Color.White])
        .opacity(WAVEFORM_OPACITY)
        .width(AUDIO_WAVEFORM_WIDTH)
        .accessibilityLevel('no')

      this.playButton('audioMessagePlayPause', AUDIO_PLAY_GLYPH, AUDIO_PLAY_DISC)

      Column({ space: REPLY_GAP }) {
        Text(this.model.durationText)
          .width('100%')
          .durationFont()
          .fontColor(Color.White)
          .textAlign(TextAlign.End)
        this.seekBuilder()
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: AUDIO_H_PADDING, right: AUDIO_H_PADDING })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Swift `VideoLayerView(displayLayer:coordinator:)` — the AVPlayer's output surface.
      XComponent({ id: 'playerSurface', type: XComponentType.SURFACE, controller: this.surfaceController })
        .width(this.surfaceSize(true))
        .height(this.surfaceSize(false))
        // The AVPlayer draws into this surface (startPlayback sets player.surfaceId).
        .onLoad(() => {
          this.model.surfaceId = this.surfaceController.getXComponentSurfaceId();
          // Swift sets a video player up on appear, full screen or in a message: first frame
          // and duration before play (MessageContentVM.onAppear -> getPlayer).
          if (this.sizeMode !== PlayerMode.AUDIO_MESSAGE && this.model.hasVideo && this.avPlayer === null) {
            this.startPlayback(false);
          }
        })

      // Swift `videoTapLayer` — a transparent layer carrying the tap/long-press gestures.
      if (this.model.hasVideo) {
        Column()
          .width('100%')
          .height('100%')
          // The layer must not swallow the controls beneath it (ArkUI topmost-hit-target).
          .hitTestBehavior(HitTestMode.Transparent)
          .onClick(() => {
            this.fire(this.onVideoTap);
          })
          .gesture(LongPressGesture().onAction(() => {
            this.fire(this.onVideoLongPress);
          }))
      }

      if (this.sizeMode === PlayerMode.FULL_SCREEN) {
        // Swift: the full-screen tap layer that shows/hides the controls.
        Column()
          .width('100%')
          .height('100%')
          .id('playerToggleControls')
          .hitTestBehavior(HitTestMode.Transparent)
          .onClick(() => {
            this.fire(this.onToggleControls);
          })
      }

      if (this.withControls) {
        // Swift `controlsOverlay` — a different control set per mode.
        if (this.sizeMode === PlayerMode.FULL_SCREEN) {
          Stack({ alignContent: Alignment.Center }) {
            this.centerPlayButton()
          }
          .width('100%')
          .height('100%')
          // 4.21 `if showsPlayButton { playButton.transition(.opacity) }` with the chrome's
          // `.easeInOut(duration: 0.2)`. While shown the layer itself lets taps through, so the
          // toggle layer beneath can hide the chrome again.
          .opacity(this.model.controlsVisible ? 1 : 0)
          .animation({ duration: CONTROLS_FADE_MS, curve: Curve.EaseInOut })
          .hitTestBehavior(this.model.controlsVisible
            ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
        } else if (this.sizeMode === PlayerMode.VIDEO_MESSAGE) {
          this.videoMessageControls()
        } else {
          this.audioMessageControls()
        }
      }
    }
    .width('100%')
    .clip(true)
    .onAreaChange((_old: Area, area: Area): void => {
      this.boxWidth = Number(area.width);
      this.boxHeight = Number(area.height);
    })
    // Swift `backgroundColor` — black behind a full-screen player, `placeholderText` behind a
    // message one.
    .backgroundColor(this.sizeMode === PlayerMode.FULL_SCREEN
      ? PLAYER_BG_FULLSCREEN
      : PLAYER_BG_MESSAGE)
  }
}
