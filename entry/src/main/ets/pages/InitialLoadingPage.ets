/*
 * screen_initial_loading — ported from
 *   Ring/Ring/Features/InitialLoading/InitialLoadingViewController.swift (+ .storyboard)
 *   Ring/Ring/Coordinators/AppCoordinator.swift (showInitialLoading / checkAccounts)
 *
 * The source screen is an EMPTY `UIColor.systemBackground` view whose only job is to let
 * AppCoordinator.checkAccounts() replace the root stack. All three nav edges out of it are
 * `kind: replace`, triggered by no control at all — so they live in the page's own lifecycle,
 * exactly as in the source.
 *
 * THIS PAGE IS THE APP'S ONLY INITIAL-ROUTE WRITER. A cold-start deep link
 * (`want.parameters.targetPage`) is recorded by EntryAbility and consumed here, because only
 * this page knows when bootstrap has finished. It leaves exactly once, by `replaceUrl`, when
 * BOTH facts are in — bootstrap completed and the page is on screen — and it always leaves:
 * the deep-link target, else the coordinator's route, else onboarding.
 */
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import hilog from '@ohos.hilog';
import { AppRoute, AppStateService, AppStateServices } from '../common/AppStateService';
import { AccountsService } from '../common/AccountsService';
import { AccountModel } from '../model/AccountModel';
import { ServiceRegistry } from '../common/ServiceRegistry';
import {
  isOnboardingFlowPage, isSettingsFlowPage, resolveTargetOverlay, resolveTargetPage,
  takePendingTarget
} from '../common/RouteAliases';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'InitialLoading';

/** The onboarding screen: `checkAccounts()` with no accounts, and the last-resort destination. */
const WALKTHROUGH_PAGE: string = 'pages/WelcomeOnboardingPage';
/** The conversations coordinator's root — the parent of every main-flow screen. */
const SMART_LIST_PAGE: string = 'pages/SmartListConversationsHomePage';
/** SettingsCoordinator's root — the parent of every settings sub-page. */
const SETTINGS_ROOT_PAGE: string = 'pages/AccountSummarySettingsRootPage';
/** This page. A deep link may name it, and then there is nowhere to go. */
const SELF_PAGE: string = 'pages/InitialLoadingPage';
/** AppState.needAccountMigration -> AppCoordinator.migrateAccount(accountId:). */
const MIGRATION_PAGE: string = 'pages/AccountMigrationPage';

/** Router params for a deep link whose target is an overlay hosted by the routed page. */
interface OverlayRouteParams {
  overlayScreen: string;
}

/** AccountMigrationPage's route param: `.replaceNavigationStack`, the page has no Back. */
interface MigrationRouteParams {
  replacesStack: boolean;
}

@Entry
@Component
struct InitialLoadingPage {
  /*
   * The three startup-route branches. Swift: AppCoordinator.checkAccounts() picks exactly one
   * of AppState.needToOnboard / .needAccountMigration / .allSet. They are state here because the
   * page renders while the decision is still pending, and the route below is driven by them.
   */
  /** `accountService.accounts.isEmpty` -> AppState.needToOnboard. */
  @State isNoAccounts: boolean = false;
  /** `accountService.needAccountMigration(accountId:)` -> AppState.needAccountMigration. */
  @State isNeedsMigration: boolean = false;
  /** neither of the above -> AppState.allSet. */
  @State isAllSet: boolean = false;
  /** True until `initialAccountsLoading()` has settled — the source's initial-loading state. */
  @State isLoading: boolean = true;
  /** `initialAccountsLoading()` failed; empty when there is no failure. */
  @State errorText: string = '';
  /** Swift: `accountService.currentAccount?.id`, shared with every screen that needs it. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift: AppCoordinator — the coordinator that owns the cold-start route decision. */
  private appState: AppStateService | null = null;
  /** Set once `initialAccountsLoading()` has settled and the coordinator has dispatched. */
  private bootstrapDone: boolean = false;
  /** Set by `onPageShow`: the router is live, so a route call cannot be lost to page loading. */
  private shown: boolean = false;
  /** This page leaves exactly once. */
  private routed: boolean = false;

  aboutToAppear(): void {
    const accounts: AccountsService = ServiceRegistry.shared().accountService;
    const coordinator: AppStateService = new AppStateService(new AppStateServices(accounts));
    this.appState = coordinator;
    coordinator.start();
    this.bootstrap(accounts, coordinator);
  }

  onPageShow(): void {
    this.shown = true;
    this.leave();
  }

  /**
   * The coordinator this page created is its own instance, and its constructor subscribed to
   * `stateSubject`. The page is destroyed by the `replaceUrl` that leaves it, so the subscription
   * has to go with it — Swift keeps the app coordinator alive for the whole run instead.
   */
  aboutToDisappear(): void {
    const coordinator: AppStateService | null = this.appState;
    if (coordinator !== null) {
      try {
        coordinator.dispose();
      } finally {
        this.appState = null;
      }
    }
  }

