/*
 * screen_account_migration — ported from
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/AccountMigrationView.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/AccountMigrationModel.swift
 *
 * S3: the real component tree, from the SOURCE's `var body`:
 *   ScrollView > VStack(spacing: 20) {
 *     headerView          — Text(L10n.MigrateAccount.explanation), centered
 *     profileSection      — AvatarSwiftUIView(source: model) + the profile name when non-empty
 *     accountInfoSection  — "Name:" row (+ Divider) when registeredName is set, then "Id:" row
 *     if model.needsPassword { passwordSection }   <- conditionalVariants[password_required]
 *     actionButtons       — migrateButton, removeButton
 *     Spacer()
 *   }
 *   .navigationTitle(L10n.MigrateAccount.title) .navigationBarTitleDisplayMode(.inline)
 *   .alert(model.error != nil)                     <- conditionalVariants[migration_failed]
 *   .overlay(loadingOverlay)                       <- model.isLoading
 *
 * Both nav edges out of this screen are `kind: replace` — the source swaps the whole navigation
 * stack (AppCoordinator.migrateAccount presented it with .replaceNavigationStack), so Back must
 * NOT return here.
 *
 * DAEMON GAP: AccountsService.migrateAccount / removeAccountAndWaitForCompletion are executed by
 * the jami daemon, which HarmonyOS cannot run. Both controls keep their place and their real
 * validation; a daemon-backed ACTION surfaces the gap notice instead of faking success.
 */
import { LengthMetrics, promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeError } from '../common/ErrorText';
import { AccountsService } from '../common/AccountsService';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { Profile } from '../model/Profile';
import { ProfilesService } from '../common/ProfilesService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { PasswordFieldView } from '../components/PasswordField';
import { BackChevron } from '../components/BackButton';
import { COPY_SHARE_MENU } from './AccountSummarySettingsRootPage';

/**
 * Swift composes its info-row labels as `L10n.Global.name + ":"`. The colon belongs to the view,
 * so the shared `global_name` / `swarm_identifier` resources stay bare and it is appended here.
 */
const LABEL_SUFFIX: string = ':';

/** Capture: the inline bar is 44 pt high. */
const BAR_HEIGHT: number = 44;
/** Where the stack swap landed this page with nothing behind it, Back goes where the app lives. */
const SMART_LIST_PAGE: string = 'pages/SmartListConversationsHomePage';

/** Swift `AccountMigrationView(accountId:)` — what the caller routes in with. */
interface MigrationRouteParams {
  accountId?: string;
  /**
   * Swift `.replaceNavigationStack` (AppCoordinator.migrateAccount, the live route): the page is
   * the only screen, with no Back. Absent for ConversationsCoordinator's `.show` (the switcher).
   */
  replacesStack?: boolean;
}

@Entry
@Component
struct AccountMigrationPage {
  /** Swift: AccountMigrationModel.accountId — the account AppCoordinator asked to migrate. */
  @State accountId: string = '';
  /** Swift `AccountMigrationModel.jamiId` — bound to AccountModel.jamiId, never a literal. */
  @State jamiId: string = '';
  /** Swift `AccountMigrationModel.registeredName` — `resolveAccountName(from: account)`. */
  @State registeredName: string = '';
  /** Swift `AccountMigrationModel.profileName` — svc_profiles' profile for this account. */
  @State profileNameAvatar: string = '';
  /** Swift `AvatarProvider.avatar` — the profile photo svc_profiles carries. Empty = none. */
  @State avatarData: string = '';
  /** Swift `@State private var password` — the archive password the migration uses. */
  @State password: string = '';
  /** Swift `@Published var needsPassword` (AccountModelHelper.hasPassword). */
  @State isPasswordRequired: boolean = false;
  /** Swift `@Published var isLoading` — the `loadingOverlay` condition. */
  @State isLoading: boolean = false;
  /** Swift `@Published var migrationCompleted == false` after an attempt — drives the `.alert`. */
  @State isMigrationFailed: boolean = false;
  /** Swift `@Published var error: String?` — the alert's message. */
  @State errorText: string = '';
  /** Swift `accountService.currentAccount?.id`, written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /** MigrationRouteParams.replacesStack: no Back item, and the system Back is consumed. */
  private replacesStack: boolean = false;

