/**
 * The app's composition root.
 *
 * The Phase-2 data layer is registry-built with zero-argument constructors, and a `.ts` module
 * cannot call `getContext()`. Every injector below is therefore load-bearing: without it the
 * screens read `null` at runtime.
 *
 * Deep links (`aa start ... --ps targetPage <Name>`, resolved through the generated
 * `common/RouteAliases.ts`): on a COLD start the ability only RECORDS the target - the initial
 * route belongs to `InitialLoadingPage`, the one component that knows when bootstrap finished.
 * On a relaunch of a live app (`onNewWant`) nothing is bootstrapping, so it routes immediately.
 */
import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { AccountModel } from '../model/AccountModel';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

import { ProfileStore } from '../common/ProfileStore';
import { PreferenceManager } from '../common/PreferenceManager';
import { setModelResources } from '../model/MessageModel';
import { ConversationsManager, setConversationsManagerContext } from '../common/ConversationsManager';
import { DBManager } from '../common/DbManager';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { CallsManager } from '../common/CallsManager';
import { CallUiService } from '../common/CallUiService';
import { setAccountMessageHandler } from '../common/JamiNative';
import { describeError } from '../common/ErrorText';
import { ShareActions } from '../common/ShareActions';
import {
  beginInitialRoute, isInitialRouteDone, resolveTargetOverlay, resolveTargetPage,
  setPendingTarget
} from '../common/RouteAliases';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

/** The plan's cold-start root (`screen_initial_loading`). */
const ROOT_PAGE: string = 'pages/InitialLoadingPage';

/** Where a share from another app lands (`ROUTE_ALIASES`): the iOS jamiShareExtension's ShareView. */
const SHARE_TARGET: string = 'ShareExtensionPage';

/** Router params for a deep link whose target is an overlay hosted by the routed page. */
interface OverlayRouteParams {
  overlayScreen: string;
}

/** Swift AccountMigrationView(accountId:): the page and the account it migrates. */
const MIGRATION_PAGE: string = 'pages/AccountMigrationPage';

interface MigrationRouteParams {
  accountId: string;
  /** Swift `.replaceNavigationStack`: the page is the only screen, so it has no Back. */
  replacesStack: boolean;
}

