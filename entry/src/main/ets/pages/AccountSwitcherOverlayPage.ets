/*
 * screen_account_lists — "Account Switcher Overlay", ported from
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/AccountLists.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/AccountsViewModel.swift
 *
 * presentation: popup. NOT a routed page and NOT registered in main_pages.json — it is an
 * in-place overlay toggled by the smart list's private @State showAccountList, so it is the
 * @CustomDialog SmartListConversationsHomePage already mounts.
 *
 * S3 — `AccountLists.body`:
 *   VStack(spacing: 10) { accountsView(); newAccountButton() }
 *     .accessibility(identifier: accountListView)
 *
 *   accountsView() = VStack { ZStack { Text(model.headerTitle)   // accountsListTitle
 *                                      HStack { Spacer; CloseButton(closeAccountsList) } }
 *                             accountsList() }
 *   accountsList() = ScrollView { ForEach(model.accountsRows) { AccountRowView }
 *                                 .accessibilityIdentifier("accountsItemroot") }
 *   newAccountButton() = Button(L10n.Smartlist.addAccountButton)  // addAccountButton
 *
 * NO CAPTURED STATE: the gallery declared this screen uncapturable, so every control here is
 * the source's, and its only verification is the S5 static pre-check against the contract.
 *
 * COMPOSITION ROOT: the row's avatar stack — comp_avatar_swiftui with
 * comp_account_status_indicator over its bottom-trailing corner — is declared here and handed
 * to comp_account_row as a builder. The nesting is the source's `avatarWithStatus`.
 *
 * The `accountsItemroot` identifier sits on the ROW inside the list (that is where the source
 * puts it) and `account_list_itemroot` on the row component itself — two identifiers on one
 * row in the source, both kept, neither invented.
 */
import { router, LengthMetrics } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { PreferenceManager } from '../common/PreferenceManager';
import { DisposeBag } from '../common/Observable';
import { describeError } from '../common/ErrorText';
import { AccountModel, AccountState } from '../model/AccountModel';
import { Profile } from '../model/Profile';
import { AccountRowModel, AccountRowView } from '../components/AccountRow';
import { AccountStatusIndicator } from '../components/AccountStatusIndicator';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { CloseButton } from '../components/CloseButton';

/* ── S5 metrics, the source's own (AccountLists.swift:70-150) ─────────────────────── */
/** Swift `let verticalSpacing: CGFloat = 15`. */
const VERTICAL_SPACING: number = 15;
/** Swift `let maxHeight: CGFloat = 300` on the accounts list. */
const LIST_MAX_HEIGHT: number = 300;
/** Swift `let cornerRadius: CGFloat = 16` on the card and on the add-account button. */
const CARD_RADIUS: number = 16;
/** Swift `let shadowRadius: CGFloat = 6`. */
const CARD_SHADOW_RADIUS: number = 6;
/** Swift `VStack(spacing: 10)` and `.padding(.horizontal, 5).padding(.bottom, 10)`. */
const STACK_GAP: number = 10;
const OVERLAY_H_PADDING: number = 5;
/** Swift's card shadow colour. */
const CARD_SHADOW_COLOR: string = '#26000000';

/** AccountMigrationPage's route param: the account to migrate. */
interface MigrationRouteParams {
  accountId: string;
}

