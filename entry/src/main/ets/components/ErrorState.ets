/*
 * comp_error_state — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct ErrorStateView` (line 223):
 *
 *   VStack {
 *     Image(systemName: "exclamationmark.circle.fill").foregroundColor(.jamiFailure)
 *       .font(.system(size: 50))
 *     Text(message).multilineTextAlignment(.center).padding(.vertical)
 *     ActionButton(title: buttonTitle, action: action)
 *     Spacer()
 *   }
 *
 * `exclamationmark.circle.fill` -> sys.symbol.exclamationmark_circle_fill (icon-map.json: exact).
 * The message is the failure text the caller was given (AuthError.message()), never a literal.
 */
import { ActionButton } from './ActionButton';

/* ── S5 metrics, the source's own (Views.swift:203-240) ─────────────────────────── */
/** Swift `.font(.system(size: 50))` on the state glyph. */
const STATE_GLYPH_SIZE: number = 50;
/** Swift `.foregroundColor(Color.jamiFailure/jamiSuccess)` — UIColor.jamiFailure = 0xf00000, hardcoded. */
const STATE_GLYPH_COLOR: string = '#F00000';
/** Swift `Text(message).padding(.vertical)` / the view's `.padding(.horizontal)`. */
const STATE_INSET: number = 16;

@Component
export struct ErrorStateView {
  /** Swift `let message: String`. */
  message: ResourceStr = '';
  /** Swift `let buttonTitle: String`. */
  buttonTitle: ResourceStr = '';
  /** Regular as Swift's view; a host that stands it in for a system alert passes the title's bold. */
  messageWeight: FontWeight = FontWeight.Normal;
  /** Swift `.accessibilityIdentifier("walkthroughActionButton")` on the ActionButton. */
  identifier: string = 'walkthroughActionButton';
  /** Swift `let action: () -> Void`. */
  action: () => void = () => {
    console.debug('ErrorStateView: no action supplied');
  };

  build() {
    Column() {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
        .fontSize(STATE_GLYPH_SIZE)
        .fontColor([STATE_GLYPH_COLOR])
      Text(this.message)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(this.messageWeight)
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
