/*
 * comp_media_preview_bottom_bar — Jami iOS 4.21 (origin/master, T-1624), ported from
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewChrome.swift
 *   `struct MediaPreviewActionCapsule` and `struct MediaPreviewReactionPicker`:
 *
 *     HStack(spacing: 0) {
 *         if model.canReply {
 *             Button(beginReply) { HStack(spacing: 7) { Image("arrowshape.turn.up.backward")
 *                 Text(L10n.Global.reply).font(.body.weight(.semibold)) }
 *                 .padding(.horizontal, 12).frame(height: 44) }
 *             Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24).padding(.horizontal, 6)
 *         }
 *         if model.canReact { iconButton("face.smiling", L10n.MediaPreview.react) }
 *         iconButton("arrowshape.turn.up.forward", L10n.Global.forward)
 *         iconButton("square.and.arrow.up", L10n.Global.share)
 *     }
 *     .padding(.horizontal, 5).frame(height: 54).mediaPreviewGlass(in: Capsule())
 *
 *   iconButton = Image(systemName:).font(.system(size: NavBarIcon.glyphSize, 20))
 *                .frame(width: 44, height: 44), ScaleButtonStyle; the others dim to 0.45
 *                while the reaction row is open.
 *
 * 4.20's Share / Forward / Save / Delete discs are gone: Save, Copy and Delete moved to the
 * header's "…" menu (MediaPreviewTopBar). The live iPhone (review-evidence/T-1624) draws the
 * smiley filled, so `face_smiling_fill`; HMSymbolVF has no `square.and.arrow.up`, so Share is
 * drawn (T-1021), at the iPhone's regular weight.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { EmojiPicker, PICKER_BACKGROUND } from './EmojiPicker';

/** Swift `MediaPreviewLayout.control`. */
export const PREVIEW_CONTROL: number = 44;
/** Swift `MediaPreviewLayout.capsuleHeight`. */
export const PREVIEW_CAPSULE_HEIGHT: number = 54;
/**
 * Swift `NavBarIcon.glyphSize` (20, regular). HMSymbol at 20 inks ~1.2x smaller than SF; the
 * iPhone 4.21 capture inks Reply / Forward 21 x 18 pt, which HM reaches at 24 (T-1021).
 */
export const PREVIEW_GLYPH: number = 24;
/** Swift `ScaleButtonStyle` — `.scaleEffect(configuration.isPressed ? 0.92 : 1.0)` on a spring. */
export const PREVIEW_PRESS: ClickEffect = { level: ClickEffectLevel.LIGHT, scale: 0.92 };
/**
 * Swift `mediaPreviewGlass(in:)`: `.systemUltraThinMaterialDark` (Liquid Glass `.regular` on
 * iOS 26). Over the black backdrop the live iPhone reads rgb(19) inside, a rgb(36) rim: the
 * port's dark glass tint + blur + white 0.2 hairline gives the same (T-1021 recipe).
 */
export const PREVIEW_GLASS_TINT: string = '#BC1A1A1A';
export const PREVIEW_GLASS_BLUR: number = 40;
export const PREVIEW_GLASS_STROKE: string = '#33FFFFFF';
export const PREVIEW_GLASS_STROKE_WIDTH: number = 0.5;

/** Swift `HStack(spacing: 7)` / `.padding(.horizontal, 12)` in the Reply button. */
const REPLY_GAP: number = 7;
const REPLY_H_PADDING: number = 12;
/** Swift `.font(.body.weight(.semibold))`. */
const REPLY_FONT_SIZE: number = 17;
const REPLY_FONT_WEIGHT: number = 600;
/** Swift the divider: 1 x 24, white 0.22, 6 each side. */
const DIVIDER_HEIGHT: number = 24;
const DIVIDER_MARGIN: number = 6;
const DIVIDER_COLOR: string = '#38FFFFFF';
/** Swift `.padding(.horizontal, 5)` on the capsule. */
const CAPSULE_H_PADDING: number = 5;
/** Swift `private let dimmedOpacity = 0.45`. */
const DIMMED_OPACITY: number = 0.45;
/** Swift `MediaPreviewLayout.chromeAnimation` — `.easeInOut(duration: 0.2)`. */
export const DIM_ANIMATION_MS: number = 200;
/**
 * SF `square.and.arrow.up` on a SHARE_WIDTH x SHARE_HEIGHT box (T-1021's trace): a rounded box
 * over the lower 69% whose top edge stops a third of the way in from each side, and an arrow
 * from its middle up through that gap. The 4.21 capture inks it 17.5 x 22 pt, stroked ~1.6 pt.
 */
