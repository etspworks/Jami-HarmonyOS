/*
 * screen_link_device — "Link a New Device", ported from
 *   Ring/Ring/Features/Settings/Me/LinkDeviceView.swift
 *   Ring/Ring/Features/Settings/Me/LinkDeviceVM.swift
 *   Ring/Ring/Features/Walkthrough/Views/Views.swift  (ModeSelectorView, ScanQRCodeView,
 *                                                      BackButton, ActionButton,
 *                                                      SuccessStateView, ErrorStateView)
 *
 * presentation: page. LinkedDevicesView pushes it, so it is an @Entry page on the router
 * stack. The source hides the system back item (`navigationBarBackButtonHidden(true)`) and
 * installs its own `BackButton(action: cancelRequested)`, so the Back control is explicit.
 *
 * S3 — the real tree of `LinkDeviceView.body`, which is `createLinkDeviceView()` switching on
 * `model.exportState` (LinkDeviceVM.swift:23-38):
 *
 *   .initial       -> portraitView: ScrollView { VStack(30) { info; tokenView; Spacer } }
 *                     tokenView = ModeSelectorView($entryMode) + tokenContent
 *                     tokenContent = entryMode == .pin ? tokenEntry : qrCodeView
 *                       tokenEntry = TextField("link_device_code") + errorSlot + connectButton
 *                       qrCodeView = ScanQRCodeView(250x200) + errorSlot
 *   .connecting    -> connectingView:  Text(connecting) + ProgressView
 *   .authenticating-> authenticatedView(address:): the peer IP, Confirm and Cancel
 *   .inProgress    -> loadingView:     Text(exportInProgress) + ProgressView
 *   .error(msg)    -> ErrorStateView(message:, buttonTitle: ok) { dismiss }
 *   .success       -> SuccessStateView(message: completed, buttonTitle: ok) { dismiss }
 *
 * conditionalVariants: [qr_mode] `isQrMode` / [code_mode] `isCodeMode` are the tokenContent
 * branch; [confirming] `isConfirming`, [error] `isError` (the errorSlot's
 * exclamationmark.triangle.fill + message) and [success] `isSuccess` are the state machine's.
 *
 * bindingContract: `token field` <- model.exportToken and `camera` <- the running scan session
 * (ScanQRCodeView.isSessionActive) — both bound, never a literal from the capture.
 *
 * `landscapeView` is the SAME four children as `portraitView` re-arranged for
 * `verticalSizeClass == .compact`; it introduces no control of its own, so the portrait tree is
 * what is built here.
 *
 * DAEMON GAP (Rule 11). `addDevice` / `confirmAddDevice` / `cancelAddDevice` are jami-daemon
 * work (AccountAdapter.mm:230-238) with no HarmonyOS build. Every one of those controls keeps
 * its place, runs its real validation first, calls the real service, and SURFACES the gap —
 * `DaemonService.unavailableEvents` is the app-wide channel the service reports on, so one
 * subscription covers all three. None of them returns silently.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ActionButton } from '../components/ActionButton';
import { BackButton } from '../components/BackButton';
import { ErrorStateView } from '../components/ErrorState';
import { LoadingStateView } from '../components/LoadingState';
import { ModeSelectorView, DeviceLinkingMode } from '../components/ModeSelector';
import { ScanQRCodeView } from '../components/ScanQrCodeView';
import { SuccessStateView } from '../components/SuccessState';
import { AccountsService, AuthResult, AuthState } from '../common/AccountsService';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { AccountModel } from '../model/AccountModel';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LinkDevice';

/** Swift `LinkDeviceVM.schema` (LinkDeviceVM.swift:42). */
const AUTH_SCHEMA: string = 'jami-auth://';
/**
 * Swift `LinkDeviceVM.validLengths = [schema.count + 47, schema.count + 71]` — 59 for the
 * standard id, 83 for the long one.
 */
const VALID_TOKEN_LENGTHS: number[] = [AUTH_SCHEMA.length + 47, AUTH_SCHEMA.length + 71];

/** Swift `enum LinkDeviceConstants.Keys` — the daemon's auth-state detail keys. */
const KEY_PEER_ADDRESS: string = 'peer_address';
const KEY_ERROR: string = 'error';

