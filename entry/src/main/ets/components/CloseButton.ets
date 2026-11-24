/*
 * comp_close_button — ported from Ring/Ring/Extensions/View+Helpers.swift
 * `struct CloseButton` (line 265):
 *
 *   Button(action: { action() }, label: {
 *     Image(systemName: "xmark")
 *       .font(.system(size: 12, weight: .bold))
 *       .foregroundColor(.black)
 *       .padding(10)                                  // increases the tap area
 *       .background(Circle().fill(Color.gray.opacity(0.4)))
 *       .accessibilityIdentifier(accessibilityIdentifier)
 *       .accessibilityLabel(L10n.Accessibility.close)
 *       .padding()
 *   })
 *
 * Both of the source's stored properties are ports: the caller supplies the dismiss action AND
 * the accessibility identifier, because the same component is the close affordance of several
 * screens (closeAboutView, and every other sheet that mounts it) and Rule 12 wants each of them
 * addressable under its own source slug.
 *
 * `xmark` -> sys.symbol.xmark (results/plan/icon-map.json: exact).
 */

/* ── S5 metrics, the source's own (View+Helpers.swift:265) ───────────────────────── */
/** Swift `Image(systemName: "xmark").font(.system(size: 12, weight: .bold))`. */
const CLOSE_GLYPH_SIZE: number = 12;
/** Swift `.padding(10)` inside the disc, then `.padding()` around it. */
const CLOSE_INNER_PADDING: number = 10;
/** Swift `Circle().fill(Color.gray.opacity(0.4))` — a hard-coded grey in the source. */
const CLOSE_DISC_FILL: string = '#668E8E93';
/** Swift `.foregroundColor(.black)` — black, not the semantic label colour. */
const CLOSE_GLYPH_COLOR: string = '#FF000000';

/** Swift `struct CloseButton: View`. */
@Component
export struct CloseButton {
  /** Swift `let accessibilityIdentifier: String` — the caller's Rule-12 slug for this button. */
  accessibilityIdentifier: string = 'closeButton';
  /** Swift `let action: () -> Void`. */
  onAction?: () => void;

  private fire(): void {
    const handler: (() => void) | undefined = this.onAction;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(CLOSE_GLYPH_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor([CLOSE_GLYPH_COLOR])
    }
    .id(this.accessibilityIdentifier)
    // Swift `.padding(10).background(Circle().fill(Color.gray.opacity(0.4)))`, then `.padding()`.
    .padding(CLOSE_INNER_PADDING)
    .backgroundColor(CLOSE_DISC_FILL)
    .margin($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    // Swift `.accessibilityLabel(L10n.Accessibility.close)` — the glyph carries no text.
    .accessibilityText($r('app.string.accessibility_close'))
    .onClick(() => {
      this.fire();
    })
  }
}