const SHARE_WIDTH: number = 18;
const SHARE_HEIGHT: number = 23;
const SHARE_STROKE: number = 1.6;
/** Swift `MediaPreviewLayout.reactionRowHeight`, the row's `spacing: 2` and `inset = 6`. */
const REACTION_ROW_HEIGHT: number = 50;
const REACTION_SPACING: number = 2;
const REACTION_INSET: number = 6;
/** Swift `Text(emoji).font(.system(size: 26))`, `Circle().fill(.white.opacity(isActive ? 0.22 : 0))`. */
const REACTION_EMOJI_SIZE: number = 26;
const REACTION_ACTIVE_FILL: string = '#38FFFFFF';
/** MCEmojiPicker's popover (`arrowDirection: .down`): the corner radius ContextMenu uses. */
const EMOJI_PICKER_RADIUS: number = 13;
/**
 * Swift `RecentReactions.defaults` (U+1F44D U+1F44E U+1F606 U+1F923 U+1F615) — the same five the
 * context menu offers. ponytail: 4.21 floats recently sent emojis to the front; the port keeps
 * no recents (neither does its context menu), add a store when the context menu gets one.
 */
export const PREVIEW_PREFERRED_REACTIONS: string[] = ['👍', '👎', '😆', '🤣', '😕'];

@Component
export struct MediaPreviewBottomBar {
  /** Swift `model.canReply` — the conversation's composer is available for this message. */
  @Prop canReply: boolean = false;
  /** Swift `model.canReact`. */
  @Prop canReact: boolean = false;
  /** Swift `model.isReacting` — the reaction row is open; the other actions dim. */
  @Prop isReacting: boolean = false;
  /** Swift `model.isShowingText` — Live Text is on: every action dims and takes no touch. */
  @Prop isShowingText: boolean = false;
  /** Swift `model.beginReply()`. */
  onReply?: () => void;
  /** Swift `model.toggleReacting()`. */
  onToggleReacting?: () => void;
  /** Swift `model.forward()` -> MediaPreviewSheet.forward -> ForwardContactPicker. */
  onForward?: () => void;
  /** Swift `model.share()` -> MediaPreviewSheet.share(url:) -> the system share sheet. */
  onShare?: () => void;

  private shareGlyphCommands(): string {
    const p = (vp: number): string => this.getUIContext().vp2px(vp).toFixed(2);
    const w: number = SHARE_WIDTH;
    const h: number = SHARE_HEIGHT;
    const s: number = SHARE_STROKE / 2;
    const top: number = h * 0.31;
    const r: number = 3;
    const mid: number = w / 2;
    const head: number = w * 0.21;
    return `M${p(w * 0.34)} ${p(top)} L${p(s + r)} ${p(top)} ` +
      `Q${p(s)} ${p(top)} ${p(s)} ${p(top + r)} ` +
      `L${p(s)} ${p(h - s - r)} Q${p(s)} ${p(h - s)} ${p(s + r)} ${p(h - s)} ` +
      `L${p(w - s - r)} ${p(h - s)} Q${p(w - s)} ${p(h - s)} ${p(w - s)} ${p(h - s - r)} ` +
      `L${p(w - s)} ${p(top + r)} Q${p(w - s)} ${p(top)} ${p(w - s - r)} ${p(top)} ` +
      `L${p(w * 0.66)} ${p(top)} M${p(mid)} ${p(h * 0.62)} L${p(mid)} ${p(s)} ` +
      `M${p(mid - head)} ${p(h * 0.19)} L${p(mid)} ${p(s)} L${p(mid + head)} ${p(h * 0.19)}`;
  }

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  /** Swift `othersOpacity` — dimmed while reacting or showing text. */
  private othersOpacity(): number {
    return this.isReacting || this.isShowingText ? DIMMED_OPACITY : 1;
  }

