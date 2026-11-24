/*
 * screen_connectivity_settings — "Connectivity and configurations", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSettingsViews.swift (ConnectivitySettingsView,
 *     dhtConfigurationView / connectivityView / publicAddressView, lines 171-345)
 *   Ring/Ring/Features/Settings/Me/AccountSettings.swift       (class AccountSettings)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift        (EditableFieldView, FieldRowView)
 *   Ring/Ring/Extensions/View+Helpers.swift                    (ToggleCell)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`).
 *
 * S3 — the real tree of `ConnectivitySettingsView.body`:
 *   List {
 *     if model.account.type == .sip {
 *       Section { ToggleCell(autoRegistration, "connectivity_settings_auto_registration")
 *                 NavigationLink(EditExpirationtime) { FieldRowView(sipExpirationTime) }
 *                   .accessibilityIdentifier("connectivity_settings_sip_expiration_time") }
 *     } else { dhtConfigurationView() }
 *     connectivityView()
 *     if model.account.type == .sip { publicAddressView() }
 *   }
 *   dhtConfigurationView  = Section(OpenDHT configuration) { bootstrap row; VStack { peer
 *                           discovery ToggleCell; footnote Text } }
 *   connectivityView      = Section(Connectivity) { UPnP; TURN; if turnEnabled { 4 rows };
 *                           if type == .sip { STUN ToggleCell; if stunEnabled { STUN row } } }
 *   publicAddressView     = Section(Public address) { allowIPAutoRewrite; if !allowIPAutoRewrite
 *                           { publishedSameAsLocal; if !publishedSameAsLocal { address; port } } }
 *
 * FOUR CONTROLS THE PLAN'S controlInventory DOES NOT LIST ARE REAL IN THE SOURCE and are kept:
 *   connectivity_settings_auto_registration      AccountSettingsViews.swift:182-187
 *   connectivity_settings_stun_enabled           AccountSettingsViews.swift:280-285
 *   connectivity_settings_allow_ipauto_rewrite   AccountSettingsViews.swift:301-306
 *   connectivity_settings_published_same_as_local AccountSettingsViews.swift:309-314
 * Each is a ToggleCell the source declares with that exact identifier. Removing them would
 * delete the selector that the plan's own `stun_enabled` / `published_custom` branches read.
 *
 * LABELS are the source's own L10n strings, which is what the capture renders
 * (results/traversal-source/pages/ConnectivitySettingsView/base.ui.json): "TURN address", not
 * the plan's symbol name "TURN server"; "Address"/"Port", not "Published address"/"Published
 * port"; "Registration expiration time (seconds)", not "Registration expiry".
 *
 * conditionalVariants — all five are ArkUI `if`s on their own bound selector:
 *   jami_account      -> isJamiAccount       (account.type == .ring)  : OpenDHT section
 *   sip_account       -> isSipAccount        (account.type == .sip)   : registration-expiry row
 *   turn_enabled      -> isTurnEnabled       (ConfigKey.TURN_ENABLE)  : the four TURN rows
 *   stun_enabled      -> isStunEnabled       (ConfigKey.STUN_ENABLE)  : the STUN address row
 *   published_custom  -> isPublishedCustom   (!allowIPAutoRewrite && !publishedSameAsLocal)
 * isJamiAccount / isSipAccount are exclusive by construction (AccountType has two members) and
 * are written as if/else-if so no state can render both.
 *
 * bindingContract — [field values] <- svc_accounts / AccountConfigModel: every row's value and
 * every switch's state is read out of the account's own detail map (Swift
 * `AccountSettings.setUpInitialParameters` -> `getStringState`/`getBoolState`) and written back
 * through AccountsService. Never a literal from the capture.
 *
 * DAEMON GAP (Rule 11). Every value here is a jami-daemon account config key, and the write's
 * daemon half is `AccountsService.setAccountDetails` -> `account.setDetails`, which is
 * unavailable. Every control still moves its own rendered state FIRST and then states the
 * ceiling in place (`showDaemonNotice`), so no tap is a silent no-op.
 *
 * S3 is structure only — colours, spacing, typography and glyph sizing are S5.
 */
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ToggleCell } from '../components/ToggleCell';
import { FieldRowView } from '../components/FieldRow';
import { EditableFieldView } from '../components/EditableField';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';
/** Swift `NavigationLink(destination: EditPasswordView($model.turnPassword))` — navOut push. */
const EDIT_PASSWORD_PAGE: string = 'pages/EditPasswordFieldPage';
/** Swift `NavigationLink(destination: EditExpirationtime(...))` — navOut push. */
const EDIT_EXPIRY_PAGE: string = 'pages/EditRegistrationExpiryPage';
/** Swift `String.maskedPassword` — the capture renders four bullets, never the secret. */
const MASKED_PASSWORD: string = '••••';
/** Swift `AccountSettings.publishedPortRange = 0...Int(UInt16.max)`. */
const PUBLISHED_PORT_MIN: number = 0;
const PUBLISHED_PORT_MAX: number = 65535;

/*
 * S5 — measured off results/traversal-source/pages/ConnectivitySettingsView/base.ui.json and
 * base.png (a 393x852 capture). iOS's InsetGroupedListStyle spells none of these in code:
 *
 *   nav bar         [0,53][393,97]       -> BAR_HEIGHT 44. The simulator capture showed the
 *                                           chevron alone; the 4.20 iPhone shows "< Back" with
 *                                           the title beside it (T-0672)
 *   section header  [20,97][373,136]     -> a 39-tall block holding an UPPERCASE grey
 *                                           caption at the rows' label edge (x 40)
 *   card            x 20..373            -> CARD_INSET 20, CARD_RADIUS 10
 *   grouped row     44 tall, label x 40  -> ROW_MIN_HEIGHT 44, ROW_TEXT_INSET 20
 *   disclosure      [345,152][352,164]   -> a 12-tall grey chevron.forward, 21 in from the
 *                                           card's trailing edge
 *   card 1 bottom 272 -> header 2 at 289 -> SECTION_GAP 16
 */
