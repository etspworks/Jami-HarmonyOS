/*
 * screen_media_preview — "Media Preview", ported from
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewView.swift + MediaPreviewModel.swift
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewState.swift
 *   Ring/Ring/Features/Conversations/views/PlayerView.swift
 *
 * presentation: modal, hostScreen: screen_conversation. MediaPreviewPresenter presents it over
 * the conversation for a received media item, so it is a @CustomDialog mounted by
 * ConversationChatPage — NOT a routed page and NOT in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): structure from source only.
 *
 * Jami iOS 4.21 (origin/master; the live App Store build 20261123 is the target, T-1624) rebuilt
 * the viewer as `MediaPreviewShell` (MediaPreviewView.swift) around ImagePreviewScreen /
 * VideoPreviewScreen, with MediaPreviewChrome.swift's parts:
 *   ZStack {
 *     Color.black.onTapGesture(handleTap)                      "mediaPreviewToggleControls"
 *     media(handleTap)                                          image / VideoPreviewContent
 *     chrome = ZStack { VStack { top scrim; Spacer; bottom scrim }
 *                       VStack { topChrome; Spacer; bottomChrome } }   while chromeVisible
 *   }
 *   topChrome    = MediaPreviewHeader (X, title capsule, "…" menu) + reactions summary
 *                  (comp_media_preview_top_bar)
 *   bottomChrome = VStack(spacing: 12) { controls(); reaction row if isReacting;
 *                  MediaPreviewActionCapsule } .padding(.horizontal, 16)
 *                  .padding(.bottom, max(safeArea.bottom - 4, 12))   (comp_media_preview_bottom_bar)
 *   controls()   = image: Live Text button (ArkUI image AI analyzer, TEXT); video: VideoPreviewControls
 *                  (mute | elapsed | scrubber | duration on a glass capsule)
 *   handleTap    = close the reaction row if open, else toggle the chrome. No auto-hide in 4.21.
 *
 * Reply: 4.21 composes the reply in the viewer (MediaReplyPanel over the dimmed media, then
 * closes and shows the latest message). The port closes the viewer and hands the reply to the
 * conversation's own composer (host onReply -> replyTo + focus), the flow the chat already has.
 *
 * bindingContract: [image] and [player] are both the transfer's local file (Swift
 * `MessageContentVM.url`). A @CustomDialog's builder arguments are fixed when the CONTROLLER is
 * built and ConversationChatPage builds one controller for every media message, so the host
 * stages the item with `stageMediaPreview()` (AppStorage) and the overlay reads it in
 * aboutToAppear — the same channel screen_media_record already uses on that host.
 * Nothing here is a literal, and nothing is seeded with a sample item.
 *
 * conditionalVariants, built as real `if`s on their own bound selector:
 *   image_item / video_item   — Image vs PlayerView (MediaPreviewContent.image/.player)
 *   controls_visible          — the top/bottom bars
 *   saved_toast               — SavedToast while model.saveSuccess
 *   can_delete                — the Delete action inside the bottom bar
 * needs_photo_permission is a system alert (showAlertDialog), as the app's other iOS alerts.
 *
 * Capability notes (self-signed build):
 *   Save uses photoAccessHelper.showAssetsCreationDialog, which writes through the system save
 *   dialog and needs NO storage permission. It is wrapped (lesson 15): a failure or an absent
 *   provider sets saveError / needsPhotoPermission, it never takes the process down.
 *   Share goes through common/ShareActions.ts (@kit.ShareKit with the clipboard fallback).
 *
 * Delete: deleting a swarm message is a daemon commit, so after the confirmation the host does
 * it (Swift `MediaPreviewActionsDelegate.deleteMessage()`, the host's empty-body edition).
 */
import { curves, LengthMetrics, promptAction, window } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { i18n, intl } from '@kit.LocalizationKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ForwardContactPicker } from '../components/ForwardContactPicker';
import { MediaSeekSlider } from '../components/MediaSeekSlider';
import {
  DIM_ANIMATION_MS, MediaPreviewBottomBar, MediaPreviewLiveTextButton, MediaPreviewReactionPicker, PREVIEW_CONTROL,
  PREVIEW_GLASS_BLUR, PREVIEW_GLASS_STROKE, PREVIEW_GLASS_STROKE_WIDTH, PREVIEW_GLASS_TINT,
  PREVIEW_GLYPH, PREVIEW_PREFERRED_REACTIONS, PREVIEW_PRESS
} from '../components/MediaPreviewBottomBar';
import { MessageContainerModel } from '../components/MessageContent';
import {
  MediaPreviewTopBar, PREVIEW_HEADER_SPACING, PREVIEW_SIDE_INSET, PreviewReactionSegment
} from '../components/MediaPreviewTopBar';
import { PlayerMode, PlayerModel, PlayerView } from '../components/PlayerView';
import { AccountModel } from '../model/AccountModel';
import { MessageAction } from '../model/MessageAction';
import { durationFormatted } from '../model/MessageModel';
import { SavedToast } from '../components/SavedToast';
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';

/** AppStorage keys `stageMediaPreview()` fills — the previewed transfer (URI_KEY: its local path). */
export const MEDIA_PREVIEW_URI_KEY: string = 'mediaPreviewUri';
export const MEDIA_PREVIEW_IS_VIDEO_KEY: string = 'mediaPreviewIsVideo';
export const MEDIA_PREVIEW_CAN_DELETE_KEY: string = 'mediaPreviewCanDelete';

/** Swift `isImageExtension()` / `isMediaExtension()` — UTTypeConformsTo, here the UTD tree. */
function conformsTo(path: string, type: uniformTypeDescriptor.UniformDataType): boolean {
  const dot: number = path.lastIndexOf('.');
  if (dot < 0) {
    return false;
  }
  try {
    const descriptor: uniformTypeDescriptor.TypeDescriptor | null = uniformTypeDescriptor
      .getTypeDescriptor(uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(
        path.substring(dot).toLowerCase()));
    return descriptor !== null && descriptor.belongsTo(type);
  } catch (error) {
    return false;
  }
}

/**
 * Swift `MessageContentVM.presentMediaPreview()` + `MessageActionHandler.handleMediaPreview`:
 * an image or a video on this device opens the in-app preview; anything else returns false and
 * keeps the host's document route (Swift `ContextMenu.openDocument`). Stages the item the
 * overlay reads in aboutToAppear; the host opens its controller when this returns true.
 * `canDelete` is Swift `allowDelete = !message.isIncoming`.
 */
export function stageMediaPreview(filePath: string, canDelete: boolean,
  message: MessageContainerModel | null = null, title: string = ''): boolean {
  const isVideo: boolean = conformsTo(filePath, uniformTypeDescriptor.UniformDataType.VIDEO);
  if (!isVideo && !conformsTo(filePath, uniformTypeDescriptor.UniformDataType.IMAGE)) {
    return false;
  }
  AppStorage.setOrCreate<string>(MEDIA_PREVIEW_URI_KEY, filePath);
  AppStorage.setOrCreate<boolean>(MEDIA_PREVIEW_IS_VIDEO_KEY, isVideo);
  AppStorage.setOrCreate<boolean>(MEDIA_PREVIEW_CAN_DELETE_KEY, canDelete);
  stagedMessage = message;
  stagedTitle = title;
  return true;
}

