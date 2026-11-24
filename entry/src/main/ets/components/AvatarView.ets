/*
 * comp_avatar_view — ported from Ring/Ring/Helpers/AvatarView.swift `class AvatarView: UIView`
 * (line 24), the UIKit avatar the contact screen builds by hand:
 *
 *   init(profileImageData:username:isGroup:size:offset:labelFontSize:)
 *     - profileImageData non-empty -> UIImageView, cornerRadius size/2, .scaleAspectFill
 *     - else a circle filled with avatarBackgroundColor(for: username), and inside it
 *         * a capitalised `username.prefixString()` monogram, when the name is neither
 *           empty, a SHA1 hash, nor a group;
 *         * otherwise person.fill / person.2.fill in white.
 *
 * Those are branch-for-branch the same three cases as `AvatarSwiftUIView`
 * (AvatarView.swift:310, comp_avatar_swiftui) — the same file, the same palette, the same
 * monogram and glyph metrics — so this component delegates instead of carrying a second copy
 * of the md5 colour table. `offset` / `labelFontSize` are UIKit frame plumbing with no ArkUI
 * counterpart: every call site in this app (ContactViewController:87,93) passes neither.
 */
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** Swift `AvatarView(profileImageData:username:isGroup:size:)`. */
@Component
export struct AvatarView {
  /** Swift `profileImageData: Data?` — svc_profiles' encoded photo; empty means none. */
  profileImageData: string = '';
  /** Swift `username: String` — what the monogram and the background colour are derived from. */
  username: string = '';
  /** Swift `isGroup: Bool`. */
  isGroup: boolean = false;
  /**
   * Swift `size: CGFloat = 32.0`. Not one of `Constants.AvatarSize`'s named diameters — the
   * UIKit initialiser carries its own default, and the contact screen overrides it (100 for
   * the stretchy header, 36 for the nav-bar TitleView).
   */
  diameter: number = 32;

  build() {
    AvatarSwiftUIView({
      avatarData: this.profileImageData,
      displayText: this.username,
      isGroup: this.isGroup,
      avatarSize: this.diameter
    })
  }
}
