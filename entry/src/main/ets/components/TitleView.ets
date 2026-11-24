/*
 * comp_title_view — ported from Ring/Ring/Contact/TitleView.swift `final class TitleView: UIView`
 * (line 27), the contact screen's `navigationItem.titleView`:
 *
 *   containerView { avatarView(avatarImage) | margin 10 | label(text) }   // centred
 *   label.textColor = .jamiSecondary; label.font = .systemFont(17, .regular)
 *   isUserInteractionEnabled = false
 *
 * The avatar is an AvatarView(size: 36) the host hands in (ContactViewController:92), and the
 * text is `viewModel.titleName` — both are bindingContract sites of the host screen, so they
 * arrive as parameters rather than being built here.
 *
 * `contentOffset` / `didChangeStretchFactor` drive the UIKit fade-and-rise as the table
 * scrolls under the nav bar; that is animation of an already-correct tree and belongs to S5/S6,
 * not to the component architecture.
 */
/** Swift `TitleView.swift` `containerView` spacing: avatar | margin 10 | label. */
const TITLE_AVATAR_GAP: number = 10;
/** Capture S0022/S0024: the nav bar band is `[0,53][393,97]` — 44vp. */
const NAV_BAR_HEIGHT: number = 44;

@Component
export struct TitleView {
  /** Swift `var text: String` <- ContactViewModel.titleName; @Prop so a rename redraws (T-1240). */
  @Prop text: string = '';
  /**
   * Swift `var avatarImage: UIView` — ContactViewController:92 hands in
   * `AvatarView(..., size: 36)`, so comp_avatar_view is declared by the page.
   */
  @BuilderParam avatarBuilder: () => void;

  build() {
    // S5 — capture S0022/S0024: the title view is centred in the 44vp nav bar
    // (`[96,53][296,97]`), avatar first, label 10pt after it.
    Row({ space: TITLE_AVATAR_GAP }) {
      this.avatarBuilder()
      Text(this.text)
        // Swift `label.font = .systemFont(ofSize: 17, weight: .regular)`.
        .fontSize($r('sys.float.Body_L'))
        // Swift `label.textColor = .jamiSecondary`.
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    // Swift the nav bar is 44pt tall; the title rides inside it. A text row grows with the
    // system font size, so this is a floor, not a fixed height.
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    // Swift `isUserInteractionEnabled = false` — the nav title is not a control.
    .hitTestBehavior(HitTestMode.None)
  }
}
