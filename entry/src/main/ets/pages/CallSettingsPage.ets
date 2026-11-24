/*
 * screen_call_settings — "Call Settings", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSettingsViews.swift  (struct CallSettingsView)
 *   Ring/Ring/Features/Settings/Me/AccountSettings.swift       (class AccountSettings)
 *   Ring/Ring/Extensions/View+Helpers.swift                    (struct ToggleCell)
 *
 * presentation: page. SettingsSummaryView reaches it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`).
 *
 * S3 — the real tree of `CallSettingsView.body`:
 *   List {
 *     Section {
 *       ToggleCell(toggleText: L10n.AccountPage.callsFromUnknownContacts,
 *                  getAction: { model.callsFromUnknownContacts },
 *                  setAction: { model.enableCallsFromUnknownContacts(enable: $0) },
 *                  identifier: "call_settings_calls_from_unknown_contacts")
 *     }
 *   }
 *   .navigationBarTitleDisplayMode(.inline)
 *   .navigationTitle(L10n.Global.call)
 *
 * One Section, one cell: the source declares no other control, so none is invented here.
 * conditionalVariants is empty — the screen renders one layout in every state.
 *
 * bindingContract — [toggle state] <- svc_accounts / AccountConfigModel: the switch reads
 * `ConfigKey.DHT_PUBLIC_IN` out of the account's own detail map (Swift
 * `getBoolState(for: ConfigKey.dhtPublicIn)`) and writes it back through
 * `AccountsService.switchAccountPropertyTo`. Never a literal.
 *
 * DAEMON GAP (Rule 11). The write's daemon half is `AccountsService.setAccountDetails`, which
 * reports `account.setDetails` unavailable; with no account configured at all there is nothing
 * to write to. Both cases say so on the screen — never a silent early return.
 */
import { router } from '@kit.ArkUI';
import { ToggleCell } from '../components/ToggleCell';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { BackChevron } from '../components/BackButton';

/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/*
 * S5 — measured off results/traversal-source/pages/CallSettingsView/base.ui.json
 * (a 393x852 capture). iOS's InsetGroupedListStyle spells none of these in code.
 *
 *   nav bar    [0,53][393,97]      -> BAR_HEIGHT 44, already here
 *   card       [20,132][373,197]  -> CARD_INSET 20, LIST_TOP 35 below the bar
 *   row label  x 40                -> ROW_TEXT_INSET 20 (16 of it ToggleCell's own padding)
 */
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** The inset-grouped card's corner radius. */
const CARD_RADIUS: number = 10;
/** Nav-bar bottom (97) to card top (132) in the capture. */
const LIST_TOP: number = 35;
/** A grouped row's content inset inside its card (label at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/**
 * ToggleCell carries 16 vp of that inset itself (`ohos_id_elements_margin_horizontal_l`),
 * so the card supplies the remaining 4 rather than the component being restyled for this
 * page — it is shared and already device-proven elsewhere.
 */
const CELL_INSET: number = 4;
/** The gap above a footnote-sized notice. */
const FOOTNOTE_GAP: number = 8;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;

@Entry
@Component
struct CallSettingsPage {
  /**
   * bindingContract[toggle state] <- svc_accounts / AccountConfigModel. Swift
   * `@Published var callsFromUnknownContacts`, filled by
   * `getBoolState(for: ConfigKey.dhtPublicIn)`.
   */
  @State toggleState: boolean = false;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** The failure this screen's own write reported; empty when there is none. */
  @State errorText: string = '';
  /** The daemon gap the write hits, stated in place rather than as a toast. */
  @State private showDaemonNotice: boolean = false;

  /**
   * AppStorage['currentAccountId'] — the account these settings belong to. svc_accounts
   * rewrites it whenever the current account changes, and the switch's value is read out of
   * THAT account's detail map, so it is re-read rather than left on what the first render saw.
   */
  @Watch('onAccountChanged') @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift `AccountSettings.init` -> `setUPJamiParameters()`, which fills the published
    // settings out of the account's detail map before the view first renders.
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

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** The gap THIS screen's own write raises — `setAccountDetails` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === 'account.setDetails') {
        this.isLoading = false;
        this.showDaemonNotice = true;
        this.errorText = error.message;
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

