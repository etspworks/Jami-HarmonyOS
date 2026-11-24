/*
 * screen_manage_account — "Manage Account", ported from
 *   Ring/Ring/Features/Settings/Me/ManageAccountView.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (CustomAlert)
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/AccountMigrationModel.swift
 *
 * presentation: page. AccountSummaryView reaches it with a NavigationLink, so it is an @Entry
 * page pushed from AccountSummarySettingsRootPage. Back is the platform affordance
 * (controlInventory marks it implicit).
 *
 * S3 builds the REAL component tree of `ManageAccountView.body`, unstyled:
 *
 *   ZStack {
 *     Form {
 *       Section { NavigationLink(BlockedContactsView) { HStack { Text(blockedContacts) } }
 *                 NavigationLink(EncryptAccount)      { HStack { Text(encryptAccount) } }
 *                 NavigationLink(BackupAccount)       { HStack { Text(BackupAccount.title) } } }
 *       Section { Button { showRemovalAlert = true } label:
 *                   { HStack { Spacer; Text(removeAccount).foregroundColor(.jamiFailure); Spacer } } }
 *     }
 *     if showRemovalAlert { CustomAlert { removalAlertContent() } }
 *   }
 *
 *   removalAlertContent(): VStack { Text(removeAccount).headline
 *                                   Text(removeAccountMessage)
 *                                   HStack { Cancel; Spacer; Remove } }
 *
 * PLAN vs SOURCE — the plan lists `comp_settings_row` for this screen and the source does NOT
 * use it: every row here is a bare `HStack { Text(...) }` with no leading glyph, and the
 * capture (S0113) confirms it — label, separator, chevron, nothing else. THE ONE INVARIANT
 * says the source wins, so SettingsRow is not instantiated and no icon is invented. Reported
 * to the orchestrator as a plan defect.
 *
 * bindingContract is EMPTY by design: this screen is static chrome, so every string is a
 * string resource.
 *
 * conditionalVariants[confirm_open] is the `if (this.isConfirmOpen)` layer below — the source
 * renders the confirmation IN PLACE over the form (a CustomAlert in its own ZStack), not as a
 * system dialog, so it stays a Stack layer here too.
 *
 * DAEMON GAP: removing an account is jami-daemon work the target platform cannot run. The
 * Remove control keeps its place, runs, and reports the gap — never a silent early return.
 *
 * S5/S6 style this tree against S0113, S0114, S0231, S0232, S0233, S0241.
 */
import { router, LengthMetrics } from '@kit.ArkUI';
import { CustomAlert } from '../components/CustomAlert';
import { AccountModel } from '../model/AccountModel';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonUnavailableError } from '../common/DaemonService';
import { BackChevron } from '../components/BackButton';

/* ── S5 metrics ───────────────────────────────────────────────────────────────────────────
 * The source is a SwiftUI `Form` with an INLINE nav title, i.e. iOS 15+ inset-grouped
 * (mapping-tables.md §7): a grey page, white content-sized cards inset from both edges, a
 * disclosure chevron iOS draws for each NavigationLink, and a separator between sibling rows
 * inset to the row's text leading edge. None of that is spelled in the Swift, so the values
 * are the design TOKENS for those iOS roles (ios-to-harmonyos-design-tokens.md); the two
 * literals are the platform bar height and the app's own failure colour.
 */
/** iOS inline navigation-bar / grouped-row height — a platform constant. */
const BAR_HEIGHT: number = 44;
/**
 * The grouped separator's inset — the row's own horizontal padding, since these rows lead
 * with TEXT (the source uses a bare `HStack { Text(...) }`, no glyph). S6 measured it on the
 * capture's own tree (S0231 `base.ui.json`, 393pt): the card spans [20..373] and every label
 * starts at x=40, i.e. 20 inside the card, which is `padding_level10`.
 */
const SEPARATOR_INSET: number = 20;
/**
 * S6, measured on S0231: iOS's grouped SECTION gap — nav bar bottom 97 to the first card's
 * top 132, and the first card's bottom 264 to the remove card's top 300. UIKit's metric, not
 * the app's, so a platform constant rather than a token.
 */
const GROUPED_SECTION_GAP: number = 35;
/**
 * `Color.jamiFailure` from Ring/Ring/Extensions/UIColor+Ring.swift:99, verbatim — the colour
 * the source puts on both destructive labels. A literal rather than a colour resource because
 * the app carries no jami_failure colour and resources are not this pass's to write; the
 * consequence is that it has no dark-mode variant, reported as a carry-forward.
 */
const JAMI_FAILURE: string = '#F00000';
/** Swift `VStack(spacing: 20)` in `removalAlertContent()`. */
const ALERT_STACK_GAP: number = 20;
/**
 * The page AccountSummaryView pushes this one from — iOS's back item carries THAT page's
 * title ("Account"), so the pop target and the label are the same screen.
 */
