/*
 * comp_action_button — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct ActionButton` (line 244):
 *
 *   Button(action: action) { Text(title) ... .background(.jamiTertiaryControl).cornerRadius(10) }
 *     .accessibilityIdentifier("walkthroughActionButton")
 *
 * The walkthrough's filled full-width button. Its source call sites are `SuccessStateView`
 * and `ErrorStateView` (Views.swift:216, :236) — the state panels the walkthrough shows after
 * an account operation finishes.
 */
/* ── S5: the values Views.swift:244 spells itself ─────────────────────────────────────────
 * `.background(.jamiTertiaryControl).cornerRadius(10)` with the label in the ordinary text
 * colour — the filled walkthrough button the capture shows on every state panel.
 */
const BUTTON_RADIUS: number = 10;
const BUTTON_HEIGHT: number = 44;

@Component
export struct ActionButton {
  /** Swift `let title: String`. */
  title: ResourceStr = '';
  /** Swift `.accessibilityIdentifier("walkthroughActionButton")`, overridable per call site. */
  identifier: string = 'walkthroughActionButton';
  /** Swift `let action: () -> Void`. */
  action: () => void = () => {
    console.debug('ActionButton: no action supplied');
  };

  build() {
    Button(this.title)
      .width('100%')
      .height(BUTTON_HEIGHT)
      .type(ButtonType.Normal)
      .borderRadius(BUTTON_RADIUS)
      .backgroundColor($r('app.color.jami_tertiary_control'))
      .fontSize($r('sys.float.Body_L'))
      .fontColor($r('app.color.label'))
      .id(this.identifier)
      .onClick(() => {
        this.action();
      })
  }
}
