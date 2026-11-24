/*
 * screen_account_summary — "Account Summary (settings root)", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSummaryVM.swift + AccountSummaryView.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 *   Ring/Ring/Features/Settings/SettingsCoordinator.swift
 *
 * SettingsCoordinator.start() makes it the root of its own navigation stack and presents that
 * stack over the smart list, so Back / Close return to the smart list.
 *
 * S3 built the REAL component tree of `AccountSummaryView.body`, unstyled.
 * S4 adds the state architecture: every value below is BOUND to the migrated data layer
 *   (svc_accounts / svc_profiles / svc_profile_store) — nothing is transcribed from the
 *   capture — every control is wired to the service call its Swift handler makes, and all six
 *   conditionalVariants are real conditions in the render body.
 *
 * OVERLAY HOST. screen_edit_profile (.sheet), screen_qr_code_presenter (.sheet) and
 * screen_name_registration (the in-place NameRegistrationView) are presented from here.
 *
 * S5 styles that structure against results/traversal-source/pages/AccountSummaryView/*.
 * The source is a SwiftUI `Form`, i.e. iOS 15+ INSET-GROUPED — a look iOS renders with no
 * line of Swift (mapping-tables.md §7): a grey page, white content-sized cards inset from
 * both edges, section headers indented to the cards' content edge, and separators inset to
 * each row's text leading edge. Every value below is a design TOKEN read off the iOS
 * semantic role (ios-to-harmonyos-design-tokens.md), never a number eyeballed off the PNG;
 * the two literals are sizes the Swift hardcodes (`frame(width: 18, height: 18)`,
 * `frame(width: 15, height: 15)`) plus the 44 vp iOS bar/row height.
 *
 * The one token that deviates from state.json's styleBaseline: the page background. The
 * baseline's `pageBackground` is `background_primary` (white), taken from the plain-`List`
 * smart list; this screen is genuinely grouped, so its page is `background_secondary` and
 * its cards carry the baseline's `cardBackground`.
 *
 * S6 finalizes that style: the six conditionalVariants each get their finished appearance,
 * and the states the capture cannot show are authored here.
 *
 * The action-contract controls this screen owes, by their contract labels: Enable account,
 * Manage account, Manage SIP account, Linked devices, Invite friends, QR code,
 * Register a username, Edit profile, Settings, Close, Settings (gear). Every one is built
 * below and carries its source slug. "Edit profile" is icon-only in the source (a bare
 * pencil), so its label reaches a screen reader through `.accessibilityText` rather than
 * through any rendered text — the shipped string resource spells it `Edit Profile`, which
 * is the app's own casing and is not this screen's to change.
 *
 * States authored in S6, none of which the single capture shows:
 *   - loading: the account vCard is read back from the sandbox and then relayed by
 *     ProfilesService, so the profile name is pending for the first frames.
 *   - failure: `describeError()` output from any service call, and — separately — the
 *     DAEMON GAP. `AccountsService.enableAccount` writes the local configuration and then
 *     reports `account.enable` unavailable, because pushing the change needs the prebuilt
 *     C++ jami daemon, which has no HarmonyOS build. That is surfaced as an explicit
 *     in-place notice under the toggle, never as a fake success and never by disabling the
 *     control (the toggle stays live: the LOCAL half of the write really did happen).
 *   - registration overlay: the source ZStacks NameRegistrationView over the whole Form and
 *     the capture (register_username.png) shows the page behind it dimmed and inert.
 */
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { PlatformAdaptiveNavView } from '../components/PlatformAdaptiveNav';
import { QRCodeSheet } from './QRCodePage';
import { SettingsRow } from '../components/SettingsRow';
import { ShareButtonView } from '../components/ShareButton';
import { ToggleCell } from '../components/ToggleCell';

import { AvatarSize } from '../common/JamiConstants';
import { describeError } from '../common/ErrorText';
import { DisposeBag } from '../common/Observable';
import { NameRegistrationState } from '../common/NameService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
// feat_persistence_profiles (svc_profile_store, @ohos.file.fs): the account vCard this screen
// renders is READ BACK from the sandbox here, which is what makes an edited profile survive a
// relaunch. ProfilesService triggers its relay off the same store.
import { ProfileStore } from '../common/ProfileStore';
// The daemon gap this screen's enable toggle runs into — see the header note.
import { DaemonUnavailableError } from '../common/DaemonService';
import { AccountModel, AccountState, accountStateFromRaw } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { Profile } from '../model/Profile';

import { EditProfileSheet } from './EditProfilePage';
import { NameRegistrationOverlay } from './RegisterAUsernamePage';

/**
 * The router params `EntryAbility.routeToTarget` attaches when a deep link names an overlay
 * THIS page hosts (`RouteAliases.resolveTargetOverlay`).
 */
interface AccountSummaryRouteParams {
  overlayScreen?: string;
}

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AccountSummary';

/** The parent coordinator's root — Swift `SettingsCoordinator.finish()` returns here. */
const SMART_LIST_PAGE: string = 'pages/SmartListConversationsHomePage';

