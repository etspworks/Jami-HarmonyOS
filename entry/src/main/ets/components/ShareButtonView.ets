/*
 * comp_share_button_view — ported from
 *   Ring/jamiShareExtension/ShareView.swift `struct ShareButtonView` (line 418):
 *
 *   VStack { HStack { Spacer()
 *       Button { announce(sending); onSend() } label: {
 *           HStack(spacing: 8) { Image(systemName: "paperplane.fill") ; Text(buttonText).bold() }
 *       }
 *       Spacer() } }
 *   .accessibilityIdentifier(ShareExtensionAccessibilityIdentifiers.shareButton)  // share_send_button
 *
 *   buttonText = selectedCount == 1 ? L10n.ShareExtension.sendToConversation(count)
 *                                   : L10n.ShareExtension.sendToConversationsPlural(count)
 *
 * The caller renders it only while `!selectedConversationIds.isEmpty && !isSending`
 * (conditionalVariants[has_selection]), so the button is ABSENT without a selection rather
 * than disabled — which is what the source does.
 *
 * `paperplane.fill` maps to sys.symbol.paperplane_fill, turned to the SF heading.
 *
 * S5 (NO CAPTURE — the source's own, `ShareButtonStyle` ShareView.swift:457):
 *   .padding(.horizontal, 20).padding(.vertical, 12)
 *   .background(LinearGradient(accentColor -> accentColor.opacity(0.9)).clipShape(Capsule())
 *               + Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
 *   .foregroundColor(.white).shadow(color: accentColor.opacity(0.3), radius: 2, y: 2)
 * The share extension's accent is its AccentColor asset, #005599 / dark #007BCF, which is
 * `app.color.jami_button_primary`. A two-stop gradient
 * from a colour to 90% of itself is not visibly a gradient, so the capsule takes the flat
 * accent fill plus the white hairline the source draws over it.
 */
import { LengthMetrics } from '@kit.ArkUI';

/** Swift `HStack(spacing: 8)` inside the label. */
const LABEL_GAP: number = 8;
/** Swift `.padding(.horizontal, 20).padding(.vertical, 12)` of ShareButtonStyle. */
const BUTTON_INSET_H: number = 20;
const BUTTON_INSET_V: number = 12;
/** Swift `Image(systemName: "paperplane.fill")` at SwiftUI's default body size. */
const GLYPH_SIZE: number = 17;
/** sys.symbol.paperplane_fill turned to SF `paperplane.fill`'s up-right heading. */
const PAPERPLANE_SF_ANGLE: number = 45;
/** Swift `Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1)`. */
const CAPSULE_STROKE: string = '#33FFFFFF';
const CAPSULE_STROKE_WIDTH: number = 1;
/** Swift `.shadow(color: Color.accentColor.opacity(0.3), radius: 2, x: 0, y: 2)`. */
const BUTTON_SHADOW_RADIUS: number = 2;
const BUTTON_SHADOW_OFFSET_Y: number = 2;
const BUTTON_SHADOW_COLOR: string = '#4D00345F';
/** The button's own minimum hit target. */
const BUTTON_MIN_HEIGHT: number = 44;

@Component
export struct ShareButtonView {
  /** Swift `let selectedCount: Int` — the button says how many rooms it sends to. */
  @Prop selectedCount: number = 0;
  /** Swift `let isSending: Bool`. */
  @Prop isSending: boolean = false;
  /** Swift `let onSend: () -> Void` -> `sendSelected()`. */
  onSend?: () => void;

  /** Swift `private var buttonText` — singular for one room, plural for the rest. */
  private buttonText(): ResourceStr {
    return this.selectedCount === 1
      ? $r('app.string.share_extension_send_to_conversation', this.selectedCount)
      : $r('app.string.share_extension_send_to_conversations_plural', this.selectedCount);
  }

  build() {
    Row() {
      Blank()

      Button() {
        Row({ space: LABEL_GAP }) {
          SymbolGlyph($r('sys.symbol.paperplane_fill'))
            .fontSize(GLYPH_SIZE)
            // Swift `.foregroundColor(.white)` on the whole label.
            .fontColor([Color.White])
            // The HarmonyOS paperplane points straight up; SF `paperplane.fill` points up-right.
            .rotate({ angle: PAPERPLANE_SF_ANGLE })

          // Swift `Text(buttonText).fontWeight(.semibold)`.
          Text(this.buttonText())
            .fontWeight(600)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('sys.color.font_on_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(VerticalAlign.Center)
        .padding({
          start: LengthMetrics.vp(BUTTON_INSET_H),
          end: LengthMetrics.vp(BUTTON_INSET_H),
          top: LengthMetrics.vp(BUTTON_INSET_V),
          bottom: LengthMetrics.vp(BUTTON_INSET_V)
        })
      }
      .id('share_send_button')
      .accessibilityText($r('app.string.share_extension_accessibility_send_button'))
      // Swift `ShareButtonStyle` — a capsule in the extension's accent, hairline and shadow.
      .type(ButtonType.Capsule)
      .padding(0)
      .constraintSize({ minHeight: BUTTON_MIN_HEIGHT })
      .backgroundColor($r('app.color.jami_button_primary'))
      .borderWidth(CAPSULE_STROKE_WIDTH)
      .borderColor(CAPSULE_STROKE)
      .shadow({
        radius: BUTTON_SHADOW_RADIUS,
        color: BUTTON_SHADOW_COLOR,
        offsetY: BUTTON_SHADOW_OFFSET_Y
      })
      .onClick(() => {
        const handler: (() => void) | undefined = this.onSend;
        if (handler !== undefined) {
          handler();
        }
      })

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
