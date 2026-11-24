/*
 * screen_link_to_account — "Link This Device to an Account", ported from
 *   Ring/Ring/Features/Walkthrough/Views/LinkToAccountView.swift
 *   Ring/Ring/Features/Walkthrough/Models/LinkToAccountVM.swift
 *   Ring/Ring/Features/Walkthrough/Views/Views.swift          (BackButton, ModeSelectorView,
 *                                                              Success/Error/LoadingStateView)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift       (QRCodeView)
 *
 * presentation: page. WalkthroughCoordinator.showLinkDevice(linkAction:) PUSHES this view onto
 * the walkthrough stack, so it is an @Entry page reached with router.pushUrl from
 * WelcomeOnboardingPage ("Link a device"), and Back pops back to it.
 *
 * S3 — `mainContent` is a 7-way switch on `LinkToAccountVM.uiState`
 * (conditionalVariants[link_ui_state]); each case renders a COMPLETELY different body, so the
 * seven branches are real `if`s here, never one flattened layout:
 *
 *   .initial          -> info + ProgressView                     (LoadingStateView's shape)
 *   .displayingToken  -> info + ModeSelectorView + QR code | token label + ShareButtonView
 *   .connecting       -> Text(actionRequired)
 *   .authenticating   -> userInfoView + (hasPassword ? passwordView) + Import account
 *   .inProgress       -> ProgressView                            (LoadingStateView)
 *   .success          -> SuccessStateView(allSet, goToAccounts)
 *   .error(message)   -> ErrorStateView(message, exit)
 *
 * The toolbar is the source's own: `navigationBarBackButtonHidden(true)` +
 * `BackButton(action: cancelRequested)`, which raises the confirm alert while the operation is
 * not in a cancelable state (`viewModel.shouldShowAlert()`), and pops otherwise.
 *
 * bindingContract: the QR code is generated from `viewModel.token` (never a bundled
 * placeholder), and the password field appears only when `viewModel.hasPassword`.
 *
 * The export token, the auth-state ladder and the final import run on the daemon:
 * `createTemporaryAccount()` adds the `jami-auth` account and `DeviceAuthStateChanged` drives
 * `uiState`, exactly as in the source.
 */
import { router, SymbolGlyphModifier } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackButton } from '../components/BackButton';
import { CustomAlert } from '../components/CustomAlert';
import { ErrorStateView } from '../components/ErrorState';
import { LoadingStateView } from '../components/LoadingState';
import { QRCodeView } from '../components/QrCodeView';
import { SuccessStateView } from '../components/SuccessState';
import { ShareButtonView } from '../components/ShareButton';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { WalkthroughPasswordView } from '../components/WalkthroughPassword';
import { AccountsService, AuthResult, AuthState } from '../common/AccountsService';
import { LookupNameResponse, LookupNameState, NameService } from '../common/NameService';
import { AccountModel } from '../model/AccountModel';
import { AvatarSize } from '../common/JamiConstants';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { PreferenceManager } from '../common/PreferenceManager';
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LinkToAccount';

/** Swift `QRCodeView(…, size: 200)` at this call site. */
const QR_CODE_SIZE: number = 200;

