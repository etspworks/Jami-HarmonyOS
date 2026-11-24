/*
 * comp_current_account_button — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SmartListContainer.swift
 * `struct CurrentAccountButton` (line 286): the leading nav-bar label — the current account's
 * avatar with its connectivity dot, plus its best name.
 *
 * bindingContract: `current account button` <- svc_accounts (the current account's name +
 * avatar). Both are passed in by the host from AccountsService, never written as a literal.
 *
 * S5 style, from the source: `Text(model.bestName).bold().lineLimit(1)
 * .foregroundColor(Color.jami).frame(maxWidth: 150, alignment: .leading)`, preceded by
 * `Spacer().frame(width: model.dimensions.spacing)` — AccountRowSizes.spacing = 7 — and the
 * status dot at `.offset(x: 1, y: 2)` over the avatar's bottom-trailing corner.
 */
import { AccountState } from '../model/AccountModel';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { AccountStatusIndicator } from './AccountStatusIndicator';

/** Swift `AccountRowSizes.spacing`. */
const NAME_SPACING: number = 7;
/** Swift `.frame(maxWidth: 150, alignment: .leading)`. */
const NAME_MAX_WIDTH: number = 150;

/** The action contract calls this control the **Current account button**. */
@Component
export struct CurrentAccountButton {
  /** Swift `model.bestName` — registeredName ?? alias ?? jamiId, resolved by svc_accounts. */
  @Prop bestName: string = '';
  /** Swift `AvatarSwiftUIView(source: model)` — the account profile's avatar. */
  @Prop avatarData: string = '';
  /** Swift `model.accountStatus`. */
  @Prop accountStatus: AccountState = AccountState.UNREGISTERED;
  /**
   * bindingContract[unread badge] <- svc_conversation_source, summed by the host. Announced
   * rather than drawn: the source draws no badge here, so adding one would be an invented
   * control, while a screen reader still has to say how many conversations are unread.
   */
  @Prop unreadCount: number = 0;

  private accessibilityLabel(): string {
    return this.unreadCount > 0
      ? `${this.bestName} (${this.unreadCount})` : this.bestName;
  }

  build() {
    Row() {
      // Swift: `.accessibilityHidden(true)` — the whole button carries one label instead.
      Stack({ alignContent: Alignment.BottomEnd }) {
        // AvatarSwiftUIView draws through a by-value @Builder that never refreshes, so a name
        // that arrives after first draw (a new account, a switch) kept the id's glyph. Keying
        // on the inputs rebuilds it, the same workaround AvatarSwiftui uses for groups.
        ForEach([`${this.bestName}|${this.avatarData}`], (_key: string) => {
          AvatarSwiftUIView({
            avatarData: this.avatarData,
            displayText: this.bestName,
            isGroup: false,
            avatarSize: AvatarSize.ACCOUNT_28
          })
        }, (key: string) => key)
        AccountStatusIndicator({
          status: this.accountStatus,
          indicatorSize: 8,
          ringWidth: 1
        })
          .offset({ x: 1, y: 2 })
      }

      Text(this.bestName)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.jami'))
        .constraintSize({ maxWidth: NAME_MAX_WIDTH })
        .margin({ left: NAME_SPACING })
    }
    .alignItems(VerticalAlign.Center)
    .accessibilityText($r('app.string.accessibility_smart_list_switch_accounts'))
    .accessibilityDescription(this.accessibilityLabel())
  }
}
