/*
 * screen_name_registration — "Register a Username", ported from
 *   Ring/Ring/Features/Settings/Me/NameRegistrationView.swift
 *   Ring/Ring/Features/Settings/Me/NameRegistrationVM.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (CustomAlert / PasswordFieldView)
 *
 * presentation: popup, hostScreen: screen_account_summary. NameRegistrationView wraps its body
 * in CustomAlert and AccountSummaryView renders it in place behind `showAccountRegistration`,
 * so it is a @CustomDialog mounted by AccountSummarySettingsRootPage — NOT a routed page and
 * NOT in main_pages.json. The dialog itself IS the CustomAlert (scrim + card), which is why
 * comp_custom_alert is not instantiated a second time inside it.
 *
 * S3 builds the REAL component tree of `createNameRegistrationView()`, unstyled — the SOURCE's
 * four-way switch on `NameRegistrationVM.state`, not one flattened body:
 *
 *   .initial -> initialView()   .started -> loadingView()
 *   .error   -> errorView()     .success -> EmptyView() (+ the alert dismisses itself)
 *
 *   initialView: VStack { Text(registerAUsername).headline
 *                         Text(registerNameExplanation).subheadline
 *                         VStack { TextField(usernamePlaceholder, $model.name)
 *                                  if isVerifying { ProgressView }
 *                                  else if !message.isEmpty { Text(message) } }
 *                         if model.hasPassword() { PasswordFieldView(...) }
 *                         HStack { Cancel; Spacer; Register.disabled(!registerButtonAvailable) } }
 *   loadingView: VStack { Text(usernameRegistering).headline; ProgressView }
 *   errorView:   VStack { Text(title).headline; Text(message); HStack { Spacer; OK } }
 *
 * conditionalVariants, all four as real conditions in the render body:
 *   [name_available] the lookup says the name is free -> Register is enabled
 *   [name_taken]     the lookup says it is taken      -> the unavailable message
 *   [registering]    registration in flight           -> loadingView
 *   [result_state]   a result is shown                -> errorView + its OK
 *
 * bindingContract: the username field is bound to `usernameDraft` (Swift `model.name`) and the
 * status line to svc_name (Swift `model.usernameValidationState`) — every keystroke runs
 * `NameService.lookupName`, exactly as the VM's `didSet` does. Nothing is transcribed from the
 * capture.
 *
 * DAEMON GAP: both the lookup and the registration go through the jami daemon. NameService
 * resolves each to its ERROR response, so the field keeps the typed name, the status line
 * states the failure and the alert lands in its error branch — never a silent no-op and never
 * a disabled control.
 *
 * S5/S6 style this tree against S0277, S0278, S0279.
 */
import { PasswordFieldView } from '../components/PasswordField';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { UsernameValidationStatus } from '../common/NameService';

/* ── S5 metrics ───────────────────────────────────────────────────────────────────────────
 * The overlay IS the source's `CustomAlert`: a dimmed page with a rounded
 * secondarySystemBackground card inset from both edges. The host mounts it with
 * `customStyle: true`, so the card is drawn HERE (comp_custom_alert is the same style, kept
 * identical so the app's two in-app alerts match). Every value is either the design token for
 * the iOS role (ios-to-harmonyos-design-tokens.md) or a number the Swift itself hardcodes.
 */
/** Swift `let padding: CGFloat = 20` — NameRegistrationView's own VStack spacing. */
const ALERT_STACK_GAP: number = 20;
/** Swift `CustomAlert`: `.shadow(radius: 10)` on the card. */
const ALERT_SHADOW_RADIUS: number = 10;
/** Swift `AlertFieldStyle`: `.cornerRadius(8)` on a field inside an alert. */
const ALERT_FIELD_RADIUS: number = 8;
/** Swift `AlertFieldStyle`: `.padding(.vertical, 12)` (the horizontal one is the 16 token). */
const ALERT_FIELD_V_PADDING: number = 12;
/** Swift `loadingView()`: `ProgressView().scaleEffect(2)` — twice the stock 24 vp spinner. */
const ALERT_SPINNER_SIZE: number = 48;
/** Swift `loadingView()`: `.padding(.bottom, 30)` under the spinner. */
const ALERT_SPINNER_BOTTOM: number = 30;
/**
 * S6, measured on the capture's own tree (S0279, 393pt): the field ends at y=485 and the
 * validation line starts at y=490 — the status sits TIGHT under the field, not a full
 * `padding` below it, and it is CENTRED in the card ([123..269] of the [32..361] content
 * box), unlike the field it annotates.
 */
