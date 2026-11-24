/*
 * App-level navigation state machine.
 *
 * Ported from Ring/Ring/Coordinators/AppCoordinator.swift (+ Coordinator.swift,
 * WalkthroughCoordinator.swift, ConversationsCoordinator.swift).
 *
 * On iOS AppCoordinator both DECIDES the app state and PRESENTS UIViewControllers.
 * A `.ts` module cannot present ArkUI, so the decision half is ported verbatim here
 * and the presentation half becomes an observable route stack plus command subjects
 * the pages subscribe to. No UI is created here.
 */

import hilog from '@ohos.hilog';
import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { AccountsService } from './AccountsService';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AppStateService';

/** `alerts.dbFailedTitle` in the iOS string table (results/analysis/string-key-map.json). */
export const ALERT_DB_FAILED_TITLE_KEY: string = 'alerts_db_failed_title';
/** `alerts.dbFailedMessage`. */
export const ALERT_DB_FAILED_MESSAGE_KEY: string = 'alerts_db_failed_message';

/** Swift: `enum AppState: State`. ArkTS enums carry no payload, so the payload lives on `AppState`. */
export enum AppStateKind {
  INITIAL_LOADING = 'INITIAL_LOADING',
  NEED_TO_ONBOARD = 'NEED_TO_ONBOARD',
  ADD_ACCOUNT = 'ADD_ACCOUNT',
  ALL_SET = 'ALL_SET',
  NEED_ACCOUNT_MIGRATION = 'NEED_ACCOUNT_MIGRATION'
}

/** Application global navigation state. */
export class AppState {
  readonly kind: AppStateKind;
  /** `needToOnboard(animated:)`. */
  readonly animated: boolean;
  /** `needToOnboard(isFirstAccount:)`. */
  readonly isFirstAccount: boolean;
  /** `needAccountMigration(accountId:)`. */
  readonly accountId: string;

  constructor(kind: AppStateKind, animated: boolean, isFirstAccount: boolean, accountId: string) {
    this.kind = kind;
    this.animated = animated;
    this.isFirstAccount = isFirstAccount;
    this.accountId = accountId;
  }

  static initialLoading(): AppState {
    return new AppState(AppStateKind.INITIAL_LOADING, false, false, '');
  }

  static needToOnboard(animated: boolean, isFirstAccount: boolean): AppState {
    return new AppState(AppStateKind.NEED_TO_ONBOARD, animated, isFirstAccount, '');
  }

  static addAccount(): AppState {
    return new AppState(AppStateKind.ADD_ACCOUNT, false, false, '');
  }

  static allSet(): AppState {
    return new AppState(AppStateKind.ALL_SET, false, false, '');
  }

  static needAccountMigration(accountId: string): AppState {
    return new AppState(AppStateKind.NEED_ACCOUNT_MIGRATION, false, false, accountId);
  }
}

/** Swift: `private enum InitialState` — the launch gate that orders daemon-ready vs. start(). */
export enum InitialState {
  NOT_STARTED = 'NOT_STARTED',
  STARTED = 'STARTED',
  READY_TO_DISPATCH = 'READY_TO_DISPATCH',
  COMPLETED = 'COMPLETED'
}

/** Swift: `public enum VCType: String` — keys of the `presentingVC` re-entrancy lock. */
export enum VcType {
  CONVERSATION = 'conversation',
  CONTACT = 'contact',
  BLOCK_LIST = 'blockList',
  LOG = 'log'
}

/**
 * The routes the app-level navigation stack can hold. iOS pushes UIViewController
 * instances; here the stack holds logical routes and the page layer maps each to a page.
 */
export enum AppRoute {
  INITIAL_LOADING = 'INITIAL_LOADING',
  WALKTHROUGH = 'WALKTHROUGH',
  SMART_LIST = 'SMART_LIST',
  ACCOUNT_MIGRATION = 'ACCOUNT_MIGRATION'
}

