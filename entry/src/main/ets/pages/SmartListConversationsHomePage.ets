/*
 * screen_smart_list — "Smart List (conversations home)", the cold-start root of the
 * signed-in app. Ported from
 *   Ring/Ring/Features/Conversations/ConversationsCoordinator.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SmartListContainer.swift  (SmartListView)
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SmartListContentView.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/ConversationsViewModel.swift
 *   Ring/Ring/Features/Conversations/views/JamiSearchView/JamiSearchViewModel.swift
 *
 * S3 built the tree. S4 adds the state architecture: Swift's ConversationsViewModel opened
 * five subscriptions in its initialiser (`setupFilteredConversations`, `observeSearchModelUpdates`,
 * `observeNetworkState`, `observeAccountChange`, `setupNewConversationHandler`) and this page
 * opens the same five onto the migrated services, holding them in one DisposeBag that
 * `aboutToDisappear` releases in a `finally`.
 *
 * OVERLAY HOST. This page hosts screen_account_lists (popup), screen_dialpad,
 * screen_requests (sheet) and screen_active_calls (modal —
 * ConversationsCoordinator.subscribeToActiveCalls() raises it from the service, not a control).
 *
 * THE DAEMON. Swift's search performed a name lookup / JAMS directory search through the
 * libjami daemon. HarmonyOS has no daemon, so NameService resolves those requests as ERROR
 * and this page renders the `daemon_not_available` notice instead of inventing a result. The
 * conversation list is likewise empty when the daemon cannot supply conversations — an honest
 * empty list, never a literal row set transcribed from a capture.
 *
 * S5 style. Every value below is either the source's own declaration (NavBarIcon.glyphSize 20 /
 * tapTarget 44, `Color.jami` for every bar glyph, `networkAlertBackground` #F56E58 with a 12 pt
 * corner and 15 pt padding, the gear at 30 pt white) or the HarmonyOS system token whose ROLE
 * matches the iOS one the framework supplied (plain `systemBackground` page, `.label` /
 * `.secondaryLabel` text, `.separator` hairlines). No value is measured off a screenshot, and
 * nothing structural changes: the controls, bindings, branches and presentation are S1-S4's.
 */
import { LengthMetrics, router, SymbolGlyphModifier } from '@kit.ArkUI';
import { ApplicationStateChangeCallback, common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { contact } from '@kit.ContactsKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';

import { AccountSwitcherOverlay } from './AccountSwitcherOverlayPage';
import { DialpadOverlay } from './DialpadPage';
import { ConversationRequestsSheet } from './ConversationRequestsPage';
import { IncomingActiveCallsOverlay } from './IncomingActiveCallsPage';
import { ContactPickerSheet } from './ContactPickerPage';
import { ScanQRCodeOverlay } from './ScanQRCodePage';
import { showSystemAlert } from '../components/CustomAlert';

import { ConversationDataSource, ConversationViewModel } from '../common/ConversationDataSource';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ShareActions } from '../common/ShareActions';
import { PreferenceManager } from '../common/PreferenceManager';
import { describeError } from '../common/ErrorText';
import { DisposeBag } from '../common/Observable';
import { ConnectionType } from '../common/NetworkService';
import { JamiUri, UriType } from '../common/JamiUri';
import {
  LookupNameResponse, LookupNameState, NameRegistrationState, UserSearchResponse, UserSearchState
} from '../common/NameService';
import { AccountModel, AccountState, accountStateFromRaw } from '../model/AccountModel';
import { InCallScreenOverlay } from './InCallScreenPage';
import { ReturnToCallBar } from '../components/CallBanner';
import { IncomingCallBanner, ringingIncomingCall } from '../components/IncomingCallBanner';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
import { AccountType } from '../model/AccountConfigModel';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import { RequestModel } from '../model/RequestModel';
import { AccountCallTracker, ActiveCall } from '../model/ActiveCall';
import { Profile } from '../model/Profile';

import { PlatformAdaptiveNavView } from '../components/PlatformAdaptiveNav';
import { CurrentAccountButton } from '../components/CurrentAccountButton';
import { CustomSearchController } from '../components/CustomSearchController';
import { ConversationsView } from '../components/ConversationsView';
import { TempConversationsView } from '../components/TempConversationsView';
import { ConversationRowView, ROW_SEPARATOR_INSET } from '../components/ConversationRow';
import { RequestsIndicatorView } from '../components/RequestsIndicator';
import { lookupRegisteredName } from '../components/RequestsRow';
import { LazyView } from '../components/LazyView';
import { Indicator, IndicatorOrientation } from '../components/Indicator';

/** Swift `JamiSearchViewModel.search(withText:)` — a jami name needs 3 characters to look up. */
const MIN_LOOKUP_LENGTH: number = 3;

/** The navigation bar's own height; the capture puts its items in a 52 pt band. */
const NAV_BAR_HEIGHT: number = 52;
/** Swift `networkSettingsButton()`: `Image(systemName: "gear").frame(width: 30, height: 30)`. */
const NETWORK_GEAR_SIZE: number = 30;
/** Swift `networkSettingsButton()`: `.padding(.horizontal, 15).padding(.vertical, 15)`. */
const NETWORK_BANNER_PADDING: number = 15;
/** Swift `Spacer().frame(width: 15)` between the banner's text and its gear. */
const NETWORK_BANNER_GAP: number = 15;
/** Swift `Color.networkAlertBackground` (`UIColor(red: 245, green: 110, blue: 88)`). */
const NETWORK_ALERT_BACKGROUND: string = '#F56E58';
/** Swift `networkInfo()`: `VStack(spacing: 5)`. */
const NETWORK_TEXT_SPACING: number = 5;
/** Swift `smartListTopView`: `.listRowInsets(... leading: 15, trailing: 15)` + `.padding(.bottom)`. */
const TOP_VIEW_INSET: number = 15;

/*
 * The banner's own destination. Swift `SmartListContentView.openSettings()` is
 * `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString))` — the OS
 * Settings app's page for THIS app, not any in-app settings page. The HarmonyOS counterpart is
 * the settings app's app-info entry (the same trio NotificationSettingsPage already launches).
 */
const SETTINGS_BUNDLE: string = 'com.huawei.hmos.settings';
const SETTINGS_ABILITY: string = 'com.huawei.hmos.settings.MainAbility';
const SETTINGS_APP_INFO_URI: string = 'application_info_entry';

/*
 * S6 — the app's OWN empty/placeholder design, read off `NoConversationsView` /
 * `NoSearchResultsView` (Ring/jamiShareExtension/ShareView.swift:534). The smart list's
 * SwiftUI `listContent` renders a plain empty List when there is nothing to show, so these
 * are the only empty-state declarations the app makes and they are the vocabulary a
 * HarmonyOS build has to reuse rather than invent: `VStack(spacing: 16)`, a 48 pt light
 * secondary glyph, `.font(.body).fontWeight(.semibold).foregroundColor(.primary)` text,
 * `.padding(.bottom, 80)` and `.padding(.horizontal)`.
 */
const PLACEHOLDER_SPACING: number = 16;
const PLACEHOLDER_GLYPH_SIZE: number = 48;
const PLACEHOLDER_BOTTOM_PADDING: number = 80;
/** SwiftUI `.padding(.horizontal)` — the platform's own 16 pt edge inset. */
const PLACEHOLDER_HORIZONTAL_PADDING: number = 16;
/** The list/account spinner. ArkUI has no `.controlSize`; 48 matches the glyph above it. */
const LOADING_SPINNER_SIZE: number = 48;

/**
 * The router params `EntryAbility.routeToTarget` attaches when a deep link names an overlay
 * THIS page hosts (`RouteAliases.resolveTargetOverlay`).
 */
interface SmartListRouteParams {
  overlayScreen?: string;
}

/** The params openConversation() pushes ConversationChatPage with. */
interface ChatRouteParams {
  conversationKey?: string;
}

