/*
 * screen_welcome — "Welcome / Onboarding", ported from
 *   Ring/Ring/Features/Walkthrough/Views/WelcomeView.swift
 *   Ring/Ring/Features/Walkthrough/Views/Views.swift          (AlertFactory)
 *   Ring/Ring/Features/Walkthrough/WalkthroughCoordinator.swift
 *   Ring/Ring/Features/Walkthrough/Models/WelcomeVM.swift
 *
 * S3: the real component tree, from the SOURCE's `var body`:
 *   ZStack {
 *     Group { HorizontalView | PortraitView }.padding()
 *     alertView().ignoresSafeArea()
 *   }
 *   .toolbar { ToolbarItem(.cancellationAction) { if !notCancelable { cancelButton() } } }
 *   .applyJamiBackground()          // Image("backgroundLogin").scaledToFill()
 *
 * PortraitView = VStack { Spacer(minLength: 80); HeaderView(); ScrollView { ButtonsView() };
 * AboutButton() }. HorizontalView is the SAME children re-arranged side by side for
 * `verticalSizeClass == .compact` (a phone in landscape), where the portrait column has no
 * height left for the buttons; HeightBreakpoint.HEIGHT_SM is that size class here.
 *
 * alertView() switches on WelcomeVM.creationState — the four branches the plan records as
 * conditionalVariants[creating / timeout / name_not_registered / creation_error], each a
 * CustomAlert over the screen.
 *
 * OVERLAY HOST. screen_about_jami, screen_create_account, screen_import_from_archive,
 * screen_jams_connect and screen_sip_configuration are all `present` edges out of this screen,
 * so they are mounted here as dialogs rather than routed. Only "Link a device" is a `push`.
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describeError } from '../common/ErrorText';
import { AboutJamiModalOverlay } from './AboutJamiModalPage';
import { CreateJamiAccountOverlay } from './CreateJamiAccountPage';
import { RestoreAccountFromBackupOverlay } from './RestoreAccountFromBackupPage';
import { JamsConnectOverlay } from './ConnectToAJAMSServerPage';
import { AddASIPAccountOverlay } from './AddASIPAccountPage';
import { AboutButton } from '../components/AboutButton';
import { ButtonsView } from '../components/ButtonsView';
import { HeaderView } from '../components/HeaderView';
import { CustomAlert } from '../components/CustomAlert';
import { AccountCreationError, AccountCreationResult, AccountsService } from '../common/AccountsService';
import { AccountModel, AccountState, accountStateFromRaw } from '../model/AccountModel';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';

/** Swift HeaderView's `Text(title).frame(maxWidth: 250)`, which sizes HorizontalView's left column. */
const HEADER_COLUMN_WIDTH: number = 250;
/** Swift `HStack(spacing: 30)` in HorizontalView. */
const HORIZONTAL_SPACING: number = 30;
/** The sandbox copy of a picked backup archive, in cacheDir while it is being imported. */
const IMPORT_ARCHIVE_FILE: string = 'import_archive';

/**
 * The router params `EntryAbility.routeToTarget` attaches when a deep link names an overlay
 * THIS page hosts (`RouteAliases.resolveTargetOverlay`).
 */
interface WelcomeRouteParams {
  overlayScreen?: string;
  /** Set by the link-device page when it returns here after a successful link. */
  walkthroughCompleted?: boolean;
}

@Entry
@Component
struct WelcomeOnboardingPage {
  /** Swift `Text(L10n.Welcome.title)` — the header title (bindingContract: title text). */
  @State titleText: ResourceStr = $r('app.string.welcome_title');
  /** Swift `Image("jamiGnupackage")` (bindingContract: logo). */
  @State logo: Resource = $r('app.media.jami_gnupackage');
  /** Swift `applyJamiBackground()` -> `Image("backgroundLogin")` (bindingContract: background). */
  @State bgResource: Resource = $r('app.media.background_login');

