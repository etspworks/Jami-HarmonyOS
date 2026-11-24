/*
 * screen_requests — "Conversation Requests", ported from
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/RequestsView.swift
 *   Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/RequestsViewModel.swift
 *
 * presentation: sheet, hostScreen: screen_smart_list. SmartListContentView presents it on
 * requestsModel.requestViewOpened, so it is the content of a .bindSheet() mounted by
 * SmartListConversationsHomePage — NOT a routed page and NOT in main_pages.json.
 *
 * Swift `RequestsView.body`:
 *   NavigationView { VStack(spacing: 0) {
 *     ZStack { HStack { Spacer(); CloseButton(...requestsCloseButton) }
 *              Text(model.title).font(.headline) }
 *     requestsList              // ScrollView { ForEach(model.requestsRow) { RequestsRowView } }
 *   } }
 *
 * S3 = STRUCTURE. The invitation list is bound to svc_requests through a keyed ForEach over
 * `invitationList` (bindingContract[invitation list]) — never a literal array; the capture is
 * empty only because a fresh account has no pending invitations. ForEach, not LazyForEach, so
 * a handled row can leave with Swift's `.transition(.slide)`. Both conditionalVariants
 * (`empty` / `has_requests`) are real ArkUI `if` branches. Style is S5/S6.
 *
 * S5 style, read off `RequestsView.body`:
 *   .background(Color.jamiRequestsBackground.ignoresSafeArea())
 *       -> app.color.jami_requests_background on the sheet root
 *   Text(model.title).font(.headline).foregroundColor(Color(UIColor.systemBackground))
 *       -> Body_L + FontWeight.Medium + sys.color.background_primary, centred in the ZStack
 * Everything the page adds that the source has no counterpart for (the spinner, the empty
 * line, the daemon notice, the error line) takes the SAME systemBackground foreground: on a
 * navy card the default font_primary is black on navy, i.e. invisible.
 *
 * THE DAEMON GAP. Accept / Reject / Block all bottom out in libjami
 * (`RequestsService.acceptConverversationRequest` and friends reject with
 * DaemonUnavailableError, `ContactsService.removeContact` the same). Each control therefore
 * surfaces the disclosed `daemon_not_available` notice — the DialpadPage pattern — and never
 * returns silently, which would ship three dead taps.
 */
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { RequestModel } from '../model/RequestModel';
import { AccountModel } from '../model/AccountModel';
import { CloseButton } from '../components/CloseButton';
import { RequestRowViewModel, RequestsRowView } from '../components/RequestsRow';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ConversationRequestsSheet';
/** The in-flight spinner's box; the source has no loading state, so nothing dictates a size. */
const LOADING_SIZE: number = 32;
/** Swift `markRowsForRemoval`: `withAnimation(.easeInOut(duration: 0.2)) { markedToRemove = true }`. */
const MARK_DURATION_MS: number = 200;
/** Swift `scheduleRowRemoval`: `asyncAfter(.now() + 0.6)`, then `.easeInOut(duration: 0.5)`. */
const REMOVE_DELAY_MS: number = 600;
const REMOVE_DURATION_MS: number = 500;
/** Swift `processNewRequests`: with no request left, `requestViewOpened = false` 0.5 s later. */
const CLOSE_DELAY_MS: number = 500;

@Component
export struct ConversationRequestsSheet {
  /** Owned by screen_smart_list; the host's @State drives the sheet. */
  @Link isPresented: boolean;