export default class EntryAbility extends UIAbility {
  /** Built in `onCreate`, handed to the four services that need it, disposed in `onDestroy`. */
  private db: DBManager | null = null;
  private callsManager: CallsManager | null = null;
  private callUi: CallUiService | null = null;
  private conversationsManager: ConversationsManager | null = null;
  /** The root page is loaded: the window can now carry the notification prompt. */
  private contentLoaded: boolean = false;
  /** Ends the network -> daemon connectivityChanged subscription made in `onCreate`. */
  private stopConnectivityChanges: () => void = (): void => {};

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'set colorMode failed: %{public}s', describeError(error as BusinessError));
    }

    // 1. static context injectors (no registry needed)
    try {
      ProfileStore.setContext(this.context);
      PreferenceManager.setContext(this.context);
      setModelResources(this.context.resourceManager);
      setConversationsManagerContext(this.context);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'static context injection failed: %{public}s',
        describeError(error as BusinessError));
    }

    const registry: ServiceRegistry = ServiceRegistry.shared();

    // 2. the database layer - ONE DBManager handed to the four services that need it
    try {
      const db: DBManager = new DBManager();
      db.setContext(this.context);
      this.db = db;
      registry.accountService.setDbManager(db);
      registry.conversationsService.setDatabase(db);
      registry.contactsService.setDatabase(db);
      registry.dataTransferService.setDatabase(db);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'database injection failed: %{public}s',
        describeError(error as BusinessError));
    }

    // 3. the remaining per-service injectors
    try {
      registry.accountService.setResources(this.context.resourceManager);
      registry.accountService.setFilesDir(this.context.filesDir);
      registry.conversationsService.setContext(this.context);
      registry.dataTransferService.setContext(this.context);
      registry.videoService.setContext(this.context);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'service injection failed: %{public}s',
        describeError(error as BusinessError));
    }

    // 3b. network reachability. The monitor is the ONLY writer of `networkService.connectionState`,
    // so without this one call the relay keeps its `ConnectionType.NONE` default for the whole
    // process lifetime and the app believes it is permanently offline (a standing "no network"
    // banner, the DISCONNECTED variant of every connectivity-branching screen). It starts here
    // because the composition root is the one place that runs exactly once; it is idempotent, and
    // it seeds the current state synchronously so the first render is already correct. Released in
    // `onDestroy` - a registered NetConnection is a held OS resource.
    // Swift AppDelegate: a real transition (never the first evaluation) tells the daemon, which
    // does not watch the network itself; without it the DHT and every peer channel stay bound to
    // the lost network and outgoing messages, invites and transfers wait on dead connections.
    try {
      this.stopConnectivityChanges = registry.networkService.connectivityChangedObservable
        .subscribe((): void => {
          registry.daemonService.connectivityChanged();
        });
      registry.networkService.monitorNetworkType();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'network monitor startup failed: %{public}s',
        describeError(error as BusinessError));
    }

    // 4. CallsManager - the registry holds it as a mutable nullable field, the root assigns it
    try {
      const callsManager: CallsManager = new CallsManager();
      registry.callsManager = callsManager;
      callsManager.start();
      this.callsManager = callsManager;

      // 5. the call-UI substitution (the registry deliberately does NOT vend it)
      const callUi: CallUiService = new CallUiService();
      callUi.setContext(this.context);
      callUi.start(callsManager.callKit);
      this.callUi = callUi;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'call layer startup failed: %{public}s',
        describeError(error as BusinessError));
    }

    // 5b. the Jami daemon (libjami over NAPI). Before the conversations manager, whose event
    // pipeline it feeds, and before InitialLoadingPage loads the account list from it.
    try {
      registry.daemonService.startDaemon(this.context.filesDir);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'daemon startup failed: %{public}s', describeError(error as BusinessError));
    }

    // 6. the conversations manager (owns no registry slot; the root builds and starts it)
    try {
      const conversationsManager: ConversationsManager = new ConversationsManager();
      conversationsManager.start();
      this.conversationsManager = conversationsManager;
      setAccountMessageHandler((payloads: Map<string, string>, from: string, messageId: string,
        accountId: string): void => {
        conversationsManager.didReceiveMessage(payloads, from, messageId, accountId);
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'conversations manager startup failed: %{public}s',
        describeError(error as BusinessError));
    }

    // 6b. Swift AppDelegate: reload an account's requests, conversations and contacts once the
    // accounts are loaded and whenever the current account changes (`reloadDataFor(account:)`).
    try {
      registry.accountService.currentWillChange.subscribe((account: AccountModel | null): void => {
        if (account !== null) {
          registry.conversationsService.clearConversationsData(account.id);
          registry.presenceService.subscribeBuddies(account.id, registry.contactsService.contacts.value,
            false);
        }
      });
      registry.accountService.currentAccountChanged.subscribe((account: AccountModel | null): void => {
        if (account !== null) {
          this.reloadDataFor(account);
          this.requestNotificationPermission();
        }
      });
      // Swift AppDelegate.prepareAccounts(): the current account entering ERROR_NEED_MIGRATION
      // while the app runs (a JAMS device token refused) goes to AppCoordinator.migrateAccount.
      registry.accountService.needMigrateCurrentAccount.subscribe((accountId: string): void => {
        this.migrateAccount(accountId);
      });
      registry.accountService.initialAccountsLoading().then((): void => {
        // Swift AppDelegate: restore the account the user last selected.
        const saved: AccountModel | null =
          registry.accountService.getAccount(PreferenceManager.getSelectedAccountId());
        if (saved !== null) {
          // Publishes currentAccountChanged, whose subscriber above reloads the account's data.
          registry.accountService.currentAccount = saved;
          return;
        }
        const current: AccountModel | null = registry.accountService.currentAccount;
        if (current !== null) {
          this.reloadDataFor(current);
          this.requestNotificationPermission();
        }
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'account data loading failed: %{public}s', describeError(error as BusinessError));
    }

    // Deep link on a cold start: RECORD it, never route it from here. `InitialLoadingPage` is the
    // one component that knows when bootstrap has finished, so it owns the initial route and
    // consumes this. Routing from the ability as well raced its redirect, and the app ended up on
    // whichever call lost.
    const target: string = EntryAbility.readTarget(want);
    beginInitialRoute(target);
    hilog.info(DOMAIN, TAG, 'onCreate (targetPage %{public}s) - held for InitialLoadingPage',
      target.length > 0 ? target : '<none>');
  }

  /** Launch type is `singleton`: a second `aa start` on a live app arrives here only. */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.callUi?.handleWant(want.parameters);
    const target: string = EntryAbility.readTarget(want);
    hilog.info(DOMAIN, TAG, 'onNewWant (targetPage %{public}s)',
      target.length > 0 ? target : '<none>');
    if (target.length === 0) {
      return;
    }
    if (isInitialRouteDone()) {
      // The app is past bootstrap and the loading page has handed the route over: nothing else
      // is routing, so push straight away.
      this.routeToTarget(target);
      return;
    }
    // A relaunch that arrived while the loading page still owns the route: hand it the target
    // rather than pushing against it.
    setPendingTarget(target);
  }

  /**
   * The page a launch asks for: the share page when the system share panel started us (the
   * sendData skill in module.json5; the records go to ShareExtensionPage through ShareActions),
   * otherwise the `targetPage` deep link.
   */
  private static readTarget(want: Want): string {
    return ShareActions.receiveSharedWant(want) ? SHARE_TARGET : EntryAbility.readTargetPage(want);
  }

  /** `want.parameters.targetPage`, or '' when the launch carried none. */
  private static readTargetPage(want: Want): string {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters === undefined) {
      return '';
    }
    const raw: Object | undefined = parameters['targetPage'];
    if (typeof raw === 'string') {
      return raw as string;
    }
    return '';
  }

  /** Resolve a source page identity through RouteAliases and push it. Unknown = stay on root. */
  private routeToTarget(name: string): void {
    const url: string = resolveTargetPage(name);
    if (url.length === 0) {
      hilog.warn(DOMAIN, TAG, 'unknown targetPage %{public}s; staying on the root page', name);
      return;
    }
    const overlay: string = resolveTargetOverlay(name);
    if (overlay.length > 0) {
      const params: OverlayRouteParams = { overlayScreen: overlay };
      router.pushUrl({ url: url, params: params }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'pushUrl %{public}s failed: %{public}s', url, describeError(error));
      });
    } else {
      router.pushUrl({ url: url }).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'pushUrl %{public}s failed: %{public}s', url, describeError(error));
      });
    }
  }

  /**
   * Swift AppDelegate `registerNotifications()`: asked at launch when an account exists and when
   * one is created (the current account changes then too), so the first call never raises it.
   */
  private requestNotificationPermission(): void {
    if (this.contentLoaded && ServiceRegistry.shared().accountService.currentAccount !== null) {
      this.callUi?.requestNotificationPermission();
    }
  }

  /**
   * Swift `AppCoordinator.migrateAccount(accountId:)`: the migration view replaces the whole
   * navigation stack. Before the loading page has handed the route over, its own
   * `checkAccounts()` routes a migrating current account, so nothing is pushed against it.
   */
  private migrateAccount(accountId: string): void {
    hilog.info(DOMAIN, TAG, 'current account %{public}s needs migration (route live: %{public}s)',
      accountId, String(isInitialRouteDone()));
    if (!isInitialRouteDone()) {
      return;
    }
    const params: MigrationRouteParams = { accountId: accountId, replacesStack: true };
    router.clear();
    router.replaceUrl({ url: MIGRATION_PAGE, params: params }).catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'replaceUrl %{public}s failed: %{public}s', MIGRATION_PAGE,
        describeError(error));
    });
  }

  /** Swift `AppDelegate.reloadDataFor(account:)`. */
  private reloadDataFor(account: AccountModel): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    registry.requestsService.loadRequests(account.id, account.jamiId);
    this.conversationsManager?.prepareConversationsForAccount(account.id, account.jamiId);
    // Swift subscribes the contacts' presence right after loadContacts (T-1635). A jami account's
    // list is read synchronously; a SIP one waits on the database.
    registry.contactsService.loadContacts(account).then((): void => this.subscribePresence(true));
  }

  /**
   * Swift `subscribeBuddies(withAccount:withContacts:subscribe:)` for the current account's
   * contacts: after loading them, and in `sceneWillEnterForeground` / `sceneDidEnterBackground`.
   */
  private subscribePresence(subscribe: boolean): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.currentAccount;
    if (account !== null) {
      registry.presenceService.subscribeBuddies(account.id, registry.contactsService.contacts.value, subscribe);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    try {
      if (this.callUi !== null) {
        this.callUi.stop();
      }
      if (this.callsManager !== null) {
        this.callsManager.stop();
      }
      if (this.conversationsManager !== null) {
        this.conversationsManager.stop();
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'teardown failed: %{public}s', describeError(error as BusinessError));
    } finally {
      if (this.db !== null) {
        this.db.dispose();
      }
      // The NetConnection registered in `onCreate` is a held OS resource (Rule 8).
      this.stopConnectivityChanges();
      ServiceRegistry.shared().networkService.dispose();
      ServiceRegistry.shared().callsManager = null;
      this.callUi = null;
      this.callsManager = null;
      this.conversationsManager = null;
      this.db = null;
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent(ROOT_PAGE, (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      this.contentLoaded = true;
      this.requestNotificationPermission();
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    try {
      ServiceRegistry.shared().locationSharingService.setAppForeground(true);
      if (this.conversationsManager !== null) {
        this.conversationsManager.appMovedForeground();
      }
      this.subscribePresence(true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'onForeground failed: %{public}s', describeError(error as BusinessError));
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    try {
      ServiceRegistry.shared().locationSharingService.setAppForeground(false);
      if (this.conversationsManager !== null) {
        this.conversationsManager.appMovedToBackground();
      }
      this.subscribePresence(false);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'onBackground failed: %{public}s', describeError(error as BusinessError));
    }
  }
}