  /** Swift `@SwiftUI.State var showImportOptions` (conditionalVariants[import_expanded]). */
  @State isImportExpanded: boolean = false;
  /** Swift `@SwiftUI.State var showAdvancedOptions` (conditionalVariants[advanced_expanded]). */
  @State isAdvancedExpanded: boolean = false;
  /**
   * Swift `!notCancelable` — WalkthroughCoordinator.start() passes `isAccountFirst`, so the
   * Cancel toolbar item exists only when the walkthrough was opened to ADD an account to an
   * app that already has one (conditionalVariants[cancelable]).
   */
  @State cancelable: boolean = false;
  /** Swift `verticalSizeClass == .compact` — picks HorizontalView over PortraitView. */
  @State private isCompactHeight: boolean = false;

  /** Swift `creationState == .started` (conditionalVariants[creating]). */
  @State isCreating: boolean = false;
  /** Swift `creationState == .timeOut` (conditionalVariants[timeout]). */
  @State isTimeout: boolean = false;
  /** Swift `creationState == .nameNotRegistered` (conditionalVariants[name_not_registered]). */
  @State isNameNotRegistered: boolean = false;
  /** Swift `creationState == .error(AccountCreationError)` (conditionalVariants[creation_error]). */
  @State isCreationError: boolean = false;
  /** The associated value of `.error(error:)` — decides the alert's title and message. */
  @State private creationError: AccountCreationError = AccountCreationError.GENERIC;

  /** True while this screen's services are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output; empty when there is no failure. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /**
   * screen_create_account — presentation: modal, hostScreen: screen_welcome. The overlay's
   * `isPresented` is the HOST's state (Swift: WalkthroughCoordinator owns the presented VC),
   * so the overlay can dismiss itself and the host stays the single writer.
   */
  @State private isCreateAccountPresented: boolean = false;

