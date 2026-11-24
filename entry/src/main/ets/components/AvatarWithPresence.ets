/*
 * comp_avatar_with_presence — ported from
 * Ring/Ring/Calls/ContactPicker/ContactPickerView.swift `struct AvatarWithPresence` (line 182):
 *
 *   ZStack(alignment: .bottomTrailing) {
 *     AvatarSwiftUIView(source: avatarSource)
 *     switch presenceTracker.status {
 *       case .connected: presenceCircle(color: .onlinePresence)
 *       case .available: presenceCircle(color: .availablePresence)
 *       default:         EmptyView()
 *     }
 *   }
 *   presenceCircle = Circle 12 pt + a 1 pt systemBackground ring, offset(x: -1, y: 0)
 *
 * The status is svc_presence's (`PresenceTracker` subscribes to
 * `PresenceService.getSubscriptionsForContact`), and the avatar is svc_profiles' — both are the
 * host screen's binding sites, so they arrive as parameters.
 */
import { PresenceStatus } from '../common/PresenceService';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** Swift `presenceCircle`'s `.frame(width: 12, height: 12)`. */
export const PRESENCE_DOT_SIZE: number = 12;
/** Swift `Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1)`. */
const PRESENCE_RING_WIDTH: number = 1;
/**
 * S5 — Swift `Color.onlinePresence` / `.availablePresence`
 * (Ring/Ring/Extensions/UIColor+Ring.swift). The source hard-codes both hexes, so they are
 * carried over verbatim rather than mapped to a system token — the same pair
 * comp_account_status_indicator already uses.
 */
const ONLINE_PRESENCE: string = '#0B8271';
const AVAILABLE_PRESENCE: string = '#E59028';

@Component
export struct AvatarWithPresence {
  /** Swift `avatarSource.avatar` <- svc_profiles. */
  avatarData: string = '';
  /** Swift `avatarSource.profileName` — what the monogram falls back to. */
  displayName: string = '';
  /** Swift `avatarSource.isGroup`. */
  isGroup: boolean = false;
  /** Swift `AvatarProvider(size: .medium45)` — every picker row uses the 45 pt avatar. */
  avatarSize: number = AvatarSize.MEDIUM_45;
  /** Swift `presenceTracker.status` <- svc_presence. */
  presence: PresenceStatus = PresenceStatus.OFFLINE;

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      AvatarSwiftUIView({
        avatarData: this.avatarData,
        displayText: this.displayName,
        isGroup: this.isGroup,
        avatarSize: this.avatarSize
      })

      // Swift's switch: a dot for .connected and .available, nothing for any other status.
      if (this.presence === PresenceStatus.CONNECTED || this.presence === PresenceStatus.AVAILABLE) {
        Circle()
          .width(PRESENCE_DOT_SIZE)
          .height(PRESENCE_DOT_SIZE)
          .fill(this.presence === PresenceStatus.CONNECTED
            ? ONLINE_PRESENCE : AVAILABLE_PRESENCE)
          // Swift's 1 pt systemBackground ring — ArkUI strokes centred, so the width doubles.
          .stroke($r('sys.color.background_primary'))
          .strokeWidth(PRESENCE_RING_WIDTH * 2)
          // Swift `.offset(x: -1, y: 0)` — pulled a point inside the avatar's trailing edge.
          .offset({ x: -PRESENCE_RING_WIDTH, y: 0 })
          // Decorative: the row's name text is what a screen reader announces.
          .accessibilityLevel('no')
      }
    }
  }
}