  /**
   * Swift: the daemon reports it finished starting and AppCoordinator.initialLoadingCompleted()
   * dispatches. The Jami daemon is a disclosed gap here, so the account load is what we wait on;
   * whatever its outcome, the app must still dispatch — `finally` guarantees it.
   */
  private async bootstrap(accounts: AccountsService, coordinator: AppStateService): Promise<void> {
    try {
      await accounts.initialAccountsLoading();
    } catch (err) {
      // checkAccounts() treats "no accounts" as onboarding, which is the correct outcome here.
      this.errorText = describeError(err as BusinessError);
    } finally {
      // Swift `checkAccounts()`, read off the same service the coordinator reads.
      this.resolveStartupRoute(accounts);
      // Synchronous: dispatchApplication -> checkAccounts -> the route stack is final on return.
      coordinator.initialLoadingCompleted();
      this.bootstrapDone = true;
      this.isLoading = false;
      this.leave();
    }
  }

  /**
   * Swift `AppCoordinator.checkAccounts()`:
   *   accounts.isEmpty                                  -> needToOnboard
   *   currentAccount?.id && needAccountMigration(id)    -> needAccountMigration
   *   otherwise                                         -> allSet
   * Exactly one of the three flags is true afterwards.
   */
  private resolveStartupRoute(accounts: AccountsService): void {
    const current: AccountModel | null = accounts.currentAccount;
    this.currentAccountId = current === null ? '' : current.id;
    this.isNoAccounts = accounts.accounts.length === 0;
    this.isNeedsMigration = !this.isNoAccounts && current !== null &&
      accounts.needAccountMigration(current.id);
    this.isAllSet = !this.isNoAccounts && !this.isNeedsMigration;
  }

