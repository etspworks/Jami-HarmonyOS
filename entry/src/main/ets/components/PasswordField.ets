/*
 * comp_password_field — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct PasswordFieldView` (line 175):
 *
 *   HStack {
 *     Group { if isVisible { TextField(placeholder, text: $text) }
 *             else         { SecureField(placeholder, text: $text) } }
 *       .disableAutocorrection(true).autocapitalization(.none)
 *     Spacer()
 *     Button { isVisible.toggle() } label: { Image(systemName: isVisible ? "eye" : "eye.slash") }
 *       .accessibilityIdentifier("passwordVisibilityToggle")
 *   }
 *
 * The visibility flag belongs to the field, exactly as in the source; the password itself is the
 * caller's (`@Binding var text`). The field's OWN accessibilityIdentifier is supplied per call
 * site (`var identifier: String = ""`), so the slug in `.id()` is always the source element's.
 */
import { LengthMetrics } from '@kit.ArkUI';

/**
 * The secure field's dots (T-1636). ArkUI draws the obscuring bullet with the field's font size,
 * family and weight, but it ignores letterSpacing: -6fp tracking left the BRA-AL00 pitch at 16 vp
 * (7.0.0.109). The default font's bullet is 1 em wide (16 vp at Body_L, dot 3.7 vp). HarmonyOS
 * Sans Condensed Bold at 21 fp draws a 10.2 vp pitch with a 6.5 vp dot. The iOS SecureField
 * draws a 10.2 pt pitch with a 7.3 pt dot (T-0692 ref, 3x: 125/155/186/217 px).
 * ponytail: tuned to that system font. A device without it falls back to the 1 em bullet at
 * 21 fp; if one turns up, change the family here.
 */
const SECURE_DOT_FONT_SIZE: number = 21;
const SECURE_DOT_FONT_FAMILY: string = 'HarmonyOS Sans Condensed';

@Component
export struct PasswordFieldView {
  /** Swift `@Binding var text: String`. */
  @Link text: string;
  /** Swift `var placeholder: String`. */
  placeholder: ResourceStr = '';
  /** Swift `var identifier: String = ""` — the call site's accessibilityIdentifier. */
  identifier: string = '';
  /*
   * Swift `WalkthroughPasswordView` declares `var backgroundColor: Color =
   * Color(UIColor.secondarySystemGroupedBackground)` and paints the pill with it; the default
   * below is what AccountMigrationView's capture measured (#F2F2F7) for the one call site that
   * instantiates PasswordFieldView directly on a WHITE page. On a page that is already grouped
   * gray (the walkthrough sheets) the pill is the lighter card colour, or it disappears into
   * the page — so the call site passes it, exactly as the Swift call site does.
   */
  pillBackground: ResourceColor = $r('sys.color.comp_background_gray');
  /**
   * The pill's horizontal inset and corner. Swift's alert call sites style the field with
   * `textFieldStyleInAlert()` (UtilitiesViews.swift AlertFieldStyle): `.padding(.horizontal)`,
   * i.e. 16, and `.cornerRadius(8)`.
   */
  pillInset: number = 10;
  pillRadius: number = 10;
  /** Swift `@SwiftUI.State private var isVisible: Bool = false`. */
  @State private isVisible: boolean = false;
  /*
   * The field's FIRST-RESPONDER state. UIKit publishes "is editing" as a trait on the text
   * field itself, so a screen reader — and the on-device uitest dump — can tell a field being
   * edited from an idle one; ArkUI publishes nothing, so the same fact is stated here, exactly
   * as the device-verified `components/WalkthroughTextEdit.ets` states it for the walkthrough
   * fields. Additive and invisible: it changes no pixel and no control, only what the field
   * says about itself. SwiftUI's own editors for this component's call sites carry the same
   * state (`EditableFieldView.isTextFieldFocused`, UtilitiesViews.swift:341).
   */
  @State private isEditing: boolean = false;

  /** Swift: the eye button's action — `isVisible.toggle()`. */
  private toggleVisibility(): void {
    this.isVisible = !this.isVisible;
  }

  /** What the field is called while idle, and while it is the first responder. */
  private fieldHint(): Resource {
    return this.isEditing
      ? $r('app.string.accessibility_text_field_editing')
      : $r('app.string.global_password');
  }

