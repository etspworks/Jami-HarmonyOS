/*
 * screen_call — "In-Call Screen", ported from
 *   Ring/Ring/Calls/CallScreenPresenter.swift + Views/CallScreenView.swift
 *   Ring/Ring/Calls/Views/CallControlsView.swift + CallHeaderView.swift + CallTopActionsView.swift
 *   Ring/Ring/Calls/Views/Canvas/* + Views/ConferenceParticipantsView.swift
 *   Ring/Ring/Calls/ViewModels/CallViewModel.swift
 *
 * presentation: modal, hostScreen: screen_conversation. CallScreenPresenter owns the call UI for
 * the app's lifetime and presents it over whatever is on screen, so it is the @CustomDialog
 * ConversationChatPage mounts — NOT a routed page and NOT in main_pages.json.
 *
 * COMPOSITION ROOT. Every component of screen_call is instantiated in this page: the tile's
 * video surface (comp_renderer_layer), its avatar (comp_call_avatar) and the header
 * (comp_call_header) are declared as the builders below and handed
 * to their containers through @BuilderParam. The nesting is the source's.
 *
 * S3 — `CallScreenView.body`:
 *   ZStack { Color.jamiCallBackdrop
 *            PiPSourceView(model:)        // CallPictureInPicture's own typeNode surface
 *            ConferenceCanvasView(model:previewControlInsets:)  // comp_participant_canvas
 *              .opacity(model.contentHidden ? 0 : 1) }
 *     .overlay(chrome)                                       // top actions + controls
 *     .sheet(isPresented: $model.showsDialpad)    { InCallDialpadView }
 *     .sheet(isPresented: $model.showsParticipants) { ConferenceParticipantsView }
 *
 *   chrome = VStack { if model.showsChrome { CallTopActionsView }
 *                     Spacer()
 *                     if model.showsChrome { CallControlsView } }
 *
 * The control bar is DATA-DRIVEN (`CallControlsLayout.plan`), so the visible buttons follow the
 * call's state, media and conference role. The ids are the source's own
 * `call_control_<intent>` / `call_top_action_<intent>`, with `<intent>` spelled as the Swift
 * enum case (toggleMic, hangUp, startPictureInPicture, …).
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): every control and branch
 * here comes from the source, and the S5 static pre-check against the contract is its only
 * verification.
 *
 * DAEMON GAP: every call action — place, answer, mute, hold, hang up, record, moderate — is
 * jami-daemon work, and HarmonyOS cannot run the daemon. Each control keeps its place and
 * reports the ceiling; nothing here fakes a call or bridges the daemon.
 *
 * CAPABILITY: feat_pip maps to @ohos.PiPWindow (S4), never SYSTEM_FLOAT_WINDOW — a float window
 * is ungrantable on a self-signed build. feat_callkit has no HarmonyOS equivalent without the
 * daemon and is reported, not substituted.
 *
 * OVERLAY HOST: screen_in_call_dialpad (sheet) is mounted here — Swift
 * `.sheet(isPresented: $model.showsDialpad)` — bound to the `call_control_showDialpad` control,
 * which is its `present` trigger.
 */
import { PiPWindow, typeNode, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { CallService, SinkScaling } from '../common/CallService';
// feat_voice_call: svc_audio owns the route with no system call provider to own it.
import { AudioService } from '../common/AudioService';
// feat_video_call: svc_video owns the camera capture and the daemon video sinks.
import { VideoFrameInfo, VideoService } from '../common/VideoService';
import { DisposeBag } from '../common/Observable';
import { describeError } from '../common/ErrorText';
import { LookupNameResponse, LookupNameState } from '../common/NameService';
import {
  CallId, CallState, CallSystemState, CallDirection, ConferenceLayoutMode, ConferenceLifecycle, ConferenceState, ConfId
} from '../model/CallState';
import { ConfigKey } from '../model/ConfigKeyModel';
import {
  MediaItem, MediaLabel, hasNegotiatedVideo as mediaHasNegotiatedVideo, hasVideo as mediaHasVideo,
  isVideoMuted as mediaIsVideoMuted
} from '../model/MediaItem';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ContactModel } from '../model/ContactModel';
import { Profile } from '../model/Profile';
import { filterOutHost } from '../model/CallDetails';
import { jamiHash } from '../common/ProfileStore';
import {
  CallIntent,
  CallStatus,
  CallStatusKind,
  holdSideIncludesLocal,
  holdSideIncludesPeer
} from '../model/CallStatus';
import { ConferenceParticipantInfo } from '../model/ConferenceParticipantInfo';

import { CallAvatarView } from '../components/CallAvatar';
import { AvatarSize } from '../common/JamiConstants';
import {
  CallControlIntent, CallControlsView, ControlAction, ControlActionStyle, ON_VIDEO_GLASS_BLUR,
  ON_VIDEO_GLASS_FILL
} from '../components/CallControls';
import { CallHeaderAvatar, CallHeaderModel, CallHeaderView } from '../components/CallHeader';
import { CallTopActionsView } from '../components/CallTopActions';
import {
  CanvasTileModel, CanvasTileSource, ParticipantCanvas, ParticipantTileUIView
} from '../components/ParticipantCanvas';
import { RendererLayerView } from '../components/RendererLayer';
import { VideoPreviewLayer } from '../components/VideoPreviewLayer';
import {
  ConferenceMenuItem, ConferenceParticipantRow, ConferenceParticipantsView, PendingParticipantRow,
  participantActions
} from '../components/ConferenceParticipants';
import { InCallDialpadSheet } from './InCallDialpadPage';
import { ContactPickerSheet } from './ContactPickerPage';
import { PickerItem } from '../components/ContactRow';

/* ── S5 tokens, the source's own (CallScreenView.swift:75-125) ───────────────────── */
/** Swift `.foregroundColor(.white.opacity(0.9))` on the ringing status line. */
const CALL_STATUS_COLOR: string = '#E6FFFFFF';
/** Swift `preferredStatusBarStyle = .lightContent`: light clock and icons over the dark call. */
const LIGHT_STATUS_BAR_CONTENT: string = '#FFFFFF';
/** The panels (roster, dialpad, picker) that stand in for sheets over the call. */
const SHEET_SCRIM: string = '#66000000';
/** Swift `.presentationDetents([.medium])` on the roster: half the screen. */
const MEDIUM_SHEET: string = '50%';
const SHEET_CORNER_RADIUS: number = 10;
const SHEET_RADIUS: number = 24;
/**
 * A page sheet (Swift `host.present(picker)`, a `.sheet` with no detents) reaches up to just
 * under the status bar: 10 pt clear of it on the iPhone (TC-CALL-189).
 */
const PAGE_SHEET_GAP: number = 10;
const CONFERENCE_AVATAR_SIZE: number = 72;
/** Swift `CallHeaderModel.maximumAvatars = 3`. */
const MAX_HEADER_AVATARS: number = 3;
/** The floating local preview. */
const LOCAL_PREVIEW_WIDTH: number = 108;
const LOCAL_PREVIEW_HEIGHT: number = 144;
/** Swift `CanvasLayout.previewPadding = 16` — the preview's clearance from the canvas edges. */
const PREVIEW_PADDING: number = 16;
/** Swift `previewControlInsets`: the preview travels between the top actions and the control bar. */
const PREVIEW_TOP_WALL: number = 72;
const PREVIEW_BOTTOM_WALL: number = 124;
/** Swift `PreviewDocking`: dock past a third of the width or on a 650 pt/s fling outward. */
const DOCK_DISTANCE_FRACTION: number = 1 / 3;
const DOCK_FLING_VELOCITY: number = 650;
/** Swift `PreviewDocking`: a docked preview comes back after 32 pt inward or a 500 pt/s fling. */
const RESTORE_DISTANCE: number = 32;
const RESTORE_FLING_VELOCITY: number = 500;
const RUBBER_BAND_COEFFICIENT: number = 0.55;
/** Swift `PreviewDockHandleView.Metrics`: 44 x 64 hit area, 28 pt visible, 14 pt corners. */
const DOCK_HANDLE_HIT_WIDTH: number = 44;
const DOCK_HANDLE_HEIGHT: number = 64;
const DOCK_HANDLE_VISIBLE_WIDTH: number = 28;
const DOCK_HANDLE_RADIUS: number = 14;
const DOCK_HANDLE_GLYPH: number = 17;
const PREVIEW_MOVE_MS: number = 300;

/** Swift `PreviewPresentationState` + `PreviewDockSide`. */
enum PreviewDock {
  NONE,
  LEFT,
  RIGHT
}

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'InCallScreenPage';

/** Swift `PendingParticipantRow.progressText`. */
class PendingProgress {
  static text(status: CallStatus): Resource {
    if (status.kind === CallStatusKind.CONNECTING) {
      return $r('app.string.calls_connecting');
    }
    if (status.kind === CallStatusKind.RINGING) {
      return $r('app.string.calls_ringing');
    }
    return $r('app.string.calls_calling');
  }
}

/**
 * The floating window's own surface, reported with its size. The framework calls this without
 * the instance as `this` (T-1385: `this.onReady` was undefined and the TypeError closed Jami), so
 * it reaches the one running session by name.
 */
class PipSurfaceController extends XComponentController {
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    pipSession.surfaceChanged(surfaceId, rect.surfaceWidth, rect.surfaceHeight);
  }
}

/** Below this (px) the PiP window is still its 16x9 placeholder, not its real size. */
const PIP_MIN_SURFACE: number = 64;

/**
 * Swift `CallScreenPresenter.minimizeCallScreen` / `restoreCallScreen` with the model's
 * PiPController: while picture-in-picture runs the call screen is dismissed and Jami stays on
 * the screen under it (T-1385: minimizing the main window sent Jami to the home screen). The
 * overlay is torn down when it closes, so the running PiP lives here, drawn into a typeNode
 * XComponent that no page owns.
 */
class CallPictureInPicture {
  /** The remote sink in the floating window; '' while none runs or starts. */
  private sink: string = '';
  private surface: string = '';
  /** The size the sink was attached at, 'WxH'. */
  private surfaceSize: string = '';
  private controller: PiPWindow.PiPController | null = null;
  /** The tile surface the sink goes back to while the call screen is still up, else null. */
  private tileSurface: string | null = null;
  /** The tile's scaling, given back with its surface; the floating window always crops. */
  private tileScaling: SinkScaling = SinkScaling.FILL;
  /** The host's call-screen dialog: a restore presents the call screen through it again. */
  private dialog: CustomDialogController | null = null;
  /** Swift `onMinimize`: closes the call screen that started PiP, once the window is up. */
  private onStarted: (() => void) | null = null;
  private restoring: boolean = false;
  private unwatch: (() => void) | null = null;

  get isActive(): boolean {
    return this.sink.length > 0;
  }

