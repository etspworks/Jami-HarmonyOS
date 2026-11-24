/*
 * screen_edit_password — "Edit Password Field", ported from
 *   Ring/Ring/Features/Settings/Me/ManageAccountView.swift (EditPasswordView, line 110)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift    (PasswordFieldView, line 175)
 *
 *   struct EditPasswordView: View {
 *     @Binding var password: String
 *     var onDisappearAction: () -> Void
 *     var body: some View {
 *       Form { Section {
 *         PasswordFieldView(text: $password, placeholder: L10n.Global.password,
 *                           identifier: "edit_password_field")
 *       } }
 *       .navigationTitle(L10n.Global.editPassword)
 *       .onDisappear { onDisappearAction() }
 *     }
 *   }
 *
 * presentation: page. EditPasswordView is pushed from the connectivity settings (TURN password)
 * and the SIP-account settings, so it is an @Entry page on the router stack
 * (pages/ConnectivityAndConfigurationsPage pushes it). Back is the platform affordance, composed
 * here because an @Entry router page draws no system chrome (controlInventory's
 * `implicit: true / affordance: back` entry, hence `.id('back')`). navOut: none.
 *
 * S3 — the page is a Form with ONE section holding ONE row, and that row IS PasswordFieldView.
 * The shared comp_password_field (components/PasswordField.ets, owned by screen_account_migration
 * and device-verified) is that component, so it is instantiated rather than re-declared: the
 * field's slug is supplied per call site exactly as Swift's `var identifier: String` is, and the
 * `passwordVisibilityToggle` button and the visible/hidden branch both live inside it — this page
 * must NOT draw a second one.
 *
 * conditionalVariants[visible] / [hidden] — Swift's
 *   `Group { if isVisible { TextField } else { SecureField } }`
 * is PasswordFieldView's own `@SwiftUI.State private var isVisible`, and the ported component
 * already builds it as a real ArkUI `if`. Duplicating the flag on this page would fork the
 * state and leave the page's copy inert.
 *
 * S4 — which config key is being edited, the read out of AccountConfigModel / svc_accounts,
 * and the write-back on aboutToDisappear (Swift `.onDisappear { onDisappearAction() }`; this
 * view has NO submit control and never had one).
 *
 * THE KEY. Swift takes it from the caller's `@Binding`: ConnectivitySettingsView:264 passes
 * `$model.turnPassword` (write-back `model.saveTurnSettings()`), ManageSipAccountView:54 passes
 * `$model.password` (write-back `model.updateSipSettings()`). The connectivity pusher passes no
 * route param, and a cold deep link passes none either, so the key is read from
 * `router.getParams()` when one IS present and otherwise defaults to ConfigKey.TURN_PASSWORD —
 * the connectivity TURN-password row is the call site the capture itself recorded (S0183/S0184).
 * SIP MODE: ManageSIPAccountPage passes ConfigKey.ACCOUNT_PASSWORD. The SIP password is not a
 * detail key — SipAccountDetailModel keeps it in the account's CREDENTIALS — so that mode reads
 * `credentialDetails.first.password` and writes back as `updateSipSettings()` does, through
 * `setAccountCrdentials` (T-1595).
 *
 * DAEMON GAP (Rule 11). The value is a jami-daemon account config key; with no daemon it reads
 * back empty, which is what the capture itself shows.
 */
import { LengthMetrics, router } from '@kit.ArkUI';

import { BusinessError } from '@kit.BasicServicesKit';
import { PasswordFieldView } from '../components/PasswordField';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountCredentialsModel } from '../model/AccountCredentialsModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

/** The route param the pusher MAY carry — Swift's `@Binding var password` by another name. */
interface EditPasswordRouteParams {
  configKey?: string;
  /** The account to edit when the pusher is pinned to one (Manage SIP); else the current one. */
  accountId?: string;
}

/** ConnectivitySettingsView is what pushed this page — the root a cold deep link lacks. */
const CONNECTIVITY_PAGE: string = 'pages/ConnectivityAndConfigurationsPage';