/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** The inset-grouped card's corner radius. */
const CARD_RADIUS: number = 10;
/** A grouped row's minimum height, and iOS's tap target. */
const ROW_MIN_HEIGHT: number = 44;
/** A grouped row's content inset inside its card (label at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/**
 * ToggleCell carries 16 vp of that inset itself (`ohos_id_elements_margin_horizontal_l`), so
 * the card supplies the remaining 4 rather than the shared, device-proven component being
 * restyled for this page.
 */
const CELL_INSET: number = 4;
/** The 39-tall header block: 16 above the caption, 4 below it. */
const SECTION_HEADER_TOP: number = 16;
const SECTION_HEADER_BOTTOM: number = 4;
/** The gap a card leaves below itself, before the next section's header. */
const SECTION_GAP: number = 16;
/**
 * The pushed editor's Form card: 35 below the bar, the same LIST_TOP as the Notifications, Name
 * server and Manage SIP editors (T-1660). It has no section header, so the 16 + 4 header block
 * left it 15 higher.
 */
const EDITOR_LIST_TOP: number = 35;
/** The gap above a footnote-sized notice. */
const FOOTNOTE_GAP: number = 8;
/**
 * The disclosure chevron: 7x12 of ink in the capture ([345,152][352,164]), whose core pixel
 * is (191,191,191) — iOS `.tertiaryLabel`, not `.secondaryLabel`. `sys.color.font_tertiary`
 * is that row of the iOS token table, and fontSize 14 is the em box the same 7x12 ink
 * measures to on every other settings capture in this app (SettingsSummaryView's chevron is
 * the identical glyph at the identical x band), so this page now draws it the way the
 * device-passed sibling pages do.
 */
const CHEVRON_SIZE: number = 14;
/** Value text ends at x 334, the chevron box begins just after it. */
const CHEVRON_GAP: number = 8;
/** The hairline iOS draws between two grouped rows. */
const HAIRLINE: number = 0.5;
/** The back item's inset from the bar's leading edge. */
const BACK_LEADING: number = 8;
/** The chevron-to-label gap of the back item, as on the sibling edit pages. */
const BACK_GLYPH_GAP: number = 6;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back" — EditPasswordFieldPage's BACK_FIT_MARGIN (T-1611).
 */
const BACK_FIT_MARGIN: number = 16;
/**
 * Swift FocusableTextField.updateUIView: "Wait untill view shows" — becomeFirstResponder after
 * 0.5 s, which is what raises the keyboard on the pushed editor (ManageSIPAccountPage, T-0513).
 */
const EDITOR_FOCUS_DELAY_MS: number = 500;
/** The editor layer slides in from the trailing edge, as a pushed screen does. */
const EDITOR_TRANSITION_MS: number = 250;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';

/**
 * Swift `static func isValid(_ value: String, in range: ClosedRange<Int>)` — `guard let number =
 * Int(value)`. `Int(_:)` parses the WHOLE string, so "12ab" is invalid there and must be here
 * too; Number.parseInt returned 12 for it (T-1633). EditRegistrationExpiryPage's same check.
 */
function isValueInRange(value: string, min: number, max: number): boolean {
  if (!/^[+-]?[0-9]+$/.test(value)) {
    return false;
  }
  const parsed: number = Number.parseInt(value, 10);
  return parsed >= min && parsed <= max;
}

/**
 * UINavigationBar swaps the origin's title for the generic "Back" when it would not fit left
 * of the centred title — T-1601's rule (T-1611).
 */
function isBackShortened(fullBackWidth: number, barWidth: number, titleWidth: number): boolean {
  return fullBackWidth > 0 && fullBackWidth + BACK_FIT_MARGIN > (barWidth - titleWidth) / 2;
}

/** Swift `static func isValidStunServer(_ value: String)`. */
function isValidStunServer(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  const colon: number = value.indexOf(':');
  if (colon < 0) {
    return true;
  }
  const host: string = value.substring(0, colon);
  const port: string = value.substring(colon + 1);
  return host.length > 0 && isValueInRange(port, PUBLISHED_PORT_MIN, PUBLISHED_PORT_MAX);
}

@Entry
@Component
struct ConnectivityAndConfigurationsPage {
  /**
   * bindingContract[field values] <- svc_accounts / AccountConfigModel, keyed by the raw
   * ConfigKey the source reads each value from (Swift `getStringState(for:)`).
   */
  @State fieldValues: Map<string, string> = new Map<string, string>();
  /** conditionalVariants[jami_account] — Swift `model.account.type == .ring`. */
  @State isJamiAccount: boolean = true;
  /** conditionalVariants[sip_account] — Swift `model.account.type == .sip`. */
  @State isSipAccount: boolean = false;
  /** conditionalVariants[turn_enabled] — Swift `model.turnEnabled` <- ConfigKey.turnEnable. */
  @State isTurnEnabled: boolean = false;
  /** conditionalVariants[stun_enabled] — Swift `model.stunEnabled` <- ConfigKey.stunEnable. */
  @State isStunEnabled: boolean = false;
  /** conditionalVariants[published_custom] — Swift `!allowIPAutoRewrite && !publishedSameAsLocal`. */
  @State isPublishedCustom: boolean = false;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** The failure this screen's own write reported; empty when there is none. */
  @State errorText: string = '';

