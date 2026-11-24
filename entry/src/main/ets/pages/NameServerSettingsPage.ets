/*
 * screen_name_server — "Name server", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSettingsViews.swift (struct NameServerView, line 150)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift       (EditableFieldView line 337,
 *                                                              FieldRowView line 368)
 *   Ring/Ring/Features/Settings/Me/AccountSettings.swift      (serverName 67/132,
 *                                                              saveNameServer 249)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`). navOut is empty.
 *
 * S3 — the real tree of `NameServerView.body`:
 *
 *   List {
 *     NavigationLink(destination: EditableFieldView(value: $model.serverName,
 *                                                   title: L10n.AccountPage.nameServer,
 *                                                   placeholder: L10n.Account.serverLabel,
 *                                                   onDisappearAction: { model.saveNameServer() })) {
 *       FieldRowView(label: L10n.AccountPage.nameServer, value: model.serverName)
 *     }
 *     .accessibilityIdentifier("name_server_name_server")
 *   }
 *   .navigationBarTitleDisplayMode(.inline)
 *   .navigationTitle(L10n.AccountPage.notificationTitle)
 *
 * ONE row, and nothing else — the page title really is `notificationTitle` ("Notifications"),
 * which is the source's own slip and is what the capture renders
 * (results/traversal-source/pages/NameServerView/base.ui.json), so it is reproduced verbatim
 * rather than corrected.
 *
 * THE PUSHED EDITOR IS A FULL-PAGE LAYER ON THIS PAGE — not a `router.pushUrl`, and no longer
 * inline in the row's card (T-0763). It is NotificationSettingsPage's layer (T-0774, from
 * ConnectivityAndConfigurationsPage's T-0674): an "Edit Name server" bar whose back item reads
 * "Notifications" or "Back" by the T-1611 fit rule (the inline bar ran 'Notifications' into the
 * title), the field prefilled and focused so the keyboard comes up, and closing it — back
 * item, device Back key — is what runs the write-back (`model.saveNameServer()`), exactly as
 * popping the pushed editor does in the source.
 *
 * bindingContract — [server name] <- svc_accounts: Swift `@Published var serverName`, filled by
 * `getStringState(for: .ringNsURI)` out of THIS account's own detail map
 * (AccountSettings.swift:132). Never a literal.
 *
 * DAEMON GAP (Rule 11). `saveNameServer()` is `accountService.setAccountProperty(property:
 * ConfigKey.ringNsURI …)`, whose daemon half is `account.setDetails`; the /addr lookups
 * NameService then performs are daemon work too. With no daemon the value reads back empty and
 * the save cannot persist, so closing the editor states the ceiling in the page's own body —
 * never a silent return. The idiom is pages/ChatSettingsPage.ets's `showDaemonNotice`.
 */