/*
 * Structure-bearing measurements off results/traversal-source/pages/EditPasswordView/
 * base.ui.json (393x852); exact colour/typography is S5:
 *
 *   nav bar    [0,53][393,97]      -> BAR_HEIGHT 44; title 'Edit password' [140,65][252,85]
 *   back item  [0,53][68,97]       -> the chevron plus its 'Back' label
 *   the card   [20,132][373,176]   -> CARD_INSET 20, LIST_TOP 35 below the bar, 44 tall
 *   the field  [40,144][308,165]   -> 20 inside the card
 *   the toggle [328,145][351,163]  -> the eye-slash, inside PasswordFieldView
 */
const CARD_INSET: number = 20;
const CARD_RADIUS: number = 10;
const LIST_TOP: number = 35;
/**
 * The row's inset inside the card is 20 (field x 40 = card 20 + 20); PasswordFieldView carries
 * 10 of it as its own horizontal padding (Swift's WalkthroughPasswordView pill), so the card
 * supplies the other 10.
 */
const ROW_INSET: number = 10;
const BAR_HEIGHT: number = 44;
const BACK_GLYPH_GAP: number = 6;
const FOOTNOTE_GAP: number = 8;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back" — ManageSIPAccountPage's BACK_FIT_MARGIN, calibrated off
 * the 4.20 iPhone (T-1611).
 */
