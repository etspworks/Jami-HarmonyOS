/*
 * screen_sip_configuration — "Add a SIP Account", ported from
 *   Ring/Ring/Features/Walkthrough/Views/SIPConfigurationView.swift
 *   Ring/Ring/Features/Walkthrough/Models/ConnectSipVM.swift
 *   Ring/Ring/Features/Walkthrough/Models/WelcomeVM.swift   (createSipAccount)
 *
 * presentation: modal, hostScreen: screen_welcome. WalkthroughCoordinator.showConnectSIP()
 * presents SIPConfigurationView .formModal, so it is a @CustomDialog mounted by
 * WelcomeOnboardingPage — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — the real component tree of `SIPConfigurationView.body`:
 *   VStack {
 *     header: ZStack { HStack { cancelButton; Spacer; configureButton }; Text(sipAccount).headline }
 *     ScrollView(showsIndicators: false) {
 *       Text(L10n.CreateAccount.sipConfigure)
 *       serverView        // WalkthroughFocusableTextView("sipConfigurationServer")
 *       usernameView      // WalkthroughTextEditView("sipConfigurationUsername")
 *       passwordView      // WalkthroughPasswordView("sipConfigurationPassword")
 *     }
 *     .frame(maxWidth: 500)
 *   }
 *
 * `WalkthroughFocusableTextView` is `WalkthroughTextEditView` plus the first-responder
 * binding, which the ported component already carries (`isFocused`), so both text fields are
 * the one component — ConnectSipVM starts `isTextFieldFocused = true`, i.e. the SERVER field.
 *
 * The source declares no validation (`connect()` forwards whatever the three fields hold), so
 * none is invented here. `addSipAccount` makes the new account current, which is what finishes
 * the walkthrough on the host. On failure Swift takes `setState(.error(.unknown))`; the sheet
 * stays up and shows that error in place instead of dismissing into silence.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import { WalkthroughTextEditView } from '../components/WalkthroughTextEdit';
import { WalkthroughPasswordView } from '../components/WalkthroughPassword';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SipConfiguration';

/*
 * S5 — the values the SOURCE hardcodes, copied verbatim rather than tokenised (the token rule's
 * one exception). SwiftUI's bare `.padding()` / `.padding(.vertical)` / `.padding(.horizontal)`
 * is 16pt, and `.frame(maxWidth: 500)` caps the field column on a wide screen.
 * Capture cross-check (S0060, points on a 393x852 screen): header band 85..105 inside a 16pt
 * pad, subtitle 145..165, field cards 190..235 / 244..289 / 297..343 — i.e. a default 8pt VStack
 * gap between the fields, which is `Column({ space: FIELD_GAP })`.
 */
const SHEET_PADDING: number = 16;
const FIELD_GAP: number = 8;
const CONTENT_MAX_WIDTH: number = 500;
const SPINNER_SIZE: number = 32;
/** S6 — how far the form recedes while the account is being created. */
const CONTENT_DIM: number = 0.4;
/** SwiftUI `.headline` = 17pt semibold; ArkUI spells semibold as the numeric weight 600. */
const TITLE_WEIGHT: number = 600;
/** `.formModal` leaves the walkthrough wallpaper showing above the sheet (capture: top at 68pt). */
const SHEET_HEIGHT: string = '92%';

