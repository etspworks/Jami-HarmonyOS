/*
 * screen_edit_expiration_time — "Edit Registration Expiry", ported from
 *   Ring/Ring/Features/Settings/Me/AccountSettingsViews.swift (EditExpirationtime, line 409)
 *   Ring/Ring/Features/Settings/Me/AccountSettings.swift (setExpirationTime,
 *     registrationExpireRange = 60...604800, isValid(_:in:))
 *
 * presentation: page. ConnectivitySettingsView reaches it with a NavigationLink
 * (`NavigationLink(destination: EditExpirationtime(expirationtime: $model
 * .autoRegistrationExpirationTime, ...))`), so it is an @Entry page on the router stack and
 * pages/ConnectivityAndConfigurationsPage already pushes it. Back is the platform affordance,
 * composed here because an @Entry router page draws no system chrome (controlInventory's
 * `implicit: true / affordance: back` entry, hence `.id('back')`).
 *
 * navOut: none.
 *
 * S3 — the real tree of `EditExpirationtime.body`:
 *
 *   Form { Section(footer: footer) {
 *     HStack {
 *       TextField(L10n.Global.time, text: $expirationtime).keyboardType(.numberPad)
 *         .overlay(RoundedRectangle(cornerRadius: 10).stroke(...))
 *         .accessibilityIdentifier("edit_expiration_time_field")
 *       Stepper("", value: Binding(get/set clamped to registrationExpireRange), step: 1)
 *         .accessibilityIdentifier("edit_expiration_time_stepper")
 *     } } }
 *
 * THE STEPPER IS TWO BUTTONS, not one Counter. UIKit renders a SwiftUI Stepper as a segmented
 * pill whose two halves are separate accessibility elements, and the capture
 * (results/traversal-source/pages/EditExpirationtime/base.ui.json) records them that way:
 *   Decrement  edit_expiration_time_stepper-Decrement  [259,158][305,190]
 *   Increment  edit_expiration_time_stepper-Increment  [306,158][353,190]
 * Those two ids are what action-contracts.json requires and what the on-device drivers locate,
 * so each half is its own Button carrying its own slug. The slug is NOT put on the wrapper Row:
 * a handler living on a descendant of the slugged node reads `contract-control-inert`, and a
 * tap at the wrapper's centre lands on the hairline divider between the two halves.
 *
 * conditionalVariants[out_of_range] — Swift's `@ViewBuilder private var footer`, an `if isValid`
 * with the red invalid string on the false branch. Built as a real ArkUI `if`.
 *
 * INITIAL STATE, from the capture: the field is EMPTY (the placeholder "Time" shows) in every
 * captured state, the stepper's accessibility value reads 60 — SwiftUI clamping its binding to
 * `registrationExpireRange.lowerBound` — and the footer is the RED out-of-range one, because
 * `AccountSettings.isValid("")` is false. That is what this page starts as.
 *
 * S4 — `value` is read out of svc_accounts (ConfigKey.REGISTRATION_EXPIRE on the current
 * account's AccountConfigModel, Swift `$model.autoRegistrationExpirationTime` <-
 * `getStringState(for: ConfigKey.registrationExpire)`), the write-back is
 * `AccountSettings.setExpirationTime()` on aboutToDisappear (Swift
 * `.onDisappear { onDisappearAction() }` — this view has NO submit control and never had one),
 * and the daemon ceiling is stated in place through the DaemonService.unavailableEvents
 * subscription (app.string.daemon_not_available), never a toast.
 *
 * DAEMON GAP (Rule 11). The value is a jami-daemon account config key. The control keeps its
 * place; the local @State drives the clamp and the footer branch, and an unreachable daemon
 * reads back empty — which is exactly what the capture itself shows.
 */
