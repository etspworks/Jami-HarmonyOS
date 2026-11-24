/*
 * comp_saved_toast — ported from
 *   Ring/Ring/Features/Conversations/Preview/MediaPreviewView.swift `private struct SavedToast`
 *   (line 415):
 *
 *     HStack(spacing: 8) {
 *         Image(systemName: "checkmark")
 *         Text(L10n.Conversation.imageSaved)
 *     }
 *     .foregroundColor(.white)
 *     .padding(.horizontal, 16)
 *     .frame(height: 40)
 *     .glassCapsuleBackground()
 *     .accessibilityElement(children: .combine)
 *
 * No control of its own — MediaPreviewOverlay renders it while `model.saveSuccess` holds
 * (conditionalVariants[saved_toast]) and lowers it again after the source's 2s delay.
 *
 * The checkmark is `sys.symbol.checkmark`, the exact match results/plan/icon-map.json resolved
 * for the source's `checkmark` SF Symbol.
 *
 * S5 (NO CAPTURE — styled from the source's own metrics):
 *   checkmark .font(.system(size: 14, weight: .semibold)); label .font(.system(size: 15,
 *   weight: .medium)); both .foregroundColor(.white); .glassCapsuleBackground() =
 *   UIBlurEffect(.dark) + LinearGradient(black 0.05 -> 0.2).opacity(0.5), Capsule-clipped,
 *   overlaid with white 0.2 stroke, lineWidth 0.5 (MediaViewHelpers.swift:25).
 */
import { LengthMetrics } from '@kit.ArkUI';

/** Swift `HStack(spacing: 8)`. */
const TOAST_GAP: number = 8;
/** Swift `.frame(height: 40)`. */
const TOAST_HEIGHT: number = 40;
/** Swift `.padding(.horizontal, 16)`. */
const TOAST_INSET: number = 16;
/** Swift `Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))`. */
const CHECK_GLYPH_SIZE: number = 14;
/** Swift `Text(...).font(.system(size: 15, weight: .medium))`. */
const TOAST_FONT_SIZE: number = 15;
/** Swift `LinearGradient(black 0.05 -> 0.2).opacity(0.5)` over the dark blur — its midpoint. */
const GLASS_TINT: string = '#1A000000';
/** Swift `shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5)`. */
const GLASS_STROKE: string = '#33FFFFFF';
const GLASS_STROKE_WIDTH: number = 0.5;

@Component
export struct SavedToast {
  build() {
    Row({ space: TOAST_GAP }) {
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(CHECK_GLYPH_SIZE)
        .fontWeight(FontWeight.Medium)
        // Swift `.foregroundColor(.white)` on the whole HStack.
        .fontColor([Color.White])

      Text($r('app.string.conversation_image_saved'))
        .fontSize(TOAST_FONT_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .id('mediaPreviewSavedToast')
    // The label scales with the system font size, so the 40 pt frame is a floor, not a cap.
    .constraintSize({ minHeight: TOAST_HEIGHT })
    .padding({ start: LengthMetrics.vp(TOAST_INSET), end: LengthMetrics.vp(TOAST_INSET) })
    .alignItems(VerticalAlign.Center)
    // Swift `.glassCapsuleBackground()`.
    .backgroundColor(GLASS_TINT)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
    .borderWidth(GLASS_STROKE_WIDTH)
    .borderColor(GLASS_STROKE)
    .borderRadius(TOAST_HEIGHT / 2)
  }
}