  /*
   * S5 — style from the AccountMigrationView capture (S0090, the password state), reconciled
   * with the source. The ROUNDED GRAY PILL around the field is not PasswordFieldView's own: in
   * Swift it belongs to `WalkthroughPasswordView`, which draws
   *   RoundedRectangle(cornerRadius: 10).foregroundColor(backgroundColor)
   * behind `PasswordFieldView().padding(.horizontal, 10).padding(.vertical, 12)`.
   * AccountMigrationPage instantiates PasswordFieldView directly (its only call site in this
   * app), so the pill is carried here rather than being lost. Measured off the capture and in
   * exact agreement with those Swift values: container x 16..377 (the page's own 16 pt margin),
   * y 390.7..435.7 -> 45 high = 12 + 21 + 12; fill #F2F2F7; the field's text begins at x 27.4,
   * i.e. 10 pt inside; radius ~11 measured, and the source says 10, so 10 it is — a
   * source-hardcoded non-standard value is copied verbatim, never rounded to a token.
   */
  build() {
    Row() {
      // Swift `Group { if isVisible { TextField } else { SecureField } }`. Placeholder: iOS
      // `placeholderText` (#3C3C43 at 30%, ~#C3C6C7 on white on the iPhone); font_fourth
      // (#33182431 light, ~#D1D3D6 on white) is the nearest theme token (T-1601).
      if (this.isVisible) {
        TextInput({ placeholder: this.placeholder, text: $$this.text })
          .type(InputType.Normal)
          .enableAutoFill(true)
          .layoutWeight(1)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .placeholderFont({ size: $r('sys.float.Body_L') })
          .caretColor($r('app.color.jami'))
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding(0)
          .accessibilityDescription(this.fieldHint())
          .onFocus(() => {
            this.isEditing = true;
          })
          .onBlur(() => {
            this.isEditing = false;
          })
          .id(this.identifier)
      } else {
        TextInput({ placeholder: this.placeholder, text: $$this.text })
          .type(InputType.Password)
          .showPasswordIcon(false)
          .enableAutoFill(true)
          .layoutWeight(1)
          // Only while there are dots: the placeholder keeps the regular Body_L font.
          .fontSize(this.text.length > 0 ? SECURE_DOT_FONT_SIZE : $r('sys.float.Body_L'))
          .fontFamily(this.text.length > 0 ? SECURE_DOT_FONT_FAMILY : undefined)
          .fontWeight(this.text.length > 0 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .placeholderFont({ size: $r('sys.float.Body_L') })
          .caretColor($r('app.color.jami'))
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding(0)
          .accessibilityDescription(this.fieldHint())
          .onFocus(() => {
            this.isEditing = true;
          })
          .onBlur(() => {
            this.isEditing = false;
          })
          .id(this.identifier)
      }
      // Swift `Spacer()` — the eye sits at the trailing edge; layoutWeight(1) above does that.
      // Capture: the glyph is #8A8A8E (secondaryLabel), ~26x20 at x 340..366, which is the
      // 10 pt trailing inset below. Swift: `.foregroundColor(.gray)`.
      SymbolGlyph(this.isVisible ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
        .fontSize(22)
        .fontColor([$r('app.color.secondary_label')])
        .id('passwordVisibilityToggle')
        // The glyph is the only thing that changes when the field is empty, so the toggle's
        // state is carried in the accessibility surface too: the label names the ACTION the tap
        // performs, the description names the CURRENT state. The Swift source labels neither
        // (the eye is a bare SF Symbol button), so this is additive and changes nothing visible.
        .accessibilityText(this.isVisible
          ? $r('app.string.accessibility_password_hide')
          : $r('app.string.accessibility_password_show'))
        // The description names the ACTION, not the state, because it is the ONLY accessibility
        // surface a HarmonyOS uitest dump exposes (`.accessibilityText()` does not appear in it
        // at all) and it is therefore the only thing the on-device drivers can locate this
        // icon-only control by besides its `.id()`. The capture records this element's iOS
        // accessibility LABEL as the locator for one of its states
        // (results/traversal-source/graph.json: S0262 `EncryptAccount/hide` and S0281
        // `EditPasswordView/hide` both carry actionPath [{type: tap, slug: "hide", desc:
        // "Hide"}]), so the value is copied from the source element rather than invented —
        // Rule 12. The two values still differ between states, which is what keeps the tap
        // detectable as a screen change by evidence_collect.tree_signature.
        .accessibilityDescription(this.isVisible
          ? $r('app.string.accessibility_password_show')
          : $r('app.string.accessibility_password_hide'))
        .onClick(() => {
          this.toggleVisibility();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // Text grows with the system font size, so the pill has a floor, not a fixed height.
    .constraintSize({ minHeight: 45 })
    .padding({
      top: LengthMetrics.vp(12),
      bottom: LengthMetrics.vp(12),
      start: LengthMetrics.vp(this.pillInset),
      end: LengthMetrics.vp(this.pillInset)
    })
    .backgroundColor(this.pillBackground)
    .borderRadius(this.pillRadius)
  }
}
