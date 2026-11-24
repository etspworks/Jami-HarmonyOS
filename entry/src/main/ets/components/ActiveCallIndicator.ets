/*
 * comp_active_call_indicator — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 * `struct ActiveCallIndicator` (line 144): the pulsing phone glyph a smart-list row shows
 * while its conversation has a live call.
 *
 * S5 style, verbatim from the source:
 *   Image(systemName: "phone")                     -> sys.symbol.phone (icon-map: exact)
 *     .font(.system(size: 18, weight: .semibold))
 *     .foregroundColor(.jami)                      -> app.color.jami
 *     .padding(.horizontal)                        -> 16 vp each side
 *     .opacity(isAnimating ? 0.4 : 1.0) driven by
 *     Animation.easeInOut(duration: 1).repeatForever(autoreverses: true)
 */
/** Swift `.font(.system(size: 18, weight: .semibold))`. */
const GLYPH_SIZE: number = 18;
/** Swift `Animation.easeInOut(duration: 1)`. */
const PULSE_DURATION: number = 1000;
const PULSE_MIN_OPACITY: number = 0.4;

@Component
export struct ActiveCallIndicator {
  /** Swift `@SwiftUI.State private var isAnimating`. */
  @State private pulse: number = 1.0;

  aboutToAppear(): void {
    // Swift `withAnimation(...repeatForever(autoreverses: true)) { isAnimating = true }`.
    animateTo({
      duration: PULSE_DURATION,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.pulse = PULSE_MIN_OPACITY;
    });
  }

  build() {
    SymbolGlyph($r('sys.symbol.phone'))
      .fontSize(GLYPH_SIZE)
      .fontWeight(FontWeight.Medium)
      .fontColor([$r('app.color.jami')])
      .opacity(this.pulse)
      .margin({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })
  }
}
