/*
 * comp_media_preview_top_bar — Jami iOS 4.21 (origin/master, T-1624), ported from
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewChrome.swift `struct MediaPreviewHeader`
 *   and `struct MediaPreviewReactionsSummary`, stacked as MediaPreviewShell.topChrome:
 *
 *     VStack(spacing: 8) {
 *         HStack(spacing: 12) {
 *             MediaPreviewGlassButton("xmark", L10n.Global.close)          // 44, glass circle
 *             Spacer()
 *             if !menuActions.isEmpty { MediaPreviewMenuButton(actions) }  // "ellipsis", glass
 *         }
 *         .overlay(titleCapsule.padding(.horizontal, 44 + 12))
 *         .padding(.horizontal, 16)
 *         if showsBottomChrome, let reactions { MediaPreviewReactionsSummary }
 *     }
 *
 *   titleCapsule = VStack { Text(title).font(.subheadline.weight(.semibold)).truncationMode(.middle)
 *                           Text(subtitle).font(.caption).foregroundColor(.white.opacity(0.72)) }
 *                  .lineLimit(1).padding(.horizontal, 16).frame(minHeight: 44).glass(Capsule())
 *   menuActions  = Save (images), Copy (images), Delete (destructive, own messages) — a UIMenu,
 *                  here bindMenu with leading glyphs as DocumentRow's Menu.
 *
 * The live iPhone (review-evidence/T-1624/T-1624-ios-01) measures X and "…" 44 pt at 16 pt from
 * the edges, the title capsule 44 pt high: "QA port f2" / "Today, 10:05".
 */
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  PREVIEW_CONTROL, PREVIEW_GLASS_BLUR, PREVIEW_GLASS_STROKE, PREVIEW_GLASS_STROKE_WIDTH,
  PREVIEW_GLASS_TINT, PREVIEW_GLYPH, PREVIEW_PRESS
} from './MediaPreviewBottomBar';

/** Swift `MediaPreviewLayout.sideInset` / `headerSpacing` / `reactionsTopSpacing`. */
export const PREVIEW_SIDE_INSET: number = 16;
export const PREVIEW_HEADER_SPACING: number = 12;
const REACTIONS_TOP_SPACING: number = 8;
/** Swift `.font(.subheadline.weight(.semibold))` / `.font(.caption)` / white 0.72. */
const TITLE_FONT_SIZE: number = 15;
const TITLE_FONT_WEIGHT: number = 600;
const SUBTITLE_FONT_SIZE: number = 12;
const SUBTITLE_COLOR: string = '#B8FFFFFF';
/** Swift `.padding(.horizontal, 16)` in the title capsule. */
const TITLE_H_PADDING: number = 16;
/** Swift `MediaPreviewReactionsSummary`: spacing 8 / 3, padding 12 x 5, min height 30. */
const SUMMARY_SEGMENT_GAP: number = 8;
const SUMMARY_CONTENT_GAP: number = 3;
const SUMMARY_H_PADDING: number = 12;
const SUMMARY_V_PADDING: number = 5;
const SUMMARY_MIN_HEIGHT: number = 30;
/** Swift `Text(emoji).font(.subheadline)`; the count `.footnote.weight(.semibold).monospacedDigit()`. */
const SUMMARY_EMOJI_SIZE: number = 15;
const SUMMARY_COUNT_SIZE: number = 13;
/** SF `ellipsis` at NavBarIcon size: 4.5 pt dots, 4.75 pt apart (23 pt across). */
const ELLIPSIS_DOT: number = 4.5;
const ELLIPSIS_GAP: number = 4.75;
/** Swift `UIMenu` destructive red. */
const DESTRUCTIVE_RED: string = '#FF3B30';

/** Swift `ReactionSegment` — one emoji, how many put it, whether we are among them. */
export class PreviewReactionSegment {
  emoji: string = '';
  count: number = 0;