/**
 * The separator inset of a row that leads with a glyph. iOS insets a grouped separator to the
 * row's TEXT leading edge, which here is the row's own padding (elements_margin_horizontal_l,
 * 16) + the glyph the source hardcodes at 18 + the gap (card_margin_start, 12). Composed from
 * the tokens rather than measured off the screenshot.
 */
const SEPARATOR_INSET: number = 46;
/** iOS navigation-bar / grouped-row height — a platform constant, not an app value. */
const BAR_HEIGHT: number = 44;

/**
 * SwiftUI `.textSelection(.enabled)` offers exactly Copy and Share on the iPhone; the
 * HarmonyOS selection menu adds Translate, Search and more (T-0892).
 */
class CopyShareMenu implements EditMenuOptions {
  onCreateMenu(menuItems: Array<TextMenuItem>): Array<TextMenuItem> {
    return menuItems.filter((item: TextMenuItem): boolean =>
      item.id.equals(TextMenuItemId.COPY) || item.id.equals(TextMenuItemId.SHARE));
  }

  onMenuItemClick(menuItem: TextMenuItem, range: TextRange): boolean {
    return false;
  }
}

export const COPY_SHARE_MENU: CopyShareMenu = new CopyShareMenu();
/**
 * `Color.jamiFailure` from Ring/Ring/Extensions/UIColor+Ring.swift:99, verbatim. It is a
 * literal rather than a colour resource because the app carries no jami_failure colour and
 * resources are not this pass's to write; the consequence is that it has no dark-mode
 * variant, which is reported as a carry-forward.
 */
const JAMI_FAILURE: string = '#F00000';

/**
 * Swift `Image(systemName: "envelope").resizable().aspectRatio(contentMode: .fit)
 * .frame(width: 18, height: 18)`: the SF envelope drawn 18 wide. No HarmonyOS symbol has its
 * shape — `sys.symbol.envelope` lacks the two lower diagonals of the SF glyph (T-0495) — so it is
 * an outline on a 24-unit grid, 24x18 centred in the square as aspect-fit leaves it: rounded
 * body, the flap V, and the two lines up from the bottom corners.
 */
const ENVELOPE_WIDTH: number = 18;
const ENVELOPE_GRID: number = 24;
const ENVELOPE_COMMANDS: string =
  'M3.5 4.5L20.5 4.5Q22.5 4.5 22.5 6.5L22.5 17.5Q22.5 19.5 20.5 19.5L3.5 19.5Q1.5 19.5 1.5 17.5' +
  'L1.5 6.5Q1.5 4.5 3.5 4.5ZM2.2 5.4L12 13.4L21.8 5.4M2.2 18.8L9.2 11.6M21.8 18.8L14.8 11.6';
const ENVELOPE_STROKE: number = 1.5;
/** Swift `.padding(.trailing, 5)` on the image plus the HStack's default 8pt spacing. */
const ENVELOPE_GAP: number = 13;

/** `List(.insetGrouped)`: a white, content-sized card inset from both page edges. */
@Styles function groupedCard() {
  .width('100%')
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .margin({ bottom: $r('sys.float.margin_level2') })
}

/** The padding of one grouped row inside a card. */
@Styles function groupedRow() {
  .width('100%')
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      top: $r('sys.float.padding_level6'),
      bottom: $r('sys.float.padding_level6')
    })
}

@Entry
@Component
struct AccountSummarySettingsRootPage {
  // ── bound content — every site in the plan's bindingContract ───────────────────────────
  /** bindingContract[profile name] <- Profile.alias (Swift `AccountSummaryVM.profileName`). */
  @State profileName: string = '';
  /** bindingContract[registered name] <- AccountModel.registeredName. */
  @State registeredName: string = '';
  /** bindingContract[jami id] <- AccountModel.jamiId. */
  @State jamiId: string = '';
  /** bindingContract[avatar] <- svc_profiles / svc_profile_store (the vCard PHOTO payload). */
  @State avatar: string = '';
  /** bindingContract[status] <- AccountModel.status, resolved by `getAccountStatus`. */
  @State status: ResourceStr = $r('app.string.account_status_unknown');

  // ── branch selectors (conditionalVariants) ─────────────────────────────────────────────
  /** conditionalVariants[sip_account]: `model.account.type == .sip`. */
  @State isSipAccount: boolean = false;
  /** conditionalVariants[jami_account]: `model.account.type == .ring`. */
  @State isJamiAccount: boolean = true;
  /** conditionalVariants[jams_account]: `model.account.isJams`. */
  @State isJamsAccount: boolean = false;
  /** conditionalVariants[no_registered_name]: registeredName empty, or equal to the jami id. */
  @State isNoRegisteredName: boolean = true;
  /** conditionalVariants[registration_overlay]: Swift `showAccountRegistration == true`. */
  @State isRegistrationOverlay: boolean = false;
  /** conditionalVariants[account_disabled]: the enable toggle is off -> status shows offline. */
  @State isAccountDisabled: boolean = false;

  /** True while svc_accounts / svc_profiles are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * THE DAEMON GAP, surfaced in place. True once `AccountsService.enableAccount` has written
   * the local configuration and reported `account.enable` unavailable — the change is real
   * on this device and cannot be pushed anywhere. Cleared on the next toggle.
   */
  @State showDaemonNotice: boolean = false;