/** Which part of the app a child coordinator drives. */
export enum CoordinatorKind {
  WALKTHROUGH = 'WALKTHROUGH',
  CONVERSATIONS = 'CONVERSATIONS'
}

/** Swift: the `ConversationState` cases AppCoordinator forwards to ConversationsCoordinator. */
export enum CoordinatorCommandKind {
  OPEN_CONVERSATION_FOR_PARTICIPANT = 'OPEN_CONVERSATION_FOR_PARTICIPANT',
  OPEN_CONVERSATION_FOR_ID = 'OPEN_CONVERSATION_FOR_ID',
  OPEN_CONVERSATION_FROM_CALL = 'OPEN_CONVERSATION_FROM_CALL',
  START_CALL = 'START_CALL',
  START_AUDIO_CALL = 'START_AUDIO_CALL',
  START_OUTGOING_CALL = 'START_OUTGOING_CALL',
  POP_TO_SMART_LIST = 'POP_TO_SMART_LIST'
}

/** One navigation command handed to a child coordinator's `stateSubject`. */
export class CoordinatorCommand {
  readonly kind: CoordinatorCommandKind;
  readonly accountId: string;
  readonly conversationId: string;
  readonly participantId: string;
  readonly peerUri: string;
  readonly userName: string;
  readonly isAudioOnly: boolean;

  constructor(kind: CoordinatorCommandKind, accountId: string, conversationId: string,
              participantId: string, peerUri: string, userName: string, isAudioOnly: boolean) {
    this.kind = kind;
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.participantId = participantId;
    this.peerUri = peerUri;
    this.userName = userName;
    this.isAudioOnly = isAudioOnly;
  }
}

/** Swift: `struct CallConversationRoute` (CallScreenPresenter.swift). */
export class CallConversationRoute {
  readonly conversationId: string;
  readonly peerUri: string;
  readonly accountId: string;

  constructor(conversationId: string, peerUri: string, accountId: string) {
    this.conversationId = conversationId;
    this.peerUri = peerUri;
    this.accountId = accountId;
  }
}

/** A user-facing alert the page layer resolves from `resources/base/element/string.json`. */
export class AlertRequest {
  readonly titleKey: string;
  readonly messageKey: string;

  constructor(titleKey: string, messageKey: string) {
    this.titleKey = titleKey;
    this.messageKey = messageKey;
  }
}

/**
 * Swift: `private let navigationController = UINavigationController()`.
 * The app-level route stack, observable so the root page can follow it.
 */
export class NavigationStackState {
  viewControllers: Array<AppRoute> = [];
  readonly changed: BehaviorRelay<Array<AppRoute>> = new BehaviorRelay<Array<AppRoute>>([]);

  /** Swift: `setViewControllers(_:animated:)`. */
  setViewControllers(routes: Array<AppRoute>): void {
    this.viewControllers = routes;
    this.changed.accept(routes);
  }

  push(route: AppRoute): void {
    const next: Array<AppRoute> = this.viewControllers.slice();
    next.push(route);
    this.setViewControllers(next);
  }

  /** Swift: `popToViewController(smartList)` / `popViewController`. */
  popToRoot(): void {
    if (this.viewControllers.length <= 1) {
      return;
    }
    this.setViewControllers([this.viewControllers[0]]);
  }

  get top(): AppRoute | undefined {
    if (this.viewControllers.length === 0) {
      return undefined;
    }
    return this.viewControllers[this.viewControllers.length - 1];
  }

  contains(route: AppRoute): boolean {
    return this.viewControllers.indexOf(route) >= 0;
  }
}

/**
 * Swift: `final class CallScreenPresenter` — owns in-call screen presentation for the
 * whole app lifetime. Only the part AppCoordinator uses is ported: the route callback
 * that takes the user from the call screen back into its conversation.
 */
