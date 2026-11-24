/*
 * comp_walkthrough_text_edit — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct WalkthroughTextEditView` (line 38):
 *
 *   TextField(placeholder, text: $text)
 *     .autocorrectionDisabled(true).autocapitalization(.none)
 *     .accessibilityIdentifier(identifier)
 *     .background(secondarySystemGroupedBackground).cornerRadius(10)
 *
 * S4: the source's `.onChange(of: name) { viewModel.usernameUpdated(to: $0) }` lives on the
 * CALLER (CreateAccountView), so the field forwards each edit through `onTextChange` rather
 * than knowing about any view model.
 *
 * CreateAccountView uses its focusable twin (`WalkthroughFocusableTextView`, same field with
 * a first-responder binding); that binding is `isFocused`, driven both ways like
 * UtilitiesViews.swift `FocusableTextField.updateUIView`.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export struct WalkthroughTextEditView {
  /** Swift `@Binding var text: String`. */
  @Link text: string;
  /** Swift `var placeholder: String`. */
  placeholder: ResourceStr = '';
  /** Swift `var identifier: String`. */
  identifier: string = '';
  /**
   * Swift `WalkthroughFocusableTextView`'s `@Binding var isTextFieldFocused: Bool`, handed to
   * `FocusableTextField(isFirstResponder:)`. The field raises it when it takes focus and
   * drops it on blur; the caller lowers it when it moves focus away itself
   * (CreateAccountView.swift:208, the encrypt button).
   */
  @Link @Watch('applyFocus') isFocused: boolean;
  /** Whether the TextInput holds focus now, so the field's own onFocus/onBlur are not replayed. */
  private hasFocus: boolean = false;
  /**
   * Swift: the caller's `.onChange(of: text)`. The default is never silent — a field wired
   * with no listener is an edit nobody reacts to, so it says so in the log.
   */
  onTextChange: (value: string) => void = (value: string): void => {
    hilog.debug(0x0001, 'WalkthroughTextEdit', 'edited with no listener wired (%{public}d chars)',
      value.length);
  };

  /**
   * The caller's own screen-reader description. Unset or '' gives none, so the field speaks its
   * placeholder or text the way a UIKit TextField with no label does: no walkthrough field in
   * the source carries one. CreateAccountView puts its username prompt on a hidden footer label
   * UNDER the field (`footerView`), not on the field (T-1663; iOS AXLabel null, focused or not).
   */
  spokenText?: ResourceStr;

  /**
   * `spokenText` resolved to a `string`: `accessibilityDescription` is an OVERLOAD pair
   * (`string` | `Resource`) and a `ResourceStr` union matches neither.
   */
  private spokenDescription(): string {
    const text: ResourceStr = this.spokenText ?? '';
    return typeof text === 'string' ? text : getContext(this).resourceManager.getStringSync(text.id);
  }

  /**
   * Swift `FocusableTextField.updateUIView`: resign at once when the binding drops, become
   * first responder 0.5 s later ("wait until view shows") when it rises — on first appear the
   * field sits in a CustomDialog that is still opening.
   */
  private applyFocus(_propName?: string): void {
    if (this.isFocused === this.hasFocus || this.identifier.length === 0) {
      return;
    }
    const focus = this.getUIContext().getFocusController();
    if (!this.isFocused) {
      focus.clearFocus();
      return;
    }
    setTimeout(() => {
      if (!this.isFocused || this.hasFocus) {
        return;
      }
      try {
        focus.requestFocus(this.identifier);
      } catch (e) {
        hilog.warn(0x0001, 'WalkthroughTextEdit', 'requestFocus(%{public}s) refused: %{public}s',
          this.identifier, JSON.stringify(e));
      }
    }, 500);
  }

  build() {
    // S5 — style. Swift pins this field's look itself: `.padding(.horizontal, 10)`,
    // `.padding(.vertical, 12)`, `.background(secondarySystemGroupedBackground)` (white on a
    // grouped page) and `.cornerRadius(10)` — hardcoded values, copied verbatim rather than
    // tokenised, exactly as the design-token rule allows.
    TextInput({ placeholder: this.placeholder, text: $$this.text })
      .width('100%')
      .fontSize($r('sys.float.Body_L'))
      .fontColor($r('app.color.label'))
      .placeholderColor($r('app.color.placeholder_text'))
      .placeholderFont({ size: $r('sys.float.Body_L') })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(10)
      .padding({ left: 10, right: 10, top: 12, bottom: 12 })
      .onChange((value: string) => {
        this.onTextChange(value);
      })
      // Swift `FocusableTextField`'s first-responder binding, both directions.
      .onFocus(() => {
        this.hasFocus = true;
        this.isFocused = true;
      })
      .onBlur(() => {
        this.hasFocus = false;
        this.isFocused = false;
      })
      .onAppear(() => {
        this.applyFocus();
      })
      .accessibilityDescription(this.spokenDescription())
      .id(this.identifier)
  }
}
