/*
 * comp_editable_field — ported from
 * Ring/Ring/Features/Settings/Me/UtilitiesViews.swift `struct EditableFieldView` (line 337):
 *
 *   @Binding var value: String
 *   var title: String
 *   var placeholder: String
 *   @SwiftUI.State private var isTextFieldFocused = true
 *   var onDisappearAction: () -> Void          // "save action on disappear"
 *   var keyboardType: UIKeyboardType = .default
 *   var validate: ((String) -> Bool)?
 *   var errorMessage: String = ""
 *
 *   footer = if let validate, !validate(value) { Text(errorMessage).foregroundColor(.red) }
 *
 *   body = Form { Section(footer: footer) {
 *              FocusableTextField(text: $value, isFirstResponder: $isTextFieldFocused,
 *                                 placeholder: placeholder,
 *                                 identifier: "editable_field_value",
 *                                 keyboardType: keyboardType) } }
 *          .navigationTitle(L10n.Global.edit + " \(title)")
 *          .onDisappear { onDisappearAction() }
 *
 * The single-field editor four screens push (screen_notifications_settings, screen_name_server,
 * screen_connectivity_settings, screen_manage_sip_account), so it carries the source's whole
 * parameter set rather than one caller's subset:
 *   - `@Binding value`      -> @Link, so the host's field follows every keystroke;
 *   - `isFirstResponder`    -> `.defaultFocus(true)`, the field takes focus as it appears;
 *   - `onDisappearAction`   -> `aboutToDisappear()`, the WRITE-BACK the source names — a host
 *                              that pops (or closes) the editor persists there, not on submit;
 *   - `keyboardType`        -> `InputType`, plus the secure variant EditPasswordView uses;
 *   - `validate`/`errorMessage` -> the footer, shown only while the value fails the check.
 *
 * `identifier: "editable_field_value"` is the source's own slug (Rule 12) and is kept verbatim.
 */

import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, from the source's iOS Form idiom (UtilitiesViews.swift:337) ──────── */
/** Swift `.foregroundColor(.red)` on the section footer — the iOS system red. */
const ERROR_RED: string = '#FF3B30';
/** An inset-grouped Form row: 44vp minimum, content inset to the card's own padding. */
const FIELD_ROW_MIN_HEIGHT: number = 44;

@Component
export struct EditableFieldView {
  /** Swift `@Binding var value: String` — the host's field, two-way. */
  @Link value: string;
  /** Swift `var title: String` — the pushed editor's navigation title. */
  title: ResourceStr = '';
  /** Swift `.navigationTitle(...)` exists only where the editor is pushed as its own screen. */
  showsTitle: boolean = false;
  /** Swift `var placeholder: String`. */
  placeholder: ResourceStr = '';
  /** Swift `var keyboardType: UIKeyboardType = .default`. */
  inputType: InputType = InputType.Normal;
  /** Swift `EditPasswordView`'s secure sibling of the same editor. */
  isSecure: boolean = false;
  /** Swift `var errorMessage: String` — the footer's text while `validate` fails. */
  errorMessage: ResourceStr = '';
  /** Swift `var validate: ((String) -> Bool)?` — no validator means nothing to fail. */
  validate?: (value: string) => boolean;
  /** Swift `onDisappearAction: () -> Void` — the save the host performs on disappear. */
  onDisappearAction?: () => void;

  /** Swift `.onDisappear { onDisappearAction() }`. */
  aboutToDisappear(): void {
    const save: (() => void) | undefined = this.onDisappearAction;
    if (save !== undefined) {
      save();
    }
  }

  /** Swift `if let validate = validate, !validate(value)`. */
  private isInvalid(): boolean {
    const check: ((value: string) => boolean) | undefined = this.validate;
    if (check === undefined) {
      return false;
    }
    return !check(this.value);
  }

  build() {
    // S5 — Swift `Form { Section(footer:) { FocusableTextField } }`: one white grouped card
    // holding the field, the footer beneath it indented to the card's content edge.
    Column() {
      // Swift `.navigationTitle(L10n.Global.edit + " \(title)")`.
      if (this.showsTitle) {
        Text(this.title)
          .width('100%')
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          .textAlign(TextAlign.Center)
          .padding({
            top: LengthMetrics.resource($r('sys.float.padding_level4')),
            bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
          })
      }

      // Swift `FocusableTextField(text:isFirstResponder:placeholder:identifier:keyboardType:)`.
      TextInput({ placeholder: this.placeholder, text: this.value })
        .id('editable_field_value')
        .type(this.isSecure ? InputType.Password : this.inputType)
        .width('100%')
        .constraintSize({ minHeight: FIELD_ROW_MIN_HEIGHT })
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .placeholderFont({ size: $r('sys.float.Body_L') })
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        })
        // Swift `isFirstResponder = true` — the field is focused as the editor appears.
        .defaultFocus(true)
        .onChange((updated: string) => {
          this.value = updated;
        })

      // Swift `Section(footer: footer)` — the error line, only while the value fails.
      if (this.isInvalid()) {
        Text(this.errorMessage)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor(ERROR_RED)
          .padding({
            start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
            end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
            top: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // iOS insetGrouped Form: the card sits 20 pt in from each edge (T-0674 ref, field x=20).
    .padding({
      start: LengthMetrics.resource($r('sys.float.padding_level10')),
      end: LengthMetrics.resource($r('sys.float.padding_level10')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
    })
  }
}