export class CallScreenPresenter {
  private readonly navigation: NavigationStackState;
  /** Swift: `var onOpenConversation: ((CallConversationRoute) -> Void)?`. */
  onOpenConversation: ((route: CallConversationRoute) => void) | undefined = undefined;

  constructor(navigation: NavigationStackState) {
    this.navigation = navigation;
  }

  /** Called by the call layer when the user taps "open conversation" on the call screen. */
  openConversation(route: CallConversationRoute): void {
    const handler: ((route: CallConversationRoute) => void) | undefined = this.onOpenConversation;
    if (handler === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'call screen asked to open a conversation with no handler set');
      return;
    }
    handler(route);
  }

  get navigationStack(): NavigationStackState {
    return this.navigation;
  }
}

/**
 * Swift: `protocol Coordinator` + WalkthroughCoordinator / ConversationsCoordinator.
 * ArkTS is nominally typed, so the two child coordinators become one class
 * discriminated by `kind` rather than a protocol with two conformers.
 */
export class ChildCoordinator {
  readonly kind: CoordinatorKind;
  parentCoordinator: AppStateService | undefined = undefined;
  childCoordinators: Array<ChildCoordinator> = [];
  /** Swift: `var presentingVC = [String: Bool]()` — the "already presenting" lock. */
  presentingVC: Map<string, boolean> = new Map<string, boolean>();
  disposeBag: DisposeBag = new DisposeBag();
  /** Swift: `let stateSubject = PublishSubject<State>()`. */
  readonly stateSubject: PublishSubject<CoordinatorCommand> = new PublishSubject<CoordinatorCommand>();
  /** Swift: `WalkthroughCoordinator.isAccountFirst`. */
  isAccountFirst: boolean = true;
  /** Swift: `WalkthroughCoordinator.withAnimations`. */
  withAnimations: boolean = true;
  /** Swift: `ConversationsCoordinator.rootViewController` — the stack it drives. */
  readonly navigation: NavigationStackState;

  constructor(kind: CoordinatorKind, navigation: NavigationStackState) {
    this.kind = kind;
    this.navigation = navigation;
    if (kind === CoordinatorKind.CONVERSATIONS) {
      // Swift: ConversationsCoordinator.addLockFlags()
      this.presentingVC.set(VcType.CONTACT, false);
      this.presentingVC.set(VcType.CONVERSATION, false);
    }
  }

  /** Swift: `func start()` — walkthrough shows Welcome, conversations replaces the stack with the smart list. */
  start(): void {
    if (this.kind === CoordinatorKind.WALKTHROUGH) {
      this.navigation.push(AppRoute.WALKTHROUGH);
      return;
    }
    this.navigation.setViewControllers([AppRoute.SMART_LIST]);
  }

  /** Swift: `Coordinator.addChildCoordinator`. */
  addChildCoordinator(child: ChildCoordinator): void {
    this.childCoordinators.push(child);
  }

  /** Swift: `Coordinator.removeChildCoordinator`. */
  removeChildCoordinator(child: ChildCoordinator): void {
    this.childCoordinators = this.childCoordinators.filter((item: ChildCoordinator) => item !== child);
  }
}

/**
 * Swift: `let injectionBag: InjectionBag`, narrowed to what AppCoordinator actually reads.
 * A class, not an interface: ArkTS forbids structural typing, so ServiceRegistry builds
 * one of these rather than being assignable to an interface it never declared.
 */
export class AppStateServices {
  readonly accountService: AccountsService;

  constructor(accountService: AccountsService) {
    this.accountService = accountService;
  }
}

/**
 * Swift: `final class AppCoordinator: Coordinator, StateableResponsive`.
 * Drives the global navigation of the app: loading interface, walkthrough, main
 * interface or account migration.
 */