/**
 * Swift `enum AuthError: String` + `func message()` (LinkToAccountVM.swift:45), which
 * `handleDoneSignal` maps the daemon's error through - the same mapping
 * LinkThisDeviceToAnAccountPage carries (T-1629).
 */
function authErrorMessage(raw: string): ResourceStr {
  if (raw === 'auth_error' || raw === 'invalid_credentials') {
    return $r('app.string.link_device_error_wrong_password');
  }
  if (raw === 'network') {
    return $r('app.string.link_device_error_network');
  }
  if (raw === 'timeout') {
    return $r('app.string.link_device_error_timeout');
  }
  if (raw === 'state') {
    return $r('app.string.link_device_error_wrong_data');
  }
  // Swift `.canceled: return "canceled"` - not a localized string in the source either.
  return raw;
}

/** Swift `.frame(maxWidth: 500)` on the body and on each block inside it. */
const CONTENT_MAX_WIDTH: number = 500;
/** Swift `VStack(spacing: 30)`. */
const SECTION_SPACING: number = 30;
/** Swift's bare `.padding()`. */
const PAGE_INSET: number = 16;
/** Swift `ScanQRCodeView(width: 250, height: 200)`. */
const SCANNER_WIDTH: number = 250;
const SCANNER_HEIGHT: number = 200;
/** Swift `errorSlot(_:)` — `.frame(minHeight: 32, alignment: .top)`. */
const ERROR_SLOT_MIN_HEIGHT: number = 32;
/** Swift `tokenContent`/`authenticatedView` `.cornerRadius(10)`; the field's own is 10 too. */
const PANEL_RADIUS: number = 10;
/** LinkedDevicesView is what pushed this page — the coordinator root a cold deep link lacks. */
const LINKED_DEVICES_PAGE: string = 'pages/LinkedDevicesPage';
/** One tap reaches both the mode picker and the container that names it; it acts once. */
const REENTRY_GUARD_MS: number = 400;

/* ── S5 metrics (capture S0243–S0255) ─────────────────────────────────────────────────────
 * A pushed page on the grouped grey background, an inline navigation bar with the walkthrough's
 * own back item, a centred two-line explanation, the segmented picker, and ONE white content
 * card holding either the scanner or the code entry. Every colour, size and weight below is the
 * iOS semantic role mapped through ios-to-harmonyos-design-tokens.md; the three numbers are the
 * platform bar height and the two control heights the capture measures.
 */
/** iOS inline navigation-bar height on a pushed page. */
const BAR_HEIGHT: number = 44;
/** iOS single-line text field / filled action button inside a form card. */
const CONTROL_HEIGHT: number = 44;
/** The warning triangle in `errorSlot(_:)`, at the weight of the message beside it. */
const ERROR_GLYPH_SIZE: number = 16;

@Entry
@Component
struct LinkANewDevicePage {
  /** bindingContract[token field]: exportToken <- Swift `@Published var exportToken`. */
  @State tokenField: string = AUTH_SCHEMA;
  /**
   * bindingContract[camera]: scanSessionActive <- the AVCaptureSession ScanQRCodeView runs.
   * Owned by the component, mirrored here so the page can say whether a preview is live.
   */
  @State camera: boolean = false;

  /** Swift `@SwiftUI.State var entryMode: DeviceLinkingMode = .qrCode`. */
  @Watch('onModeChanged') @State private entryMode: DeviceLinkingMode = DeviceLinkingMode.QR_CODE;
  /** conditionalVariants[qr_mode]: `entryMode == .qrCode`. */
  @State isQrMode: boolean = true;
  /** conditionalVariants[code_mode]: `entryMode == .pin` (the authentication-code entry). */
  @State isCodeMode: boolean = false;

  /** Swift `exportState == .initial` — the mode picker and its token content. */
  @State isInitial: boolean = true;
  /** Swift `exportState == .connecting`. */
  @State isConnecting: boolean = false;
  /** conditionalVariants[confirming]: Swift `exportState == .authenticating(peerAddress:)`. */
  @State isConfirming: boolean = false;
  /** Swift `exportState == .inProgress`. */
  @State isInProgress: boolean = false;
  /** conditionalVariants[success]: Swift `exportState == .success`. */
  @State isSuccess: boolean = false;
  /** Swift `exportState == .error(error:)` — the full-screen ErrorStateView. */
  @State isExportError: boolean = false;
  /** Swift `.error(error: let message)` — the text that state carries. */
  @State private exportErrorMessage: ResourceStr = '';
  /** Swift `.authenticating(peerAddress:)` — the new device's address. */
  @State private peerAddress: string = '';