@Entry
@Component
struct SmartListConversationsHomePage {
  // ---------------------------------------------------------------- conditional variants
  /** conditionalVariants[account_list_open] — Swift `@SwiftUI.State var showAccountList`. */
  @State isAccountListOpen: boolean = false;
  /** conditionalVariants[sip_account] — Swift `model.isSipAccount()`. */
  @State isSipAccount: boolean = false;
  /** conditionalVariants[jami_account] — Swift `!model.isSipAccount()`. */
  @State isJamiAccount: boolean = true;
  /** conditionalVariants[searching] — Swift `model.searchFlow.isActive`. */
  @State isSearching: boolean = false;
  /** conditionalVariants[has_requests] — Swift `requestsModel.unreadRequests > 0`. */
  @State hasRequests: boolean = false;
  /** conditionalVariants[network_unavailable] — Swift `model.connectionState == .none`. */
  @State isNetworkUnavailable: boolean = false;

  /** True while svc_conversation_source / svc_accounts are still in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  // ---------------------------------------------------------------- bound content
  /** AppStorage['currentAccountId'], written by svc_accounts on an account switch. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /** bindingContract[current account button] <- svc_accounts (bestName). */
  @State currentAccountButton: string = '';
  /** bindingContract[current account button] <- svc_accounts / svc_profiles (avatar). */
  @State currentAccountAvatar: string = '';
  /** Swift `model.accountsModel.accountStatus`. */
  @State currentAccountStatus: AccountState = AccountState.UNREGISTERED;

  /**
   * bindingContract[conversation list] <- svc_conversation_source. Swift
   * `@Published var filteredConversations` (`setupFilteredConversations`: the data source's
   * rows, narrowed by the search query). Starts EMPTY and is filled by the service — the
   * LazyForEach in ConversationsView reads `filteredSource`, which mirrors this array.
   */
  @State conversationListListLazyForEachOverConversationDataSourceConversationViewModels:
    ConversationViewModel[] = [];

  /** bindingContract[row title] <- ConversationModel.title, for the page's own (temporary) row. */
  @State rowTitle: string = '';
  /** bindingContract[row subtitle] <- MessageModel.content, for the page's own (temporary) row. */
  @State rowSubtitle: string = '';
  /** bindingContract[row avatar] <- svc_profiles, for the page's own (temporary) row. */
  @State rowAvatar: string = '';
  /** bindingContract[unread badge] <- svc_conversation_source (summed over the rows). */
  @State unreadBadge: number = 0;

  /** Swift `model.searchFlow.text`. */
  @State searchText: string = '';
  /** Swift `model.temporaryConversation` — the searched jami id with no conversation yet. */
  @State temporaryConversation: ConversationViewModel | null = null;
  /** Swift `requestsModel.unreadRequests`. */
  @State unreadRequests: number = 0;
  /** Swift `requestsModel.requestNames`. */
  @State requestNames: string = '';
  /**
   * Swift `RequestNameResolver.registeredNames` for the indicator: sender jami id -> registered
   * name, '' while the lookup is pending or found nothing. A key means it was already asked.
   */
  private requestRegisteredNames: Map<string, string> = new Map<string, string>();
  /**
   * How many JAMS directory rows the last search produced. `jamsSource` is an
   * ArrayDataSource (not observable state), so the search's no-results VISUAL needs the
   * count mirrored here.
   */
  @State jamsCount: number = 0;

  /**
   * The overflow menu's own presentation flag. Swift's `Menu` builds its rows only while it is
   * open; ArkUI's one-argument `.bindMenu(builder)` builds the CustomBuilder with the page, so
   * the six MenuItems sat in the landing UI-tree before any tap (and the drivers tapped them
   * there). The flag gates BOTH the `isShow` overload and the builder body, so the rows exist
   * only while the menu is actually raised.
   */
  @State private isOverflowMenuOpen: boolean = false;

  /** screen_requests — presentation: sheet, hostScreen: screen_smart_list. */
  @State showRequests: boolean = false;

  /** screen_contact_picker — presentation: sheet, mounted here (not a routed page). */
  @State showContactPicker: boolean = false;

  /**
   * svc_conversation_source — Swift's `ConversationDataSource`, owned by
   * ConversationsCoordinator and handed to the view model.
   */
  private source: ConversationDataSource = new ConversationDataSource();

  /** Swift `model.filteredConversations`, wrapped for LazyForEach. Reloaded, never replaced. */
  private filteredSource: ArrayDataSource<ConversationViewModel> =
    new ArrayDataSource<ConversationViewModel>([]);

  /** Swift `model.jamsSearchResult` — JAMS directory hits, an itemType of this screen. */
  private jamsSource: ArrayDataSource<ConversationViewModel> =
    new ArrayDataSource<ConversationViewModel>([]);

  /** Swift `var disposeBag = DisposeBag()` — the five subscriptions the view model opened. */
  private bag: DisposeBag = new DisposeBag();
  /** Swift `profileDisposeBag` — the current account's profile; replaced on every switch. */
  private profileBag: DisposeBag = new DisposeBag();

  /** Guards the deep-link overlay: `onPageShow` fires again on every return from a push. */
  private deepLinkOverlayOpened: boolean = false;

