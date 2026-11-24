/*
 * screen_jams_connect — "Connect to a JAMS Server", ported from
 *   Ring/Ring/Features/Walkthrough/Views/JamsConnectView.swift
 *   Ring/Ring/Features/Walkthrough/Models/ConnectToManagerVM.swift
 *   Ring/Ring/Features/Walkthrough/Models/WelcomeVM.swift   (connectToAccountManager)
 *
 * presentation: modal, hostScreen: screen_welcome. WalkthroughCoordinator.showConnectJAMS()
 * presents JamsConnectView .formModal, so it is a @CustomDialog mounted by
 * WelcomeOnboardingPage — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — the real component tree of `JamsConnectView.body`:
 *   VStack {
 *     header: ZStack { HStack { cancelButton; Spacer; signinButton }; Text(title).headline }
 *     ScrollView {
 *       Text(jamsExplanation)
 *       serverView        // WalkthroughFocusableTextView("jamsConnectServer")
 *       Text(enterCredentials)
 *       usernameView      // WalkthroughTextEditView("jamsConnectUsername")
 *       passwordView      // WalkthroughPasswordView("jamsConnectPassword")
 *     }
 *   }
 *
 * `WalkthroughFocusableTextView` is `WalkthroughTextEditView` plus the first-responder
 * binding, which the ported component already carries (`isFocused`), so both fields are the
 * one component — the source's own view model starts focused (`isTextFieldFocused = true`).
 *
 * `viewModel.isSignInDisabled = username.isEmpty || password.isEmpty || server.isEmpty` is
 * the source's REAL gate on Sign in, so it is the condition here, not an invented one.
 *
 * A failed sign-in keeps the sheet up and shows Swift's `AccountCreationError` title and message
 * (CreateAccountVM.swift) in place — conditionalVariants[error].
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WalkthroughTextEditView } from '../components/WalkthroughTextEdit';
import { WalkthroughPasswordView } from '../components/WalkthroughPassword';
import { AccountCreationError, AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'JamsConnect';

/* ── S5 metrics, from the source (JamsConnectView.swift:32-104) + the S0055 capture ── */
/**
 * The ScrollView's implicit VStack spacing — capture: the Username pill ends at y 350 and the
 * Password pill starts at y 358 (393x852 pt).
 */
const FIELD_SPACING: number = 8;
/** Swift `Text(...).padding(.vertical)` around the two explanation lines. */
const BLOCK_INSET: number = 16;
/** Swift `.frame(maxWidth: 500)` on the scroll content. */
const CONTENT_MAX_WIDTH: number = 500;
/** `.formModal` leaves the top of the screen showing (capture: the sheet starts at y 69/852). */
const SHEET_HEIGHT: string = '92%';
/** Breathing room between the header title and the Cancel / Sign in labels beside it. */
const HEADER_TITLE_GAP: number = 8;