/**
 * 4.21 `MessageActionHandler.makePreviewModel`: the message the viewer reacts / replies to and
 * its sender's name (`message.$username`, ours `.withYourselfSuffix()`), which only the
 * conversation can resolve. Null / '' from a host that passes neither: no title, no Reply,
 * no React.
 */
let stagedMessage: MessageContainerModel | null = null;
let stagedTitle: string = '';

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * 4.21 `Date.conversationDayLabel()` (Date+Helpers.swift): "Today" / "Yesterday" (relative,
 * sentence-cased), the weekday within the last week, "EEE MMM d" this year, "y MMM d" before.
 */
function conversationDayLabel(date: Date, locale: string): string {
  const now: Date = new Date();
  const days: number = Math.round((startOfDay(now) - startOfDay(date)) / 86400000);
  if (days === 0 || days === 1) {
    const text: string = new intl.RelativeTimeFormat(locale, { numeric: 'auto' }).format(0 - days, 'day');
    return text.charAt(0).toLocaleUpperCase() + text.substring(1);
  }
  if (days >= 2 && days <= 6) {
    return new intl.DateTimeFormat(locale, { weekday: 'long' }).format(date);
  }
  if (date.getFullYear() === now.getFullYear()) {
    return new intl.DateTimeFormat(locale, { weekday: 'short', month: 'short', day: 'numeric' }).format(date);
  }
  return new intl.DateTimeFormat(locale, { year: 'numeric', month: 'short', day: 'numeric' }).format(date);
}

/** 4.21 `Date.messageTimeString()` — `.formatted(time: .shortened)`, the device's 12/24 h. */
function messageTimeString(date: Date, locale: string): string {
  return new intl.DateTimeFormat(locale, {
    hour: 'numeric', minute: '2-digit', hour12: !i18n.System.is24HourClock()
  }).format(date);
}

/** Swift `try await Task.sleep(nanoseconds: 2_000_000_000)` before saveSuccess is lowered. */
const SAVED_TOAST_MS: number = 2000;
/** Swift `private let doubleTapZoomScale: CGFloat = 3`. */
const DOUBLE_TAP_ZOOM: number = 3;

/* ── S6 animation (the source's own curves, MediaPreviewView.swift) ────────────────── */
/**
 * Swift `withAnimation(.spring(response: 0.35, dampingFraction: 0.8))` — raising and lowering
 * `model.saveSuccess` (4.21 MediaPreviewShell keeps it; the chrome toggle is 0.2 s ease).
 * `curves.springMotion(response, dampingFraction)` is the same two-parameter spring.
 */
const SPRING_RESPONSE: number = 0.35;
const SPRING_DAMPING: number = 0.8;
/** 4.21 `.animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.isReacting)`. */
const REACT_SPRING_RESPONSE: number = 0.3;
const REACT_SPRING_DAMPING: number = 0.82;
/**
 * 4.21 Live Text (ImagePreviewScreen + ImageLiveTextSession): ArkUI's image AI analyzer
 * (`Image(src, { types: [TEXT], aiController })` + `enableAnalyzer`), offered when Core Vision's
 * OCR finds text, as iOS shows the button only on `hasResults(for: .text)`. The image is decoded
 * no larger than this for that check.
 */
const OCR_MAX_SIDE: number = 2048;
const OCR_SYSCAP: string = 'SystemCapability.AI.OCR.TextRecognition';
/** image.d.ts enableAnalyzer: "SVG and GIF images cannot be analyzed". */
const NOT_ANALYZABLE: RegExp = /\.(gif|svg)$/i;
const LOG_DOMAIN: number = 0x0001;
const F5_TAG: string = 'JamiF5';
/** Diagnostic only: when to read the support types back once the analyzer overlay is built. */
const ANALYZER_READBACK_MS: number = 1000;
/** 4.21 `MediaPreviewLayout.bottomStackSpacing` / `capsuleBottomOffset` (-4, at least 12). */
const BOTTOM_STACK_SPACING: number = 12;
const CAPSULE_BOTTOM_OFFSET: number = -4;
const CAPSULE_BOTTOM_MIN: number = 12;
/**
 * 4.21 `MediaPreviewScrim`: black up to 16% at the screen edge, eased off with a cosine over
 * 12 steps, `scrimFade` (24) past the chrome.
 */
const SCRIM_FADE: number = 24;
/** The image's single tap (chrome toggle), which Live Text turns off; its double tap stays. */
const SINGLE_TAP_TAG: string = 'mediaPreviewSingleTap';

function scrimStops(): Array<[ResourceColor, number]> {
  const stops: Array<[ResourceColor, number]> = [];
  for (let i = 0; i <= 12; i++) {
    const location: number = i / 12;
    const alpha: number = Math.round(255 * 0.16 * (1 + Math.cos(location * Math.PI)) / 2);
    stops.push([`#${alpha.toString(16).padStart(2, '0')}000000`, location]);
  }
  return stops;
}

const SCRIM_STOPS: Array<[ResourceColor, number]> = scrimStops();
/** 4.21 `VideoPreviewControls`: HStack(spacing: 4), padding leading 4 / trailing 16 / vertical 5, max 600. */
const VIDEO_CONTROLS_GAP: number = 4;
const VIDEO_CONTROLS_LEADING: number = 4;
const VIDEO_CONTROLS_TRAILING: number = 16;
const VIDEO_CONTROLS_V_PADDING: number = 5;
const VIDEO_CONTROLS_MAX_WIDTH: number = 600;
/** 4.21 `MediaScrubberRow`: HStack(spacing: 12), `.font(.subheadline.monospacedDigit())`, white 0.7. */
const SCRUBBER_GAP: number = 12;
const TIME_FONT_SIZE: number = 15;
const TIME_COLOR: string = '#B3FFFFFF';
/** Swift `.lightContent` — the status bar over the black backdrop. */
const LIGHT_STATUS_BAR_CONTENT: string = '#FFFFFF';
/** Swift `withAnimation(.easeInOut(duration: 0.25))` in `toggleZoom()` (line 326). */
const ZOOM_ANIM_MS: number = 250;
/** Swift `withAnimation(.easeInOut(duration: 0.2))` recentring after a pinch back to 1. */
const RECENTER_ANIM_MS: number = 200;

/* ── drag-to-dismiss (MediaPreviewView.swift imagePanGesture / dismissDragGesture) ──── */
/** Swift `private let dismissThreshold: CGFloat = 120`. */
const DISMISS_DISTANCE: number = 120;
/** Swift `abs(value.predictedEndTranslation.height) > 800` — a flick dismisses too. */
const DISMISS_PREDICTED: number = 800;
/**
 * SwiftUI predicts the end of a drag with the scroll view's 0.998 deceleration, which
 * travels velocity x 0.5 s further; ArkUI reports only the velocity.
 */
const PREDICT_SECONDS: number = 0.5;
/** Swift `if controlsVisible && abs(value.translation.height) > 10 { controlsVisible = false }`. */
const DRAG_HIDES_CONTROLS: number = 10;