  // ---------------------------------------------------------------- hosted overlays
  /** screen_account_lists — presentation: popup, hostScreen: screen_smart_list. */
  private accountSwitcher: CustomDialogController = new CustomDialogController({
    builder: AccountSwitcherOverlay({ isPresented: $isAccountListOpen }),
    autoCancel: true,
    customStyle: true,
    // Swift `ZStack(alignment: .bottom)`: the cards sit on the bottom edge.
    // DialogAlignment.Default centred them on the foldable.
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: 0 },
    // Swift `backgroundCover()`: black at 0.09 edge to edge. The dialog's own mask is that
    // cover; a second page-level cover under it doubled the dim.
    maskColor: '#17000000',
    // Swift: tapping the background cover calls toggleAccountList() — the overlay closes and
    // the branch selector goes back to false.
    cancel: () => {
      this.isAccountListOpen = false;
    }
  });

  /** screen_dialpad — presentation: modal, hostScreen: screen_smart_list. */
  /** screen_dialpad's own presentation flag, so the overlay can close itself. */
  @State private showDialpad: boolean = false;

  private dialpad: CustomDialogController = new CustomDialogController({
    builder: DialpadOverlay({ isPresented: $showDialpad }),
    autoCancel: true,
    customStyle: true
  });

  /**
   * screen_active_calls — presentation: modal, hostScreen: screen_smart_list.
   * Swift: `ConversationsCoordinator.subscribeToActiveCalls()` presents ActiveCallsView
   * `.overFullScreen` while CallService.activeCalls holds an incoming, unanswered call.
   */
  /**
   * screen_active_calls' presentation flag. This page owns it; the overlay holds it by @Link
   * and lowers it when the last renderable call goes (Swift `onNoRenderableCalls?()`), so the
   * coordinator's dismissal is visible here without reading the controller.
   */
  @State private isActiveCallsPresented: boolean = false;

  /**
   * Swift: CallKit's incoming-call UI, then the coordinator's call screen. HarmonyOS has no
   * system call UI here, so a ringing incoming call raises screen_call over the smart list.
   */
  @State private showIncomingCall: boolean = false;
  private incomingCallDialog: CustomDialogController = new CustomDialogController({
    builder: InCallScreenOverlay({ isPresented: $showIncomingCall }),
    autoCancel: false,
    // Back closes the call screen; the call goes on and the return bar brings it back.
    cancel: (): void => {
      this.showIncomingCall = false;
    },
    // T-1731: Back with an in-call sheet open closes only the sheet, as iOS.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK && InCallScreenOverlay.closeOpenPanel()) {
        return;
      }
      this.showIncomingCall = false;
      action.dismiss();
    },
    customStyle: true,
    // T-1470: flush on the keyboard; the default 16 vp gap let the page show through.
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });

  /**
   * T-1628: with Jami in the foreground a ringing call shows CallKit's compact banner (iOS 4.20)
   * over whatever page is up, and its body opens the call screen above. Non-modal and never
   * focused, so the page under it stays usable and an open keyboard stays up.
   */
  @State private showIncomingBanner: boolean = false;
  private incomingBannerDialog: CustomDialogController = new CustomDialogController({
    builder: IncomingCallBanner({
      isPresented: $showIncomingBanner,
      onExpand: (): void => {
        this.presentCallScreen();
      }
    }),
    autoCancel: false,
    isModal: false,
    focusable: false,
    alignment: DialogAlignment.Top,
    customStyle: true,
    // Back hides it, as Back closes the call screen: the call goes on ringing.
    cancel: (): void => {
      this.showIncomingBanner = false;
    }
  });
  /** Set by the application's foreground / background changes; the page is built in the foreground. */
  private appInForeground: boolean = true;

  private activeCallsDialog: CustomDialogController = new CustomDialogController({
    // Swift: joining places the call and the coordinator shows the call screen (T-1591).
    builder: IncomingActiveCallsOverlay({
      isPresented: $isActiveCallsPresented,
      onJoined: (): void => {
        this.presentCallScreen();
      }
    }),
    autoCancel: true,
    customStyle: true,
    // S5: Swift presents ActiveCallsView `.overFullScreen` and it paints its own
    // `Color.black.opacity(0.5)` scrim edge to edge, so the dialog box takes the whole window
    // rather than the default inset one.
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    // Swift `presentFromTopController(..., animation: false)` / `dismiss(animated: false)`.
    openAnimation: { duration: 0 },
    closeAnimation: { duration: 0 },
    cancel: (): void => {
      this.isActiveCallsPresented = false;
    }
  });

  /** screen_scan_qr — presentation: modal, raised by the deep link and by the in-place
   * search results (screen_smart_list_search), which owns the scanner affordance. */
  /** screen_scan_qr's own presentation flag, so the overlay can close itself. */
  @State private showScanQr: boolean = false;

  private scanQrDialog: CustomDialogController = new CustomDialogController({
    builder: ScanQRCodeOverlay({ isPresented: $showScanQr }),
    autoCancel: true,
    customStyle: true
  });

  // ---------------------------------------------------------------- lifecycle
  aboutToAppear(): void {
    this.isLoading = true;
    // Swift `AppDelegate.registerDonationsDefaults()` — the shipped campaign window is written
    // into the preferences store on first run and read back on every later launch.
    PreferenceManager.registerDonationsDefaults();
    this.source.start();
    ConversationDataSource.smartList = this.source;
    this.subscribeToServices();
    this.refresh();
  }

  aboutToDisappear(): void {
    try {
      this.bag.dispose();
      this.profileBag.dispose();
    } finally {
      if (ConversationDataSource.smartList === this.source) {
        ConversationDataSource.smartList = null;
      }
      this.source.stop();
    }
  }

  /** A deep link is delivered once per arrival; `onPageShow` also fires on every return. */
  onPageShow(): void {
    // Swift `setSearchActive(false)` clears `searchFlow.text`: neither a query nor a focused,
    // keyboard-raising search field survives the return from the results page.
    this.getUIContext().getFocusController().clearFocus();
    if (this.searchText.length > 0) {
      this.performSearch('');
    }
    this.openDeepLinkOverlay();
  }

  /**
   * Swift `ConversationsCoordinator` presenting what the incoming link asked for after
   * `popToSmartList()` (`showDialpad(inCall:)`, `presentRequests()`, the accounts popup).
   * On HarmonyOS the link arrives as `want.parameters.targetPage`, which `EntryAbility`
   * resolves through `RouteAliases` and pushes onto THIS page carrying the overlay id.
   * Nothing else reads that param, so without this the link lands on the smart list and the
   * overlay it named never opens.
   */
  private openDeepLinkOverlay(): void {
    if (this.deepLinkOverlayOpened) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    const params: SmartListRouteParams = raw as SmartListRouteParams;
    const overlay: string = params.overlayScreen === undefined ? '' : params.overlayScreen;
    if (overlay.length === 0) {
      return;
    }
    this.deepLinkOverlayOpened = true;
    if (overlay === 'screen_account_lists') {
      this.toggleAccountList();
    } else if (overlay === 'screen_dialpad') {
      this.openDialpad();
    } else if (overlay === 'screen_requests') {
      this.openRequests();
    } else if (overlay === 'screen_active_calls') {
      this.showActiveCalls();
    } else if (overlay === 'screen_scan_qr') {
      this.openScanQr();
    } else {
      hilog.warn(0x0001, 'SmartList', 'deep link named an overlay this page does not host: %{public}s',
        overlay);
    }
  }

  /**
   * The body of Swift's `ConversationsViewModel.init` — five subscriptions onto the migrated
   * services, all held in one DisposeBag.
   */
  private subscribeToServices(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();

    // Swift `setupFilteredConversations()` — the data source's rows, narrowed by the query.
    this.bag.add(registry.conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        this.applyConversations(conversations.length);
        // Swift combineLatest(requests, conversations): an accepted invitation leaves the banner.
        this.applyRequests(registry.requestsService.requests.value);
      }));

    // Swift `observeNetworkState()`.
    this.bag.add(registry.networkService.connectionState.subscribe(
      (state: ConnectionType): void => {
        this.isNetworkUnavailable = state === ConnectionType.NONE;
      }));

    // Swift `AccountsViewModel.subscribeToStatusChanges()` — the status dot follows the
    // current account's registration state.
    this.bag.add(registry.accountService.sharedResponseStream.subscribe((event: ServiceEvent): void => {
      if (event.eventType !== ServiceEventType.REGISTRATION_STATE_CHANGED ||
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) !== this.currentAccountId) {
        return;
      }
      const newState: AccountState | null =
        accountStateFromRaw(event.getEventInput(ServiceEventInput.REGISTRATION_STATE) ?? '');
      // The volatile details that carry the registered name land with the registration state:
      // a fresh account's header was resolved before its name was known and stayed on the id.
      this.applyAccount(registry.accountService.currentAccount);
      if (newState !== null) {
        this.currentAccountStatus = newState;
      }
    }));

    // Swift `AccountsViewModel.subscribeToRegisteredName()` — re-resolve the header's name
    // once the current account's name registration succeeds.
    this.bag.add(registry.nameService.sharedRegistrationStatus.subscribe((event: ServiceEvent): void => {
      if (event.eventType === ServiceEventType.NAME_REGISTRATION_ENDED &&
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) === this.currentAccountId &&
        event.getEventInput(ServiceEventInput.STATE) === NameRegistrationState.SUCCESS) {
        this.applyAccount(registry.accountService.currentAccount,
          event.getEventInput(ServiceEventInput.NAME) ?? '');
      }
    }));

    this.bag.add(registry.callService.callsUpdated.subscribe((): void => {
      if (ringingIncomingCall(registry.callService.stateMirror.liveCalls) !== undefined) {
        this.presentIncomingCall();
      }
    }));

    // T-1628: the banner is for the foreground only. Leaving the app with it up swaps in the
    // call screen, which is what a ringing call shows in the background (and on the way back).
    const app: common.ApplicationContext = getContext(this).getApplicationContext();
    const appState: ApplicationStateChangeCallback = {
      onApplicationForeground: (): void => {
        this.appInForeground = true;
      },
      onApplicationBackground: (): void => {
        this.appInForeground = false;
        if (this.showIncomingBanner) {
          this.presentCallScreen();
        }
      }
    };
    app.on('applicationStateChange', appState);
    this.bag.add((): void => {
      app.off('applicationStateChange', appState);
    });

    // Swift `observeAccountChange()`.
    this.bag.add(registry.accountService.currentAccountChanged.subscribe(
      (account: AccountModel | null): void => {
        this.applyAccount(account);
        this.applyConversations(this.source.conversationViewModels.length);
        this.applyRequests(registry.requestsService.requests.value);
      }));

    // Swift `RequestsViewModel` — the pending-invitation counter the top view renders.
    this.bag.add(registry.requestsService.requests.subscribe(
      (requests: RequestModel[]): void => {
        this.applyRequests(requests);
      }));

    // Swift `ConversationsCoordinator.subscribeToActiveCalls()` — an incoming, unanswered call
    // raises the active-calls overlay this page hosts.
    this.bag.add(registry.callService.activeCalls.subscribe(
      (trackers: Map<string, AccountCallTracker>): void => {
        this.applyActiveCalls(trackers);
      }));

    // Swift `observeSearchModelUpdates()` — JamiSearchViewModel.performLookup's two streams.
    this.bag.add(registry.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        this.applyLookupResult(response);
      }));
    this.bag.add(registry.nameService.userSearchResponseShared.subscribe(
      (response: UserSearchResponse): void => {
        this.applyJamsResult(response);
      }));
  }

  /** Reads the screen's bound values off the services the plan assigns it. */
  private refresh(): void {
    this.isLoading = true;
    try {
      const registry: ServiceRegistry = ServiceRegistry.shared();
      this.applyAccount(registry.accountService.currentAccount);
      this.isNetworkUnavailable =
        registry.networkService.connectionState.value === ConnectionType.NONE;
      this.applyRequests(registry.requestsService.requests.value);
      this.applyConversations(this.source.conversationViewModels.length);
      this.errorText = '';
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /** Swift `observeAccountChange` + `CurrentAccountButton(model: model.accountsModel)`. */
  private applyAccount(account: AccountModel | null, registeredNameHint: string = ''): void {
    this.profileBag.dispose();
    if (account === null) {
      this.currentAccountId = '';
      this.currentAccountButton = '';
      this.currentAccountAvatar = '';
      this.currentAccountStatus = AccountState.UNREGISTERED;
      return;
    }
    this.currentAccountId = account.id;
    // Swift `resolveAccountName(from:)`: the account's name, else the one just registered
    // (Swift's UserDefaults copy), else the id.
    const registeredName: string = account.registeredName.length > 0 ? account.registeredName
      : registeredNameHint.length > 0 ? registeredNameHint : account.jamiId;
    this.currentAccountStatus = account.status;
    this.isSipAccount = account.type === AccountType.SIP;
    this.isJamiAccount = !this.isSipAccount;
    // Swift `updateProfileDetails(account:)` + `updateBestName()`: follow the account's own
    // profile rather than reading it once. The relay starts empty and fills ~100 ms later, so a
    // single read left the header on the old alias and avatar after a switch.
    this.profileBag.add(ServiceRegistry.shared().profileService.getAccountProfile(account.id)
      .subscribe((profile: Profile): void => {
        this.currentAccountAvatar = profile.photo === null ? '' : profile.photo;
        this.currentAccountButton = profile.alias !== null && profile.alias.length > 0
          ? profile.alias : registeredName;
      }));
  }

  /**
   * Swift `setupFilteredConversations()` — `CombineLatest($searchQuery,
   * conversationsSource.$conversationViewModels)` mapped through
   * `conversationViewModels.filter { $0.matches(searchQuery) }`.
   */
  private applyConversations(sourceCount: number): void {
    const query: string = this.searchText.trim().toLowerCase();
    const rows: ConversationViewModel[] = [];
    let unread: number = 0;
    for (const row of this.source.conversationViewModels) {
      unread += row.unreadCount;
      if (query.length === 0 || SmartListConversationsHomePage.matches(row, query)) {
        rows.push(row);
      }
    }
    this.conversationListListLazyForEachOverConversationDataSourceConversationViewModels = rows;
    this.filteredSource.reload(rows);
    this.unreadBadge = unread;
    this.publishBadge(unread);
    if (sourceCount > 0 && this.errorText.length > 0) {
      this.errorText = '';
    }
  }

  /** Swift `ConversationViewModel.matches(_:)` — title, then the peer's jami id. */
  private static matches(row: ConversationViewModel, query: string): boolean {
    if (row.title.toLowerCase().indexOf(query) >= 0) {
      return true;
    }
    return row.key.toLowerCase().indexOf(query) >= 0;
  }

  /**
   * Swift set `UIApplication.shared.applicationIconBadgeNumber` from the unread total. The
   * HarmonyOS equivalent is the app's own badge, which needs no permission.
   */
  private publishBadge(unread: number): void {
    notificationManager.setBadgeNumber(unread).catch((error: BusinessError): void => {
      // A device with badges switched off is not a screen defect — it is logged, not surfaced.
      hilog.warn(0x0001, 'SmartList', 'setBadgeNumber failed: %{public}s', describeError(error));
    });
  }

  /** Swift `subscribeToActiveCalls()` — present while any account has a live call. */
  private applyActiveCalls(trackers: Map<string, AccountCallTracker>): void {
    // Swift `subscribeToActiveCalls()`: only an incoming call that is neither accepted nor
    // ignored counts, the overlay is raised once (`activeCallsController == nil`), and only
    // when the current account is among the trackers. Any call at all used to re-open it on
    // every emission, so an accepted or outgoing call flashed it. Dismissal is the overlay's
    // own `onNoRenderableCalls`.
    const incoming: ActiveCall[] = [];
    trackers.forEach((tracker: AccountCallTracker): void => {
      incoming.push(...tracker.incomingNotAcceptedNotIgnoredCalls());
    });
    if (incoming.length === 0 || this.isActiveCallsPresented || !trackers.has(this.currentAccountId)) {
      return;
    }
    // Swift: "Skip showing call alert if the conversation for incoming call is already open" —
    // one account, one incoming call, and the top page is that call's conversation, which shows
    // only its own call banner.
    if (trackers.size === 1 && incoming.length === 1 && this.isConversationOnTop(incoming[0])) {
      return;
    }
    this.showActiveCalls();
  }

  /** Swift `navigationController.topViewController as? ConversationViewController` showing it. */
  private isConversationOnTop(call: ActiveCall): boolean {
    const top: router.RouterState = this.getUIContext().getRouter().getState();
    if (top.name !== 'ConversationChatPage' || top.params === undefined || top.params === null) {
      return false;
    }
    // The chat page's router params carry ConversationViewModel.key, `<accountId>|<id>`.
    return (top.params as ChatRouteParams).conversationKey === `${call.accountId}|${call.conversationId}`;
  }

  /**
   * Swift `RequestsViewModel.unreadRequests` / `requestNames`. The names follow
   * `sortRequestsByReceivedDate`, oldest first, as the sheet does (T-1581).
   */
  private applyRequests(all: RequestModel[]): void {
    const requests: RequestModel[] =
      ServiceRegistry.shared().requestsService.pendingRequests(all, this.currentAccountId)
        .sort((left: RequestModel, right: RequestModel): number =>
          left.receivedDate.getTime() - right.receivedDate.getTime());
    this.unreadRequests = requests.length;
    this.hasRequests = this.unreadRequests > 0;
    const names: string[] = [];
    for (const request of requests) {
      // Swift `RequestNameResolver.requestName`: the swarm title, else the first participant's
      // registered name once the name service finds it, else its jami id.
      if (request.name.length > 0 || request.participants.length === 0) {
        names.push(request.name);
        continue;
      }
      const jamiId: string = request.participants[0].jamiId;
      if (!this.requestRegisteredNames.has(jamiId)) {
        this.requestRegisteredNames.set(jamiId, '');
        this.bag.add(lookupRegisteredName(request.accountId, jamiId, (found: string): void => {
          this.requestRegisteredNames.set(jamiId, found);
          this.applyRequests(ServiceRegistry.shared().requestsService.requests.value);
        }));
      }
      const registered: string = this.requestRegisteredNames.get(jamiId) ?? '';
      names.push(registered.length > 0 ? registered : jamiId);
    }
    this.requestNames = names.join(', ');
  }

  // ---------------------------------------------------------------- search
  /**
   * Swift `ConversationsViewModel.updateSearchText(_:)` -> `performSearch(query:)` ->
   * `JamiSearchViewModel.search(withText:)`: clean up the previous search, re-filter the
   * existing rows, then ask the name service for anything not already on screen.
   */
  private performSearch(query: string): void {
    this.searchText = query;
    // Swift `cleanUpPreviousSearch()`.
    this.temporaryConversation = null;
    this.rowTitle = '';
    this.rowSubtitle = '';
    this.rowAvatar = '';
    this.jamsSource.reload([]);
    this.jamsCount = 0;
    this.applyConversations(this.source.conversationViewModels.length);

    const trimmed: string = query.trim();
    this.isSearching = trimmed.length > 0;
    if (trimmed.length === 0) {
      this.errorText = '';
      return;
    }

    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    // Swift: a SIP account dials the number straight away; a jami account needs 3 characters.
    if (account.type === AccountType.SIP) {
      this.temporaryConversation = this.makeTemporaryConversation(trimmed, account, trimmed);
      return;
    }
    if (trimmed.length < MIN_LOOKUP_LENGTH) {
      return;
    }
    // Swift `addTemporaryConversationsIfNeed` -> `performLookup`. Both branches are
    // daemon-backed; NameService answers with an ERROR state, handled below.
    if (account.isJams) {
      ServiceRegistry.shared().nameService.searchUser(account.id, trimmed);
      return;
    }
    ServiceRegistry.shared().nameService.lookupName(account.id, '', trimmed);
  }

  /** Swift `createTemporarySwarmConversation` / `createTemporarySipConversation`. */
  private makeTemporaryConversation(hash: string, account: AccountModel,
    displayName: string): ConversationViewModel {
    const isSip: boolean = account.type === AccountType.SIP;
    const uri: JamiUri = JamiUri.fromInfoHash(isSip ? UriType.SIP : UriType.RING, hash);
    const participant: string = uri.userInfo.length > 0 ? uri.userInfo : hash;
    const conversation: ConversationModel = isSip
      ? ConversationModel.withParticipantUriAndHash(participant, account.id, hash,
        ConversationType.SIP)
      : ConversationModel.withParticipantUri(participant, account.id, ConversationType.ONE_TO_ONE,
        account.jamiId === hash);
    const row: ConversationViewModel = new ConversationViewModel();
    row.setConversation(conversation);
    // bindingContract row title/subtitle/avatar for the ONE row this page owns: the directory
    // result carries the name, so the row cannot derive it from the (empty) conversation.
    this.rowTitle = displayName;
    this.rowSubtitle = '';
    this.rowAvatar = this.avatarFor(participant, account.id);
    return row;
  }

  /** bindingContract[row avatar] <- svc_profiles. */
  private avatarFor(jamiId: string, accountId: string): string {
    const profile: Profile =
      ServiceRegistry.shared().profileService.getProfile(jamiId, accountId).value;
    return profile.photo === null ? '' : profile.photo;
  }

  /** Swift `performLookup`'s `usernameLookupStatus` subscription. */
  private applyLookupResult(response: LookupNameResponse): void {
    if (response.requestedName !== this.searchText.trim()) {
      return;
    }
    if (response.state === LookupNameState.FOUND) {
      const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
      if (account !== null) {
        this.temporaryConversation =
          this.makeTemporaryConversation(response.address, account, response.name);
        this.errorText = '';
      }
      return;
    }
    if (response.state === LookupNameState.ERROR) {
      // The libjami name server is the daemon gap: say so rather than reporting "no result".
      this.showDaemonNotice();
    }
  }

  /** Swift `performLookup`'s `userSearchResponseShared` subscription (the JAMS directory). */
  private applyJamsResult(response: UserSearchResponse): void {
    if (response.state === UserSearchState.ERROR) {
      this.jamsSource.reload([]);
      this.jamsCount = 0;
      this.showDaemonNotice();
      return;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    const rows: ConversationViewModel[] = [];
    for (const result of response.results) {
      const jamiId: string | undefined = result.get('id');
      if (jamiId === undefined || jamiId.length === 0) {
        continue;
      }
      const conversation: ConversationModel = ConversationModel.withParticipantUri(
        jamiId, account.id, ConversationType.ONE_TO_ONE, account.jamiId === jamiId);
      const row: ConversationViewModel = new ConversationViewModel();
      row.setConversation(conversation);
      rows.push(row);
    }
    this.jamsSource.reload(rows);
    this.jamsCount = rows.length;
    this.errorText = '';
  }

  /** The Rule-11 `gap` disclosure: an explicit notice, never a fake success. */
  private showDaemonNotice(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      this.errorText = context.resourceManager.getStringByNameSync('daemon_not_available');
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    }
  }

  // ---------------------------------------------------------------- control effects
  /** Swift `toggleAccountList()` — the current-account button and the Accounts menu item. */
  private toggleAccountList(): void {
    if (this.isAccountListOpen) {
      // Swift `animateAccountListVisibility()` — `withAnimation { showAccountList.toggle() }`.
      this.animateAccountList(false);
      this.accountSwitcher.close();
      return;
    }
    // Swift `prepareAccountsIfNeeded()` — refresh the rows before the list is shown.
    this.refresh();
    this.animateAccountList(true);
    this.accountSwitcher.open();
  }

  /** Swift `withAnimation { showAccountList.toggle() }` (feat_animations). */
  private animateAccountList(open: boolean): void {
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.isAccountListOpen = open;
    });
  }

  /** Swift `activateSearch = true` (compose) / the search bar becoming first responder. */
  private openSearch(): void {
    // `isSearching` is derived from the query in performSearch(), never from the tap: forcing
    // it here left the smart list showing its search branch after Back popped the results.
    // Single: a second Compose tap during the transition must not stack a second search page.
    router.pushUrl({ url: 'pages/SmartListSearchResultsPage' }, router.RouterMode.Single)
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /**
   * Swift `showingPicker.toggle()` -> ContactPicker -> `showSipConversation(withNumber:)`.
   * The system address book is the picker (feat_contacts); the app's own picker sheet is the
   * fallback when the system one is unavailable.
   */
  private openContactPicker(): void {
    // CNContactPickerViewController lists contacts by name and returns all their numbers; the
    // HarmonyOS picker defaults to one row per number.
    contact.selectContacts({ isMultiSelect: false, isDisplayedByName: true })
      .then((selected: contact.Contact[]): void => {
        if (selected.length === 0) {
          return; // cancelled
        }
        const numbers: contact.PhoneNumber[] | undefined = selected[0].phoneNumbers;
        if (numbers === undefined || numbers.length === 0) {
          this.showNoNumberAlert();
        } else if (numbers.length === 1) {
          this.showSipConversation(numbers[0].phoneNumber);
        } else {
          this.presentNumberSelection(numbers);
        }
      }).catch((error: BusinessError): void => {
        this.errorText = describeError(error);
        this.showContactPicker = true;
      });
  }

  /**
   * Swift ContactPicker `presentNumberSelection(from:with:)`: an alert titled
   * L10n.Smartlist.selectOneNumber, one button per number, then Cancel — stacked, as UIKit
   * lays out an alert with more than two actions.
   */
  private presentNumberSelection(numbers: contact.PhoneNumber[]): void {
    const buttons: AlertDialogButtonOptions[] = numbers.map(
      (number: contact.PhoneNumber): AlertDialogButtonOptions => ({
        value: number.phoneNumber,
        action: (): void => {
          this.showSipConversation(number.phoneNumber);
        }
      }));
    buttons.push({ value: $r('app.string.global_cancel'), action: (): void => {} });
    this.getUIContext().showAlertDialog({
      title: $r('app.string.smartlist_select_one_number'),
      message: '',
      autoCancel: false,
      buttons: buttons,
      buttonDirection: DialogButtonDirection.VERTICAL
    });
  }

  /** Swift ContactPicker: `UIAlertController(title: L10n.Smartlist.noNumber)` with one OK. */
  private showNoNumberAlert(): void {
    showSystemAlert(this.getUIContext(), $r('app.string.smartlist_no_number'));
  }

  /** Swift `ConversationsViewModel.showSipConversation(withNumber:publisher:)`. */
  private showSipConversation(number: string): void {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    const row: ConversationViewModel = this.makeTemporaryConversation(number, account, number);
    this.temporaryConversation = row;
    this.openConversation(row);
  }

  /** Swift `ConversationNavigation.openQRCode()` -> ScanViewController presented modally. */
  private openScanQr(): void {
    this.showScanQr = true;
    this.scanQrDialog.open();
  }

  /** Swift `stateEmitter.showDialpad()` -> ConversationState.showDialpad(inCall: false). */
  private openDialpad(): void {
    this.showDialpad = true;
    this.dialpad.open();
  }

  /** Swift `subscribeToActiveCalls()` — an incoming call raises the active-calls overlay. */
  private showActiveCalls(): void {
    this.isActiveCallsPresented = true;
    this.activeCallsDialog.open();
  }

  /** Swift `requestsModel.presentRequests()` -> `requestViewOpened = true` -> RequestsView sheet. */
  private openRequests(): void {
    this.showRequests = true;
  }

  /**
   * Swift `SmartListContentView.openSettings()` — `UIApplication.openSettingsURLString`, i.e.
   * the OS Settings app's page for this app. It is NOT the in-app Connectivity-and-
   * configurations screen this previously pushed: that is a different, separately declared
   * screen the source's banner never reaches. Guarded like every other system-entry launch —
   * an entry point missing on a build must surface a notice, never take the process down.
   */
  private openNetworkSettings(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // Swift `UIApplication.openSettingsURLString` lands on the app's own page. Without
    // `pushParams` naming this bundle, Settings stops at the generic Apps list.
    const want: Want = {
      bundleName: SETTINGS_BUNDLE,
      abilityName: SETTINGS_ABILITY,
      uri: SETTINGS_APP_INFO_URI,
      parameters: { pushParams: context.abilityInfo.bundleName }
    };
    try {
      context.startAbility(want).catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
    } catch (error) {
      // `startAbility` can throw synchronously where the target ability does not exist.
      this.errorText = describeError(error as BusinessError);
    }
  }

  /** Swift `model.showConversation(withConversationViewModel:publisher:)`. */
  private openConversation(conversation: ConversationViewModel): void {
    router.pushUrl({
      url: 'pages/ConversationChatPage',
      params: { conversationKey: conversation.key }
    }).catch((error: BusinessError): void => {
      this.errorText = describeError(error);
    });
  }

  /** Swift `stateEmitter.createSwarm()` -> SwarmCreationViewController shown. */
  private openNewGroup(): void {
    router.pushUrl({ url: 'pages/CreateSwarmHostPage' })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /** Swift `ConversationsViewModel.showAccount(publisher:)` -> AccountSummaryView. */
  private openAccountSettings(): void {
    router.pushUrl({ url: 'pages/AccountSummarySettingsRootPage' })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /** Swift `stateEmitter.openAboutJami()` -> AboutViewController shown. */
  private openAboutJami(): void {
    router.pushUrl({ url: 'pages/AboutJamiNavPage' })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
      });
  }

  /** Swift `ShareLink(item: model.accountInfoToShare)` (iOS 16+) — ShareKit, clipboard fallback. */
  private inviteFriends(): void {
    const info: string[] | null = ServiceRegistry.shared().accountService.accountInfoToShare;
    const content: string = info === null ? '' : info.join('\n');
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // `accountInfoToShare` is null while there is no loaded account to invite anyone TO (the
    // daemon gap), and an empty string is not a share — ShareActions.share drops it and the
    // control reads as dead. Disclose the gap instead of firing a no-op share.
    if (content.length === 0) {
      this.showDaemonNotice();
      return;
    }
    ShareActions.share(context, content,
      context.resourceManager.getStringByNameSync('smartlist_invite_friends'))
      .catch((error: BusinessError) => {
        this.errorText = describeError(error);
      });
  }

  /** Swift `ConversationsViewModel.donate()` -> `SharedActionsPresenter.openDonationLink()`. */
  private supportJami(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ShareActions.openDonationLink(context).catch((error: BusinessError) => {
      this.errorText = describeError(error);
    });
  }

  // ---------------------------------------------------------------- builders
  /**
   * Swift `menuButton`'s SwiftUI Menu — the rows behind the **Overflow menu** control. Real
   * rows, so every item is addressable by its slug.
   *
   * S6 finalize. Each source row is a SwiftUI `Label(text, systemImage:)`, so the glyph is
   * half the row and the capture (`more.png`) shows all six. `MenuItemOptions.symbolEndIcon`
   * (SymbolGlyphModifier, API 12) is the ArkUI equivalent — `startIcon`/`endIcon` take a
   * ResourceStr and cannot carry a system symbol, which is why S5 left these label-only.
   * Names come from the source's own `systemImage:` argument through the icon ladder:
   *   person.2      -> sys.symbol.person_2                (exact)
   *   envelope.open -> sys.symbol.envelope_open           (exact)
   *   list.bullet   -> sys.symbol.list_bullet             (icon-map: exact)
   *   person.circle -> sys.symbol.person_crop_circle_fill (icon-map candidates: the only
   *                    person-in-a-circle in the shortlist; the rest are badges/plain circle)
   *   heart         -> sys.symbol.heart                   (exact)
   * About Jami is NOT a symbol in the source — it is `Image(uiImage: model.jamiImage)`,
   * i.e. `Asset.jamiIcon` resized to 20x20 — so it takes the bundled asset through `endIcon`.
   *
   * Two labels are corrected to the string the source actually passes (the capture shows
   * both): `L10n.Swarm.newGroup` = "Create new group", not smartlist_new_group; and
   * `L10n.AccountPage.settingsHeader` = "Settings", not global_account_settings.
   */
  @Builder
  overflowMenu() {
    // Gated on the same flag `bindMenu`'s `isShow` reads: a CustomBuilder handed to the
    // one-argument `.bindMenu(builder)` is built with the page, which put all six MenuItems in
    // the landing UI-tree before the overflow control was ever tapped.
    if (this.isOverflowMenuOpen) {
      Menu() {
        // Swift: the swarm + invite items exist only for a Jami account.
        if (this.isJamiAccount) {
          MenuItem({
            content: $r('app.string.swarm_new_group'),
            symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.person_2'))
          })
            .id('newGroupButton')
            .onClick(() => {
              this.openNewGroup();
            })
          MenuItem({
            content: $r('app.string.smartlist_invite_friends'),
            symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.envelope_open'))
          })
            .id('smartListInviteFriends')
            .onClick(() => {
              this.inviteFriends();
            })
        }
        MenuItem({
          content: $r('app.string.smartlist_accounts'),
          symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.list_bullet'))
        })
          .id('smartListAccounts')
          .onClick(() => {
            this.toggleAccountList();
          })
        MenuItem({
          content: $r('app.string.account_page_settings_header'),
          symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill'))
        })
          .id('smartListSettings')
          .onClick(() => {
            this.openAccountSettings();
          })
        MenuItem({
          content: $r('app.string.smartlist_about_jami'),
          endIcon: $r('app.media.jami_icon')
        })
          .id('smartListAboutJami')
          .onClick(() => {
            this.openAboutJami();
          })
        MenuItem({
          content: $r('app.string.global_support_jami'),
          symbolEndIcon: new SymbolGlyphModifier($r('sys.symbol.heart'))
        })
          .id('smartListSupportJami')
          .onClick(() => {
            this.supportJami();
          })
      }
    }
  }

  /** Swift `leadingBarItems` + `trailingBarItems`. */
  @Builder
  navigationBar() {
    Row() {
      // actionContract: **Current account button** — Swift `leadingBarItems`,
      // Button { toggleAccountList() } label: { CurrentAccountButton }.
      Button({ type: ButtonType.Normal }) {
        CurrentAccountButton({
          bestName: this.currentAccountButton,
          avatarData: this.currentAccountAvatar,
          accountStatus: this.currentAccountStatus,
          unreadCount: this.unreadBadge
        })
      }
      .id('accountsInformationIdentifier')
      .backgroundColor(Color.Transparent)
      .padding(0)
      .onClick(() => {
        this.toggleAccountList();
      })

      Blank()

      // actionContract: **Overflow menu** — Swift `trailingBarItems`:
      // menu + (SIP ? **Phone book** : compose).
      Button({ type: ButtonType.Normal }) {
        // The capture recorded this control under the slug `more`, not under the source's
        // own `openMenuInSmartList`: SwiftUI puts `.accessibility(identifier:)` on this inner
        // image, but at capture time iOS exposed the Menu button by its accessibility LABEL
        // ("More"), which is what the action path for S0082 taps. The drivers read only
        // `text`, `description` and the last `/`-segment of `.id()` — and on this device a
        // uitest dump leaves `description` empty even where `.accessibilityText()` is set —
        // so the slug has to be an id. It goes on the glyph rather than on the Button so the
        // Button keeps `openMenuInSmartList` EXACTLY (the action contract matches that one by
        // exact slug). The glyph is non-clickable and sits inside the Button, so a tap
        // resolved to its bounds-centre lands on the Button and opens the menu.
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .id('more')
          .fontSize($r('app.float.nav_bar_icon_glyph_size'))
          .fontColor([$r('app.color.jami')])
      }
      .id('openMenuInSmartList')
      .type(ButtonType.Circle)
      .backgroundColor(Color.Transparent)
      .width($r('app.float.tap_target_size'))
      .height($r('app.float.tap_target_size'))
      .onClick(() => {
        this.isOverflowMenuOpen = true;
      })
      // The `isShow` overload (API 12): the menu is raised by the control's own handler and
      // lowered again by its dismissal, so nothing of it is in the tree while it is closed.
      .bindMenu(this.isOverflowMenuOpen, this.overflowMenu(), {
        onDisappear: (): void => {
          this.isOverflowMenuOpen = false;
        }
      })

      if (this.isSipAccount) {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.phone_book'))
            .width($r('app.float.nav_bar_icon_glyph_size'))
            .height($r('app.float.nav_bar_icon_glyph_size'))
            .objectFit(ImageFit.Contain)
            .fillColor($r('app.color.jami'))
        }
        .id('bookButtonIdentifier')
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .width($r('app.float.tap_target_size'))
        .height($r('app.float.tap_target_size'))
        .accessibilityText($r('app.string.contact_picker_contacts'))
        .onClick(() => {
          this.openContactPicker();
        })
      } else {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize($r('app.float.nav_bar_icon_glyph_size'))
            .fontColor([$r('app.color.jami')])
        }
        .id('composeButton')
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .width($r('app.float.tap_target_size'))
        .height($r('app.float.tap_target_size'))
        .accessibilityText($r('app.string.smartlist_new_contact'))
        .onClick(() => {
          this.openSearch();
        })
      }
    }
    .width('100%')
    .height(NAV_BAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  /**
   * Swift `smartListTopView` — shown only when there is something to say:
   * `if requestsModel.unreadRequests > 0 || model.connectionState == .none`.
   */
  @Builder
  smartListTopView() {
    // Swift is an `@ViewBuilder` whose whole body sits behind
    // `if requestsModel.unreadRequests > 0 || model.connectionState == .none` — with nothing
    // to say it contributes no row at all. S5 left the wrapper unconditional, which put its
    // 16 vp bottom margin under the search bar on the ordinary path (the capture shows the
    // first conversation row directly under the search field).
    if (this.isNetworkUnavailable || this.hasRequests) {
      Column() {
        if (this.isNetworkUnavailable) {
          // The **Network settings banner**. Swift `networkSettingsButton()`: the no-network
          // banner + a gear, tappable.
          // `Image(systemName: "gear")` -> sys.symbol.gearshape, the settings-gear glyph in this
          // SDK's symbol table (icon-map's `drive_gear`/`reverse_gear` candidates are vehicle
          // glyphs, not this one).
          Row({ space: NETWORK_BANNER_GAP }) {
            Column({ space: NETWORK_TEXT_SPACING }) {
              Text($r('app.string.smartlist_no_network_connectivity'))
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('sys.color.font_on_primary'))
                .textAlign(TextAlign.Center)
                .width('100%')
              Text($r('app.string.smartlist_cellular_access'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_on_primary'))
                .textAlign(TextAlign.Center)
                .width('100%')
            }
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.gearshape'))
              .fontSize(NETWORK_GEAR_SIZE)
              .fontColor([$r('sys.color.font_on_primary')])
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding(NETWORK_BANNER_PADDING)
          .backgroundColor(NETWORK_ALERT_BACKGROUND)
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .id('smartListNetworkSettings')
          .onClick(() => {
            this.openNetworkSettings();
          })
        }
        if (this.hasRequests) {
          RequestsIndicatorView({
            requestNames: this.requestNames,
            unreadRequests: this.unreadRequests
          })
            .id('smartListRequestsIndicator')
            .margin({ top: this.isNetworkUnavailable ? NETWORK_TEXT_SPACING : 0 })
            .onClick(() => {
              this.openRequests();
            })
        }
      }
      .width('100%')
      // Swift: `.listRowInsets(EdgeInsets(top: 0, leading: 15, bottom: 5, trailing: 15))`
      // plus the VStack's own `.padding(.bottom)`.
      .padding({ left: TOP_VIEW_INSET, right: TOP_VIEW_INSET })
      .margin({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
    }
  }

  /*
   * The three data-less states share the app's own placeholder composition
   * (`NoConversationsView` / `NoSearchResultsView`): a light 48 pt secondary glyph over one
   * semibold body line, 16 pt apart, lifted off the bottom edge. They are written out rather
   * than folded behind one parameterised @Builder: a multi-parameter @Builder passes BY
   * VALUE, so the notice's caption would freeze at whatever `errorText` held when the branch
   * was first built and never follow a later failure.
   */

  /**
   * The Rule-11 daemon gap, and every other service failure, AS A FINISHED STATE. The
   * message itself is bound (`errorText` <- util_error_text / the `daemon_not_available`
   * string resource), never a caption typed in here. `exclamationmark.circle.fill` is
   * icon-map exact.
   */
  @Builder
  noticeState() {
    Column({ space: PLACEHOLDER_SPACING }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
        .fontSize(PLACEHOLDER_GLYPH_SIZE)
        .fontWeight(FontWeight.Lighter)
        .fontColor([$r('app.color.secondary_label')])
      Text(this.errorText)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({
      left: PLACEHOLDER_HORIZONTAL_PADDING,
      right: PLACEHOLDER_HORIZONTAL_PADDING,
      bottom: PLACEHOLDER_BOTTOM_PADDING
    })
  }

  /**
   * Search ran and matched nothing. The source's own `NoSearchResultsView` uses
   * `magnifyingglass` (icon-map exact) with `L10n.Smartlist.noConversationsFound`.
   */
  @Builder
  noResultsState() {
    Column({ space: PLACEHOLDER_SPACING }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(PLACEHOLDER_GLYPH_SIZE)
        .fontWeight(FontWeight.Lighter)
        .fontColor([$r('app.color.secondary_label')])
      Text($r('app.string.smartlist_no_conversations_found'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({
      left: PLACEHOLDER_HORIZONTAL_PADDING,
      right: PLACEHOLDER_HORIZONTAL_PADDING,
      bottom: PLACEHOLDER_BOTTOM_PADDING
    })
  }

  /** Data is in flight. SwiftUI showed the List frame while it filled; ArkUI needs a spinner. */
  @Builder
  loadingState() {
    Column() {
      LoadingProgress()
        .width(LOADING_SPINNER_SIZE)
        .height(LOADING_SPINNER_SIZE)
        .color($r('app.color.jami'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: PLACEHOLDER_BOTTOM_PADDING })
  }

  /**
   * Swift: while the search controller is active the smart list's own rows are replaced by
   * SmartListSearchResultsView, whose two in-place row kinds are the temporary conversation
   * and the JAMS directory hits (bindingContract itemTypes 2 and 3).
   */
  @Builder
  searchResults() {
    Column() {
      // The **Temporary conversation row** (bindingContract itemType 2).
      TempConversationsView({
        conversation: this.temporaryConversation,
        titleOverride: this.rowTitle,
        subtitleOverride: this.rowSubtitle,
        avatarOverride: this.rowAvatar,
        // Swift 4.20: the temporary row opens the conversation, as any smart-list row.
        onSelect: (conversation: ConversationViewModel): void => {
          this.openConversation(conversation);
        }
      })
      // S6: the search's own data-less visuals. A lookup that failed is the daemon gap and
      // must SAY so; one that simply matched nothing is the source's NoSearchResultsView.
      // Neither may be a blank panel — a search that silently shows nothing is
      // indistinguishable from a search that never ran.
      if (this.errorText.length > 0) {
        this.noticeState()
      } else if (this.temporaryConversation === null && this.jamsCount === 0) {
        this.noResultsState()
      }
      List() {
        LazyForEach(this.jamsSource, (conversation: ConversationViewModel) => {
          ListItem() {
            ConversationRowView({ model: conversation, withSeparator: true })
          }
          .id('jamsSearchResultItemroot')
          .onClick(() => {
            this.openConversation(conversation);
          })
        }, (conversation: ConversationViewModel) => conversation.key)
      }
      .layoutWeight(1)
      .divider({
        strokeWidth: 0.5,
        color: $r('sys.color.comp_divider'),
        startMargin: ROW_SEPARATOR_INSET,
        endMargin: 0
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }

  /**
   * Swift `listContent` — the List that carries the top view and the conversations.
   *
   * S6 finalize, two fixes over S5's shape:
   *
   * 1. THE CHROME STAYS. S5 put loading and error ahead of everything, so a failure or a
   *    refresh replaced the WHOLE body — including `smartListTopView`, the persistent
   *    no-network banner and the invitations row. That is the android-ui-fidelity §7
   *    bug class (a full-screen panel hiding the screen's own chrome), and it hides the
   *    banner exactly when the network is the thing that failed. The top view is now a
   *    sibling of the content region and only the region below it swaps.
   * 2. EVERY DATA-LESS STATE IS DESIGNED, in the source's own placeholder vocabulary:
   *    in-flight, failed (the daemon gap included) and search-matched-nothing.
   *
   * Branch order inside the region is Swift's own precedence: in flight, then a failure to
   * disclose, then the rows (an empty list is just an empty list, as on iOS).
   */
  @Builder
  listContent() {
    Column() {
      if (this.isSearching) {
        // conditionalVariants[searching] — SmartListSearchResultsView replaces the list,
        // and the source's search controller covers the smart list's own top view with it.
        this.searchResults()
      } else {
        // Persistent chrome: the network banner and the invitations row survive every
        // content state below them.
        this.smartListTopView()
        if (this.isLoading) {
          this.loadingState()
        } else if (this.errorText.length > 0) {
          this.noticeState()
        } else {
          // bindingContract[conversation list] — the **Conversation row** set, off
          // svc_conversation_source through LazyForEach. An empty list stays a plain, empty
          // list: Swift SmartListContainer/ConversationsView draw no empty-state placeholder.
          ConversationsView({
            rows: this.filteredSource,
            onSelect: (conversation: ConversationViewModel): void => {
              this.openConversation(conversation);
            }
          })
            .layoutWeight(1)
        }
      }
    }
    .width('100%')
    // The space left under the navigation bar and the search field. height('100%') took the
    // whole body's height, so the list ran that much past the screen and its last rows could
    // never be scrolled into view (T-1607).
    .layoutWeight(1)
    .backgroundColor($r('sys.color.background_primary'))
  }

  /** Swift `SearchableConversationsView` — the content, with the search bar over it. */
  @Builder
  conversationsBody() {
    Column() {
      this.navigationBar()
      // The **Search field** (comp_custom_search_controller wraps comp_search_bar).
      // Here it only presents the results page, where the typing happens. The wrapper takes
      // every tap itself and is not focusable, so the home field cannot take focus: it regained
      // focus on Back, raised the keyboard and filled with text. SearchBar stays editable for
      // its other hosts. (A full-height tap-catcher in a Stack here stretched the bar to the
      // whole page and hid the list.)
      Column() {
        CustomSearchController({
          text: $searchText,
          onActivate: (): void => {
            this.openSearch();
          },
          onTextChange: (value: string): void => {
            this.performSearch(value);
          }
        })
      }
      .width('100%')
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.openSearch();
      })
      this.listContent()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    // screen_contact_picker, mounted here and not on the page root: one .bindSheet() per node,
    // and the root already carries screen_requests. The source picker has its own Cancel,
    // so the system close is suppressed.
    .bindSheet($$this.showContactPicker, this.contactPickerSheet(), { showClose: false })
    .id('conversationView')
  }

  /** screen_requests — the sheet body, built only once the sheet is actually raised. */
  @Builder
  requestsSheet() {
    Column() {
      Indicator({ orientation: IndicatorOrientation.HORIZONTAL })
        .margin({ top: $r('sys.float.ohos_id_elements_margin_horizontal_m') })
      // The rest of the sheet below the grabber: the sheet's own height('100%') then resolves
      // against this, not the whole sheet, so its last row is not pushed under the bottom edge.
      Column() {
        LazyView({ isActive: this.showRequests }) {
          ConversationRequestsSheet({ isPresented: $showRequests })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    // S6: the sheet is edge-to-edge `Color.jamiRequestsBackground` in the capture
    // (RequestsView.body `.background(Color.jamiRequestsBackground.ignoresSafeArea())`), so the
    // grabber band above the content is navy too - not a white strip the source never shows.
    .backgroundColor($r('app.color.jami_requests_background'))
  }

  /** screen_contact_picker — the sheet body, built only once the sheet is actually raised. */
  @Builder
  contactPickerSheet() {
    Column() {
      LazyView({ isActive: this.showContactPicker }) {
        ContactPickerSheet({ isPresented: $showContactPicker })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }

  /**
   * Swift `CallScreenPresenter`: one call screen. A call screen the chat already shows (an
   * outgoing call started there) takes the new call itself; a second one stacked over it made
   * Back need two presses.
   */
  private presentCallScreen(): void {
    if (this.showIncomingBanner) {
      this.showIncomingBanner = false;
      this.incomingBannerDialog.close();
    }
    if (this.showIncomingCall || InCallScreenOverlay.isMounted()) {
      return;
    }
    this.showIncomingCall = true;
    this.incomingCallDialog.open();
  }

  /**
   * A ringing call (T-1628): CallKit's compact banner while Jami is in the foreground and no call
   * screen is up; otherwise the call screen, which puts the ringing call in front itself.
   */
  private presentIncomingCall(): void {
    const banner: boolean = this.appInForeground && !this.showIncomingCall && !InCallScreenOverlay.isMounted();
    hilog.info(0x0001, 'JamiF4', 'T-1628 ringing call -> %{public}s (foreground %{public}s)',
      banner ? 'banner' : 'call screen', String(this.appInForeground));
    if (!banner) {
      this.presentCallScreen();
    } else if (!this.showIncomingBanner) {
      this.showIncomingBanner = true;
      this.incomingBannerDialog.open();
    }
  }

  build() {
    // Swift `ZStack(alignment: .bottom)`.
    Stack({ alignContent: Alignment.Bottom }) {
      PlatformAdaptiveNavView() {
        this.conversationsBody()
      }

      if (!this.showIncomingCall) {
        ReturnToCallBar({
          onReturn: (): void => {
            this.presentCallScreen();
          }
        })
          .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    // The source sheet carries its own CloseButton, so the system close is suppressed.
    .bindSheet($$this.showRequests, this.requestsSheet(), { showClose: false })
    .id('screen_smart_list')
  }
}