@CustomDialog
export struct AccountSwitcherOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /** Owned by screen_smart_list; the host's @State drives this overlay. */
  @Link isPresented: boolean;

  /** bindingContract[account switcher list] <- svc_accounts (model.accountsRows). */
  @State accountSwitcherList: ArrayDataSource<AccountRowModel> =
    new ArrayDataSource<AccountRowModel>([]);
  /** bindingContract[row name] <- AccountModel.registeredName (Swift `accountRow.bestName`). */
  @State rowName: string = '';
  /** bindingContract[row status] <- AccountModel.status. */
  @State rowStatus: AccountState = AccountState.UNREGISTERED;
  /** bindingContract[row avatar] <- svc_profiles. */
  @State rowAvatar: string = '';
  /** conditionalVariants[migration_needed]: an account row needs migration. */
  @State isMigrationNeeded: boolean = false;
  /** True while svc_accounts / svc_profiles are in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** Swift `model.selectedAccount`; written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `private var cancellables` — the profile subscriptions this overlay opens. */
  private bag: DisposeBag = new DisposeBag();
  /** The per-row profile subscriptions; replaced on every reload so stale rows stop updating. */
  private profileBag: DisposeBag = new DisposeBag();

  /** Swift `AccountsViewModel.init` — the rows are built from svc_accounts' own list. */
  aboutToAppear(): void {
    this.reloadAccounts();
    this.bag.add(ServiceRegistry.shared().accountService.currentAccountChanged.subscribe(
      (account: AccountModel | null): void => {
        this.currentAccountId = account === null ? '' : account.id;
        this.reloadAccounts();
      }));
  }

  aboutToDisappear(): void {
    this.bag.dispose();
    this.profileBag.dispose();
  }

  /** Swift `AccountsViewModel.accountsRows` — one row per configured account. */
  private reloadAccounts(): void {
    this.isLoading = true;
    this.profileBag.dispose();
    try {
      const registry: ServiceRegistry = ServiceRegistry.shared();
      const rows: AccountRowModel[] = [];
      for (const account of registry.accountService.accountList) {
        const row: AccountRowModel = new AccountRowModel();
        row.id = account.id;
        // Swift `accountRow.bestName` — the registered name, else the jami id.
        row.bestName = account.registeredName.length > 0
          ? account.registeredName : account.jamiId;
        row.status = account.status;
        // Swift `accountRow.needMigrate = L10n.Account.needMigration` — the notice's TEXT
        // ("Account requires migration."), which AccountRow prints in red; not the account id.
        row.needMigrate = registry.accountService.needAccountMigration(account.id)
          ? getContext(this).resourceManager.getStringSync($r('app.string.account_need_migration').id)
          : '';
        rows.push(row);
      }
      this.accountSwitcherList.reload(rows);
      for (let i: number = 0; i < rows.length; i++) {
        this.trackAvatar(rows[i], registry.accountService.accountList[i], rows);
      }
      this.applySelectedRow(rows);
      this.errorText = '';
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(0x0001, 'AccountSwitcherOverlay', 'reload failed: %{public}s', this.errorText);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift `AccountProfileObserver.updateProfileDetails` — the account's OWN profile
   * (`getAccountProfile(accountId:)`), and `updateBestName()`: profile name, else the
   * registered name.
   */
  private trackAvatar(row: AccountRowModel, account: AccountModel, rows: AccountRowModel[]): void {
    this.profileBag.add(ServiceRegistry.shared().profileService
      .getAccountProfile(account.id)
      .subscribe((profile: Profile): void => {
        row.avatar = profile.photo === null ? '' : profile.photo;
        const alias: string | null = profile.alias;
        if (alias !== null && alias.trim().length > 0) {
          row.bestName = alias.trim();
        }
        if (row.id === this.currentAccountId) {
          this.rowAvatar = row.avatar;
          this.rowName = row.bestName;
        }
        // The rows are plain objects: a reload with a key that changes with the profile is
        // what makes LazyForEach rebuild the row.
        this.accountSwitcherList.reload(rows.slice());
      }));
  }

  /** The values the header row of the overlay binds for the CURRENT account. */
  private applySelectedRow(rows: AccountRowModel[]): void {
    this.isMigrationNeeded = false;
    for (const row of rows) {
      if (row.id !== this.currentAccountId) {
        continue;
      }
      this.rowName = row.bestName;
      this.rowStatus = row.status;
      this.rowAvatar = row.avatar;
      this.isMigrationNeeded = row.needMigrate.length > 0;
    }
  }

  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `model.changeCurrentAccount(accountId:)` then `accountSelectedCallback()`. A row that
   * needs migration routes to AccountMigrationView instead (plan edge
   * screen_account_lists -> screen_account_migration).
   */
  private selectAccount(accountId: string): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    if (registry.accountService.needAccountMigration(accountId)) {
      this.isMigrationNeeded = true;
      this.openAccountMigration(accountId);
      return;
    }
    // Swift `model.changeCurrentAccount(accountId:)` — svc_accounts owns the switch, and the
    // AppStorage key follows it through `currentAccountChanged`.
    const account: AccountModel | null = registry.accountService.getAccount(accountId);
    if (account === null) {
      return;
    }
    registry.accountService.currentAccount = account;
    PreferenceManager.setSelectedAccountId(accountId);
    this.currentAccountId = accountId;
    this.dismiss();
  }

  /** Swift `.migrateAccount(accountId: account.id)` -> AccountMigrationView(accountId:), `.show`. */
  private openAccountMigration(accountId: string): void {
    this.dismiss();
    const params: MigrationRouteParams = { accountId: accountId };
    router.pushUrl({ url: 'pages/AccountMigrationPage', params: params });
  }

  /**
   * Swift: `createAccountCallback()` -> ConversationState.createNewAccount ->
   * AppState.addAccount -> AppCoordinator.showWalkthrough(). The walkthrough page then
   * presents the create-account form (screen_create_account, an overlay it hosts).
   */
  private addAccount(): void {
    this.dismiss();
    router.pushUrl({ url: 'pages/WelcomeOnboardingPage' });
  }

  /** Swift `avatarWithStatus` — the status dot on the avatar's bottom-trailing corner. */
  @Builder
  private accountAvatar(account: AccountRowModel) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      AvatarSwiftUIView({
        avatarData: account.avatar,
        displayText: account.bestName,
        isGroup: false
      })
      AccountStatusIndicator({ status: account.status })
    }
  }

  /** Swift `accountsList()`. */
  @Builder
  private accountsList() {
    List() {
      LazyForEach(this.accountSwitcherList, (account: AccountRowModel) => {
        ListItem() {
          AccountRowView({
            accountRow: account,
            avatarBuilder: (): void => {
              this.accountAvatar(account)
            },
            isSelected: account.id === this.currentAccountId,
            onSelect: (accountId: string) => {
              this.selectAccount(accountId);
            }
          })
        }
        // Swift puts this identifier on the row inside the ForEach.
        .id('accountsItemroot')
        // isSelected is a plain field on the row: the selection is part of the key, so a switch
        // rebuilds the old and the new current rows instead of reusing their stale highlight.
      }, (account: AccountRowModel) => account.id + '|' + account.bestName + '|' +
        account.avatar.length + '|' + (account.id === this.currentAccountId))
    }
    .width('100%')
    // Swift `accountsList()`'s `.frame(maxHeight: 300)`.
    .constraintSize({ maxHeight: LIST_MAX_HEIGHT })
    .backgroundColor(Color.Transparent)
    .scrollBar(BarState.Off)
  }

  build() {
    // S5 — Swift `AccountLists.body`: `VStack(spacing: 10) { accountsView(); newAccountButton() }`
    // inset `.padding(.horizontal, 5).padding(.bottom, 10)`. The accounts CARD and the
    // add-account button are two separate rounded material surfaces, not one.
    Column({ space: STACK_GAP }) {
      Column() {
        // Swift `accountsView()`: the title centred, the close button trailing, over one band.
        Stack({ alignContent: Alignment.Center }) {
          Text($r('app.string.smartlist_accounts_title'))
            .id('accountsListTitle')
            // Swift `.fontWeight(.semibold)`.
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))

          Row() {
            Blank()
            CloseButton({
              accessibilityIdentifier: 'closeAccountsList',
              onAction: () => {
                this.dismiss();
              }
            })
          }
          .width('100%')
        }
        .width('100%')
        .margin({ top: VERTICAL_SPACING, bottom: VERTICAL_SPACING })

        // Swift: a row that needs migration carries its notice, and tapping it routes to
        // AccountMigrationView instead of switching — conditionalVariants[migration_needed].
        if (this.isMigrationNeeded) {
          Text($r('app.string.account_need_migration'))
            .width('100%')
            .id('accountsMigrationNotice')
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .textAlign(TextAlign.Center)
            .padding({ bottom: STACK_GAP })
        }

        this.accountsList()

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .textAlign(TextAlign.Center)
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        }

        Blank()
          .height(VERTICAL_SPACING)
      }
      .width('100%')
      // Swift `accountsView()`: `.background(VisualEffect(.systemMaterial)).cornerRadius(16)
      // .shadow(radius: 6).fixedSize(horizontal: false, vertical: true)`.
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .clip(true)
      .shadow({
        radius: CARD_SHADOW_RADIUS,
        color: CARD_SHADOW_COLOR,
        offsetX: 0,
        offsetY: 2
      })

      // Swift `newAccountButton()` — its own full-width chrome-material card under the list,
      // same radius and shadow, label in `jamiButtonPrimary`.
      Button($r('app.string.smartlist_add_account_button'))
        .id('addAccountButtonIdentifier')
        .accessibilityText($r('app.string.accessibility_smart_list_add_account'))
        .type(ButtonType.Normal)
        .width('100%')
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami_button_primary'))
        .backgroundColor($r('sys.color.comp_background_gray'))
        .borderRadius(CARD_RADIUS)
        .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        .shadow({
          radius: CARD_SHADOW_RADIUS,
          color: CARD_SHADOW_COLOR,
          offsetX: 0,
          offsetY: 2
        })
        .onClick(() => {
          this.addAccount();
        })
    }
    .width('100%')
    .padding({
      start: LengthMetrics.vp(OVERLAY_H_PADDING),
      end: LengthMetrics.vp(OVERLAY_H_PADDING),
      bottom: LengthMetrics.vp(STACK_GAP)
    })
    .id('screen_account_lists')
  }
}