  aboutToAppear(): void {
    const params: Object | undefined = router.getParams();
    this.replacesStack = params !== undefined && params !== null &&
      (params as MigrationRouteParams).replacesStack === true;
    this.loadAccount();
  }

  /**
   * iOS has no system Back on the stack-replacing route: the user must migrate or remove the
   * account. Consumed there so Back cannot leave the page with the account unmigrated; the
   * switcher's pushed page pops as usual.
   */
  onBackPress(): boolean {
    return this.replacesStack;
  }

  /**
   * Swift `Text(L10n.Global.name + ":")` — the colon is composed by the VIEW, not carried by the
   * localized string (which is shared with other screens and stays bare). Resolved through the
   * resource manager so the label stays a bound/resource site rather than a captured literal.
   */
  private labelWithColon(resId: number): string {
    return getContext(this).resourceManager.getStringSync(resId) + LABEL_SUFFIX;
  }

  /**
   * Swift `AccountMigrationView.init(accountId:)` — AppCoordinator.migrateAccount(accountId:)
   * hands the id in. Router params carry it here; the current account is the fallback the
   * coordinator itself used (`checkAccounts()` reads `currentAccount?.id`).
   */
  private resolveAccountId(accounts: AccountsService): string {
    const params: Object | undefined = router.getParams();
    if (params !== undefined && params !== null) {
      const routed: string | undefined = (params as MigrationRouteParams).accountId;
      if (routed !== undefined && routed.length > 0) {
        return routed;
      }
    }
    if (this.currentAccountId.length > 0) {
      return this.currentAccountId;
    }
    const current: AccountModel | null = accounts.currentAccount;
    return current === null ? '' : current.id;
  }

