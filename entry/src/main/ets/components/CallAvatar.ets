/*
 * comp_call_avatar — ported from Ring/Ring/Calls/Views/Canvas/CallAvatarView.swift
 * `final class CallAvatarView: UIView` (line 22):
 *
 *   render(image:name:)
 *     image        -> imageView (scaleAspectFill, circular)
 *     name usable  -> monogramLabel, `String(name.prefix(1)).uppercased()`, over
 *                     avatarBackgroundColor(for: name)
 *     otherwise    -> symbolView, "person.fill"
 *   `isHidden = provider?.isAvatarResolved != true` — the tile shows NOTHING until the avatar
 *   has resolved, rather than flashing a monogram it is about to replace.
 *
 * The three render branches are `AvatarSwiftUIView`'s (comp_avatar_swiftui), down to the same
 * `AvatarMetrics` font sizes and the same md5 palette, so this component delegates rather than
 * carrying a second copy; what it adds is the RESOLVED gate, which only the call tiles have.
 */
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';

@Component
export struct CallAvatarView {
  /** Swift `provider.avatar` <- svc_profiles. */
  avatarData: string = '';
  /** Swift `provider.profileName`. */
  displayName: string = '';
  /** Swift `provider.isAvatarResolved` — nothing is drawn until this is true. */
  isAvatarResolved: boolean = false;
  /** The tile's avatar diameter (the canvas sizes it per tile). */
  avatarSize: number = AvatarSize.CALL_160;

  build() {
    Column() {
      // Swift `isHidden = provider?.isAvatarResolved != true`.
      if (this.isAvatarResolved) {
        AvatarSwiftUIView({
          avatarData: this.avatarData,
          displayText: this.displayName,
          isGroup: false,
          avatarSize: this.avatarSize
        })
      }
    }
  }
}