@CustomDialog
export struct AddASIPAccountOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /**
   * Owned by screen_welcome (Swift: WalkthroughCoordinator owns the presented VC), so the
   * modal can dismiss itself while the host stays the single writer of "is it up".
   */
  @Link isPresented: boolean;

  /** Swift `@Published var server: String = ""`. */
  @State private server: string = '';
  /** Swift `@Published var username: String = ""`. */
  @State private username: string = '';
  /** Swift `@Published var password: String = ""`. */
  @State private password: string = '';
  /** Swift `@Published var isTextFieldFocused: Bool = true` — the server field starts focused. */
  @State private isServerFocused: boolean = true;
  /** The username field is the plain `WalkthroughTextEditView`, i.e. no source focus binding. */
  @State private isUsernameFocused: boolean = false;

  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** Swift `.error(.unknown)`: the creation failed. */
  @State private showError: boolean = false;
  /** AppStorage['currentAccountId'], written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `cancelButton`: `dismissHandler.dismissView()`. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `configureButton` -> `ConnectSipVM.connect()` ->
   * `connectAction(username, password, server)`, which WelcomeVM binds to
   * `createSipAccount(userName:password:server:)` ->
   * `accountService.addSipAccount(userName:password:sipServer:)`.
   *
   * Swift's argument ORDER is (username, password, server) at the closure and
   * (userName, password, sipServer) at the service — carried over verbatim.
   */
  private async configure(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.showError = false;
    this.isLoading = true;
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const created: boolean = await accounts.addSipAccount(this.username, this.password, this.server);
    this.isLoading = false;
    if (created) {
      // Swift `accountCreated(stateHandler:)` — the host finishes the walkthrough.
      this.dismiss();
      return;
    }
    // Swift `setState(state: .error(error: .unknown))`.
    this.showError = true;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'SIP account creation failed');
  }

  /** Swift `header` — ZStack { HStack { cancel; Spacer; configure }; Text(title).headline }. */
  @Builder
  private header() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        // Swift `cancelButton` — `Text(L10n.Global.cancel).foregroundColor(UIColor.label)`, i.e.
        // a bare text button: no fill, no capsule, primary text colour (capture: black).
        Button($r('app.string.global_cancel'))
          .id('sipConfigurationCancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .onClick(() => {
            this.dismiss();
          })
        Blank()
        // Swift `configureButton` — `Text(L10n.Account.configure).foregroundColor(.jami)`; the
        // capture shows it in the app accent, not the system blue.
        Button($r('app.string.account_configure'))
          .id('sipConfigurationConfigure')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.configure();
          })
      }
      .width('100%')

      // Swift `Text(L10n.Account.sipAccount).font(.headline)` — 17pt semibold, centred over
      // the same band as the two buttons.
      Text($r('app.string.account_sip_account'))
        .fontSize($r('sys.float.Body_L'))
        // S6 — `.headline` is 17pt SEMIBOLD, i.e. 600, not FontWeight.Medium's 500; the capture
        // shows the title noticeably heavier than the two bar buttons beside it.
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    // Swift `.padding()` on the header ZStack.
    .padding({
      start: LengthMetrics.vp(SHEET_PADDING),
      end: LengthMetrics.vp(SHEET_PADDING),
      top: LengthMetrics.vp(SHEET_PADDING),
      bottom: LengthMetrics.vp(SHEET_PADDING)
    })
  }

  build() {
    // Swift `VStack { header; ScrollView { … } }.frame(maxWidth: .infinity, maxHeight: .infinity)`
    // — a plain VStack, so its default 8pt spacing separates the header from the scroll body
    // (capture: header padded edge 121, subtitle padded edge 129).
    Column({ space: FIELD_GAP }) {
      this.header()

      /*
       * S6 — the in-flight state. It sits ABOVE the scroll body rather than under the password
       * field so it cannot be scrolled out of sight, and the form behind it recedes (see the
       * `.opacity` below): a dimmed form plus a moving spinner reads as "working", where a
       * still form with a spinner buried at the bottom of the scroll reads as frozen.
       */
      if (this.isLoading) {
        Row() {
          LoadingProgress()
            .width(SPINNER_SIZE)
            .height(SPINNER_SIZE)
            .color($r('app.color.jami'))
        }
        .id('sip_configuration_loading')
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: $r('sys.float.margin_level2'), bottom: $r('sys.float.margin_level2') })
      }

      Scroll() {
        // Swift: the ScrollView's implicit VStack — centred alignment (the capture's subtitle is
        // centred on the page) and the default 8pt spacing between the three field rows.
        Column({ space: FIELD_GAP }) {
          // Swift `Text(L10n.CreateAccount.sipConfigure).padding(.vertical)` — `.body`, primary
          // colour, centred (capture: 80..313 on a 393pt screen).
          Text($r('app.string.create_account_sip_configure'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .margin({ top: SHEET_PADDING, bottom: SHEET_PADDING })

          /*
           * Swift `serverView` — WalkthroughFocusableTextView(text: $model.server,
           * isTextFieldFocused: $model.isTextFieldFocused, placeholder: L10n.Account.sipServer).
           * The field shows its name as a PLACEHOLDER and nothing else, exactly as the source
           * does; the contract matches it on the `.id()` slug the component carries. No
           * accessibility text either (the component's default is the create-account username
           * prompt), so a screen reader reads the placeholder or text, as on the iPhone.
           */
          WalkthroughTextEditView({
            text: $server,
            placeholder: $r('app.string.account_sip_server'),
            identifier: 'sipConfigurationServer',
            isFocused: $isServerFocused,
            spokenText: ''
          })

          // Swift `usernameView` — WalkthroughTextEditView(placeholder: L10n.Global.username).
          WalkthroughTextEditView({
            text: $username,
            placeholder: $r('app.string.global_username'),
            identifier: 'sipConfigurationUsername',
            isFocused: $isUsernameFocused,
            spokenText: ''
          })

          // Swift `passwordView` — carries the show/hide toggle (`passwordVisibilityToggle`,
          // the capture's "Hide" body control).
          WalkthroughPasswordView({
            text: $password,
            placeholder: $r('app.string.global_password'),
            identifier: 'sipConfigurationPassword'
          })
            // Swift `passwordView … .padding(.bottom)`.
            .margin({ bottom: SHEET_PADDING })

          /*
           * S6 — the failure surface, finished. The source has no error UI, so the shape is the
           * app's own notice card rather than an invented banner: the same white card and corner
           * radius the three field rows above it use, so it reads as one more row of the form
           * instead of an alert dropped on top of it, and the text is the warning colour so a
           * glance separates it from the grey helper text.
           */
          if (this.showError) {
            // Swift `AccountCreationError.unknown.message`.
            Text($r('app.string.alerts_account_default_error_message'))
              .id('sip_configuration_error')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.warning'))
              .padding($r('sys.float.padding_level4'))
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
              .margin({ bottom: $r('sys.float.margin_level2') })
          }
        }
        .width('100%')
        // Swift `.frame(maxWidth: 500)` on the scroll body.
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      // Swift `.padding(.horizontal)` on the ScrollView (capture: cards 16..377 of 393).
      .padding({ start: LengthMetrics.vp(SHEET_PADDING), end: LengthMetrics.vp(SHEET_PADDING) })
      // Swift `ScrollView(showsIndicators: false)`.
      .scrollBar(BarState.Off)
      // S6 — the form recedes while svc_accounts is in flight; full strength at rest, so no
      // control is ever dimmed on the screen the device actually sees.
      .opacity(this.isLoading ? CONTENT_DIM : 1)
    }
    .width('100%')
    // `.formModal` leaves the walkthrough wallpaper showing above the sheet, so the modal is a
    // rounded-top panel, not a full-bleed page — the same chrome the sibling walkthrough modals use.
    .height(SHEET_HEIGHT)
    // Swift `.background(Color(UIColor.systemGroupedBackground))` — the grey page under the white
    // field cards (palette.json light #F2F2F7).
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius({
      topLeft: $r('sys.float.ohos_id_corner_radius_dialog'),
      topRight: $r('sys.float.ohos_id_corner_radius_dialog')
    })
    .clip(true)
    .id('screen_sip_configuration')
  }
}
