/*
 * comp_walkthrough_password — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct WalkthroughPasswordView` (line 21), which is a rounded box around
 * Ring/Ring/Features/Settings/Me/UtilitiesViews.swift `struct PasswordFieldView` (line 181):
 *
 *   SecureField / TextField behind an `isVisible` toggle, with the eye / eye.slash button
 *   (accessibilityIdentifier "passwordVisibilityToggle") at the trailing edge.
 *
 * The visibility state belongs to the field, exactly as in the source; the password itself
 * stays the caller's.
 */

/**
 * The secure field's dots (T-1659), the same as PasswordField.ets after 8099da9 (T-1636). ArkUI
 * ignores letterSpacing on obscured text, so the 1 em bullet stays 16 vp apart at Body_L.
 * HarmonyOS Sans Condensed Bold at 21 fp draws a 10.2 vp pitch, the iOS SecureField's 10.2 pt.
 * ponytail: tuned to that system font; change the family here and in PasswordField together.
 */
const SECURE_DOT_FONT_SIZE: number = 21;
const SECURE_DOT_FONT_FAMILY: string = 'HarmonyOS Sans Condensed';

@Component
export struct WalkthroughPasswordView {
  /** Swift `@Binding var text: String`. */
  @Link text: string;
  /** Swift `var placeholder: String`. */
  placeholder: ResourceStr = '';
  /** Swift `var identifier: String`. */
  identifier: string = '';
  /** Swift `@SwiftUI.State private var isVisible: Bool`. */
  @State private isVisible: boolean = false;

  /** Swift: `isVisible.toggle()` behind the eye button. */
  private toggleVisibility(): void {
    this.isVisible = !this.isVisible;
  }

  build() {
    // S5 — style. Swift: `ZStack { RoundedRectangle(cornerRadius: 10).foregroundColor(
    // secondarySystemGroupedBackground); PasswordFieldView().padding(.horizontal, 10)
    // .padding(.vertical, 12) }` — the rounded white box is the ROW, so the input inside it
    // carries no chrome of its own. Both values are hardcoded in the source.
    Row() {
      // Swift: `if isVisible { TextField } else { SecureField }`.
      if (this.isVisible) {
        TextInput({ placeholder: this.placeholder, text: $$this.text })
          .type(InputType.Normal)
          .layoutWeight(1)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .placeholderFont({ size: $r('sys.float.Body_L') })
          .backgroundColor(Color.Transparent)
          .padding(0)
          .id(this.identifier)
      } else {
        TextInput({ placeholder: this.placeholder, text: $$this.text })
          .type(InputType.Password)
          .showPasswordIcon(false)
          .layoutWeight(1)
          // Only while there are dots: the placeholder keeps the regular Body_L font.
          .fontSize(this.text.length > 0 ? SECURE_DOT_FONT_SIZE : $r('sys.float.Body_L'))
          .fontFamily(this.text.length > 0 ? SECURE_DOT_FONT_FAMILY : undefined)
          .fontWeight(this.text.length > 0 ? FontWeight.Bold : FontWeight.Normal)
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .placeholderFont({ size: $r('sys.float.Body_L') })
          .backgroundColor(Color.Transparent)
          .padding(0)
          .id(this.identifier)
      }
      // Swift `PasswordFieldView`: the eye is `.foregroundColor(.gray)`, `.padding(.leading, 10)`.
      SymbolGlyph(this.isVisible ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
        .fontSize(18)
        .fontColor([$r('app.color.secondary_label')])
        .margin({ left: 10 })
        .id('passwordVisibilityToggle')
        .onClick(() => {
          this.toggleVisibility();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(10)
    .padding({ left: 10, right: 10, top: 12, bottom: 12 })
  }
}