import { LengthMetrics, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { FieldRowView } from '../components/FieldRow';
import { EditableFieldView } from '../components/EditableField';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { NameService, LookupNameResponse, LookupNameState } from '../common/NameService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'NameServerSettingsPage';

/** The daemon feature `common/AccountsService.ts` reports when a property cannot be written. */
const ACCOUNT_DETAILS_FEATURE: string = 'account.setDetails';
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';
/**
 * The plan's feat_name_service fallback: "on a name-server failure the screen keeps the typed
 * name, shows the app's own network-error string and re-enables the control". This is that
 * string — `alerts_account_no_network_title`, the app's own.
 */
const NAME_SERVER_ERROR_RESOURCE: string = 'alerts_account_no_network_title';

/*
 * Style tokens: state.json.generation.styleBaseline (device-proven, read-only) as the sibling
 * inset-grouped settings pages already spell them — pages/ChatSettingsPage.ets,
 * pages/ConnectivityAndConfigurationsPage.ets. Corroborated by this screen's OWN capture,
 * results/traversal-source/pages/NameServerView/base.ui.json (393x852):
 *
 *   nav bar    [0,53][393,97]      -> BAR_HEIGHT 44; title 'Notifications' [146,65][247,85]
 *   the row    [20,132][373,176]   -> CARD_INSET 20, LIST_TOP 35 below the bar, 44 tall
 *   row label  [40,144][137,164]   -> ROW_TEXT_INSET 20
 *   chevron    [345,148][352,160]  -> a 7x12 glyph ending 21 in from the card's trailing edge
 */
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** The inset-grouped card's corner radius. */
const CARD_RADIUS: number = 10;
/** Nav-bar bottom (97) to card top (132) in the capture. */
const LIST_TOP: number = 35;
/** A grouped row's content inset inside its card (label at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/** The grouped row's minimum tap target — the capture's 44-tall box. */
const ROW_MIN_HEIGHT: number = 44;
/** iOS's disclosure indicator: capture [345,148][352,160], a 7x12 glyph — chevron.forward
 * is tall and narrow, so a 7x12 box is the glyph at ~14, and its ink samples (191,191,191),
 * the grey `font_tertiary` below (NOT the row's black label). */
const CHEVRON_SIZE: number = 14;
const CHEVRON_GAP: number = 8;
/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back" (T-1611's rule). The iPhone 4.20 keeps '< Notifications'
 * beside 'Edit Name server' with only ~10.5 pt between them (TC-SETTINGS-289-2), so the
 * clearance is UIKit's 8 pt item spacing (T-0964).
 */
const BACK_FIT_MARGIN: number = 8;
/**
 * Swift FocusableTextField.updateUIView: "Wait untill view shows" — becomeFirstResponder after
 * 0.5 s, which is what raises the keyboard on the pushed editor (T-0674).
 */
const EDITOR_FOCUS_DELAY_MS: number = 500;
/** The editor layer slides in from the trailing edge, as a pushed screen does. */
const EDITOR_TRANSITION_MS: number = 250;
/** The gap above a footnote-sized notice. */
const FOOTNOTE_GAP: number = 8;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';

/**
 * UINavigationBar keeps the title centred and swaps the origin's title for the generic "Back"
 * when it would not fit left of it (T-1601/T-1611 rule). The T-0964 review moved the title off
 * centre instead, to keep '< Notifications' (~123 vp) beside a centred title starting at
 * 121.5 vp on the 374 vp folded Mate X7; QA flagged the off-centre title (T-1622), so the
 * centred rule is back: '< Back' on the folded X7, '< Notifications' where it fits (iPhone).
 */
function isBackShortened(fullBackWidth: number, barWidth: number, titleWidth: number): boolean {
  return fullBackWidth > 0 && fullBackWidth + BACK_FIT_MARGIN > (barWidth - titleWidth) / 2;
}

@Entry
@Component
struct NameServerSettingsPage {
  /**
   * bindingContract[server name] <- svc_accounts. Swift `@Published var serverName`, filled by
   * `getStringState(for: .ringNsURI)` — this account's own `RingNS.uri` detail. Never a literal.
   */
  @State serverName: string = '';
  /** conditionalVariants[row] / [editing] — whether the EditableFieldView layer is open. */
  @State isEditing: boolean = false;
  /** The account the open editor belongs to, captured as it opens: the save goes there (T-1632). */
  private editingAccountId: string = '';
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The daemon gap the write hits, stated in place rather than as a toast. */
  @State showDaemonNotice: boolean = false;
  /** The editor bar's width, its title's, and its back item's while it shows "Notifications". */
  @State private editorBarWidth: number = 0;
  @State private editorTitleWidth: number = 0;
  @State private editorFullBackWidth: number = 0;

  /**
   * AppStorage['currentAccountId'] — the account these settings belong to. svc_accounts
   * rewrites it whenever the current account changes, and the name server is read out of THAT
   * account's detail map, so it is re-read rather than left on what the first render saw.
   */
  @Watch('onAccountChanged') @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;
  /** True between this screen's own verification lookup and its response. */
  private awaitingLookup: boolean = false;
  /** The account that lookup was fired for — svc_name's stream is shared app-wide. */
  private lookupAccountId: string = '';

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift `AccountSettings.init` -> `setUPJamiParameters()`, which fills `serverName` out of
    // the account's detail map before the view first renders.
    this.refreshFromAccount();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
    this.observeNameServerLookup(ServiceRegistry.shared().nameService);
  }

  /** The page is pushed, so it is re-shown after a Back from anywhere above it. */
  onPageShow(): void {
    if (this.isEditing) {
      // Do not overwrite what is being typed with the stored value.
      return;
    }
    this.refreshFromAccount();
  }

  /** The device Back key pops the editor layer first, then this page. */
  onBackPress(): boolean {
    if (!this.isEditing) {
      return false;
    }
    this.closeEditor();
    return true;
  }

  /** @Watch on currentAccountId — svc_accounts moved the current account. */
  private onAccountChanged(_propName: string): void {
    if (this.isEditing) {
      // The open editor belongs to the OUTGOING account: save it under that account
      // (editingAccountId — currentAccountId has already moved) before the page re-reads.
      this.closeEditor();
    }
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
  /** The gap THIS screen's own write raises — `setAccountDetails` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === ACCOUNT_DETAILS_FEATURE) {
        this.isLoading = false;
        // `showDaemonNotice` renders app.string.daemon_not_available, the same sentence as
        // this error's own `message`; `errorText` is left to genuinely different failures.
        this.showDaemonNotice = true;
      }
    }));
  }

  /**
   * feat_name_service — the verdict on the host this screen just configured. `NameService`'s
   * lookup stream is shared app-wide (contact rows, the search field), so only a response to
   * THIS screen's own verification is read; the plan's fallback governs it — keep the typed
   * name, show the app's network-error string, leave the control enabled. The daemon notice
   * wins where it is already up: it is the more specific statement of the same ceiling.
   */
  private observeNameServerLookup(name: NameService): void {
    this.bag.add(name.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
      if (!this.awaitingLookup || response.accountId !== this.lookupAccountId) {
        return;
      }
      this.awaitingLookup = false;
      this.isLoading = false;
      const failed: boolean = response.state === LookupNameState.ERROR ||
        response.state === LookupNameState.INVALID_NAME;
      if (failed && !this.showDaemonNotice) {
        this.errorText = this.resolveString(NAME_SERVER_ERROR_RESOURCE);
      }
    }));
  }

  /**
   * feat_name_service — the URI this screen writes IS the `nameserver` every NameService
   * lookup is handed (`lookupName`/`lookupAddress` take it per call, never a hardcoded host),
   * so the save is confirmed by resolving this account's own address against the newly
   * configured host: the feature's own verification.
   */
  private verifyNameServer(accountId: string): void {
    if (this.serverName.length === 0) {
      // Nothing configured — the account falls back to the daemon's default host, and this
      // screen has no host of its own to verify.
      return;
    }
    this.lookupAccountId = accountId;
    this.awaitingLookup = true;
    ServiceRegistry.shared().nameService.lookupAddress(accountId, this.serverName, accountId);
  }

  /** One resolver for the two plain strings this page composes outside a `Text`. */
  private resolveString(name: string): string {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      return context.resourceManager.getStringByNameSync(name);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'string %{public}s unresolved: %{public}s', name,
        describeError(error as BusinessError));
      return '';
    }
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

  /** Swift `setUPJamiParameters()` — `self.serverName = getStringState(for: .ringNsURI)`. */
  private refreshFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.currentAccount();
      const details: AccountConfigModel | null = account === null ? null : account.details;
      if (account === null || details === null) {
        // There is no account to read: configuring one is daemon work, and this build has no
        // daemon. The row keeps its place and reads empty, which is the truth.
        this.serverName = '';
        return;
      }
      this.serverName = details.get(new ConfigKeyModel(ConfigKey.RING_NS_URI));
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /** Swift the `NavigationLink`'s push of `EditableFieldView(value: $model.serverName, …)`. */
  private openEditor(): void {
    if (this.isEditing) {
      // Re-entry guard: the layer covers the row, so a second tap can only land while it is
      // still sliding in, and re-opening would throw away what has been typed.
      return;
    }
    this.errorText = '';
    this.showDaemonNotice = false;
    const account: AccountModel | null = this.currentAccount();
    this.editingAccountId = account === null ? '' : account.id;
    this.isEditing = true;
    setTimeout((): void => {
      focusControl.requestFocus('editable_field_value');
    },
      EDITOR_FOCUS_DELAY_MS);
  }

  /**
   * Swift `EditableFieldView.onDisappear { onDisappearAction() }` — the write-back, which the
   * source performs when the pushed editor is popped. The layer's back item and the device
   * Back key call it directly.
   */
  private closeEditor(): void {
    if (!this.isEditing) {
      // The editor's own `aboutToDisappear` re-enters here after the flag has already moved;
      // without this the save would run twice.
      return;
    }
    // Cleared first so that re-entry returns above.
    this.isEditing = false;
    this.saveNameServer();
  }

  /**
   * Swift `func saveNameServer()` (AccountSettings.swift:249):
   * `accountService.setAccountProperty(property: ConfigKeyModel(withKey: .ringNsURI),
   *                                    value: self.serverName, accountId: account.id)`.
   */
  private saveNameServer(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(this.editingAccountId);
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      // Nothing to write to — say so rather than returning silently.
      this.showDaemonNotice = true;
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(ConfigKey.RING_NS_URI);
    this.isLoading = true;
    try {
      // The LOCAL detail map really updates; the daemon half (`account.setDetails`) reports
      // the gap, which `observeDaemonGap` turns into the in-body notice.
      ServiceRegistry.shared().accountService
        .setAccountProperty(property, this.serverName, account.id);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
    if (details.get(property) !== this.serverName) {
      // Not even the local half moved — the write reached nothing at all.
      this.showDaemonNotice = true;
    }
    // feat_name_service: make the newly configured host take effect and say whether it answers.
    this.verifyNameServer(account.id);
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
   * Swift `.navigationTitle(L10n.AccountPage.notificationTitle)` with
   * `.navigationBarTitleDisplayMode(.inline)`, plus iOS's own leading back item: 'Settings', the
   * title of SettingsSummaryView that pushes this screen (SettingsSummaryView.swift:44,70 at
   * 4.20). Capture: 'Notifications' [146,65][247,85], centred and BOLD.
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Text($r('app.string.account_page_notification_title'))
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
      // Localized edges (LengthMetrics start/end), never left/right: an absolute edge is the
      // one thing that survives RTL mirroring, and it would park the back item on the right.
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  private isEditorBackShortened(): boolean {
    return isBackShortened(this.editorFullBackWidth, this.editorBarWidth, this.editorTitleWidth);
  }

  /**
   * EditableFieldView's `.navigationTitle(L10n.Global.edit + " \(title)")` — 'Edit Name server'
   * (capture [128,65][264,85]) — inline, and iOS's back item, labelled with this page's own
   * `notificationTitle` when that fits beside the centred title, else "Back" (T-1611).
   */
  @Builder
  private editorNavigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Text() {
          Span($r('app.string.global_edit'))
          Span(' ')
          Span($r('app.string.account_page_name_server'))
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
          : $r('app.string.account_page_notification_title'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('editable_field_back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
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
   * conditionalVariants[row] — Swift `NavigationLink(destination: …) { FieldRowView(label:
   * L10n.AccountPage.nameServer, value: model.serverName) }`.
   *
   * ONE clickable row spanning the card, with the slug on that row: the capture carries the
   * slug on the clickable Button ([20,132][373,176]) while the label Text beside it is inert,
   * and a handler on a descendant of the slugged node reads `contract-control-inert`.
   */
  @Builder
  private nameServerRow() {
    Row({ space: CHEVRON_GAP }) {
      FieldRowView({
        label: $r('app.string.account_page_name_server'),
        value: this.serverName
      })
        .layoutWeight(1)
      // iOS's disclosure indicator — `chevron.forward` in the capture.
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(CHEVRON_SIZE)
        .fontColor([$r('sys.color.font_tertiary')])
        // Decorative: the row already reads its label and value; the chevron adds no name.
        .accessibilityLevel('no')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .padding({ start: LengthMetrics.vp(ROW_TEXT_INSET), end: LengthMetrics.vp(ROW_TEXT_INSET) })
    .id('name_server_name_server')
    .onClick(() => {
      this.openEditor();
    })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        this.navigationBar()

        if (this.isLoading && !this.isEditing && this.serverName.length === 0) {
          // The first read only: exclusive with the content below, so an in-flight read never
          // renders beside the value it is still reading.
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
            // Swift `List { NavigationLink { … } }` — one row, not a collection.
            Column() {
              // The section's white inset-grouped card — capture [20,132][373,176], radius 10.
              Column() {
                // conditionalVariants[row]; [editing] is the layer build() draws over the page.
                this.nameServerRow()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)

              // The grouped section's FOOTER: the daemon ceiling and any real failure, stated in
              // place rather than as a toast. Below the card, so a notice does not push the card
              // off the captured [20,132].
              if (this.showDaemonNotice) {
                Text($r('app.string.daemon_not_available'))
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ start: LengthMetrics.vp(ROW_TEXT_INSET), end: LengthMetrics.vp(ROW_TEXT_INSET) })
                  .margin({ top: FOOTNOTE_GAP })
              }
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ start: LengthMetrics.vp(ROW_TEXT_INSET), end: LengthMetrics.vp(ROW_TEXT_INSET) })
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
      // iOS `systemGroupedBackground` — the page grey the white card sits on.
      .backgroundColor($r('sys.color.background_secondary'))

      // Swift `EditableFieldView` — the screen the NavigationLink pushes, as a page layer
      // (NotificationSettingsPage, T-0774). Its Form card sits LIST_TOP below the bar, where
      // the row's card sits on the page underneath (capture [20,132][373,176]).
      if (this.isEditing) {
        Column() {
          this.editorNavigationBar()
          EditableFieldView({
            value: $serverName,
            title: $r('app.string.account_page_name_server'),
            placeholder: $r('app.string.account_server_label'),
            onDisappearAction: (): void => {
              this.closeEditor();
            }
          })
            .margin({ top: LIST_TOP })
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
    .id('screen_name_server')
  }
}