/* ── S5 metrics (NO CAPTURE — the source's own, MediaPreviewView/State.swift) ──────── */
/**
 * Swift `Color.black.opacity(overlayState.backgroundAlpha)`; `backgroundAlpha` is raised to 1
 * the moment the preview expands (MediaPreviewState.swift:118) and the overlay only renders
 * while expanded, so the backdrop is opaque black.
 */
const BACKDROP: string = '#FF000000';
/** Swift `.alert(...)` — the iOS system alert's own 270 pt content width. */
const ALERT_WIDTH: number = 270;
/** Swift `UIApplication.openSettingsURLString` — the app's page in the system Settings. */
const SETTINGS_BUNDLE: string = 'com.huawei.hmos.settings';
const SETTINGS_ABILITY: string = 'com.huawei.hmos.settings.MainAbility';
const SETTINGS_APP_INFO_URI: string = 'application_info_entry';
/** Swift `model.isBusy` — the overlay's progress ring, sized like the source's `.large` one. */
const BUSY_SIZE: number = 32;

@CustomDialog
export struct MediaPreviewOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /** Swift `MediaPreviewModel.forwardCallback` — the host sends the item to the picked rooms. */
  onForwardSelected?: (conversationIds: string[]) => void;
  /** Swift `MediaPreviewActionsDelegate.deleteMessage()` — the conversation owns the delete. */
  onDelete?: () => void;
  /**
   * 4.21 `MediaPreviewConversationActions.beginReply(toMessage:)` — the conversation quotes the
   * message in its composer (the viewer has closed). Absent: no Reply button.
   */
  onReply?: () => void;
  /** 4.21 `react(toMessage:with:)` adding an emoji — the conversation sends it. */
  onReact?: (emoji: string) => void;
  /** 4.21 `react(toMessage:with:)` on one of ours — the conversation withdraws that reaction. */
  onRevokeReaction?: (reactionId: string) => void;

  /**
   * Swift `overlayState.isPresented` — owned by screen_conversation (the host raises and
   * lowers the preview), so the host sees a drag/Close dismissal without reading the
   * controller.
   */
  @Link isPresented: boolean;

  /** Swift `fileURL` — the transfer's local file, staged by the host (stageMediaPreview). */
  private filePath: string = '';
  /**
   * bindingContract[image]: the local file <- `Image(uiImage:)`, as the bubble draws it.
   * A @CustomDialog's builder arguments are fixed when the CONTROLLER is built and the host
   * builds one controller for every media message, so the previewed item is handed over
   * through AppStorage and read in aboutToAppear — which runs when the dialog is opened.
   */
  @State image: string = '';
  /** conditionalVariants[video_item]: MediaPreviewContent is `.player`. */
  @State isVideoItem: boolean = false;
  /** conditionalVariants[can_delete]: Swift `model.canDelete`. */
  @State canDelete: boolean = false;

  /**
   * bindingContract[player]: the local file <- the PlayerView coordinator. `path` is the one
   * field the player reads, and it is the previewed item's own file — never a bundled sample.
   */
  @State player: PlayerModel = new PlayerModel();
  /** conditionalVariants[image_item]: MediaPreviewContent is `.image`. */
  @State isImageItem: boolean = true;
  /** conditionalVariants[controls_visible]: 4.21 `@State private var chromeVisible`. */
  @State isControlsVisible: boolean = true;
  /** 4.21 `model.title` / `model.subtitle` — the sender and "Today, 10:05". */
  @State title: string = '';
  @State subtitle: string = '';
  /** 4.21 `model.canReply` / `model.canReact`. */
  @State canReply: boolean = false;
  @State canReact: boolean = false;
  /** 4.21 `model.isReacting` — the reaction row over the action capsule. */
  @State isReacting: boolean = false;
  /** 4.21 `model.canShowText` (the image has text the analyzer can show) / `isShowingText`. */
  @State canShowText: boolean = false;
  @State isShowingText: boolean = false;
  /** ArkUI's image analyzer controller (`ImageAIOptions.aiController`). */
  private analyzer: ImageAnalyzerController = new ImageAnalyzerController();
  /** onComplete can fire again (zoom re-decodes); the text check runs once per preview. */
  private textChecked: boolean = false;
  /** 4.21 `model.reactions` segments and `reactionChoices.own`, kept here as we react. */
  @State reactionSegments: PreviewReactionSegment[] = [];
  @State ownEmojis: string[] = [];
  /** The previewed message (4.21 `messageId` + `conversationActions`), null without a host one. */
  private message: MessageContainerModel | null = null;
  /** The window's width, and the chrome's heights the scrims extend past (4.21 preference keys). */
  @State screenWidth: number = 0;
  @State topChromeHeight: number = 0;
  @State bottomChromeHeight: number = 0;
  /** conditionalVariants[saved_toast]: Swift `@Published var saveSuccess`. */
  @State isSavedToast: boolean = false;
  /** Swift `@Published var saveError: String?` — the "could not save" alert. */
  @State errorText: string = '';
  /** Swift `model.activeSheet == .forward` — the ForwardContactPicker sheet. */
  @State @Watch('onForwardingChanged') isForwarding: boolean = false;
  /** The window under the dialog, and its status-bar content colour before the preview. */
  private win: window.Window | null = null;
  private savedStatusBarContent: string | undefined = undefined;
  /** Swift `@State private var imageScale` — never below 1, the image's fitted size. */
  @State imageScale: number = 1;
  /** Swift `@State private var lastScale` — the scale a pinch starts from. */
  private lastScale: number = 1;
  /** Swift `@State private var imageOffset` / `lastOffset` — the zoomed image's pan. */
  @State imageOffsetX: number = 0;
  @State imageOffsetY: number = 0;
  private lastOffsetX: number = 0;
  private lastOffsetY: number = 0;
  /** True while a save / share / forward is in flight — Swift's `model.isBusy` guard. */
  @State isLoading: boolean = false;
  /**
   * Swift: the backdrop and media `.ignoresSafeArea()`, but the bars stay in the safe area —
   * Close sits under the status bar and the bottom capsule above the home indicator. The
   * dialog covers the whole window, so the bars take the window's avoid areas as padding.
   */
  @State topInset: number = 0;
  @State bottomInset: number = 0;

  aboutToAppear(): void {
    this.applyItem();
    this.resolveInsets();
    // 4.21 raises the chrome once the viewer has grown open; the port opens without the grow.
    this.showControls(true);
  }

  aboutToDisappear(): void {
    // Swift: the overlay window goes, and the status bar is the conversation's again.
    if (this.win !== null && this.savedStatusBarContent !== undefined) {
      this.setStatusBarContent(this.win, this.savedStatusBarContent);
    }
  }

  private resolveInsets(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.topInset = px2vp(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height);
      this.bottomInset = px2vp(
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      // Light status-bar icons over the black backdrop; the old colour comes back on close.
      // ponytail: restores an explicit colour, so a dark-mode switch after a preview keeps it.
      this.win = win;
      this.savedStatusBarContent = win.getWindowSystemBarProperties().statusBarContentColor;
      this.setStatusBarContent(win, LIGHT_STATUS_BAR_CONTENT);
    }).catch((error: BusinessError): void => {
      console.warn(`MediaPreviewOverlay: window unavailable: ${error.code}`);
    });
  }

  private setStatusBarContent(win: window.Window, color: string): void {
    win.setWindowSystemBarProperties({ statusBarContentColor: color })
      .catch((error: BusinessError): void => {
        console.warn(`MediaPreviewOverlay: status bar colour not set: ${error.code}`);
      });
  }

  /**
   * Swift `MediaPreviewPresenter.present(model:)` — the content kind is decided by the item,
   * not by this view: `.player` for a playable transfer, `.image` otherwise.
   */
  private applyItem(): void {
    this.filePath = AppStorage.get<string>(MEDIA_PREVIEW_URI_KEY) ?? '';
    this.image = this.filePath.length > 0 ? 'file://' + this.filePath : '';
    this.isVideoItem = AppStorage.get<boolean>(MEDIA_PREVIEW_IS_VIDEO_KEY) ?? false;
    this.canDelete = AppStorage.get<boolean>(MEDIA_PREVIEW_CAN_DELETE_KEY) ?? false;
    this.isImageItem = !this.isVideoItem;
    this.player.path = this.filePath;
    // Swift previews a `.player` only when `player.hasVideo` — the full-screen mute button too.
    this.player.hasVideo = this.isVideoItem;
    this.applyMessage();
  }

  /**
   * 4.21 `makePreviewModel`: title (the sender), subtitle `L10n.MediaPreview.dateTime(
   * date.conversationDayLabel(), date.messageTimeString())`, and `enableReactions`.
   */
  private applyMessage(): void {
    const container: MessageContainerModel | null = stagedMessage;
    this.message = container;
    this.title = stagedTitle;
    if (container === null) {
      return;
    }
    const date: Date = container.content.message.receivedDate;
    const locale: string = i18n.System.getSystemLocale();
    const day: string = conversationDayLabel(date, locale);
    const time: string = messageTimeString(date, locale);
    this.subtitle = getContext(this).resourceManager.getStringSync(
      $r('app.string.media_preview_date_time').id,
      day,
      time
    );
    this.canReply = this.onReply !== undefined && container.canReply;
    this.canReact = this.onReact !== undefined && container.content.menuItems.length > 0;
    this.applyReactions(container);
  }

  /** The message's reactions as they stand (the conversation updates its MessageModel in place). */
  private reactions(container: MessageContainerModel): MessageAction[] {
    return Array.from(container.content.message.reactions.values());
  }

  /** Swift `currentJamiAccountId` <- `accountService.currentAccount?.jamiId`, as ContextMenu. */
  private localJamiId(): string {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    return account === null ? '' : account.jamiId;
  }

  /**
   * 4.21 `ReactionsContainerModel.updateSegments()`: one segment per emoji, biggest count first,
   * then by emoji; and `ReactionActions.ownEmojis(on:)` for the local account.
   */
  private applyReactions(container: MessageContainerModel): void {
    const jamiId: string = this.localJamiId();
    const counts: Map<string, number> = new Map<string, number>();
    const own: Set<string> = new Set<string>();
    this.reactions(container).forEach((reaction: MessageAction): void => {
      counts.set(reaction.content, (counts.get(reaction.content) ?? 0) + 1);
      if (reaction.author === jamiId) {
        own.add(reaction.content);
      }
    });
    this.reactionSegments = Array.from(counts.entries())
      .map((entry: [string, number]): PreviewReactionSegment => new PreviewReactionSegment(entry[0], entry[1]))
      .sort((a: PreviewReactionSegment, b: PreviewReactionSegment): number =>
        a.count !== b.count ? b.count - a.count : (a.emoji < b.emoji ? -1 : a.emoji > b.emoji ? 1 : 0));
    this.ownEmojis = Array.from(own);
  }

  /** 4.21 `ReactionChoices.all` — the preferred five, then our own others, sorted. */
  private reactionChoices(): string[] {
    const others: string[] = this.ownEmojis
      .filter((emoji: string): boolean => !PREVIEW_PREFERRED_REACTIONS.includes(emoji))
      .sort();
    return PREVIEW_PREFERRED_REACTIONS.concat(others);
  }

  /** 4.21 `model.toggleReacting()`. */
  private toggleReacting(): void {
    animateTo({ curve: curves.springMotion(REACT_SPRING_RESPONSE, REACT_SPRING_DAMPING) }, (): void => {
      this.isReacting = !this.isReacting;
    });
  }

  /**
   * 4.21 `model.react(emoji)` -> `ReactionActions.toggle(_:on:)`: one of ours is withdrawn, any
   * other emoji sent; the row closes. The summary follows at once, as the daemon's commit does
   * on the iPhone a moment later (this overlay does not observe the conversation).
   */
  private react(emoji: string): void {
    this.isReacting = false;
    const isOwn: boolean = this.ownEmojis.includes(emoji);
    if (isOwn) {
      // Our reaction's commit id, from the live message: one sent from this preview has it
      // once the daemon committed it. ponytail: a withdraw tapped before that commit lands
      // only updates the summary; iOS queues it (pendingRemovals), add that if it shows.
      const container: MessageContainerModel | null = this.message;
      const jamiId: string = this.localJamiId();
      const ours: MessageAction | undefined = container === null ? undefined : this.reactions(container)
        .find((reaction: MessageAction): boolean => reaction.author === jamiId && reaction.content === emoji);
      const revoke: ((reactionId: string) => void) | undefined = this.onRevokeReaction;
      if (ours !== undefined && revoke !== undefined) {
        revoke(ours.id);
      }
      this.ownEmojis = this.ownEmojis.filter((own: string): boolean => own !== emoji);
    } else {
      const send: ((emoji: string) => void) | undefined = this.onReact;
      if (send !== undefined) {
        send(emoji);
      }
      this.ownEmojis = this.ownEmojis.concat([emoji]);
    }
    const delta: number = isOwn ? -1 : 1;
    const segments: PreviewReactionSegment[] = this.reactionSegments
      .map((segment: PreviewReactionSegment): PreviewReactionSegment =>
        new PreviewReactionSegment(segment.emoji, segment.emoji === emoji ? segment.count + delta : segment.count))
      .filter((segment: PreviewReactionSegment): boolean => segment.count > 0);
    if (!isOwn && !segments.some((segment: PreviewReactionSegment): boolean => segment.emoji === emoji)) {
      segments.push(new PreviewReactionSegment(emoji, 1));
    }
    this.reactionSegments = segments;
  }

  /**
   * 4.21 `model.beginReply()`. The reply is composed in the conversation's own panel: the viewer
   * closes first, then the host quotes this message there and raises the keyboard.
   */
  private reply(): void {
    const handler: (() => void) | undefined = this.onReply;
    this.dismiss();
    if (handler !== undefined) {
      handler();
    }
  }

  /**
   * 4.21 `model.copy()` — the image onto the pasteboard (`UIPasteboard.setData`), decoded to a
   * PixelMap, which is what HarmonyOS apps paste. A failure is reported, never fatal.
   */
  private copyImage(): void {
    try {
      const source: image.ImageSource = image.createImageSource(this.filePath);
      source.createPixelMap()
        .then((pixelMap: image.PixelMap): Promise<void> => pasteboard.getSystemPasteboard()
          .setData(pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap)))
        .catch((error: BusinessError): void => {
          this.errorText = describeError(error);
        })
        .finally((): void => {
          source.release();
        });
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    }
  }

  /** 4.21 `handleTap()`: an open reaction row closes first, then Live Text, else the chrome toggles. */
  private handleTap(): void {
    if (this.isReacting) {
      this.toggleReacting();
      return;
    }
    if (this.isShowingText) {
      this.isShowingText = false;
      return;
    }
    this.toggleControls();
  }

  /** 4.21 `model.toggleShowingText()` — the reaction row closes, the analyzer turns on / off. */
  private toggleShowingText(): void {
    this.isReacting = false;
    this.isShowingText = !this.isShowingText;
    hilog.info(LOG_DOMAIN, F5_TAG, 'live text: analyzer %{public}s', this.isShowingText ? 'on' : 'off');
    if (this.isShowingText) {
      setTimeout((): void => {
        hilog.info(LOG_DOMAIN, F5_TAG, 'live text: support types after enabling %{public}s (analyzer %{public}s)',
          this.supportTypes(), this.isShowingText ? 'on' : 'off');
      }, ANALYZER_READBACK_MS);
    }
  }

  /** getImageAnalyzerSupportTypes() for the log: null until ArkUI binds the controller. */
  private supportTypes(): string {
    try {
      const types: ImageAnalyzerType[] | null = this.analyzer.getImageAnalyzerSupportTypes() ?? null;
      return types === null ? 'null' : `[${types.join(',')}]`;
    } catch (error) {
      return `unavailable: ${describeError(error as BusinessError)}`;
    }
  }

  /**
   * 4.21 `ImageLiveTextSession.analyze` -> `onTextAvailable`: the button exists when OCR finds
   * text in this (static) image. getImageAnalyzerSupportTypes() answers null until ArkUI hands the
   * aiController to the analyzer, which it does only when it builds the analyzer overlay, i.e.
   * with enableAnalyzer(true) (ArkUI ImageAnalyzerController.getImageAnalyzerSupportTypes,
   * ImagePattern::IsSupportImageAnalyzerFeature). The analyzer is off until the button is tapped,
   * so null here means "not known yet" and OCR decides; only a list without TEXT hides the
   * button. Where Core Vision's OCR is absent or fails, a list with TEXT alone shows it.
   */
  private detectText(): void {
    if (this.textChecked) {
      return;
    }
    this.textChecked = true;
    let types: ImageAnalyzerType[] | null = null;
    try {
      // BRA-AL00 (OpenHarmony 7.0.0.111) answers null, not a list: the preview crashed on it.
      types = this.analyzer.getImageAnalyzerSupportTypes() ?? null;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, F5_TAG, 'live text: analyzer types unavailable: %{public}s',
        describeError(error as BusinessError));
    }
    const supported: boolean = types !== null && types.includes(ImageAnalyzerType.TEXT);
    const ruledOut: boolean = NOT_ANALYZABLE.test(this.filePath) || (types !== null && !supported);
    hilog.info(LOG_DOMAIN, F5_TAG, 'live text: support types before enabling %{public}s, OCR %{public}s%{public}s',
      types === null ? 'null' : `[${types.join(',')}]`, canIUse(OCR_SYSCAP) ? 'yes' : 'no',
      ruledOut ? ', not offered' : '');
    if (ruledOut) {
      return;
    }
    if (!canIUse(OCR_SYSCAP)) {
      this.canShowText = supported;
      return;
    }
    const offerOnSupport = (error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, F5_TAG, 'live text: OCR failed (%{public}s), offered %{public}s',
        describeError(error), supported ? 'yes' : 'no');
      this.canShowText = supported;
    };
    try {
      const source: image.ImageSource = image.createImageSource(this.filePath);
      source.getImageInfo()
        .then((info: image.ImageInfo): Promise<image.PixelMap> => {
          const scale: number = Math.min(1, OCR_MAX_SIDE / Math.max(info.size.width, info.size.height, 1));
          return source.createPixelMap({
            desiredSize: {
              width: Math.max(1, Math.round(info.size.width * scale)),
              height: Math.max(1, Math.round(info.size.height * scale))
            }
          });
        })
        .then((pixelMap: image.PixelMap): Promise<void> => textRecognition.recognizeText({ pixelMap: pixelMap })
          .then((result: textRecognition.TextRecognitionResult): void => {
            const found: boolean = result.value.trim().length > 0;
            hilog.info(LOG_DOMAIN, F5_TAG, 'live text: OCR found text %{public}s', found ? 'yes' : 'no');
            this.canShowText = found;
          })
          .finally((): void => {
            pixelMap.release();
          }))
        .catch(offerOnSupport)
        .finally((): void => {
          source.release();
        });
    } catch (error) {
      offerOnSupport(error as BusinessError);
    }
  }

  /**
   * Live Text owns the image's touches the way ImageLiveTextSession does on iOS: while it is on,
   * the unzoomed pan (drag-to-dismiss) and the single tap stand down so a press and drag select
   * text; pinch, double-tap zoom and the zoomed pan stay.
   */
  private judgeImageGesture(info: GestureInfo): GestureJudgeResult {
    if (!this.isShowingText) {
      return GestureJudgeResult.CONTINUE;
    }
    if (info.type === GestureControl.GestureType.PAN_GESTURE && this.imageScale <= 1) {
      return GestureJudgeResult.REJECT;
    }
    if (info.tag === SINGLE_TAP_TAG) {
      return GestureJudgeResult.REJECT;
    }
    return GestureJudgeResult.CONTINUE;
  }

  /** Swift `mediaPreviewClose` / the drag dismissal — `overlayState.dismiss()`. */
  private dismiss(): void {
    this.showControls(false);
    this.isShowingText = false;
    this.imageScale = 1;
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** 4.21 `chromeVisible.toggle()` under `.animation(MediaPreviewLayout.chromeAnimation)`. */
  private toggleControls(): void {
    animateTo({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut }, (): void => {
      this.showControls(!this.isControlsVisible);
    });
  }

  /** 4.21 has no auto-hide: the chrome stays until a tap, a drag or a sheet takes it. */
  private showControls(visible: boolean): void {
    this.isControlsVisible = visible;
    // 4.21 `showsPlayButton: chromeVisible && ...` — the player's play disc follows the chrome.
    this.player.controlsVisible = visible;
    if (!visible) {
      this.isReacting = false;
    }
  }

  /**
   * Swift `.onChange(of: model.activeSheet?.id)`: the bars go, unanimated, under the sheet and
   * spring back when it closes.
   */
  private onForwardingChanged(): void {
    if (this.isForwarding) {
      this.showControls(false);
    } else if (this.isPresented) {
      // 4.21 `chromeVisible = true` under the chrome's `.easeInOut(duration: 0.2)`.
      animateTo({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut },
        (): void => {
          this.showControls(true);
        });
    }
  }

  /** Swift `magnificationGesture.onChanged` — `imageScale = max(1, lastScale * value)`. */
  private pinchUpdate(event: GestureEvent): void {
    this.imageScale = Math.max(1, this.lastScale * event.scale);
  }

  /** Swift `magnificationGesture.onEnded` — keep the scale; back at 1 the image recentres. */
  private pinchEnd(event: GestureEvent): void {
    this.lastScale = Math.max(1, this.lastScale * event.scale);
    this.imageScale = this.lastScale;
    if (this.imageScale <= 1) {
      animateTo({ duration: RECENTER_ANIM_MS, curve: Curve.EaseInOut }, (): void => {
        this.imageOffsetX = 0;
        this.imageOffsetY = 0;
        this.lastOffsetX = 0;
        this.lastOffsetY = 0;
      });
    }
  }

  /** Swift `imagePanGesture.onChanged` (zoomed: the image follows) / `dismissDragGesture`. */
  private panUpdate(event: GestureEvent): void {
    if (this.imageScale > 1) {
      this.imageOffsetX = this.lastOffsetX + event.offsetX;
      this.imageOffsetY = this.lastOffsetY + event.offsetY;
    }
    if (this.isControlsVisible && Math.abs(event.offsetY) > DRAG_HIDES_CONTROLS) {
      this.showControls(false);
    }
  }

  /**
   * Swift `.onEnded`: 120 pt of vertical travel, or a flick, dismisses — 4.21 only while the
   * image is not zoomed and Live Text is off (`allowsDismissDrag: !isZoomed && !isShowingText`).
   */
  private panEnd(event: GestureEvent): void {
    if (this.imageScale <= 1 && !this.isShowingText && (Math.abs(event.offsetY) > DISMISS_DISTANCE
      || Math.abs(event.offsetY + event.velocityY * PREDICT_SECONDS) > DISMISS_PREDICTED)) {
      this.dismiss();
      return;
    }
    this.lastOffsetX = this.imageOffsetX;
    this.lastOffsetY = this.imageOffsetY;
  }

  /** Swift `toggleZoom()` — the image's double tap, 1 <-> doubleTapZoomScale. */
  private toggleZoom(): void {
    // Swift `withAnimation(.easeInOut(duration: 0.25))`.
    animateTo({ duration: ZOOM_ANIM_MS, curve: Curve.EaseInOut }, (): void => {
      this.imageScale = this.imageScale > 1 ? 1 : DOUBLE_TAP_ZOOM;
      this.lastScale = this.imageScale;
      this.imageOffsetX = 0;
      this.imageOffsetY = 0;
      this.lastOffsetX = 0;
      this.lastOffsetY = 0;
    });
  }

  /** Swift `model.share()` — `.share(url:)` then the activity sheet, here @kit.ShareKit. */
  private share(): void {
    if (this.image.length === 0) {
      // Never a silent return — a Share with nothing to share has to say so.
      promptAction.showToast({ message: $r('app.string.daemon_not_available') });
      return;
    }
    this.isLoading = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ShareActions.shareFile(context, this.filePath)
      .then((): void => {
        this.isLoading = false;
      })
      .catch((error: BusinessError): void => {
        this.isLoading = false;
        this.errorText = describeError(error);
      });
  }

  /** Swift `model.forward()` — raises the ForwardContactPicker sheet over the preview. */
  private forward(): void {
    this.isForwarding = true;
  }

  /** Swift `conversationSelectedCB` — the host forwards the item to the picked conversations. */
  private forwardTo(conversationIds: string[]): void {
    const handler: ((ids: string[]) => void) | undefined = this.onForwardSelected;
    if (handler !== undefined) {
      handler(conversationIds);
    }
    this.dismiss();
  }

  /**
   * Swift `model.save()` — `photoSaver.saveImageWithAuthCheck(url:onSuccess:onError:
   * onAccessDenied:)`, guarded on the item being an image. `showAssetsCreationDialog` is the
   * keyless HarmonyOS equivalent: the system save dialog grants the single write, so no
   * storage permission is requested. The dialog only hands back the URI the user allowed; the
   * image is copied into it, and "Saved" rises only once that write succeeds. Every failure
   * path is caught — a system picker that cannot start must not take the app down.
   */
  private save(): void {
    if (!this.isImageItem || this.image.length === 0) {
      promptAction.showToast({ message: $r('app.string.daemon_not_available') });
      return;
    }
    this.errorText = '';
    this.isLoading = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const config: photoAccessHelper.PhotoCreationConfig = {
      fileNameExtension: this.fileExtension(),
      photoType: photoAccessHelper.PhotoType.IMAGE
    };
    try {
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      helper.showAssetsCreationDialog([fileUri.getUriFromPath(this.filePath)], [config])
        .then((uris: string[]): void => {
          this.isLoading = false;
          // T-1024: what the system save prompt answered, so a device that raises no alert
          // after Deny shows which branch it took.
          console.info(`MediaPreviewOverlay: save prompt granted ${uris.length} uri(s)`);
          // An empty list is the user refusing the save in the system prompt — HarmonyOS's
          // photo-library authorisation, so Swift's `onAccessDenied:` (T-0967).
          if (uris.length === 0) {
            this.showPhotoPermissionAlert();
            return;
          }
          // A throw here (open or copy) lands in the catch below as a failed save.
          const source: fs.File = fs.openSync(this.filePath, fs.OpenMode.READ_ONLY);
          try {
            const destination: fs.File = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY);
            try {
              fs.copyFileSync(source.fd, destination.fd);
            } finally {
              fs.closeSync(destination);
            }
          } finally {
            fs.closeSync(source);
          }
          this.announceSaved();
        })
        .catch((error: BusinessError): void => {
          this.saveFailed(error);
        });
    } catch (error) {
      this.saveFailed(error as BusinessError);
    }
  }

  /** Swift `onSuccess:` — saveSuccess, announced, then lowered after 2s. */
  private announceSaved(): void {
    // Swift `.animation(.spring(response: 0.35, dampingFraction: 0.8), value: model
    // .saveSuccess)` on the way in, and the same spring inside the 2s `withAnimation` on the
    // way out (MediaPreviewView.swift:118).
    animateTo({ curve: curves.springMotion(SPRING_RESPONSE, SPRING_DAMPING) }, (): void => {
      this.isSavedToast = true;
    });
    setTimeout((): void => {
      animateTo({ curve: curves.springMotion(SPRING_RESPONSE, SPRING_DAMPING) }, (): void => {
        this.isSavedToast = false;
      });
    }, SAVED_TOAST_MS);
  }

  /**
   * Swift `onError:` / `onAccessDenied:` — a denial raises the photo-permission alert, every
   * other failure the "could not save" one.
   */
  private saveFailed(error: BusinessError): void {
    this.isLoading = false;
    console.warn(`MediaPreviewOverlay: save failed: ${error.code} ${error.message}`);
    if (error.code === 201 || error.code === 13900012) {
      this.showPhotoPermissionAlert();
      return;
    }
    this.errorText = describeError(error);
  }

  /** Swift `url.pathExtension` — what PhotoCreationConfig needs to name the saved asset. */
  private fileExtension(): string {
    const dot: number = this.filePath.lastIndexOf('.');
    if (dot < 0 || dot === this.filePath.length - 1) {
      return 'jpg';
    }
    return this.filePath.substring(dot + 1);
  }

  /**
   * Swift `presentDeleteAlert()`: "Delete message", no body, destructive Delete and Cancel —
   * Cancel left, as the iPhone lays a two-button alert out. Delete -> `model.delete()` (the
   * host's delegate) and the preview dismisses; Cancel leaves the preview as it was.
   */
  private deleteMedia(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.global_delete_message'),
      message: '',
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.actions_delete_action'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          const handler: (() => void) | undefined = this.onDelete;
          if (handler !== undefined) {
            handler();
          }
          this.dismiss();
        }
      }
    });
  }

  /**
   * 4.21 `VideoPreviewControls` — `HStack(spacing: 4) { mute; MediaScrubberRow(elapsed, duration)
   * { MediaSeekSlider } }`, padding leading 4 / trailing 16 / vertical 5, on a glass capsule no
   * wider than 600.
   */
  @Builder
  private videoControls() {
    Row({ space: VIDEO_CONTROLS_GAP }) {
      Stack() {
        SymbolGlyph(this.player.isMuted
          ? $r('sys.symbol.speaker_slash_fill')
          : $r('sys.symbol.speaker_wave_2_fill'))
          .fontSize(PREVIEW_GLYPH)
          .fontColor([Color.White])
      }
      .id('mediaPreviewMute')
      .width(PREVIEW_CONTROL)
      .height(PREVIEW_CONTROL)
      .accessibilityText(this.player.isMuted
        ? $r('app.string.accessibility_audio_player_unmute')
        : $r('app.string.accessibility_audio_player_mute'))
      .clickEffect(PREVIEW_PRESS)
      // The player applies `isMuted` to its AVPlayer (PlayerView.onModelChange).
      .onClick(() => {
        this.player.isMuted = !this.player.isMuted;
      })

      // 4.21 `MediaScrubberRow` — elapsed | scrubber | duration, 44 high.
      Row({ space: SCRUBBER_GAP }) {
        Text(durationFormatted(this.player.position * this.player.durationSeconds))
          .fontSize(TIME_FONT_SIZE)
          .fontFeature('"tnum" on')
          .fontColor(TIME_COLOR)
        Column() {
          MediaSeekSlider({
            positionRatio: this.player.position,
            scrubber: true,
            onSeekChange: (value: number): void => {
              this.player.position = value;
            }
          })
        }
        .layoutWeight(1)
        Text(this.player.durationText.length > 0 ? this.player.durationText : durationFormatted(0))
          .fontSize(TIME_FONT_SIZE)
          .fontFeature('"tnum" on')
          .fontColor(TIME_COLOR)
      }
      .layoutWeight(1)
      .height(PREVIEW_CONTROL)
    }
    .id('mediaPreviewVideoControls')
    .width('100%')
    .constraintSize({ maxWidth: VIDEO_CONTROLS_MAX_WIDTH })
    .padding({
      start: LengthMetrics.vp(VIDEO_CONTROLS_LEADING),
      end: LengthMetrics.vp(VIDEO_CONTROLS_TRAILING),
      top: LengthMetrics.vp(VIDEO_CONTROLS_V_PADDING),
      bottom: LengthMetrics.vp(VIDEO_CONTROLS_V_PADDING)
    })
    .backgroundColor(PREVIEW_GLASS_TINT)
    .backdropBlur(PREVIEW_GLASS_BLUR)
    .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
    .borderColor(PREVIEW_GLASS_STROKE)
    .borderRadius((PREVIEW_CONTROL + 2 * VIDEO_CONTROLS_V_PADDING) / 2)
  }

  /**
   * Swift `.alert(isPresented: $model.needsPhotoPermission)`: noLibraryPermissionsTitle,
   * photoAccessRequiredMessage, `.cancel` and `.default(goToSettings)` — Cancel left, as the
   * iPhone lays a two-button alert out. Over the preview; the image is not saved.
   */
  private showPhotoPermissionAlert(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.alerts_no_library_permissions_title'),
      message: $r('app.string.conversation_photo_access_required_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.actions_go_to_settings'),
        action: (): void => {
          this.openSettings();
        }
      }
    });
  }

  /** Swift `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString))`. */
  private openSettings(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      bundleName: SETTINGS_BUNDLE,
      abilityName: SETTINGS_ABILITY,
      uri: SETTINGS_APP_INFO_URI,
      parameters: { pushParams: context.abilityInfo.bundleName }
    };
    try {
      context.startAbility(want).catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
    } catch (error) {
      // `startAbility` can throw synchronously where the target ability does not exist.
      this.errorText = describeError(error as BusinessError);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      /*
       * Swift `Color.black.opacity(overlayState.backgroundAlpha).contentShape(Rectangle())
       * .onTapGesture { toggleControls() }` — the backdrop IS the toggle control, so the slug
       * sits on the tappable layer itself rather than on a child of it.
       */
      Column()
        .id('mediaPreviewToggleControls')
        .width('100%')
        .height('100%')
        .backgroundColor(BACKDROP)
        .onClick(() => {
          this.handleTap();
        })

      // Swift `mediaContent()` — the two content branches, never flattened into one.
      if (this.isImageItem) {
        // 4.21 Live Text: ArkUI's AI analyzer for TEXT, on while `isShowingText`. image.d.ts:
        // no overlay / alt / obscured / repeat here, a static image; Contain shows it whole.
        Image(this.image, { types: [ImageAnalyzerType.TEXT], aiController: this.analyzer })
          .id('mediaPreviewImage')
          .enableAnalyzer(this.isShowingText)
          .onComplete(() => {
            this.detectText();
          })
          // UIImage applies the EXIF orientation; ArkUI's default (UP) draws the raw pixels,
          // so a photo tagged Orientation 3 showed upside down.
          .orientation(ImageRotateOrientation.AUTO)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .scale({ x: this.imageScale, y: this.imageScale })
          .translate({ x: this.imageOffsetX, y: this.imageOffsetY })
          // Swift `magnificationGesture`, then `imagePanGesture` (zoomed) / `dismissDragGesture`
          // (not zoomed) as one pan. Exclusive: a pinch never ends as a drag-to-dismiss.
          .gesture(GestureGroup(GestureMode.Exclusive,
            PinchGesture()
              .onActionUpdate((event: GestureEvent) => {
                this.pinchUpdate(event);
              })
              .onActionEnd((event: GestureEvent) => {
                this.pinchEnd(event);
              })
              .onActionCancel(() => {
                this.lastScale = this.imageScale;
              }),
            PanGesture()
              .onActionUpdate((event: GestureEvent) => {
                this.panUpdate(event);
              })
              .onActionEnd((event: GestureEvent) => {
                this.panEnd(event);
              })))
          // Swift `.onTapGesture(count: 2) { toggleZoom() }` then `.onTapGesture(count: 1)
          // { handleTap() }`: SwiftUI waits for the double tap to fail before the single one.
          // Exclusive does that here; a bare onClick won every first tap, so zoom never ran.
          .gesture(GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => {
              this.toggleZoom();
            }),
            TapGesture({ count: 1 }).tag(SINGLE_TAP_TAG).onAction(() => {
              this.handleTap();
            })))
          .onGestureJudgeBegin((info: GestureInfo, _event: BaseGestureEvent): GestureJudgeResult =>
            this.judgeImageGesture(info))
      } else if (this.isVideoItem) {
        // Swift `PlayerView(viewModel:, sizeMode: .fullScreen, withControls: true,
        // externalControlsVisible: $controlsVisible)` — comp_player_view, with the seek
        // slider it owns (comp_media_seek_slider).
        PlayerView({
          model: this.player,
          sizeMode: PlayerMode.FULL_SCREEN,
          withControls: true,
          // 4.21: the scrubber is the preview's own bottom chrome (videoControls), not the player's.
          seekBuilder: (): void => {},
          onToggleControls: (): void => {
            this.handleTap();
          }
        })
          .height('100%')
          // Swift: the player's own `DragGesture().onEnded` — a vertical drag dismisses.
          .gesture(PanGesture({ direction: PanDirection.Vertical })
            .onActionEnd((event: GestureEvent) => {
              this.panEnd(event);
            }))
      }

      // 4.21 `MediaPreviewShell.chrome` — conditionalVariants[controls_visible]. The scrims sit
      // under the chrome and take no touch.
      if (this.isControlsVisible) {
        Column() {
          Column()
            .width('100%')
            .height(this.topChromeHeight + SCRIM_FADE)
            .linearGradient({ direction: GradientDirection.Bottom, colors: SCRIM_STOPS })
            .hitTestBehavior(HitTestMode.None)
          // None on each child too: the parent's None does not reach them, and a Default child
          // here took every touch over the image (no tap toggle, zoom or drag-to-dismiss).
          Blank()
            .hitTestBehavior(HitTestMode.None)
          Column()
            .width('100%')
            .height(this.bottomChromeHeight + SCRIM_FADE)
            .linearGradient({ direction: GradientDirection.Top, colors: SCRIM_STOPS })
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY)
      }

      Column() {
        if (this.isControlsVisible) {
          MediaPreviewTopBar({
            title: this.title,
            subtitle: this.subtitle,
            canSave: this.isImageItem,
            canCopy: this.isImageItem,
            canDelete: this.canDelete,
            reactions: this.reactionSegments,
            summaryMaxWidth: this.screenWidth - 2 * (PREVIEW_SIDE_INSET + PREVIEW_CONTROL + PREVIEW_HEADER_SPACING),
            onClose: (): void => {
              this.dismiss();
            },
            onSave: (): void => {
              this.save();
            },
            onCopy: (): void => {
              this.copyImage();
            },
            onDelete: (): void => {
              this.deleteMedia();
            }
          })
            .padding({ top: this.topInset })
            .onAreaChange((_old: Area, area: Area): void => {
              this.topChromeHeight = Number(area.height);
            })
            .transition(TransitionEffect.OPACITY)
        }

        Blank()
          .hitTestBehavior(HitTestMode.None)

        // 4.21 `bottomChrome` — for images and videos alike now.
        if (this.isControlsVisible) {
          Column({ space: BOTTOM_STACK_SPACING }) {
            if (this.isVideoItem) {
              this.videoControls()
            }
            // 4.21 ImagePreviewScreen `controls`: the Live Text button, trailing, while the image
            // has text and the reaction row is closed.
            if (this.isImageItem && this.canShowText && !this.isReacting) {
              Row() {
                MediaPreviewLiveTextButton({
                  isActive: this.isShowingText,
                  onToggle: (): void => {
                    this.toggleShowingText();
                  }
                })
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
              .transition(TransitionEffect.OPACITY)
            }
            // 4.21 `reactionsArea` — `.transition(.scale(scale: 0.9).combined(with: .opacity))`.
            if (this.isReacting) {
              MediaPreviewReactionPicker({
                choices: this.reactionChoices(),
                own: this.ownEmojis,
                maxWidth: this.screenWidth - 2 * PREVIEW_SIDE_INSET,
                onPick: (emoji: string): void => {
                  this.react(emoji);
                }
              })
                .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })))
            }
            MediaPreviewBottomBar({
              canReply: this.canReply,
              canReact: this.canReact,
              isReacting: this.isReacting,
              isShowingText: this.isShowingText,
              onReply: (): void => {
                this.reply();
              },
              onToggleReacting: (): void => {
                this.toggleReacting();
              },
              onForward: (): void => {
                this.forward();
              },
              onShare: (): void => {
                this.share();
              }
            })
          }
          .width('100%')
          .padding({
            start: LengthMetrics.vp(PREVIEW_SIDE_INSET),
            end: LengthMetrics.vp(PREVIEW_SIDE_INSET),
            bottom: LengthMetrics.vp(Math.max(this.bottomInset + CAPSULE_BOTTOM_OFFSET, CAPSULE_BOTTOM_MIN))
          })
          .onAreaChange((_old: Area, area: Area): void => {
            this.bottomChromeHeight = Number(area.height);
          })
          .transition(TransitionEffect.OPACITY)
        }
      }
      .width('100%')
      .height('100%')
      // Swift: the VStack's Spacer is not hit-testable, so the image under the empty middle
      // keeps its tap, pan and zoom while the bars are up. Default here blocked every sibling
      // beneath this full-screen column, and the controls could not be tapped away.
      .hitTestBehavior(HitTestMode.Transparent)

      // Swift `model.isBusy` — the save/share round trip is a system dialog away.
      if (this.isLoading) {
        LoadingProgress()
          .id('mediaPreviewBusy')
          .width(BUSY_SIZE)
          .height(BUSY_SIZE)
          // The ring sits on the opaque black backdrop, so it takes the bar glyphs' white.
          .color(Color.White)
      }

      // Swift `.overlay { if model.saveSuccess { SavedToast() } }`.
      if (this.isSavedToast) {
        SavedToast()
      }

      // Swift `.alert(model.saveError != nil) { Alert(errorSavingImage) }`.
      if (this.errorText.length > 0) {
        // Swift `.alert(model.saveError != nil) { Alert(errorSavingImage) }` — the same
        // centred alert card the photo-permission branch uses.
        Text(this.errorText)
          .id('mediaPreviewSaveError')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.label'))
          .textAlign(TextAlign.Center)
          .width(ALERT_WIDTH)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
      }

      // Swift `.sheet(item: $model.activeSheet) { case .forward: ForwardContactPicker(...) }`.
      if (this.isForwarding) {
        ForwardContactPicker({
          isPresented: $isForwarding,
          onConversationsSelected: (ids: string[]): void => {
            this.forwardTo(ids);
          }
        })
          // The dialog covers the status bar; the iOS sheet starts below it.
          .padding({ top: this.topInset })
          .backgroundColor($r('sys.color.background_primary'))
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area): void => {
      this.screenWidth = Number(area.width);
    })
    .id('screen_media_preview')
  }
}
