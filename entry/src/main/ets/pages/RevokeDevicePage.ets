/*
 * screen_revocation — "Revoke Device", ported from
 *   Ring/Ring/Features/Settings/Me/RevocationView.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (CustomAlert, PasswordFieldView)
 *   Ring/Ring/Features/Settings/Me/BackupAccountModel.swift (hasPassword())
 *
 * presentation: popup, hostScreen: screen_linked_devices. RevocationView is a CustomAlert
 * rendered over LinkedDevicesView on `showRevocationAlert`, so LinkedDevicesPage renders it
 * IN PLACE — NOT a routed page and NOT in main_pages.json.
 *
 * NO CAPTURED STATE: the gallery declared this screen uncapturable, so its structure is source
 * only.
 *
 * S3 — the real tree of `createRevocationViewView()`, four exclusive bodies in source order:
 *   if let errorMessage   { errorView }      // "revocation_error_ok"
 *   else if let success   { successView }    // checkmark + "revocation_success_ok"
 *   else if revocationRequested { loadingView }  // ProgressView(deviceRevocationProgress)
 *   else                  { initialView }    // title, message, [PasswordFieldView],
 *                                            // "revocation_cancel" + "revocation_remove"
 *
 * The host hands over the device id it put in its own `@State deviceToRevoke`. initialView
 * never names the device: title, message, [password], Cancel / Remove — as on iPhone 4.20.
 *
 * conditionalVariants, each a real `if` on its own bound selector:
 *   confirm — isConfirm, the confirmation body (with the password field iff the account has one)
 *   success — isSuccess, revocation succeeded
 *   error   — isError, revocation failed
 *
 * Swift `.disabled(model.hasPassword() && password.isEmpty)` on Remove is SOURCE state and is
 * carried over verbatim: with a password-protected account an empty field really does leave
 * Remove inert, and with no password it is never guarded.
 *
 * Remove calls the daemon's revokeDevice and waits on the progress body for its
 * DeviceRevocationEnded, whose state picks the success or the error body (Swift
 * LinkedDevicesVM.subscribeToDeviceRevocationEvents / handleRevocationState).
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
// feat_device_linking lives in AccountsService — the device list this body names and the
// revocation write Remove performs are both its calls.
import { AccountsService, DeviceRevocationState } from '../common/AccountsService';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { PasswordFieldView } from '../components/PasswordField';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountModel } from '../model/AccountModel';

/** Swift `VStack(spacing: 20)` — every body of the alert. */
const BODY_GAP: number = 20;
/** Swift `.frame(width: 15, height: 15)` on the success checkmark. */
const SUCCESS_GLYPH: number = 15;
/** Swift `.padding(.trailing, 5)` on the success checkmark. */
const SUCCESS_GLYPH_GAP: number = 5;
/** Swift `.frame(minWidth: 280, minHeight: 150)` on the loading body. */
const LOADING_MIN_WIDTH: number = 280;
const LOADING_MIN_HEIGHT: number = 150;

/* ── S5 metrics (NO CAPTURE — the source's own, UtilitiesViews.swift:140 `CustomAlert`) ──
 *   ZStack { Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)
 *            content.padding().background(Color(UIColor.secondarySystemBackground))
 *                   .cornerRadius(12).padding().shadow(radius: 10) }
 * The backdrop and the card are the overlay's own root and its four exclusive bodies, so no
 * node is added for either: the root Column IS the dimmed, centring backdrop and each body
 * Column IS the card.
 */
/** Swift `Color.black.opacity(0.5)` — the alert's scrim. */
const ALERT_SCRIM: string = '#80000000';
/** Swift the inner `.padding()` and the outer `.padding()` — SwiftUI's default 16 pt. */
const ALERT_PADDING: number = 16;
/** Swift `.cornerRadius(12)`. */
const ALERT_RADIUS: number = 12;
/**
 * Swift `errorView` / `successView` carry a further `.padding(.top)` INSIDE CustomAlert's own
 * `.padding()`, so those two bodies sit one default inset lower than the confirm body.
 */
