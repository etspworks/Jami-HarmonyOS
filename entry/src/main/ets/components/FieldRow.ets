/*
 * comp_field_row — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct FieldRowView` (line 368):
 *
 *   HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondaryLabel) }
 *
 * A read-only label/value settings row. Its real callers are the account-settings screens
 * (AccountSettingsViews.swift: proxy, name server, bootstrap, TURN); AccountSummaryView does
 * not instantiate it.
 */
/* ── S6 metrics, from the source's iOS Form idiom (UtilitiesViews.swift:368) ───────── */
/** Swift's `HStack` row inside a `Form` — the grouped-row minimum tap target. */
const FIELD_ROW_MIN_HEIGHT: number = 44;
/** Swift `Spacer()`'s minimum length: the gap that stays between the label and the value. */
const FIELD_GAP: number = 8;
/**
 * SwiftUI's HStack proposes half the row to the shorter text first, then the rest to the other:
 * the value gets at most half when the label is long too, and row − label − gap beside a short
 * label ('Current proxy | dhtproxy1.jami.net:85' stays on one line, as on iOS).
 */
const FIELD_VALUE_MIN_SHARE: number = 0.5;

@Component
export struct FieldRowView {
  /** Swift `var label: String`. */
  label: ResourceStr = '';
  /** Swift `var value: String`. @Prop so the row follows the host's state after an edit (a plain
   * member is copied once at construction and kept the old value: T-0629). */
  @Prop value: string = '';
  /** The row's own width (vp), for the value cap. 0 until the first layout. */
  @State private rowWidth: number = 0;

  /** max(half, row − label − gap); half until the row has been measured. */
  private valueMaxWidth(): Length {
    if (this.rowWidth <= 0) {
      return `${FIELD_VALUE_MIN_SHARE * 100}%`;
    }
    const ui: UIContext = this.getUIContext();
    const labelWidth: number = ui.px2vp(Number(ui.getMeasureUtils().measureText({
      textContent: this.label,
      fontSize: $r('sys.float.Body_L')
    })));
    return Math.max(this.rowWidth * FIELD_VALUE_MIN_SHARE, this.rowWidth - labelWidth - FIELD_GAP);
  }

  build() {
    // S6 — the row's own chrome comes from its host card (ManageSIPAccountPage lays the white
    // grouped card, the 16vp inset and the hairline); what belongs to the row itself is the
    // label/value type ladder: `.body` primary label, `.secondaryLabel` value trailing.
    // SwiftUI Text has no line limit here: both texts WRAP. The label takes what the value
    // leaves ("Registration expiration time (seconds)" goes to two lines), so the row never
    // overflows onto the host's chevron.
    Row({ space: FIELD_GAP }) {
      Text(this.label)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)

      // Swift `Text(value).foregroundColor(.secondaryLabel)` — trailing, and a long value (the
      // proxy list URL) wraps leading-aligned inside its box, as the 4.20 iPhone shows.
      Text(this.value)
        .constraintSize({ maxWidth: this.valueMaxWidth() })
        .flexShrink(0)
        .textAlign(TextAlign.Start)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.secondary_label'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: FIELD_ROW_MIN_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.rowWidth = Number(area.width);
    })
    // A wrapped row keeps the grouped row's vertical inset; a one-line row stays at the 44 min.
    .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level4') })
  }
}