import { LengthMetrics, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

/** Swift: `AccountSettings.registrationExpireRange = 60...(7 * 24 * 3600)`. */
const EXPIRY_MIN_SECONDS: number = 60;
const EXPIRY_MAX_SECONDS: number = 604800;

/** ConnectivitySettingsView is what pushed this page — the root a cold deep link lacks. */
const CONNECTIVITY_PAGE: string = 'pages/ConnectivityAndConfigurationsPage';

/*
 * Structure-bearing measurements off results/traversal-source/pages/EditExpirationtime/
 * base.ui.json (393x852). Exact colour/typography is S5; these are only enough to lay the real
 * tree out, and they agree with the sibling inset-grouped settings pages
 * (pages/NameServerSettingsPage.ets, pages/ConnectivityAndConfigurationsPage.ets):
 *
 *   nav bar     [0,53][393,97]        -> BAR_HEIGHT 44; title 'Expiration time' [137,65][256,85]
 *   back item   [0,53][68,97]         -> the chevron plus its 'Back' label
 *   the card    [20,132][373,216]     -> CARD_INSET 20, LIST_TOP 35 below the bar
 *   the field   [39,153][193,196]     -> 19 inside the card; that is the ACCESSIBILITY
 *                                      frame. S5 measured the DRAWN stroke off base.png:
 *                                      x 39.4..193.4, y 157.1..192.5 -> 154x36, cornerRadius
 *                                      10 (Swift), and the card is y 132.8..216.9 (84 tall),
 *                                      so the row's vertical padding is 24, not the 21 the
 *                                      a11y frame implied.
 *   the stepper [259,158][353,190]    -> 94x32, split 305|306 by a hairline divider
 *   the footer  [20,216][373,250]     -> below the card, on the grouped grey
 */
const CARD_INSET: number = 20;
const CARD_RADIUS: number = 10;
const LIST_TOP: number = 35;
/** The field's own inset inside the card (x 39 = card 20 + 19). */
const ROW_INSET: number = 19;
/** Card top 132.8 to the field's drawn top 157.1, and the same below (216.9 - 192.5). */
const ROW_V_PADDING: number = 24;
/** Swift `.overlay(RoundedRectangle(cornerRadius: 10).stroke(..., lineWidth: 1))`. */
const FIELD_RADIUS: number = 10;
const FIELD_BORDER: number = 1;
/** The field's drawn stroke box, 154x36 (the a11y frame it reports is taller). */
const FIELD_WIDTH: number = 154;
const FIELD_HEIGHT: number = 36;
/** Placeholder 'Time' starts at x 60.4, the field's inner edge at 40.7 -> 20 of lead. */
const FIELD_TEXT_INSET: number = 20;
/** One half of the segmented stepper pill: 94x32 split in two. */
const STEPPER_HALF_WIDTH: number = 47;
const STEPPER_HEIGHT: number = 32;
const STEPPER_RADIUS: number = 8;
/** The hairline between the two halves: 18 of the pill's 32, centred. */
const STEPPER_DIVIDER_HEIGHT: number = 18;
const STEPPER_GLYPH_SIZE: number = 17;
const BAR_HEIGHT: number = 44;
const BACK_GLYPH_GAP: number = 6;
const FOOTNOTE_GAP: number = 8;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back" — EditPasswordFieldPage's BACK_FIT_MARGIN (T-1611).
 */
const BACK_FIT_MARGIN: number = 16;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, this app's own failure colour. */
const FAILURE_COLOR: string = '#F00000';
/**
 * The footer is Swift's `.foregroundColor(.red)`, and SwiftUI `.red` is systemRed, not
 * jamiFailure. The capture agrees: the reddest pixel of the footer band in
 * results/traversal-source/pages/EditExpirationtime/base.png is exactly (255, 59, 48).
 * Same value as components/EditableField.ets's ERROR_RED.
 */
const SYSTEM_RED: string = '#FF3B30';

@Entry
@Component
struct EditRegistrationExpiryPage {
  /**
   * bindingContract[value] <- svc_accounts. Swift `@Binding var expirationtime: String`, which
   * ConnectivitySettingsView fills from `$model.autoRegistrationExpirationTime`. Wired in S4;
   * empty is what the capture renders, and what the daemon gap leaves it as.
   */
  @State value: string = '';
  /**
   * Swift `@SwiftUI.State private var stepperValue: Int`. Not rendered — the source stepper
   * shows only its two glyphs and carries the number as its accessibility value, which the
   * capture reads as 60 while the field is empty (SwiftUI clamping to the range's lower bound).
   */
  @State private stepperValue: number = EXPIRY_MIN_SECONDS;
  /**
   * conditionalVariants[out_of_range] — Swift `isValid` inverted. True at first render because
   * `AccountSettings.isValid("")` is false, which is the red footer every capture shows.
   */
  @State isOutOfRange: boolean = true;
  /**
   * Swift `@SwiftUI.State private var isTextFieldFocused = false` (AccountSettingsViews.swift:412,
   * `struct EditExpirationtime`) — the field's own first-responder state, declared by the source
   * and dropped in S2/S3 because the Swift body never read it back.
   *
   * Ported here with components/WalkthroughTextEdit.ets's pattern, for its reason: UIKit
   * publishes the first-responder ("is editing") trait on the text field itself, ArkUI
   * publishes nothing, so the app states the same fact. Additive — no pixel, control or
   * binding changes.
   */
  @State private isTextFieldFocused: boolean = false;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * The daemon ceiling (Rule 11): `AccountsService.setAccountDetails` -> `account.setDetails`
   * is unavailable on this build, so the write states it in place rather than failing silently.
   */
  @State private showDaemonNotice: boolean = false;
  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /** The bar, its title and its back item, measured for the back label's fit (T-1611). */
  @State private barWidth: number = 0;
  @State private titleWidth: number = 0;
  /** The back item's width while it still shows the origin's title, kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  /** Swift `.onAppear { if let initialValue = Int(expirationtime) { stepperValue = initialValue } }`
   * over the binding ConnectivitySettingsView fills from the account's own detail map. */
  aboutToAppear(): void {
    this.loadFromAccount();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /**
   * A pop shows the previous page (its onPageShow re-reads the account) BEFORE this page's
   * aboutToDisappear runs, so the write goes here; the later call finds nothing changed.
   */
  onPageHide(): void {
    this.saveExpirationTime();
  }

  /** Swift `.onDisappear { onDisappearAction() }` — the ONLY write this view performs. */
  aboutToDisappear(): void {
    try {
      this.saveExpirationTime();
    } finally {
      // ArkTS rule 8 — the subscription is released whatever the write did.
      this.bag.dispose();
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
   * bindingContract[value] <- svc_accounts: Swift `getStringState(for: .registrationExpire)`,
   * a plain lookup in THIS account's own detail map — never a default table and never a
   * literal from the capture. A key the account does not carry reads back EMPTY, which is
   * what this build genuinely yields (the daemon is a Rule-11 gap) and what every captured
   * state shows: an empty field, the stepper at the range's lower bound, the red footer.
   */
  private loadFromAccount(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.currentAccount();
      const details: AccountConfigModel | null = account === null ? null : account.details;
      const stored: string = details === null
        ? '' : details.get(new ConfigKeyModel(ConfigKey.REGISTRATION_EXPIRE));
      this.value = stored;
      // Swift's Stepper(value:in:) clamps its binding, so an unparsable/absent value renders
      // as the range's lower bound while the field itself stays empty.
      this.stepperValue = this.isValidValue(stored)
        ? Number.parseInt(stored, 10) : EXPIRY_MIN_SECONDS;
      this.isOutOfRange = !this.isValidValue(stored);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift `AccountSettings.setExpirationTime()`:
   *   guard isValid(value, in: registrationExpireRange) else { value = saved; return }
   *   if value == saved { return }
   *   accountService.setAccountProperty(.registrationExpire, value, account.id)
   * An invalid value is never written — the stored one is put back instead.
   */
  private saveExpirationTime(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const account: AccountModel | null = this.currentAccount();
    const details: AccountConfigModel | null = account === null ? null : account.details;
    if (account === null || details === null) {
      // Nothing to write to: configuring an account is daemon work, and this build has none.
      this.showDaemonNotice = true;
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(ConfigKey.REGISTRATION_EXPIRE);
    const saved: string = details.get(property);
    if (!this.isValidValue(this.value)) {
      // Swift `autoRegistrationExpirationTime = saved` — the invalid entry visibly reverts.
      this.value = saved;
      this.stepperValue = this.isValidValue(saved)
        ? Number.parseInt(saved, 10) : EXPIRY_MIN_SECONDS;
      this.isOutOfRange = !this.isValidValue(saved);
      return;
    }
    if (this.value === saved) {
      return;
    }
    this.isLoading = true;
    try {
      ServiceRegistry.shared().accountService
        .setAccountProperty(property, this.value, account.id);
    } catch (error) {
      // The write itself failed, which is a different thing from the daemon ceiling.
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
    if (details.get(property) !== this.value) {
      // Not even the local half moved — the write reached nothing at all.
      this.showDaemonNotice = true;
    }
  }

  /**
   * Swift `static func isValid(_ value: String, in range: ClosedRange<Int>)`:
   *   guard let number = Int(value) else { return false }
   *   return range.contains(number)
   * `Int(_:)` parses the WHOLE string, so "60abc" is invalid there and must be here too —
   * Number.parseInt would happily return 60 and silently widen the valid set.
   */
  private isValidValue(text: string): boolean {
    if (!/^[+-]?[0-9]+$/.test(text)) {
      return false;
    }
    const seconds: number = Number.parseInt(text, 10);
    return seconds >= EXPIRY_MIN_SECONDS && seconds <= EXPIRY_MAX_SECONDS;
  }

  /**
   * What a screen reader is told about the field: that it is being edited while it holds focus,
   * its own label otherwise. Two `Resource` branches, never a `Resource | string` union —
   * `accessibilityDescription` is an OVERLOAD pair (`string` | `Resource`) and a union matches
   * neither.
   */
  private focusHint(): Resource {
    return this.isTextFieldFocused
      ? $r('app.string.accessibility_text_field_editing')
      : $r('app.string.global_time');
  }

  /** Swift: TextField `.onChange(of: expirationtime)` — `Int(newValue) ?? 0` into stepperValue. */
  private onValueTyped(typed: string): void {
    this.value = typed;
    this.stepperValue = /^[+-]?[0-9]+$/.test(typed) ? Number.parseInt(typed, 10) : 0;
    this.isOutOfRange = !this.isValidValue(typed);
  }

  /**
   * Swift: the Stepper binding's `set:` —
   *   stepperValue = min(max(range.lowerBound, newValue), range.upperBound)
   *   expirationtime = "\(stepperValue)"
   * Both halves go through it, so the clamp is written once.
   */
  private setStepper(next: number): void {
    const clamped: number = Math.min(Math.max(EXPIRY_MIN_SECONDS, next), EXPIRY_MAX_SECONDS);
    this.stepperValue = clamped;
    this.value = clamped.toString();
    this.isOutOfRange = !this.isValidValue(this.value);
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
      router.replaceUrl({ url: CONNECTIVITY_PAGE }).catch((error: Error): void => {
        this.isNavigating = false;
        console.error('EditRegistrationExpiryPage: replaceUrl ' + CONNECTIVITY_PAGE
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

  /** Swift `.navigationTitle(L10n.AccountPage.editSipExpirationTime)`, inline, plus iOS's own
   * leading back item — capture: title [137,65][256,85] centred, back item [0,53][68,97]. */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Text($r('app.string.account_page_edit_sip_expiration_time'))
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
        // Connectivity and configurations (AccountSettingsViews.swift:180, the NavigationLink's
        // owner) — and with "Back" when that does not fit beside the title (T-1611).
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
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

  /**
   * Swift `Stepper("", value: …, in: registrationExpireRange, step: 1)` as UIKit renders it:
   * one segmented pill, two independently addressable halves divided by a hairline. Each half
   * is its own Button carrying its own source slug.
   *
   * The visible content is the −/+ glyph, which no matcher can key on, so each half also
   * carries `.accessibilityDescription` with the capture's own label ('Decrement'/'Increment').
   * That attribute — unlike `.accessibilityText()` — does surface in the HarmonyOS uitest dump,
   * so it is the only locator these icon-only controls have besides their `.id()`.
   */
  @Builder
  private stepper() {
    Row() {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.minus'))
          .fontSize(STEPPER_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .width(STEPPER_HALF_WIDTH)
      .height(STEPPER_HEIGHT)
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .padding(0)
      .id('edit_expiration_time_stepper-Decrement')
      .accessibilityDescription('Decrement')
      .onClick(() => {
        this.setStepper(this.stepperValue - 1);
      })

      // The pill's hairline divider — S5 measured it off base.png at x 305.6..306.6 (1 pt)
      // and y 165.8..183.5, i.e. an 18 pt rule centred in the 32 pt pill, NOT full height.
      Divider()
        .vertical(true)
        .height(STEPPER_DIVIDER_HEIGHT)
        .strokeWidth(1)
        .color($r('sys.color.comp_divider'))

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(STEPPER_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .width(STEPPER_HALF_WIDTH)
      .height(STEPPER_HEIGHT)
      .backgroundColor(Color.Transparent)
      .borderRadius(0)
      .padding(0)
      .id('edit_expiration_time_stepper-Increment')
      .accessibilityDescription('Increment')
      .onClick(() => {
        this.setStepper(this.stepperValue + 1);
      })
    }
    .height(STEPPER_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('sys.color.comp_background_gray'))
    .borderRadius(STEPPER_RADIUS)
    .clip(true)
  }

  build() {
    Column() {
      this.navigationBar()

      Scroll() {
        // Swift `Form { Section(footer: footer) { … } }` — one section, one row.
        Column() {
          // The section's white inset-grouped card — capture [20,132][373,216], radius 10.
          Column() {
            // Swift `HStack { TextField … ; Stepper … }`.
            Row() {
              // Swift `TextField(L10n.Global.time, text: $expirationtime)
              //          .keyboardType(.numberPad)`, with the stroked rounded overlay.
              TextInput({ placeholder: $r('app.string.global_time'), text: $$this.value })
                .type(InputType.Number)
                .width(FIELD_WIDTH)
                .height(FIELD_HEIGHT)
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('app.color.label'))
                .placeholderColor($r('app.color.placeholder_text'))
                .backgroundColor(Color.Transparent)
                .borderRadius(FIELD_RADIUS)
                .border({ width: FIELD_BORDER, color: $r('app.color.secondary_label') })
                .padding({
                  start: LengthMetrics.vp(FIELD_TEXT_INSET),
                  end: LengthMetrics.vp(FIELD_TEXT_INSET)
                })
                .id('edit_expiration_time_field')
                .onChange((typed: string) => {
                  this.onValueTyped(typed);
                })
                // Swift's own `isTextFieldFocused` state, both directions.
                .onFocus(() => {
                  this.isTextFieldFocused = true;
                })
                .onBlur(() => {
                  this.isTextFieldFocused = false;
                })
                .accessibilityDescription(this.focusHint())

              // Swift's HStack spacing — the stepper sits at the row's trailing edge.
              Blank()

              this.stepper()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({
              start: LengthMetrics.vp(ROW_INSET),
              end: LengthMetrics.vp(ROW_INSET),
              top: LengthMetrics.vp(ROW_V_PADDING),
              bottom: LengthMetrics.vp(ROW_V_PADDING)
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(CARD_RADIUS)

          // Swift `@ViewBuilder private var footer` — the grouped section's footer, below the
          // card on the grey. conditionalVariants[out_of_range]: a real `if`, never flattened.
          if (this.isOutOfRange) {
            // Swift `Text(L10n.AccountPage.invalidSipExpirationTime).foregroundColor(.red)`.
            // Capture [20,216][373,250], slug `enter_a_value_between`. Not clickable.
            Text($r('app.string.account_page_invalid_sip_expiration_time'))
              .width('100%')
              .fontSize($r('sys.float.Body_S'))
              .fontColor(SYSTEM_RED)
              .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })
              .margin({ top: FOOTNOTE_GAP })
              .id('enter_a_value_between')
          } else {
            // Swift `Text(L10n.AccountPage.selectSipExpirationTime)` — the valid branch.
            Text($r('app.string.account_page_select_sip_expiration_time'))
              .width('100%')
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.secondary_label'))
              .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })
              .margin({ top: FOOTNOTE_GAP })
          }

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
    .id('screen_edit_expiration_time')
  }
}