  constructor(emoji: string, count: number) {
    this.emoji = emoji;
    this.count = count;
  }
}

@Component
export struct MediaPreviewTopBar {
  /** Swift `model.title` — the sender's best name, ours with " (You)". */
  @Prop title: string = '';
  /** Swift `model.subtitle` — `L10n.MediaPreview.dateTime(day, time)`, "Today, 10:05". */
  @Prop subtitle: string = '';
  /** Swift `model.canSave` (an image file) / `isImagePreview` (Copy) / `canDelete`. */
  @Prop canSave: boolean = false;
  @Prop canCopy: boolean = false;
  @Prop canDelete: boolean = false;
  /** Swift `showsBottomChrome && model.reactions` — the summary under the title. */
  @Prop reactions: PreviewReactionSegment[] = [];
  /** Swift `reactionsSummaryMaxWidth`. */
  @Prop summaryMaxWidth: number = 0;
  /** Swift `onClose` — `close()`: chrome off, `overlayState.dismiss()`. */
  onClose?: () => void;
  onSave?: () => void;
  onCopy?: () => void;
  onDelete?: () => void;

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  private hasMenu(): boolean {
    return this.canSave || this.canCopy || this.canDelete;
  }

  /** Swift `MediaPreviewModel.menuActions(onDelete:)`, in its order. */
  @Builder
  private moreMenu() {
    Menu() {
      if (this.canSave) {
        MenuItem({
          content: $r('app.string.global_save'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_arrow_down'))
        })
          .id('mediaPreviewMenuSave')
          .onClick(() => {
            this.fire(this.onSave);
          })
      }
      if (this.canCopy) {
        MenuItem({
          content: $r('app.string.global_copy'),
          // SF `doc.on.doc` — the context menu's Copy glyph.
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.doc_text_on_doc_text'))
        })
          .id('mediaPreviewMenuCopy')
          .onClick(() => {
            this.fire(this.onCopy);
          })
      }
      if (this.canDelete) {
        MenuItem({
          content: $r('app.string.actions_delete_action'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([DESTRUCTIVE_RED])
        })
          .id('mediaPreviewMenuDelete')
          .contentFontColor(DESTRUCTIVE_RED)
          .onClick(() => {
            this.fire(this.onDelete);
          })
      }
    }
  }

  /** Swift `MediaPreviewGlassButton` — a 44 glass circle around a NavBarIcon-sized glyph. */
  @Styles
  private glassCircle() {
    .width(PREVIEW_CONTROL)
      .height(PREVIEW_CONTROL)
      .backgroundColor(PREVIEW_GLASS_TINT)
      .backdropBlur(PREVIEW_GLASS_BLUR)
      .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
      .borderColor(PREVIEW_GLASS_STROKE)
      .borderRadius(PREVIEW_CONTROL / 2)
      .clickEffect(PREVIEW_PRESS)
  }

  build() {
    Column({ space: REACTIONS_TOP_SPACING }) {
      Stack() {
        Row() {
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(PREVIEW_GLYPH)
              .fontColor([Color.White])
          }
          .id('mediaPreviewClose')
          .accessibilityText($r('app.string.global_close'))
          .glassCircle()
          .onClick(() => {
            this.fire(this.onClose);
          })

          Blank()

          if (this.hasMenu()) {
            // SF `ellipsis`: three dots inked 23 x 4.5 pt on the 4.21 capture. HMSymbolVF has no
            // plain horizontal ellipsis (`more` is a four-tile grid), so the dots are drawn.
            Row({ space: ELLIPSIS_GAP }) {
              ForEach([0, 1, 2], (_dot: number) => {
                Circle()
                  .width(ELLIPSIS_DOT)
                  .height(ELLIPSIS_DOT)
                  .fill(Color.White)
              }, (dot: number) => `${dot}`)
            }
            .justifyContent(FlexAlign.Center)
            .id('mediaPreviewMore')
            .accessibilityText($r('app.string.media_preview_more_actions'))
            .glassCircle()
            .bindMenu(this.moreMenu)
          }
        }
        .width('100%')

        // Swift `.overlay(titleCapsule.padding(.horizontal, control + headerSpacing))`.
        if (this.title.length > 0) {
          Row() {
            Column() {
              Text(this.title)
                .fontSize(TITLE_FONT_SIZE)
                .fontWeight(TITLE_FONT_WEIGHT)
                .fontColor(Color.White)
                .maxLines(1)
                // Swift `.truncationMode(.middle)`.
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .ellipsisMode(EllipsisMode.CENTER)
              if (this.subtitle.length > 0) {
                Text(this.subtitle)
                  .fontSize(SUBTITLE_FONT_SIZE)
                  .fontColor(SUBTITLE_COLOR)
                  .maxLines(1)
              }
            }
            .id('mediaPreviewTitle')
            .justifyContent(FlexAlign.Center)
            .constraintSize({ minHeight: PREVIEW_CONTROL })
            .padding({ start: LengthMetrics.vp(TITLE_H_PADDING), end: LengthMetrics.vp(TITLE_H_PADDING) })
            .backgroundColor(PREVIEW_GLASS_TINT)
            .backdropBlur(PREVIEW_GLASS_BLUR)
            .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
            .borderColor(PREVIEW_GLASS_STROKE)
            .borderRadius(PREVIEW_CONTROL / 2)
            .accessibilityGroup(true)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({
            start: LengthMetrics.vp(PREVIEW_CONTROL + PREVIEW_HEADER_SPACING),
            end: LengthMetrics.vp(PREVIEW_CONTROL + PREVIEW_HEADER_SPACING)
          })
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
      .width('100%')
      .padding({ start: LengthMetrics.vp(PREVIEW_SIDE_INSET), end: LengthMetrics.vp(PREVIEW_SIDE_INSET) })

      // Swift `MediaPreviewReactionsSummary` — emoji and count per segment, biggest first.
      if (this.reactions.length > 0) {
        Row({ space: SUMMARY_SEGMENT_GAP }) {
          ForEach(this.reactions, (segment: PreviewReactionSegment) => {
            Row({ space: SUMMARY_CONTENT_GAP }) {
              Text(segment.emoji)
                .fontSize(SUMMARY_EMOJI_SIZE)
              if (segment.count > 1) {
                Text(`${segment.count}`)
                  .fontSize(SUMMARY_COUNT_SIZE)
                  .fontWeight(TITLE_FONT_WEIGHT)
                  .fontFeature('"tnum" on')
                  .fontColor(Color.White)
              }
            }
          }, (segment: PreviewReactionSegment) => `${segment.emoji}${segment.count}`)
        }
        .id('mediaPreviewReactions')
        // ponytail: every segment is shown and the capsule clips at the summary width; 4.21
        // folds the overflow into "+N", add that when a message carries more than ~7 emojis.
        .constraintSize({ minHeight: SUMMARY_MIN_HEIGHT, maxWidth: this.summaryMaxWidth })
        .clip(true)
        .padding({
          start: LengthMetrics.vp(SUMMARY_H_PADDING),
          end: LengthMetrics.vp(SUMMARY_H_PADDING),
          top: LengthMetrics.vp(SUMMARY_V_PADDING),
          bottom: LengthMetrics.vp(SUMMARY_V_PADDING)
        })
        .backgroundColor(PREVIEW_GLASS_TINT)
        .backdropBlur(PREVIEW_GLASS_BLUR)
        .borderWidth(PREVIEW_GLASS_STROKE_WIDTH)
        .borderColor(PREVIEW_GLASS_STROKE)
        .borderRadius(SUMMARY_MIN_HEIGHT / 2)
        .accessibilityGroup(true)
        .accessibilityText($r('app.string.accessibility_message_reactions'))
      }
    }
    .width('100%')
  }
}
