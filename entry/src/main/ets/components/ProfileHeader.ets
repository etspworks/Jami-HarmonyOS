/*
 * comp_profile_header — ported from Ring/Ring/Contact/ProfileHeaderView.xib +
 * Ring/Ring/Contact/ProfileHeaderView.swift `class ProfileHeaderView: GSKStretchyHeaderView`
 * (line 22). The xib declares four outlets stacked over `background`:
 *
 *   avatarView   -> ContactViewController:86 fills it with AvatarView(..., size: 100)
 *   displayName  -> viewModel.displayName   (the profile alias)
 *   userName     -> viewModel.userName, shown ONLY when it differs from conversation.hash
 *                   (ContactViewController:115)
 *   jamiID       -> a CopyableLabel holding conversation.hash (ContactViewController:121)
 *
 * All four are bindingContract sites of the host screen (svc_profiles / ContactModel.userName /
 * ContactModel.hash), so they arrive as parameters; nothing here is a literal.
 *
 * `didChangeStretchFactor` fades and scales the four subviews with the scroll offset — S5/S6
 * styling of this same tree, not structure.
 */
import { LengthMetrics } from '@kit.ArkUI';

/** Swift xib: 20pt between the avatar and the labels, and between the labels. */
const HEADER_LABEL_GAP: number = 8;
/**
 * Capture S0022: the 100vp avatar's top edge sits at y=130 with the nav band ending at y=97 —
 * a 33vp inset, which is the xib's own top constraint on `avatarView`. No baseline spacing
 * token is that size, so it is carried over as the source metric it is.
 */
const HEADER_TOP_INSET: number = 32;

@Component
export struct ProfileHeaderView {
  /**
   * Swift ContactViewController:86 — the host BUILDS `AvatarView(..., size: 100)` and fills
   * the xib's `avatarView` outlet with it, so comp_avatar_view is declared by the page.
   */
  @BuilderParam avatarBuilder: () => void;
  /*
   * @Prop, not plain members: ArkUI copies a plain member once at construction, so the header
   * kept the pre-edit name after Edit > Save re-emitted the profile (T-1240).
   */
  /** Swift `displayName` <- ContactViewModel.displayName (the profile alias). */
  @Prop displayName: string = '';
  /** Swift `userName` <- ContactViewModel.userName (the registered name). */
  @Prop userName: string = '';
  /** Swift `jamiID` <- conversation.hash. */
  @Prop jamiId: string = '';

  build() {
    // S5 — capture S0022: white page, the 100vp avatar centred ~32vp under the 44vp nav bar,
    // the three labels stacked and centred beneath it. The xib's own metrics: avatar 100,
    // 20pt gaps, header height 195.
    Column({ space: HEADER_LABEL_GAP }) {
      this.avatarBuilder()

      // Swift xib `displayName`: system 22, darkTextColor. The frozen baseline's `title` role.
      // S6 — the label is a bound site with nothing in it until svc_profiles answers; an empty
      // Text still takes the Column's 8vp gap, which pushed the whole header off the capture's
      // metrics on a profile with no alias (capture S0022 is exactly that state).
      if (this.displayName.length > 0) {
        Text(this.displayName)
          .id('contact_display_name')
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // Swift ContactViewController:115 — `if username != conversation.hash`: the registered
      // name is shown only when the lookup produced something other than the raw hash, which
      // the jamiID label below already carries.
      if (this.userName.length > 0 && this.userName !== this.jamiId) {
        // Swift xib `userName`: system 19, one step under displayName.
        Text(this.userName)
          .id('contact_user_name')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // Swift `jamiID: CopyableLabel` — selectable so the hash can be copied out. System 16,
      // the smallest of the three; a 40-char hash wraps rather than being clipped.
      // S6 — same as displayName: no hash yet, no empty row.
      if (this.jamiId.length > 0) {
        Text(this.jamiId)
          .id('contact_jami_id')
          .copyOption(CopyOptions.LocalDevice)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      top: LengthMetrics.vp(HEADER_TOP_INSET),
      bottom: LengthMetrics.resource($r('sys.float.margin_level2')),
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    })
  }
}