  /** Swift `@Published var requestsRow = [RequestRowViewModel]()` — bindingContract[invitation list]. */
  @State invitationList: RequestRowViewModel[] = [];
  /** conditionalVariants[empty] — Swift `model.requestsRow` is empty. */
  @State isEmpty: boolean = true;
  /** conditionalVariants[has_requests] — one row per pending RequestModel. */
  @State hasRequests: boolean = false;
  /**
   * bindingContract[row name] <- `RequestModel.name` (Swift `nameResolver.bestName`). The page
   * mirrors the newest invitation's name; the render site is RequestsRowView, which reads the
   * same value off its own row model.
   */
  @State rowName: string = '';
  /** bindingContract[row avatar] <- `RequestModel.avatar` (Swift `Image(uiImage: avatar)`). */
  @State rowAvatar: string = '';
  /** True while svc_requests is still loading the account's invitations. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The disclosed Rule-11 daemon gap raised by Accept / Reject / Block. */
  @State showDaemonNotice: boolean = false;
  /** Ids of the rows marked to remove — Swift `.zIndex(markedToRemove ? 1 : 0)` on the item. */
  @State removingIds: string[] = [];
  /**
   * The navigation-indicator avoid height (vp). The SwiftUI ScrollView ends its content above the
   * home-indicator safe area, so the last row and its divider stay clear of the gesture bar.
   */
  @State bottomInset: number = 0;

  /** The pending removal / close timers (Swift `DispatchQueue.main.asyncAfter`). */
  private timers: number[] = [];

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /** Swift `RequestsViewModel.subscribeToNewRequests()`. */
  aboutToAppear(): void {
    this.resolveBottomInset();
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.isLoading = true;
    this.bag.add(registry.requestsService.requests.subscribe(
      (requests: RequestModel[]): void => {
        this.applyRequests(requests);
      }));
    this.applyRequests(registry.requestsService.requests.value);
  }

  aboutToDisappear(): void {
    try {
      this.bag.dispose();
    } finally {
      this.timers.forEach((timer: number) => clearTimeout(timer));
      this.invitationList.forEach((row: RequestRowViewModel) => row.dispose());
    }
  }

  private later(delayMs: number, action: () => void): void {
    this.timers.push(setTimeout(action, delayMs));
  }

  /**
   * Swift `filterRequestsNotInConversations(requests:conversations:accountId:)` +
   * `processNewRequests(_:)`: the invitations of the current account that are not already a
   * conversation. The rows on screen are kept: a handled request's row is marked to remove
   * (its status text, the raised card and the bounce play) and leaves 0.6 s later; a new
   * request is appended, oldest first (`sortRequestsByReceivedDate`).
   */
  private applyRequests(requests: RequestModel[]): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.currentAccount;
    const pending: RequestModel[] = registry.requestsService
      .pendingRequests(requests, account === null ? '' : account.id);
    const pendingIds: Set<string> = new Set<string>(
      pending.map((request: RequestModel) => request.getIdentifier()));

    // Swift `findOutdatedRequests` -> `markRowsForRemoval` -> `scheduleRowRemoval`.
    for (const row of this.invitationList) {
      if (!row.markedToRemove && !pendingIds.has(row.id)) {
        this.getUIContext().animateTo({ duration: MARK_DURATION_MS, curve: Curve.EaseInOut }, () => {
          row.markedToRemove = true;
          this.removingIds = this.removingIds.concat([row.id]);
        });
        this.later(REMOVE_DELAY_MS, () => {
          this.removeRow(row);
        });
      }
    }

    // Swift `findNewRequests` -> `addNewRequests`.
    const shownIds: Set<string> = new Set<string>(
      this.invitationList.map((row: RequestRowViewModel) => row.id));
    const added: RequestRowViewModel[] = pending
      .filter((request: RequestModel) => !shownIds.has(request.getIdentifier()))
      .sort((left: RequestModel, right: RequestModel): number =>
        left.receivedDate.getTime() - right.receivedDate.getTime())
      .map((request: RequestModel) => new RequestRowViewModel(request));
    // Swift `RequestNameResolver.performLookup()`, on the observed rows.
    added.forEach((row: RequestRowViewModel) => row.resolveName());
    if (added.length > 0) {
      this.invitationList = this.invitationList.concat(added);
    }