  /** AppStorage['currentAccountId'], written by svc_accounts (screen_smart_list writes it). */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `model.accountInfoToShare` — the "contact me on Jami" payload of the share sheet. */
  @State accountInfoToShare: string = '';

  /** screen_edit_profile — presentation: sheet, hostScreen: screen_account_summary. */
  @State showEditProfile: boolean = false;
  /** screen_qr_code_presenter — presentation: sheet, hostScreen: screen_account_summary. */
  @State showQRCode: boolean = false;

  /** Swift `let disposeBag = DisposeBag()` — the status subscription `subscribeStatus` opens. */
  private bag: DisposeBag = new DisposeBag();
  /** Guards the deep-link overlay: `onPageShow` fires again on every return from a push. */
  private deepLinkOverlayOpened: boolean = false;

  /** screen_name_registration — presentation: popup, hostScreen: screen_account_summary. */
  private nameRegistrationDialog: CustomDialogController = new CustomDialogController({
    // Swift `NameRegistrationView(isPresented: $showAccountRegistration, ...)` — the overlay
    // writes the host's own flag back through the binding when Cancel or OK closes it.
    builder: NameRegistrationOverlay({ isPresented: $isRegistrationOverlay }),
    autoCancel: true,
    customStyle: true,
    // S6: the source's CustomAlert is CENTRED over the dimmed page — capture S0277 puts the
    // card at y 325..558 of 852. `DialogAlignment.Default` anchors an ArkUI dialog to the
    // BOTTOM of the screen, which is a HarmonyOS default the source never asks for.
    alignment: DialogAlignment.Center,
    // Swift: dismissing NameRegistrationView sets `showAccountRegistration = false` and calls
    // `model.nameRegistered()`, which re-resolves the account's name.
    cancel: () => {
      this.isRegistrationOverlay = false;
      this.nameRegistered();
    }
  });

