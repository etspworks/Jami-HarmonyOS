/*
 * screen_security_settings — "Security", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSettingsViews.swift (SecuritySettingsView :347-407)
 *   Ring/Ring/Features/Settings/Me/AccountSettings.swift      (:258-315, the SIP extension)
 *   Ring/Ring/Extensions/View+Helpers.swift                   (struct ToggleCell)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink (SIP accounts), so
 * it is an @Entry page on the router stack; Back is the platform affordance, composed here
 * because an @Entry router page draws no system chrome (controlInventory's
 * `implicit: true / affordance: back` entry, hence `.id('back')`). navOut is empty.
 *
 * S3 — the real tree of `SecuritySettingsView.body`:
 *
 *   List {
 *     Section { ToggleCell(enableSRTP, …, identifier: "security_settings_enable_srtp") }
 *     Section {
 *       ToggleCell(encryptNegotiation, …, identifier: "security_settings_encrypt_negotiation")
 *       if model.enableTLS {
 *         ToggleCell(tlsVerifyServerCertificates,  … "…_tls_verify_server_certificates")
 *         ToggleCell(tlsVerifyClientCertificates,  … "…_tls_verify_client_certificates")
 *         ToggleCell(tlsRequireTlsCertificate,     … "…_tls_require_tls_certificate")
 *         ToggleCell(tlsDisableSecureDlgCheck,     … "…_tls_disable_secure_dlg_check")
 *       }
 *     }
 *   }
 *   .navigationBarTitleDisplayMode(.inline).navigationTitle(L10n.AccountPage.security)
 *
 * TWO sections, and the four TLS rows live INSIDE the second one, gated by an ArkUI `if` on
 * `isTlsEnabled` (conditionalVariants[tls_enabled]) — never a flattened layout and never both
 * states at once. The capture proves both branches: S0201/S0202/S0204/S0205/S0207 show two
 * rows with the TLS switch off, S0203 shows six with it on.
 *
 * bindingContract — [toggle states] <- svc_accounts: every switch reads its own
 * `AccountConfigModel` value out of THIS account's detail map and writes it back through
 * `AccountsService`. Never a literal. SRTP is the odd one out in the source too: it is stored
 * as the STRING `SRTP.keyExchange` ("sdes" / ""), which `getSRTPEnabled()` compares, and
 * `AccountsService.enableSRTP` writes.
 *
 * DAEMON GAP (Rule 11). Every write ends in `AccountsService.setAccountDetails`, whose daemon
 * half reports `account.setDetails` unavailable. The switches still follow the finger and the
 * page states the ceiling in its own body — never a silent return. The idiom is
 * pages/CallSettingsPage.ets's `observeDaemonGap` / `showDaemonNotice`.
 */