  /** Swift `model.upnpEnabled` <- ConfigKey.accountUpnpEnabled. */
  @State private upnpEnabled: boolean = false;
  /** Swift `model.peerDiscovery` <- ConfigKey.dhtPeerDiscovery. */
  @State private peerDiscovery: boolean = false;
  /** Swift `model.autoRegistrationEnabled` <- ConfigKey.keepAliveEnabled (SIP). */
  @State private autoRegistrationEnabled: boolean = false;
  /** Swift `model.allowIPAutoRewrite` <- ConfigKey.allowIPAutoRewrite (SIP). */
  @State private allowIPAutoRewrite: boolean = true;
  /** Swift `model.publishedSameAsLocal` <- ConfigKey.publishedSameAsLocal (SIP). */
  @State private publishedSameAsLocal: boolean = true;
  /** The daemon gap the writes hit, stated in place rather than as a toast. */
  @State private showDaemonNotice: boolean = false;
  /**
   * There is no account to READ, so no bound toggle on this page can report its real position:
   * the daemon is a Rule-11 `gap`, so `currentAccount` is null and every `getBool` reads false.
   * A conditional section must NOT be hidden on that false — the source landed those sections
   * open, and hiding them reads as a whole section missing. Set only by `refreshFromAccount`,
   * never by a handler, so a tap elsewhere can never make a mounted section vanish.
   */
  @State private accountUnavailable: boolean = false;
  /** Which row's EditableFieldView is open — Swift's pushed editor, a full-page layer here. */
  @State private editingKey: string = '';
  /** The account the open editor belongs to, captured as it opens: the save goes there (T-1632). */
  private editingAccountId: string = '';
  /** Swift `EditableFieldView`'s `@Binding var value` while the editor is open. */
  @State editingValue: string = '';
  /** The bar, its title and its back item, measured for the back label's fit (T-1611). */
  @State private barWidth: number = 0;
  @State private titleWidth: number = 0;
  @State private backWidth: number = 0;
  /** The back item's width while it still shows the origin's title, kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;
  /** The same three for the editor layer's own bar. */
  @State private editorBarWidth: number = 0;
  @State private editorTitleWidth: number = 0;
  @State private editorFullBackWidth: number = 0;

  /**
   * AppStorage['currentAccountId'] — the account these settings belong to. svc_accounts
   * rewrites it whenever the current account changes, and every value on this page is read out
   * of THAT account's detail map.
   */
  @Watch('onAccountChanged') @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Re-entry guard: a row is a 44vp target and a double tap must not push twice. */
  private navigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift `AccountSettings.init` -> `setUpInitialParameters()`.
    this.refreshFromAccount();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /** The page is pushed, so it is re-shown after a Back from either editor page. */
  onPageShow(): void {
    this.navigating = false;
    this.refreshFromAccount();
  }

  /** The device Back key pops the editor layer first, then this page. */
  onBackPress(): boolean {
    if (this.editingKey.length === 0) {
      return false;
    }
    this.closeEditor();
    return true;
  }