  start(context: Context, ui: UIContext, sink: string, tileSurface: string | null,
    tileScaling: SinkScaling, dialog: CustomDialogController | null, onStarted: () => void): void {
    if (this.isActive) {
      return;
    }
    this.sink = sink;
    this.tileSurface = tileSurface;
    this.tileScaling = tileScaling;
    ServiceRegistry.shared().callService.setSinkScaling(sink, SinkScaling.FILL);
    this.dialog = dialog;
    this.onStarted = onStarted;
    const surfaceController: PipSurfaceController = new PipSurfaceController();
    const node: typeNode.XComponent = typeNode.createNode(ui, 'XComponent',
      { type: XComponentType.SURFACE, controller: surfaceController } as XComponentOptions);
    // Swift: the presenter dismisses the call when it ends, and the floating window with it.
    const calls: CallService = ServiceRegistry.shared().callService;
    const unwatchCalls: () => void = calls.callsUpdated.subscribe((updated: boolean): void => {
      if (calls.stateMirror.liveCalls.length === 0) {
        this.stop();
      }
    });
    // Swift: AVPictureInPictureController sizes the window to the video. The window takes the
    // sink's aspect as shown, and follows it when the peer turns (T-1592: a fixed 16:9 window
    // cut a portrait peer to a band).
    const video: VideoService = ServiceRegistry.shared().videoService;
    const unwatchSize: () => void = video.shownSizeChanged.subscribe((info: VideoFrameInfo): void => {
      const running: PiPWindow.PiPController | null = this.controller;
      if (running === null || info.sinkId !== this.sink || info.width <= 0 || info.height <= 0) {
        return;
      }
      try {
        running.updateContentSize(info.width, info.height);
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'PiP resize failed: %{public}d', (error as BusinessError).code);
      }
    });
    this.unwatch = (): void => {
      unwatchCalls();
      unwatchSize();
    };
    const shown: VideoFrameInfo | null = video.shownSize(sink);
    PiPWindow.create({
      context: context,
      componentController: surfaceController,
      templateType: PiPWindow.PiPTemplateType.VIDEO_CALL,
      contentWidth: shown === null ? undefined : shown.width,
      contentHeight: shown === null ? undefined : shown.height
    }, node).then((controller: PiPWindow.PiPController): void => {
      if (this.sink !== sink) {
        return;
      }
      this.controller = controller;
      controller.setAutoStartEnabled(false);
      controller.on('stateChange', (state: PiPWindow.PiPState, reason: string): void => {
        this.stateChanged(state);
      });
      controller.startPiP().catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'startPiP failed: %{public}d', error.code);
        this.end();
      });
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'PiP unavailable: %{public}d', error.code);
      this.end();
    });
  }

  /**
   * The floating window's surface has a size: the remote sink draws into it. The window opens at
   * a 16x9 px placeholder and grows a moment later, and the native renderer keeps the size it was
   * attached at, so it attaches at the real size and again on each change (T-1385: frames drawn
   * at the placeholder size after the window grew crashed in sws_scale, SIGSEGV).
   */
  surfaceChanged(surfaceId: string, width: number, height: number): void {
    const size: string = `${width}x${height}`;
    if (!this.isActive || width < PIP_MIN_SURFACE || height < PIP_MIN_SURFACE ||
      (surfaceId === this.surface && size === this.surfaceSize)) {
      return;
    }
    this.surface = surfaceId;
    this.surfaceSize = size;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'PiP surface %{public}s', size);
    ServiceRegistry.shared().videoService.setSinkSurface(this.sink, surfaceId);
  }

  /** The call screen is back, or the call ended: the floating window closes. */
  stop(): void {
    const controller: PiPWindow.PiPController | null = this.controller;
    if (!this.isActive) {
      return;
    }
    if (controller === null) {
      this.end();
    } else if (!this.restoring) {
      controller.stopPiP().catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stopPiP failed: %{public}d', error.code);
      });
    }
  }

  /** The call screen closed: there is no tile to go back to, nor a screen to close. */
  callScreenGone(): void {
    this.tileSurface = null;
    this.onStarted = null;
  }

  private stateChanged(state: PiPWindow.PiPState): void {
    if (state === PiPWindow.PiPState.STARTED) {
      const started: (() => void) | null = this.onStarted;
      this.callScreenGone();
      if (started !== null) {
        started();
      }
    } else if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      // Swift `requestRestore` -> `restoreCallScreen`: the call screen comes back over Jami.
      this.restoring = true;
      const dialog: CustomDialogController | null = this.dialog;
      if (dialog !== null && !InCallScreenOverlay.isMounted()) {
        try {
          dialog.open();
        } catch (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'restoring the call screen failed: %{public}d',
            (error as BusinessError).code);
        }
      }
    } else if (state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR) {
      this.end();
    }
  }

  private end(): void {
    const controller: PiPWindow.PiPController | null = this.controller;
    if (controller !== null) {
      controller.off('stateChange');
    }
    const unwatch: (() => void) | null = this.unwatch;
    if (unwatch !== null) {
      unwatch();
    }
    const sink: string = this.sink;
    const surface: string = this.surface;
    const back: string | null = this.tileSurface;
    const backScaling: SinkScaling = this.tileScaling;
    this.sink = '';
    this.surface = '';
    this.surfaceSize = '';
    this.controller = null;
    this.tileSurface = null;
    this.dialog = null;
    this.onStarted = null;
    this.restoring = false;
    this.unwatch = null;
    if (sink.length > 0 && surface.length > 0) {
      // Back to its tile while the call screen is up, else detached until a call screen shows
      // it again; a call screen that came back has taken the sink already.
      ServiceRegistry.shared().videoService.releaseSinkSurface(sink, surface, back);
    }
    if (sink.length > 0 && back !== null) {
      // PiP never started over the call screen: its tile keeps its own scaling. A call screen
      // shown again applies its own.
      ServiceRegistry.shared().callService.setSinkScaling(sink, backScaling);
    }
  }
}

const pipSession: CallPictureInPicture = new CallPictureInPicture();