/* ── S5 metrics, the source's own (LinkToAccountView.swift:40-290) + S0047 ───────── */
/** Swift `VStack(spacing: 30)` — loadingView, portraitView and tokenLabel all use it. */
const SECTION_SPACING: number = 30;
/** Swift `VStack(spacing: 15)` — userInfoView and autenticatingView. */
const FIELD_SPACING: number = 15;
/** Swift `.padding()` / `.padding(.horizontal)` / `.padding(.top)` — the system 16 pt inset. */
const PAGE_INSET: number = 16;
/** Swift `.frame(maxWidth: 500)` on mainContent and on the token panel. */
const CONTENT_MAX_WIDTH: number = 500;
/** Swift `tokenContent` / `userInfoView`: `.cornerRadius(10)`, hardcoded in the source. */
const PANEL_RADIUS: number = 10;
/** Swift `CommonButtonStyle`: `.padding(.horizontal, 10).padding(.vertical, 12)`. */
const BUTTON_PADDING_H: number = 10;
const BUTTON_PADDING_V: number = 12;
/** Swift `CommonButtonStyle`: `.cornerRadius(10)`. */
const BUTTON_RADIUS: number = 10;
/** Swift `.opacity(viewModel.isImportButtonDisabled ? 0.5 : 1)`. */
const DISABLED_OPACITY: number = 0.5;
/** Swift `.lineSpacing(4)` on the `.callout` instruction blocks. */
const CALLOUT_LINE_HEIGHT: number = 20;
/** Capture: the inline nav bar is 44 pt tall (Back sits at y 60..90 under a 44 pt bar). */
const NAV_BAR_MIN_HEIGHT: number = 44;
/** Capture: the ActivityIndicator is 20x20 pt (x 186..206, y 232..252). */
const PROGRESS_SIZE: number = 20;
/** The segmented control: the track's own inset and each segment's vertical inset. */
const SEGMENT_TRACK_PADDING: number = 2;
const SEGMENT_PADDING: number = 6;
/** The unselected segment sits flat on the track; only the selected one is lifted. */
const NO_SHADOW: ShadowOptions = { radius: 0, color: Color.Transparent };
/** Swift `Color.jamiFailure` — `UIColor.jamiFailure = 0xf00000`, hardcoded in the source. */
const FAILURE_COLOR: string = '#F00000';
/** The iOS default tint (systemBlue): LinkToAccountView and its host set no `.accentColor`. */
const IOS_TINT_BLUE: string = '#007AFF';

/** Swift `enum LinkDeviceConstants.Keys` — the daemon's auth-state detail keys. */
const KEY_AUTH_SCHEME: string = 'auth_scheme';
const KEY_AUTH_ERROR: string = 'auth_error';
const KEY_PEER_ID: string = 'peer_id';
const KEY_TOKEN: string = 'token';
const KEY_ERROR: string = 'error';
/** Swift `LinkDeviceConstants.AuthScheme.password`. */
const AUTH_SCHEME_PASSWORD: string = 'password';

/** Swift `typealias DisplayMode = DeviceLinkingMode` — the two token presentations. */
enum DisplayMode {
  QR_CODE = 'QR_CODE',
  PIN = 'PIN'
}

