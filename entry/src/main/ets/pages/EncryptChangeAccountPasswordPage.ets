/*
 * screen_encrypt_account — "Encrypt / Change Account Password", ported from
 *   Ring/Ring/Features/Settings/Me/EncryptAccountView.swift   (struct EncryptAccount)
 *   Ring/Ring/Features/Settings/Me/EncryptAccountVM.swift     (class EncryptAccountVM)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift       (PasswordFieldView)
 *
 * presentation: page. ManageAccountView reaches it with a NavigationLink, so it is an @Entry
 * page pushed from ManageAccountPage; Back is the platform affordance, composed here because
 * an @Entry router page draws no system chrome (controlInventory's `implicit: true /
 * affordance: back` entry, hence `.id('back')`).
 *
 * S3 — the real tree of `EncryptAccount.body`:
 *   ZStack(alignment: .top) {
 *     List {
 *       if model.hasPassword() {
 *         Section(header: explanationHeader, footer: errorFooter) { PasswordFieldView(current) }
 *         Section(footer: validationFooter)  { PasswordFieldView(new); PasswordFieldView(confirm) }
 *       } else {
 *         Section(header: explanationHeader, footer: validationFooter) { new; confirm }
 *       }
 *       if model.savingPasswordInProgress { ProgressView() } else { Button(change/create) }
 *     }
 *     if showToast, let message = model.successMessage { checkmark.circle.fill + message }
 *   }
 *
 * conditionalVariants — all four are real ArkUI conditionals here, never one flat layout:
 *   [has_password]      `hasPassword`        -> the current-password section is added
 *   [no_password]       `isNoPassword`       -> new + confirm only
 *   [validation_error]  `isValidationError`  -> validationFooter
 *   [success]           `isSuccess`          -> the checkmark.circle.fill toast
 *
 * bindingContract — [fields] <- `passwordDraft` (the VM's three @Published password fields,
 * carried here as `fields`, refreshed by the @Watch that ports Swift's three
 * `.onChange(of:) { model.validatePasswords() }` modifiers); [footer] <- `validationMessage`
 * (EncryptAccountVM.validationError). Nothing on this page is a literal from the capture.
 *
 * DAEMON GAP (Rule 11). Setting or changing the archive password is jami-daemon work:
 * `AccountsService.changePassword` reports `account.changePassword` unavailable and returns
 * false, exactly as the daemon-less service must. Submit keeps its place, runs the real
 * service call, and the screen says so — never a silent early return, never a fake success.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PasswordFieldView } from '../components/PasswordField';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { BackChevron } from '../components/BackButton';

/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/*
 * S5 — every number below is MEASURED off results/traversal-source/pages/EncryptAccount/
 * base.ui.json (a 393x852 capture) or copied verbatim from the Swift source. iOS's
 * InsetGroupedListStyle spells none of them in code, so the capture is the only record.
 *
 *   nav bar            [0,53][393,97]                 -> BAR_HEIGHT 44, already here
 *   explanation header text x 40, top ~113            -> LIST_TOP 16 + ROW_TEXT_INSET 20
 *   card (both fields) x 20..373                      -> CARD_INSET 20
 *   new-password cell  [20,190][373,234]              -> 44 high, PasswordFieldView's own 45
 *   field text x 40, eye right edge 351               -> ROW_TEXT_INSET 20 (10 of it the field's)
 *   divider at y 234, x 40 -> the card's right edge   -> Divider margin left ROW_TEXT_INSET
 *   submit button      [20,313][373,358]              -> SECTION_GAP 35 below the card, 45 high
 */
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** Swift's own `.cornerRadius(10)` on the submit button; the card measures the same. */
const CARD_RADIUS: number = 10;
/** The gap between two grouped sections (card bottom 278 -> button top 313). */
const SECTION_GAP: number = 35;
/** The list's top inset, above the first section header. */
const LIST_TOP: number = 16;
/** A grouped row's content inset inside its card (text at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/** PasswordFieldView carries 10 vp of that inset itself; the card supplies the other 10. */
const FIELD_INSET: number = 10;
/** The grouped list's hairline separator. */
const HAIRLINE: number = 0.5;
/** Capture: the submit button is [20,313][373,358] — 45 high. */
const SUBMIT_HEIGHT: number = 45;
/** The gap between a section header/footer and its card. */
const FOOTNOTE_GAP: number = 8;
/** Swift `Text(...).padding(.horizontal, 10).padding(.vertical, 12)` inside the submit Button. */
const BUTTON_PAD_H: number = 10;
const BUTTON_PAD_V: number = 12;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';
/** Swift `UIColor(hex: 0x00b20b)` — `Color.jamiSuccess`, hardcoded the same way. */
const SUCCESS_COLOR: string = '#00B20B';
/** Swift's toast: `.padding(.horizontal, 16).padding(.vertical, 10).cornerRadius(20)`. */
const TOAST_PAD_H: number = 16;
const TOAST_PAD_V: number = 10;
const TOAST_RADIUS: number = 20;
const TOAST_SHADOW: number = 4;
const TOAST_GAP: number = 6;
/** ManageAccountView is what pushed this page — the coordinator root a cold deep link lacks. */
const MANAGE_ACCOUNT_PAGE: string = 'pages/ManageAccountPage';
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/** UINavigationBar's spacing between the back item and a title it had to slide aside. */
const TITLE_GAP: number = 8;
/** SwiftUI `Color.gray` (systemGray) — the iPhone's explanation grey, ~#8C8E91 measured (T-1601). */
const EXPLANATION_GRAY: string = '#8E8E93';
/** Swift `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` after changePassword(). */
const SAVE_SETTLE_MS: number = 100;
/** Swift `DispatchQueue.main.asyncAfter(deadline: .now() + 2)` — the toast's dwell. */
const TOAST_MS: number = 2000;