  /*
   * Every walkthrough sheet below is a Swift `.formModal`: pinned to the bottom of the screen,
   * with the keyboard drawn OVER its lower part. ArkUI's default keyboard avoidance re-lays the
   * dialog out above the keyboard instead, which cuts the sheet off mid-screen and shows this
   * page through the gap (TC-ONBOARD-300), hence `alignment` + `keyboardAvoidMode` on each.
   */
  private createAccountDialog: CustomDialogController = new CustomDialogController({
    builder: CreateJamiAccountOverlay({
      isPresented: $isCreateAccountPresented,
      createAction: (name: string, password: string, profileName: string, profileImage: string): void => {
        this.createAccount(name, password, profileName, profileImage);
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    keyboardAvoidMode: KeyboardAvoidMode.NONE,
    cancel: () => {
      this.isCreateAccountPresented = false;
    }
  });

  /** screen_import_from_archive — presentation: modal, hostScreen: screen_welcome. */
  @State private isImportArchivePresented: boolean = false;

  private importArchiveDialog: CustomDialogController = new CustomDialogController({
    builder: RestoreAccountFromBackupOverlay({
      isPresented: $isImportArchivePresented,
      importAction: (uri: string, password: string): void => {
        this.importFromArchive(uri, password);
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    keyboardAvoidMode: KeyboardAvoidMode.NONE,
    cancel: () => {
      this.isImportArchivePresented = false;
    }
  });

  /** screen_about_jami — presentation: modal, hostScreen: screen_welcome. */
  @State private isAboutJamiPresented: boolean = false;

  private aboutJamiDialog: CustomDialogController = new CustomDialogController({
    builder: AboutJamiModalOverlay({ isPresented: $isAboutJamiPresented }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    keyboardAvoidMode: KeyboardAvoidMode.NONE,
    cancel: () => {
      this.isAboutJamiPresented = false;
    }
  });

  /** screen_jams_connect — presentation: modal, hostScreen: screen_welcome. */
  @State private isJamsConnectPresented: boolean = false;

  private jamsConnectDialog: CustomDialogController = new CustomDialogController({
    builder: JamsConnectOverlay({ isPresented: $isJamsConnectPresented }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    keyboardAvoidMode: KeyboardAvoidMode.NONE,
    cancel: () => {
      this.isJamsConnectPresented = false;
    }
  });

  /** screen_sip_configuration — presentation: modal, hostScreen: screen_welcome. */
  @State private isSipConfigurationPresented: boolean = false;

  private sipConfigurationDialog: CustomDialogController = new CustomDialogController({
    builder: AddASIPAccountOverlay({ isPresented: $isSipConfigurationPresented }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    keyboardAvoidMode: KeyboardAvoidMode.NONE,
    cancel: () => {
      this.isSipConfigurationPresented = false;
    }
  });

  /** Guards the deep-link overlay: `onPageShow` fires again on every return from a push. */
  private deepLinkOverlayOpened: boolean = false;
  /** Swift `WelcomeVM.disposeBag` — the creation subscriptions below. */
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    // Swift `WalkthroughCoordinator.start(notCancelable: isAccountFirst)` — the walkthrough is
    // cancelable exactly when it is NOT the app's first account. Asked of the daemon: removing
    // the last account routes here before its accountsChanged signal prunes the cached list,
    // so hasAccounts() still counted the removed account and showed Cancel (T-1608).
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const ids: string[] | null = accounts.getAccountsId();
    this.cancelable = ids !== null ? ids.length > 0 : accounts.hasAccounts();
    this.observeAccountCreation(accounts);
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscriptions go whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      // The five `present` edges are dialogs this page HOSTS. `finish()` can route away while
      // one of them is still up (a successful creation dismisses the walkthrough from inside the
      // sheet), and a dialog whose host is gone stays on screen over the next page.
      this.closeOverlays();
      this.isCreating = false;
    }
  }

  /** Every overlay this page hosts, dismissed with it. `close()` on a closed dialog is a no-op. */
  private closeOverlays(): void {
    this.createAccountDialog.close();
    this.importArchiveDialog.close();
    this.aboutJamiDialog.close();
    this.jamsConnectDialog.close();
    this.sipConfigurationDialog.close();
    this.isCreateAccountPresented = false;
    this.isImportArchivePresented = false;
    this.isAboutJamiPresented = false;
    this.isJamsConnectPresented = false;
    this.isSipConfigurationPresented = false;
  }

  /**
   * Swift `WelcomeVM`'s creation pipeline. Every walkthrough branch (create, link, import,
   * JAMS, SIP) funnels through the SAME two outcomes on the view model, so the welcome screen
   * — not the sheet that started it — is where they are observed:
   *   `accountCreated()`            -> .success  -> WalkthroughState.completed -> finish()
   *   `handleAccountCreationError()`-> .error(e) -> the error alert
   * Both streams are app-wide, so they only count while one of this page's flows is running
   * (`isCreationInFlight`); otherwise a temp link account's error, or the link page making its
   * account current underneath, would raise a stray alert or finish from the wrong page.
   */
  private observeAccountCreation(accounts: AccountsService): void {
    // Swift `handleAccountCreationError(_:)` — a failed creation raises the alert.
    this.bag.add(accounts.accountCreationStatusObservable()
      .subscribe((result: AccountCreationResult): void => {
        // The JAMS sheet reports its own sign-in failure and stays up; a second alert here,
        // behind it, would show the same error twice.
        if (result.errorCode === null || this.isJamsConnectPresented ||
          !this.isCreationInFlight()) {
          return;
        }
        this.setCreationError(result.errorCode);
      }));
    // Swift `accountCreated(stateHandler:)` — the new account becomes current, and the
    // walkthrough is done; `.completed` is what dismisses it.
    this.bag.add(accounts.currentAccountChanged
      .subscribe((account: AccountModel | null): void => {
        if (account === null || !this.isCreationInFlight()) {
          return;
        }
        this.currentAccountId = account.id;
        this.accountCreated();
      }));
  }

  /** True while one of the five modals this page hosts is up. */
  private isOverlayPresented(): boolean {
    return this.isCreateAccountPresented || this.isImportArchivePresented ||
      this.isJamsConnectPresented || this.isSipConfigurationPresented || this.isAboutJamiPresented;
  }

  /**
   * Create, JAMS and SIP finish while their sheet is still up; import dismisses its sheet first
   * and runs under `isCreating`. The link flow is a pushed page and reports back through
   * `walkthroughCompleted` instead.
   */
  private isCreationInFlight(): boolean {
    return this.isOverlayPresented() || this.isCreating;
  }

  /** Swift `handleAccountCreationError(_:)` -> `setState(state: .error(error:))`. */
  private setCreationError(errorCode: string): void {
    const state: AccountState | null = accountStateFromRaw(errorCode);
    this.errorText = errorCode;
    this.showCreationError(state === AccountState.ERROR_NETWORK ? AccountCreationError.NETWORK
      : AccountCreationError.UNKNOWN);
  }

  /** Swift `accountCreated(stateHandler:)` — `.success`, then `WalkthroughState.completed`. */
  private accountCreated(): void {
    this.isCreating = false;
    this.isCreationError = false;
    this.isTimeout = false;
    this.isNameNotRegistered = false;
    this.finish();
  }

  /** A deep link is delivered once per arrival; `onPageShow` also fires on every return. */
  onPageShow(): void {
    // Swift `linkAction` -> `WelcomeVM.linkDeviceCompleted` -> `accountCreated`.
    const params: WelcomeRouteParams | undefined = router.getParams() as WelcomeRouteParams;
    if (params?.walkthroughCompleted === true) {
      this.accountCreated();
      return;
    }
    this.openDeepLinkOverlay();
  }

  /**
   * The five `present` edges out of this screen are overlays, not routes, so a deep link naming
   * one resolves to THIS page plus an `overlayScreen` id. Open the modal it names, once.
   */
  private openDeepLinkOverlay(): void {
    if (this.deepLinkOverlayOpened) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    const params: WelcomeRouteParams = raw as WelcomeRouteParams;
    const overlay: string = params.overlayScreen === undefined ? '' : params.overlayScreen;
    if (overlay.length === 0) {
      return;
    }
    this.deepLinkOverlayOpened = true;
    if (overlay === 'screen_create_account') {
      this.openAccountCreation();
    } else if (overlay === 'screen_profile') {
      // Swift presents ProfileView OVER CreateAccountView (`createAccountCustomize` ->
      // `.sheet(isPresented: $showProfileView)`), so the deep link opens the account-creation
      // modal and asks it to raise its profile sheet on top — the same path the control takes.
      AppStorage.setOrCreate<boolean>('walkthroughProfileSheetRequested', true);
      this.openAccountCreation();
    } else if (overlay === 'screen_import_from_archive') {
      this.openImportArchive();
    } else if (overlay === 'screen_about_jami') {
      this.openAboutJami();
    } else if (overlay === 'screen_jams_connect') {
      this.openJAMS();
    } else if (overlay === 'screen_sip_configuration') {
      this.openSIP();
    } else {
      hilog.warn(0x0001, 'Welcome', 'deep link named an overlay this page does not host: %{public}s',
        overlay);
    }
  }

  /** Swift: `WelcomeVM.openAccountCreation` -> WalkthroughState.accountCreation (.formModal). */
  private openAccountCreation(): void {
    this.isCreateAccountPresented = true;
    this.createAccountDialog.open();
  }

  /**
   * Swift `WelcomeVM.createAccount(name:password:stateHandler:)`: `creationState = .started`, the
   * "Creating account" alert, covers the screen until the outcome, so nothing can start a second
   * account meanwhile (T-1620). Success finishes through the currentAccountChanged handler.
   */
  private createAccount(name: string, password: string, profileName: string, profileImage: string): void {
    if (this.isCreating) {
      return;
    }
    this.isCreating = true;
    ServiceRegistry.shared().accountService.addJamiAccount(name, password, '', '', profileName)
      .then((accountId: string): void => {
        // Swift `handleAccountCreationSuccess` -> `saveProfile(accountId:)`.
        if (profileName.length > 0 || profileImage.length > 0) {
          ServiceRegistry.shared().accountService
            .updateProfile(accountId, profileName, profileImage, 'JPEG')
            .catch((error: Error): void => {
              hilog.warn(0x0001, 'Welcome', 'profile save failed: %{public}s', error.message);
            });
        }
      })
      .catch((error: Error): void => {
        // Swift `handleAccountCreationError(_:)`.
        this.showCreationError(error.message === AccountCreationError.NETWORK
          ? AccountCreationError.NETWORK : AccountCreationError.UNKNOWN);
      });
  }

  /** Swift: `WelcomeVM.openImportArchive` -> WalkthroughState.importArchive (.formModal). */
  private openImportArchive(): void {
    this.isImportArchivePresented = true;
    this.importArchiveDialog.open();
  }

  /**
   * Swift `WelcomeVM.importFromArchive(path:password:)`. The picker hands over a document URI
   * that the daemon cannot open as a path, so the archive is first copied into the sandbox, which
   * is this platform's `startAccessingSecurityScopedResource()`, and the copy is removed when the
   * import ends. Success finishes through the currentAccountChanged handler, like every creation.
   */
  private importFromArchive(uri: string, password: string): void {
    const path: string =
      (getContext(this) as common.UIAbilityContext).cacheDir + '/' + IMPORT_ARCHIVE_FILE;
    let source: fs.File | null = null;
    try {
      source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(source.fd, path);
    } catch (error) {
      hilog.error(0x0001, 'Welcome', 'cannot read the picked archive: %{public}s',
        describeError(error as BusinessError));
      // Swift `guard path.startAccessingSecurityScopedResource() else { .error(.unknown) }`.
      this.showCreationError(AccountCreationError.UNKNOWN);
      return;
    } finally {
      if (source !== null) {
        fs.closeSync(source);
      }
    }
    // Swift `creationState = .started` — the "Creating account" alert.
    this.isCreating = true;
    ServiceRegistry.shared().accountService.addJamiAccount('', password, '', path, '')
      .catch((error: Error): void => {
        // Swift `handleAccountCreationError(_:)`.
        this.showCreationError(error.message === AccountCreationError.NETWORK
          ? AccountCreationError.NETWORK : AccountCreationError.UNKNOWN);
      })
      .finally((): void => {
        fs.unlink(path).catch((): void => {});
      });
  }

  /** Swift `setState(state: .error(error:))`. */
  private showCreationError(error: AccountCreationError): void {
    this.creationError = error;
    this.isCreating = false;
    this.isCreationError = true;
  }

  /** Swift: `WelcomeVM.openAboutJami` -> WalkthroughState.aboutJami (.formModal). */
  private openAboutJami(): void {
    this.isAboutJamiPresented = true;
    this.aboutJamiDialog.open();
  }

  /** Swift: `WelcomeVM.openJAMS` -> WalkthroughState.connectJAMS -> JamsConnectView (.formModal). */
  private openJAMS(): void {
    this.isJamsConnectPresented = true;
    this.jamsConnectDialog.open();
  }

  /** Swift: `WelcomeVM.openSIP` -> WalkthroughState.connectSIP -> SIPConfigurationView (.formModal). */
  private openSIP(): void {
    this.isSipConfigurationPresented = true;
    this.sipConfigurationDialog.open();
  }

  /** Swift: `WelcomeVM.openLinkDevice` -> WalkthroughState.linkDevice -> LinkToAccountView PUSHED. */
  private openLinkDevice(): void {
    // `push`, not `replace`: Back from the link screen must return to this page.
    router.pushUrl({ url: 'pages/LinkThisDeviceToAnAccountPage' }).catch((error: BusinessError) => {
      hilog.error(0x0001, 'Welcome', 'pushUrl LinkThisDeviceToAnAccountPage failed: %{public}s',
        describeError(error));
    });
  }

  /**
   * Swift `WelcomeVM.finish(stateHandler:)` -> WalkthroughState.completed ->
   * WalkthroughCoordinator.finish(), which dismisses the walkthrough back onto whatever was
   * under it. Here that is the page below on the router stack; when the walkthrough IS the
   * root (the cold-start onboarding case) there is nothing to pop to, so the smart list — the
   * screen the coordinator reveals — takes its place.
   */
  private finish(): void {
    if (router.getLength() !== '1') {
      router.back();
      return;
    }
    router.replaceUrl({ url: 'pages/SmartListConversationsHomePage' }).catch((error: BusinessError) => {
      hilog.error(0x0001, 'Welcome', 'replaceUrl SmartListConversationsHomePage failed: %{public}s',
        describeError(error));
    });
  }

  /** Swift `AccountCreationError.title`. */
  private creationErrorTitle(): ResourceStr {
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
  private creationErrorMessage(): ResourceStr {
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

  /** Swift `AlertFactory.alertWithOkButton(title:message:action:)` (Views.swift:138). */
  @Builder
  private alertWithOkButton(title: ResourceStr, message: ResourceStr, action: () => void) {
    Column({ space: 20 }) {
      Text(title)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(message)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')
      Row() {
        Blank()
        // Swift AlertFactory's `.default` button — the walkthrough's accent is Color.jami.
        Button($r('app.string.global_ok'))
          .type(ButtonType.Normal)
          .padding(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .id('alertOkButton')
          .onClick(() => {
            action();
          })
      }
      .width('100%')
    }
  }

  /** Swift `AlertFactory.createLoadingView()` (Views.swift:157). */
  @Builder
  private loadingAlertBody() {
    Column({ space: 20 }) {
      // Swift `.font(.headline)`.
      Text($r('app.string.create_account_creating_account'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
        .width('100%')
      LoadingProgress()
        .width(64)
        .height(64)
        .color($r('app.color.jami'))
    }
  }

  @Builder
  private timeoutAlertBody() {
    this.alertWithOkButton($r('app.string.create_account_timeout_title'),
      $r('app.string.create_account_timeout_message'), () => {
        this.isTimeout = false;
        this.finish();
      });
  }

  @Builder
  private nameNotRegisteredAlertBody() {
    this.alertWithOkButton($r('app.string.create_account_username_not_registered_title'),
      $r('app.string.create_account_username_not_registered_message'), () => {
        this.isNameNotRegistered = false;
        this.finish();
      });
  }

  @Builder
  private creationErrorAlertBody() {
    this.alertWithOkButton(this.creationErrorTitle(), this.creationErrorMessage(), () => {
      // Swift: `viewModel.creationState = .initial` — the alert clears, the screen stays.
      this.isCreationError = false;
      this.errorText = '';
    });
  }

  /** Swift `ButtonsView(...)`, shared by PortraitView and HorizontalView. */
  @Builder
  private buttonsView() {
    ButtonsView({
      isImportExpanded: $isImportExpanded,
      isAdvancedExpanded: $isAdvancedExpanded,
      onJoinJami: () => {
        this.openAccountCreation();
      },
      onLinkDevice: () => {
        this.openLinkDevice();
      },
      onImportArchive: () => {
        this.openImportArchive();
      },
      onConnectJams: () => {
        this.openJAMS();
      },
      onCreateSipAccount: () => {
        this.openSIP();
      }
    })
  }

  /** Swift `PortraitView` — the same four children HorizontalView re-arranges when compact. */
  @Builder
  private portraitView() {
    Column() {
      // Swift `Spacer(minLength: 80)`.
      Blank(80)
      HeaderView({ logo: this.logo, title: this.titleText })
      Scroll() {
        this.buttonsView()
      }
      .layoutWeight(1)
      // A Scroll centres content shorter than itself; SwiftUI's ScrollView starts it at the top, so
      // the stack sits under the header and an expanded group grows downward (T-1629).
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      AboutButton({
        onAboutJami: () => {
          this.openAboutJami();
        }
      })
    }
    .width('100%')
    .height('100%')
    // Swift `Group { PortraitView }.padding()` — the 16 pt margin the capture shows on every
    // band: the button column is x 16..377 and About Jami's baseline sits 16 above the safe
    // area. The content stays INSIDE the safe area; only the background ignores it.
    .padding(16)
  }

  /**
   * Swift `HorizontalView` — HStack(spacing: 30) { VStack { Spacer; HeaderView; AboutButton;
   * Spacer }; VStack { Spacer; ScrollView { ButtonsView }.frame(height: content); Spacer } }.
   * A Scroll with no height of its own already hugs its content up to the column's height.
   */
  @Builder
  private horizontalView() {
    Row({ space: HORIZONTAL_SPACING }) {
      Column() {
        HeaderView({ logo: this.logo, title: this.titleText })
        AboutButton({
          onAboutJami: () => {
            this.openAboutJami();
          }
        })
      }
      .width(HEADER_COLUMN_WIDTH)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      Column() {
        Scroll() {
          this.buttonsView()
        }
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    // Swift `Group { HorizontalView }.padding()`.
    .padding(16)
  }

  build() {
    // Swift `ZStack { content; alertView() }.applyJamiBackground()`.
    Stack() {
      // Swift `applyJamiBackground()` — Image("backgroundLogin").resizable().scaledToFill().
      // Capture: `backgroundLogin` is [0,0][393,883] — wider and taller than the window, i.e.
      // Swift's `.resizable().scaledToFill().ignoresSafeArea()`. Cover is scaledToFill and
      // expandSafeArea is ignoresSafeArea; it is on the IMAGE alone, exactly as in the source,
      // so the content above keeps its safe-area insets.
      Image(this.bgResource)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .accessibilityLevel('no')

      if (this.isCompactHeight) {
        this.horizontalView()
      } else {
        this.portraitView()
      }

      // Swift `.toolbar { ToolbarItem(.cancellationAction) { if !notCancelable { cancelButton() } } }`
      // — conditionalVariants[cancelable].
      if (this.cancelable) {
        Row() {
          // Swift `cancelButton()` is a toolbar item: a plain label in the walkthrough's
          // accent, with no fill — the same treatment as advancedButton/AboutButton.
          Button($r('app.string.global_cancel'))
            .type(ButtonType.Normal)
            .padding(12)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.jami'))
            .fontSize($r('sys.float.Body_L'))
            // A `.cancellationAction` item is regular weight; an ArkUI Button defaults to Medium.
            .fontWeight(FontWeight.Normal)
            .id('welcomeCancel')
            .onClick(() => {
              this.finish();
            })
          Blank()
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
        // The toolbar row covers the page; only its button may take a touch.
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // Swift `alertView()` — the creationState switch. `.initial`, `.unknown` and `.success`
      // render EmptyView, so they have no branch here.
      if (this.isCreating) {
        CustomAlert() {
          this.loadingAlertBody()
        }
      } else if (this.isTimeout) {
        CustomAlert() {
          this.timeoutAlertBody()
        }
      } else if (this.isNameNotRegistered) {
        CustomAlert() {
          this.nameNotRegisteredAlertBody()
        }
      } else if (this.isCreationError) {
        CustomAlert() {
          this.creationErrorAlertBody()
        }
      }
    }
    .width('100%')
    .height('100%')
    // The whole screen is the background image, but a surface is never left unpainted: if the
    // asset is slow or missing the page must not fall through to the device colour mode.
    .backgroundColor($r('sys.color.background_primary'))
    // Re-evaluated on every resize, i.e. on rotation and fold/unfold.
    .onAreaChange(() => {
      this.isCompactHeight =
        this.getUIContext().getWindowHeightBreakpoint() === HeightBreakpoint.HEIGHT_SM;
    })
    .id('screen_welcome')
  }
}
