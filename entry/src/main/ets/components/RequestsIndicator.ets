/*
 * comp_requests_indicator — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/RequestsView.swift
 * `struct RequestsIndicatorView` (line 24): the pending-invitations row the smart list shows
 * above the conversation list when there are unread invitations.
 *
 * Structure: envelope glyph | title + the requesting names | unread badge.
 * The counter and the names are bound to svc_requests by the host — never a captured number.
 *
 * S5 style, from the source's own private constants:
 *   iconSize 25, cornerRadius 12, horizontalPaddingForBody 20 (also the HStack spacing),
 *   verticalPaddingForBadge 20, verticalTextPadding 5, badgePadding 8, badgeCornerRadius 5,
 *   foregroundColor = Color(UIColor.systemBackground),
 *   background = Color.jamiRequestsBackground, badge = requestsBadge{Foreground,Background}.
 * All four app colours were migrated by the assets pass and carry their dark variants.
 */
/** Swift `private let iconSize: CGFloat = 25`. */
const ICON_SIZE: number = 25;
/** Swift `horizontalPaddingForBody` — also the HStack spacing. */
const BODY_PADDING: number = 20;
/** Swift `verticalPaddingForBadge`. */
const VERTICAL_PADDING: number = 20;
/** Swift `verticalTextPadding`. */
const TEXT_SPACING: number = 5;
/** Swift `badgePadding` / `badgeCornerRadius`. */
const BADGE_PADDING: number = 8;
const BADGE_CORNER_RADIUS: number = 5;

@Component
export struct RequestsIndicatorView {
  /** Swift `model.title`. */
  title: ResourceStr = $r('app.string.smartlist_invitation_received');
  /** Swift `model.requestNames` — the joined names of the pending requests. */
  @Prop requestNames: string = '';
  /** Swift `model.unreadRequests`. */
  @Prop unreadRequests: number = 0;

  build() {
    Row({ space: BODY_PADDING }) {
      SymbolGlyph($r('sys.symbol.envelope_badge_dot'))
        .fontSize(ICON_SIZE)
        .fontColor([$r('sys.color.background_primary')])

      Column({ space: TEXT_SPACING }) {
        Text(this.title)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.background_primary'))
        Text(this.requestNames)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.background_primary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.unreadRequests.toString())
        .fontSize($r('sys.float.Body_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.requests_badge_foreground'))
        .backgroundColor($r('app.color.requests_badge_background'))
        .borderRadius(BADGE_CORNER_RADIUS)
        .padding({
          left: BADGE_PADDING,
          right: BADGE_PADDING,
          top: $r('sys.float.ohos_id_elements_margin_horizontal_s'),
          bottom: $r('sys.float.ohos_id_elements_margin_horizontal_s')
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: BODY_PADDING,
      right: BODY_PADDING,
      top: VERTICAL_PADDING,
      bottom: VERTICAL_PADDING
    })
    .backgroundColor($r('app.color.jami_requests_background'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
  }
}
