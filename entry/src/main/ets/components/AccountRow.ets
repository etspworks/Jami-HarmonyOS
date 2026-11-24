/*
 * comp_account_row — ported from
 * .../SmartList/SwiftUI/Views/AccountLists.swift `struct AccountRowView` (line 164):
 *
 *   HStack(spacing: 0) {
 *     avatarWithStatus                                  // ZStack { avatar; AccountStatusIndicator }
 *     Spacer(width: dimensions.spacing)
 *     VStack(alignment: .leading) { Text(accountRow.bestName).lineLimit(1) }
 *     Spacer()
 *     if let migrationText = accountRow.needMigrate, !migrationText.isEmpty {
 *       Text(migrationText).foregroundColor(.red)       // the migration_needed variant
 *     }
 *   }
 *   .background(backgroundForAccountRow())              // only the SELECTED account is filled
 *   .onTapGesture { if model.changeCurrentAccount(accountId:) { accountSelectedCallback() } }
 *   .accessibilityIdentifier("account_list_itemroot")
 *
 * Every value is svc_accounts' (bestName, accountStatus, needMigrate) or svc_profiles' (the
 * avatar) — none of it is a literal.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { AccountState } from '../model/AccountModel';

/* ── S5 metrics, the source's own (AccountLists.swift:164-230, AccountsViewModel.swift:77) ── */
/** Swift `accountRow.dimensions.spacing = 7` — avatar gap and the row's vertical padding. */
const ROW_SPACING: number = 7;
/** Swift `AccountRowView.cornerRadius = 8` on the selected row's fill. */
const ROW_RADIUS: number = 8;
/** Swift `backgroundForAccountRow()`'s `.padding(.horizontal, 6)`. */
const ROW_SELECTION_INSET: number = 6;
/**
 * Swift `Color(UIColor.secondarySystemFill)` behind the SELECTED account only. iOS resolves it
 * to #78788028 over a light surface.
 */
const ROW_SELECTED_FILL: string = '#28787880';
/** Swift `.foregroundColor(.red)` on the migration notice — the iOS system red. */
const MIGRATION_RED: string = '#FF3B30';

/** Swift `AccountRow` — one configured account as the switcher renders it. */
export class AccountRowModel {
  /** Swift `accountRow.id` — the account id, also the LazyForEach key. */
  id: string = '';
  /** bindingContract[row name] <- AccountModel.registeredName (Swift `bestName`). */
  bestName: string = '';
  /** bindingContract[row avatar] <- svc_profiles. */
  avatar: string = '';
  /** bindingContract[row status] <- AccountModel.status. */
  status: AccountState = AccountState.UNREGISTERED;
  /**
   * Swift `accountRow.needMigrate` — the migration notice's text; empty when the account does
   * not need migrating. conditionalVariants[migration_needed] keys on it.
   */
  needMigrate: string = '';
}

@Component
export struct AccountRowView {
  accountRow: AccountRowModel = new AccountRowModel();
  /**
   * Swift `avatarWithStatus` — comp_avatar_swiftui with comp_account_status_indicator on its
   * bottom-trailing corner, declared by the screen's page.
   */
  @BuilderParam avatarBuilder: () => void;
  /** Swift `isSelectedAccount` — `accountRow.id == model.selectedAccount`. */
  isSelected: boolean = false;
  /** Swift `model.changeCurrentAccount(accountId:)` then `accountSelectedCallback()`. */
  onSelect?: (accountId: string) => void;

  private select(): void {
    const handler: ((accountId: string) => void) | undefined = this.onSelect;
    if (handler !== undefined) {
      handler(this.accountRow.id);
    }
  }

  build() {
    // S5 — Swift `HStack(spacing: 0)` with a 7pt spacer after the avatar, `.padding(.horizontal)`
    // and `.padding(.vertical, 7)`; only the SELECTED row carries a fill.
    Row({ space: ROW_SPACING }) {
      // Swift `avatarWithStatus` — the status dot sits on the avatar's bottom-trailing corner.
      this.avatarBuilder()

      Column() {
        Text(this.accountRow.bestName)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Blank()

      // Swift `if let migrationText = accountRow.needMigrate, !migrationText.isEmpty`.
      if (this.accountRow.needMigrate.length > 0) {
        Text(this.accountRow.needMigrate)
          // Swift `.font(.caption).foregroundColor(.red)`.
          .fontSize($r('sys.float.Body_S'))
          .fontColor(MIGRATION_RED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      top: LengthMetrics.vp(ROW_SPACING),
      bottom: LengthMetrics.vp(ROW_SPACING)
    })
    // Swift `backgroundForAccountRow()` — a fill on the selected account, nothing on the rest.
    .backgroundColor(this.isSelected ? ROW_SELECTED_FILL : Color.Transparent)
    .borderRadius(ROW_RADIUS)
    .margin({
      start: LengthMetrics.vp(ROW_SELECTION_INSET),
      end: LengthMetrics.vp(ROW_SELECTION_INSET)
    })
    // Rule 12's list-row exception: every account row shares this id.
    .id('account_list_itemroot')
    .accessibilityText(this.accountRow.bestName)
    // Swift `.contentShape(Rectangle())` — the whole row is the tap target.
    .hitTestBehavior(HitTestMode.Transparent)
    .onClick(() => {
      this.select();
    })
  }
}
