/*
 * comp_focusable_text_field — ported from
 * Ring/Ring/Features/Settings/Me/UtilitiesViews.swift `struct FocusableTextField`
 * (UIViewRepresentable, line 211):
 *
 *   @Binding var text: String
 *   @Binding var isFirstResponder: Bool
 *   var placeholder: String = ""
 *   var identifier: String = ""
 *   var keyboardType: UIKeyboardType = .default
 *
 *   makeUIView: a UITextField with autocorrection/autocapitalization/spellChecking off and
 *               `accessibilityIdentifier = identifier`
 *   updateUIView: pushes `text` in, resigns first responder when the binding goes false and
 *                 becomes first responder when it goes true
 *   Coordinator: textFieldDidChangeSelection -> text, DidBeginEditing -> isFirstResponder = true,
 *                DidEndEditing -> isFirstResponder = false
 *
 * ArkUI already owns the text field's lifecycle, so the whole UIViewRepresentable collapses to
 * one `TextInput` plus the two-way focus contract. `focusControl.requestFocus` keys on the
 * component's `.id()`, which is why the caller's slug is set there (Rule 12 wants it anyway).
 *
 * S3 — structure only: no colours, spacing or typography here; the two call sites
 * (screen_linked_devices, screen_connectivity_settings) style their own row.
 */
// `focusControl` is a global ArkUI namespace (ets/component/common.d.ts) — not a @kit.ArkUI export.

@Component
export struct FocusableTextField {
  /** Swift `@Binding var text: String`. */
  @Link text: string;
  /** Swift `@Binding var isFirstResponder: Bool` — two-way, exactly as the Coordinator is. */
  @Link @Watch('onFirstResponderChanged') isFirstResponder: boolean;
  /** Swift `var placeholder: String = ""`. */
  placeholder: ResourceStr = '';
  /** Swift `var identifier: String = ""` — the SOURCE element's slug, set by the call site. */
  identifier: string = '';
  /** Swift `var keyboardType: UIKeyboardType = .default`. */
  inputType: InputType = InputType.Normal;

  /** Swift `updateUIView`'s "wait until the view shows, then becomeFirstResponder". */
  aboutToAppear(): void {
    this.applyFocus();
  }

  /** Swift `updateUIView`: the binding flipping drives focus, not the other way round. */
  private onFirstResponderChanged(_propName: string): void {
    this.applyFocus();
  }

  private applyFocus(): void {
    if (this.isFirstResponder && this.identifier.length > 0) {
      focusControl.requestFocus(this.identifier);
    }
  }

  build() {
    // Swift `makeUIView` — one UITextField; `autocorrectionType/autocapitalizationType/
    // spellCheckingType = .no` have no ArkUI attribute, so nothing is emitted for them.
    TextInput({ placeholder: this.placeholder, text: this.text })
      .id(this.identifier)
      .type(this.inputType)
      .enableKeyboardOnFocus(true)
      // S5: the source is a BARE UITextField — no chrome of its own, inheriting the row's
      // `.body` on `.label`. ArkUI's TextInput defaults to a filled grey plate with a large
      // inset, which would draw a control iOS never draws, so both are cleared and the field
      // occupies exactly the line the label it replaces occupied.
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .padding(0)
      .width('100%')
      .fontSize($r('sys.float.Body_L'))
      .fontColor($r('app.color.label'))
      .placeholderColor($r('app.color.placeholder_text'))
      .caretColor($r('app.color.jami'))
      .onChange((value: string) => {
        // Swift `textFieldDidChangeSelection(_:)`.
        this.text = value;
      })
      .onFocus(() => {
        // Swift `textFieldDidBeginEditing(_:)` — guarded the same way the source guards it.
        if (!this.isFirstResponder) {
          this.isFirstResponder = true;
        }
      })
      .onBlur(() => {
        // Swift `textFieldDidEndEditing(_:)`.
        if (this.isFirstResponder) {
          this.isFirstResponder = false;
        }
      })
  }
}