/**
 * bindingContract[fields] — `passwordDraft`, the three @Published password fields of
 * EncryptAccountVM held as one value. The fields themselves stay individual @State strings
 * because PasswordFieldView takes the password as a `@Link` (Swift `@Binding var text`); this
 * is the draft they add up to, and it is what validatePasswords() reads.
 */
class PasswordDraft {
  currentPassword: string = '';
  newPassword: string = '';
  confirmPassword: string = '';

  constructor(currentPassword: string = '', newPassword: string = '',
    confirmPassword: string = '') {
    this.currentPassword = currentPassword;
    this.newPassword = newPassword;
    this.confirmPassword = confirmPassword;
  }
}

@Entry
@Component
struct EncryptChangeAccountPasswordPage {
  /** bindingContract[fields] <- passwordDraft (EncryptAccountVM's password fields). */
  @State fields: PasswordDraft = new PasswordDraft();
  /** bindingContract[footer] <- validationMessage — Swift `@Published var validationError`. */
  @State footer: string = '';
  /** conditionalVariants[has_password]: Swift `model.hasPassword()`. */
  @State hasPassword: boolean = false;
  /** conditionalVariants[no_password]: the `else` half of the same test. */
  @State isNoPassword: boolean = true;
  /** conditionalVariants[validation_error]: validatePasswords() produced a message. */
  @State isValidationError: boolean = false;
  /** conditionalVariants[success]: Swift `showToast, let message = model.successMessage`. */
  @State isSuccess: boolean = false;
  /** Swift `@Published var savingPasswordInProgress`. */
  @State isLoading: boolean = false;
  /** Swift `@Published var encryptError` — the failure the change reported. */
  @State errorText: string = '';
  /** The daemon gap Submit hits, stated in place rather than as a toast. */
  @State private showDaemonNotice: boolean = false;
  /** Swift `@Published var successMessage`. */
  @State private successMessage: string = '';
  /** Swift `@Published var buttonEnabled` — `updateButtonEnableState()` keeps it. */
  @State private buttonEnabled: boolean = false;

  /** Swift `@Published var currentPassword` — PasswordFieldView's `@Binding var text`. */
  @State @Watch('onDraftChanged') private currentPassword: string = '';
  /** Swift `@Published var newPassword`. */
  @State @Watch('onDraftChanged') private newPassword: string = '';
  /** Swift `@Published var confirmPassword`. */
  @State @Watch('onDraftChanged') private confirmPassword: string = '';