  /** Swift `AccountMigrationModel.updateAccountInfo()` + `AvatarProvider.updateProfileDetails`. */
  private loadAccount(): void {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const wanted: string = this.resolveAccountId(accounts);
    const account: AccountModel | null = wanted.length === 0 ? null : accounts.getAccount(wanted);
    if (account === null) {
      // Swift `updateAccountInfo()`: `guard let account = ... else { error = ... }`. The alert
      // it raises is `model.error != nil`, and the ONLY errors the view can show at rest are
      // ones that have actually occurred; the model is always constructed with an accountId the
      // coordinator resolved, so this guard is unreachable there. Here the page can be entered
      // with no account at all (a deep link, or a device with none), which is not a failed
      // migration - `isMigrationFailed` is the alert's selector and means exactly
      // `handleMigrationResult(false)` / `handleMigrationError()`. Record the load failure,
      // leave the alert down.
      this.errorText = 'migrate_account_error';
      return;
    }
    this.accountId = account.id;
    this.jamiId = account.jamiId;
    this.registeredName = account.registeredName;
    // Swift: `needsPassword = AccountModelHelper(withAccount: account).hasPassword`.
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    const helper: AccountModelHelper = new AccountModelHelper(
      details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
    this.isPasswordRequired = helper.hasPassword;
    this.loadProfile(account.id);
  }

  /** Swift `AvatarProvider` reading `profileService.getAccountProfile(accountId:)`. */
  private loadProfile(accountId: string): void {
    const profiles: ProfilesService = ServiceRegistry.shared().profileService;
    const profile: Profile = profiles.getAccountProfile(accountId).value;
    this.profileNameAvatar = profile.alias === null ? '' : profile.alias;
    this.avatarData = profile.photo === null ? '' : profile.photo;
  }

  /** Swift `AvatarSwiftUIView(source: model)` — `resolvedDisplayText`. */
  private displayText(): string {
    if (this.profileNameAvatar.length > 0) {
      return this.profileNameAvatar;
    }
    if (this.registeredName.length > 0) {
      return this.registeredName;
    }
    return this.jamiId;
  }

  /** Swift `migrateButton.disabled(model.needsPassword && password.isEmpty || model.isLoading)`. */
  private migrateDisabled(): boolean {
    return (this.isPasswordRequired && this.password.length === 0) || this.isLoading;
  }

  /**
   * Swift `model.handleMigration(password:)` -> `handleMigrationResult(success)`:
   * success updates the current account and `migrationCompleted` dismisses the view (the app
   * is `allSet`, so the smart list becomes the root); failure raises the alert.
   * DAEMON GAP: `AccountsService.migrateAccount` is executed by the daemon, so the ATTEMPT is
   * real — validation, loading overlay, alert — and its RESULT is the not-available notice.
   */
  private async migrate(): Promise<void> {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    this.isLoading = true;
    this.errorText = '';
    this.isMigrationFailed = false;
    try {
      const ok: boolean = await accounts.migrateAccount(this.accountId, this.password);
      if (ok) {
        // Swift `updateCurrentAccount()` before the view dismisses.
        const migrated: AccountModel | null = accounts.getAccount(this.accountId);
        if (migrated !== null) {
          accounts.currentAccount = migrated;
          this.currentAccountId = migrated.id;
        }
        // `replace`: AppState.allSet swaps the whole stack, so Back must not return here.
        this.replace(SMART_LIST_PAGE);
      } else {
        // Swift `handleMigrationResult(false)` -> MigrationError.migrationFailed.
        this.errorText = 'migrate_account_error';
        this.isMigrationFailed = true;
      }
    } catch (err) {
      // Swift `onError: handleMigrationError()`.
      this.errorText = 'migrate_account_error';
      this.isMigrationFailed = true;
      this.reportUnavailable();
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift `removeButton`: `model.removeAccount()` (synchronous
   * `accountService.removeAccount(id:)`), then `dismiss()` + `onCompletion?(false)`.
   * Pushed from the account switcher for a non-current account (ConversationsCoordinator
   * `.show`), `dismiss()` pops back to the smart list and the current account stays current.
   * Otherwise the walkthrough REPLACES this stack. removeAccountById reaches the daemon
   * (jami.removeAccount), so no "daemon not available" notice: iOS shows none.
   */
  private deleteAccount(): void {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const removingCurrent: boolean = this.currentAccountId === this.accountId;
    accounts.removeAccountById(this.accountId);
    if (!removingCurrent && router.getLength() !== '1') {
      router.back();
      return;
    }
    this.currentAccountId = '';
    this.replace('pages/WelcomeOnboardingPage');
  }

  private reportUnavailable(): void {
    promptAction.showToast({ message: $r('app.string.daemon_not_available') });
  }

  /**
   * Both edges out of this screen are `kind: replace`. The rejection has to be consumed: an
   * unhandled router promise takes the app down, which on this page would strand the user on a
   * migration screen whose account has already been removed.
   */
  private replace(url: string): void {
    router.replaceUrl({ url: url }).catch((error: BusinessError) => {
      console.error(`AccountMigrationPage.replaceUrl ${url} failed: ${describeError(error)}`);
    });
  }

  /**
   * Swift `.navigationTitle(...).navigationBarTitleDisplayMode(.inline)` inside the pushed
   * NavigationView: iOS draws the inline title AND the leading back item itself. An @Entry
   * router page draws no system chrome, so both are composed here (mapping-tables §7).
   * Capture (S0090/S0092 ui.json): NavigationBar [0,53][393,97], title [123,65][269,85], and a
   * clickable Button labelled "Back" at [0,53][44,97] — chevron only, no caption, jami blue
   * (accountMigrationMigrate.png). The source element carries no accessibilityIdentifier, so
   * Rule 12's iOS fallback applies: the slug is its accessibility LABEL, "Back" -> `back`,
   * the same slug every other pushed page in this app uses.
   */
  @Builder
  private toolbarBuilder() {
    Stack({ alignContent: Alignment.Start }) {
      Text($r('app.string.migrate_account_title'))
        .width('100%')
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // AppCoordinator's `.replaceNavigationStack` leaves nothing to go back to: no item (T-1739).
      if (!this.replacesStack) {
        // The source item is a 44x44 hit area around a 19 pt glyph, so the tappable container is
        // the Row, not the glyph (an .onClick on the glyph alone is a 19 pt target).
        Row() {
          BackChevron()
        }
        .constraintSize({ minWidth: BAR_HEIGHT, minHeight: BAR_HEIGHT })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .id('back')
        // The item is icon-only, so `text` is empty in the uitest dump and the description is the
        // only surface the on-device drivers and the structural diff can name it by. The value is
        // the source element's own accessibility label ("Back" — actions_back_action), not invented.
        .accessibilityText($r('app.string.actions_back_action'))
        .accessibilityDescription($r('app.string.actions_back_action'))
        .onClick(() => {
          this.goBack();
        })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  /**
   * Swift: the nav item pops the pushed AccountMigrationView back to whoever presented it
   * (AppCoordinator / ConversationsCoordinator, i.e. the smart list the account switcher sits
   * on). A replay cold-start deep-links straight here, leaving nothing on the stack to pop —
   * then Back goes to that same origin page instead of swallowing the press.
   */
  private goBack(): void {
    if (router.getLength() === '1') {
      this.replace(SMART_LIST_PAGE);
      return;
    }
    router.back();
  }

  /** Swift `private var profileSection`. */
  @Builder
  private profileSection() {
    Column({ space: 20 }) {
      AvatarSwiftUIView({
        avatarData: this.avatarData,
        displayText: this.displayText(),
        isGroup: false,
        avatarSize: AvatarSize.ACCOUNT_100
      })
      // Swift: `if !model.profileName.isEmpty { Text(model.profileName).font(.headline) }`.
      // `.headline` is 17 pt semibold -> Body_L + Medium.
      if (this.profileNameAvatar.length > 0) {
        Text(this.profileNameAvatar)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
  }

  /** Swift `private var accountInfoSection`. */
  @Builder
  private accountInfoSection() {
    Column({ space: 10 }) {
      if (this.registeredName.length > 0) {
        Row({ space: 8 }) {
          // Swift `Text(L10n.Global.name + ":").fontWeight(.medium)` — the colon is composed by
          // the VIEW, not carried by the localized string (which is shared and stays bare), so
          // it is appended as a second Span inside the same Text run, exactly as the capture
          // renders it ("Name:").
          Text(this.labelWithColon($r('app.string.global_name').id))
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))
          Text(this.registeredName)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Start)
            .layoutWeight(1)
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // Capture: the hairline is #BDBDC3 at y 358.8, inset to the card's content edges
        // (x 32..361.3), which the card's own 16 pt padding already produces.
        Divider()
          .color($r('sys.color.comp_divider'))
          .strokeWidth(0.5)
      }
      if (this.jamiId.length > 0) {
        Row({ space: 8 }) {
          // Swift `Text(L10n.Global.identifier + ":")` — same view-composed colon as the name row.
          Text(this.labelWithColon($r('app.string.swarm_identifier').id))
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))
          // Swift `.font(.footnote).truncationMode(.middle)`; the capture wraps the 40-char id
          // over two 17 pt lines at [115,368][295,402] rather than truncating it.
          Text(this.jamiId)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Start)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
            .maxLines(2)
            .layoutWeight(1)
            .copyOption(CopyOptions.LocalDevice)
            .editMenuOptions(COPY_SHARE_MENU)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // Swift: `.padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(12)`.
    // Capture: card x 16..377, y 290.2..418.7, fill #F2F2F7, radius 12, 16 pt inner padding.
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .backgroundColor($r('sys.color.comp_background_gray'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
  }

  /** Swift `private var passwordSection` — conditionalVariants[password_required]. */
  @Builder
  private passwordSection() {
    Column({ space: 8 }) {
      // Swift `.font(.callout).foregroundColor(Color(UIColor.secondaryLabel))`; the capture
      // renders it #8A8A8E across two lines at [16,342][376,382].
      Text($r('app.string.migrate_account_password_explanation'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.secondary_label'))
        .textAlign(TextAlign.Start)
        .width('100%')
      PasswordFieldView({
        text: $password,
        placeholder: $r('app.string.global_enter_password'),
        identifier: 'accountMigrationPassword'
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `private var actionButtons` — migrateButton then removeButton. */
  @Builder
  private actionButtons() {
    Column({ space: 15 }) {
      // Swift migrateButton: `.padding(.vertical, 12).background(Color.jami)
      // .foregroundColor(.white).cornerRadius(12)`. Capture: [16,438.7][377,483.1] — 44.4 high,
      // fill sampled #00345F, which is exactly app.color.jami.
      // `.disabled()` does not restyle that label: iOS keeps it jami blue with white text while
      // disabled (T-1740). A disabled ArkUI Button always dims itself to 0.4, so the control is
      // the label itself, a Text with the Button's look (Medium weight) and button role, which
      // `.enabled(false)` blocks without restyling.
      Text($r('app.string.migrate_account_migrate_button'))
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .padding({ top: 12, bottom: 12 })
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.jami'))
        .fontColor($r('sys.color.font_on_primary'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .enabled(!this.migrateDisabled())
        .id('accountMigrationMigrate')
        .onClick(() => {
          this.migrate();
        })
      // Swift removeButton: same shape, `secondarySystemBackground` fill and `.red` label.
      // Capture: [16,498.1][377,542.5], fill #F2F2F7, text #FF3B30 (the destructive role).
      Button($r('app.string.global_remove_account'))
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .padding({ top: 12, bottom: 12 })
        .backgroundColor($r('sys.color.comp_background_gray'))
        .fontColor($r('sys.color.warning'))
        .fontSize($r('sys.float.Body_L'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .enabled(!this.isLoading)
        .id('accountMigrationRemoveAccount')
        .onClick(() => {
          this.deleteAccount();
        })
    }
    .width('100%')
  }

  build() {
    // Swift `.overlay(loadingOverlay)` — the scroll content with the dimming layer above it.
    Stack() {
      Scroll() {
        Column({ space: 20 }) {
          this.toolbarBuilder()
          // Swift `private var headerView` — `.multilineTextAlignment(.center).padding(.vertical)`.
          // Capture: [90,113][302,134], centred, 17 pt on the primary label colour.
          Text($r('app.string.migrate_account_explanation'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .padding({ top: 16, bottom: 16 })
          this.profileSection()
          this.accountInfoSection()
          // conditionalVariants[password_required]: `if model.needsPassword { passwordSection }`.
          if (this.isPasswordRequired) {
            this.passwordSection()
          }
          this.actionButtons()
          // Swift `Spacer()`.
          Blank()
          // conditionalVariants[migration_failed]: `.alert(isPresented: model.error != nil)`,
          // raised when `migrationCompleted` came back false.
          if (this.isMigrationFailed) {
            Column({ space: 8 }) {
              Text($r('app.string.migrate_account_error'))
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('app.color.label'))
                .textAlign(TextAlign.Center)
                .width('100%')
              Button($r('app.string.global_ok'))
                .type(ButtonType.Normal)
                .width('100%')
                .constraintSize({ minHeight: 44 })
                .padding({ top: 12, bottom: 12 })
                .backgroundColor($r('sys.color.comp_background_gray'))
                .fontColor($r('app.color.jami'))
                .fontSize($r('sys.float.Body_L'))
                .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
                .id('accountMigrationErrorOk')
                .onClick(() => {
                  // Swift's alert binding setter: `model.error = nil`.
                  this.errorText = '';
                  this.isMigrationFailed = false;
                })
            }
            .width('100%')
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
            .backgroundColor($r('sys.color.comp_background_gray'))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          }
        }
        .width('100%')
        // Swift `.padding(.horizontal)` on the VStack — the 16 pt page margin every band in
        // the capture sits on (card, buttons and password field all run x 16..377).
        .padding({ start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)

      // Swift `private var loadingOverlay` — `Color.black.opacity(0.4)` over a ProgressView.
      if (this.isLoading) {
        Column() {
          // Swift: `ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))`.
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Color.White)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // Swift: `Color.black.opacity(0.4).ignoresSafeArea()` — a value the source hardcodes,
        // so it is copied verbatim rather than mapped to a token.
        .backgroundColor('#66000000')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.Block)
      }
    }
    .width('100%')
    .height('100%')
    // The capture's page is plain white `systemBackground`; never leave the surface unpainted,
    // or it follows the device colour mode and renders black where the reference is light.
    // NOT expandSafeArea: unlike the splash, this page's content is inset — the capture puts
    // its bar at y 53..97, below the status bar. Only the loading overlay ignores the insets,
    // which is what the source says (`Color.black.opacity(0.4).ignoresSafeArea()`).
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_account_migration')
  }
}