const BACK_FIT_MARGIN: number = 16;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`. */
const FAILURE_COLOR: string = '#F00000';

@Entry
@Component
struct EditPasswordFieldPage {
  /**
   * bindingContract[field] — Swift `@Binding var password: String` handed in by the caller,
   * read here out of the edited account's own detail map. Empty is what the capture renders
   * and what the Rule-11 daemon gap genuinely leaves it as; never a literal.
   */
  @State field: string = '';
  /**
   * conditionalVariants[visible] / [hidden] — Swift's
   *   `Group { if isVisible { TextField } else { SecureField } }`
   * is PasswordFieldView's OWN `@SwiftUI.State private var isVisible`, and the ported shared
   * component (components/PasswordField.ets, device-verified, not this screen's to edit)
   * builds that branch. These two are the plan's declared selectors for the pair; the live
   * flag stays where the source puts it, so this page does not fork it.
   */
  @State isVisible: boolean = false;
  @State isHidden: boolean = true;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * The daemon ceiling (Rule 11): `AccountsService.setAccountDetails` -> `account.setDetails`
   * is unavailable on this build. The write SAYS so rather than failing silently or
   * fabricating success.
   */
  @State private showDaemonNotice: boolean = false;
  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /** The bar, its title and its back item, measured for the back label's fit (T-1611). */
  @State private barWidth: number = 0;
  @State private titleWidth: number = 0;
  /** The back item's width while it still shows the origin's title, kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;

  /** The detail key this editor edits — the route param, else the capture's own call site. */
  private configKey: ConfigKey = ConfigKey.TURN_PASSWORD;
  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;
  /** The account this editor was opened for, captured on load: the save goes there (T-1632). */
  private editingAccountId: string = '';

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    const raw: Object | undefined = router.getParams();
    const requested: string = raw === undefined
      ? '' : ((raw as EditPasswordRouteParams).configKey ?? '');
    this.configKey = this.resolveKey(requested);
    this.editingAccountId = raw === undefined ? '' : ((raw as EditPasswordRouteParams).accountId ?? '');
    this.loadFromAccount();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /**
   * A pop shows the previous page (its onPageShow re-reads the account) BEFORE this page's
   * aboutToDisappear runs, so the write goes here; the later call finds nothing changed.
   */
  onPageHide(): void {
    this.savePassword();
  }

  /** Swift `.onDisappear { onDisappearAction() }` — the ONLY write this view performs. */
  aboutToDisappear(): void {
    try {
      this.savePassword();
    } finally {
      // ArkTS rule 8 — the subscription is released whatever the write did.
      this.bag.dispose();
      this.isLoading = false;
    }
  }

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /**
   * A route param is a bare string; ConfigKey is a string enum and ArkTS will not widen one
   * back, so the keys this editor can actually serve are matched by name and anything else
   * falls back to the captured call site rather than being cast blind.
   */
  private resolveKey(raw: string): ConfigKey {
    if (raw === String(ConfigKey.ACCOUNT_PASSWORD)) {
      return ConfigKey.ACCOUNT_PASSWORD;
    }
    return ConfigKey.TURN_PASSWORD;
  }

  /** SIP mode: the account's credential password (see the header). */
  private isSipPassword(): boolean {
    return this.configKey === ConfigKey.ACCOUNT_PASSWORD;
  }

  /** The gap THIS screen's own write raises — `setAccountDetails` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === 'account.setDetails') {
        this.isLoading = false;
        this.showDaemonNotice = true;
      }
    }));
  }

  /** The account whose configuration this page edits — Swift `AccountSettings.account`. */
  private currentAccount(): AccountModel | null {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    if (this.currentAccountId.length > 0) {
      const byId: AccountModel | null = accounts.getAccount(this.currentAccountId);
      if (byId !== null) {
        return byId;
      }
    }
    return accounts.currentAccount;
  }

  /**
   * Swift `AccountSettings.turnPassword = getStringState(for: ConfigKey.turnPassword)`, which
   * ConnectivitySettingsView hands in as the binding — a plain lookup in THIS account's own
   * detail map, never a default table. A key the account does not carry reads back EMPTY, so
   * the field shows its "Password" placeholder, which is exactly what the capture shows.
   */
  private loadFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.editingAccountId.length > 0
        ? ServiceRegistry.shared().accountService.getAccount(this.editingAccountId)
        : this.currentAccount();
      this.editingAccountId = account === null ? '' : account.id;
      if (this.isSipPassword()) {
        // Swift `SipAccountDetailModel.init`: `password = credentials.password`.
        const credentials: AccountCredentialsModel | undefined =
          account === null ? undefined : account.credentialDetails[0];
        this.field = credentials === undefined ? '' : credentials.password;
        return;
      }
      const details: AccountConfigModel | null = account === null ? null : account.details;
      this.field = details === null ? '' : details.get(new ConfigKeyModel(this.configKey));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift's `onDisappearAction`. For the TURN password that is `model.saveTurnSettings()` ->
   * `accountService.setTurnSettings(accountId:server:username:password:realm:)` — the whole
   * quartet goes in ONE call there, the other three read back from the account — and for any
   * other detail key the plain `setAccountProperty`.
   */
  private savePassword(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    // Not currentAccount(): currentAccountId may have moved since this editor opened.
    const account: AccountModel | null = accounts.getAccount(this.editingAccountId);
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      // Nothing to write to: configuring an account is daemon work, and this build has none.
      this.showDaemonNotice = true;
      return;
    }
    if (this.isSipPassword()) {
      // Swift `updateSipSettings()` with only the password changed: the credentials alone go
      // back, through `setAccountCrdentials`; no credentials means nothing to write.
      const credentials: AccountCredentialsModel | undefined = account.credentialDetails[0];
      if (credentials === undefined || credentials.password === this.field) {
        return;
      }
      credentials.password = this.field;
      account.credentialDetails = [credentials];
      accounts.setAccountCrdentials(account.id, [credentials.toDictionary()]);
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(this.configKey);
    if (details.get(property) === this.field) {
      return;
    }
    this.isLoading = true;
    try {
      if (this.configKey === ConfigKey.TURN_PASSWORD) {
        accounts.setTurnSettings(account.id,
          details.get(new ConfigKeyModel(ConfigKey.TURN_SERVER)),
          details.get(new ConfigKeyModel(ConfigKey.TURN_USERNAME)),
          this.field,
          details.get(new ConfigKeyModel(ConfigKey.TURN_REALM)));
      } else {
        accounts.setAccountProperty(property, this.field, account.id);
      }
    } catch (error) {
      // The write itself failed, which is a different thing from the daemon ceiling: say what
      // failed rather than blaming the gap.
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
    if (details.get(property) !== this.field) {
      // Not even the local half moved — the write reached nothing at all. Never silent, and
      // never a fabricated success.
      this.showDaemonNotice = true;
    }
  }

  /** The platform back affordance of a pushed page; the source writes back as it pops. */
  private goBack(): void {
    if (this.isNavigating) {
      return;
    }
    this.isNavigating = true;
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: CONNECTIVITY_PAGE }).catch((error: Error): void => {
        this.isNavigating = false;
        console.error('EditPasswordFieldPage: replaceUrl ' + CONNECTIVITY_PAGE
          + ' failed: ' + error.message);
      });
      return;
    }
    router.back();
    this.isNavigating = false;
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * UINavigationBar swaps the origin's title for the generic "Back" when it would not fit left
   * of the centred title — T-1601's rule (T-1611).
   */
  private isBackShortened(): boolean {
    return this.fullBackWidth > 0 &&
      this.fullBackWidth + BACK_FIT_MARGIN > (this.barWidth - this.titleWidth) / 2;
  }

  /** Swift `.navigationTitle(L10n.Global.editPassword)`, inline, plus iOS's own leading back
   * item — capture: title [140,65][252,85] centred, back item [0,53][68,97]. */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Text($r('app.string.global_edit_password'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.label'))
          .flexShrink(1)
          .onAreaChange((_old: Area, area: Area) => {
            this.titleWidth = Number(area.width);
          })
      }
      .width('100%')
      .height(BAR_HEIGHT)
      .justifyContent(FlexAlign.Center)

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        // iOS labels a pushed screen's back item with the title of the screen one pop lands on —
        // Manage account (SIP) or Connectivity and configurations (TURN, the iPhone's own back
        // button name) — and with "Back" when that does not fit beside the title (T-1611).
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
          : this.isSipPassword() ? $r('app.string.account_page_manage_account')
            : $r('app.string.account_page_connectivity_and_configuration'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      // Localized edges (LengthMetrics start/end), never left/right — an absolute edge would
      // park the back item on the right under RTL.
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
      .onAreaChange((_old: Area, area: Area) => {
        if (!this.isBackShortened()) {
          this.fullBackWidth = Number(area.width);
        }
      })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.barWidth = Number(area.width);
    })
  }

  build() {
    Column() {
      this.navigationBar()

      Scroll() {
        // Swift `Form { Section { PasswordFieldView(...) } }` — one section, one row.
        Column() {
          // The section's white inset-grouped card — capture [20,132][373,176], radius 10.
          Column() {
            /*
             * Swift `PasswordFieldView(text: $password, placeholder: L10n.Global.password,
             *                          identifier: "edit_password_field")`.
             *
             * `pillBackground` is the CARD's own colour here: the component's default is the
             * grey pill (#F2F2F7) that AccountMigrationPage needs on a white page, which on
             * this grouped page would paint a grey pill inside the white card. The capture has
             * the field sitting directly on the white card, so the card IS the row background.
             */
            PasswordFieldView({
              text: $field,
              placeholder: $r('app.string.global_password'),
              identifier: 'edit_password_field',
              pillBackground: $r('sys.color.comp_background_list_card')
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ start: LengthMetrics.vp(ROW_INSET), end: LengthMetrics.vp(ROW_INSET) })
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(CARD_RADIUS)

          // The Rule-11 daemon ceiling, stated in place as the page's footer — a toast would
          // be gone before any evidence dump runs.
          if (this.showDaemonNotice) {
            Text($r('app.string.daemon_not_available'))
              .width('100%')
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.secondary_label'))
              .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })
              .margin({ top: FOOTNOTE_GAP })
          }

          // Filled from svc_accounts failures; empty when there is none, so nothing renders.
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .fontSize($r('sys.float.Body_S'))
              .fontColor(FAILURE_COLOR)
              .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })
              .margin({ top: FOOTNOTE_GAP })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          start: LengthMetrics.vp(CARD_INSET),
          end: LengthMetrics.vp(CARD_INSET),
          top: LengthMetrics.vp(LIST_TOP),
          bottom: LengthMetrics.vp(CARD_INSET)
        })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the page grey the white card sits on.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_edit_password')
  }
}
