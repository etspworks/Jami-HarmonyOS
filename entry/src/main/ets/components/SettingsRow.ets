/*
 * comp_settings_row — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct SettingsRow` (line 382):
 *
 *   HStack { Image(systemName: iconName) ... ; Text(title) }
 *
 * A leading glyph plus a title. The row carries NO tap of its own: in the source it is the
 * label of a `NavigationLink`, so the caller owns the navigation and the identifier.
 *
 * S5 — style only. The source pins the glyph at 18x18 `.foregroundColor(.secondary)` with a
 * 5 pt trailing pad inside an HStack (8 pt default spacing) = the 12 vp gap the capture shows;
 * the title is the plain `.label` body. The row's own padding belongs to the CALLER, because
 * the same row is used both inside an inset-grouped card and edge to edge.
 */
@Component
export struct SettingsRow {
  /** Swift `var iconName: String` — an SF Symbol name, resolved to a sys.symbol by the caller. */
  icon: Resource = $r('sys.symbol.person_crop_circle_fill');
  /** Swift `var title: String`. */
  title: ResourceStr = '';

  build() {
    Row() {
      // Swift `.frame(width: 18, height: 18)` — a size the source hardcodes, copied verbatim.
      SymbolGlyph(this.icon)
        .fontSize(18)
        .fontColor([$r('app.color.secondary_label')])
        .margin({ right: $r('sys.float.ohos_id_card_margin_start') })
      // Swift `Text(title)` has no lineLimit: a title wider than the caller leaves it wraps
      // rather than running into the caller's chevron (T-0624). flexShrink did nothing in this
      // wrap-content Row, so at a larger text size it still ran under the chevron (T-0933):
      // the row fills the slot its caller gives it and the title takes what the glyph leaves.
      Text(this.title)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
