/*
 * comp_toggle_cell — ported from Ring/Ring/Extensions/View+Helpers.swift `struct ToggleCell`
 * (line 318):
 *
 *   HStack { Text(toggleText); Spacer(); Toggle("", isOn: Binding(get:set:)).labelsHidden() }
 *   .accessibilityIdentifier(identifier)
 *
 * Swift passes the toggle's value in and out through a get/set pair rather than a Binding, so
 * the cell never owns the state. `@Prop` + `onToggle` is the ArkUI form of exactly that: the
 * parent stays the single writer.
 *
 * S5 — style only. The source's `.toggleStyle(SwitchToggleStyle(tint: Color.jami))` is the
 * switch's on-colour; the label is the plain `.label` body of a 44 pt grouped row, so the cell
 * carries the row's own inset-grouped padding (it is a settings row wherever it is used).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Swift `Spacer()`'s minimum length: the gap that stays between a wrapped label and the switch. */
const LABEL_SWITCH_GAP: number = 8;

@Component
export struct ToggleCell {
  /**
   * Swift `let toggleText: String` — already resolved by the caller (it can be bound data).
   * `@Prop`, not a plain field: SwiftUI re-renders the cell when the parent's text changes (the
   * account status flips to Offline the moment the enable switch goes off); a plain field is
   * read once at creation and would keep the old text until the page is rebuilt.
   */
  @Prop toggleText: ResourceStr = '';
  /** Swift `getAction() -> Bool`. */
  @Prop isOn: boolean = false;
  /**
   * Swift `setAction(Bool)`. The default is never silent: a cell wired with no setter is a
   * dead switch, so it says so in the log rather than swallowing the change.
   */
  onToggle: (value: boolean) => void = (value: boolean): void => {
    hilog.warn(0x0001, 'ToggleCell', 'toggled to %{public}s with no setter wired',
      String(value));
  };
  /** Swift `var identifier: String` — the cell's stable accessibility identifier. */
  identifier: string = '';

  build() {
    // Swift `HStack { Text; Spacer(); Toggle }`: the label takes the width the switch leaves and
    // wraps; the switch never shrinks, so a long label cannot push it past the card edge.
    Row({ space: LABEL_SWITCH_GAP }) {
      Text(this.toggleText)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
      // Swift `SwitchToggleStyle(tint: Color.jami)`.
      //
      // S6: the identifier goes on the SWITCH, which is where Swift puts it
      // (`.accessibilityIdentifier(...)` is applied to the Toggle, after `.labelsHidden()`,
      // not to the enclosing HStack). Two consequences on device, both wanted: a driver that
      // resolves the slug and taps the node's centre lands on the switch instead of on the
      // middle of the row, where nothing happens; and the switch stops being an anonymous
      // interactive leaf, which is what `control-invented` reports a framework-drawn control
      // as. The row keeps the label, so the combined element still reads as one cell.
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.jami'))
        .flexShrink(0)
        .id(this.identifier)
        .onChange((value: boolean) => {
          this.onToggle(value);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      top: $r('sys.float.padding_level6'),
      bottom: $r('sys.float.padding_level6')
    })
  }
}