@CustomDialog
export struct JamsConnectOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /**
   * Owned by screen_welcome (Swift: WalkthroughCoordinator owns the presented VC), so the
   * sheet can dismiss itself while the host stays the single writer of "is it up".
   */
  @Link isPresented: boolean;

  /** Swift `@Published var server: String = ""`. */
  @State @Watch('onCredentialsChanged') private server: string = '';
  /** Swift `@Published var username: String = ""`. */
  @State @Watch('onCredentialsChanged') private username: string = '';
  /** Swift `@Published var password: String = ""`. */
  @State @Watch('onCredentialsChanged') private password: string = '';
  /** Swift `@Published var isTextFieldFocused: Bool = true` — the server field starts focused. */
  @State private isServerFocused: boolean = true;
  /** The username field is the plain `WalkthroughTextEditView`, i.e. no source focus binding. */
  @State private isUsernameFocused: boolean = false;
  /** Swift `var isSignInDisabled` — all three fields must be non-empty. */
  @State private isSignInDisabled: boolean = true;

  /** conditionalVariants[error]: ConnectToManagerVM's sign-in reports a failure. */
  @State isError: boolean = false;
  /** True while the sign-in is in flight. */
  @State isLoading: boolean = false;
  /** The rejected creation's `AccountCreationError` (or any other message: `.unknown`). */
  @State private creationError: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts when the account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `isSignInDisabled: username.isEmpty || password.isEmpty || server.isEmpty`. */
  private onCredentialsChanged(_propName: string): void {
    this.isSignInDisabled =
      this.username.length === 0 || this.password.length === 0 || this.server.length === 0;
  }

  /** Swift: `dismissHandler.dismissView()` behind the Cancel button. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `signinButton`: `dismissHandler.dismissView()` then `viewModel.connect()`, which
   * calls `connectAction(username, password, server)` only when the form is complete; that
   * closure is `WelcomeVM.connectToAccountManager` ->
   * `accountService.connectToAccountManager(username:password:serverUri:)`.
   *
   * The sheet is NOT dismissed first here: it stays up with the spinner and, on failure, shows
   * the error in place, so the user can correct the form (TC-ONBOARD-186).
   */
  private signIn(): void {
    // Swift `func connect() { if !isSignInDisabled { … } }`.
    if (this.isSignInDisabled || this.isLoading) {
      return;
    }
    this.isError = false;
    this.isLoading = true;
    // Sign in is tapped with the keyboard up, and the host mounts this sheet with
    // KeyboardAvoidMode.NONE, so the spinner and the error below the password field sat under
    // the keyboard and the tap looked dead (TC-ONBOARD-184). Swift dismisses the sheet here.
    this.getUIContext().getFocusController().clearFocus();
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    accounts.connectToAccountManager(this.username, this.password, this.server)
      .then((): void => {
        // The host (screen_welcome) observes the creation and finishes the walkthrough.
        this.isLoading = false;
        this.dismiss();
      })
      .catch((error: Object): void => {
        this.isLoading = false;
        this.creationError = error instanceof Error ? error.message : '';
        this.isError = true;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'JAMS sign-in failed: %{public}s', this.creationError);
      });
  }

  /** Swift `AccountCreationError.title`. */
  private errorTitle(): ResourceStr {
    if (this.creationError === AccountCreationError.GENERIC ||
      this.creationError === AccountCreationError.LINK_ERROR) {
      return $r('app.string.alerts_account_cannot_be_found_title');
    }
    if (this.creationError === AccountCreationError.NETWORK) {
      return $r('app.string.alerts_account_no_network_title');
    }
    if (this.creationError === AccountCreationError.WRONG_CREDENTIALS) {
      return $r('app.string.alerts_error_wrong_credentials');
    }
    return $r('app.string.alerts_account_default_error_title');
  }

  /** Swift `AccountCreationError.message` — `.wrongCredentials` deliberately carries none. */
  private errorMessage(): ResourceStr {
    if (this.creationError === AccountCreationError.NETWORK) {
      return $r('app.string.alerts_account_no_network_message');
    }
    if (this.creationError === AccountCreationError.LINK_ERROR) {
      return $r('app.string.alerts_account_cannot_be_found_message');
    }
    if (this.creationError === AccountCreationError.WRONG_CREDENTIALS) {
      return '';
    }
    return $r('app.string.alerts_account_default_error_message');
  }

  /**
   * Swift `header` — ZStack { HStack { cancel; Spacer; sign in }; Text(title).headline }.
   * SwiftUI's ZStack leaves the title in the gap between the buttons; an ArkUI Stack does not,
   * and on a narrow (folded) screen "Management server account" painted over both labels. The
   * title is therefore the middle child of the Row, given only the width the buttons leave.
   */
  @Builder
  private header() {
    Row() {
      // Swift `cancelButton` — `Text(L10n.Global.cancel).foregroundColor(UIColor.label)`.
      Button($r('app.string.global_cancel'))
        .id('jamsConnectCancel')
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .padding(0)
        .onClick(() => {
          this.dismiss();
        })

      // Swift `Text(L10n.LinkToAccountManager.title).font(.headline)`.
      Text($r('app.string.link_to_account_manager_title'))
        .layoutWeight(1)
        .margin({ left: HEADER_TITLE_GAP, right: HEADER_TITLE_GAP })
        .textAlign(TextAlign.Center)
        .maxFontSize($r('sys.float.Body_L'))
        .minFontSize($r('sys.float.Body_M'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // Swift `signinButton` — `.disabled(viewModel.isSignInDisabled)`, tinted
      // `signInButtonColor = isSignInDisabled ? secondaryLabel : .jami` off the SAME field.
      Button($r('app.string.link_to_account_manager_sign_in'))
        .id('jamsConnectSignIn')
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .fontSize($r('sys.float.Body_L'))
        .fontColor(this.isSignInDisabled
          ? $r('app.color.secondary_label')
          : $r('app.color.jami'))
        .padding(0)
        .enabled(!this.isSignInDisabled)
        .onClick(() => {
          this.signIn();
        })
    }
    .width('100%')
    // Swift `header.padding()` — capture: Cancel starts at x 16, y 85 under a sheet top of 69.
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
  }

  build() {
    // Swift `VStack { header; ScrollView { … } }.frame(maxWidth: .infinity, maxHeight: .infinity)`.
    Column() {
      this.header()

      Scroll() {
        Column({ space: FIELD_SPACING }) {
          // Swift `Text(jamsExplanation).multilineTextAlignment(.center).padding(.vertical)`.
          Text($r('app.string.link_to_account_manager_jams_explanation'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)
            .margin({ top: BLOCK_INSET, bottom: BLOCK_INSET })

          // Swift `serverView` — WalkthroughFocusableTextView(text: $viewModel.server, …).
          // The white rounded pill (10 pt corner, 10/12 insets) is the component's own.
          WalkthroughTextEditView({
            text: $server,
            placeholder: $r('app.string.link_to_account_manager_account_manager_placeholder'),
            identifier: 'jamsConnectServer',
            // Swift `isTextFieldFocused: $viewModel.isTextFieldFocused`.
            isFocused: $isServerFocused,
            // iOS JamsConnectView attaches no accessibility text to the field (T-1612).
            spokenText: ''
          })

          // Swift `Text(enterCredentials).padding(.vertical)`.
          Text($r('app.string.link_to_account_manager_enter_credentials'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)
            .margin({ top: BLOCK_INSET, bottom: BLOCK_INSET })

          // Swift `usernameView`.
          WalkthroughTextEditView({
            text: $username,
            placeholder: $r('app.string.global_username'),
            identifier: 'jamsConnectUsername',
            isFocused: $isUsernameFocused,
            spokenText: ''
          })

          // Swift `passwordView` — carries the show/hide toggle (`passwordVisibilityToggle`).
          WalkthroughPasswordView({
            text: $password,
            placeholder: $r('app.string.global_password'),
            identifier: 'jamsConnectPassword'
          })

          if (this.isLoading) {
            LoadingProgress()
              .width(BLOCK_INSET * 2)
              .height(BLOCK_INSET * 2)
              .color($r('app.color.jami'))
          }

          // conditionalVariants[error] — the sign-in failure branch.
          if (this.isError) {
            Column({ space: FIELD_SPACING }) {
              Text(this.errorTitle())
                .fontSize($r('sys.float.Body_L'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.label'))
                .textAlign(TextAlign.Center)
              if (this.creationError !== AccountCreationError.WRONG_CREDENTIALS) {
                Text(this.errorMessage())
                  .fontSize($r('sys.float.Body_M'))
                  .fontColor($r('app.color.secondary_label'))
                  .textAlign(TextAlign.Center)
              }
            }
            .id('jams_connect_error')
            .width('100%')
            .margin({ top: BLOCK_INSET })
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      // Swift `ScrollView(showsIndicators: false)` + `.padding(.horizontal)` — capture: the
      // pills span x 16..377 of 393.
      .scrollBar(BarState.Off)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })
    }
    .width('100%')
    // `.formModal` over the walkthrough wallpaper; Swift paints the body
    // `systemGroupedBackground` (capture: #F2F2F7) edge to edge behind it.
    .height(SHEET_HEIGHT)
    .backgroundColor($r('sys.color.background_secondary'))
    // Swift `.background(systemGroupedBackground.ignoresSafeArea())` — the grey runs under the
    // navigation indicator instead of stopping above it and showing the wallpaper.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .borderRadius({
      topLeft: $r('sys.float.ohos_id_corner_radius_default_m'),
      topRight: $r('sys.float.ohos_id_corner_radius_default_m')
    })
    .clip(true)
    .id('screen_jams_connect')
  }
}
