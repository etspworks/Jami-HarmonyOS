/*
 * comp_success_state — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct SuccessStateView` (line 203):
 *
 *   VStack {
 *     Image(systemName: "checkmark.circle.fill").foregroundColor(.jamiSuccess).font(.system(size: 50))
 *     Text(message).multilineTextAlignment(.center).padding(.vertical)
 *     ActionButton(title: buttonTitle, action: action)
 *     Spacer()
 *   }
 *
 * `checkmark.circle.fill` -> sys.symbol.checkmark_circle_fill (icon-map.json: exact).
 */
import { ActionButton } from './ActionButton';

/* ── S5 metrics, the source's own (Views.swift:203-240) ─────────────────────────── */
/** Swift `.font(.system(size: 50))` on the state glyph. */
const STATE_GLYPH_SIZE: number = 50;
/** Swift `.foregroundColor(Color.jamiFailure/jamiSuccess)` — UIColor.jamiSuccess = 0x00b20b, hardcoded. */
const STATE_GLYPH_COLOR: string = '#00B20B';
/** Swift `Text(message).padding(.vertical)` / the view's `.padding(.horizontal)`. */
const STATE_INSET: number = 16;

@Component
export struct SuccessStateView {
  /** Swift `let message: String`. */
  message: ResourceStr = '';
  /** Swift `let buttonTitle: String`. */
  buttonTitle: ResourceStr = '';
  /** Swift `.accessibilityIdentifier("walkthroughActionButton")` on the ActionButton. */
  identifier: string = 'walkthroughActionButton';
  /** Swift `let action: () -> Void`. */
  action: () => void = () => {
    console.debug('SuccessStateView: no action supplied');
  };

  build() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(STATE_GLYPH_SIZE)
        .fontColor([STATE_GLYPH_COLOR])
      Text(this.message)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .margin({ top: STATE_INSET, bottom: STATE_INSET })
      ActionButton({
        title: this.buttonTitle,
        identifier: this.identifier,
        action: () => {
          this.action();
        }
      })
      Blank()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.padding(.horizontal)` on the state view.
    .padding({ left: STATE_INSET, right: STATE_INSET })
  }
}