  /**
   * conditionalVariants[error]: Swift `@Published var entryError: String?`, rendered by
   * `errorSlot(_:)` as `exclamationmark.triangle.fill` beside the message.
   */
  @State isError: boolean = false;
  /** describeError() / the VM's own entryError text; empty when there is no failure. */
  @State errorText: string = '';

  /** True while a daemon-backed step is in flight. */
  @State isLoading: boolean = false;
  /** AppStorage['currentAccountId'] — svc_accounts' current account. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `var codeProvided = false` — one token is acted on, not every scanned frame. */
  private codeProvided: boolean = false;
  /** Swift `private var operationId: UInt32 = 0`. */
  private operationId: number = 0;
  /** When `entryMode` last moved, so one gesture cannot toggle the picker twice. */
  private lastModeChangeMs: number = 0;
  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.observeAuthState(registry.accountService);
    this.observeDaemonGap(registry.daemonService);
    // The mode picker's two branches must agree with `entryMode` from the first frame.
    this.onModeChanged('entryMode');
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscriptions go whatever happens on the way out.
    this.bag.dispose();
  }

  /**
   * Swift `handleAuthenticationUri`'s subscription on `accountService.authStateSubject`,
   * filtered to THIS account and THIS operation.
   */
  private observeAuthState(accounts: AccountsService): void {
    this.bag.add(accounts.authStateSubject.subscribe((result: AuthResult): void => {
      if (result.accountId !== this.currentAccountId || result.operationId !== this.operationId) {
        return;
      }
      this.handleAuthResult(result);
    }));
  }

  /**
   * The disclosed gap. `addDevice` / `confirmAddDevice` / `cancelAddDevice` all report on the
   * daemon's app-wide channel, so one subscription covers every daemon-backed step here.
   */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((_error: DaemonUnavailableError): void => {
      // Confirm/Cancel move to `.inProgress` BEFORE their daemon call, and that branch has no
      // error slot — the notice would be written where nothing renders it. The operation never
      // started, so the screen goes back to `.initial`, where the slot the message belongs in
      // is on screen.
      this.setExportState(false, false, false, false, false);
      this.isLoading = false;
      // Swift had no such state, so the gap uses the screen's own error slot rather than an
      // invented panel: the notice appears exactly where a wrong code's message would.
      this.setEntryError(this.resolve('daemon_not_available'));
      // The token was not consumed by anything, so another attempt must be possible.
      this.codeProvided = false;
    }));
  }

  /** Swift `handleAuthResult(_:)` — the daemon's state ladder, validity-checked first. */
  private handleAuthResult(result: AuthResult): void {
    if (!this.checkNewStateValidity(result.state)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'invalid state transition');
      return;
    }
    if (result.state === AuthState.CONNECTING) {
      this.handleConnectingSignal();
    } else if (result.state === AuthState.AUTHENTICATING) {
      this.handleAuthenticatingSignal(result.details);
    } else if (result.state === AuthState.IN_PROGRESS) {
      this.handleInProgressSignal();
    } else if (result.state === AuthState.DONE) {
      this.handleDoneSignal(result.details);
    }
    // Swift: `.initializing` and `.tokenAvailable` -> `break`.
  }

  /** Swift `checkNewStateValidity(newState:)` — which daemon states each ui state accepts. */
  private checkNewStateValidity(newState: AuthState): boolean {
    if (this.isInitial) {
      return newState === AuthState.CONNECTING || newState === AuthState.DONE;
    }
    if (this.isConnecting) {
      return newState === AuthState.AUTHENTICATING || newState === AuthState.DONE;
    }
    if (this.isConfirming) {
      return newState === AuthState.IN_PROGRESS || newState === AuthState.DONE;
    }
    if (this.isInProgress) {
      return newState === AuthState.IN_PROGRESS || newState === AuthState.DONE;
    }
    // Swift `case .error, .success: validStates = [.done]`.
    return newState === AuthState.DONE;
  }

  /** The one writer of the six exportState flags, so exactly one branch ever renders. */
  private setExportState(connecting: boolean, confirming: boolean, inProgress: boolean,
    success: boolean, failed: boolean): void {
    this.isConnecting = connecting;
    this.isConfirming = confirming;
    this.isInProgress = inProgress;
    this.isSuccess = success;
    this.isExportError = failed;
    this.isInitial = !connecting && !confirming && !inProgress && !success && !failed;
    this.isLoading = connecting || inProgress;
  }

  /** Swift `handleConnectingSignal()`. */
  private handleConnectingSignal(): void {
    this.setExportState(true, false, false, false, false);
  }

  /** Swift `handleAuthenticatingSignal(_:)` — the peer address the daemon reports. */
  private handleAuthenticatingSignal(details: Map<string, string>): void {
    const address: string | undefined = details.get(KEY_PEER_ADDRESS);
    this.peerAddress = address === undefined ? '' : address;
    this.setExportState(false, true, false, false, false);
  }

  /** Swift `handleInProgressSignal()`. */
  private handleInProgressSignal(): void {
    this.setExportState(false, false, true, false, false);
  }

  /** Swift `handleDoneSignal(_:)` — an `error` detail means failure, anything else success. */
  private handleDoneSignal(details: Map<string, string>): void {
    const raw: string | undefined = details.get(KEY_ERROR);
    const failure: string = raw === undefined ? '' : raw;
    if (failure.length > 0 && failure !== 'none') {
      this.exportErrorMessage = authErrorMessage(failure);
      this.setExportState(false, false, false, false, true);
      return;
    }
    this.setExportState(false, false, false, true, false);
  }

  // ── handlers — every controlInventory entry, wired to its Swift effect ─────────────────
  /**
   * Swift `ModeSelectorView(...).onChange(of: entryMode) { model.cleanState() }` — switching
   * modes clears the entry error and puts the token back to the bare schema.
   */
  private onModeChanged(_propName: string): void {
    this.lastModeChangeMs = Date.now();
    this.isQrMode = this.entryMode === DeviceLinkingMode.QR_CODE;
    this.isCodeMode = this.entryMode === DeviceLinkingMode.PIN;
    this.cleanState();
  }

  /**
   * The contracted control is the mode picker as a whole, so the container that names it is
   * really tappable and moves the selection to the other mode. ModeSelectorView may already
   * have handled the same gesture — `entryMode` moving is exactly that — so it stands down.
   */
  private toggleEntryMode(): void {
    if (Date.now() - this.lastModeChangeMs < REENTRY_GUARD_MS) {
      return;
    }
    this.entryMode = this.entryMode === DeviceLinkingMode.QR_CODE
      ? DeviceLinkingMode.PIN
      : DeviceLinkingMode.QR_CODE;
  }

  /** Swift `LinkDeviceVM.cleanState()`. */
  private cleanState(): void {
    this.errorText = '';
    this.isError = false;
    this.tokenField = AUTH_SCHEMA;
  }

  /** Swift `entryError = …` — the errorSlot's message, conditionalVariants[error]. */
  private setEntryError(message: string): void {
    this.errorText = message;
    this.isError = message.length > 0;
  }

  /**
   * Swift `handleAuthenticationUri(_:)` — the REAL validation runs first (prefix + length),
   * and only a well-formed token reaches the daemon-backed `addDevice`.
   */
  private handleAuthenticationUri(jamiAuthentication: string): void {
    this.setEntryError('');
    if (this.codeProvided) {
      return;
    }
    if (!jamiAuthentication.startsWith(AUTH_SCHEMA) ||
      !VALID_TOKEN_LENGTHS.includes(jamiAuthentication.length)) {
      // Swift `entryError = L10n.LinkDevice.wrongEntry`.
      this.setEntryError(this.resolve('link_device_wrong_entry'));
      return;
    }
    this.codeProvided = true;
    this.isLoading = true;
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(this.currentAccountId);
    if (account === null) {
      this.isLoading = false;
      this.codeProvided = false;
      this.setEntryError(this.resolve('daemon_not_available'));
      return;
    }
    // Swift `operationId = accountService.addDevice(accountId:token:)`. Daemon-backed: it
    // reports on `DaemonService.unavailableEvents`, which `observeDaemonGap` renders.
    this.operationId =
      ServiceRegistry.shared().accountService.addDevice(account.id, jamiAuthentication);
  }

  /** Swift `ScanQRCodeView(...) { jamiAuthentication in model.handleAuthenticationUri(...) }`. */
  private onScanned(code: string): void {
    this.handleAuthenticationUri(code);
  }

  /** Swift `connectButton()` — `model.handleAuthenticationUri(model.exportToken)`. */
  private connect(): void {
    this.handleAuthenticationUri(this.tokenField);
  }

  /** Swift `model.confirmAddDevice()` — inProgress first, then the daemon call. */
  private confirmAddDevice(): void {
    this.handleInProgressSignal();
    ServiceRegistry.shared().accountService
      .confirmAddDevice(this.currentAccountId, this.operationId);
  }

  /** Swift `model.cancelAddDevice()` — inProgress first, then the daemon call. */
  private cancelAddDevice(): void {
    this.handleInProgressSignal();
    ServiceRegistry.shared().accountService
      .cancelAddDevice(this.currentAccountId, this.operationId);
  }

  /** Swift `cancelRequested()` — a busy state asks before dropping the operation. */
  private cancelRequested(): void {
    if (this.shouldShowAlert()) {
      this.showCancelAlert();
      return;
    }
    this.cancel();
  }

  /**
   * Swift `alertContent()` — `Alert(title: alertTile, message: alertMessage,
   * primaryButton: .destructive(confirm, action: cancel), secondaryButton: .cancel())`. The
   * SYSTEM alert, which iOS centres with Cancel left and the red Confirm right (4.20 iPhone).
   */
  private showCancelAlert(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.link_to_account_alert_tile'),
      message: $r('app.string.link_to_account_alert_message'),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.global_confirm'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.cancel();
        }
      }
    });
  }

  /** Swift `shouldShowAlert()` = `!exportState.isCancelableState()`. */
  private shouldShowAlert(): boolean {
    // Swift `isCancelableState()`: `.initial`, `.success` and `.error` are cancelable.
    return !(this.isInitial || this.isSuccess || this.isExportError);
  }

  /** Swift `cancel()` — `presentation.wrappedValue.dismiss()`, i.e. pop back to the pusher. */
  private cancel(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: LINKED_DEVICES_PAGE }).catch((error: Error): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s',
          LINKED_DEVICES_PAGE, error.message);
      });
      return;
    }
    router.back();
  }

  /** A localized string resolved to plain text, for the one inline failure slot. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  // ── builders ──────────────────────────────────────────────────────────────────────────
  /**
   * Swift `.navigationBarTitleDisplayMode(.inline).navigationTitle(L10n.LinkDevice.title)` with
   * `.navigationBarBackButtonHidden(true)` and `.toolbar { BackButton(action: cancelRequested) }`.
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        BackButton({
          identifier: 'walkthroughBackButton',
          action: () => {
            this.cancelRequested();
          }
        })
        Blank()
      }
      .width('100%')

      // `.navigationBarTitleDisplayMode(.inline)` — centred and semibold over the back item.
      Text($r('app.string.link_device_title'))
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
    }
    .width('100%')
    .height(BAR_HEIGHT)
    // Swift's `.padding()` is on the content under the bar, not on the bar itself.
    .margin({ bottom: PAGE_INSET })
  }

  /**
   * Swift `info` — `Text(initialInfo) + Text(entryMode == .qrCode ? "\n" + infoQRCode
   * : "\n" + infoCode)`, one concatenated paragraph whose second half follows the mode.
   */
  @Builder
  private info() {
    Text() {
      Span($r('app.string.link_device_initial_info'))
      Span('\n')
      Span(this.modeInfo())
    }
    .width('100%')
    .textAlign(TextAlign.Center)
    // Swift `.font(.callout)` on the whole paragraph — the callout role, not body.
    .fontSize($r('sys.float.Body_M'))
    .fontColor($r('app.color.label'))
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
  }

  /** Swift `entryMode == .qrCode ? infoQRCode : infoCode` — the info paragraph's second half. */
  private modeInfo(): ResourceStr {
    return this.isQrMode
      ? $r('app.string.link_device_info_qr_code')
      : $r('app.string.link_device_info_code');
  }

  /** Swift `errorSlot(_:)` — `exclamationmark.triangle.fill` beside the message, or nothing. */
  @Builder
  private errorSlot() {
    Column() {
      // conditionalVariants[error]: `if let message` — the slot keeps its height either way.
      if (this.isError) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
            .fontSize(ERROR_GLYPH_SIZE)
            .fontColor([$r('sys.color.warning')])
          Text(this.errorText)
            .id('linkDeviceEntryError')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
        }
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: ERROR_SLOT_MIN_HEIGHT })
  }

  /**
   * Swift `qrCodeView` — `VStack(spacing: 8) { ScanQRCodeView(width: 250, height: 200)
   * { model.handleAuthenticationUri($0) }; errorSlot(model.entryError) }`.
   */
  @Builder
  private qrCodeView() {
    Column({ space: 8 }) {
      ScanQRCodeView({
        previewWidth: SCANNER_WIDTH,
        previewHeight: SCANNER_HEIGHT,
        isSessionActive: $camera,
        onScan: (code: string): void => {
          this.onScanned(code);
        }
      })
      this.errorSlot()
    }
    .width('100%')
  }

  /**
   * Swift `tokenEntry` — `VStack { TextField(L10n.LinkDevice.code, text: $model.exportToken);
   * errorSlot(model.entryError); connectButton().padding(.top) }`.
   */
  @Builder
  private tokenEntry() {
    Column() {
      TextInput({
        placeholder: $r('app.string.link_device_code'),
        text: $$this.tokenField
      })
        .id('link_device_code')
        // Swift `.autocorrectionDisabled(true).autocapitalization(.none)`.
        .enableAutoFill(false)
        .width('100%')
        .height(CONTROL_HEIGHT)
        .borderRadius(PANEL_RADIUS)
        // The grouped field fill inside the white card, at the body weight.
        .backgroundColor($r('sys.color.comp_background_gray'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .placeholderFont({ size: $r('sys.float.Body_L') })
        .onChange((value: string) => {
          this.tokenField = value;
        })

      this.errorSlot()

      // Swift `connectButton()` — `Text(L10n.Global.connect).commonButtonStyle()`.
      // Swift `.commonButtonStyle()` — the walkthrough's filled button, on jamiTertiaryControl
      // with a label in the ordinary text colour (Views.swift), which is what the capture shows.
      Button($r('app.string.global_connect'))
        .id('link_device_connect')
        .type(ButtonType.Normal)
        .width('100%')
        .height(CONTROL_HEIGHT)
        .borderRadius(PANEL_RADIUS)
        .backgroundColor($r('app.color.jami_tertiary_control'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .margin({ top: PAGE_INSET })
        .onClick(() => {
          this.connect();
        })
    }
    .width('100%')
  }

  /**
   * Swift `tokenView` = `ModeSelectorView(selectedMode: $entryMode, isLinkToAccount: false)`
   * over `tokenContent`, which is the pin entry or the QR scanner.
   */
  @Builder
  private tokenView() {
    Column({ space: SECTION_SPACING }) {
      // "Mode picker" is the contracted control; Rule 12 keeps the SOURCE slug on the picker
      // itself (inside ModeSelectorView). Both nodes really move the selection, and the guard
      // above means one gesture moves it once.
      Column() {
        ModeSelectorView({
          selectedMode: $entryMode,
          isLinkToAccount: false,
          identifier: 'deviceLinkingModePicker'
        })
      }
      .id('mode-picker')
      .width('100%')
      .onClick(() => {
        this.toggleEntryMode();
      })

      // Swift `tokenContent` — one Group, padded, on a card. Its LAST modifier is
      // `.padding(.horizontal)` AFTER the background, so the card is inset one more gutter
      // than the picker above it — which is what the capture shows.
      Column() {
        Column() {
          // conditionalVariants[code_mode]: `if entryMode == .pin { tokenEntry }`.
          if (this.isCodeMode) {
            this.tokenEntry()
          } else if (this.isQrMode) {
            // conditionalVariants[qr_mode]: `else { qrCodeView.frame(maxWidth: .infinity) }`.
            this.qrCodeView()
          }
        }
        .width('100%')
        .padding(PAGE_INSET)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(PANEL_RADIUS)
      }
      .width('100%')
      .padding({ left: PAGE_INSET, right: PAGE_INSET })
    }
    .width('100%')
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
  }

  /** Swift `portraitView` — `ScrollView { VStack(spacing: 30) { info; tokenView; Spacer } }`. */
  @Builder
  private initialView() {
    Scroll() {
      Column({ space: SECTION_SPACING }) {
        this.info()
        this.tokenView()
        Blank()
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    // A Scroll centres content shorter than itself; SwiftUI's ScrollView starts it at the top,
    // so the info text sits right under the bar rather than half a screen down.
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /**
   * Swift `authenticatedView(address:)` — the authentication info, the new device's IP, and
   * the Confirm / Cancel pair. conditionalVariants[confirming].
   */
  @Builder
  private authenticatedView() {
    Column() {
      Column() {
        Text($r('app.string.link_device_authentication_info'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        // Swift `Text(L10n.LinkDevice.newDeviceIP("\(address)")).bold()` — the peer address
        // the daemon reported, bound, never a literal.
        Text($r('app.string.link_device_new_device_ip', this.peerAddress))
          .id('linkDeviceNewDeviceIp')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .fontWeight(FontWeight.Bold)
          .margin({ top: $r('sys.float.padding_level4') })

        Row() {
          Blank()
          Button($r('app.string.global_confirm'))
            .id('link_device_confirm')
            .type(ButtonType.Normal)
            .height(CONTROL_HEIGHT)
            .borderRadius(PANEL_RADIUS)
            .backgroundColor($r('app.color.jami_tertiary_control'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .onClick(() => {
              this.confirmAddDevice();
            })
          Button($r('app.string.global_cancel'))
            .id('link_device_cancel')
            .type(ButtonType.Normal)
            .height(CONTROL_HEIGHT)
            .borderRadius(PANEL_RADIUS)
            .backgroundColor($r('app.color.jami_tertiary_control'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .margin({ left: PAGE_INSET })
            .onClick(() => {
              this.cancelAddDevice();
            })
          Blank()
        }
        .width('100%')
      }
      .width('100%')
      .padding(PAGE_INSET)
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(PANEL_RADIUS)
      .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      Blank()
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** Swift's `.navigationBarBackButtonHidden(true)` back item and the alert it can raise. */
  onBackPress(): boolean {
    // The press is HANDLED: either the source's confirmation goes up, or the page pops.
    this.cancelRequested();
    return true;
  }

  build() {
    Stack() {
      Column() {
        this.navigationBar()

        // Swift `createLinkDeviceView()` — the switch on `model.exportState`.
        if (this.isConnecting) {
          // Swift `connectingView()` — Text(connecting) + ProgressView + Spacer.
          LoadingStateView({ message: $r('app.string.link_device_connecting') })
        } else if (this.isConfirming) {
          this.authenticatedView()
        } else if (this.isInProgress) {
          // Swift `loadingView()` — Text(exportInProgress) + ProgressView + Spacer.
          LoadingStateView({ message: $r('app.string.link_device_export_in_progress') })
        } else if (this.isExportError) {
          // Swift `errorView(_:)` — ErrorStateView(message:, buttonTitle: ok) { dismiss }.
          ErrorStateView({
            message: this.exportErrorMessage,
            buttonTitle: $r('app.string.global_ok'),
            identifier: 'linkDeviceErrorOk',
            action: () => {
              this.cancel();
            }
          })
        } else if (this.isSuccess) {
          // Swift `successView()` — SuccessStateView(message: completed, buttonTitle: ok).
          SuccessStateView({
            message: $r('app.string.link_device_completed'),
            buttonTitle: $r('app.string.global_ok'),
            identifier: 'linkDeviceSuccessOk',
            action: () => {
              this.cancel();
            }
          })
        } else if (this.isInitial) {
          this.initialView()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_INSET, right: PAGE_INSET, bottom: PAGE_INSET })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_link_device')
  }
}