  /** Swift `private func getBoolState(for: ConfigKey.dhtPublicIn)`. */
  private refreshFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.currentAccount();
      if (account === null) {
        this.toggleState = false;
        return;
      }
      const details: AccountConfigModel | null = account.details;
      if (details === null) {
        this.toggleState = false;
        return;
      }
      this.toggleState = details.getBool(new ConfigKeyModel(ConfigKey.DHT_PUBLIC_IN));
    } finally {
      this.isLoading = false;
    }
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /** Swift `func enableCallsFromUnknownContacts(enable: Bool)`. */
  private enableCallsFromUnknownContacts(enable: boolean): void {
    // Swift's `if self.callsFromUnknownContacts == enable { return }` is NOT repeated here.
    // It guards a @Published var that the view model also writes programmatically; the only
    // caller here is the switch's own onChange, which fires only on a real change, and the
    // redundant-write guard it protects still runs inside `switchAccountPropertyTo`
    // (`if (accountDetails.get(property) === boolToString(state)) return`). Repeating it at the
    // page would add the one thing this screen must not have: a tap that returns silently.
    this.errorText = '';
    this.showDaemonNotice = false;
    // The switch follows the finger whatever the write reaches; the notice below states what
    // it reached.
    this.toggleState = enable;
    const account: AccountModel | null = this.currentAccount();
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      // There is nothing to write to: configuring an account is daemon work, and this build
      // has no daemon. `switchAccountPropertyTo` returns silently on both of these, so the
      // screen says it here instead.
      this.showDaemonNotice = true;
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(ConfigKey.DHT_PUBLIC_IN);
    this.isLoading = true;
    try {
      // The LOCAL detail map really updates; the daemon half (`account.setDetails`) reports the
      // gap synchronously, which the subscription above turns into the notice.
      ServiceRegistry.shared().accountService
        .switchAccountPropertyTo(enable, account.id, property);
    } finally {
      this.isLoading = false;
    }
    if (details.getBool(property) !== enable) {
      // Not even the local half moved — the write reached nothing at all.
      this.showDaemonNotice = true;
    }
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: SETTINGS_SUMMARY_PAGE }).catch((error: Error): void => {
        console.error('CallSettingsPage: replaceUrl ' + SETTINGS_SUMMARY_PAGE + ' failed: '
          + error.message);
      });
      return;
    }
    router.back();
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * Swift `.navigationTitle(L10n.Global.call).navigationBarTitleDisplayMode(.inline)` plus
   * iOS's own leading back item, labelled with the ORIGIN page's title ("Settings").
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // Capture: the title is centred and BOLD — iOS's inline nav title.
      Text($r('app.string.global_call'))
        .width('100%')
        .height(BAR_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      // Capture: chevron + label in the Jami navy (#00345F = app.color.jami). The inset is
      // padding, not margin, so the tap target still reaches the screen edge as the
      // source's own back item does.
      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text($r('app.string.account_page_settings_header'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ left: FOOTNOTE_GAP })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  build() {
    Column() {
      this.navigationBar()

      if (this.isLoading) {
        // Exclusive with the content below: an in-flight read must never render beside the
        // value it is still reading.
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
          // Swift `List { Section { ToggleCell } }` — one static section, not a collection.
          Column() {
            // The one Section's card: capture [20,132][373,197], white on the page grey,
            // 10 vp radius. The label lands at x 40 = card 20 + CELL_INSET 4 + ToggleCell's
            // own 16.
            Column() {
              ToggleCell({
                toggleText: $r('app.string.account_page_calls_from_unknown_contacts'),
                isOn: this.toggleState,
                identifier: 'call_settings_calls_from_unknown_contacts',
                onToggle: (value: boolean): void => {
                  this.enableCallsFromUnknownContacts(value);
                }
              })
            }
            .width('100%')
            .padding({ left: CELL_INSET, right: CELL_INSET })
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(CARD_RADIUS)

            // S6 — the daemon gap and the failure the write reported, as the grouped
            // section's FOOTER: below its card, footnote size, Swift's `Color.jamiFailure`,
            // at the same x 40 the card's own label sits at. Both stay rendered in the page
            // body; putting them after the card rather than before it is what keeps the card
            // itself at the captured [20,132] in the toggled state, instead of pushing it down
            // by the height of the notice.
            if (this.showDaemonNotice) {
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
          .padding({ left: CARD_INSET, right: CARD_INSET, top: LIST_TOP })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the capture's page grey (#f1f3f5), the colour the
    // white card above sits on.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_call_settings')
  }
}
