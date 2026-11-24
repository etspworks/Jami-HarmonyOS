/*
 * comp_numeric_text_field — ported from
 * Ring/Ring/Features/Settings/Me/GeneralSettingsViews.swift `struct TextFieldWithDoneButton`
 * (UIViewRepresentable, line 24) and its `Coordinator` (line 74):
 *
 *   @Binding var text: String
 *   var onEditingChanged: (Bool) -> Void
 *   var onDone: () -> Void
 *   var onCancel: () -> Void
 *   var keyboardType: UIKeyboardType = .default
 *
 *   makeUIView:   a UITextField with `accessibilityIdentifier = "settings_numeric_text_field"`,
 *                 `keyboardType`, `textAlignment = .right`, and an inputAccessoryView UIToolbar
 *                 holding [cancel, flexSpace, done].
 *   updateUIView: pushes `text` in.
 *   Coordinator:  textFieldDidBeginEditing -> `originalValue = textField.text`, then
 *                                             `onEditingChanged(true)`
 *                 textFieldDidChangeSelection -> `parent.text = textField.text`
 *                 textFieldDidEndEditing -> `onEditingChanged(false)`
 *                 donePressed  -> `parent.onDone()`
 *                 cancelPressed -> `parent.text = originalValue`, then `parent.onCancel()`
 *
 * TWO parts of that live in the CALLER, not here, and both are deliberate:
 *
 * 1. The toolbar. iOS attaches it to the keyboard (`inputAccessoryView`), so it is drawn at
 *    the bottom of the SCREEN, full width, over everything — the capture has it at
 *    [0,808][393,852] with the keyboard down and [0,517][393,561] with it up. A child
 *    component cannot draw outside its parent's box, so the page renders the toolbar row in
 *    its own bottom-aligned Stack slot, gated on the same editing flag this component reports.
 *
 * 2. `originalValue`. Swift's Coordinator holds it and `cancelPressed` writes it back through
 *    the BINDING — i.e. the value's owner restores it, not the field. Here the page is that
 *    owner (the same `@Prop` + callback contract `comp_toggle_cell` uses), so this component
 *    HANDS the original up at the moment the Coordinator captures it, and the page's cancel
 *    handler writes it back. One writer, and it is the page.
 *
 * `shouldMoveCursorToEnd` has no counterpart: it exists because UIKit places the caret where
 * updateUIView left it; ArkUI's TextInput places it at the tap, which is the behaviour the
 * flag was restoring.
 *
 * S3 — structure only. No colours, spacing or typography here; the call site styles its row.
 *
 * S5 — measured off results/traversal-source/pages/FileTransferSettingsView/base.ui.json and
 * .../settings_numeric_text_field.ui.json (393x852). The field's frame is [195,201][353,257] —
 * the right half of a 64 tall grouped row — and it draws NO chrome of its own: the capture
 * shows the value alone, right-aligned, on the card's white. So every default ArkUI TextInput
 * decoration (its filled background, its own padding, its corner radius) is cleared here, and
 * only Swift's own three attributes survive: `textAlignment = .right`, `textColor` and the
 * `.numberPad` keyboard.
 *
 * `textColor` is Swift's `var textColor: UIColor = .label` — a PARAMETER of
 * TextFieldWithDoneButton, passed by the call site
 * (`model.automaticlyDownloadIncomingFiles ? UIColor(Color.jami) : UIColor.secondaryLabel`),
 * which is why it is a prop here rather than a constant: the owner of the value owns its
 * colour, exactly as it owns `text`.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'NumericTextField';
/**
 * The field's own box inside the row. The capture's frame is 56 tall in a 64 tall row, but
 * that is UIKit's hit area around a single line of text; 40 leaves the row at the measured
 * 64 once its own 11 of vertical padding is added, with the text on the label's baseline.
 */
const FIELD_HEIGHT: number = 40;

@Component
export struct NumericTextField {
  /** Swift `@Binding var text: String` — read-only here; the parent is the single writer. */
  @Prop text: string = '';
  /** Swift `textField.accessibilityIdentifier` — the SOURCE slug, set by the call site. */
  identifier: string = '';
  /** Swift `keyboardType: UIKeyboardType` — `.numberPad` at this call site. */
  inputType: InputType = InputType.Number;
  /** Swift `var textColor: UIColor = .label` — the call site's, defaulted to `.label`. */
  textColor: ResourceColor = $r('app.color.label');

  /** Swift `Coordinator.textFieldDidChangeSelection` -> `parent.text = textField.text`. */
  onTextChange: (value: string) => void = (value: string): void => {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'text changed to %{public}s with no writer wired', value);
  };

  /**
   * Swift `Coordinator.textFieldDidBeginEditing`: captures `originalValue` and calls
   * `onEditingChanged(true)`. Both halves in one callback — the captured value is handed to
   * the owner because the owner is what `cancelPressed` restores through.
   */
  onBeginEditing: (originalValue: string) => void = (originalValue: string): void => {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'editing began at %{public}s with no owner wired',
      originalValue);
  };

  /** Swift `Coordinator.textFieldDidEndEditing` -> `onEditingChanged(false)`. */
  onEndEditing: () => void = (): void => {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'editing ended with no owner wired');
  };

  build() {
    // Swift `makeUIView` — one UITextField.
    TextInput({ text: this.text })
      .id(this.identifier)
      .type(this.inputType)
      .enableKeyboardOnFocus(true)
      // Swift `textField.textAlignment = .right`: the value sits against the row's right
      // edge (capture — "20" ends at x 353, the card's own content edge).
      .textAlign(TextAlign.End)
      // Swift `textField.textColor`.
      .fontColor(this.textColor)
      .caretColor(this.textColor)
      // A bare UITextField has no fill, no border and no rounding — it is the card's white
      // showing through. ArkUI's TextInput supplies all three by default, so all three go.
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .padding(0)
      // The grouped row's `.label` body, the same weight the label opposite it carries.
      .fontSize($r('sys.float.Body_L'))
      .height(FIELD_HEIGHT)
      .width('100%')
      .onChange((value: string) => {
        this.onTextChange(value);
      })
      .onFocus(() => {
        // The value as it stood when editing began — what a later cancel restores.
        this.onBeginEditing(this.text);
      })
      .onBlur(() => {
        this.onEndEditing();
      })
  }
}