const ACCOUNT_SUMMARY_PAGE: string = 'pages/AccountSummarySettingsRootPage';
/** Capture: the gap between the chevron and its label. */
const BACK_GLYPH_GAP: number = 6;

/** `Form`/`List(.insetGrouped)`: a white, content-sized card inset from both page edges. */
@Styles function groupedCard() {
  .width('100%')
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .clip(true)
}

/** The padding of one grouped row inside a card. */
@Styles function groupedRow() {
  .width('100%')
    .padding({
      left: $r('sys.float.padding_level10'),
      right: $r('sys.float.padding_level10'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4')
    })
}

@Entry
@Component
struct ManageAccountPage {
  /** Swift: `@State private var showRemovalAlert` (conditionalVariants[confirm_open]). */
  @State isConfirmOpen: boolean = false;
  /** True while svc_accounts is being read. */
  @State isLoading: boolean = false;
  /** The daemon gap the Remove control hits, stated in place rather than as a toast. */
  @State private showDaemonNotice: boolean = false;
  /** The gap's own message, rendered under the notice; empty when nothing has failed. */
  @State errorText: string = '';

  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // The gap THIS screen's own control raises — `removeAccount` on the daemon half.
    this.bag.add(ServiceRegistry.shared().daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'account.remove') {
          this.showDaemonNotice = true;
          this.errorText = error.message;
        }
      }));
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
    }
  }

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** Swift `AccountSummaryVM.account` — here the account id in AppStorage. */
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

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /** Swift `NavigationLink -> BlockedContactsView`. */
  private openBlockedContacts(): void {
    router.pushUrl({ url: 'pages/BlockedContactsPage' });
  }

  /** Swift `NavigationLink -> EncryptAccount`. */
  private openEncryptAccount(): void {
    router.pushUrl({ url: 'pages/EncryptChangeAccountPasswordPage' });
  }

  /** Swift `NavigationLink -> BackupAccount`. */
  private openBackupAccount(): void {
    router.pushUrl({ url: 'pages/BackupAccountPage' });
  }

  /** Swift: the removeAccount Button — `showRemovalAlert = true`. */
  private showRemovalConfirmation(): void {
    this.isConfirmOpen = true;
  }

  /**
   * iOS's leading back item for a page pushed by a NavigationLink — the same pop the device
   * Back key performs. A cold deep link can land here as the only entry in the stack, where
   * `back()` would pop the last page and exit the app, so go to the parent coordinator root
   * instead (the same shape AccountSummarySettingsRootPage.dismiss() uses).
   */
  private goBack(): void {
    if (router.getLength() === '1') {
      router.replaceUrl({ url: ACCOUNT_SUMMARY_PAGE }).catch((error: Error): void => {
        console.error('ManageAccountPage: replaceUrl ' + ACCOUNT_SUMMARY_PAGE + ' failed: '
          + error.message);
      });
      return;
    }
    router.back();
  }

  /** Swift: removalAlertContent's Cancel — `showRemovalAlert = false`. */
  private cancelRemoval(): void {
    this.isConfirmOpen = false;
  }

  /**
   * Swift: removalAlertContent's Remove — `model.removeAccount(statePublisher:)`: remove, make
   * the next account that needs no migration current and leave settings for the smart list
   * (walkthrough when none is left, migration when every one needs it) (T-1616).
   */
  private removeAccount(): void {
    const account: AccountModel | null = this.currentAccount();
    this.isConfirmOpen = false;
    if (account === null) {
      // The same daemon gap one step earlier: with no daemon there is no account to remove.
      // State it instead of returning silently.
      this.showDaemonNotice = true;
      this.errorText = '';
      return;
    }
    // Cleared first: the gap is reported synchronously, so the subscription above sets it
    // again on the way back out if the daemon is still missing.
    this.showDaemonNotice = false;
    this.errorText = '';
    this.isLoading = true;
    try {
      ServiceRegistry.shared().accountService.removeAccountAndLeaveSettings(account.id);
    } finally {
      this.isLoading = false;
    }
  }

  /* ── render ───────────────────────────────────────────────────────────────────────────── */
  /** Swift: `NavigationLink { HStack { Text(title) } }` — label plus the push chevron. */
  @Builder
  navigationRow(title: Resource, slug: string, onTap: () => void) {
    Row() {
      Text(title)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      // The chevron iOS draws for a NavigationLink with no line of Swift
      // (mapping-tables.md §7) — part of the row, not a control of its own.
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: BAR_HEIGHT })
    .groupedRow()
    .id(slug)
    // The whole row is the tap target, exactly as the NavigationLink is.
    .onClick(() => {
      onTap();
    })
  }

  /** iOS draws a grouped row separator itself, inset to the row's text leading edge. */
  @Builder
  rowSeparator() {
    Divider()
      .strokeWidth(0.5)
      .color($r('sys.color.comp_divider'))
      .margin({ left: SEPARATOR_INSET })
  }

  /** Swift `removalAlertContent()`. */
  @Builder
  removalAlertContent() {
    // Swift `VStack(spacing: 20) { headline; subheadline; HStack { Cancel; Spacer; Remove } }`.
    Column({ space: ALERT_STACK_GAP }) {
      Text($r('app.string.global_remove_account'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      Text($r('app.string.account_page_remove_account_message'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)

      if (this.showDaemonNotice) {
        Text($r('app.string.daemon_not_available'))
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
      }
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
      }

      Row() {
        // Swift `.foregroundColor(Color(UIColor.label))` — the non-destructive choice.
        Text($r('app.string.global_cancel'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .id('manage_account_cancel')
          .onClick(() => {
            this.cancelRemoval();
          })
        Blank()
        // Swift `.foregroundColor(Color.jamiFailure)`.
        Text($r('app.string.global_remove'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor(JAMI_FAILURE)
          .id('manage_account_remove')
          .onClick(() => {
            this.removeAccount();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  build() {
    // Swift `ZStack { Form { ... }; if showRemovalAlert { removalAlert() } }`.
    Stack() {
      Column() {
        // Swift `.navigationTitle(...).navigationBarTitleDisplayMode(.inline)` — iOS centres
        // an inline title in the bar's own optical row (mapping-tables.md §7) and draws the
        // leading back item itself, labelled with the ORIGIN page's title ("Account"). An
        // @Entry router page draws no system chrome, so that item is composed here; it is
        // controlInventory's `implicit: true / affordance: back` entry, hence `.id('back')`.
        Stack({ alignContent: Alignment.Start }) {
          Text($r('app.string.account_page_manage_account'))
            .width('100%')
            .height(BAR_HEIGHT)
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)

          Row({ space: BACK_GLYPH_GAP }) {
            BackChevron()
            Text($r('app.string.account_page_account_header'))
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.jami'))
          }
          .id('back')
          .alignItems(VerticalAlign.Center)
          .constraintSize({ minHeight: BAR_HEIGHT })
          .onClick(() => {
            this.goBack();
          })
        }
        .width('100%')
        .constraintSize({ minHeight: BAR_HEIGHT })

        // Swift: the daemon gap surfaces on the screen that remains after the alert closes.
        if (this.showDaemonNotice) {
          Text($r('app.string.daemon_not_available'))
            .width('100%')
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .padding({
              start: LengthMetrics.resource($r('sys.float.padding_level10')),
              end: LengthMetrics.resource($r('sys.float.padding_level10')),
              bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
            })
        }

        // Swift `Section { three NavigationLinks }`.
        Column() {
          this.navigationRow($r('app.string.account_page_blocked_contacts'),
            'manage_account_blocked_contacts', () => {
              this.openBlockedContacts();
            })
          this.rowSeparator()
          this.navigationRow($r('app.string.account_page_encrypt_account'),
            'manage_account_encrypt_account', () => {
              this.openEncryptAccount();
            })
          this.rowSeparator()
          this.navigationRow($r('app.string.backup_account_title'),
            'manage_account_backup_account', () => {
              this.openBackupAccount();
            })
        }
        .groupedCard()
        .margin({ top: GROUPED_SECTION_GAP, bottom: GROUPED_SECTION_GAP })

        // Swift `Section { Button { HStack { Spacer; Text(removeAccount); Spacer } } }` —
        // its own card, the label centred by the two Spacers and in `Color.jamiFailure`.
        Row() {
          Blank()
          // iOS renders this row as ONE `Button` carrying BOTH the label and the tap
          // (capture remove_account.ui.json: Button[text='Remove account',
          // id=manage_account_remove_account, clickable]). Putting the label on a child of a
          // clickable Row split those across two nodes — and `removalAlertContent()`'s
          // headline is the SAME string, so a label lookup tied between the two and resolved
          // to the headline, reading a healthy control as untappable. Label + handler on one
          // node, spanning the row (layoutWeight collapses the Spacers), is the source shape.
          Text($r('app.string.global_remove_account'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor(JAMI_FAILURE)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .id('manage_account_remove_account')
            .onClick(() => {
              this.showRemovalConfirmation();
            })
          Blank()
        }
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: BAR_HEIGHT })
        .groupedRow()
        .groupedCard()
      }
      .width('100%')
      .height('100%')
      // `Form` sits on systemGroupedBackground, its cards inset 20 from both page edges
      // (capture S0231: the cards span [20..373] of 393).
      .padding({
        start: LengthMetrics.resource($r('sys.float.padding_level10')),
        end: LengthMetrics.resource($r('sys.float.padding_level10'))
      })
      .backgroundColor($r('sys.color.background_secondary'))

      // conditionalVariants[confirm_open] — the in-place confirmation over the form.
      if (this.isConfirmOpen) {
        CustomAlert() {
          this.removalAlertContent()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_manage_account')
  }
}