  /** Swift `iconButton(_:label:)` — a 44 x 44 glyph, no disc of its own. */
  @Builder
  private iconButton(id: string, glyph: Resource, label: Resource, handler?: () => void) {
    Stack() {
      SymbolGlyph(glyph)
        .fontSize(PREVIEW_GLYPH)
        .fontColor([Color.White])
    }
    .id(id)
    .width(PREVIEW_CONTROL)
    .height(PREVIEW_CONTROL)
    .accessibilityText(label)
    .clickEffect(PREVIEW_PRESS)
    .onClick(() => {
      this.fire(handler);
    })
  }

  build() {
    Row() {
      if (this.canReply) {
        Row({ space: REPLY_GAP }) {
          SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left'))
            .fontSize(PREVIEW_GLYPH)
            .fontColor([Color.White])
          Text($r('app.string.global_reply'))
            .fontSize(REPLY_FONT_SIZE)
            .fontWeight(REPLY_FONT_WEIGHT)
            .fontColor(Color.White)
            .maxLines(1)
        }
        .id('mediaPreviewReply')
        .height(PREVIEW_CONTROL)
        .padding({ start: LengthMetrics.vp(REPLY_H_PADDING), end: LengthMetrics.vp(REPLY_H_PADDING) })
        .opacity(this.othersOpacity())
        .animation({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut })
        .clickEffect(PREVIEW_PRESS)
        .onClick(() => {
          this.fire(this.onReply);
        })

        Row()
          .width(1)
          .height(DIVIDER_HEIGHT)
          .backgroundColor(DIVIDER_COLOR)
          .margin({ start: LengthMetrics.vp(DIVIDER_MARGIN), end: LengthMetrics.vp(DIVIDER_MARGIN) })
          .accessibilityLevel('no')
      }

      if (this.canReact) {
        Row() {
          this.iconButton('mediaPreviewReact', $r('sys.symbol.face_smiling_fill'),
            $r('app.string.media_preview_react'), this.onToggleReacting)
        }
        .opacity(this.isShowingText ? DIMMED_OPACITY : 1)
        .animation({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut })
      }

      Row() {
        this.iconButton('mediaPreviewForward', $r('sys.symbol.arrowshape_turn_up_right'),
          $r('app.string.global_forward'), this.onForward)

        Stack() {
          Path()
            .width(SHARE_WIDTH)
            .height(SHARE_HEIGHT)
            .commands(this.shareGlyphCommands())
            .fillOpacity(0)
            .stroke(Color.White)
            .strokeWidth(SHARE_STROKE)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
        }
        .id('mediaPreviewShare')
        .width(PREVIEW_CONTROL)
        .height(PREVIEW_CONTROL)
        .accessibilityText($r('app.string.global_share'))
        .clickEffect(PREVIEW_PRESS)
        .onClick(() => {
          this.fire(this.onShare);
        })
      }
      .opacity(this.othersOpacity())
      .animation({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut })
    }
    // Swift `.allowsHitTesting(!model.isShowingText)`.
    .hitTestBehavior(this.isShowingText ? HitTestMode.None : HitTestMode.Default)
    .height(PREVIEW_CAPSULE_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .padding({ start: LengthMetrics.vp(CAPSULE_H_PADDING), end: LengthMetrics.vp(CAPSULE_H_PADDING) })
    // Swift `.mediaPreviewGlass(in: Capsule())`.
    .backgroundColor(PREVIEW_GLASS_TINT)
    .backdropBlur(PREVIEW_GLASS_BLUR)
    .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
    .borderColor(PREVIEW_GLASS_STROKE)
    .borderRadius(PREVIEW_CAPSULE_HEIGHT / 2)
  }
}

/**
 * Swift `MediaPreviewReactionPicker` — `ScrollView(.horizontal) { HStack(spacing: 2) {
 * MediaPreviewEmojiPickerButton; ForEach(choices.all) { emojiButton } } .padding(.horizontal, 6)
 * .frame(height: 50) }.frame(width: min(contentWidth, maxWidth)).mediaPreviewGlass(in: Capsule())`.
 */
@Component
export struct MediaPreviewReactionPicker {
  /** Swift `choices.all` — the preferred five, then our own others. */
  @Prop choices: string[] = [];
  /** Swift `choices.own` — the emojis we already put on this message, ringed. */
  @Prop own: string[] = [];
  @Prop maxWidth: number = 0;
  /** Swift `onPick` — `model.react(emoji)`, which toggles ours off. */
  onPick?: (emoji: string) => void;
  /** Swift `MediaPreviewEmojiPickerButton.isPresented`. */
  @State private isEmojiPickerPresented: boolean = false;
  /** The plus's top edge (window vp): MCEmojiPicker opens above it (`arrowDirection: .down`). */
  @State private plusTop: number = 0;