  /**
   * AppStorage['currentAccountId'] — the account whose archive this page encrypts. svc_accounts
   * rewrites it whenever the current account changes, and `hasPassword()` is derived FROM that
   * account, so the branch selector is re-derived rather than left on what the first render saw.
   */
  @Watch('onAccountChanged') @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  private saveTimer: number = -1;
  private toastTimer: number = -1;
  /** Measured nav bar, back item and title widths — the title is placed from them. */
  @State private barWidth: number = 0;
  @State private backWidth: number = 0;
  @State private titleWidth: number = 0;
  /** The back item's width while it still shows the origin's title, kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift `EncryptAccountVM.init` — hasPassword() decides which sections exist, and
    // updateButtonEnableState() runs before anything is typed.
    this.refreshHasPassword();
    this.updateButtonEnableState();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /**
   * The page is pushed, so it is re-shown after a Back from anywhere above it; Swift rebuilds
   * EncryptAccountVM with the account each time `EncryptAccount` is constructed.
   */
  onPageShow(): void {
    this.refreshHasPassword();
    this.updateButtonEnableState();
  }

  /** @Watch on currentAccountId — svc_accounts moved the current account. */
  private onAccountChanged(_propName: string): void {
    this.refreshHasPassword();
    this.updateButtonEnableState();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription and both timers go whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      if (this.saveTimer !== -1) {
        clearTimeout(this.saveTimer);
        this.saveTimer = -1;
      }
      if (this.toastTimer !== -1) {
        clearTimeout(this.toastTimer);
        this.toastTimer = -1;
      }
      this.isLoading = false;
    }
  }

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** The gap THIS screen's own control raises — `changePassword` on the daemon half. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === 'account.changePassword') {
        this.showDaemonNotice = true;
      }
    }));
  }

  /**
   * The account this page encrypts — Swift `EncryptAccount(account:accountService:)`, which is
   * handed the account ManageAccountView is already showing. AppStorage carries its id; when
   * that is empty or stale, svc_accounts' own current account is the same one ManageAccount
   * displays, so the page never silently falls back to "no account".
   */
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

  /** Swift `func hasPassword() -> Bool` — `AccountModelHelper(withAccount:).hasPassword`. */
  private refreshHasPassword(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      this.hasPassword = false;
      this.isNoPassword = true;
      return;
    }
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    const helper: AccountModelHelper = new AccountModelHelper(
      details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
    this.hasPassword = helper.hasPassword;
    this.isNoPassword = !this.hasPassword;
  }

  /**
   * Swift's three `.onChange(of: model.<field>) { _ in model.validatePasswords() }` modifiers.
   * The draft is rebuilt first, so `fields` is always the value validatePasswords() reads.
   */
  private onDraftChanged(_propName: string): void {
    this.fields = new PasswordDraft(this.currentPassword, this.newPassword,
      this.confirmPassword);
    this.validatePasswords();
  }

  /** Swift `func validatePasswords()`, line for line. */
  private validatePasswords(): void {
    this.successMessage = '';
    this.isSuccess = false;
    this.errorText = '';
    this.showDaemonNotice = false;
    if (this.fields.newPassword.length === 0 || this.fields.confirmPassword.length === 0) {
      this.footer = '';
    } else if (this.fields.newPassword !== this.fields.confirmPassword) {
      this.footer = this.resolve('account_page_passwords_do_not_match');
    } else {
      this.footer = '';
    }
    this.isValidationError = this.footer.length > 0;
    this.updateButtonEnableState();
  }

  /** Swift `private func updateButtonEnableState()`. */
  private updateButtonEnableState(): void {
    const currentPasswordValid: boolean =
      !this.hasPassword || this.fields.currentPassword.length > 0;
    const newPasswordValid: boolean = this.fields.newPassword.length > 0;
    const confirmPasswordValid: boolean = this.fields.confirmPassword.length > 0;
    this.buttonEnabled = !this.isValidationError && newPasswordValid && confirmPasswordValid
      && currentPasswordValid;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * Swift the submit Button: `model.savingPasswordInProgress = true; model.changePassword();
   * hideKeyboard()`, then EncryptAccountVM.changePassword's own body.
   *
   * DAEMON GAP: `AccountsService.changePassword` is the daemon's `account.changePassword`. It
   * reports the gap and answers false, so this lands in the failure half — which is the honest
   * outcome and is what the screen shows.
   */
  private submit(): void {
    // The contracted control is addressable on the row and on the button, so one gesture can
    // reach this twice; the second is a no-op while the first is still settling.
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const successMessage: string = this.hasPassword
      ? this.resolve('account_page_password_updated')
      : this.resolve('account_page_password_created');
    const account: AccountModel | null = this.currentAccount();
    const accountId: string = account === null ? this.currentAccountId : account.id;
    const success: boolean = accounts.changePassword(accountId,
      this.fields.currentPassword, this.fields.newPassword);
    // The service reports the gap synchronously, so the subscription has already fired; the
    // flag is kept here because clearing the fields below re-runs validatePasswords(), which
    // resets every message on the screen.
    const gap: boolean = this.showDaemonNotice;
    // Swift clears all three fields immediately, before the 0.1 s settle.
    this.newPassword = '';
    this.confirmPassword = '';
    this.currentPassword = '';
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.isLoading = false;
      // Swift: `encryptError = success ? nil : L10n.AccountPage.changePasswordError`.
      this.errorText = success ? '' : this.resolve('account_page_change_password_error');
      this.showDaemonNotice = gap;
      this.successMessage = success ? successMessage : '';
      this.isSuccess = success;
      if (success) {
        this.showToastForAWhile();
      }
    }, SAVE_SETTLE_MS);
  }

  /** Swift `.onChange(of: model.successMessage)` — show, then hide two seconds later. */
  private showToastForAWhile(): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.toastTimer = -1;
      this.isSuccess = false;
    }, TOAST_MS);
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: MANAGE_ACCOUNT_PAGE }).catch((error: Error): void => {
        console.error('EncryptChangeAccountPasswordPage: replaceUrl ' + MANAGE_ACCOUNT_PAGE
          + ' failed: ' + error.message);
      });
      return;
    }
    router.back();
  }

  /** A localized string resolved to plain text, for the validation and failure slots. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * UINavigationBar centres the inline title, and slides it right of the back item when centred
   * would run under it (T-1592: "Manage account" is wide enough to collide on a narrow screen).
   */
  private titleStart(): number {
    return Math.max((this.barWidth - this.titleWidth) / 2, this.backWidth + TITLE_GAP);
  }

  /**
   * UINavigationBar swaps the origin's title for the generic "Back" when it would not fit left
   * of the centred title — the iPhone does at 390 pt (T-1601).
   */
  private isBackShortened(): boolean {
    return this.fullBackWidth > 0 &&
      this.fullBackWidth + TITLE_GAP > (this.barWidth - this.titleWidth) / 2;
  }

  /**
   * Swift `.navigationTitle(L10n.AccountPage.encryptAccount)
   * .navigationBarTitleDisplayMode(.inline)` plus iOS's own leading back item, labelled with
   * the ORIGIN page's title ("Manage account").
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // Capture: the title is centred and BOLD at [158,65][235,85] — iOS's inline nav title.
      Row() {
        Text($r('app.string.account_page_encrypt_account'))
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
      .padding({ left: this.titleStart(), right: TITLE_GAP })

      // Capture: chevron + label in the Jami navy (#00345F = app.color.jami), chevron at
      // x ~11, label at x ~30. The padding is inside the Row so the tap target still
      // reaches the screen edge, as the source's own back item does ([0,53][103,97]).
      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
          : $r('app.string.account_page_manage_account'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ left: FOOTNOTE_GAP })
      .onAreaChange((_old: Area, area: Area) => {
        this.backWidth = Number(area.width);
        if (!this.isBackShortened()) {
          this.fullBackWidth = this.backWidth;
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

  /** Swift `var explanationHeader` — the section header both branches carry. */
  @Builder
  private explanationHeader() {
    // Swift `.font(.footnote).foregroundColor(.gray).textCase(nil)`. Capture: grey, x 40
    // (the card's 20 plus the grouped header's own 20), four lines at an 18 pt line height.
    Text($r('app.string.account_page_password_explanation'))
      .width('100%')
      .fontSize($r('sys.float.Body_S'))
      .fontColor(EXPLANATION_GRAY)
      .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
      .margin({ bottom: FOOTNOTE_GAP })
  }

  /**
   * Swift `@ViewBuilder var errorFooter` — `if let error = model.encryptError`. The daemon
   * notice rides in the same slot: the gap IS this screen's encryption failure.
   */
  @Builder
  private errorFooter() {
    // Swift `.foregroundColor(Color.jamiFailure)` on a grouped section footer: footnote
    // size, at the same x 40 inset as the header. Both stay in the page body where S4 put
    // them — this styles them, it does not move them.
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

  /** Swift `@ViewBuilder var validationFooter` — `if let error = model.validationError`. */
  @Builder
  private validationFooter() {
    // conditionalVariants[validation_error] — bound to the validation message itself.
    if (this.isValidationError) {
      Text(this.footer)
        .width('100%')
        .fontSize($r('sys.float.Body_S'))
        .fontColor(FAILURE_COLOR)
        .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
        .margin({ top: FOOTNOTE_GAP })
    }
  }

  build() {
    Column() {
      this.navigationBar()

      // Swift `ZStack(alignment: .top) { List { ... }; if showToast { toast } }`.
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column() {
            // conditionalVariants[has_password] / [no_password] — the two exclusive section
            // layouts of `if model.hasPassword() { ... } else { ... }`. Never flattened: the
            // current-password field exists in one of them and in neither other state.
            if (this.hasPassword) {
              // Section(header: explanationHeader, footer: errorFooter) — its own card.
              this.explanationHeader()
              Column() {
                Column() {
                  PasswordFieldView({
                    text: $currentPassword,
                    placeholder: $r('app.string.account_page_current_password_placeholder'),
                    identifier: 'encrypt_account_current_password',
                    // The grey pill PasswordFieldView draws for the white pages that use it
                    // is the card's own white here: in the capture the field is flush inside
                    // the card with nothing behind it. Its `pillBackground` exists for
                    // exactly this, as the Swift call site's `backgroundColor` does.
                    pillBackground: $r('sys.color.comp_background_list_card')
                  })
                }
                .width('100%')
                .padding({ left: FIELD_INSET, right: FIELD_INSET })
              }
              .width('100%')
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)
              this.errorFooter()

              // Section(footer: validationFooter) { new; confirm } — the second card, the
              // two fields split by the grouped list's hairline.
              Column() {
                Column() {
                  PasswordFieldView({
                    text: $newPassword,
                    placeholder: $r('app.string.account_page_new_password_placeholder'),
                    identifier: 'encrypt_account_new_password',
                    pillBackground: $r('sys.color.comp_background_list_card')
                  })
                }
                .width('100%')
                .padding({ left: FIELD_INSET, right: FIELD_INSET })
                Divider()
                  .strokeWidth(HAIRLINE)
                  // S6: measured #C6C6C8 at y 234 in base.ui.json's hairline row — iOS
                  // `.separator`. `comp_divider` renders ~#F2F2F2 over the white card, which
                  // reads as no rule at all; the legacy list-separator token is the one the
                  // iOS-token table maps `.separator` to (#33182431 light).
                  .color($r('sys.color.ohos_id_color_list_separator'))
                  .margin({ left: ROW_TEXT_INSET })
                Column() {
                  PasswordFieldView({
                    text: $confirmPassword,
                    placeholder: $r('app.string.account_page_new_password_confirm_placeholder'),
                    identifier: 'encrypt_account_confirm_password',
                    pillBackground: $r('sys.color.comp_background_list_card')
                  })
                }
                .width('100%')
                .padding({ left: FIELD_INSET, right: FIELD_INSET })
              }
              .width('100%')
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)
              .margin({ top: SECTION_GAP })
              this.validationFooter()
            } else if (this.isNoPassword) {
              // Section(header: explanationHeader, footer: validationFooter) { new; confirm }.
              // conditionalVariants[no_password] reads its OWN selector rather than riding on a
              // bare `else`: the two are exact complements (`isNoPassword = !hasPassword`), so
              // the rendering is unchanged and the branch is anchored on the field the plan
              // names.
              this.explanationHeader()
              // Capture base.ui.json: card x 20..373, the two 44 pt cells at y 190..234 and
              // 234..278, hairline between them starting at x 40.
              Column() {
                Column() {
                  PasswordFieldView({
                    text: $newPassword,
                    placeholder: $r('app.string.account_page_new_password_placeholder'),
                    identifier: 'encrypt_account_new_password',
                    pillBackground: $r('sys.color.comp_background_list_card')
                  })
                }
                .width('100%')
                .padding({ left: FIELD_INSET, right: FIELD_INSET })
                Divider()
                  .strokeWidth(HAIRLINE)
                  // S6: measured #C6C6C8 at y 234 in base.ui.json's hairline row — iOS
                  // `.separator`. `comp_divider` renders ~#F2F2F2 over the white card, which
                  // reads as no rule at all; the legacy list-separator token is the one the
                  // iOS-token table maps `.separator` to (#33182431 light).
                  .color($r('sys.color.ohos_id_color_list_separator'))
                  .margin({ left: ROW_TEXT_INSET })
                Column() {
                  PasswordFieldView({
                    text: $confirmPassword,
                    placeholder: $r('app.string.account_page_new_password_confirm_placeholder'),
                    identifier: 'encrypt_account_confirm_password',
                    pillBackground: $r('sys.color.comp_background_list_card')
                  })
                }
                .width('100%')
                .padding({ left: FIELD_INSET, right: FIELD_INSET })
              }
              .width('100%')
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)
              this.validationFooter()
              // The source gives this branch no errorFooter slot, but the daemon gap must be
              // visible wherever Submit can be pressed, so the failure is stated here too.
              this.errorFooter()
            }

            // Swift `if model.savingPasswordInProgress { ProgressView() } else { Button }` —
            // exclusive, the spinner REPLACES the button while the save is in flight.
            if (this.isLoading) {
              Row() {
                LoadingProgress()
                  .width(BAR_HEIGHT)
                  .height(BAR_HEIGHT)
                  .color($r('sys.color.font_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ top: SECTION_GAP })
            } else {
              // Swift, verbatim: `.foregroundColor(Color(UIColor.label))
              // .padding(.horizontal, 10).padding(.vertical, 12).frame(maxWidth: .infinity)
              // .background(Color.jamiTertiaryControl).cornerRadius(10)`, with
              // `.listRowInsets(0)` so it spans the full list width. Capture:
              // [20,313][373,358] = 45 high (12 + 21 + 12), pale blue, label grey from the
              // disabled dimming.
              Button(this.hasPassword
                ? $r('app.string.account_page_change_password')
                : $r('app.string.account_page_create_password'))
                .type(ButtonType.Normal)
                .width('100%')
                .constraintSize({ minHeight: SUBMIT_HEIGHT })
                .padding({
                  left: BUTTON_PAD_H,
                  right: BUTTON_PAD_H,
                  top: BUTTON_PAD_V,
                  bottom: BUTTON_PAD_V
                })
                .backgroundColor($r('app.color.jami_tertiary_control'))
                .fontColor($r('app.color.label'))
                .fontSize($r('sys.float.Body_L'))
                .borderRadius(CARD_RADIUS)
                .margin({ top: SECTION_GAP })
                .id('encrypt_account_submit')
                // Swift `.disabled(!model.buttonEnabled).opacity(model.buttonEnabled ? 1 : 0.5)`
                // — the real condition, kept by updateButtonEnableState() on every keystroke. A
                // disabled ArkUI Button already dims itself (interactive_disable, 0.4); a second
                // `.opacity(0.5)` multiplied that to 0.2 and the button all but vanished (T-1592).
                .enabled(this.buttonEnabled)
                .onClick(() => {
                  this.submit();
                })
            }
          }
          .width('100%')
          .padding({
            left: CARD_INSET,
            right: CARD_INSET,
            top: LIST_TOP,
            bottom: LIST_TOP
          })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)

        // conditionalVariants[success] — Swift's success toast, `checkmark.circle.fill` and
        // the VM's own message, over the list.
        if (this.isSuccess) {
          // Swift, verbatim: `.font(.subheadline).foregroundColor(.white)
          // .padding(.horizontal, 16).padding(.vertical, 10)
          // .background(Color.jamiSuccess).cornerRadius(20).shadow(radius: 4)
          // .padding(.top, 8)`.
          Row({ space: TOAST_GAP }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize($r('sys.float.Body_M'))
              .fontColor([$r('sys.color.font_on_primary')])
            Text(this.successMessage)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_on_primary'))
          }
          .alignItems(VerticalAlign.Center)
          .padding({
            left: TOAST_PAD_H,
            right: TOAST_PAD_H,
            top: TOAST_PAD_V,
            bottom: TOAST_PAD_V
          })
          .backgroundColor(SUCCESS_COLOR)
          .borderRadius(TOAST_RADIUS)
          .shadow({ radius: TOAST_SHADOW, color: $r('app.color.shadow_color') })
          .margin({ top: FOOTNOTE_GAP })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the capture's page grey (#f1f3f5), the colour the
    // white cards above sit on.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_encrypt_account')
  }
}