@CustomDialog
export struct InCallScreenOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /**
   * screen_contact_picker lives on the host (screen_conversation), so `Add participant` asks the
   * host to raise it. Supplied by ConversationChatPage.
   */
  onAddParticipant?: () => void;

  /** Owned by screen_conversation; the host's @State drives this overlay. */
  @Link isPresented: boolean;
  /** Set once a call has been shown, so its end closes the screen. */
  private hadCall: boolean = false;
  /**
   * Swift `CallScreenPresenter`: ONE call screen owns the call UI. The chat and the Home page
   * each host this overlay; the count tells a host that one is already up (it then follows the
   * new call itself, see callToShow).
   */
  private static mountedCount: number = 0;

  static isMounted(): boolean {
    return InCallScreenOverlay.mountedCount > 0;
  }

  /**
   * The app's status-bar content colour before the first call screen went up; the last one down
   * restores it (a closing screen can overlap the next one opening).
   * ponytail: restores an explicit colour, so a dark-mode switch during a call keeps it.
   */
  private static savedStatusBarContent: string | undefined = undefined;
  private win: window.Window | null = null;

  /** The mounted screen's `closePanels`, for a host's Back (T-1731). */
  private static panelCloser: (() => boolean) | null = null;

  /**
   * A host's `onWillDismiss` on Back: closes the open sheet (dialpad, roster, picker) and
   * returns true, so the call screen stays, as iOS dismisses only the sheet. False: none open.
   */
  static closeOpenPanel(): boolean {
    const closer: (() => boolean) | null = InCallScreenOverlay.panelCloser;
    return closer !== null && closer();
  }
  /** Swift `CallViewModel.callId` - the call the controls act on. */
  private callId: CallId | null = null;
  /** The call the header shows; the duration timer re-reads it every second. */
  private shownCall: CallState | null = null;
  /** The call whose audio route was last activated. */
  private routedCallId: string = '';
  private durationTimer: number = -1;
  /** Registered names resolved for peers without a profile name (Swift `bestName`). */
  private peerNames: Map<string, string> = new Map<string, string>();
  private lookedUp: Set<string> = new Set<string>();
  /** Swift `CallHeaderModel.uniqueURIs(rows)` — one per person, however many devices. */
  private rosterCount: number = 0;

  /* ── bound content ─────────────────────────────────────────────────────────────── */
  /** bindingContract[header] <- CallState.displayName (CallViewModel.header). */
  @State header: CallHeaderModel = new CallHeaderModel();
  /** bindingContract[controls] <- CallState.status (CallControlsLayout.plan.primary). */
  @State controls: ControlAction[] = [];
  /** Swift `plan.supplemental` — [hold, dialpad], SIP accounts only. */
  @State private supplementalControls: ControlAction[] = [];
  /** Swift `CallControlsModel.canHold` / `canResume` — what the hold control does on a tap. */
  private canHold: boolean = false;
  private canResume: boolean = false;
  /** Swift `toggleHold()`'s `conference.isHost` branch — the hosted conference the tap holds. */
  private holdConferenceId: ConfId | null = null;
  /** Swift `plan.pictureInPicture` / `plan.raiseHand` — null when the plan omits them. */
  @State private pictureInPicture: ControlAction | null = null;
  @State private raiseHand: ControlAction | null = null;
  /** bindingContract[participant tiles] <- svc_calls. */
  @State participantTiles: CanvasTileModel[] = [];
  /** Swift `previewId`'s tile — the local preview floating over the grid. */
  @State private preview: CanvasTileModel | null = null;
  /** bindingContract[conference participant list] <- svc_calls. */
  @State conferenceParticipantListTileCanvas: ArrayDataSource<ConferenceParticipantRow> =
    new ArrayDataSource<ConferenceParticipantRow>([]);
  /** Swift `model.pendingRows`. */
  @State private pending: ArrayDataSource<PendingParticipantRow> =
    new ArrayDataSource<PendingParticipantRow>([]);
  @State private hasPending: boolean = false;
  /** Swift `model.participantRows.count` / `model.pendingRows.count` — the roster's titles. */
  @State private participantCount: number = 0;
  @State private pendingCount: number = 0;
  /** Swift `model.canAddParticipant` — the header tap, the top-right control and the roster's. */
  @State private canAddParticipant: boolean = false;
  /** Swift `model.canModerateConference` — the host, or a participant made moderator. */
  @State private canModerateConference: boolean = false;

  /* ── conditionalVariants ───────────────────────────────────────────────────────── */
  /** [incoming]: CallStatus incoming/ringing — the answer controls. */
  @State isIncoming: boolean = false;
  /** [outgoing]: outgoing ringing. */
  @State isOutgoing: boolean = false;
  /** [in_progress]: the call is connected. */
  @State isInProgress: boolean = false;
  /** [audio_only]: the avatar canvas instead of video. */
  @State isAudioOnly: boolean = true;
  /** The local camera is turned off in a video call. */
  @State isVideoMuted: boolean = false;
  /** [video]: negotiated video — the ParticipantCanvas renderers. */
  @State isVideo: boolean = false;
  /** [conference]: conferenceId != nil — the roster and the moderator actions. */
  @State isConference: boolean = false;
  /** [conference_host]: the local device is a moderator. */
  @State isConferenceHost: boolean = false;
  /** [on_hold]: peerHolding / local hold. */
  @State isOnHold: boolean = false;
  /** [recording]: peerIsRecording — the header's RecordingIndicator. */
  @State isRecording: boolean = false;

  /** Swift `model.showsChrome` — the top actions and the control bar fade together. */
  @State private showsChrome: boolean = true;
  /** The front camera's preview is mirrored, the back camera's is not. */
  @State private previewMirrored: boolean = true;
  /** Swift the floating preview's origin, its corner and its dock (ParticipantCanvas). */
  @State private previewX: number = 0;
  @State private previewY: number = 0;
  @State private previewDock: PreviewDock = PreviewDock.NONE;
  private previewTop: boolean = false;
  private previewLeading: boolean = false;
  private dragOriginX: number = 0;
  private dragOriginY: number = 0;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  /** Each tile's own surface, by sink id, so a sink goes back to its tile if PiP fails to start. */
  private tileSurfaces: Map<string, string> = new Map<string, string>();
  /** Swift `videoScalingPolicyOverrides`: a pinch's choice, by sink id. */
  private scalingOverrides: Map<string, SinkScaling> = new Map<string, SinkScaling>();
  /** The scaling last sent to each sink, so a refresh sends only a change. */
  private appliedScaling: Map<string, SinkScaling> = new Map<string, SinkScaling>();
  /** Swift `model.contentHidden`. */
  @State private contentHidden: boolean = false;
  /** Swift `model.showsParticipants` — drives ConferenceParticipantsView. */
  @State private showsParticipants: boolean = false;
  /** Swift `model.showsDialpad` — raises the in-call dialpad sheet (screen_in_call_dialpad). */
  @State private showsDialpad: boolean = false;
  /** The contact picker raised by `Add participant`. */
  @State private showsContactPicker: boolean = false;
  /** The status bar's height: the overlay is drawn under it, and the page sheet stops below it. */
  @State private topInset: number = 0;
  /** True while svc_calls is in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  /**
   * The disclosed daemon gap: every call intent below the UI is jami-daemon work. Rendered as
   * a visible notice, so no call control is ever a silent no-op.
   */
  @State showDaemonNotice: boolean = false;

  /** Swift `let disposeBag = DisposeBag()` — the call-state subscription this screen opens. */
  private bag: DisposeBag = new DisposeBag();

  /**
   * Swift `CallViewModel.init(call:)` — the screen reads the current call out of svc_calls and
   * re-reads it on every `callsUpdated` tick, which is what drives all ten branch selectors.
   */
  aboutToAppear(): void {
    InCallScreenOverlay.mountedCount++;
    InCallScreenOverlay.panelCloser = this.closeOpenPanels;
    // Swift `restoreCallScreen`: the call screen is up again, so the floating window goes.
    this.isPresented = true;
    pipSession.stop();
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.topInset = px2vp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
      this.win = win;
      if (InCallScreenOverlay.savedStatusBarContent === undefined) {
        InCallScreenOverlay.savedStatusBarContent = win.getWindowSystemBarProperties().statusBarContentColor;
      }
      InCallScreenOverlay.setStatusBarContent(win, LIGHT_STATUS_BAR_CONTENT);
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'window unavailable: %{public}d', error.code);
    });
    this.bag.add(ServiceRegistry.shared().nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (response.state === LookupNameState.FOUND && response.name.length > 0) {
          this.peerNames.set(response.address, response.name);
          this.refreshFromCallService();
        }
      }));
    this.refreshFromCallService();
    this.bag.add(ServiceRegistry.shared().audioService.speakerActive.subscribe(
      (active: boolean): void => {
        this.refreshFromCallService();
      }));
    this.bag.add(ServiceRegistry.shared().callService.callsUpdated.subscribe(
      (updated: boolean): void => {
        this.refreshFromCallService();
      }));
    // Swift `durationTimer` - the elapsed time in the status line ticks every second.
    this.durationTimer = setInterval((): void => {
      this.refreshHeader();
    }, 1000);
  }

  aboutToDisappear(): void {
    InCallScreenOverlay.mountedCount = Math.max(0, InCallScreenOverlay.mountedCount - 1);
    if (InCallScreenOverlay.panelCloser === this.closeOpenPanels) {
      InCallScreenOverlay.panelCloser = null;
    }
    clearInterval(this.durationTimer);
    this.bag.dispose();
    pipSession.callScreenGone();
    const saved: string | undefined = InCallScreenOverlay.savedStatusBarContent;
    if (InCallScreenOverlay.mountedCount === 0 && this.win !== null && saved !== undefined) {
      InCallScreenOverlay.savedStatusBarContent = undefined;
      InCallScreenOverlay.setStatusBarContent(this.win, saved);
    }
  }

  private static setStatusBarContent(win: window.Window, color: string): void {
    win.setWindowSystemBarProperties({ statusBarContentColor: color })
      .catch((error: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'status bar colour not set: %{public}d', error.code);
      });
  }

  /** Swift `CallHeaderModel` title plus `CallHeaderModel.statusLine(for:)`. */
  private refreshHeader(): void {
    const call: CallState | null = this.shownCall;
    if (call === null) {
      this.header.title = '';
      this.header.statusLine = '';
      return;
    }
    this.header.statusLine = this.statusLine(call);
    if (this.header.showsRoster) {
      // Swift `CallHeaderModel`: a conference is titled by its head count, never by the call's
      // own peer (for a joined swarm call that peer is the raw `rdv:` URI).
      this.header.title = getContext(this).resourceManager.getStringSync(
        $r('app.string.calls_participants_in_call').id, this.rosterCount.toString());
      this.header.titleIsIdentifier = false;
      return;
    }
    const peer: string = call.peerHash;
    let title: string = call.bestName;
    if (title === peer && this.peerNames.has(peer)) {
      title = this.peerNames.get(peer) as string;
    }
    this.header.title = title;
    this.header.titleIsIdentifier = title === peer;
  }

  private statusLine(call: CallState): string {
    const context: Context = getContext(this);
    switch (call.status.kind) {
      case CallStatusKind.INCOMING:
        return context.resourceManager.getStringSync($r('app.string.global_incoming_call').id);
      case CallStatusKind.CONNECTING:
        return context.resourceManager.getStringSync($r('app.string.calls_connecting').id);
      case CallStatusKind.RINGING:
        return context.resourceManager.getStringSync($r(call.direction === CallDirection.INCOMING
          ? 'app.string.global_incoming_call' : 'app.string.calls_ringing').id);
      case CallStatusKind.HELD:
        return context.resourceManager.getStringSync($r('app.string.accessibility_calls_default_pause_call').id);
      case CallStatusKind.CURRENT:
        {
          const startedAt: Date | null = call.startedAt;
          if (startedAt === null) {
            return '';
          }
          const seconds: number = Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
          const two = (n: number): string => n.toString().padStart(2, '0');
          const hours: number = Math.floor(seconds / 3600);
          const clock: string = two(Math.floor(seconds / 60) % 60) + ':' + two(seconds % 60);
          return hours > 0 ? hours.toString() + ':' + clock : clock;
        }
      default:
        return '';
    }
  }

  /** Swift `CallViewModel`'s published values, all read off svc_calls' own state mirror. */
  private refreshFromCallService(): void {
    this.isLoading = true;
    try {
      const calls: CallService = ServiceRegistry.shared().callService;
      const mirror: CallSystemState = calls.stateMirror;
      // Swift `CallViewModel(call:)` shows the call from the moment it rings, not only once
      // it is connected (`ongoingCalls` is CURRENT/HELD only).
      const ongoing: CallState[] = mirror.liveCalls;
      if (ongoing.length === 0) {
        this.applyNoCall();
        // Swift: the coordinator dismissed the call screen when the call ended. Only once a
        // call has been shown, so the screen opened just before the call registers stays up.
        if (this.hadCall) {
          this.dismiss();
        }
        return;
      }
      this.hadCall = true;
      const call: CallState = this.callToShow(ongoing);
      this.callId = call.id;
      this.applyCall(call, mirror);
      this.errorText = '';
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'call refresh failed: %{public}s', this.errorText);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift: CallKit puts a newly ringing incoming call in front of the call already up (another
   * local account's included); otherwise the screen stays on the call it shows. Always the first
   * live call hid a second account's incoming call behind an outgoing one, so it never rang.
   */
  private callToShow(live: CallState[]): CallState {
    const ringing: CallState | undefined = live.find((call: CallState): boolean =>
      call.direction === CallDirection.INCOMING &&
      (call.status.kind === CallStatusKind.INCOMING || call.status.kind === CallStatusKind.RINGING));
    if (ringing !== undefined) {
      return ringing;
    }
    const shown: CallId | null = this.callId;
    const same: CallState | undefined = shown === null ? undefined
      : live.find((call: CallState): boolean => call.id.equals(shown));
    return same ?? live[0];
  }

  /** No call in svc_calls: every state branch is off and the header carries nothing. */
  private applyNoCall(): void {
    this.isIncoming = false;
    this.isOutgoing = false;
    this.isInProgress = false;
    this.isOnHold = false;
    this.isRecording = false;
    this.isConference = false;
    this.isConferenceHost = false;
    this.isVideo = false;
    this.isAudioOnly = true;
    this.shownCall = null;
    this.participantTiles = [];
    this.conferenceParticipantListTileCanvas.reload([]);
  }

  /** Swift `CallViewModel`'s branch selectors, one per conditionalVariants entry. */
  private applyCall(call: CallState, mirror: CallSystemState): void {
    // [incoming] / [outgoing] / [in_progress] — CallStatusKind plus the call's direction.
    const kind: CallStatusKind = call.status.kind;
    this.isIncoming = kind === CallStatusKind.INCOMING ||
      (kind === CallStatusKind.RINGING && call.direction === CallDirection.INCOMING);
    this.isOutgoing = call.direction === CallDirection.OUTGOING &&
      (kind === CallStatusKind.RINGING || kind === CallStatusKind.CONNECTING);
    this.isInProgress = kind === CallStatusKind.CURRENT;
    // [on_hold] — either side holding.
    const holdSide = call.status.holdSide;
    this.isOnHold = kind === CallStatusKind.HELD || call.peerHolding ||
      (holdSide !== null && (holdSideIncludesLocal(holdSide) || holdSideIncludesPeer(holdSide)));
    // [recording] — Swift `header.isRecording` (peerIsRecording).
    this.isRecording = call.peerIsRecording;
    // [conference] / [conference_host] — conferenceId != nil, and the local moderator flag.
    const conferenceId = call.conferenceId;
    this.isConference = conferenceId !== null;
    const conference: ConferenceState | null = conferenceId === null
      ? null : mirror.conferences.get(conferenceId.raw) ?? null;
    this.isConferenceHost = conference !== null && conference.isHost;
    // [audio_only] / [video] — Swift reads the negotiated media (`effectiveMedia(in:)`), not the
    // placing flag alone: an audio call the camera button upgraded negotiates video and becomes
    // a video call here too.
    const media: MediaItem[] = call.effectiveMedia(conference);
    this.isVideo = !call.isAudioOnly || mediaHasNegotiatedVideo(media);
    this.isAudioOnly = !this.isVideo;
    // Swift `media.isVideoMuted` — no video stream at all counts as muted, so an audio call's
    // camera control is the active (light, slashed) one.
    this.isVideoMuted = mediaIsVideoMuted(media);

    if (this.shownCall === null || this.shownCall.peerHash !== call.peerHash) {
      const registered: string | null = call.registeredName;
      if (call.displayName.length === 0 && (registered === null || registered.length === 0)) {
        ServiceRegistry.shared().nameService.lookupAddress(call.accountId, '', call.peerHash);
      }
    }
    this.shownCall = call;
    this.header.showsRoster = this.isConference;
    this.refreshHeader();
    this.header.isRecording = this.isRecording;

    this.applyParticipants(call, conference);
    this.applyControlPlan(call, conference);
    // feat_video_call: the camera is the video service's, not this screen's — it is asked for
    // a capture only while the call actually negotiated video.
    const video: VideoService = ServiceRegistry.shared().videoService;
    if (this.isVideo) {
      video.startPreviewCapture();
    } else {
      video.stopPreviewCapture();
    }
    // feat_voice_call: with no system call provider, the route is activated here.
    // Once per call: re-running it on every refresh undid the user's speaker choice.
    if (this.routedCallId !== call.id.raw) {
      this.routedCallId = call.id.raw;
      const audio: AudioService = ServiceRegistry.shared().audioService;
      audio.callKitActivated(this.isVideo, call.direction);
    }
  }

  /**
   * Swift `isSipAccount: account?.type == .sip` (CallScreenPresenter) — the call's ACCOUNT, not
   * its URI: libjami reports an incoming SIP peer as `user@host`, and a dialled number has no
   * `sip:` either.
   */
  private isSipAccount(call: CallState): boolean {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(call.accountId);
    return account !== null && account.type === AccountType.SIP;
  }

  /**
   * Swift `CallControlsLayout.plan(_:)` — the visible buttons follow the call's own media,
   * status and conference role. `canToggleMedia` / `canHold` / `canResume` are the source's
   * own guards, so a control is disabled only where the SOURCE disables it.
   */
  private applyControlPlan(call: CallState, conference: ConferenceState | null): void {
    const isSip: boolean = this.isSipAccount(call);
    // Swift `CallControlsModel(call:conference:)`: an attached hosted conference owns the media
    // and its pending re-invite; a host whose own device is detached cannot change media.
    const hosted: ConferenceState | null = call.mediaOwningHostedConference(conference);
    const pendingMediaRequest: MediaItem[] | null =
      hosted === null ? call.pendingMediaRequest : hosted.pendingMediaRequest;
    const canToggleMedia: boolean = call.status.allows(CallIntent.CHANGE_MEDIA)
      && pendingMediaRequest === null
      && !(conference !== null && conference.isHost && !conference.hasAttachedHost);
    const isAudioMuted: boolean = call.effectiveAudioMuted(conference);
    const speakerActive: boolean = ServiceRegistry.shared().audioService.speakerActive.value;
    const primary: ControlAction[] = [
      // Swift `speaker.wave.3.fill` while the speaker is on, `speaker.wave.2.fill` otherwise.
      new ControlAction(CallControlIntent.TOGGLE_AUDIO_OUTPUT,
        speakerActive ? $r('sys.symbol.speaker_wave_3_fill') : $r('sys.symbol.speaker_wave_2_fill'),
        speakerActive ? $r('app.string.accessibility_calls_alter_toggle_speaker')
          : $r('app.string.accessibility_calls_default_toggle_speaker'),
        speakerActive ? ControlActionStyle.ACTIVE : ControlActionStyle.NORMAL),
      new ControlAction(CallControlIntent.TOGGLE_MIC,
        isAudioMuted ? $r('sys.symbol.mic_slash_fill') : $r('sys.symbol.mic_fill'),
        // Swift `isAudioMuted ? L10n.Calls.unmuteAudio : L10n.Calls.muteAudio`.
        isAudioMuted ? $r('app.string.calls_unmute_audio') : $r('app.string.calls_mute_audio'),
        isAudioMuted ? ControlActionStyle.ACTIVE : ControlActionStyle.NORMAL, canToggleMedia),
      new ControlAction(CallControlIntent.TOGGLE_CAMERA,
        this.isVideoMuted ? $r('sys.symbol.video_slasj_fill') : $r('sys.symbol.video_fill'),
        this.isVideoMuted ? $r('app.string.accessibility_calls_default_toggle_video')
          : $r('app.string.accessibility_calls_alter_toggle_video'),
        this.isVideoMuted ? ControlActionStyle.ACTIVE : ControlActionStyle.NORMAL, canToggleMedia),
      new ControlAction(CallControlIntent.FLIP_CAMERA,
        $r('sys.symbol.arrow_triangle_2_circlepath_camera'), $r('app.string.accessibility_calls_default_switch_camera'),
        // Swift `isEnabled: model.canToggleMedia && model.canSwitchCamera`, where
        // `canSwitchCamera = media.hasVideo`: on while the camera sends, also in an upgraded call.
        ControlActionStyle.NORMAL, canToggleMedia && mediaHasVideo(call.effectiveMedia(conference))),
      new ControlAction(CallControlIntent.HANG_UP,
        $r('sys.symbol.phone_down_fill'), $r('app.string.accessibility_calls_default_end_call'),
        ControlActionStyle.DESTRUCTIVE)
    ];
    this.controls = primary;
    // Swift `if model.showsDialpad { supplemental = [hold, dialpad] } else { [] }`.
    if (isSip) {
      // Swift `CallControlsModel.init`: the host of a SIP conference holds the conference by its
      // lifecycle; otherwise `canHoldCall = isSipAccount && call.conferenceId == nil`. The icon
      // and label of `holdAction(_:)` follow `canResume` (a LOCAL hold), style normal.
      const confId: ConfId | null = call.conferenceId;
      if (conference !== null && conference.isHost && confId !== null && conference.id.equals(confId)) {
        this.canHold = conference.lifecycle === ConferenceLifecycle.ACTIVE_ATTACHED;
        this.canResume = conference.lifecycle === ConferenceLifecycle.ACTIVE_DETACHED ||
          conference.lifecycle === ConferenceLifecycle.HOLD;
      } else {
        this.canHold = confId === null && call.status.allows(CallIntent.HOLD);
        this.canResume = confId === null && call.status.allows(CallIntent.RESUME);
      }
      // Swift `toggleHold()`: a hosted conference is held as a whole.
      this.holdConferenceId = conference !== null && conference.isHost ? conference.id : null;
      this.supplementalControls = [
        new ControlAction(CallControlIntent.TOGGLE_HOLD,
          this.canResume ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause_fill'),
          this.canResume ? $r('app.string.accessibility_calls_alter_pause_call')
            : $r('app.string.accessibility_calls_default_pause_call'),
          ControlActionStyle.NORMAL, this.canHold || this.canResume),
        new ControlAction(CallControlIntent.SHOW_DIALPAD,
          $r('sys.symbol.circle_grid_2x2'), $r('app.string.accessibility_calls_default_show_dialpad'))
      ];
    } else {
      this.canHold = false;
      this.canResume = false;
      this.holdConferenceId = null;
      this.supplementalControls = [];
    }
    // Swift `plan.pictureInPicture` = `canStartPictureInPicture`: a remote video to show
    // (PiPSourceSelector) and `pip.isSupported`; `plan.raiseHand` — conferences only.
    this.pictureInPicture = this.pipSink().length === 0 || !InCallScreenOverlay.pipSupported() ?
      null :
      new ControlAction(
        CallControlIntent.START_PICTURE_IN_PICTURE,
        // Swift `pip.enter`: a frame with an arrow into a small window at its bottom right. On the device
        // smal_window_playback draws that way (the SDK font's outline is mirrored; do not flip it).
        $r('sys.symbol.smal_window_playback'), $r('app.string.calls_start_picture_in_picture'));
    // Swift `raiseHandAction(isRaised:)` — the active disc while the local hand is up.
    const me: ConferenceParticipantInfo | undefined =
      conference === null ? undefined : this.localParticipant(call, conference);
    const isHandRaised: boolean = me !== undefined && me.isHandRaised;
    this.raiseHand = (conference === null || isSip) ? null : new ControlAction(
      CallControlIntent.TOGGLE_RAISE_HAND,
      $r('sys.symbol.hand_raised_fingers_spread'),
      isHandRaised ? $r('app.string.accessibility_calls_alter_raise_hand')
        : $r('app.string.accessibility_calls_default_raise_hand'),
      isHandRaised ? ControlActionStyle.ACTIVE : ControlActionStyle.NORMAL);
  }

  /**
   * Swift `model.rows` / `model.tiles` — the conference roster and the tile canvas.
   *
   * The tile half is `CallTilePlanner.conferenceTiles` + `CallTileComposer.model(from:)`: each
   * participant becomes a plan whose `source` is `.localCamera` for the local device and
   * `.remoteStream(sinkId)` for everyone else, and the composer reads that to pick the frame
   * source and the layer transform. Both are carried on the tile so ParticipantTileUIView can
   * branch the same way the source does.
   */
  private applyParticipants(call: CallState, conference: ConferenceState | null): void {
    let rows: ConferenceParticipantRow[] = [];
    const tiles: CanvasTileModel[] = [];
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(call.accountId);
    const localJamiId: string = account === null ? '' : account.jamiId;
    const localDeviceId: string = account === null || account.details === null ? ''
      : account.details.getValue(ConfigKey.ACCOUNT_DEVICE_ID);
    let isLocalModerator: boolean = false;
    if (conference !== null) {
      // Swift `CallTilePlanner.conferenceTiles(localJamiId:localDeviceId:isHostedLocally:)`.
      const isHostedLocally: boolean = conference.isHost;
      // Swift `videoService.localLayerTransform` — the front camera's mirror, applied to the
      // local tile alone.
      const mirrored: boolean =
        ServiceRegistry.shared().videoService.localLayerTransform.mirrored;
      // Swift `ConferenceParticipants.rows(from:conference:...)`: the local device's own row,
      // its menu, and every row's menu by the local role.
      const localInfo: ConferenceParticipantInfo | undefined = conference.participants.find(
        (p: ConferenceParticipantInfo) => p.isLocalDevice(localJamiId, localDeviceId, isHostedLocally));
      isLocalModerator = localInfo !== undefined && localInfo.isModerator;
      for (const participant of conference.participants) {
        const isLocalRow: boolean = localInfo !== undefined && participant.id === localInfo.id;
        const row: ConferenceParticipantRow = new ConferenceParticipantRow();
        row.id = participant.id;
        row.uri = participant.resolvedUri(localJamiId, call.peerUri, isHostedLocally);
        // Swift `participant.bestName`: the contact's registered name, else the id; the host
        // reports itself with an empty uri.
        row.displayName = this.participantName(participant.uri, localJamiId, call);
        row.avatarName = this.participantBareName(participant.uri, localJamiId, call);
        row.avatar = this.photo(row.uri, call);
        row.isLocal = isLocalRow;
        row.isModerator = participant.isModerator;
        row.isAudioMuted = participant.isAudioLocallyMuted || participant.isAudioModeratorMuted;
        row.isAudioModeratorMuted = participant.isAudioModeratorMuted;
        row.isVideoMuted = participant.isVideoMuted;
        row.isHandRaised = participant.isHandRaised;
        row.isRecording = participant.isRecording;
        row.isSpeaking = participant.hasVoiceActivity;
        row.actions = participantActions(participant, isLocalRow, conference, localInfo);
        rows.push(row);

        const tile: CanvasTileModel = new CanvasTileModel();
        tile.id = participant.sinkId.raw;
        tile.participant = participant;
        tile.displayName = row.displayName;
        tile.avatarName = row.avatarName;
        // Swift `tile.bindAvatar(model.avatarProvider)` — the participant's photo, not only the
        // initial (AvatarSwiftUIView turns the vCard base64 into a data URI).
        tile.avatar = row.avatar;
        tile.isAvatarResolved = true;
        // Swift `CallTilePlan.source` — the local device's own tile is the camera, never a sink.
        const isLocal: boolean =
          participant.isLocalDevice(localJamiId, '', isHostedLocally);
        tile.kind = isLocal ? CanvasTileSource.LOCAL_CAMERA : CanvasTileSource.REMOTE_STREAM;
        tile.isMirrored = isLocal && mirrored;
        // Swift `ParticipantTileState(showsVideo:showsName:isSpeaking:)` — the composer sets
        // exactly these three. Left unset, every tile rendered the avatar with no name plate,
        // whatever the call was doing.
        tile.tileState.showsVideo = !participant.isVideoMuted;
        tile.tileState.showsName = true;
        tile.tileState.isSpeaking = participant.hasVoiceActivity;
        tiles.push(tile);
      }
      rows = rows.filter((row: ConferenceParticipantRow) => row.isLocal)
        .concat(rows.filter((row: ConferenceParticipantRow) => !row.isLocal));
    } else {
      // Swift `CallTilePlanner` one-to-one: a single peer tile, its avatar while there is no video.
      const tile: CanvasTileModel = new CanvasTileModel();
      tile.id = call.id.raw;
      tile.displayName = this.header.title;
      tile.avatar = this.photo(call.peerHash, call);
      tile.isAvatarResolved = true;
      // The peer's video only once the call is up; before that, their avatar. Swift
      // `showsVideo: call.hasNegotiatedVideo && call.isOngoing`.
      tile.tileState.showsVideo = this.isVideo && this.isInProgress;
      tiles.push(tile);
    }
    // Swift `rebuildRows()`: a call with no conference infos yet (one-to-one, or a conference
    // before its first infos) is still the two people talking — `rows(from: call)`.
    if (rows.length === 0 && call.status.isOngoing) {
      rows = this.callRows(call, localJamiId);
    }
    this.conferenceParticipantListTileCanvas.reload(rows);
    this.participantCount = rows.length;
    this.applyPending(call, localJamiId);
    this.participantTiles = tiles;
    this.applyVideoScalingPolicies();
    // Swift `canModerateConference` / `rebuildControlsAndCapabilities()`.
    this.canModerateConference = conference !== null && (conference.isHost || isLocalModerator);
    this.canAddParticipant = call.status.isOngoing && !this.isSipAccount(call)
      && (conference === null || this.canModerateConference);
    if (conference !== null) {
      this.applyRosterHeader(call, conference);
    } else if (this.header.avatars.length > 0) {
      this.header.avatars = [];
    }
  }

  /** Swift `ConferenceParticipants.rows(from call:localJamiId:)` — you, then the peer; no menus. */
  private callRows(call: CallState, localJamiId: string): ConferenceParticipantRow[] {
    const local: ConferenceParticipantRow = new ConferenceParticipantRow();
    local.id = ConferenceParticipantInfo.id(localJamiId, '');
    local.uri = localJamiId;
    local.isLocal = true;
    local.displayName = this.participantName(localJamiId, localJamiId, call);
    local.avatarName = this.participantBareName(localJamiId, localJamiId, call);
    local.avatar = this.photo(localJamiId, call);
    if (call.peerUri.length === 0) {
      return [local];
    }
    const peer: ConferenceParticipantRow = new ConferenceParticipantRow();
    peer.id = ConferenceParticipantInfo.id(call.peerUri, '');
    peer.uri = call.peerUri;
    // The name and face are the peer's id without its scheme (`jami:`/`sip:`) or host.
    peer.displayName = this.participantName(call.peerHash, localJamiId, call);
    peer.avatar = this.photo(call.peerHash, call);
    return [local, peer];
  }

  /** Swift `ConferenceParticipants.pendingRows(from: call.pendingInvites)`. */
  private applyPending(call: CallState, localJamiId: string): void {
    const context: Context = getContext(this);
    const rows: PendingParticipantRow[] = call.pendingInvites.map((invite): PendingParticipantRow => {
      const row: PendingParticipantRow = new PendingParticipantRow();
      row.id = invite.callId.raw;
      row.callId = invite.callId.raw;
      row.uri = invite.peerUri;
      row.displayName = this.participantName(invite.peerUri, localJamiId, call);
      row.avatar = this.photo(invite.peerUri, call);
      row.progressText = context.resourceManager.getStringSync(PendingProgress.text(invite.status).id);
      return row;
    });
    this.pending.reload(rows);
    this.pendingCount = rows.length;
    this.hasPending = rows.length > 0;
  }

  /** The participant's photo <- svc_profiles (the account's own for the local device). */
  private photo(uri: string, call: CallState): string {
    const id: string = filterOutHost(uri);
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(call.accountId);
    const profile: Profile = account !== null && id === account.jamiId
      ? ServiceRegistry.shared().profileService.getAccountProfile(call.accountId).value
      : ServiceRegistry.shared().profileService.getProfile(id, call.accountId).value;
    return profile.photo === null ? '' : profile.photo;
  }

  /**
   * Swift `CallHeaderModel(call:isConference:rows:...)`: the head count, and the faces of up to
   * three other participants, one per person.
   */
  private applyRosterHeader(call: CallState, conference: ConferenceState): void {
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(call.accountId);
    const localJamiId: string = account === null ? '' : account.jamiId;
    const uris: string[] = [];
    for (const participant of conference.participants) {
      const uri: string = filterOutHost(
        participant.resolvedUri(localJamiId, call.peerUri, conference.isHost));
      if (!uris.includes(uri)) {
        uris.push(uri);
      }
    }
    // Swift: until the first infos land the conference is still the two people talking.
    this.rosterCount = conference.participants.length > 0 ? uris.length : 2;
    this.header.avatars = uris.filter((uri: string): boolean => uri !== localJamiId)
      .slice(0, MAX_HEADER_AVATARS)
      .map((uri: string): CallHeaderAvatar => {
        const avatar: CallHeaderAvatar = new CallHeaderAvatar();
        avatar.uri = uri;
        avatar.name = this.participantName(uri, localJamiId, call);
        const photo: string | null =
          ServiceRegistry.shared().profileService.getProfile(uri, call.accountId).value.photo;
        avatar.avatar = photo === null ? '' : photo;
        return avatar;
      });
    this.refreshHeader();
  }

  /** Swift: CallTopActionsView's close / CallViewModel.hangUp — returns to the conversation. */
  private dismiss(): void {
    this.isPresented = false;
    ServiceRegistry.shared().videoService.stopPreviewCapture();
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `model.perform(_:)` — one intent per control. Every one of them is daemon work except
   * hang up (which also closes this overlay) and the dialpad (a local sheet).
   */
  private perform(intent: CallControlIntent): void {
    const calls: CallService = ServiceRegistry.shared().callService;
    const id: CallId | null = this.callId;
    // Swift `CallViewModel.perform(_:)`.
    if (intent === CallControlIntent.HANG_UP) {
      const confId: ConfId | null = this.shownCall === null ? null : this.shownCall.conferenceId;
      if (confId !== null && this.isConferenceHost) {
        // The host ends the whole conference, as on iOS.
        calls.hangUpConference(confId);
      } else if (id !== null) {
        calls.hangUp(id);
      }
      this.dismiss();
      return;
    }
    if (intent === CallControlIntent.TOGGLE_MIC && id !== null) {
      calls.toggleMute(id, MediaLabel.DEFAULT_AUDIO);
      return;
    }
    if (intent === CallControlIntent.TOGGLE_CAMERA && id !== null) {
      calls.toggleMute(id, MediaLabel.DEFAULT_VIDEO);
      return;
    }
    if (intent === CallControlIntent.TOGGLE_AUDIO_OUTPUT) {
      ServiceRegistry.shared().audioService.toggleSpeaker();
      return;
    }
    if (intent === CallControlIntent.TOGGLE_HOLD && id !== null) {
      // Swift `toggleHold()`: `guard canHold || canResume`, then `hold = canHold`, sent to the
      // hosted conference when there is one, else to the call.
      const confId: ConfId | null = this.holdConferenceId;
      if (!this.canHold && !this.canResume) {
        return;
      }
      if (confId !== null) {
        calls.holdConference(confId, this.canHold);
      } else {
        calls.hold(id, this.canHold);
      }
      return;
    }
    if (intent === CallControlIntent.FLIP_CAMERA) {
      const video: VideoService = ServiceRegistry.shared().videoService;
      video.switchCamera();
      this.previewMirrored = video.localLayerTransform.mirrored;
      // Swift `switchCamera()` then `rebuildTiles()`: a conference's own camera tile takes the
      // new lens's mirror too; it was set only when the roster changed (T-1591).
      this.participantTiles = this.participantTiles.map((tile: CanvasTileModel): CanvasTileModel => {
        tile.isMirrored = tile.kind === CanvasTileSource.LOCAL_CAMERA && this.previewMirrored;
        return tile;
      });
      return;
    }
    if (intent === CallControlIntent.TOGGLE_RAISE_HAND) {
      this.toggleOwnHand();
      return;
    }
    if (intent === CallControlIntent.SHOW_DIALPAD) {
      this.openDialpad();
      return;
    }
    if (intent === CallControlIntent.START_PICTURE_IN_PICTURE) {
      this.startPictureInPicture();
      return;
    }
    // Every other intent (mic, camera, output, hold, raise hand) is a daemon write, so the
    // control keeps its place and the gap is reported and shown.
    this.reportGap('call.' + intent);
  }

  /** One place turns a daemon-backed intent into the screen's visible notice. */
  private reportGap(feature: string): void {
    ServiceRegistry.shared().daemonService.reportUnavailable(feature);
    this.showDaemonNotice = true;
  }

  /** Swift `model.addParticipantTapped` -> ContactPicker(.forCall), presented by the host. */
  private addParticipant(): void {
    if (!this.canAddParticipant) {
      return;
    }
    // Swift `addParticipantTapped`: the picker opens over the call, which stays on screen.
    this.showsParticipants = false;
    this.showsContactPicker = true;
  }

  private closePanels(): void {
    this.showsParticipants = false;
    this.showsDialpad = false;
    this.showsContactPicker = false;
  }

  /** `closePanels` when a sheet is open; false when none is. */
  private closeOpenPanels: () => boolean = (): boolean => {
    if (!this.showsParticipants && !this.showsDialpad && !this.showsContactPicker) {
      return false;
    }
    this.closePanels();
    return true;
  };

  /** Swift `contactSelectedCB` for the call: the picked contact joins the call on screen. */
  private addPickedParticipant(item: PickerItem): void {
    this.showsContactPicker = false;
    const call: CallState | null = this.shownCall;
    if (call === null) {
      return;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(call.accountId);
    if (account === null) {
      return;
    }
    const deviceId: string = account.details === null ? ''
      : account.details.getValue(ConfigKey.ACCOUNT_DEVICE_ID);
    ServiceRegistry.shared().callService.addParticipant(item.id, call.id, account.jamiId, deviceId);
  }

  /** Swift: CallControlsView's dialpad action — `model.showsDialpad = true` (edge: present). */
  private openDialpad(): void {
    this.showsDialpad = true;
  }

  /** Swift: CallHeaderView -> `model.showsParticipants = true`. */
  private showParticipants(): void {
    this.showsParticipants = true;
  }

  /** Swift `model.perform(_:on:)` — a moderator action on one participant (daemon work). */
  private performOnParticipant(item: ConferenceMenuItem, participantId: string): void {
    const calls: CallService = ServiceRegistry.shared().callService;
    const call: CallState | null = this.shownCall;
    const confId: ConfId | null = call === null ? null : call.conferenceId;
    const conference: ConferenceState | null = confId === null ? null
      : calls.stateMirror.conferences.get(confId.raw) ?? null;
    if (call === null || conference === null) {
      return;
    }
    const info: ConferenceParticipantInfo | undefined =
      conference.participants.find((p: ConferenceParticipantInfo) => p.id === participantId);
    if (info === undefined) {
      return;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(call.accountId);
    const localJamiId: string = account === null ? '' : account.jamiId;
    const localDeviceId: string = account === null || account.details === null ? ''
      : account.details.getValue(ConfigKey.ACCOUNT_DEVICE_ID);
    const target: string = info.resolvedUri(localJamiId, call.peerUri, conference.isHost);
    // Swift `CallViewModel.perform(_:on:)`.
    switch (item) {
      case ConferenceMenuItem.MAXIMIZE:
        calls.setActiveParticipant(target, conference.id);
        calls.setLayout(conference.layout === ConferenceLayoutMode.GRID
          ? ConferenceLayoutMode.ONE_WITH_SMALL : ConferenceLayoutMode.ONE, conference.id);
        break;
      case ConferenceMenuItem.MINIMIZE:
        calls.setLayout(conference.layout === ConferenceLayoutMode.ONE
          ? ConferenceLayoutMode.ONE_WITH_SMALL : ConferenceLayoutMode.GRID, conference.id);
        break;
      case ConferenceMenuItem.MUTE_AUDIO:
        calls.muteStream(target, conference.id, info.device, info.sinkId.raw, !info.isAudioModeratorMuted);
        break;
      case ConferenceMenuItem.SET_MODERATOR:
        calls.setModerator(target, conference.id, !info.isModerator);
        break;
      case ConferenceMenuItem.END_CALL:
        calls.hangUpParticipant(target, conference.id, info.device);
        break;
      default:
        {
          const isLocal: boolean = info.isLocalDevice(localJamiId, localDeviceId, conference.isHost);
          calls.raiseHand(isLocal ? '' : target, conference.id, isLocal ? '' : info.device,
            item === ConferenceMenuItem.RAISE_HAND);
          break;
        }
    }
  }

  /**
   * Swift `ParticipantRowView.displayName` over `CallParticipantAvatars`: the profile alias (the
   * account's own for the local device), else the registered name, else the id, the local one
   * suffixed "(You)". libjami reports peers as `<id>@ring.dht`, which matched no contact and no
   * name lookup, so every tile showed a raw id.
   */
  private participantName(uri: string, localJamiId: string, call: CallState): string {
    const id: string = uri.length === 0 ? localJamiId : jamiHash(filterOutHost(uri));
    const name: string = this.participantBareName(uri, localJamiId, call);
    if (id !== localJamiId) {
      return name;
    }
    const you: string = getContext(this).resourceManager.getStringSync($r('app.string.conversation_yourself').id);
    return name + ' (' + you + ')';
  }

  /** The name without the local '(You)': Swift's avatar takes `resolvedDisplayText`, not the label. */
  private participantBareName(uri: string, localJamiId: string, call: CallState): string {
    // jamiHash also drops the 'jami:'/'ring:' scheme a pending invite carries (Swift bestName).
    const id: string = uri.length === 0 ? localJamiId : jamiHash(filterOutHost(uri));
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const isLocal: boolean = id === localJamiId;
    const profile: Profile = isLocal ? registry.profileService.getAccountProfile(call.accountId).value
      : registry.profileService.getProfile(id, call.accountId).value;
    let name: string = profile.alias === null ? '' : profile.alias;
    if (name.length === 0) {
      name = isLocal ? this.localRegisteredName(call.accountId) : this.peerName(id, call);
    }
    return name.length > 0 ? name : id;
  }

  private localRegisteredName(accountId: string): string {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(accountId);
    return account === null ? '' : account.registeredName;
  }

  /** A peer's registered name, else its id; an unknown id is looked up once. */
  private peerName(id: string, call: CallState): string {
    if (id === call.peerHash && call.bestName !== call.peerHash) {
      return call.bestName;
    }
    const contact: ContactModel | null = ServiceRegistry.shared().contactsService.contact(id);
    const known: string | null = contact === null ? null : contact.userName;
    if (known !== null && known.length > 0) {
      return known;
    }
    const resolved: string | undefined = this.peerNames.get(id);
    if (resolved !== undefined) {
      return resolved;
    }
    if (!this.lookedUp.has(id)) {
      // The answer lands in peerNames and redraws the roster.
      this.lookedUp.add(id);
      ServiceRegistry.shared().nameService.lookupAddress(call.accountId, '', id);
    }
    return id;
  }

  /** Swift `model.toggleRaiseHand()` — the local device's own hand, an empty uri/device. */
  private toggleOwnHand(): void {
    const call: CallState | null = this.shownCall;
    const confId: ConfId | null = call === null ? null : call.conferenceId;
    const calls: CallService = ServiceRegistry.shared().callService;
    const conference: ConferenceState | null = confId === null ? null
      : calls.stateMirror.conferences.get(confId.raw) ?? null;
    if (call === null || conference === null) {
      return;
    }
    const me: ConferenceParticipantInfo | undefined = this.localParticipant(call, conference);
    calls.raiseHand('', conference.id, '', me === undefined ? true : !me.isHandRaised);
  }

  /** The local device's own row in the conference infos. */
  private localParticipant(call: CallState, conference: ConferenceState): ConferenceParticipantInfo | undefined {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(call.accountId);
    const localJamiId: string = account === null ? '' : account.jamiId;
    const localDeviceId: string = account === null || account.details === null ? ''
      : account.details.getValue(ConfigKey.ACCOUNT_DEVICE_ID);
    return conference.participants.find(
      (p: ConferenceParticipantInfo) => p.isLocalDevice(localJamiId, localDeviceId, conference.isHost));
  }

  /** Swift `model.cancelInvite(callId)`. */
  private cancelInvite(callId: string): void {
    ServiceRegistry.shared().callService.hangUp(new CallId(callId));
  }

  /**
   * Swift `onTileLongPressed(participantId)` — the per-participant moderator menu. Every entry
   * of that menu is daemon work, so the control keeps its place and reports the ceiling.
   */
  private tileLongPressed(participantId: string): void {
    // The roster carries each participant's moderator menu.
    if (this.isConference) {
      this.showsParticipants = true;
    }
  }

  /** Swift `model.showGridLayout()` — `callService.setLayout(.grid, in: confId)`; the roster stays. */
  private showGridLayout(): void {
    const confId: ConfId | null = this.shownCall === null ? null : this.shownCall.conferenceId;
    if (confId !== null) {
      ServiceRegistry.shared().callService.setLayout(ConferenceLayoutMode.GRID, confId);
    }
  }

  /* ── picture in picture (Swift PiPController / PiPSourceSelector) ─────────────────── */
  /** Swift `pip.isSupported`. */
  private static pipSupported(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (error) {
      return false;
    }
  }

  /** Swift `PiPSourceSelector.select`: the first remote participant whose video is on. */
  private pipSink(): string {
    const remote: CanvasTileModel | undefined = this.participantTiles.find((tile: CanvasTileModel): boolean =>
      tile.kind === CanvasTileSource.REMOTE_STREAM && tile.tileState.showsVideo && tile.id.length > 0);
    return remote === undefined ? '' : remote.id;
  }

  /**
   * Swift `minimizeToPictureInPicture()`: `pip.start()`, then `onMinimize` dismisses the call
   * screen and Jami stays on the screen under it, the call in the floating window. Restoring
   * from the window presents the call screen again; closing it leaves the call running.
   */
  private startPictureInPicture(): void {
    const sink: string = this.pipSink();
    if (sink.length === 0) {
      return;
    }
    const tileSurface: string | undefined = this.tileSurfaces.get(sink);
    pipSession.start(getContext(this), this.getUIContext(), sink,
      tileSurface === undefined ? null : tileSurface, this.appliedScaling.get(sink) ?? SinkScaling.FILL,
      this.controller ?? null, (): void => {
        this.closeForPictureInPicture();
      });
  }

  /**
   * Swift `ParticipantCanvas.applyVideoScalingPolicies`: the primary tile (the lone remote one,
   * Swift `CanvasLayout` grid with one participant) scales automatically, the others crop; a
   * pinch overrides either.
   */
  private applyVideoScalingPolicies(): void {
    const remote: CanvasTileModel[] = this.participantTiles.filter((tile: CanvasTileModel): boolean =>
      tile.kind === CanvasTileSource.REMOTE_STREAM && tile.id.length > 0);
    const primary: string = remote.length === 1 ? remote[0].id : '';
    for (const tile of remote) {
      const policy: SinkScaling = this.scalingOverrides.get(tile.id) ??
        (tile.id === primary ? SinkScaling.AUTOMATIC : SinkScaling.FILL);
      if (this.appliedScaling.get(tile.id) !== policy) {
        this.appliedScaling.set(tile.id, policy);
        ServiceRegistry.shared().callService.setSinkScaling(tile.id, policy);
      }
    }
  }

  /** Swift `minimizeCallScreen`: the call screen goes, the call (and the camera) carry on. */
  private closeForPictureInPicture(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /* ── the floating preview (ParticipantCanvas preview pan / PreviewDocking) ───────── */
  private travelMinX(): number {
    return PREVIEW_PADDING;
  }

  private travelMaxX(): number {
    return Math.max(PREVIEW_PADDING, this.canvasWidth - LOCAL_PREVIEW_WIDTH - PREVIEW_PADDING);
  }

  private travelMinY(): number {
    return this.topInset + PREVIEW_PADDING + PREVIEW_TOP_WALL;
  }

  private travelMaxY(): number {
    return Math.max(this.travelMinY(),
      this.canvasHeight - LOCAL_PREVIEW_HEIGHT - PREVIEW_PADDING - PREVIEW_BOTTOM_WALL);
  }

  /** Swift `PreviewDocking.rubberBanded(_:dimension:)`. */
  private static rubberBanded(distance: number, dimension: number): number {
    if (distance <= 0 || dimension <= 0) {
      return 0;
    }
    return (1 - 1 / (distance * RUBBER_BAND_COEFFICIENT / dimension + 1)) * dimension;
  }

  /** Swift `dockedPreviewOrigin(for:tile:)` — just past the side edge. */
  private dockedX(dock: PreviewDock): number {
    return dock === PreviewDock.LEFT ? -LOCAL_PREVIEW_WIDTH - 1 : this.canvasWidth + 1;
  }

  /** Swift `previewRestOrigin()` / `layoutDockedPreview()` — where the preview rests now. */
  private settlePreview(animated: boolean): void {
    if (this.canvasWidth <= 0) {
      return;
    }
    const x: number = this.previewDock !== PreviewDock.NONE ? this.dockedX(this.previewDock)
      : (this.previewLeading ? this.travelMinX() : this.travelMaxX());
    const y: number = this.previewTop ? this.travelMinY() : this.travelMaxY();
    if (!animated) {
      this.previewX = x;
      this.previewY = y;
      return;
    }
    animateTo({ duration: PREVIEW_MOVE_MS, curve: Curve.Friction }, () => {
      this.previewX = x;
      this.previewY = y;
    });
  }

  private previewDragStarted(): void {
    this.dragOriginX = this.previewX;
    this.dragOriginY = this.previewY;
  }

  /** Swift `dockAwarePreviewOrigin(for:)`: Y clamped, X rubber-banded past a side edge. */
  private previewDragged(offsetX: number, offsetY: number): void {
    const draggedX: number = this.dragOriginX + offsetX;
    const draggedY: number = this.dragOriginY + offsetY;
    this.previewY = Math.min(Math.max(draggedY, this.travelMinY()), this.travelMaxY());
    if (draggedX < this.travelMinX()) {
      this.previewX = this.travelMinX() -
        InCallScreenOverlay.rubberBanded(this.travelMinX() - draggedX, this.canvasWidth);
    } else if (draggedX > this.travelMaxX()) {
      this.previewX = this.travelMaxX() +
        InCallScreenOverlay.rubberBanded(draggedX - this.travelMaxX(), this.canvasWidth);
    } else {
      this.previewX = draggedX;
    }
  }

  /**
   * Swift `previewPanned` `.ended`: past a third of its width (or flung) beyond a side edge the
   * preview docks there; otherwise it settles in the corner nearest to where it was let go.
   */
  private previewReleased(offsetX: number, velocityX: number): void {
    const draggedX: number = this.dragOriginX + offsetX;
    const leftOvershoot: number = this.travelMinX() - draggedX;
    const rightOvershoot: number = draggedX - this.travelMaxX();
    const dockLimit: number = LOCAL_PREVIEW_WIDTH * DOCK_DISTANCE_FRACTION;
    this.previewTop = this.previewY + LOCAL_PREVIEW_HEIGHT / 2 < this.canvasHeight / 2;
    if (leftOvershoot > 0 && (leftOvershoot >= dockLimit || -velocityX >= DOCK_FLING_VELOCITY)) {
      this.previewDock = PreviewDock.LEFT;
      this.previewLeading = true;
    } else if (rightOvershoot > 0 && (rightOvershoot >= dockLimit || velocityX >= DOCK_FLING_VELOCITY)) {
      this.previewDock = PreviewDock.RIGHT;
      this.previewLeading = false;
    } else {
      this.previewLeading = this.previewX + LOCAL_PREVIEW_WIDTH / 2 < this.canvasWidth / 2;
    }
    this.settlePreview(true);
  }

  /** Swift `restorePreview()` — the docked preview returns to its corner on that side. */
  private restorePreview(): void {
    this.previewDock = PreviewDock.NONE;
    this.settlePreview(true);
  }

  /** Swift `previewDockHandlePanned` `.changed`: the preview slides in with the finger. */
  private dockHandleDragged(offsetX: number): void {
    const dock: PreviewDock = this.previewDock;
    const inward: number = Math.min(Math.max(0, dock === PreviewDock.LEFT ? offsetX : -offsetX),
      LOCAL_PREVIEW_WIDTH + PREVIEW_PADDING);
    this.previewX = this.dockedX(dock) + (dock === PreviewDock.LEFT ? inward : -inward);
  }

  /** Swift `previewDockHandlePanned` `.ended`: 32 pt or a fling inward restores, else re-docks. */
  private dockHandleReleased(offsetX: number, velocityX: number): void {
    const left: boolean = this.previewDock === PreviewDock.LEFT;
    const inward: number = left ? offsetX : -offsetX;
    const inwardVelocity: number = left ? velocityX : -velocityX;
    if (inward >= RESTORE_DISTANCE || inwardVelocity >= RESTORE_FLING_VELOCITY) {
      this.restorePreview();
    } else {
      this.settlePreview(true);
    }
  }

  /**
   * Swift `PreviewDockHandleView`: a 28 pt glass tab on the docked edge, at the preview's
   * height, its chevron pointing back in; tap or drag it inward to bring the preview back.
   */
  @Builder
  private previewDockHandle() {
    Stack() {
      SymbolGlyph(
        this.previewDock === PreviewDock.LEFT ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left')
      )
        .fontSize(DOCK_HANDLE_GLYPH)
        .fontWeight(FontWeight.Medium)
        .fontColor([Color.White])
    }
    .width(DOCK_HANDLE_VISIBLE_WIDTH)
    .height(DOCK_HANDLE_HEIGHT)
    .backgroundColor(ON_VIDEO_GLASS_FILL)
    .backdropBlur(ON_VIDEO_GLASS_BLUR)
    .borderRadius(this.previewDock === PreviewDock.LEFT
      ? { topRight: DOCK_HANDLE_RADIUS, bottomRight: DOCK_HANDLE_RADIUS }
      : { topLeft: DOCK_HANDLE_RADIUS, bottomLeft: DOCK_HANDLE_RADIUS })
    // The 44 pt hit area extends inward past the visible tab.
    .responseRegion(this.previewDock === PreviewDock.LEFT
      ? { x: 0, y: 0, width: DOCK_HANDLE_HIT_WIDTH, height: DOCK_HANDLE_HEIGHT }
      : {
        x: DOCK_HANDLE_VISIBLE_WIDTH - DOCK_HANDLE_HIT_WIDTH, y: 0, width: DOCK_HANDLE_HIT_WIDTH,
        height: DOCK_HANDLE_HEIGHT
      })
    .position({
      x: this.previewDock === PreviewDock.LEFT ? 0 : this.canvasWidth - DOCK_HANDLE_VISIBLE_WIDTH,
      y: Math.min(Math.max(this.previewY + (LOCAL_PREVIEW_HEIGHT - DOCK_HANDLE_HEIGHT) / 2,
        this.travelMinY()), this.travelMaxY() + LOCAL_PREVIEW_HEIGHT - DOCK_HANDLE_HEIGHT)
    })
    .zIndex(2)
    .id('call_preview_dock_handle')
    .accessibilityText($r('app.string.accessibility_conference_show_local_preview'))
    .onClick(() => {
      this.restorePreview();
    })
    .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
      .onActionUpdate((event: GestureEvent) => {
        this.dockHandleDragged(event.offsetX);
      })
      .onActionEnd((event: GestureEvent) => {
        this.dockHandleReleased(event.offsetX, event.velocityX);
      }))
  }

  /** Swift `onCanvasTapped` — the canvas toggles the chrome. */
  private toggleChrome(): void {
    // A sheet (roster, dialpad, picker) is modal on iOS: a tap inside it never reaches the canvas.
    if (this.showsParticipants || this.showsDialpad || this.showsContactPicker) {
      return;
    }
    this.showsChrome = !this.showsChrome;
  }

  /** Decline / accept for a ringing incoming call (CallKit's answer UI on iOS). */
  @Builder
  private answerControls() {
    Row() {
      this.answerButton('call_decline', $r('sys.symbol.phone_down_fill'), '#E53935', (): void => {
        const id: CallId | null = this.callId;
        if (id !== null) {
          ServiceRegistry.shared().callService.refuse(id);
        }
        // Declining a second call returns to the call already up; the screen closes only when
        // the declined call was the last one.
        const others: CallState[] = ServiceRegistry.shared().callService.stateMirror.liveCalls
          .filter((call: CallState): boolean => id === null || !call.id.equals(id));
        if (others.length === 0) {
          this.dismiss();
        }
      })
      this.answerButton('call_accept', $r('sys.symbol.phone_fill'), '#2E7D32', (): void => {
        const id: CallId | null = this.callId;
        if (id !== null) {
          // A video call is answered with the camera on (CallKit's video answer on iOS).
          ServiceRegistry.shared().callService.accept(id, !this.isAudioOnly);
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceAround)
    .margin({ bottom: $r('sys.float.padding_level16') })
  }

  @Builder
  private answerButton(id: string, icon: Resource, color: string, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(32)
        .fontColor([Color.White])
    }
    .id(id)
    .width(72)
    .height(72)
    .borderRadius(36)
    .backgroundColor(color)
    .onClick(action)
  }

  /* ── the call composition ──────────────────────────────────────────────────────── */
  /** comp_renderer_layer — Swift `let videoView = RendererLayerView()` on one tile. */
  @Builder
  private tileRenderer(tile: CanvasTileModel) {
    // conditionalVariants[audio_only]: an audio-only call negotiates no video, so the tile
    // shows the avatar canvas instead of a renderer there is nothing to feed.
    // The tile draws its own avatar while it has no video.
    if (!this.isAudioOnly) {
      RendererLayerView({
        rendererId: tile.id,
        // Swift `aspectFill` for a tile, the whole frame only for the local preview.
        showsWholeFrame: tile.isLocalPreview,
        onSurfaceReady: (surfaceId: string): void => {
          this.tileSurfaces.set(tile.id, surfaceId);
        }
      })
    }
  }

  /** comp_call_avatar — Swift `avatarView`, shown whenever the tile carries no video. */
  @Builder
  private tileAvatar(tile: CanvasTileModel) {
    CallAvatarView({
      avatarData: tile.avatar,
      displayName: tile.avatarName.length > 0 ? tile.avatarName : tile.displayName,
      isAvatarResolved: tile.isAvatarResolved,
      // A conference tile is a fraction of the screen; the full-size face would overflow it.
      avatarSize: this.isConference ? CONFERENCE_AVATAR_SIZE : AvatarSize.CALL_160
    })
  }

  /** Swift `ParticipantTileUIView` — one participant of the canvas. */
  @Builder
  private callTile(tile: CanvasTileModel) {
    ParticipantTileUIView({
      tile: tile,
      rendererBuilder: (): void => {
        this.tileRenderer(tile)
      },
      avatarBuilder: (): void => {
        this.tileAvatar(tile)
      },
      onLongPress: (participantId: string): void => {
        this.tileLongPressed(participantId);
      },
      // Swift `canvasPinched`: pinch out fills the tile, pinch in shows the whole frame.
      onScalingChosen: (participantId: string, wholeFrame: boolean): void => {
        this.scalingOverrides.set(participantId, wholeFrame ? SinkScaling.FIT : SinkScaling.FILL);
        this.applyVideoScalingPolicies();
      }
    })
  }

  /** comp_call_header — Swift `CallHeaderView(model:horizontalInset:)`. */
  @Builder
  private callHeader() {
    CallHeaderView({
      header: this.header,
      canAddParticipant: this.canAddParticipant,
      onShowParticipants: (): void => {
        this.showParticipants();
      }
    })
  }

  /** screen_in_call_dialpad — presentation: sheet, hostScreen: screen_call. */
  @Builder
  dialpadSheet() {
    InCallDialpadSheet({ isPresented: $showsDialpad })
  }

  /** Swift `.sheet(isPresented: $model.showsParticipants) { ConferenceParticipantsView }`. */
  @Builder
  participantsSheet() {
    // Swift: the sheet is the call's own, one-to-one included — there it lists you and the peer.
    ConferenceParticipantsView({
      participants: this.conferenceParticipantListTileCanvas,
      pending: this.pending,
      hasPending: this.hasPending,
      pendingCount: this.pendingCount,
      participantCount: this.participantCount,
      canModerateConference: this.canModerateConference,
      canAddParticipant: this.canAddParticipant,
      onPerform: (item: ConferenceMenuItem, participantId: string): void => {
        this.performOnParticipant(item, participantId);
      },
      onCancelInvite: (callId: string): void => {
        this.cancelInvite(callId);
      },
      onShowGridLayout: (): void => {
        this.showGridLayout();
      },
      onAddParticipant: (): void => {
        this.addParticipant();
      },
      onDismiss: (): void => {
        this.closePanels();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Swift `ConferenceCanvasView(...).opacity(model.contentHidden ? 0 : 1)`. Picture-in-
      // picture draws into its own window (CallPictureInPicture), not a layer of this screen.
      if (!this.contentHidden) {
        ParticipantCanvas({
          tiles: this.participantTiles,
          preview: this.preview,
          tileBuilder: (tile: CanvasTileModel): void => {
            this.callTile(tile)
          },
          onCanvasTapped: (): void => {
            this.toggleChrome();
          }
        })
      }

      // The local camera, floating over the remote video (Swift `previewId`'s tile).
      // Kept mounted while the camera is off (hidden), so its surface - and the camera session
      // bound to it - survive a mute/unmute.
      if (this.isVideo && !this.isIncoming) {
        Stack() {
          Stack() {
            VideoPreviewLayer({
              audioOnly: false,
              onSurfaceReady: (surfaceId: string): void => {
                ServiceRegistry.shared().videoService.setPreviewSurface(surfaceId);
              },
              onSurfaceReleased: (): void => {
                ServiceRegistry.shared().videoService.setPreviewSurface(null);
              }
            })
          }
          .width('100%')
          .height('100%')
          // The mirror sits inside, so the drag below is not mirrored with it.
          .scale({ x: this.previewMirrored ? -1 : 1, y: 1 })
        }
        .width(LOCAL_PREVIEW_WIDTH)
        .height(LOCAL_PREVIEW_HEIGHT)
        .borderRadius(12)
        .clip(true)
        .position({ x: this.previewX, y: this.previewY })
        .zIndex(1)
        // Swift: a conference shows the local camera as its own tile, never as a floating preview.
        .visibility(this.isVideoMuted || this.isConference ? Visibility.Hidden : Visibility.Visible)
        .accessibilityText($r('app.string.accessibility_conference_local_preview'))
        // Swift `previewPanned`: the preview follows the finger inside the travel bounds, is
        // rubber-banded past a side edge, then docks there or settles in the nearest corner.
        .gesture(PanGesture({ distance: 1 })
          .onActionStart(() => {
            this.previewDragStarted();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.previewDragged(event.offsetX, event.offsetY);
          })
          .onActionEnd((event: GestureEvent) => {
            this.previewReleased(event.offsetX, event.velocityX);
          }))

        if (this.previewDock !== PreviewDock.NONE && !this.isVideoMuted && !this.isConference) {
          this.previewDockHandle()
        }
      }

      // Swift `chrome` — both halves appear and disappear with `model.showsChrome`.
      Column() {
        if (this.showsChrome) {
          CallTopActionsView({
            header: this.header,
            headerBuilder: (): void => {
              this.callHeader()
            },
            pictureInPicture: this.pictureInPicture,
            raiseHand: this.raiseHand,
            // Swift `model.canAddParticipant`: an ongoing non-SIP call, and in a conference only
            // a moderator (a one-to-one call may always add one, which creates the conference).
            canAddParticipant: this.canAddParticipant,
            onPerform: (intent: CallControlIntent): void => {
              this.perform(intent);
            },
            onAddParticipant: (): void => {
              this.addParticipant();
            },
            onShowParticipants: (): void => {
              this.showParticipants();
            }
          })
        }

        Blank()

        // The disclosed daemon gap raised by this screen's own controls.
        if (this.showDaemonNotice) {
          Text($r('app.string.daemon_not_available'))
            .width('100%')
            .id('call_daemon_notice')
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_on_primary'))
            .textAlign(TextAlign.Center)
            .padding($r('sys.float.ohos_id_card_margin_start'))
            .backgroundColor($r('app.color.jami'))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            .margin({ bottom: $r('sys.float.ohos_id_card_margin_start') })
        }

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .fontSize($r('sys.float.Body_M'))
            .fontColor(CALL_STATUS_COLOR)
            .textAlign(TextAlign.Center)
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        }

        // HarmonyOS has no CallKit answer screen: a ringing incoming call is answered here.
        if (this.isIncoming) {
          this.answerControls()
        } else if (this.showsChrome) {
          Column() {
            CallControlsView({
              primary: this.controls,
              // Swift `plan.supplemental` in every state the controls show (ringing too): hold
              // is disabled until `canHold`/`canResume`, the dialpad stays tappable.
              supplemental: this.supplementalControls,
              onPerform: (intent: CallControlIntent): void => {
                this.perform(intent);
              }
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
        }
      }
      .width('100%')
      .height('100%')
      // Swift `chrome` is `.padding()`-inset over the canvas; outside its controls a touch goes
      // through to the canvas (a tile's long press or pinch), so it never blocks what is below.
      .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      .hitTestBehavior(HitTestMode.Transparent)

      // Swift's three sheets (roster, dialpad, contact picker). This screen is itself a
      // CustomDialog, where bindSheet does not present, so they are panels over the call.
      if (this.showsParticipants || this.showsDialpad || this.showsContactPicker) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(SHEET_SCRIM)
          .onClick(() => {
            this.closePanels();
          })
          .zIndex(4)
        Column() {
          // Swift `.preferredColorScheme(.dark)` on the roster and the dialpad sheets; the
          // picker follows the system.
          WithTheme({
            colorMode: this.showsParticipants || this.showsDialpad ? ThemeColorMode.DARK : ThemeColorMode.SYSTEM
          }) {
              Column() {
                if (this.showsParticipants) {
                  this.participantsSheet()
                } else if (this.showsDialpad) {
                  this.dialpadSheet()
                } else {
                  ContactPickerSheet({
                    isPresented: $showsContactPicker,
                    pickerForConversation: false,
                    onContactSelected: (item: PickerItem): void => {
                      this.addPickedParticipant(item);
                    }
                  })
                }
              }
              .width('100%')
              .height('100%')
              // iOS dark sheets sit on the elevated dark systemBackground (#1C1C1E), not black; the
              // roster's own 30% backdrop over it gives the #151618 measured on iOS (T-1700 review).
              .backgroundColor(this.showsParticipants || this.showsDialpad ? $r('app.color.jami_call_canvas')
                : $r('sys.color.background_primary'))
            }
        }
        .width('100%')
        // Swift: the roster is a medium-detent sheet; the dialpad (`.sheet` with no detents) and
        // the picker (`present()`) are page sheets reaching up to just under the status bar.
        .height(this.showsParticipants ? MEDIUM_SHEET : `calc(100% - ${this.topInset + PAGE_SHEET_GAP}vp)`)
        .position({ x: 0, y: this.showsParticipants ? MEDIUM_SHEET : this.topInset + PAGE_SHEET_GAP })
        // iOS 18 sheet: 10 pt top corners (measured on the simulator's roster, T-1700 review).
        .borderRadius({ topLeft: SHEET_CORNER_RADIUS, topRight: SHEET_CORNER_RADIUS })
        .clip(true)
        .zIndex(5)
      }
    }
    .width('100%')
    .height('100%')
    // Swift `Color.jamiCallBackdrop.ignoresSafeArea()` under every layer.
    .backgroundColor($r('app.color.jami_call_backdrop'))
    // Swift `canvasTapped` -> `screenTapped()`: a tap that no control takes toggles the chrome.
    // On the root, not only on the canvas: the chrome layer covers the canvas while it shows,
    // and a child's own tap (a control, the scrim, a tile) still wins over this one.
    .onClick(() => {
      this.toggleChrome();
    })
    // Swift `layoutSubviews` -> `relayout`: a new canvas size (a fold, a rotation) re-seats the
    // preview at its corner or its dock.
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.canvasWidth = Number(newArea.width);
      this.canvasHeight = Number(newArea.height);
      this.settlePreview(false);
    })
    .id('screen_call')
  }
}