/**
 * Swift `enum AuthError: String` + `func message()` — the VM's own mapping from the daemon's
 * error string to the text the error state shows.
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
  // Swift `.canceled: return "canceled"` — not a localized string in the source either.
  return raw;
}

@Entry
@Component
struct LinkThisDeviceToAnAccountPage {
  /**
   * Swift `@Published var token: String` — the export token the QR code encodes. Named for
   * the plan's stateVars entry (`qRCode` <- exportToken <- viewModel.token).
   */
  @State qRCode: string = '';
  /** Swift `@Published var password: String`. */
  @State password: string = '';
  /**
   * Swift `@Published var hasPassword: Bool = true` — whether the peer account is locked, i.e.
   * whether the password field exists. Named for the plan's stateVars entry (`passwordField`).
   */
  @State passwordField: boolean = true;
  /** Swift `@Published var authError: String?` — the message when the daemon reported one. */
  @State authError: ResourceStr = '';
  /** Swift `if let error = viewModel.authError` — whether there IS one. */
  @State hasAuthError: boolean = false;
  /** Swift `AvatarProvider.jamiId` — the peer id the daemon reports while authenticating. */
  @State jamiId: string = '';
  /** Swift `AvatarProvider.registeredName` — filled by the name lookup. */
  @State registeredName: string = '';
  /** Swift `.error(message:)`'s associated value. */
  @State errorMessage: ResourceStr = '';

  /** Swift `@SwiftUI.State private var displayMode: DisplayMode = .qrCode`. */
  @State isPinMode: boolean = false;
  /** Swift `@SwiftUI.State private var showAlert = false`. */
  @State showAlert: boolean = false;

  /* conditionalVariants[link_ui_state] — `viewModel.uiState`, one flag per case. */
  /** `uiState == .initial`. */
  @State isInitial: boolean = true;
  /** `uiState == .displayingToken`. */
  @State isDisplayingToken: boolean = false;
  /** `uiState == .connecting`. */
  @State isConnecting: boolean = false;
  /** `uiState == .authenticating`. */
  @State isAuthenticating: boolean = false;
  /** `uiState == .inProgress`. */
  @State isInProgress: boolean = false;
  /** `uiState == .success`. */
  @State isSuccess: boolean = false;
  /** `uiState == .error(message)`. */
  @State isError: boolean = false;

  /** True while this screen's services are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts when the account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `private var tempAccount: String?`. */
  private tempAccount: string = '';
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /** Swift `LinkToAccountVM.init` -> `self.start()`. */
  aboutToAppear(): void {
    this.start();
  }

  /**
   * Swift `.navigationBarBackButtonHidden(true)`: the system back takes the same path as the
   * toolbar BackButton, so it raises the stop-linking alert mid-import and otherwise removes
   * the temporary account before popping.
   */
  onBackPress(): boolean {
    this.cancelRequested();
    return true;
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscriptions go whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
    }
  }

  /** Swift `func start()` — `uiState = .initial`, observe, then create the temporary account. */
  private start(): void {
    this.setInitial();
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.setupDeviceAuthObserver(registry.accountService);
    this.isLoading = true;
    registry.accountService.createTemporaryAccount()
      .then((accountId: string): void => {
        this.tempAccount = accountId;
        this.isLoading = false;
      })
      .catch((error: Object): void => {
        this.isLoading = false;
        this.errorText = describeError(error as BusinessError);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'createTemporaryAccount failed: %{public}s', this.errorText);
        this.setError(this.errorText);
      });
  }

  /** Swift `setupDeviceAuthObserver()` — `authStateSubject.filter { $0.accountId == tempAccount }`. */
  private setupDeviceAuthObserver(accounts: AccountsService): void {
    this.bag.add(accounts.authStateSubject.subscribe((result: AuthResult): void => {
      if (result.accountId !== this.tempAccount) {
        return;
      }
      this.updateDeviceAuthState(result);
    }));
  }

  /**
   * Swift `checkNewStateValidity(newState:)` — which daemon states each ui state accepts.
   * Without it a late signal can drag the screen backwards out of .success or .error.
   */
  private checkNewStateValidity(newState: AuthState): boolean {
    if (this.isInitial) {
      return newState === AuthState.TOKEN_AVAILABLE || newState === AuthState.DONE;
    }
    if (this.isDisplayingToken) {
      return newState === AuthState.TOKEN_AVAILABLE || newState === AuthState.CONNECTING
        || newState === AuthState.DONE;
    }
    if (this.isConnecting) {
      return newState === AuthState.AUTHENTICATING || newState === AuthState.DONE;
    }
    if (this.isAuthenticating || this.isInProgress) {
      return newState === AuthState.IN_PROGRESS || newState === AuthState.DONE
        || newState === AuthState.AUTHENTICATING;
    }
    // Swift `.error, .success`.
    return newState === AuthState.DONE || newState === AuthState.AUTHENTICATING
      || newState === AuthState.IN_PROGRESS;
  }

  /** Swift `updateDeviceAuthState(result:)` — the state ladder the daemon publishes. */
  private updateDeviceAuthState(result: AuthResult): void {
    // Swift `guard checkNewStateValidity(newState: result.state) else { return }`.
    if (!this.checkNewStateValidity(result.state)) {
      return;
    }
    if (result.state === AuthState.TOKEN_AVAILABLE) {
      this.handleTokenAvailable(result.details);
    } else if (result.state === AuthState.CONNECTING) {
      this.setConnecting();
    } else if (result.state === AuthState.AUTHENTICATING) {
      this.handleAuthenticating(result.details);
    } else if (result.state === AuthState.IN_PROGRESS) {
      this.setInProgress();
    } else if (result.state === AuthState.DONE) {
      this.handleDone(result.details);
    }
  }

  /** Swift `handleTokenAvailable(details:)`. */
  private handleTokenAvailable(details: Map<string, string>): void {
    const token: string | undefined = details.get(KEY_TOKEN);
    if (token === undefined || token.length === 0) {
      this.setError($r('app.string.link_device_error_code'));
      return;
    }
    this.qRCode = token;
    this.setDisplayingToken();
  }

  /** Swift `handleAuthenticating(details:)`. */
  private handleAuthenticating(details: Map<string, string>): void {
    const scheme: string | undefined = details.get(KEY_AUTH_SCHEME);
    this.passwordField = scheme === AUTH_SCHEME_PASSWORD;
    const rawError: string | undefined = details.get(KEY_AUTH_ERROR);
    if (rawError !== undefined && rawError.length > 0) {
      this.authError = authErrorMessage(rawError);
      this.hasAuthError = true;
    }
    const peerId: string | undefined = details.get(KEY_PEER_ID);
    if (peerId === undefined) {
      return;
    }
    this.jamiId = peerId;
    // Swift `if self.registeredName.isEmpty { self.lookupUserName(jamiId: jamiId) }`.
    if (this.registeredName.length === 0) {
      this.lookupUserName(peerId);
    }
    this.setAuthenticating();
  }

  /**
   * Swift `lookupUserName(jamiId:)` — subscribe to the name service's lookup channel, filtered
   * on this jami hash, then ask for the address. Both halves are disposed with the page.
   */
  private lookupUserName(jamiId: string): void {
    if (this.tempAccount.length === 0) {
      return;
    }
    const names: NameService = ServiceRegistry.shared().nameService;
    this.bag.add(names.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
      if (response.requestedName !== jamiId) {
        return;
      }
      if (response.state === LookupNameState.FOUND && response.name.length > 0) {
        this.registeredName = response.name;
      }
    }));
    names.lookupAddress(this.tempAccount, '', jamiId);
  }

  /** Swift `handleDone(details:)`. */
  private handleDone(details: Map<string, string>): void {
    const rawError: string | undefined = details.get(KEY_ERROR);
    if (rawError !== undefined && rawError.length > 0 && rawError !== 'none') {
      this.setError(authErrorMessage(rawError));
      return;
    }
    this.setSuccess();
  }

  /* Swift `withAnimation { uiState = … }` — one case true at a time, so the seven branches
   * below are mutually exclusive by construction. */
  private clearState(): void {
    this.isInitial = false;
    this.isDisplayingToken = false;
    this.isConnecting = false;
    this.isAuthenticating = false;
    this.isInProgress = false;
    this.isSuccess = false;
    this.isError = false;
  }

  private setInitial(): void {
    this.clearState();
    this.isInitial = true;
  }

  private setDisplayingToken(): void {
    this.clearState();
    this.isDisplayingToken = true;
  }

  private setConnecting(): void {
    this.clearState();
    this.isConnecting = true;
  }

  private setAuthenticating(): void {
    this.clearState();
    this.isAuthenticating = true;
  }

  private setInProgress(): void {
    this.clearState();
    this.isInProgress = true;
  }

  private setSuccess(): void {
    this.clearState();
    this.isSuccess = true;
  }

  private setError(message: ResourceStr): void {
    this.clearState();
    this.errorMessage = message;
    this.isError = true;
  }

  /** Swift `viewModel.isImportButtonDisabled` — `uiState != .authenticating`. */
  private isImportButtonDisabled(): boolean {
    return !this.isAuthenticating;
  }

  /** Swift `shouldShowAlert()` — `!uiState.isCancelableState()`: mid-import, cancelling warns. */
  private shouldShowAlert(): boolean {
    return this.isConnecting || this.isAuthenticating || this.isInProgress;
  }

  /** Swift `func cancelRequested()`. */
  private cancelRequested(): void {
    if (this.shouldShowAlert()) {
      this.showAlert = true;
      return;
    }
    this.cancel();
  }

  /** Swift `func cancel()` — `dismissHandler.dismissView()` then `viewModel.onCancel()`. */
  private cancel(): void {
    this.showAlert = false;
    this.onCancel();
    router.back();
  }

  /** Swift `func onCancel()` — the temporary account is removed if one was made. */
  private onCancel(): void {
    if (this.tempAccount.length === 0) {
      return;
    }
    ServiceRegistry.shared().accountService.removeAccountById(this.tempAccount);
    this.tempAccount = '';
  }

  /** Swift `func connect()` — `handleInProgress()` then `provideAccountAuthentication(…)`. */
  private connect(): void {
    this.errorText = '';
    this.setInProgress();
    // Swift `if let tempAccountId = tempAccount { … }`.
    if (this.tempAccount.length === 0) {
      return;
    }
    ServiceRegistry.shared().accountService
      .provideAccountAuthentication(this.tempAccount, this.password);
  }

  /** Swift `func linkCompleted()` — the imported account becomes current, then `linkAction()`. */
  private linkCompleted(): void {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    if (this.tempAccount.length > 0) {
      const account: AccountModel | null = accounts.getAccount(this.tempAccount);
      if (account !== null) {
        accounts.updateCurrentAccount(account);
        // Swift: `sharedDefaults.set(accountId, forKey: Constants.selectedAccountID)`.
        PreferenceManager.setSelectedAccountId(account.id);
        this.currentAccountId = account.id;
      }
    }
    // Swift `linkAction()` = `WelcomeVM.linkDeviceCompleted` -> `accountCreated` -> the
    // walkthrough finishes. The welcome screen owns that completion, so it is told to finish as
    // it comes back on top (updateCurrentAccount emits nothing when the account already heads
    // the list, i.e. for a first account, so the change itself cannot be the signal).
    router.back({ url: 'pages/WelcomeOnboardingPage', params: { walkthroughCompleted: true } });
  }

  /** Swift `getShareInfo()` — `L10n.LinkToAccount.shareMessage(token)`. */
  private shareInfo(): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync('link_to_account_share_message')
      .replace('%s', this.qRCode);
  }

  /** Swift: the token's `contextMenu` copy action (UIPasteboard). */
  private copyToken(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ShareActions.copyToClipboard(context, this.qRCode)
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'copyToken failed: %{public}s', this.errorText);
      });
  }

  /**
   * Swift `info` — one composed Text: exportInstructions + the bold path + the mode-dependent
   * closing line (`scanQrCode` in QR mode, `enterProvidedCode` in PIN mode).
   */
  @Builder
  private info() {
    // Swift: one concatenated Text, `.multilineTextAlignment(.center).font(.callout)
    // .lineSpacing(4).frame(maxWidth: 500)` — the middle line is `.bold()`.
    Column() {
      Text($r('app.string.link_to_account_export_instructions'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .lineHeight(CALLOUT_LINE_HEIGHT)
      Text($r('app.string.link_to_account_export_instructions_path'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
        .lineHeight(CALLOUT_LINE_HEIGHT)
      if (this.isPinMode) {
        Text($r('app.string.link_to_account_enter_provided_code'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.label'))
          .lineHeight(CALLOUT_LINE_HEIGHT)
      } else {
        Text($r('app.string.link_to_account_scan_qr_code'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.label'))
          .lineHeight(CALLOUT_LINE_HEIGHT)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
  }

  /**
   * Swift `ModeSelectorView(selectedMode: $displayMode, isLinkToAccount: true)` — a segmented
   * Picker over DeviceLinkingMode, `.accessibilityIdentifier("deviceLinkingModePicker")`.
   * ArkUI has no segmented picker, so it is the same two choices as a two-segment row; the
   * source's own slug stays on the control and each segment is addressable under it.
   */
  @Builder
  private modeSelector() {
    // Swift `.pickerStyle(SegmentedPickerStyle())`: a gray track with the selected segment
    // lifted out in white — composed here, since ArkUI has no segmented Picker. The track is
    // the iOS fill (comp_background_secondary), NOT the page gray, or it vanishes into the page;
    // the unselected segment is transparent on it.
    Row() {
      Button($r('app.string.link_to_account_show_qr_code'))
        .id('deviceLinkingModePickerQrCode')
        .layoutWeight(1)
        .type(ButtonType.Normal)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .fontWeight(this.isPinMode ? FontWeight.Normal : FontWeight.Medium)
        .backgroundColor(this.isPinMode ? Color.Transparent : $r('sys.color.comp_background_list_card'))
        .shadow(this.isPinMode ? NO_SHADOW : ShadowStyle.OUTER_DEFAULT_XS)
        .borderRadius(PANEL_RADIUS - SEGMENT_TRACK_PADDING)
        .padding({ top: SEGMENT_PADDING, bottom: SEGMENT_PADDING })
        .onClick(() => {
          this.isPinMode = false;
        })
      Button($r('app.string.link_to_account_show_pin_code'))
        .id('deviceLinkingModePickerPin')
        .layoutWeight(1)
        .type(ButtonType.Normal)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .fontWeight(this.isPinMode ? FontWeight.Medium : FontWeight.Normal)
        .backgroundColor(this.isPinMode ? $r('sys.color.comp_background_list_card') : Color.Transparent)
        .shadow(this.isPinMode ? ShadowStyle.OUTER_DEFAULT_XS : NO_SHADOW)
        .borderRadius(PANEL_RADIUS - SEGMENT_TRACK_PADDING)
        .padding({ top: SEGMENT_PADDING, bottom: SEGMENT_PADDING })
        .onClick(() => {
          this.isPinMode = true;
        })
    }
    .id('deviceLinkingModePicker')
    .width('100%')
    .padding(SEGMENT_TRACK_PADDING)
    .backgroundColor($r('sys.color.comp_background_secondary'))
    .borderRadius(PANEL_RADIUS)
  }

  /** Swift: the `contextMenu` on the token label. */
  @Builder
  private tokenMenu() {
    Menu() {
      MenuItem({
        content: $r('app.string.global_copy'),
        symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.doc_filled_on_doc'))
      })
        .id('linkToAccountCopyToken')
        .onClick(() => {
          this.copyToken();
        })
    }
  }

  /**
   * Swift `ShareButtonView(infoToShare:)`'s default label (UtilitiesViews.swift:81):
   * `Label(L10n.Global.share, systemImage: "square.and.arrow.up.fill").commonButtonStyle()`.
   * The glyph is `sys.symbol.upload`, the same square.and.arrow.up match DiagnosticsLogPage uses.
   */
  @Builder
  private shareLabel() {
    Row({ space: BUTTON_PADDING_H }) {
      SymbolGlyph($r('sys.symbol.upload'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor([$r('app.color.label')])
      Text($r('app.string.global_share'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: BUTTON_PADDING_H,
      right: BUTTON_PADDING_H,
      top: BUTTON_PADDING_V,
      bottom: BUTTON_PADDING_V
    })
    .backgroundColor($r('app.color.jami_tertiary_control'))
    .borderRadius(BUTTON_RADIUS)
  }

  /** Swift `tokenLabel` — the token text with its copy menu, over the share button. */
  @Builder
  private tokenLabel() {
    // Swift `VStack(spacing: 30) { Text(token).font(.footnote); ShareButtonView }`.
    Column({ space: SECTION_SPACING }) {
      Text(this.qRCode)
        .id('linkToAccountToken')
        .width('100%')
        // Swift `Text(token)` with no multilineTextAlignment — leading.
        .textAlign(TextAlign.Start)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.label'))
        .bindContextMenu(this.tokenMenu, ResponseType.LongPress)
      ShareButtonView({
        infoToShare: this.shareInfo(),
        identifier: 'linkToAccountShareToken',
        titleResourceName: 'global_share',
        rowInsets: false,
        content: this.shareLabel
      })
    }
    .width('100%')
  }

  /** Swift `tokenContent` — `if displayMode == .pin { tokenLabel } else { qrCodeView }`. */
  @Builder
  private tokenContent() {
    // Swift `Group { … }.padding().background(secondarySystemGroupedBackground)
    // .cornerRadius(10).padding(.horizontal)` — the white panel around either presentation.
    // The outer `.padding(.horizontal)` is a wrapper's padding: a margin on a 100%-wide panel
    // only overflowed the column, leaving the panel as wide as the mode selector.
    Column() {
      Column() {
        if (this.isPinMode) {
          this.tokenLabel()
        } else {
          // Swift `qrCodeView` — QRCodeView(jamiId: viewModel.token, …, size: 200). The code is
          // GENERATED from the live token; bindingContract forbids a bundled placeholder.
          QRCodeView({
            jamiId: this.qRCode,
            accessibilityLabel: $r('app.string.accessibility_account_summary_qr_code'),
            qrSize: QR_CODE_SIZE
          })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      .padding(PAGE_INSET)
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(PANEL_RADIUS)
    }
    .width('100%')
    .padding({ left: PAGE_INSET, right: PAGE_INSET })
  }

  /** Swift `userInfoView` — avatar, registered name (when there is one) and the jami id. */
  @Builder
  private userInfoView() {
    Column({ space: FIELD_SPACING }) {
      AvatarSwiftUIView({
        displayText: this.registeredName.length > 0 ? this.registeredName : this.jamiId,
        avatarSize: AvatarSize.ACCOUNT_60
      })
      if (this.registeredName.length > 0) {
        Text(this.registeredName)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
      }
      // Swift `Text(viewModel.jamiId).font(.callout)`.
      Text(this.jamiId)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.padding().background(secondarySystemGroupedBackground).cornerRadius(10)`.
    .padding(PAGE_INSET)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(PANEL_RADIUS)
  }

  /** Swift `passwordView` — the locked-account prompt, the field, and the auth error. */
  @Builder
  private passwordView() {
    Column({ space: FIELD_SPACING }) {
      // Swift `Text(accountLockedWithPassword).font(.callout).lineSpacing(4)`.
      Text($r('app.string.link_to_account_account_locked_with_password'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .lineHeight(CALLOUT_LINE_HEIGHT)
      WalkthroughPasswordView({
        text: $password,
        placeholder: $r('app.string.global_password'),
        identifier: 'linkToAccountPassword'
      })
      // Swift `if let error = viewModel.authError { Text(error) … }`.
      if (this.hasAuthError) {
        // Swift `.foregroundColor(Color.jamiFailure).font(.footnote)`.
        Text(this.authError)
          .id('linkToAccountAuthError')
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_S'))
          .fontColor(FAILURE_COLOR)
      }
    }
    .width('100%')
    // Swift `passwordView.padding(.top)` at the autenticatingView call site.
    .margin({ top: PAGE_INSET })
  }

  /** Swift `autenticatingView`. */
  @Builder
  private authenticatingView() {
    Scroll() {
      // Swift `VStack(spacing: 15) { … }.padding(.horizontal)`.
      Column({ space: FIELD_SPACING }) {
        this.userInfoView()
        // bindingContract: the password field exists only when `viewModel.hasPassword`.
        if (this.passwordField) {
          this.passwordView()
        }
        // Swift `Text(importAccount).commonButtonStyle()` — the label's own color, 10/12
        // insets, full width, jamiTertiaryControl plate, 10 pt corner — plus
        // `.opacity(isImportButtonDisabled ? 0.5 : 1)`.
        Button($r('app.string.link_to_account_import_account'))
          .id('linkToAccountImport')
          .width('100%')
          .type(ButtonType.Normal)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .backgroundColor($r('app.color.jami_tertiary_control'))
          .borderRadius(BUTTON_RADIUS)
          .padding({
            left: BUTTON_PADDING_H,
            right: BUTTON_PADDING_H,
            top: BUTTON_PADDING_V,
            bottom: BUTTON_PADDING_V
          })
          .opacity(this.isImportButtonDisabled() ? DISABLED_OPACITY : 1)
          .enabled(!this.isImportButtonDisabled())
          .onClick(() => {
            this.connect();
          })
        Blank()
      }
      .width('100%')
      .padding({ left: PAGE_INSET, right: PAGE_INSET })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /** Swift `portraitView` — the .displayingToken body (landscape re-arranges the same three). */
  @Builder
  private tokenView() {
    Scroll() {
      // Swift `portraitView` — `VStack(spacing: 30) { info; tokenDisplay; Spacer() }`.
      Column({ space: SECTION_SPACING }) {
        this.info()
        // Swift `tokenDisplay` = ModeSelectorView + tokenContent.
        this.modeSelector()
        this.tokenContent()
        Blank()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /** Swift `alertContent()` — the confirm-cancel alert raised by `cancelRequested()`. */
  @Builder
  private cancelAlertBody() {
    Column({ space: FIELD_SPACING }) {
      // iOS alert: bold title over a smaller gray message, both centred.
      Text($r('app.string.link_to_account_alert_tile'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
      Text($r('app.string.link_to_account_alert_message'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
      Row({ space: PAGE_INSET }) {
        // Swift `.secondaryButton: .cancel()`.
        Button($r('app.string.global_cancel'))
          .id('linkToAccountAlertCancel')
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .fontSize($r('sys.float.Body_L'))
          // A system alert's `.cancel()` button is the bold one.
          .fontWeight(FontWeight.Medium)
          // A system alert's buttons take the tint; Swift's `.cancel()` sets no colour.
          .fontColor(IOS_TINT_BLUE)
          .backgroundColor($r('sys.color.comp_background_gray'))
          .borderRadius(BUTTON_RADIUS)
          .padding({ top: BUTTON_PADDING_V, bottom: BUTTON_PADDING_V })
          .onClick(() => {
            this.showAlert = false;
          })
        // Swift `.primaryButton: .destructive(Text(L10n.Global.confirm), action: cancel)` —
        // a destructive action is red on iOS.
        Button($r('app.string.global_confirm'))
          .id('linkToAccountAlertConfirm')
          .layoutWeight(1)
          .type(ButtonType.Normal)
          .fontSize($r('sys.float.Body_L'))
          .fontColor(FAILURE_COLOR)
          .backgroundColor($r('sys.color.comp_background_gray'))
          .borderRadius(BUTTON_RADIUS)
          .padding({ top: BUTTON_PADDING_V, bottom: BUTTON_PADDING_V })
          .onClick(() => {
            this.cancel();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(PAGE_INSET)
  }

  build() {
    Stack() {
      Column() {
        // Swift `.toolbar { ToolbarItem(.navigationBarLeading) { BackButton(action:
        // cancelRequested) } }` over `.navigationTitle(L10n.LinkToAccount.importAccount)`
        // `.navigationBarBackButtonHidden(true)`.
        // `.navigationBarTitleDisplayMode(.inline)`: iOS centres the title in the SAME optical
        // row as the leading item (capture: Back y 60..90, title y 65..85, centred on x 196
        // of 393). ArkUI has no such default, so the bar is composed explicitly.
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

          Text($r('app.string.link_to_account_import_account'))
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .constraintSize({ minHeight: NAV_BAR_MIN_HEIGHT })
        // Swift's `mainContent.padding()` also insets the TOP, but the system bar it sits
        // under is not part of mainContent — so the top inset belongs between the composed
        // bar and the content (capture: the instruction block starts ~16 pt under the bar).
        .margin({ bottom: PAGE_INSET })

        // Swift `mainContent` — the 7-way switch on uiState.
        if (this.isInitial) {
          // Swift `loadingView` — `VStack(spacing: 30) { info; ProgressView(); Spacer() }`.
          Column({ space: SECTION_SPACING }) {
            this.info()
            LoadingProgress()
              .width(PROGRESS_SIZE)
              .height(PROGRESS_SIZE)
              .color($r('app.color.jami'))
            Blank()
          }
          .layoutWeight(1)
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        } else if (this.isDisplayingToken) {
          this.tokenView()
        } else if (this.isConnecting) {
          // Swift `connectingView` — VStack { Text(actionRequired); Spacer() }, the text
          // `.font(.callout).lineSpacing(4)`.
          Column() {
            Text($r('app.string.link_to_account_action_required'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.label'))
              .lineHeight(CALLOUT_LINE_HEIGHT)
            Blank()
          }
          .layoutWeight(1)
          .width('100%')
        } else if (this.isAuthenticating) {
          this.authenticatingView()
        } else if (this.isInProgress) {
          // Swift `inProgressView` — a centred ProgressView with no message.
          LoadingStateView({ message: '' })
        } else if (this.isSuccess) {
          // Swift `successView()`.
          SuccessStateView({
            message: $r('app.string.link_to_account_all_set'),
            buttonTitle: $r('app.string.link_to_account_go_to_accounts'),
            identifier: 'linkToAccountGoToAccounts',
            action: () => {
              this.linkCompleted();
            }
          })
        } else if (this.isError) {
          // Swift `errorView(message)`.
          ErrorStateView({
            message: this.errorMessage,
            buttonTitle: $r('app.string.link_to_account_exit'),
            identifier: 'linkToAccountExit',
            action: () => {
              this.cancel();
            }
          })
        }

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .padding(PAGE_INSET)
        }
      }
      .width('100%')
      .height('100%')
      // Swift `mainContent.padding().frame(maxWidth: 500)` — the page's own 16 pt inset
      // (capture: the instruction block sits inside x 16..377 of 393).
      // The 16 pt side inset covers the bar (capture: Back at x 16) and mainContent alike.
      .padding({ left: PAGE_INSET, right: PAGE_INSET, bottom: PAGE_INSET })

      // Swift `.alert(isPresented: $showAlert, content: alertContent)`.
      if (this.showAlert) {
        CustomAlert() {
          this.cancelAlertBody()
        }
      }
    }
    .width('100%')
    .height('100%')
    // Swift `.background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())` —
    // capture: #F2F2F7 edge to edge.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_link_to_account')
  }
}