  /** Both facts in, once. Neither can be skipped, so the app can never stay on this page. */
  private leave(): void {
    if (this.routed || !this.bootstrapDone || !this.shown) {
      return;
    }
    this.routed = true;
    const target: string = takePendingTarget();
    if (target.length > 0) {
      // The launch asked for THIS page by name. The source shows the same screen for as long as
      // the coordinator has not moved on (`showInitialLoading()`), and the capture records it as
      // a state of its own — so render it and stay. Routing here would replace the page with
      // itself, and the reloaded page finds no pending target and leaves.
      if (resolveTargetPage(target) === SELF_PAGE) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'targetPage names this page; staying on the loading screen');
        return;
      }
      if (this.replaceWithDeepLink(target)) {
        return;
      }
    }
    // `replace`: the source calls setViewControllers([...]) — the loading screen is gone for good.
    this.replace(this.coordinatorUrl());
  }

  /** The deep link's destination, or false when the launch named a target nothing maps. */
  private replaceWithDeepLink(target: string): boolean {
    const url: string = resolveTargetPage(target);
    if (url.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'unknown targetPage %{public}s; using the cold-start route',
        target);
      return false;
    }
    const overlay: string = resolveTargetOverlay(target);
    // An overlay is hosted by `url`: the host opens it from this param in onPageShow.
    let params: OverlayRouteParams | null = null;
    if (overlay.length > 0) {
      const overlayParams: OverlayRouteParams = { overlayScreen: overlay };
      params = overlayParams;
    }
    this.routeDeepLink(url, params);
    return true;
  }

  /**
   * A deep link lands mid-stack in the source: every screen below a coordinator root has that
   * root under it, so `back()` out of it pops to the root rather than to nothing. Seed that
   * parent before showing the target — replace with the root, then push the target onto it.
   * A target that IS a root (or an onboarding entry) keeps the single `replaceUrl`.
   */
  private routeDeepLink(url: string, params: OverlayRouteParams | null): void {
    const root: string = this.rootFor(url);
    const options: router.RouterOptions = { url: url };
    if (params !== null) {
      options.params = params;
    }
    if (root.length === 0) {
      router.replaceUrl(options).catch((error: BusinessError) => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s', url,
          describeError(error));
      });
      return;
    }
    // Chained, never concurrent: the push must land on a stack the replace has already reset.
    router.replaceUrl({ url: root }).then((): Promise<void> => {
      return router.pushUrl(options);
    }).catch((error: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'seeding %{public}s under %{public}s failed: %{public}s',
        url, root, describeError(error));
    });
  }

  /** The coordinator root a deep-linked page needs beneath it, or '' when it is itself a root. */
  private rootFor(url: string): string {
    if (url === SMART_LIST_PAGE || url === SETTINGS_ROOT_PAGE || url === WALKTHROUGH_PAGE ||
      url === SELF_PAGE) {
      return '';
    }
    if (isSettingsFlowPage(url)) {
      return SETTINGS_ROOT_PAGE;
    }
    if (isOnboardingFlowPage(url)) {
      return WALKTHROUGH_PAGE;
    }
    return SMART_LIST_PAGE;
  }

  /** AppRoute -> the registered page that renders it. Onboarding is the unreachable-case default. */
  private coordinatorUrl(): string {
    const coordinator: AppStateService | null = this.appState;
    if (coordinator === null) {
      return WALKTHROUGH_PAGE;
    }
    const routes: Array<AppRoute> = coordinator.rootViewController.viewControllers;
    const top: AppRoute | undefined = routes.length === 0 ? undefined : routes[routes.length - 1];
    if (top === AppRoute.SMART_LIST) {
      return 'pages/SmartListConversationsHomePage';
    }
    if (top === AppRoute.ACCOUNT_MIGRATION) {
      return MIGRATION_PAGE;
    }
    // WALKTHROUGH — and anything that never dispatched, which must not strand the app here.
    return WALKTHROUGH_PAGE;
  }

  private replace(url: string): void {
    const options: router.RouterOptions = { url: url };
    if (url === MIGRATION_PAGE) {
      // Swift AppCoordinator.migrateAccount presents with .replaceNavigationStack: no Back (T-1739).
      const params: MigrationRouteParams = { replacesStack: true };
      options.params = params;
    }
    router.replaceUrl(options).catch((error: BusinessError) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s', url,
        describeError(error));
    });
  }

  /*
   * S3 structure — InitialLoadingViewController.storyboard declares exactly two subviews and
   * no control at all (controlInventory is empty):
   *   - imageView "backgroundLogin", pinned to all four edges, contentMode scaleAspectFill
   *   - imageView "jamiIcon", 120x120, centerX, centerY offset -75, contentMode scaleAspectFit
   * Nothing else is on this screen; the coordinator replaces it as soon as checkAccounts()
   * returns, which is what the lifecycle above does.
   */
  /**
   * The storyboard's centred `jamiIcon`. The source renders the SAME view for every outcome of
   * checkAccounts() — the branch decides where the coordinator goes, not what is drawn — so all
   * three route branches below render this one builder.
   */
  @Builder
  splash() {
    // S5 — capture S0001: `jamiIcon` sits at [136,291][256,411] in the 393x852 pt window, i.e.
    // 120x120 centred on x and 75 pt above the window's vertical centre. The storyboard's
    // scaleAspectFit is ImageFit.Contain. Decorative: the storyboard gives it no label, and it
    // is the same mark the background already carries, so the screen reader skips it.
    Image($r('app.media.jami_icon'))
      .width(120)
      .height(120)
      .objectFit(ImageFit.Contain)
      .offset({ y: -75 })
      // Rule 12: the SOURCE element's slug, verbatim — the capture records this node as
      // resource-id `jamiIcon`, and the on-device drivers locate a node only by text or .id().
      .id('jamiIcon')
      .accessibilityLevel('no')
  }

  build() {
    Stack() {
      // S5 — capture S0001: `backgroundLogin` is pinned to all four window edges ([0,0][393,852],
      // status bar included), scaleAspectFill. Cover + expandSafeArea on the root is that, and
      // the image is pure decoration.
      Image($r('app.media.background_login'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        // Rule 12: source slug, verbatim — capture resource-id `backgroundLogin`.
        .id('backgroundLogin')
        .accessibilityLevel('no')
      if (this.isLoading) {
        // The daemon/account load is still in flight — the source's `.initialLoading` state.
        this.splash()
      } else if (this.isNoAccounts) {
        // AppState.needToOnboard — the walkthrough replaces this stack (see `leave()`).
        this.splash()
      } else if (this.isNeedsMigration) {
        // AppState.needAccountMigration — the migration page replaces this stack.
        this.splash()
      } else if (this.isAllSet) {
        // AppState.allSet — the conversations home replaces this stack.
        this.splash()
      }
      if (this.errorText.length > 0) {
        // The storyboard has no error view, so the capture cannot style this. It is failure
        // chrome over a photographic background: a scrim keeps it legible on any part of the
        // image, and it sits clear of the logo at the foot of the screen.
        Column() {
          Text(this.errorText)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_on_primary'))
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '88%' })
            .padding($r('sys.float.ohos_id_card_margin_start'))
            .backgroundColor($r('app.color.jami_on_video_scrim'))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    // Never leave a surface unpainted: if the cover image is slow or missing, the page must
    // still be the source's `UIColor.systemBackground`, not the device's raw window.
    .backgroundColor($r('sys.color.background_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .id('screen_initial_loading')
  }
}