import { LengthMetrics, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { ToggleCell } from '../components/ToggleCell';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SecuritySettingsPage';

/** The daemon feature `common/AccountsService.ts` reports when a property cannot be written. */
const ACCOUNT_DETAILS_FEATURE: string = 'account.setDetails';
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';
/** Swift `getSRTPEnabled()` — `stringValue == "sdes"`, and `enableSRTP` writes exactly that. */
const SRTP_SDES: string = 'sdes';
/**
 * How long a switch's own on/off animation is given before the account write runs (T-0788).
 * ArkUI draws the knob from animatable modifier properties on the UI thread, so the write has
 * to wait for the knob to settle, not just for the next frame.
 */
const TOGGLE_SETTLE_MS: number = 300;

/*
 * S5 — every metric below is confirmed against
 * results/traversal-source/pages/SecuritySettingsView/base.ui.json (TLS off) and
 * security_settings_encrypt_negotiation.ui.json (TLS on), a 393x852 capture:
 *
 *   nav bar          [0,53][393,97]       -> BAR_HEIGHT 44
 *   section 1 card   [20,132][373,176]    -> CARD_INSET 20, LIST_TOP 35, rows 44 tall
 *   section 2 card   [20,212][…]          -> SECTION_GAP 36 measured, 35 kept (the value the
 *                                            device-VERIFIED sibling settings pages carry)
 *   row label        x 40                 -> ROW_TEXT_INSET 20 (16 of it ToggleCell's own)
 *   row separators   [40,255][373,256], [40,299][373,300], [40,343][373,344],
 *                    [40,408][373,408]    -> inset to the label, running to the card's edge
 *   two-line rows    64 tall ([20,344][373,408]) -> the label wraps; nothing is clamped
 */
/* ── layout ─────────────────────────────────────────────────────────────────────────────── */
const BAR_HEIGHT: number = 44;
const CARD_INSET: number = 20;
const CARD_RADIUS: number = 10;
const LIST_TOP: number = 35;
const ROW_TEXT_INSET: number = 20;
/** ToggleCell carries 16 of that inset itself; the card supplies the remaining 4. */
const CELL_INSET: number = 4;
const SECTION_GAP: number = 35;
const BACK_GLYPH_GAP: number = 6;
const FOOTNOTE_GAP: number = 8;
const HAIRLINE: number = 0.5;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';

@Entry
@Component
struct SecuritySettingsPage {
  /**
   * bindingContract[toggle states] <- svc_accounts. One entry per switch, keyed by the
   * `ConfigKey` it is stored under — which is what the plan's single `toggleStates` state var
   * names. A V1 `@State` Map is observed on `set`, so a write re-renders the rows.
   */
  @State toggleStates: Map<string, boolean> = new Map<string, boolean>();
  /** conditionalVariants[tls_enabled] — Swift `model.enableTLS` <- ConfigKey.tlsEnable. */
  @State isTlsEnabled: boolean = false;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The daemon gap a write hits, stated in place rather than as a toast. */
  @State showDaemonNotice: boolean = false;

  /**
   * AppStorage['currentAccountId'] — the account these settings belong to. svc_accounts
   * rewrites it whenever the current account changes, and every switch is read out of THAT
   * account's detail map.
   */
  @Watch('onAccountChanged') @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift `AccountSettings.init` -> `setUPSIPParameters()`, which fills every published
    // switch out of the account's detail map before the view first renders.
    this.refreshFromAccount();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /** The page is pushed, so it is re-shown after a Back from anywhere above it. */
  onPageShow(): void {
    this.refreshFromAccount();
  }

  /** @Watch on currentAccountId — svc_accounts moved the current account. */
  private onAccountChanged(_propName: string): void {
    this.refreshFromAccount();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
    }
  }

  /* ── svc_accounts ─────────────────────────────────────────────────────────────────────── */
  /** The gap THIS screen's own writes raise — `setAccountDetails` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === ACCOUNT_DETAILS_FEATURE) {
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

  /** One switch's current value — the `isOn` every ToggleCell below is handed. */
  private toggleValue(key: ConfigKey): boolean {
    const stored: boolean | undefined = this.toggleStates.get(String(key));
    return stored === undefined ? false : stored;
  }

  /** Swift `setUPSIPParameters()` — the security half of it. */
  private refreshFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.currentAccount();
      const details: AccountConfigModel | null = account === null ? null : account.details;
      if (account === null || details === null) {
        // There is no SIP account to read: adding one is daemon work, and this build has no
        // daemon. Every switch reads off, which is the truth, and the TLS branch stays closed.
        this.toggleStates = new Map<string, boolean>();
        this.isTlsEnabled = false;
        return;
      }
      const values: Map<string, boolean> = new Map<string, boolean>();
      // Swift `self.enableSRTP = self.getSRTPEnabled()` — a STRING comparison, not a bool.
      values.set(String(ConfigKey.SRTP_KEY_EXCHANGE),
        details.get(new ConfigKeyModel(ConfigKey.SRTP_KEY_EXCHANGE)) === SRTP_SDES);
      values.set(String(ConfigKey.TLS_ENABLE),
        details.getBool(new ConfigKeyModel(ConfigKey.TLS_ENABLE)));
      values.set(String(ConfigKey.TLS_VERIFY_SERVER),
        details.getBool(new ConfigKeyModel(ConfigKey.TLS_VERIFY_SERVER)));
      values.set(String(ConfigKey.TLS_VERIFY_CLIENT),
        details.getBool(new ConfigKeyModel(ConfigKey.TLS_VERIFY_CLIENT)));
      values.set(String(ConfigKey.TLS_REQUIRE_CLIENT_CERTIFICATE),
        details.getBool(new ConfigKeyModel(ConfigKey.TLS_REQUIRE_CLIENT_CERTIFICATE)));
      values.set(String(ConfigKey.DISABLE_SECURE_DLG_CHECK),
        details.getBool(new ConfigKeyModel(ConfigKey.DISABLE_SECURE_DLG_CHECK)));
      this.toggleStates = values;
      this.isTlsEnabled = this.toggleValue(ConfigKey.TLS_ENABLE);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /** The rendered state follows the finger whatever the write below reaches. */
  private setToggleState(key: ConfigKey, enable: boolean): void {
    this.toggleStates.set(String(key), enable);
  }

  /**
   * T-0788 — the account write runs once the switch has finished moving. Every write ends in
   * libjami's synchronous `setAccountDetails`, which saves the config and re-registers the SIP
   * account on this (UI) thread, so writing inside onChange held the knob still until the daemon
   * returned. The rendered state is set before this is called; timers of equal delay fire in
   * order, so quick taps are still written in tap order, the last one last.
   * ponytail: the write still blocks the UI thread, only after the knob settles; moving
   * setAccountDetails onto a taskpool worker (common/AccountsService.ts) removes the stall.
   */
  private afterToggleSettles(write: () => void): void {
    setTimeout(write, TOGGLE_SETTLE_MS);
  }

  /**
   * Swift `private func switchSipBoolProperty(_:current:enable:update:)` — the write every TLS
   * row and the TLS switch itself goes through.
   *
   * Swift's leading `if current == enable { return }` is NOT repeated: it guards a @Published
   * var the model also writes programmatically, while the only caller here is a switch's own
   * onChange, which fires on a real change — and the redundant-write guard it protects still
   * runs inside `switchAccountPropertyTo`. Repeating it would add the one thing this screen
   * must not have: a tap that returns silently.
   */
  private switchBoolProperty(key: ConfigKey, enable: boolean): void {
    this.setToggleState(key, enable);
    // Resolved at the tap, while the page and its storage link are still alive.
    const account: AccountModel | null = this.currentAccount();
    this.afterToggleSettles((): void => {
      this.errorText = '';
      this.showDaemonNotice = false;
      const details: AccountConfigModel | null = account === null ? null : account.details;
      if (account === null || details === null) {
        // Nothing to write to: adding a SIP account is daemon work, and this build has no
        // daemon. `switchAccountPropertyTo` returns silently on that, so the screen says it.
        this.showDaemonNotice = true;
        return;
      }
      const property: ConfigKeyModel = new ConfigKeyModel(key);
      this.isLoading = true;
      try {
        // The LOCAL detail map really updates; the daemon half (`account.setDetails`) reports
        // the gap, which `observeDaemonGap` turns into the in-body notice.
        ServiceRegistry.shared().accountService
          .switchAccountPropertyTo(enable, account.id, property);
      } catch (error) {
        this.errorText = describeError(error as BusinessError);
      } finally {
        this.isLoading = false;
      }
      if (details.getBool(property) !== enable) {
        // Not even the local half moved — the write reached nothing at all.
        this.showDaemonNotice = true;
      }
    });
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * Swift `func enableSRTP(enable: Bool)` -> `accountService.enableSRTP(enable:accountId:)`,
   * which writes `SRTP.keyExchange` as "sdes" / "" rather than a boolean.
   */
  private setEnableSrtp(enable: boolean): void {
    this.setToggleState(ConfigKey.SRTP_KEY_EXCHANGE, enable);
    const account: AccountModel | null = this.currentAccount();
    this.afterToggleSettles((): void => {
      this.errorText = '';
      this.showDaemonNotice = false;
      const details: AccountConfigModel | null = account === null ? null : account.details;
      if (account === null || details === null) {
        this.showDaemonNotice = true;
        return;
      }
      this.isLoading = true;
      try {
        ServiceRegistry.shared().accountService.enableSRTP(enable, account.id);
      } catch (error) {
        this.errorText = describeError(error as BusinessError);
      } finally {
        this.isLoading = false;
      }
      const written: string = details.get(new ConfigKeyModel(ConfigKey.SRTP_KEY_EXCHANGE));
      if ((written === SRTP_SDES) !== enable) {
        this.showDaemonNotice = true;
      }
    });
  }

  /** Swift `func enableTLS(enable: Bool)` — and what opens/closes the four rows below it. */
  private setEnableTls(enable: boolean): void {
    this.switchBoolProperty(ConfigKey.TLS_ENABLE, enable);
    // conditionalVariants[tls_enabled] follows the switch, not the write: the rows are the
    // source's own `if model.enableTLS`, which Swift sets from `enable` too.
    this.isTlsEnabled = enable;
  }

  /** Swift `func setTlsVerifyServer(enable: Bool)`. */
  private setTlsVerifyServer(enable: boolean): void {
    this.switchBoolProperty(ConfigKey.TLS_VERIFY_SERVER, enable);
  }

  /** Swift `func setTlsVerifyClient(enable: Bool)`. */
  private setTlsVerifyClient(enable: boolean): void {
    this.switchBoolProperty(ConfigKey.TLS_VERIFY_CLIENT, enable);
  }

  /** Swift `func setTlsRequireClientCertificate(enable: Bool)`. */
  private setTlsRequireClientCertificate(enable: boolean): void {
    this.switchBoolProperty(ConfigKey.TLS_REQUIRE_CLIENT_CERTIFICATE, enable);
  }

  /** Swift `func setTlsDisableSecureDlgCheck(enable: Bool)`. */
  private setTlsDisableSecureDlgCheck(enable: boolean): void {
    this.switchBoolProperty(ConfigKey.DISABLE_SECURE_DLG_CHECK, enable);
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    if (this.isNavigating) {
      return;
    }
    this.isNavigating = true;
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: SETTINGS_SUMMARY_PAGE }).catch((error: Error): void => {
        this.isNavigating = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s',
          SETTINGS_SUMMARY_PAGE, error.message);
      });
      return;
    }
    router.back();
    this.isNavigating = false;
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * Swift `.navigationTitle(L10n.AccountPage.security)` with
   * `.navigationBarTitleDisplayMode(.inline)`, plus iOS's own leading back item, labelled
   * 'Settings': SettingsSummaryView pushes this screen (SettingsSummaryView.swift:30 at 4.20).
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Text($r('app.string.account_page_security'))
        .width('100%')
        .height(BAR_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text($r('app.string.account_page_settings_header'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  /** The grouped list's row separator, inset to the label and running to the card's edge. */
  @Builder
  private rowDivider() {
    Divider()
      .strokeWidth(HAIRLINE)
      .color($r('sys.color.comp_divider'))
      .margin({ start: LengthMetrics.vp(ROW_TEXT_INSET - CELL_INSET) })
  }

  /**
   * Swift's SECOND `Section` — the TLS switch, then the four certificate rows inside
   * `if model.enableTLS`.
   */
  @Builder
  private tlsSection() {
    Column() {
      ToggleCell({
        toggleText: $r('app.string.account_page_encrypt_negotiation'),
        isOn: this.isTlsEnabled,
        identifier: 'security_settings_encrypt_negotiation',
        onToggle: (value: boolean): void => {
          this.setEnableTls(value);
        }
      })

      // conditionalVariants[tls_enabled] — the four rows exist only here, never flattened
      // beside the switch.
      if (this.isTlsEnabled) {
        this.rowDivider()
        ToggleCell({
          toggleText: $r('app.string.account_page_tls_verify_server_certificates'),
          isOn: this.toggleValue(ConfigKey.TLS_VERIFY_SERVER),
          identifier: 'security_settings_tls_verify_server_certificates',
          onToggle: (value: boolean): void => {
            this.setTlsVerifyServer(value);
          }
        })

        this.rowDivider()
        ToggleCell({
          toggleText: $r('app.string.account_page_tls_verify_client_certificates'),
          isOn: this.toggleValue(ConfigKey.TLS_VERIFY_CLIENT),
          identifier: 'security_settings_tls_verify_client_certificates',
          onToggle: (value: boolean): void => {
            this.setTlsVerifyClient(value);
          }
        })

        this.rowDivider()
        ToggleCell({
          toggleText: $r('app.string.account_page_tls_require_tls_certificate'),
          isOn: this.toggleValue(ConfigKey.TLS_REQUIRE_CLIENT_CERTIFICATE),
          identifier: 'security_settings_tls_require_tls_certificate',
          onToggle: (value: boolean): void => {
            this.setTlsRequireClientCertificate(value);
          }
        })

        this.rowDivider()
        ToggleCell({
          toggleText: $r('app.string.account_page_tls_disable_secure_dlg_check'),
          isOn: this.toggleValue(ConfigKey.DISABLE_SECURE_DLG_CHECK),
          identifier: 'security_settings_tls_disable_secure_dlg_check',
          onToggle: (value: boolean): void => {
            this.setTlsDisableSecureDlgCheck(value);
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ start: LengthMetrics.vp(CELL_INSET), end: LengthMetrics.vp(CELL_INSET) })
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(CARD_RADIUS)
    .margin({ top: SECTION_GAP })
  }

  build() {
    Column() {
      this.navigationBar()

      if (this.isLoading && this.toggleStates.size === 0) {
        // The first read only: exclusive with the content below, so an in-flight read never
        // renders beside the values it is still reading.
        Row() {
          LoadingProgress()
            .width(BAR_HEIGHT)
            .height(BAR_HEIGHT)
            .color($r('sys.color.font_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // Swift's FIRST `Section` — the SDES row alone.
            Column() {
              ToggleCell({
                toggleText: $r('app.string.account_page_enable_srtp'),
                isOn: this.toggleValue(ConfigKey.SRTP_KEY_EXCHANGE),
                identifier: 'security_settings_enable_srtp',
                onToggle: (value: boolean): void => {
                  this.setEnableSrtp(value);
                }
              })
            }
            .width('100%')
            .padding({ start: LengthMetrics.vp(CELL_INSET), end: LengthMetrics.vp(CELL_INSET) })
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(CARD_RADIUS)

            this.tlsSection()

            // The grouped section's failure footer: the daemon ceiling and any real failure,
            // stated in place rather than as a toast, and below the cards so a notice never
            // pushes them off the captured position.
            if (this.showDaemonNotice) {
              Text($r('app.string.daemon_not_available'))
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(FAILURE_COLOR)
                .padding({
                  start: LengthMetrics.vp(ROW_TEXT_INSET),
                  end: LengthMetrics.vp(ROW_TEXT_INSET)
                })
                .margin({ top: FOOTNOTE_GAP })
            }
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(FAILURE_COLOR)
                .padding({
                  start: LengthMetrics.vp(ROW_TEXT_INSET),
                  end: LengthMetrics.vp(ROW_TEXT_INSET)
                })
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
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the page grey the white cards sit on.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_security_settings')
  }
}