  private pick(emoji: string): void {
    this.isEmojiPickerPresented = false;
    const handler: ((emoji: string) => void) | undefined = this.onPick;
    if (handler !== undefined) {
      handler(emoji);
    }
  }

  private contentWidth(): number {
    const items: number = this.choices.length + 1;
    return items * PREVIEW_CONTROL + (items - 1) * REACTION_SPACING + 2 * REACTION_INSET;
  }

  @Builder
  private emojiPicker() {
    EmojiPicker({
      maxHeight: this.plusTop - REACTION_ROW_HEIGHT,
      onPick: (emoji: string): void => {
        this.pick(emoji);
      }
    })
  }

  build() {
    Scroll() {
      Row({ space: REACTION_SPACING }) {
        // Swift `MediaPreviewEmojiPickerButton` — `plus`, opening MCEmojiPicker.
        Stack() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(PREVIEW_GLYPH)
            .fontColor([Color.White])
        }
        .id('mediaPreviewMoreEmoji')
        .width(PREVIEW_CONTROL)
        .height(PREVIEW_CONTROL)
        .accessibilityText($r('app.string.media_preview_more_emoji'))
        .clickEffect(PREVIEW_PRESS)
        .onClick(() => {
          this.isEmojiPickerPresented = !this.isEmojiPickerPresented;
        })
        .onAreaChange((_old: Area, area: Area) => {
          this.plusTop = Number(area.globalPosition.y);
        })
        .bindPopup(this.isEmojiPickerPresented, {
          builder: this.emojiPicker,
          placement: Placement.Top,
          popupColor: PICKER_BACKGROUND,
          backgroundBlurStyle: BlurStyle.NONE,
          radius: EMOJI_PICKER_RADIUS,
          mask: true,
          onStateChange: (event: PopupStateChangeParam) => {
            if (!event.isVisible) {
              this.isEmojiPickerPresented = false;
            }
          }
        })

        ForEach(this.choices, (emoji: string) => {
          Text(emoji)
            .fontSize(REACTION_EMOJI_SIZE)
            .textAlign(TextAlign.Center)
            .width(PREVIEW_CONTROL)
            .height(PREVIEW_CONTROL)
            .borderRadius(PREVIEW_CONTROL / 2)
            .backgroundColor(this.own.includes(emoji) ? REACTION_ACTIVE_FILL : Color.Transparent)
            .accessibilityText(this.own.includes(emoji)
              ? getContext(this).resourceManager.getStringSync($r('app.string.accessibility_remove_reaction').id, emoji)
              : emoji)
            .clickEffect(PREVIEW_PRESS)
            .onClick(() => {
              this.pick(emoji);
            })
        }, (emoji: string) => emoji)
      }
      .height(REACTION_ROW_HEIGHT)
      .padding({ start: LengthMetrics.vp(REACTION_INSET), end: LengthMetrics.vp(REACTION_INSET) })
    }
    .id('mediaPreviewReactionPicker')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width(Math.min(this.contentWidth(), this.maxWidth))
    .height(REACTION_ROW_HEIGHT)
    .backgroundColor(PREVIEW_GLASS_TINT)
    .backdropBlur(PREVIEW_GLASS_BLUR)
    .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
    .borderColor(PREVIEW_GLASS_STROKE)
    .borderRadius(REACTION_ROW_HEIGHT / 2)
  }
}