export class AppStateService {
  /** Swift: `var presentingVC = [String: Bool]()`. */
  presentingVC: Map<string, boolean> = new Map<string, boolean>();
  /** Swift: `var parentCoordinator: Coordinator?` — always nil for the app coordinator. */
  parentCoordinator: ChildCoordinator | undefined = undefined;
  /** Swift: `var childCoordinators = [Coordinator]()`. */
  childCoordinators: Array<ChildCoordinator> = [];
  /** Swift: `private var callScreenPresenter: CallScreenPresenter?`. */
  private callScreenPresenter: CallScreenPresenter | undefined = undefined;
  /** Swift: `var disposeBag = DisposeBag()`. */
  disposeBag: DisposeBag = new DisposeBag();
  /** Swift: `let stateSubject = PublishSubject<State>()`. */
  readonly stateSubject: PublishSubject<AppState> = new PublishSubject<AppState>();
  /** Swift: `private let navigationController = UINavigationController()`. */
  private readonly navigationController: NavigationStackState = new NavigationStackState();
  /** Swift: `let injectionBag: InjectionBag`. */
  readonly injectionBag: AppStateServices;
  /** Swift: `private var initialState: InitialState = .notStarted`. */
  private initialState: InitialState = InitialState.NOT_STARTED;
  /** Observable mirror of `isConversationsPresented()`, for the root page. */
  readonly conversationsPresented: BehaviorRelay<boolean> = new BehaviorRelay<boolean>(false);
  /** `showDatabaseError()` has nowhere to present an alert from a `.ts` module; the root page renders this. */
  readonly alerts: PublishSubject<AlertRequest> = new PublishSubject<AlertRequest>();
  /** The account `migrateAccount(accountId:)` is currently migrating, read by the migration page. */
  private migratingAccountId: string = '';

  constructor(injectionBag: AppStateServices) {
    this.injectionBag = injectionBag;
    // Swift: init subscribes stateSubject and routes every AppState case.
    const unsubscribe: () => void = this.stateSubject.subscribe((state: AppState) => {
      if (state.kind === AppStateKind.INITIAL_LOADING) {
        this.showInitialLoading();
      } else if (state.kind === AppStateKind.NEED_TO_ONBOARD) {
        this.showWalkthrough(state.animated, state.isFirstAccount);
      } else if (state.kind === AppStateKind.ALL_SET) {
        this.showMainInterface();
      } else if (state.kind === AppStateKind.ADD_ACCOUNT) {
        this.showWalkthrough(false, false);
      } else if (state.kind === AppStateKind.NEED_ACCOUNT_MIGRATION) {
        this.migrateAccount(state.accountId);
      }
    });
    this.disposeBag.add(unsubscribe);
  }

  /** Swift: `var rootViewController: UIViewController { return self.navigationController }`. */
  get rootViewController(): NavigationStackState {
    return this.navigationController;
  }

  /** Swift: `private var conversationsCoordinator: ConversationsCoordinator?`. */
  get conversationsCoordinator(): ChildCoordinator | undefined {
    return this.childCoordinators.find((item: ChildCoordinator) => item.kind === CoordinatorKind.CONVERSATIONS);
  }

  /** The account id handed to the migration page by `migrateAccount(accountId:)`. */
  get accountIdBeingMigrated(): string {
    return this.migratingAccountId;
  }

  /**
   * Swift: `func start()`. Called from the ability once the window stage is ready —
   * the HarmonyOS equivalent of `AppDelegate` starting the coordinator.
   */
  start(): void {
    if (this.callScreenPresenter === undefined) {
      const presenter: CallScreenPresenter = new CallScreenPresenter(this.navigationController);
      presenter.onOpenConversation = (route: CallConversationRoute) => {
        this.openConversationFromCall(route);
      };
      this.callScreenPresenter = presenter;
    }
    this.stateSubject.onNext(AppState.initialLoading());

    if (this.initialState === InitialState.NOT_STARTED) {
      this.initialState = InitialState.STARTED;
    } else if (this.initialState === InitialState.READY_TO_DISPATCH) {
      this.dispatchApplication();
    }
  }