const ALERT_TOP_EXTRA: number = 16;
/** Swift `.shadow(radius: 10)`. */
const ALERT_SHADOW_RADIUS: number = 10;
/** SwiftUI's default shadow colour at `.shadow(radius:)` — black at one third. */
const ALERT_SHADOW_COLOR: string = '#55000000';
/** Swift `ProgressView(...)` — the iOS default (`.medium`) activity indicator. */
const LOADING_SIZE: number = 32;
/**
 * Swift `Color.jamiFailure` / `Color.jamiSuccess` = `UIColor(hex: 0xf00000)` / `0x00b20b`
 * (UIColor+Ring.swift:98-99) — hard-coded in the source, carried over verbatim.
 */
const JAMI_FAILURE: string = '#F00000';
const JAMI_SUCCESS: string = '#00B20B';
/** Swift `.opacity(model.hasPassword() && password.isEmpty ? 0.5 : 1)` on Remove. */
const REMOVE_DISABLED_OPACITY: number = 0.5;
/** Swift `AlertFieldStyle` — `.padding(.horizontal)` and `.cornerRadius(8)`. */
const ALERT_FIELD_INSET: number = 16;
const ALERT_FIELD_RADIUS: number = 8;

@CustomDialog
export struct RevokeDeviceOverlay {
  /** Injected when a host opens this through a dialog controller. */
  controller?: CustomDialogController;

  /** Swift `@Binding var showRevocationAlert` — owned by screen_linked_devices. */
  @Link isPresented: boolean;
  /** Swift `@Binding var deviceToRevoke: DeviceModel?` — the host's pick, by id. */
  @Prop deviceId: string = '';

  /**
   * Set by a host that renders this overlay IN PLACE (Swift `if showRevocationAlert { … }`)
   * instead of through a dialog controller — LinkedDevicesView is that host, and it clears its
   * own pending device here.
   */
  onDismiss?: () => void;