/**
 * SF `text.viewfinder` as the 4.21 capture draws it (19 x 19 pt at 2x): four rounded corner
 * brackets, 6 pt arms, and three text lines, the last one shorter, stroked 1.5 pt.
 * HMSymbolVF's viewfinders carry a single line (`line_viewfinder`) or a letter instead.
 */
const LIVE_TEXT_SIZE: number = 19;
const LIVE_TEXT_STROKE: number = 1.5;

/**
 * Swift `MediaPreviewLiveTextButton` — the glyph white on the glass circle, or black on a white
 * disc while Live Text is on; ScaleButtonStyle.
 */
@Component
export struct MediaPreviewLiveTextButton {
  /** Swift `isActive: model.isShowingText`. */
  @Prop isActive: boolean = false;
  /** Swift `action: model.toggleShowingText`. */
  onToggle?: () => void;

  private commands(): string {
    const p = (vp: number): string => this.getUIContext().vp2px(vp).toFixed(2);
    const w: number = LIVE_TEXT_SIZE;
    const s: number = LIVE_TEXT_STROKE / 2;
    const arm: number = 6;
    const r: number = 3;
    const corner = (x0: number, y0: number, dx: number, dy: number): string =>
      `M${p(x0)} ${p(y0 + dy * arm)} L${p(x0)} ${p(y0 + dy * r)} ` +
      `Q${p(x0)} ${p(y0)} ${p(x0 + dx * r)} ${p(y0)} L${p(x0 + dx * arm)} ${p(y0)} `;
    const line = (y: number, end: number): string => `M${p(5.25)} ${p(y)} L${p(end)} ${p(y)} `;
    return corner(s, s, 1, 1) + corner(w - s, s, -1, 1) + corner(s, w - s, 1, -1) +
      corner(w - s, w - s, -1, -1) + line(5.75, 13.75) + line(9.5, 13.75) + line(13.25, 10.75);
  }

  build() {
    Stack() {
      Path()
        .width(LIVE_TEXT_SIZE)
        .height(LIVE_TEXT_SIZE)
        .commands(this.commands())
        .fillOpacity(0)
        .stroke(this.isActive ? Color.Black : Color.White)
        .strokeWidth(LIVE_TEXT_STROKE)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .id('mediaPreviewLiveText')
    .width(PREVIEW_CONTROL)
    .height(PREVIEW_CONTROL)
    .accessibilityText($r('app.string.media_preview_live_text'))
    .accessibilitySelected(this.isActive)
    .backgroundColor(this.isActive ? Color.White : PREVIEW_GLASS_TINT)
    .backdropBlur(PREVIEW_GLASS_BLUR)
    .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
    .borderColor(PREVIEW_GLASS_STROKE)
    .borderRadius(PREVIEW_CONTROL / 2)
    .animation({ duration: DIM_ANIMATION_MS, curve: Curve.EaseInOut })
    .clickEffect(PREVIEW_PRESS)
    .onClick(() => {
      const handler: (() => void) | undefined = this.onToggle;
      if (handler !== undefined) {
        handler();
      }
    })
  }
}