  /** The in-call screen presenter, created lazily by `start()`. */
  get callScreen(): CallScreenPresenter | undefined {
    return this.callScreenPresenter;
  }

  /**
   * Swift: `func initialLoadingCompleted()`. Called when the backend finished loading.
   * The Jami daemon is a disclosed gap, so whatever owns backend startup calls this
   * with its real outcome — this module never assumes a daemon came up.
   */
  initialLoadingCompleted(): void {
    if (this.initialState === InitialState.NOT_STARTED) {
      this.initialState = InitialState.READY_TO_DISPATCH;
    } else if (this.initialState === InitialState.STARTED) {
      this.dispatchApplication();
    }
  }

  /** Swift: `func dispatchApplication()`. */
  dispatchApplication(): void {
    if (this.initialState === InitialState.COMPLETED) {
      return;
    }
    this.initialState = InitialState.COMPLETED;
    this.checkAccounts();
  }

  /** Swift: `private func checkAccounts()` — the app-level route decision. */
  private checkAccounts(): void {
    const accountService: AccountsService = this.injectionBag.accountService;
    if (accountService.accounts.length === 0) {
      this.stateSubject.onNext(AppState.needToOnboard(true, true));
      return;
    }
    const current = accountService.currentAccount;
    if (current !== undefined && current !== null && accountService.needAccountMigration(current.id)) {
      this.stateSubject.onNext(AppState.needAccountMigration(current.id));
      return;
    }
    this.stateSubject.onNext(AppState.allSet());
  }

  /** Swift: `func migrateAccount(accountId:)` — replaces the navigation stack with the migration view. */
  migrateAccount(accountId: string): void {
    this.migratingAccountId = accountId;
    this.navigationController.setViewControllers([AppRoute.ACCOUNT_MIGRATION]);
  }

  /** Swift: `func showInitialLoading()`. */
  showInitialLoading(): void {
    this.navigationController.setViewControllers([AppRoute.INITIAL_LOADING]);
  }