  /** @Watch on currentAccountId — svc_accounts moved the current account. */
  private onAccountChanged(_propName: string): void {
    // The open editor belongs to the OUTGOING account: save it there while the TURN values
    // saveTurnSettings sends with it are still that account's, then re-read (T-1632).
    this.closeEditor();
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

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** The gap THIS screen's own writes raise — `setAccountDetails` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === 'account.setDetails') {
        this.isLoading = false;
        // `showDaemonNotice` renders app.string.daemon_not_available, which is the SAME
        // sentence as this error's own `message` — writing both stacked the gap twice in red.
        // `errorText` is left to describeError's genuinely different failure text.
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

  /** Swift `setUpInitialParameters()` + `setUPJamiParameters()` / `setUPSIPParameters()`. */
  private refreshFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.currentAccount();
      const details: AccountConfigModel | null = account === null ? null : account.details;
      if (account === null || details === null) {
        this.fieldValues = new Map<string, string>();
        // Nothing answered, so no toggle below reports a real position — the sections stay
        // mounted and say so instead of reading `false` and disappearing.
        this.accountUnavailable = true;
        return;
      }
      this.accountUnavailable = false;
      this.isJamiAccount = account.type === AccountType.RING;
      this.isSipAccount = account.type === AccountType.SIP;

      // Every value below is `getBoolState(for:)` / `getStringState(for:)`, which is
      // `AccountModelHelper.getCurrentStringValue(property:)` — a plain lookup in THIS
      // account's own detail map. Never a literal, and never a default table: a key the
      // account does not carry reads back empty/false, which is what an account-less config
      // genuinely yields on this build (the daemon is a Rule-11 gap).
      const next: Map<string, string> = new Map<string, string>();

      // Swift `setUpInitialParameters()` — read for EVERY account type (AccountSettings:82-87).
      this.upnpEnabled = details.getBool(new ConfigKeyModel(ConfigKey.ACCOUNT_UPNP_ENABLED));
      this.isTurnEnabled = details.getBool(new ConfigKeyModel(ConfigKey.TURN_ENABLE));
      this.readInto(next, details, ConfigKey.TURN_SERVER);
      this.readInto(next, details, ConfigKey.TURN_USERNAME);
      this.readInto(next, details, ConfigKey.TURN_PASSWORD);
      this.readInto(next, details, ConfigKey.TURN_REALM);

      // Swift `if self.account.type == .sip { setUPSIPParameters() } else { setUPJamiParameters() }`
      // — the two halves are exclusive there, so the keys of the other half are never read and
      // the published pair keeps its declared default (`allowIPAutoRewrite`/
      // `publishedSameAsLocal` are `true` in AccountSettings:56-57, not false).
      if (this.isSipAccount) {
        // Swift `setUPSIPParameters()` — AccountSettings:257-265 (the TLS half belongs to
        // screen_security_settings, not to this page).
        this.autoRegistrationEnabled =
          details.getBool(new ConfigKeyModel(ConfigKey.KEEP_ALIVE_ENABLED));
        this.isStunEnabled = details.getBool(new ConfigKeyModel(ConfigKey.STUN_ENABLE));
        this.allowIPAutoRewrite =
          details.getBool(new ConfigKeyModel(ConfigKey.ALLOW_IP_AUTO_REWRITE));
        this.publishedSameAsLocal =
          details.getBool(new ConfigKeyModel(ConfigKey.PUBLISHED_SAME_AS_LOCAL));
        this.readInto(next, details, ConfigKey.REGISTRATION_EXPIRE);
        this.readInto(next, details, ConfigKey.STUN_SERVER);
        this.readInto(next, details, ConfigKey.PUBLISHED_ADDRESS);
        this.readInto(next, details, ConfigKey.PUBLISHED_PORT);
      } else {
        // Swift `setUPJamiParameters()` — AccountSettings:135,140 (the proxy and name-server
        // reads belong to their own screens).
        this.readInto(next, details, ConfigKey.ACCOUNT_HOSTNAME);
        this.peerDiscovery = details.getBool(new ConfigKeyModel(ConfigKey.DHT_PEER_DISCOVERY));
      }
      // Swift `if !model.allowIPAutoRewrite { if !model.publishedSameAsLocal { … } }`.
      this.isPublishedCustom = !this.allowIPAutoRewrite && !this.publishedSameAsLocal;
      // Reassigned, not mutated: a @State Map only re-renders on a new reference.
      this.fieldValues = next;
    } finally {
      this.isLoading = false;
    }
  }

  /** Swift `getStringState(for:)`, into the page's one bound value map. */
  private readInto(target: Map<string, string>, details: AccountConfigModel,
    key: ConfigKey): void {
    target.set(String(key), details.get(new ConfigKeyModel(key)));
  }

  /** The bound value of one row. */
  private fieldValue(key: string): string {
    const value: string | undefined = this.fieldValues.get(key);
    return value === undefined ? '' : value;
  }

  /** Swift `FieldRowView(value:)` — the TURN password row shows `maskedPassword`. */
  private displayValue(key: string): string {
    const value: string = this.fieldValue(key);
    if (key === String(ConfigKey.TURN_PASSWORD)) {
      return value.length === 0 ? '' : MASKED_PASSWORD;
    }
    return value;
  }

  /* ── handlers — every control the source declares, wired to its Swift effect ──────────── */
  /**
   * Swift `switchSipBoolProperty` / `enableUpnp` / `enableTurn`: the local detail map really
   * updates, the daemon half reports the gap. The rendered switch has already followed the
   * finger before this runs, so a tap is never a no-op.
   */
  private switchProperty(key: ConfigKey, enabled: boolean): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const account: AccountModel | null = this.currentAccount();
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      // There is nothing to write to: configuring an account is daemon work, and this build
      // has no daemon. `switchAccountPropertyTo` returns silently on both of these, so the
      // screen says it here instead.
      this.showDaemonNotice = true;
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(key);
    this.isLoading = true;
    try {
      ServiceRegistry.shared().accountService
        .switchAccountPropertyTo(enabled, account.id, property);
    } catch (error) {
      // The write itself failed, which is a different thing from the daemon ceiling: say what
      // failed rather than blaming the gap.
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
    if (details.getBool(property) !== enabled) {
      // Not even the local half moved — the write reached nothing at all.
      this.showDaemonNotice = true;
    }
  }

  /** Swift `model.enableUpnp(enable:)`. */
  private setUpnpEnabled(enabled: boolean): void {
    this.upnpEnabled = enabled;
    this.switchProperty(ConfigKey.ACCOUNT_UPNP_ENABLED, enabled);
  }

  /** Swift `model.enablePeerDiscovery(enable:)`. */
  private setPeerDiscovery(enabled: boolean): void {
    this.peerDiscovery = enabled;
    this.switchProperty(ConfigKey.DHT_PEER_DISCOVERY, enabled);
  }

  /** Swift `model.enableTurn(enable:)` — also the `turn_enabled` branch selector. */
  private setTurnEnabled(enabled: boolean): void {
    // Set FIRST: revealing/hiding the four TURN rows is this control's observable effect, and
    // it must happen whether or not the daemon accepts the write.
    this.isTurnEnabled = enabled;
    this.switchProperty(ConfigKey.TURN_ENABLE, enabled);
  }

  /** Swift `model.enableStun(enable:)` — also the `stun_enabled` branch selector. */
  private setStunEnabled(enabled: boolean): void {
    this.isStunEnabled = enabled;
    this.switchProperty(ConfigKey.STUN_ENABLE, enabled);
  }

  /** Swift `model.enableaAtoregister(enable:)`. */
  private setAutoRegistration(enabled: boolean): void {
    this.autoRegistrationEnabled = enabled;
    this.switchProperty(ConfigKey.KEEP_ALIVE_ENABLED, enabled);
  }

  /** Swift `model.enableAllowIPAutoRewrite(enable:)` — forces publishedSameAsLocal on enable. */
  private setAllowIPAutoRewrite(enabled: boolean): void {
    this.allowIPAutoRewrite = enabled;
    this.isPublishedCustom = !enabled && !this.publishedSameAsLocal;
    this.switchProperty(ConfigKey.ALLOW_IP_AUTO_REWRITE, enabled);
    if (enabled) {
      // Swift `if enable { enablePublishedSameAsLocal(enable: true) }`.
      this.setPublishedSameAsLocal(true);
    }
  }

  /** Swift `model.enablePublishedSameAsLocal(enable:)` — the `published_custom` selector. */
  private setPublishedSameAsLocal(enabled: boolean): void {
    this.publishedSameAsLocal = enabled;
    this.isPublishedCustom = !this.allowIPAutoRewrite && !enabled;
    this.switchProperty(ConfigKey.PUBLISHED_SAME_AS_LOCAL, enabled);
  }

  /** Swift's `NavigationLink` destinations: two are routed pages, the rest the editor layer. */
  private onRowTap(key: string): void {
    if (key === String(ConfigKey.TURN_PASSWORD)) {
      this.pushPage(EDIT_PASSWORD_PAGE);
      return;
    }
    if (key === String(ConfigKey.REGISTRATION_EXPIRE)) {
      this.pushPage(EDIT_EXPIRY_PAGE);
      return;
    }
    if (this.editingKey.length > 0) {
      // Re-entry guard: the layer covers the rows, so a second tap can only land while it is
      // still sliding in, and re-opening would throw away what has been typed.
      return;
    }
    const account: AccountModel | null = this.currentAccount();
    this.editingAccountId = account === null ? '' : account.id;
    this.editingKey = key;
    this.editingValue = this.fieldValue(key);
    setTimeout((): void => {
      focusControl.requestFocus('editable_field_value');
    },
      EDITOR_FOCUS_DELAY_MS);
  }

  /**
   * Whether the row being edited is still on the page. The layer is shown only while it is, so
   * a branch that hides the row (TURN switched off, the account changing) closes the layer and
   * its onDisappear saves the field, instead of leaving an editor for a row that is gone.
   */
  private isEditedRowShown(): boolean {
    const key: string = this.editingKey;
    if (key === String(ConfigKey.TURN_SERVER) || key === String(ConfigKey.TURN_USERNAME)
      || key === String(ConfigKey.TURN_REALM)) {
      return this.isTurnEnabled || this.accountUnavailable;
    }
    if (key === String(ConfigKey.STUN_SERVER)) {
      return this.isSipAccount && this.isStunEnabled;
    }
    if (key === String(ConfigKey.PUBLISHED_ADDRESS) || key === String(ConfigKey.PUBLISHED_PORT)) {
      return this.isSipAccount && this.isPublishedCustom;
    }
    // ACCOUNT_HOSTNAME, the OpenDHT bootstrap row.
    return !this.isSipAccount && this.isJamiAccount;
  }

  /** navOut — both edges are `kind: push`, so never `replaceUrl`. */
  private pushPage(url: string): void {
    if (this.navigating) {
      return;
    }
    this.navigating = true;
    router.pushUrl({ url: url }).catch((error: Error): void => {
      this.navigating = false;
      console.error('ConnectivityAndConfigurationsPage: pushUrl ' + url + ' failed: '
        + error.message);
    });
  }

  /**
   * Swift `EditableFieldView.onDisappear { onDisappearAction() }` — the write-back, keyed to the
   * row being edited. The layer's back item and the device Back key call it directly; the
   * editor's own aboutToDisappear calls it again and finds nothing open, unless the layer was
   * hidden from underneath (isEditedRowShown), where that call is the save.
   */
  private closeEditor(): void {
    const key: string = this.editingKey;
    if (key.length === 0) {
      return;
    }
    // Cleared first so the re-entrant call this triggers (the component is destroyed by the
    // very same state change) returns above instead of saving twice.
    this.editingKey = '';
    const value: string = this.editingValue;
    this.editingValue = '';
    this.saveField(key, value, this.editingAccountId);
  }

  /** Swift `saveBootstrap` / `saveTurnSettings` / `saveStunSettings` / `savePublished*`. */
  private saveField(key: string, value: string, accountId: string): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const account: AccountModel | null = accounts.getAccount(accountId);
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      this.showDaemonNotice = true;
      return;
    }
    this.isLoading = true;
    try {
      if (key === String(ConfigKey.ACCOUNT_HOSTNAME)) {
        // Swift `saveBootstrap()`.
        accounts.setAccountProperty(new ConfigKeyModel(ConfigKey.ACCOUNT_HOSTNAME), value,
          account.id);
      } else if (key === String(ConfigKey.TURN_SERVER) || key === String(ConfigKey.TURN_USERNAME)
        || key === String(ConfigKey.TURN_REALM)) {
        // Swift `saveTurnSettings()` — the whole TURN quartet goes in one call.
        this.saveTurnSettings(accounts, account.id, key, value);
      } else if (key === String(ConfigKey.STUN_SERVER)) {
        // Swift `saveStunSettings()` — an invalid address reverts to the stored one.
        if (isValidStunServer(value)) {
          accounts.setStunSettings(account.id, value);
        }
      } else if (key === String(ConfigKey.PUBLISHED_ADDRESS)) {
        // Swift `savePublishedAddress()` — `guard !publishedAddress.isEmpty`.
        if (value.length > 0) {
          accounts.setAccountProperty(new ConfigKeyModel(ConfigKey.PUBLISHED_ADDRESS), value,
            account.id);
        }
      } else if (key === String(ConfigKey.PUBLISHED_PORT)) {
        // Swift `savePublishedPort()` — `guard isValid(publishedPort, in: publishedPortRange)`.
        if (isValueInRange(value, PUBLISHED_PORT_MIN, PUBLISHED_PORT_MAX)) {
          accounts.setAccountProperty(new ConfigKeyModel(ConfigKey.PUBLISHED_PORT), value,
            account.id);
        }
      }
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
    // Swift re-reads the stored value, which is also how an invalid entry visibly reverts.
    this.refreshFromAccount();
  }

  /** Swift `accountService.setTurnSettings(accountId:server:username:password:realm:)`. */
  private saveTurnSettings(accounts: AccountsService, accountId: string, key: string,
    value: string): void {
    const server: string = key === String(ConfigKey.TURN_SERVER)
      ? value : this.fieldValue(String(ConfigKey.TURN_SERVER));
    const username: string = key === String(ConfigKey.TURN_USERNAME)
      ? value : this.fieldValue(String(ConfigKey.TURN_USERNAME));
    const realm: string = key === String(ConfigKey.TURN_REALM)
      ? value : this.fieldValue(String(ConfigKey.TURN_REALM));
    const password: string = this.fieldValue(String(ConfigKey.TURN_PASSWORD));
    accounts.setTurnSettings(accountId, server, username, password, realm);
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: SETTINGS_SUMMARY_PAGE }).catch((error: Error): void => {
        console.error('ConnectivityAndConfigurationsPage: replaceUrl ' + SETTINGS_SUMMARY_PAGE
          + ' failed: ' + error.message);
      });
      return;
    }
    router.back();
  }

  /* ── editor parameters, per Swift NavigationLink destination ─────────────────────────── */
  /** Swift `EditableFieldView(title:placeholder:)` for the row being edited. */
  private editorLabel(): ResourceStr {
    if (this.editingKey === String(ConfigKey.TURN_SERVER)) {
      return $r('app.string.account_page_turn_server');
    }
    if (this.editingKey === String(ConfigKey.TURN_USERNAME)) {
      return $r('app.string.account_page_turn_username');
    }
    if (this.editingKey === String(ConfigKey.TURN_REALM)) {
      return $r('app.string.account_page_turn_realm');
    }
    if (this.editingKey === String(ConfigKey.STUN_SERVER)) {
      return $r('app.string.account_page_stun_server');
    }
    if (this.editingKey === String(ConfigKey.PUBLISHED_ADDRESS)) {
      return $r('app.string.account_page_published_address');
    }
    if (this.editingKey === String(ConfigKey.PUBLISHED_PORT)) {
      return $r('app.string.account_page_published_port');
    }
    return $r('app.string.account_page_bootstrap');
  }

  /** Swift `keyboardType: .numberPad` on the published-port editor only. */
  private editorInputType(): InputType {
    return this.editingKey === String(ConfigKey.PUBLISHED_PORT)
      ? InputType.Number : InputType.Normal;
  }

  /** Swift `errorMessage:` — only the three editors the source validates carry one. */
  private editorErrorMessage(): ResourceStr {
    if (this.editingKey === String(ConfigKey.PUBLISHED_PORT)) {
      return $r('app.string.account_page_invalid_port');
    }
    return $r('app.string.account_page_invalid_address');
  }

  /**
   * Swift `validate:` — passed only on the STUN and published-address/port editors. The
   * bootstrap and TURN editors get an always-true check, which is what Swift's absent
   * `validate` closure does: `if let validate = validate, !validate(value)` never fires.
   */
  private editorValidate(): (value: string) => boolean {
    if (this.editingKey === String(ConfigKey.STUN_SERVER)) {
      return (value: string): boolean => isValidStunServer(value);
    }
    if (this.editingKey === String(ConfigKey.PUBLISHED_ADDRESS)) {
      return (value: string): boolean => value.length > 0;
    }
    if (this.editingKey === String(ConfigKey.PUBLISHED_PORT)) {
      return (value: string): boolean =>
        isValueInRange(value, PUBLISHED_PORT_MIN, PUBLISHED_PORT_MAX);
    }
    return (_value: string): boolean => true;
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  private isBackShortened(): boolean {
    return isBackShortened(this.fullBackWidth, this.barWidth, this.titleWidth);
  }

  private isEditorBackShortened(): boolean {
    return isBackShortened(this.editorFullBackWidth, this.editorBarWidth, this.editorTitleWidth);
  }

  /**
   * UINavigationBar centres the title on the bar when it clears the back item, and otherwise
   * slides it right to start just after it. The 1 vp keeps a title that fills the centred box
   * exactly (ellipsized, so its width IS the box) from reading as one that fits.
   */
  private isTitleCentred(): boolean {
    return this.titleWidth > 0 && this.titleWidth + 2 * this.backWidth + 1 <= this.barWidth;
  }

  /**
   * Swift `.navigationTitle(L10n.AccountPage.connectivityAndConfiguration)
   * .navigationBarTitleDisplayMode(.inline)` plus iOS's own leading back item, labelled with
   * the page one pop lands on (Settings) or "Back" when that does not fit (T-0672). A Row, so
   * the long title takes only the width the back item leaves and can never run under it.
   */
  @Builder
  private navigationBar() {
    Row() {
      // The Jami navy (#00345F = app.color.jami). The inset is padding, not margin, so the tap
      // target still reaches the screen edge as the source's own back item does; the trailing
      // padding is the gap iOS leaves before a title pushed against it.
      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        // SettingsSummaryView.swift:70 `.navigationTitle(L10n.AccountPage.settingsHeader)`.
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
          : $r('app.string.account_page_settings_header'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('back')
      .flexShrink(0)
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ left: BACK_LEADING, right: BACK_LEADING })
      .onAreaChange((_old: Area, area: Area) => {
        this.backWidth = Number(area.width);
        if (!this.isBackShortened()) {
          this.fullBackWidth = Number(area.width);
        }
      })
      .onClick(() => {
        this.goBack();
      })

      // Centred on the bar by an end inset as wide as the back item; otherwise flush after it.
      Row() {
        Text($r('app.string.account_page_connectivity_and_configuration'))
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
      .layoutWeight(1)
      .height(BAR_HEIGHT)
      .justifyContent(this.isTitleCentred() ? FlexAlign.Center : FlexAlign.Start)
      .padding({ right: this.isTitleCentred() ? this.backWidth : BACK_LEADING })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.barWidth = Number(area.width);
    })
  }

  /**
   * EditableFieldView's `.navigationTitle(L10n.Global.edit + " \(title)")`, inline, and iOS's
   * back item, labelled with this page's title when that fits beside the centred title, else
   * "Back" (T-1611) — ManageSIPAccountPage's editor bar (T-0513).
   */
  @Builder
  private editorNavigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Text() {
          Span($r('app.string.global_edit'))
          Span(' ')
          Span(this.editorLabel())
        }
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
        .flexShrink(1)
        .onAreaChange((_old: Area, area: Area) => {
          this.editorTitleWidth = Number(area.width);
        })
      }
      .width('100%')
      .height(BAR_HEIGHT)
      .justifyContent(FlexAlign.Center)

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text(this.isEditorBackShortened() ? $r('app.string.actions_back_action')
          : $r('app.string.account_page_connectivity_and_configuration'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('editable_field_back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ left: BACK_LEADING })
      .onAreaChange((_old: Area, area: Area) => {
        if (!this.isEditorBackShortened()) {
          this.editorFullBackWidth = Number(area.width);
        }
      })
      .onClick(() => {
        this.closeEditor();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.editorBarWidth = Number(area.width);
    })
  }

  /**
   * Swift `NavigationLink(destination: …) { FieldRowView(label:value:) }`: ONE clickable row
   * spanning the card, the slug on that row (never on an inner Text — a handler on a
   * descendant of the slugged node reads `contract-control-inert`). The destination is the
   * editor layer build() draws over the page, or a routed page (onRowTap).
   */
  @Builder
  private valueRow(key: string, label: ResourceStr, slug: string) {
    Row({ space: CHEVRON_GAP }) {
      FieldRowView({ label: label, value: this.displayValue(key) })
        .layoutWeight(1)
      // iOS's disclosure indicator — `chevron.forward` in the capture: a 12-tall grey glyph
      // whose box ends 21 in from the card's trailing edge.
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(CHEVRON_SIZE)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .padding({ left: ROW_TEXT_INSET - CELL_INSET, right: ROW_TEXT_INSET - CELL_INSET })
    .id(slug)
    .onClick(() => {
      this.onRowTap(key);
    })
  }

  /** Swift `Section(header: Text(...))`. */
  @Builder
  private sectionHeader(title: ResourceStr) {
    // iOS grouped section header: an UPPERCASE grey footnote caption, indented to the rows'
    // own label edge (x 40 = the card's 20 inset + 20) in a 39-tall block.
    Text(title)
      .width('100%')
      .textCase(TextCase.UpperCase)
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .padding({
        left: ROW_TEXT_INSET,
        right: ROW_TEXT_INSET,
        top: SECTION_HEADER_TOP,
        bottom: SECTION_HEADER_BOTTOM
      })
  }

  /**
   * The hairline iOS draws BETWEEN two grouped rows, inset to the label edge. Emitted before
   * every row but the first in its card, so a card never ends on a separator and a hidden
   * conditional row takes its own separator with it.
   */
  @Builder
  private rowSeparator() {
    Divider()
      .strokeWidth(HAIRLINE)
      .color($r('sys.color.comp_divider'))
      .margin({ left: ROW_TEXT_INSET - CELL_INSET })
  }

  /** Swift `dhtConfigurationView()` — AccountSettingsViews.swift:209. */
  @Builder
  private dhtConfigurationSection() {
    Column() {
      this.sectionHeader($r('app.string.account_page_dht_configuration'))

      // The section's white inset-grouped card — capture x 20..373, radius 10.
      Column() {
        this.valueRow(String(ConfigKey.ACCOUNT_HOSTNAME),
          $r('app.string.account_page_bootstrap'), 'connectivity_settings_bootstrap')

        this.rowSeparator()

        // Swift `VStack(alignment: .leading) { ToggleCell; Text(explanation).font(.footnote) }`.
        Column() {
          ToggleCell({
            toggleText: $r('app.string.account_page_peer_discovery'),
            isOn: this.peerDiscovery,
            identifier: 'connectivity_settings_peer_discovery',
            onToggle: (value: boolean): void => {
              this.setPeerDiscovery(value);
            }
          })
          // Swift `.font(.footnote).foregroundColor(.secondaryLabel)` — capture [40,227][330,260],
          // grey, at the same x 40 as the label above it, and INSIDE the card.
          Text($r('app.string.account_page_peer_discovery_explanation'))
            .width('100%')
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .padding({
              left: ROW_TEXT_INSET - CELL_INSET,
              right: ROW_TEXT_INSET - CELL_INSET,
              bottom: CELL_INSET * 3
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CELL_INSET, right: CELL_INSET })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .margin({ bottom: SECTION_GAP })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `connectivityView()` — AccountSettingsViews.swift:234, rendered for every account. */
  @Builder
  private connectivitySection() {
    Column() {
      this.sectionHeader($r('app.string.account_page_connectivity_header'))

      // The section's white inset-grouped card — capture x 20..373, radius 10.
      Column() {
        ToggleCell({
          toggleText: $r('app.string.account_page_upnp_enabled'),
          isOn: this.upnpEnabled,
          identifier: 'connectivity_settings_upnp_enabled',
          onToggle: (value: boolean): void => {
            this.setUpnpEnabled(value);
          }
        })

        this.rowSeparator()

        ToggleCell({
          toggleText: $r('app.string.account_page_turn_enabled'),
          isOn: this.isTurnEnabled,
          identifier: 'connectivity_settings_turn_enabled',
          onToggle: (value: boolean): void => {
            this.setTurnEnabled(value);
          }
        })

        // conditionalVariants[turn_enabled] — Swift `if model.turnEnabled { … }`. Each row
        // carries its own leading hairline, so hiding the branch hides its separators with it.
        //
        // `|| this.accountUnavailable`: the daemon is a Rule-11 gap, so with no account to read
        // `isTurnEnabled` is false for a reason that has nothing to do with the setting, and
        // the source landed these four rows OPEN. Hiding them on that false removed the whole
        // TURN block — four rows plus their chevrons — and left their replay slugs
        // (`connectivity_settings_turn_server|username|password|realm`) unaddressable. The rows
        // are mounted with the daemon notice beneath them instead; the branch still reads
        // `isTurnEnabled`, so a real account closing TURN still closes them.
        if (this.isTurnEnabled || this.accountUnavailable) {
          this.rowSeparator()
          this.valueRow(String(ConfigKey.TURN_SERVER), $r('app.string.account_page_turn_server'),
            'connectivity_settings_turn_server')
          this.rowSeparator()
          this.valueRow(String(ConfigKey.TURN_USERNAME),
            $r('app.string.account_page_turn_username'), 'connectivity_settings_turn_username')
          this.rowSeparator()
          this.valueRow(String(ConfigKey.TURN_PASSWORD),
            $r('app.string.account_page_turn_password'), 'connectivity_settings_turn_password')
          this.rowSeparator()
          this.valueRow(String(ConfigKey.TURN_REALM), $r('app.string.account_page_turn_realm'),
            'connectivity_settings_turn_realm')

          // The rows above are mounted with nothing behind them to read: say so HERE, beside
          // them, rather than letting four empty rows imply the daemon answered.
          if (this.accountUnavailable) {
            this.rowSeparator()
            Text($r('app.string.daemon_not_available'))
              .width('100%')
              .fontSize($r('sys.float.Body_S'))
              .fontColor(FAILURE_COLOR)
              .padding({
                left: ROW_TEXT_INSET - CELL_INSET,
                right: ROW_TEXT_INSET - CELL_INSET,
                top: SECTION_HEADER_BOTTOM,
                bottom: SECTION_HEADER_BOTTOM
              })
          }
        }

        // Swift `if model.account.type == .sip { ToggleCell(stun); if model.stunEnabled { … } }`.
        // The STUN toggle is NOT in the plan's controlInventory but IS in the source
        // (AccountSettingsViews.swift:280-285) with this exact identifier.
        if (this.isSipAccount) {
          this.rowSeparator()
          ToggleCell({
            toggleText: $r('app.string.account_page_stun_enabled'),
            isOn: this.isStunEnabled,
            identifier: 'connectivity_settings_stun_enabled',
            onToggle: (value: boolean): void => {
              this.setStunEnabled(value);
            }
          })

          // conditionalVariants[stun_enabled].
          if (this.isStunEnabled) {
            this.rowSeparator()
            this.valueRow(String(ConfigKey.STUN_SERVER),
              $r('app.string.account_page_stun_server'), 'connectivity_settings_stun_server')
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CELL_INSET, right: CELL_INSET })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .margin({ bottom: SECTION_GAP })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `publicAddressView()` — AccountSettingsViews.swift:299, SIP accounts only. */
  @Builder
  private publicAddressSection() {
    Column() {
      this.sectionHeader($r('app.string.account_page_public_address_header'))

      // The section's white inset-grouped card — capture x 20..373, radius 10.
      Column() {
        ToggleCell({
          toggleText: $r('app.string.account_page_allow_ip_auto_rewrite'),
          isOn: this.allowIPAutoRewrite,
          identifier: 'connectivity_settings_allow_ipauto_rewrite',
          onToggle: (value: boolean): void => {
            this.setAllowIPAutoRewrite(value);
          }
        })

        // Swift `if !model.allowIPAutoRewrite { … }`.
        if (!this.allowIPAutoRewrite) {
          this.rowSeparator()
          ToggleCell({
            toggleText: $r('app.string.account_page_published_same_as_local'),
            isOn: this.publishedSameAsLocal,
            identifier: 'connectivity_settings_published_same_as_local',
            onToggle: (value: boolean): void => {
              this.setPublishedSameAsLocal(value);
            }
          })

          // conditionalVariants[published_custom] — Swift `if !model.publishedSameAsLocal { … }`.
          if (this.isPublishedCustom) {
            this.rowSeparator()
            this.valueRow(String(ConfigKey.PUBLISHED_ADDRESS),
              $r('app.string.account_page_published_address'),
              'connectivity_settings_published_address')
            this.rowSeparator()
            this.valueRow(String(ConfigKey.PUBLISHED_PORT),
              $r('app.string.account_page_published_port'),
              'connectivity_settings_published_port')
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CELL_INSET, right: CELL_INSET })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .margin({ bottom: SECTION_GAP })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift's first `if model.account.type == .sip { Section { … } }` — the SIP registration. */
  @Builder
  private sipRegistrationSection() {
    Column() {
      // Swift's first SIP section carries no header — its card sits straight under the bar,
      // so it takes the header's own top gap as a margin instead.
      // The section's white inset-grouped card — capture x 20..373, radius 10.
      Column() {
        // Not in the plan's controlInventory, but declared in the source
        // (AccountSettingsViews.swift:182-187) with this identifier.
        ToggleCell({
          toggleText: $r('app.string.account_page_auto_registration'),
          isOn: this.autoRegistrationEnabled,
          identifier: 'connectivity_settings_auto_registration',
          onToggle: (value: boolean): void => {
            this.setAutoRegistration(value);
          }
        })

        this.rowSeparator()

        // navOut push -> screen_edit_expiration_time.
        this.valueRow(String(ConfigKey.REGISTRATION_EXPIRE),
          $r('app.string.account_page_sip_expiration_time'),
          'connectivity_settings_sip_expiration_time')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CELL_INSET, right: CELL_INSET })
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .margin({ top: SECTION_HEADER_TOP + SECTION_HEADER_BOTTOM, bottom: SECTION_GAP })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        this.navigationBar()

        if (this.isLoading) {
          // Exclusive with the content below: an in-flight read must never render beside the
          // values it is still reading.
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
              // conditionalVariants[sip_account] / [jami_account]. AccountType has exactly two
              // members, so the else-if pair is exhaustive AND can never render both.
              if (this.isSipAccount) {
                this.sipRegistrationSection()
              } else if (this.isJamiAccount) {
                this.dhtConfigurationSection()
              }

              // Swift `connectivityView()` — unconditional.
              this.connectivitySection()

              // Swift `if model.account.type == .sip { publicAddressView() }`.
              if (this.isSipAccount) {
                this.publicAddressSection()
              }

              // The daemon ceiling and the failure a write reported, as the list's footer. Stated
              // in place rather than as a toast: a toast is gone before the evidence dump runs.
              // `&& !this.accountUnavailable` — the TURN card already carries this exact sentence
              // in that case, and stacking the gap twice in red is what the subscribe above
              // already refuses to do.
              if (this.showDaemonNotice && !this.accountUnavailable) {
                Text($r('app.string.daemon_not_available'))
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
                  .margin({ top: FOOTNOTE_GAP })
              }
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
                  .margin({ top: FOOTNOTE_GAP })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: CARD_INSET, right: CARD_INSET, bottom: CARD_INSET })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      // iOS `systemGroupedBackground` — the capture's page grey, the colour the white cards
      // above sit on.
      .backgroundColor($r('sys.color.background_secondary'))

      // Swift `EditableFieldView` — the screen each NavigationLink pushes, as a page layer
      // (ManageSIPAccountPage, T-0513). EditPasswordView and EditExpirationtime are routed
      // pages of their own (navOut), so their rows never open this one.
      if (this.editingKey.length > 0 && this.isEditedRowShown()) {
        Column() {
          this.editorNavigationBar()
          EditableFieldView({
            value: $editingValue,
            title: this.editorLabel(),
            placeholder: this.editorLabel(),
            inputType: this.editorInputType(),
            errorMessage: this.editorErrorMessage(),
            validate: this.editorValidate(),
            onDisappearAction: (): void => {
              this.closeEditor();
            }
          })
            .margin({ top: EDITOR_LIST_TOP })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.background_secondary'))
        .transition(TransitionEffect.move(TransitionEdge.END)
          .animation({ duration: EDITOR_TRANSITION_MS }))
        .id('screen_editable_field')
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_connectivity_settings')
  }
}