const ALERT_STATUS_GAP: number = 5;
/** Swift `UIColor.jamiSuccess` / `UIColor.jamiFailure` — app constants, hardcoded hexes. */
const VALIDATION_OK_COLOR: string = '#00B20B';
const VALIDATION_FAIL_COLOR: string = '#F00000';

/** Swift `enum RegistrationState` (NameRegistrationVM.swift:53). */
enum RegistrationState {
  INITIAL = 'INITIAL',
  STARTED = 'STARTED',
  SUCCESS = 'SUCCESS',
  ERROR = 'ERROR'
}

/**
 * Swift `AlertFieldStyle` (UtilitiesViews.swift:159) — the look every field inside a
 * CustomAlert gets: `.padding(.horizontal).padding(.vertical, 12)
 * .background(Color(UIColor.systemBackground)).cornerRadius(8)`.
 */
@Styles function alertFieldStyle() {
  .width('100%')
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      top: ALERT_FIELD_V_PADDING,
      bottom: ALERT_FIELD_V_PADDING
    })
    .backgroundColor($r('sys.color.background_primary'))
    .borderRadius(ALERT_FIELD_RADIUS)
}

@CustomDialog
export struct NameRegistrationOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /**
   * Swift `@Binding var isPresented` (AccountSummaryView's `showAccountRegistration`) — the
   * HOST owns it, exactly as the SwiftUI binding does; Cancel and the result view's OK write
   * through it so the host's own branch closes with the dialog.
   */
  @Link isPresented: boolean;

  /** Swift `@Published var name` — bound to the field; every change runs a lookup. */
  @State usernameField: string = '';
  /** Swift `@Published var password` — filled only when the account has one; its didSet
   * re-validates the Register button, which is what @Watch is here. */
  @State @Watch('onPasswordChanged') private password: string = '';
  /** Swift `@Published var state: RegistrationState` — bindingContract[status] -> svc_name. */
  @State status: RegistrationState = RegistrationState.INITIAL;
  /** Swift `@Published var usernameValidationState` — svc_name's lookup verdict. */
  @State private validation: UsernameValidationStatus = UsernameValidationStatus.EMPTY;
  /** Swift `usernameValidationState.message` — the line under the field. */
  @State private validationMessage: Resource | null = null;
  /** Swift `@Published var registerButtonAvailable`. */
  @State private registerButtonAvailable: boolean = false;
  /** Swift `model.hasPassword()` — AccountModelHelper(withAccount:).hasPassword. */
  @State private hasPassword: boolean = false;
  /** Swift `errorView(title:message:)`'s two arguments. */
  @State private errorTitle: Resource = $r('app.string.account_page_username_registration_failed_title');
  @State errorText: Resource = $r('app.string.account_page_username_registration_failed');

  /** conditionalVariants[name_available]: the lookup says the name is free. */
  @State isNameAvailable: boolean = false;
  /** conditionalVariants[name_taken]: the lookup says the name is taken. */
  @State isNameTaken: boolean = false;
  /** conditionalVariants[registering]: registration in flight. */
  @State isRegistering: boolean = false;
  /** conditionalVariants[result_state]: a success or failure result is shown. */
  @State isResultState: boolean = false;
  /** Swift `usernameValidationState.isVerifying` — the spinner under the field. */
  @State private isVerifying: boolean = false;
  /** True while svc_name is in flight — the lookup as well as the registration. */
  @State isLoading: boolean = false;

  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()` — the name-lookup subscription. */
  private bag: DisposeBag = new DisposeBag();

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    this.readAccount();
    this.subscribeForNameLookup();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isVerifying = false;
    }
  }

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** Swift `NameRegistrationVM.account` — here the account id in AppStorage. */
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

  /** Swift `func hasPassword()` — `AccountModelHelper(withAccount: account).hasPassword`. */
  private readAccount(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      return;
    }
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    const helper: AccountModelHelper = new AccountModelHelper(
      details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
    this.hasPassword = helper.hasPassword;
  }

  /** Swift `subscribeForNameLookup()` — NameService.usernameValidationStatus. */
  private subscribeForNameLookup(): void {
    this.bag.add(ServiceRegistry.shared().nameService.usernameValidationStatus.subscribe(
      (incoming: UsernameValidationStatus): void => {
        this.applyValidation(incoming);
      }));
  }

  /** Swift: the `switch status` inside that subscription, plus `valideateRegisterButtonState()`. */
  private applyValidation(incoming: UsernameValidationStatus): void {
    this.validation = incoming;
    this.isVerifying = incoming === UsernameValidationStatus.LOOKING_UP;
    this.isLoading = this.isVerifying || this.isRegistering;
    this.isNameAvailable = incoming === UsernameValidationStatus.VALID;
    this.isNameTaken = incoming === UsernameValidationStatus.ALREADY_TAKEN;
    if (incoming === UsernameValidationStatus.LOOKING_UP) {
      this.validationMessage = $r('app.string.create_account_looking_for_username_availability');
    } else if (incoming === UsernameValidationStatus.INVALID) {
      this.validationMessage = $r('app.string.create_account_invalid_username');
    } else if (incoming === UsernameValidationStatus.ALREADY_TAKEN) {
      this.validationMessage = $r('app.string.create_account_username_already_taken');
    } else if (incoming === UsernameValidationStatus.VALID) {
      this.validationMessage = $r('app.string.create_account_username_valid');
    } else {
      this.validationMessage = null;
    }
    this.validateRegisterButtonState();
  }

  /** Swift `valideateRegisterButtonState()` (the source's own spelling of the guard). */
  private validateRegisterButtonState(): void {
    if (!this.isNameAvailable) {
      this.registerButtonAvailable = false;
      return;
    }
    this.registerButtonAvailable = this.hasPassword ? this.password.length > 0 : true;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /** Swift `@Published var name`'s didSet — a non-empty change runs a name-server lookup. */
  private onUsernameChanged(value: string): void {
    const previous: string = this.usernameField;
    this.usernameField = value;
    if (value.length === 0 || value === previous) {
      return;
    }
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      return;
    }
    ServiceRegistry.shared().nameService.lookupName(account.id, '', value);
  }

  /** Swift `@Published var password`'s didSet — re-validates the Register button. */
  private onPasswordChanged(_propName: string): void {
    this.validateRegisterButtonState();
  }

  /** Swift `registerUsername()` — NameService.registerNameObservable for the account. */
  private register(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      return;
    }
    this.status = RegistrationState.STARTED;
    this.isRegistering = true;
    this.isLoading = true;
    this.isResultState = false;
    this.bag.add(ServiceRegistry.shared().nameService
      .registerNameObservable(account.id, this.password, this.usernameField)
      .subscribe((registered: boolean): void => {
        this.handleRegistrationResult(registered);
      }));
  }

  /** Swift `handleRegistrationResult(registered:)`. */
  private handleRegistrationResult(registered: boolean): void {
    this.isRegistering = false;
    this.isLoading = false;
    if (registered) {
      // Swift: `.success` + `nameRegisteredCb()`, and the view's `.onChange(of: model.state)`
      // closes the alert — the host's `cancel` callback re-resolves the account's name.
      this.status = RegistrationState.SUCCESS;
      this.isResultState = false;
      this.dismiss();
      return;
    }
    this.status = RegistrationState.ERROR;
    this.errorTitle = $r('app.string.account_page_username_registration_failed_title');
    this.errorText = $r('app.string.account_page_username_registration_failed');
    this.isResultState = true;
  }

  /** Swift `showAccountRegistration = false` behind Cancel and behind the result view's OK. */
  private dismiss(): void {
    // Swift `showAccountRegistration = false` — the HOST's flag, written through the binding
    // so the host's own [registration_overlay] branch closes with the dialog.
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /* ── render ───────────────────────────────────────────────────────────────────────────── */
  /** Swift `initialView()`. */
  @Builder
  initialView() {
    // Swift `VStack(spacing: padding)` with `padding = 20`.
    Column({ space: ALERT_STACK_GAP }) {
      // Swift `.font(.headline)`.
      Text($r('app.string.global_register_a_username'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      // Swift `.font(.subheadline).multilineTextAlignment(.center)`.
      Text($r('app.string.account_page_register_name_explanation'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)

      Column({ space: ALERT_STATUS_GAP }) {
        // bindingContract[username field] -> usernameDraft (Swift `$model.name`).
        TextInput({
          placeholder: $r('app.string.account_page_username_placeholder'),
          text: this.usernameField
        })
          .id('name_registration_username')
          .alertFieldStyle()
          // Swift TextField's default prompt colour, `placeholderText`.
          .placeholderColor($r('app.color.placeholder_text'))
          .onChange((value: string) => {
            this.onUsernameChanged(value);
          })

        // Swift: `if isVerifying { ProgressView() } else if !message.isEmpty { Text(message) }`.
        // bindingContract[status] -> svc_name. The one `Text(message)` is split by the lookup
        // verdict so conditionalVariants[name_available] / [name_taken] are real branches —
        // each renders the same string the Swift `message` resolves to for that status.
        if (this.isVerifying) {
          LoadingProgress()
            .width(ALERT_SPINNER_SIZE / 2)
            .height(ALERT_SPINNER_SIZE / 2)
            .color($r('sys.color.font_secondary'))
        } else if (this.isNameAvailable) {
          // Swift `usernameValidationState.textColor`: `.available` -> jamiSuccess.
          Text($r('app.string.create_account_username_valid'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor(VALIDATION_OK_COLOR)
        } else if (this.isNameTaken) {
          // `.unavailable` -> jamiFailure.
          Text($r('app.string.create_account_username_already_taken'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor(VALIDATION_FAIL_COLOR)
        } else if (this.validationMessage !== null) {
          // `.invalid` -> jamiFailure; `.unknown` / `.lookingForAvailability` -> `.clear`,
          // which is what the transparent branch is.
          Text(this.validationMessage)
            .fontSize($r('sys.float.Body_S'))
            .fontColor(this.validation === UsernameValidationStatus.INVALID
              ? VALIDATION_FAIL_COLOR
              : Color.Transparent)
        }
      }
      .width('100%')
      // S6: the field fills the card (`.width('100%')` above) and the status line under it is
      // centred — capture S0279 puts "Username already taken" at [123..269] of [32..361].
      .alignItems(HorizontalAlign.Center)

      // Swift `if model.hasPassword() { PasswordFieldView(...) }` — comp_password_field.
      if (this.hasPassword) {
        PasswordFieldView({
          text: $password,
          placeholder: $r('app.string.account_page_password_placeholder'),
          identifier: 'name_registration_password'
        })
      }

      Row() {
        // Swift `.foregroundColor(Color(UIColor.label))`.
        Text($r('app.string.global_cancel'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .id('name_registration_cancel')
          .onClick(() => {
            this.dismiss();
          })
        Blank()
        // conditionalVariants[name_available] — the SOURCE's own guard,
        // `.disabled(!model.registerButtonAvailable)`, never an invented one, and the
        // colour the source pairs with it: secondaryLabel while unavailable, else .jami.
        Text($r('app.string.account_page_username_register_action'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor(this.registerButtonAvailable
            ? $r('app.color.jami')
            : $r('app.color.secondary_label'))
          .id('name_registration_register')
          .enabled(this.registerButtonAvailable)
          .onClick(() => {
            this.register();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /** Swift `loadingView()` (conditionalVariants[registering]). */
  @Builder
  loadingView() {
    // Swift `VStack(spacing: padding) { Text.headline.padding(); ProgressView.scaleEffect(2)
    //   .padding(.bottom, 30) }.padding()`.
    Column({ space: ALERT_STACK_GAP }) {
      Text($r('app.string.account_page_username_registering'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      LoadingProgress()
        .width(ALERT_SPINNER_SIZE)
        .height(ALERT_SPINNER_SIZE)
        .color($r('app.color.jami'))
        .margin({ bottom: ALERT_SPINNER_BOTTOM })
    }
    .width('100%')
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
  }

  /** Swift `errorView(title:message:)` (conditionalVariants[result_state]). */
  @Builder
  errorView() {
    // Swift `VStack(spacing: padding) { Text(title).headline; Text(message).centered;
    //   HStack { Spacer; OK } }`.
    Column({ space: ALERT_STACK_GAP }) {
      Text(this.errorTitle)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      Text(this.errorText)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
      Row() {
        Blank()
        // Swift `Text(L10n.Global.ok).foregroundColor(.jami).padding(.horizontal)`.
        Text($r('app.string.global_ok'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .padding({
            left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
          })
          .id('name_registration_ok')
          .onClick(() => {
            this.dismiss();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  build() {
    // Swift `createNameRegistrationView()` — the switch over `model.state`, branch for branch.
    // `.success` renders EmptyView while the alert dismisses itself, so it has no branch here
    // beyond falling through to nothing.
    Column() {
      if (this.isRegistering) {
        this.loadingView()
      } else if (this.isResultState) {
        this.errorView()
      } else if (this.status !== RegistrationState.SUCCESS) {
        this.initialView()
      }
    }
    .width('100%')
    // Swift: the body IS `CustomAlert { ... }` — `content.padding()
    // .background(secondarySystemBackground).cornerRadius(12).padding().shadow(radius: 10)`.
    // The host mounts this dialog with `customStyle: true`, so the card is drawn here; the
    // dim behind it is the dialog's own mask, so no scrim is painted a second time.
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .margin($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: $r('app.color.shadow_color') })
    .id('screen_name_registration')
  }
}