  /** Swift: `func showDatabaseError()` — presents the db-failure alert. */
  showDatabaseError(): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'local database could not be opened');
    this.alerts.onNext(new AlertRequest(ALERT_DB_FAILED_TITLE_KEY, ALERT_DB_FAILED_MESSAGE_KEY));
  }

  /** Swift: `private func showWalkthrough(animated:isAccountFirst:)`. */
  private showWalkthrough(animated: boolean, isAccountFirst: boolean): void {
    const walkthrough: ChildCoordinator = new ChildCoordinator(CoordinatorKind.WALKTHROUGH, this.navigationController);
    walkthrough.parentCoordinator = this;
    walkthrough.isAccountFirst = isAccountFirst;
    walkthrough.withAnimations = animated;
    walkthrough.start();
    this.addChildCoordinator(walkthrough);
  }

  /**
   * Swift: the `controllerWasDismissed` subscription set up in `showWalkthrough` —
   * the onboarding page calls this when it is dismissed.
   */
  walkthroughDismissed(): void {
    const walkthrough: ChildCoordinator | undefined =
      this.childCoordinators.find((item: ChildCoordinator) => item.kind === CoordinatorKind.WALKTHROUGH);
    if (walkthrough === undefined) {
      return;
    }
    walkthrough.disposeBag.dispose();
    this.removeChildCoordinator(walkthrough);
    this.checkAccounts();
  }

  /** Swift: `private func showMainInterface()`. */
  private showMainInterface(): void {
    if (this.isConversationsPresented()) {
      return;
    }
    const conversations: ChildCoordinator = new ChildCoordinator(CoordinatorKind.CONVERSATIONS, this.navigationController);
    conversations.parentCoordinator = this;
    this.addChildCoordinator(conversations);
    conversations.start();
  }

  /** Swift: `private func isConversationsPresented()`. */
  private isConversationsPresented(): boolean {
    return this.childCoordinators.some((item: ChildCoordinator) => item.kind === CoordinatorKind.CONVERSATIONS);
  }

  /** Swift: `Coordinator.addChildCoordinator`. */
  addChildCoordinator(child: ChildCoordinator): void {
    this.childCoordinators.push(child);
    this.conversationsPresented.accept(this.isConversationsPresented());
  }

  /** Swift: `Coordinator.removeChildCoordinator`. */
  removeChildCoordinator(child: ChildCoordinator): void {
    this.childCoordinators = this.childCoordinators.filter((item: ChildCoordinator) => item !== child);
    this.conversationsPresented.accept(this.isConversationsPresented());
  }

  /**
   * Swift: `func openConversation(participantID:accountId:)` →
   * `ConversationsCoordinator.openConversationFromNotificationFor` (pop to smart list, then open).
   */
  openConversation(participantID: string, accountId: string): void {
    const coordinator: ChildCoordinator | undefined = this.conversationsCoordinator;
    if (coordinator === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'openConversation ignored: the main interface is not presented');
      return;
    }
    this.navigationController.popToRoot();
    coordinator.stateSubject.onNext(new CoordinatorCommand(
      CoordinatorCommandKind.OPEN_CONVERSATION_FOR_PARTICIPANT, accountId, '', participantID, '', '', false));
  }

  /** Swift: `func openConversation(conversationId:accountId:)` (the notification overload). */
  openConversationForId(conversationId: string, accountId: string): void {
    const coordinator: ChildCoordinator | undefined = this.conversationsCoordinator;
    if (coordinator === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'openConversationForId ignored: the main interface is not presented');
      return;
    }
    this.navigationController.popToRoot();
    coordinator.stateSubject.onNext(new CoordinatorCommand(
      CoordinatorCommandKind.OPEN_CONVERSATION_FOR_ID, accountId, conversationId, '', '', '', false));
  }

  /** Swift: `CallScreenPresenter.onOpenConversation` → `openConversationFromCall(route:)`. */
  openConversationFromCall(route: CallConversationRoute): void {
    const coordinator: ChildCoordinator | undefined = this.conversationsCoordinator;
    if (coordinator === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'openConversationFromCall ignored: the main interface is not presented');
      return;
    }
    coordinator.stateSubject.onNext(new CoordinatorCommand(
      CoordinatorCommandKind.OPEN_CONVERSATION_FROM_CALL, route.accountId, route.conversationId,
      '', route.peerUri, '', false));
  }

  /** Swift: `func joinCall(callURI:isAudioOnly:)` → `startOutgoingCall(contactRingId:userName:"" ...)`. */
  joinCall(callURI: string, isAudioOnly: boolean): void {
    const coordinator: ChildCoordinator | undefined = this.conversationsCoordinator;
    if (coordinator === undefined) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'joinCall ignored: the main interface is not presented');
      return;
    }
    coordinator.stateSubject.onNext(new CoordinatorCommand(
      CoordinatorCommandKind.START_OUTGOING_CALL, '', '', callURI, callURI, '', isAudioOnly));
  }

  /** Swift: `func startCall(participant:name:isVideo:)` — from a recent call in the phone book. */
  startCall(participant: string, name: string, isVideo: boolean): void {
    for (const child of this.childCoordinators) {
      if (child.kind !== CoordinatorKind.CONVERSATIONS) {
        continue;
      }
      const kind: CoordinatorCommandKind =
        isVideo ? CoordinatorCommandKind.START_CALL : CoordinatorCommandKind.START_AUDIO_CALL;
      child.stateSubject.onNext(new CoordinatorCommand(kind, '', '', participant, participant, name, !isVideo));
      return;
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'startCall ignored: the main interface is not presented');
  }

  /** Release the state subscription. Swift relies on the coordinator living for the whole app run. */
  dispose(): void {
    try {
      this.disposeBag.dispose();
    } finally {
      this.callScreenPresenter = undefined;
    }
  }
}