  // ── lifecycle ──────────────────────────────────────────────────────────────────────────
  aboutToAppear(): void {
    this.subscribeStatus();
    this.refresh();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
      // A CustomDialog outlives the page that opened it: popped with the registration overlay
      // up, its own full-screen mask stays on top of whatever page comes next and eats every
      // tap there (the symptom is a gesture that lands with a byte-identical UI tree after).
      // Closing it here ties the overlay's lifetime to the host's, and clearing the gate
      // releases the [registration_overlay] HitTestMode.Block the build() body applies.
      this.isRegistrationOverlay = false;
      this.nameRegistrationDialog.close();
    }
  }

  /** Swift `nameRegistered()` is called back after a successful registration. */
  onPageShow(): void {
    this.refresh();
    this.openDeepLinkedOverlay();
  }

  /**
   * `RouteAliases` resolves screen_edit_profile to THIS page plus an overlay name, so a deep
   * link that names it arrives here and the sheet has to be opened on arrival. Guarded because
   * `onPageShow` fires again on every return from a push.
   */
  private openDeepLinkedOverlay(): void {
    if (this.deepLinkOverlayOpened) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    const params: AccountSummaryRouteParams = raw as AccountSummaryRouteParams;
    const overlay: string = params.overlayScreen === undefined ? '' : params.overlayScreen;
    if (overlay.length === 0) {
      return;
    }
    this.deepLinkOverlayOpened = true;
    if (overlay === 'screen_edit_profile') {
      this.openEditProfile();
    } else if (overlay === 'screen_qr_code_presenter') {
      this.openQRCode();
    } else if (overlay === 'screen_name_registration') {
      this.openNameRegistration();
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'deep link named an overlay this page does not host: %{public}s', overlay);
    }
  }

  // ── data layer ─────────────────────────────────────────────────────────────────────────
  /**
   * Swift `AccountSummaryVM.init`: the coordinator hands the VM the account it was started
   * for. The migrated equivalent is the account id in AppStorage (svc_accounts writes it),
   * falling back to the service's own current account.
   */
  private currentAccount(): AccountModel | null {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    if (this.currentAccountId.length > 0) {
      const byId: AccountModel | null = registry.accountService.getAccount(this.currentAccountId);
      if (byId !== null) {
        return byId;
      }
    }
    return registry.accountService.currentAccount;
  }

  /**
   * Swift `AccountProfileObserver.resolveAccountName(from:)` — the registered name, else the
   * jami id. (The Swift UserDefaults[registeredNamesKey] fallback has no migrated writer:
   * NameService's contract declares no such key, so there is nothing cached to read.)
   */
  private resolveAccountName(account: AccountModel): string {
    return account.registeredName.length > 0 ? account.registeredName : account.jamiId;
  }

  /** Swift `AccountSummaryVM.getAccountStatus(state:)`, verbatim including the enable guard. */
  private getAccountStatus(state: AccountState, enabled: boolean): ResourceStr {
    if (!enabled) {
      return $r('app.string.account_status_offline');
    }
    if (state === AccountState.REGISTERED) {
      return $r('app.string.account_status_online');
    }
    if (state === AccountState.TRYING) {
      return $r('app.string.account_status_connecting');
    }
    if (state === AccountState.ERROR_REQUEST_TIMEOUT || state === AccountState.ERROR_NOT_ACCEPTABLE ||
      state === AccountState.ERROR_SERVICE_UNAVAILABLE || state === AccountState.ERROR_EXIST_STUN ||
      state === AccountState.ERROR_CONF_STUN || state === AccountState.ERROR_HOST ||
      state === AccountState.ERROR_NETWORK || state === AccountState.ERROR_AUTH ||
      state === AccountState.ERROR) {
      return $r('app.string.account_status_connectionerror');
    }
    return $r('app.string.account_status_unknown');
  }

  /**
   * Swift `AccountSummaryVM.subscribeStatus()` — the registration-state events of THIS
   * account re-resolve the status label.
   */
  private subscribeStatus(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(registry.accountService.sharedResponseStream.subscribe(
      (event: ServiceEvent): void => {
        if (event.eventType !== ServiceEventType.REGISTRATION_STATE_CHANGED) {
          return;
        }
        const eventAccount: string | null = event.getEventInput(ServiceEventInput.ACCOUNT_ID);
        const account: AccountModel | null = this.currentAccount();
        if (account === null || eventAccount === null || eventAccount !== account.id) {
          return;
        }
        // Swift AccountSummaryVM reads the state from the event: RegistrationStateChanged is
        // raised before VolatileDetailsChanged, so account.status still held the old state.
        const raw: string | null = event.getEventInput(ServiceEventInput.REGISTRATION_STATE);
        const state: AccountState | null = raw === null ? null : accountStateFromRaw(raw);
        if (state === null) {
          return;
        }
        this.status = this.getAccountStatus(state, !this.isAccountDisabled);
      }));

    // Swift `nameRegisteredCb` -> `model.nameRegistered()`. The overlay closes itself with
    // `controller.close()` on success, which never fires the dialog's `cancel` callback, and
    // `account.registeredName` lags the daemon's account-details refresh; Swift read the name
    // NameService had just stored. So the success event of THIS account carries the name here.
    this.bag.add(registry.nameService.sharedRegistrationStatus.subscribe(
      (event: ServiceEvent): void => {
        if (event.eventType !== ServiceEventType.NAME_REGISTRATION_ENDED ||
          event.getEventInput(ServiceEventInput.STATE) !== NameRegistrationState.SUCCESS as string ||
          event.getEventInput(ServiceEventInput.ACCOUNT_ID) !== this.currentAccountId) {
          return;
        }
        const name: string | null = event.getEventInput(ServiceEventInput.NAME);
        if (name === null || name.length === 0) {
          this.nameRegistered();
          return;
        }
        this.registeredName = name;
        this.isNoRegisteredName = name === this.jamiId;
      }));

    // Swift `AccountsService.currentAccountChanged` — the settings root follows the switch.
    this.bag.add(registry.accountService.currentAccountChanged.subscribe(
      (account: AccountModel | null): void => {
        this.applyAccount(account);
      }));

    // The daemon gap raised by THIS screen's own control: `enableAccount` reports
    // `account.enable`. (The hosted Edit-Profile sheet's Save is libjami's real updateProfile,
    // so it raises none.) Every other feature's gap belongs to the screen that asked for it, so
    // the filter stays exact rather than "any unavailable event".
    this.bag.add(registry.daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'account.enable') {
          this.showDaemonNotice = true;
        }
      }));
  }

  /** Reads every bound value off the services the plan assigns this screen. */
  private refresh(): void {
    this.isLoading = true;
    try {
      this.applyAccount(this.currentAccount());
      this.errorText = '';
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'refresh failed: %{public}s', this.errorText);
      this.isLoading = false;
    }
    // No `finally { isLoading = false }`: the profile arrives through the ProfilesService
    // relay, so the load ends where the value lands (applyProfileValues) or where there is
    // no account to load one for (applyAccount's null branch).
  }

  /** Swift `AccountSummaryVM.init` + `updateProfileDetails(account:)`. */
  private applyAccount(account: AccountModel | null): void {
    if (account === null) {
      this.profileName = '';
      this.registeredName = '';
      this.jamiId = '';
      this.avatar = '';
      this.accountInfoToShare = '';
      this.isNoRegisteredName = true;
      this.status = this.getAccountStatus(AccountState.UNREGISTERED, false);
      this.isLoading = false;
      return;
    }
    this.currentAccountId = account.id;
    this.jamiId = account.jamiId;
    this.registeredName = this.resolveAccountName(account);
    this.isNoRegisteredName =
      this.registeredName.length === 0 || this.registeredName === this.jamiId;
    this.isSipAccount = account.type === AccountType.SIP;
    this.isJamiAccount = !this.isSipAccount;
    this.isJamsAccount = account.isJams;
    this.isAccountDisabled = !account.enabled;
    this.status = this.getAccountStatus(account.status, account.enabled);

    const share: string[] | null = ServiceRegistry.shared().accountService.accountInfoToShare;
    this.accountInfoToShare = share === null ? '' : share.join('\n');

    this.applyProfile(account.id);
  }

  /**
   * Swift `AccountProfileObserver.updateProfileDetails(account:)` — the account's own vCard.
   * feat_persistence_profiles: the stored vCard (svc_profile_store, @ohos.file.fs) is the
   * value that survives a relaunch, so it seeds the render; the service relay then keeps it
   * current for as long as the page is up.
   */
  private applyProfile(accountId: string): void {
    const stored: Profile | null = new ProfileStore().accountProfile(accountId);
    if (stored !== null) {
      this.applyProfileValues(stored);
    }
    this.bag.add(ServiceRegistry.shared().profileService.getAccountProfile(accountId).subscribe(
      (profile: Profile): void => {
        // Swift guards on `account.id == self.selectedAccount`: a late profile for an account
        // the user has since switched away from must not overwrite the current one.
        if (accountId !== this.currentAccountId) {
          return;
        }
        this.applyProfileValues(profile);
      }));
  }

  private applyProfileValues(profile: Profile): void {
    this.profileName = profile.alias === null ? '' : profile.alias;
    this.avatar = profile.photo === null ? '' : profile.photo;
    this.isLoading = false;
  }

  // ── handlers — every controlInventory entry, wired to its Swift effect ─────────────────
  /** Swift `showEditPrpofile = true` -> `.sheet` presenting EditProfileView. */
  private openEditProfile(): void {
    this.showEditProfile = true;
  }

  /** Swift `showQRcode = true` -> `.sheet` presenting QRCodePresenter. */
  private openQRCode(): void {
    this.showQRCode = true;
  }

  /** Swift `withAnimation { showAccountRegistration = true }` -> NameRegistrationView. */
  private openNameRegistration(): void {
    this.isRegistrationOverlay = true;
    this.nameRegistrationDialog.open();
  }

  /** Swift `model.nameRegistered()` — re-resolve the name after a successful registration. */
  private nameRegistered(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      return;
    }
    this.registeredName = this.resolveAccountName(account);
    this.isNoRegisteredName =
      this.registeredName.length === 0 || this.registeredName === this.jamiId;
  }

  /**
   * Swift `Toggle(isOn: Binding(get:set:))` -> `model.enableAccount(enable:)` ->
   * `AccountsService.enableAccount(accountId:enable:)`, which writes ConfigKey.accountEnable.
   */
  private setAccountEnabled(enable: boolean): void {
    const accountEnabled: boolean = !this.isAccountDisabled;
    if (accountEnabled === enable) {
      // Swift `if self.accountEnabled == enable { return }`.
      return;
    }
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'enable toggled with no account loaded');
      return;
    }
    this.isAccountDisabled = !enable;
    // Cleared first: `enableAccount` raises the gap event synchronously, so the subscription
    // above sets it again on the way back out if the daemon is still missing.
    this.showDaemonNotice = false;
    ServiceRegistry.shared().accountService.enableAccount(account.id, enable);
    this.status = this.getAccountStatus(account.status, enable);
  }

  /** Swift: `NavigationLink -> ManageAccountView`. */
  private openManageAccount(): void {
    router.pushUrl({ url: 'pages/ManageAccountPage' });
  }

  /** Swift: `NavigationLink -> ManageSipAccountView` (conditionalVariants[sip_account]). */
  private openManageSipAccount(): void {
    router.pushUrl({ url: 'pages/ManageSIPAccountPage' });
  }

  /** Swift: `NavigationLink -> LinkedDevicesView` (conditionalVariants[jami_account]). */
  private openLinkedDevices(): void {
    router.pushUrl({ url: 'pages/LinkedDevicesPage' });
  }

  /** Swift: `NavigationLink -> SettingsSummaryView`. */
  private openSettingsSummary(): void {
    router.pushUrl({ url: 'pages/SettingsSummaryPage' });
  }

  /**
   * Swift: `SettingsState.dismiss -> SettingsCoordinator.finish()` — the settings coordinator
   * hands control back to its PARENT (the smart list); it never leaves the app.
   *
   * This page is a coordinator root, so a cold deep link lands it as the ONLY entry in the
   * stack (`InitialLoadingPage.routeDeepLink` seeds no parent under a root). `back()` there
   * pops the last page and terminates the app — `AceRouter: Router back start ExitToDesktop`.
   * With nothing beneath, go to the parent root instead of popping.
   */
  private dismiss(): void {
    if (router.getLength() === '1') {
      router.replaceUrl({ url: SMART_LIST_PAGE }).catch((error: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s',
          SMART_LIST_PAGE, describeError(error));
      });
      return;
    }
    router.back();
  }

  /** Swift `profileName()` — the placeholder is the source's own string, not a captured value. */
  private displayProfileName(): ResourceStr {
    return this.profileName.length > 0
      ? this.profileName
      : $r('app.string.account_page_profile_name_not_selected');
  }

  // ── builders ───────────────────────────────────────────────────────────────────────────
  @Builder
  editProfileSheet() {
    // Swift `EditProfileView(accountModel: self, isPresented: $showEditPrpofile)` — the sheet's
    // view model is seeded from THIS screen's account values, and writes `accountModel.avatar`
    // back on save.
    EditProfileSheet({
      isPresented: $showEditProfile,
      accountAvatar: $avatar,
      accountProfileName: this.profileName,
      accountDisplayName: this.registeredName
    })
  }

  /**
   * Swift `.sheet(isPresented: $showQRcode) { QRCodePresenter(...) }`.
   *
   * The sheet body is screen_qr_code_presenter's OWN struct (pages/QRCodePage.ets), the same
   * shape screen_edit_profile uses: the overlay screen carries its `.id('screen_…')` marker,
   * so the replay can prove which screen it landed on. It composes comp_qr_code_view, the
   * component the plan declares for that screen.
   */
  @Builder
  qrCodeSheet() {
    QRCodeSheet({ isPresented: $showQRCode, qRImage: this.jamiId })
  }

  /**
   * The failure state of any service call this screen makes. The source has no error UI at
   * all — its services are local to the process — so the FORM here is the platform's own
   * inline notice rather than something transcribed: the failure glyph in `Color.jamiFailure`
   * beside the message, on the grouped page, never a panel that replaces the screen (the
   * profile/account cards stay up, android-ui-fidelity.md §7).
   */
  @Builder
  errorNotice() {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
        .fontSize(18)
        .fontColor([JAMI_FAILURE])
        .margin({ right: $r('sys.float.ohos_id_card_margin_start') })
      Text(this.errorText)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4')
    })
  }

  /**
   * THE DAEMON GAP, in place under the toggle that hit it. The toggle stays live and its
   * value stays where the user put it — the LOCAL configuration write really happened — and
   * this states plainly that the change reaches nothing beyond this device. Never a toast
   * (it would be gone before it was read) and never `.enabled(false)`.
   */
  @Builder
  daemonGapNotice() {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
        .fontSize(15)
        .fontColor([JAMI_FAILURE])
        .margin({ right: $r('sys.float.ohos_id_card_margin_start') })
      Text($r('app.string.daemon_not_available'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      bottom: $r('sys.float.padding_level6')
    })
  }

  /** ENVELOPE_COMMANDS scaled from its grid to ENVELOPE_WIDTH, in the px a Path draws in. */
  private envelopeCommands(): string {
    const scale: number = this.getUIContext().vp2px(ENVELOPE_WIDTH) / ENVELOPE_GRID;
    return ENVELOPE_COMMANDS.replace(/\d+(\.\d+)?/g, (n: string): string => `${Number(n) * scale}`);
  }

  /** Swift: the ShareButtonView label — `Image("envelope") + Text(L10n.Smartlist.inviteFriends)`. */
  @Builder
  inviteFriendsLabel() {
    Row() {
      Blank()
      // Swift: `.frame(width: 18, height: 18).padding(.trailing, 5)` inside an HStack,
      // `.foregroundColor(.jami)` over the whole Group.
      Path()
        .width(ENVELOPE_WIDTH)
        .height(ENVELOPE_WIDTH)
        .commands(this.envelopeCommands())
        .fill(Color.Transparent)
        .stroke($r('app.color.jami'))
        .strokeWidth(ENVELOPE_STROKE)
        .margin({ right: ENVELOPE_GAP })
      Text($r('app.string.smartlist_invite_friends'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** Swift `profileSection()` — avatar, profile name, the pencil, the whole row tappable. */
  @Builder
  profileSection() {
    Text($r('app.string.account_page_profile_header'))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        top: $r('sys.float.padding_level8'),
        bottom: $r('sys.float.padding_level4')
      })
    Column() {
      Row() {
        AvatarSwiftUIView({
          avatarData: this.avatar,
          displayText: this.profileName.length > 0 ? this.profileName : this.registeredName,
          isGroup: false,
          avatarSize: AvatarSize.ACCOUNT_60
        })
        // The profile's load state. iOS reads the vCard synchronously, so the source has no
        // such state; here the value is relayed by ProfilesService and is genuinely pending
        // for the first frames, so the slot it lands in carries the spinner rather than
        // flashing "Name not selected" at an account that has a name.
        if (this.isLoading && this.profileName.length === 0) {
          Row() {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('sys.color.font_secondary'))
          }
          .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
        } else {
          // Swift `profileName()`: the placeholder is `.foregroundColor(.gray)` at the
          // default body size, a real name is `.font(.title3)` in the plain label colour.
          Text(this.displayProfileName())
            .fontSize(this.profileName.length > 0
              ? $r('sys.float.Title_S')
              : $r('sys.float.Body_L'))
            .fontColor(this.profileName.length > 0
              ? $r('app.color.label')
              : $r('app.color.secondary_label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
            .layoutWeight(1)
        }
        // Swift `editProfileButton()` — `VStack { Image("pencil"); Spacer() }`, so the glyph
        // pins to the TOP of the row, 15x15, `.foregroundColor(Color.secondary)`.
        SymbolGlyph($r('sys.symbol.pencil_line'))
          .fontSize(15)
          .fontColor([$r('app.color.secondary_label')])
          .alignSelf(ItemAlign.Start)
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      // Swift `.padding(.vertical, 8)` on top of the Form cell's own inset.
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        top: $r('sys.float.padding_level8'),
        bottom: $r('sys.float.padding_level8')
      })
      // feat_accessibility: the control is a bare pencil, so its LABEL has to be spoken
      // rather than read off the screen; the hint stays a hint.
      .accessibilityText($r('app.string.account_page_edit_profile'))
      .accessibilityDescription($r('app.string.accessibility_account_summary_edit_profile_hint'))
      .id('account_summary_edit_profile')
      .onClick(() => {
        this.openEditProfile();
      })
    }
    .groupedCard()
  }

  /**
   * Swift: `Section(header: accountHeader) { HStack { Text(status); Spacer(); Toggle } }`.
   * conditionalVariants[account_disabled]: `getAccountStatus` returns statusOffline whenever
   * the enable toggle is off, whatever the registration state says.
   */
  @Builder
  accountStatusSection() {
    Text($r('app.string.account_page_account_header'))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        top: $r('sys.float.padding_level8'),
        bottom: $r('sys.float.padding_level4')
      })
    Column() {
      ToggleCell({
        toggleText: this.isAccountDisabled
          ? $r('app.string.account_status_offline')
          : this.status,
        isOn: !this.isAccountDisabled,
        identifier: 'account_summary_enable_account',
        onToggle: (value: boolean): void => {
          this.setAccountEnabled(value);
        }
      })
        // The capture records a tap on the cell's STATUS LABEL as its own action (slug
        // `online`, S0119) — a separate target from the switch, which carries
        // `account_summary_enable_account` on the Toggle inside ToggleCell. The source
        // StaticText has no identifier of its own, so the slug is its label; the cell root is
        // the addressable node for it here.
        .id('online')
      if (this.showDaemonNotice) {
        this.daemonGapNotice()
      }
    }
    .groupedCard()
  }

  /**
   * Swift `usernameView()` + the jami-id row with its QR-code button.
   * conditionalVariants[jams_account] and [no_registered_name] are the two branches below.
   */
  @Builder
  userIdentitySection() {
    Column() {
      if (this.isJamsAccount) {
        // A JAMS account always renders its registered name as plain text — no register
        // button. Swift `.textSelection(.enabled)` on both name branches and on the jami id
        // -> `.copyOption` + COPY_SHARE_MENU: a long press selects the text and offers Copy and
        // Share.
        Text(this.registeredName)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
          .editMenuOptions(COPY_SHARE_MENU)
          .groupedRow()
      } else if (this.isNoRegisteredName) {
        Row() {
          // Swift: the glyph and the label are one `Group { … }.foregroundColor(.jami)`.
          SymbolGlyph($r('sys.symbol.person_badge_checkmark'))
            .fontSize(18)
            .fontColor([$r('app.color.jami')])
            .margin({ right: $r('sys.float.ohos_id_card_margin_start') })
          Text($r('app.string.global_register_a_username'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
        }
        .alignItems(VerticalAlign.Center)
        .groupedRow()
        .id('account_summary_register_ausername')
        .onClick(() => {
          this.openNameRegistration();
        })
      } else {
        Text(this.registeredName)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
          .editMenuOptions(COPY_SHARE_MENU)
          .groupedRow()
      }

      // iOS draws the grouped row separator itself, inset to the row's text leading edge.
      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ left: SEPARATOR_INSET })

      Row() {
        // Swift `.truncationMode(.middle).lineLimit(1)` — the jami id elides in the MIDDLE.
        Text(this.jamiId)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .ellipsisMode(EllipsisMode.CENTER)
          .copyOption(CopyOptions.LocalDevice)
          .editMenuOptions(COPY_SHARE_MENU)
          .layoutWeight(1)
          .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
          // The capture records a tap on the jami-id row as its own action (S0115). The source
          // StaticText carries no accessibilityIdentifier, so the recorded slug is its LABEL —
          // the capture account's own jami id — and that literal is the only handle the replay
          // searches for. The rendered text stays bound to `this.jamiId`; only the addressing
          // handle is fixed.
          // ponytail: capture-account-specific slug; re-point it if the source gains a real
          // identifier for this row.
          .id('c3e25f906641164e829340b6a2fea30dc873b57e')
        SymbolGlyph($r('sys.symbol.qrcode'))
          .fontSize(18)
          .fontColor([$r('app.color.jami')])
          .accessibilityText($r('app.string.accessibility_account_summary_qr_code'))
          .id('account_summary_qrcode')
          // An 18 vp glyph is easy to miss on the device, and a missed tap opened nothing
          // (T-0431); UIKit gives a small button touch slop, so the target here is 44 vp.
          .responseRegion({ x: -13, y: -13, width: 44, height: 44 })
          .onClick(() => {
            this.openQRCode();
          })
          // One component binds one sheet, so the QR sheet mounts on its own trigger.
          // Swift QRCodePresenter `.optionalMediumPresentationDetents()`: a half-height sheet,
          // as the swarm QR sheet (SettingsViewSection); ArkUI's default is LARGE (T-1606).
          .bindSheet($$this.showQRCode, this.qrCodeSheet(),
            { detents: [SheetSize.MEDIUM], showClose: false })
      }
      .alignItems(VerticalAlign.Center)
      .groupedRow()
    }
    .groupedCard()
  }

  /** Swift: the `.sip` branch — one row, `SettingsRow(person.crop.circle, manageAccount)`. */
  @Builder
  sipAccountSection() {
    Column() {
      Row() {
        // SettingsRow fills its slot (T-0933): the slot is what the chevron leaves.
        Row() {
          SettingsRow({
            icon: $r('sys.symbol.person_crop_circle_fill'),
            title: $r('app.string.account_page_manage_account')
          })
        }
        .layoutWeight(1)
        // iOS draws a NavigationLink's disclosure chevron itself (mapping-tables.md §7).
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
      .groupedRow()
      .id('account_summary_manage_sip_account')
      .onClick(() => {
        this.openManageSipAccount();
      })
    }
    .groupedCard()
  }

  /** Swift: the Jami branch — manage account, linked devices, invite friends. */
  @Builder
  jamiAccountSection() {
    Column() {
      Row() {
        // SettingsRow fills its slot (T-0933): the slot is what the chevron leaves.
        Row() {
          SettingsRow({
            icon: $r('sys.symbol.person_crop_circle_fill'),
            title: $r('app.string.account_page_manage_account')
          })
        }
        .layoutWeight(1)
        // iOS draws a NavigationLink's disclosure chevron itself (mapping-tables.md §7).
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
      .groupedRow()
      .id('account_summary_manage_account')
      .onClick(() => {
        this.openManageAccount();
      })

      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ left: SEPARATOR_INSET })

      Row() {
        // SettingsRow fills its slot (T-0933): the slot is what the chevron leaves.
        Row() {
          SettingsRow({
            icon: $r('sys.symbol.link'),
            title: $r('app.string.account_page_linked_devices')
          })
        }
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
      .groupedRow()
      .id('account_summary_linked_devices')
      .onClick(() => {
        this.openLinkedDevices();
      })

      Divider()
        .strokeWidth(0.5)
        .color($r('sys.color.comp_divider'))
        .margin({ left: SEPARATOR_INSET })

      // feat_share_sheet — ShareButtonView hands accountInfoToShare (svc_accounts) to
      // @kit.ShareKit through common/ShareActions.ts, with its clipboard + toast fallback.
      ShareButtonView({
        infoToShare: this.accountInfoToShare,
        identifier: 'account_summary_invite_friends',
        titleResourceName: 'smartlist_invite_friends',
        // Arrow-bound: the label calls this page's envelopeCommands(), and a bare builder
        // reference would run with `this` set to ShareButtonView.
        content: (): void => {
          this.inviteFriendsLabel();
        }
      })
    }
    .groupedCard()
  }

  /** Swift `.navigationBarItems(leading: Close, trailing: gearshape -> SettingsSummaryView)`. */
  @Builder
  navigationBar() {
    // `.navigationBarTitleDisplayMode(.inline)`: iOS centres the title in the bar's own
    // optical row, independently of how wide the leading/trailing items are — so the title is
    // a centred layer, not a Row sibling (mapping-tables.md §7).
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.account_page_account_header'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      Row() {
        // Swift: `Text(L10n.Global.close).foregroundColor(.jami)` — a bar item, no chrome.
        Button($r('app.string.global_close'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .id('account_summary_close')
          .onClick(() => {
            this.dismiss();
          })
        Blank()
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor([$r('app.color.jami')])
          .accessibilityText($r('app.string.accessibility_account_summary_edit_settings_button'))
          .id('account_summary_settings_summary')
          .onClick(() => {
            this.openSettingsSummary();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(BAR_HEIGHT)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  build() {
    // @Entry's root must be a container component, so the source's navigation shell
    // (PlatformAdaptiveNavView) sits inside it rather than being the root itself.
    Column() {
      PlatformAdaptiveNavView() {
        Column() {
          this.navigationBar()

          if (this.errorText.length > 0) {
            this.errorNotice()
          }

          // Swift `Form { … }` — the scrolling section list. `Form` on iOS 15+ is the
          // inset-grouped style: cards inset from both page edges over a grey page.
          Scroll() {
            Column() {
              this.profileSection()
              this.accountStatusSection()
              if (this.isSipAccount) {
                this.sipAccountSection()
              } else if (this.isJamiAccount) {
                this.userIdentitySection()
                this.jamiAccountSection()
              }
            }
            .width('100%')
            .padding({
              left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
              right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
              bottom: $r('sys.float.margin_level2')
            })
          }
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        // conditionalVariants[registration_overlay] — the finished appearance of the branch.
        // Swift wraps the Form and NameRegistrationView in a ZStack; register_username.png
        // shows the WHOLE page behind it inert and dimmed, nav bar included, so the block
        // goes on the page column rather than on the Scroll alone (HitTestMode.None leaves
        // children tappable — the Close button and the gear stayed live under the overlay;
        // Block is the mode that stops the descendants). The dimming itself belongs to the
        // dialog's own mask: painting a second scrim here would double it.
        .hitTestBehavior(this.isRegistrationOverlay ? HitTestMode.Block : HitTestMode.Default)
        // `Form`/`List(.insetGrouped)` sits on systemGroupedBackground, not systemBackground —
        // PlatformAdaptiveNavView paints the plain-screen white, so the grouped page repaints
        // over it rather than leaving a white flood behind the cards.
        .backgroundColor($r('sys.color.background_secondary'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    // Both source sheets carry their own Cancel/Close, so the system close is suppressed.
    .bindSheet($$this.showEditProfile, this.editProfileSheet(), { showClose: false })
    .id('screen_account_summary')
  }
}
