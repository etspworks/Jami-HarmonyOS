/*
 * comp_account_status_indicator — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/AccountLists.swift `struct
 * AccountStatusIndicator` (line 23). A coloured dot whose colour is a switch over the
 * account's registration state.
 *
 * S5 style, from the source's own palette (Ring/Ring/Extensions/UIColor+Ring.swift):
 *   registered / ready       -> Color.onlinePresence     #0B8271
 *   trying / initializing    -> Color.availablePresence  #E59028
 *   everything else          -> Color.jamiFailure        #F00000
 * Each is a hard-coded hex in the source, so it is carried over verbatim rather than mapped to
 * a system token. The source set the dot on a blurred `VisualEffect` disc so it reads against
 * the avatar underneath; ArkUI has no in-place blur shape here, so the same separation is drawn
 * as a page-background ring, which is what the blur resolves to over an opaque avatar.
 */
import { AccountState } from '../model/AccountModel';

/** Swift `Color.onlinePresence`. */
const ONLINE_PRESENCE: string = '#0B8271';
/** Swift `Color.availablePresence`. */
const AVAILABLE_PRESENCE: string = '#E59028';
/** Swift `Color.jamiFailure` (`UIColor(hex: 0xf00000)`). */
const JAMI_FAILURE: string = '#F00000';

@Component
export struct AccountStatusIndicator {
  /** Swift `let status: AccountState`. */
  @Prop status: AccountState = AccountState.UNREGISTERED;
  /** Swift `let size: CGFloat` (default 10). */
  @Prop indicatorSize: number = 10;
  /** Swift `let borderWidth: CGFloat` (default 1.2). */
  @Prop ringWidth: number = 1.2;

  /** Swift `private var statusColor` — registered/ready, trying/initializing, everything else. */
  private statusColor(): ResourceColor {
    switch (this.status) {
      case AccountState.REGISTERED:
      case AccountState.READY:
        return ONLINE_PRESENCE;
      case AccountState.TRYING:
      case AccountState.INITIALIZING:
        return AVAILABLE_PRESENCE;
      default:
        return JAMI_FAILURE;
    }
  }

  build() {
    Circle()
      .width(this.indicatorSize)
      .height(this.indicatorSize)
      .fill(this.statusColor())
      .stroke($r('sys.color.background_primary'))
      .strokeWidth(this.ringWidth * 2)
  }
}