    const rows: RequestRowViewModel[] = this.invitationList;
    this.hasRequests = rows.length > 0;
    this.isEmpty = rows.length === 0;
    // The newest invitation's bound name/avatar (Swift sorts by receivedDate, so it is last).
    this.rowName = rows.length > 0 ? rows[rows.length - 1].rowName : '';
    this.rowAvatar = rows.length > 0 ? rows[rows.length - 1].rowAvatar : '';
    this.isLoading = false;

    // Swift: `if requestsNameResolvers.count() == 0 { asyncAfter(0.5) { requestViewOpened = false } }`.
    if (pending.length === 0) {
      this.later(CLOSE_DELAY_MS, () => {
        this.isPresented = false;
      });
    }
  }

  /** Swift `scheduleRowRemoval`: `withAnimation(.easeInOut(duration: 0.5)) { removeAll }`. */
  private removeRow(row: RequestRowViewModel): void {
    row.dispose();
    this.getUIContext().animateTo({ duration: REMOVE_DURATION_MS, curve: Curve.EaseInOut }, () => {
      this.invitationList = this.invitationList.filter((item: RequestRowViewModel) => item.id !== row.id);
    });
  }

  /** Swift: the CloseButton — dismisses the sheet (an overlay is not a stack entry). */
  private close(): void {
    this.isPresented = false;
  }

  /** Swift `RequestsViewModel.accept(requestRow:)` -> `requestsService.acceptConverversationRequest`. */
  private accept(row: RequestRowViewModel): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    ServiceRegistry.shared().requestsService
      .acceptConverversationRequest(row.request.conversationId, row.request.accountId)
      .then((): void => {
        // Swift `requestRow.requestAccepted()`, then the presence subscription for a 1:1 peer.
        row.requestAccepted();
        const participants: string[] = [];
        for (const participant of row.request.participants) {
          participants.push(participant.jamiId);
        }
        if (row.request.isCoredialog() && participants.length > 0) {
          ServiceRegistry.shared().presenceService
            .subscribeBuddy(row.request.accountId, participants[0], true);
        }
      })
      .catch((error: Object): void => {
        this.reportActionFailure('accept', error);
      });
  }

  /** Swift `RequestsViewModel.discard(requestRow:)` -> `discardConverversationRequest`. */
  private reject(row: RequestRowViewModel): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    ServiceRegistry.shared().requestsService
      .discardConverversationRequest(row.request.conversationId, row.request.accountId)
      .then((): void => {
        row.requestDiscarded();
      })
      .catch((error: Object): void => {
        this.reportActionFailure('discard', error);
      });
  }

  /**
   * Swift `RequestsViewModel.block(requestRow:)` — discard the request, then
   * `removeContactAndBan(jamiId:accountId:)` -> `contactsService.removeContact(ban: true)`.
   */
  private block(row: RequestRowViewModel): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    const participants: string[] = [];
    for (const participant of row.request.participants) {
      participants.push(participant.jamiId);
    }
    ServiceRegistry.shared().requestsService
      .discardConverversationRequest(row.request.conversationId, row.request.accountId)
      .then((): void => {
        row.requestBlocked();
        if (participants.length > 0) {
          ServiceRegistry.shared().contactsService
            .removeContact(participants[0], true, row.request.accountId)
            .catch((error: Object): void => {
              this.reportActionFailure('block', error);
            });
        }
      })
      .catch((error: Object): void => {
        this.reportActionFailure('block', error);
      });
  }

  /**
   * The one place a request action's failure becomes user-facing. The daemon gap is DISCLOSED
   * (Rule 11), never swallowed — a silent return here is what makes an action control dead.
   */
  private reportActionFailure(action: string, error: Object): void {
    if (error instanceof DaemonUnavailableError) {
      this.showDaemonNotice = true;
      return;
    }
    this.errorText = describeError(error as BusinessError);
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s failed: %{public}s', action, this.errorText);
  }

  /** Swift: the ZStack header — the centred title with the close button trailing. */
  @Builder
  header() {
    Stack({ alignContent: Alignment.Center }) {
      // Swift `Text(model.title).font(.headline)` = L10n.Smartlist.invitationReceived.
      Text($r('app.string.smartlist_invitation_received'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.background_primary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .padding({
          left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
          right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
        })

      Row() {
        // Swift `Spacer()` pushes the close button to the trailing edge.
        Blank()
        CloseButton({
          accessibilityIdentifier: 'requestsCloseButton',
          onAction: (): void => {
            this.close();
          }
        })
      }
      .width('100%')
    }
    .width('100%')
  }

  /**
   * Swift `requestsList` — `ScrollView { ForEach(model.requestsRow) { RequestsRowView(...) } }`.
   * bindingContract[invitation list]: svc_requests through ForEach, one item type
   * (RequestsRowView). Every row shares the row-root id `requestsItemroot`, which is how the
   * replay resolves `tap-card-N` by index.
   */
  /** The window's own navigation-indicator avoid area, never a hardcoded gesture-bar height. */
  private resolveBottomInset(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      const area: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.bottomInset = px2vp(area.bottomRect.height);
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'bottom avoid area unavailable: %{public}d', error.code);
    });
  }

  @Builder
  requestsList() {
    List() {
      ForEach(this.invitationList, (row: RequestRowViewModel) => {
        ListItem() {
          RequestsRowView({
            row: row,
            onAccept: (target: RequestRowViewModel): void => {
              this.accept(target);
            },
            onReject: (target: RequestRowViewModel): void => {
              this.reject(target);
            },
            onBlock: (target: RequestRowViewModel): void => {
              this.block(target);
            }
          })
        }
        .id('requestsItemroot')
        .zIndex(this.removingIds.includes(row.id) ? 1 : 0)
        // Swift `.transition(.slide)`: in from the leading edge, out to the trailing edge.
        .transition(TransitionEffect.asymmetric(TransitionEffect.move(TransitionEdge.START),
          TransitionEffect.move(TransitionEdge.END)))
        // Swift RequestsRowView answers no tap on the row itself; only its three action icons act.
      }, (row: RequestRowViewModel) => row.id)
    }
    .width('100%')
    .layoutWeight(1)
    // Swift: the ScrollView's content stops above the bottom safe area; the navy runs beneath it.
    .contentEndOffset(this.bottomInset)
    // Swift `ScrollView { ... }.background(Color.jamiRequestsBackground)`.
    .backgroundColor($r('app.color.jami_requests_background'))
  }

  build() {
    Column() {
      this.header()

      if (this.isLoading) {
        // svc_requests has not answered yet. The source had no such state (the list was already
        // in memory when the sheet opened), so it is a spinner and nothing else.
        LoadingProgress()
          .width(LOADING_SIZE)
          .height(LOADING_SIZE)
          .color($r('sys.color.background_primary'))
          .margin({ top: $r('sys.float.margin_level2') })
      } else if (this.isEmpty) {
        // conditionalVariants[empty] — the captured state: a fresh account with no invitation.
        Text($r('app.string.invitations_no_invitations'))
          .id('requestsEmptyState')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.background_primary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({
            left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
          })
          .margin({ top: $r('sys.float.margin_level2') })
      } else if (this.hasRequests) {
        // conditionalVariants[has_requests] — one row per pending RequestModel.
        this.requestsList()
      }

      // The disclosed daemon gap raised by Accept / Reject / Block.
      if (this.showDaemonNotice) {
        Text($r('app.string.daemon_not_available'))
          .width('100%')
          .id('requests_daemon_notice')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.background_primary'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.background_primary'))
          .textAlign(TextAlign.Center)
          .padding({
            left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l')
          })
      }
    }
    .width('100%')
    .height('100%')
    // Swift `.background(Color.jamiRequestsBackground.ignoresSafeArea())`.
    .backgroundColor($r('app.color.jami_requests_background'))
    .justifyContent(FlexAlign.Start)
    .id('screen_requests')
  }
}