  /** Swift `@State var password` — filled only when model.hasPassword(). */
  @State password: string = '';
  /** Swift `model.hasPassword()` — whether the field and the Remove guard exist at all. */
  @State hasPassword: boolean = false;
  /** conditionalVariants[confirm]: Swift's `else { initialView() }`. */
  @State isConfirm: boolean = true;
  /** conditionalVariants[success]: Swift `model.revocationSuccess != nil`. */
  @State isSuccess: boolean = false;
  /** conditionalVariants[error]: Swift `model.revocationError != nil`. */
  @State isError: boolean = false;
  /** Swift `@State var revocationRequested` — the ProgressView body. */
  @State isLoading: boolean = false;
  /** Swift `model.revocationError` / `revocationSuccess` — the message each body shows. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'] — svc_accounts is scoped to it. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** The DeviceRevocationEnded subscription Remove opens; released with the overlay. */
  private revocationDispose: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.applyAccount();
  }

  aboutToDisappear(): void {
    if (this.revocationDispose !== undefined) {
      this.revocationDispose();
    }
  }

  /** Swift `model.hasPassword()` (BackupAccountModel), read off the real account. */
  private applyAccount(): void {
    const service: AccountsService = ServiceRegistry.shared().accountService;
    const account: AccountModel | null = service.getAccount(this.currentAccountId);
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

  /** Swift every dismissing button — `withAnimation { showRevocationAlert = false }`. */
  private close(): void {
    this.password = '';
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
    const dismiss: (() => void) | undefined = this.onDismiss;
    if (dismiss !== undefined) {
      dismiss();
    }
  }

  /**
   * Swift the Remove button — `revocationRequested = true`, then
   * `model.revokeDevice(deviceId:accountPassword:)`, which first subscribes to
   * `deviceRevocationEnded` for this account and device, then asks the daemon. The answer's
   * state is Swift `handleRevocationState(_:)`.
   */
  private revoke(): void {
    this.isLoading = true;
    this.isConfirm = false;
    const service: AccountsService = ServiceRegistry.shared().accountService;
    const accountId: string = this.currentAccountId;
    const deviceId: string = this.deviceId;
    this.revocationDispose = service.sharedResponseStream.subscribe((event: ServiceEvent): void => {
      if (event.eventType !== ServiceEventType.DEVICE_REVOCATION_ENDED ||
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) !== accountId ||
        event.getEventInput(ServiceEventInput.DEVICE_ID) !== deviceId) {
        return;
      }
      const state: number = Number(event.getEventInput(ServiceEventInput.STATE));
      this.isLoading = false;
      if (state === DeviceRevocationState.SUCCESS) {
        this.isSuccess = true;
        return;
      }
      this.isError = true;
      this.errorText = this.resolve(state === DeviceRevocationState.WRONG_PASSWORD
        ? 'account_page_device_revocation_wrong_password'
        : state === DeviceRevocationState.UNKNOWN_DEVICE
          ? 'account_page_device_revocation_unknown_device'
          : 'account_page_device_revocation_error');
    });
    service.revokeDevice(accountId, this.password, deviceId);
    this.password = '';
  }

  /** A localized string resolved to plain text — the bodies show a message, not a resource. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  /** Swift `errorView(errorMessage:)`. */
  @Builder
  private errorBody() {
    Column({ space: BODY_GAP }) {
      // Swift `.foregroundColor(Color.jamiFailure)`, centred between two Spacers.
      Text(this.errorText)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor(JAMI_FAILURE)

      Row() {
        Blank()
        Button($r('app.string.global_ok'))
          .id('revocation_error_ok')
          // Swift `Text(L10n.Global.ok).foregroundColor(.jami)` — a bare tinted label.
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    // Swift `CustomAlert` — `.padding().background(secondarySystemBackground)
    // .cornerRadius(12).shadow(radius: 10)`, plus this body's own `.padding(.top)`.
    .padding({
      top: LengthMetrics.vp(ALERT_PADDING + ALERT_TOP_EXTRA),
      bottom: LengthMetrics.vp(ALERT_PADDING),
      start: LengthMetrics.vp(ALERT_PADDING),
      end: LengthMetrics.vp(ALERT_PADDING)
    })
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(ALERT_RADIUS)
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: ALERT_SHADOW_COLOR })
  }

  /** Swift `successView(successMessage:)` — the checkmark and its message. */
  @Builder
  private successBody() {
    Column({ space: BODY_GAP }) {
      Row() {
        Blank()
        // Swift the whole Group is `.foregroundColor(Color.jamiSuccess)`; the glyph carries
        // `.padding(.trailing, 5)`.
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(SUCCESS_GLYPH)
          .fontColor([JAMI_SUCCESS])
          .margin({ end: LengthMetrics.vp(SUCCESS_GLYPH_GAP) })
        Text($r('app.string.account_page_device_revocation_success'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor(JAMI_SUCCESS)
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Blank()
        Button($r('app.string.global_ok'))
          .id('revocation_success_ok')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    // Swift `CustomAlert` — `.padding().background(secondarySystemBackground)
    // .cornerRadius(12).shadow(radius: 10)`, plus this body's own `.padding(.top)`.
    .padding({
      top: LengthMetrics.vp(ALERT_PADDING + ALERT_TOP_EXTRA),
      bottom: LengthMetrics.vp(ALERT_PADDING),
      start: LengthMetrics.vp(ALERT_PADDING),
      end: LengthMetrics.vp(ALERT_PADDING)
    })
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(ALERT_RADIUS)
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: ALERT_SHADOW_COLOR })
  }

  /** Swift `loadingView()` — ProgressView(L10n.AccountPage.deviceRevocationProgress). */
  @Builder
  private loadingBody() {
    Column({ space: BODY_GAP }) {
      LoadingProgress()
        .id('revocationProgress')
        .width(LOADING_SIZE)
        .height(LOADING_SIZE)
        .color($r('sys.color.font_secondary'))
      // Swift `ProgressView(_ title:)` — the label sits under the spinner, in secondaryLabel.
      Text($r('app.string.account_page_device_revocation_progress'))
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.secondary_label'))
    }
    .justifyContent(FlexAlign.Center)
    .constraintSize({ minWidth: LOADING_MIN_WIDTH, minHeight: LOADING_MIN_HEIGHT })
    // Swift `CustomAlert` — `.padding().background(secondarySystemBackground)
    // .cornerRadius(12).shadow(radius: 10)`.
    .padding(ALERT_PADDING)
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(ALERT_RADIUS)
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: ALERT_SHADOW_COLOR })
  }

  /** Swift `initialView()` — the confirmation body. */
  @Builder
  private confirmBody() {
    Column({ space: BODY_GAP }) {
      // Swift `.font(.headline)`.
      Text($r('app.string.account_page_remove_device_title'))
        .width('100%')
        // Swift `VStack(spacing: 20)` centres its children — the headline is not leading-set.
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      // Swift `.font(.subheadline)`.
      Text($r('app.string.account_page_revoke_device_message'))
        // Swift `VStack(spacing: 20)` centres the Text, but RevocationView sets no
        // `multilineTextAlignment`, so a wrapped message is leading, unlike the centred
        // ManageAccountView removal alert (T-0552).
        .textAlign(TextAlign.Start)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))

      // Swift `if model.hasPassword() { PasswordFieldView(text: $password, …) }`.
      if (this.hasPassword) {
        // Swift `.textFieldStyleInAlert()` — a white (systemBackground) field on the grey card;
        // the default grey pill vanished into it (T-0926).
        PasswordFieldView({
          text: $password,
          placeholder: $r('app.string.global_enter_password'),
          identifier: 'revocation_password',
          pillBackground: $r('sys.color.background_primary'),
          pillInset: ALERT_FIELD_INSET,
          pillRadius: ALERT_FIELD_RADIUS
        })
      }

      Row() {
        Button($r('app.string.global_cancel'))
          .id('revocation_cancel')
          // Swift `Text(L10n.Global.cancel).foregroundColor(Color(UIColor.label))`.
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .onClick(() => {
            this.close();
          })

        Blank()

        // Swift `Text(L10n.Global.remove).foregroundColor(.jami)`. A disabled ArkUI Button dims
        // itself to 0.4 on top of the 0.5 below, which left Remove at 0.2 (T-0926), so the
        // control is the label itself with the button role, as AccountMigrationPage (T-1740).
        Text($r('app.string.global_remove'))
          .id('revocation_remove')
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          // Swift `.opacity(model.hasPassword() && password.isEmpty ? 0.5 : 1)`.
          .opacity(this.hasPassword && this.password.length === 0 ? REMOVE_DISABLED_OPACITY : 1)
          // Swift `.disabled(model.hasPassword() && password.isEmpty)` — the source's guard.
          .enabled(!(this.hasPassword && this.password.length === 0))
          .onClick(() => {
            this.revoke();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // Swift `CustomAlert` — `.padding().background(secondarySystemBackground)
    // .cornerRadius(12).shadow(radius: 10)`.
    .padding(ALERT_PADDING)
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(ALERT_RADIUS)
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: ALERT_SHADOW_COLOR })
  }

  build() {
    // Swift `CustomAlert(content: { createRevocationViewView() })` — one VStack, four
    // exclusive bodies, never two of them at once.
    Column({ space: BODY_GAP }) {
      if (this.isError) {
        this.errorBody()
      } else if (this.isSuccess) {
        this.successBody()
      } else if (this.isLoading) {
        this.loadingBody()
      } else if (this.isConfirm) {
        this.confirmBody()
      }
    }
    .width('100%')
    // Swift `CustomAlert`'s ZStack: `Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)`
    // behind a centred card, with the outer `.padding()` insetting it from the screen edges.
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(ALERT_PADDING)
    .backgroundColor(ALERT_SCRIM)
    .id('screen_revocation')
  }
}
