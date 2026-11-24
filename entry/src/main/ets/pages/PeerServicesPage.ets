/*
 * screen_peer_sharing — "Peer Services", ported from
 *   Ring/Ring/Features/Conversations/PeerSharing/PeerSharingSheet.swift
 *   Ring/Ring/Features/Conversations/PeerSharing/PeerSharingViewModel.swift
 *   Ring/Ring/Services/PeerSharingService.swift
 *
 * presentation: sheet, hostScreen: screen_conversation. ConversationContainerView presents it
 * with `.sheet` behind `showPeerServices`, so it is the content of a .bindSheet() mounted by
 * ConversationChatPage — NOT a routed page and NOT in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): structure from source only.
 *
 * S3 — the real tree of `PeerSharingSheet.body`:
 *   NavigationView { content
 *       .navigationTitle(L10n.PeerServices.title)
 *       .toolbar { Button(viewModel.refresh) { Image("arrow.clockwise") }
 *                    .disabled(viewModel.isLoading)
 *                    .accessibilityIdentifier("peerSharingRefresh") } }
 *   .fullScreenCover(item: browseSessionBinding) { PeerServiceBrowser(...) }
 *
 *   content = if isLoading        { ProgressView }
 *             else if let error   { statusView(error, isError: true) }
 *             else if services.isEmpty { statusView(L10n.PeerServices.empty) }
 *             else                { List(services) { serviceRow($0) } }
 *
 *   serviceRow = Button { viewModel.beginBrowsing(service) } label: {
 *       HStack { globe | VStack { name ; if !description.isEmpty { description } }
 *                | Spacer | if isSupported { chevron } else { Text(notSupported) } } }
 *       .accessibilityIdentifier("peerServicesItemroot")
 *       .disabled(!isSupported)
 *
 * bindingContract: [service rows] is svc_peer_sharing — `PeerSharingViewModel.services`, the
 * result of `PeerSharingService.queryPeerServices`, rendered through LazyForEach over an
 * ArrayDataSource. It starts EMPTY and is filled by the service; there is no literal row
 * anywhere here. [web view] is the loopback URL the service's own tunnel state produces.
 *
 * conditionalVariants, each a real `if` on its own bound selector:
 *   loading  — isLoading, the tunnel/query in flight
 *   browsing — isBrowsing, browseURL != nil -> the full-screen PeerServiceBrowser cover
 *   failed   — isFailed, browseFailed == true -> the viewer's error state
 *   empty    — isEmpty, the peer advertises no services
 *
 * `disabled(!isSupported)` is SOURCE state: only a web-scheme service can be opened, so a row
 * for anything else is rendered, labelled "not supported" and genuinely not tappable — the
 * guard is the source's, not an invented one.
 *
 * DAEMON GAP (Rule 11): querying a peer's advertised services and tunnelling one over the peer
 * connection is jami-daemon work. The real service is called and hands the gap back as a
 * non-success status, which this screen renders as its error text — never an invented service
 * row, and never a silent return.
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { DisposeBag } from '../common/Observable';
import { PeerServiceBrowser } from '../components/PeerServiceBrowser';
import { ServiceRegistry } from '../common/ServiceRegistry';
import {
  PeerServiceInfo,
  PeerServicesResult,
  PeerServicesStatus,
  PeerSharingService,
  PeerTunnelInfo,
  PeerTunnelState
} from '../common/PeerSharingService';

/** Swift `HStack(spacing: 12)` in the service row. */
const ROW_GAP: number = 12;
/** Swift `VStack(alignment: .leading, spacing: 2)` — the name over its description. */
const ROW_TEXT_GAP: number = 2;
/** Swift `.padding(.horizontal, 24)` on the status text. */
const STATUS_INSET: number = 24;

/* ── S5 metrics (NO CAPTURE — the source's own + the iOS system defaults it inherits) ── */
/**
 * `.navigationBarTitleDisplayMode(.inline)` — the inline bar iOS draws for free: 44 pt tall,
 * the title centred on the same optical row as the trailing item (mapping-tables.md §7).
 */
const NAV_BAR_HEIGHT: number = 44;
/** The trailing toolbar item's own 44 pt hit target; also what re-centres the inline title. */
const NAV_ITEM: number = 44;
/** `Image(systemName: "arrow.clockwise")` in a toolbar — the iOS bar-button glyph size. */
const NAV_GLYPH_SIZE: number = 20;
/** The iOS nav-bar hairline. */
const HAIRLINE: number = 0.5;
/** `ProgressView()` — the iOS default (`.medium`) activity indicator. */
const LOADING_SIZE: number = 32;
/** Swift `Image(systemName: "globe").font(.title2)` — the leading row glyph's size. */
const ROW_GLYPH_SIZE: number = 22;
/**
 * Swift `Color.jamiFailure` = `UIColor(hex: 0xf00000)` (UIColor+Ring.swift:99) — hard-coded in
 * the source, so it is carried over verbatim rather than mapped to a token.
 */
const JAMI_FAILURE: string = '#F00000';

/** Swift `private func errorText(for status: PeerServicesStatus)` — one status, one string. */
function errorResourceFor(status: PeerServicesStatus): string {
  if (status === PeerServicesStatus.NO_DEVICES) {
    return 'peer_services_error_offline';
  }
  if (status === PeerServicesStatus.UNREACHABLE) {
    return 'peer_services_error_unreachable';
  }
  if (status === PeerServicesStatus.TIMEOUT) {
    return 'peer_services_error_timeout';
  }
  return 'peer_services_error_unknown';
}

@Component
export struct PeerServicesSheet {
  /** Owned by screen_conversation; the host's @State drives the sheet. */
  @Link isPresented: boolean;
  /** Swift `init(accountId:peerId:peerSharingService:)` — supplied by the presenting host. */
  @Prop accountId: string = '';
  @Prop peerId: string = '';

  /** bindingContract[service rows]: svc_peer_sharing <- `@Published var services`. */
  @State serviceRows: PeerServiceInfo[] = [];
  /** bindingContract[web view]: svc_peer_sharing <- `@Published var browseURL` (loopback). */
  @State webView: string = '';
  /** conditionalVariants[loading]: Swift `@Published var isLoading`. */
  @State isLoading: boolean = false;
  /** conditionalVariants[browsing]: Swift `presentedBrowseSession != nil`. */
  @State isBrowsing: boolean = false;
  /** conditionalVariants[failed]: Swift `@Published var browseFailed`. */
  @State isFailed: boolean = false;
  /** conditionalVariants[empty]: Swift `viewModel.services.isEmpty`. */
  @State isEmpty: boolean = false;
  /** Swift `@Published var errorMessage` — `errorText(for: result.status)`. */
  @State errorText: string = '';

  /** LazyForEach's source (CLAUDE.md rule 7), reloaded from the query result. */
  private rows: ArrayDataSource<PeerServiceInfo> = new ArrayDataSource<PeerServiceInfo>([]);
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Swift `presentedBrowseSession?.service.id` — the session Done has to close. */
  private browsingServiceId: string = '';
  /** Swift `private var sawPendingForBrowse`. */
  private sawPendingForBrowse: boolean = false;

  /** Swift `init(...)` — observeTunnelState() then refresh(). */
  aboutToAppear(): void {
    this.observeTunnelState();
    this.refresh();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription and the peer's tunnels go whatever happens on the way out.
    this.bag.dispose();
    ServiceRegistry.shared().peerSharingService
      .closeAllTunnelsForPeer(this.accountId, this.peerId);
  }

  /**
   * Swift `refresh()` — `peerSharingService.queryPeerServices(accountId:peerId:)`, whose
   * result either fills `services` or sets the status's error text.
   */
  private refresh(): void {
    this.isLoading = true;
    this.errorText = '';
    this.applyServices([]);
    ServiceRegistry.shared().peerSharingService
      .queryPeerServices(this.accountId, this.peerId)
      .then((result: PeerServicesResult): void => {
        this.applyResult(result);
      })
      .catch((): void => {
        this.isLoading = false;
        this.applyServices([]);
        this.errorText = this.resolve('peer_services_error_unknown');
      });
  }

  /** Swift the query's `onNext` — success fills the rows, anything else is the error text. */
  private applyResult(result: PeerServicesResult): void {
    this.isLoading = false;
    if (result.status === PeerServicesStatus.SUCCESS) {
      this.applyServices(result.services);
      this.errorText = '';
      return;
    }
    this.applyServices([]);
    this.errorText = this.resolve(errorResourceFor(result.status));
  }

  /** A localized string resolved to plain text, for the one inline failure slot. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  private applyServices(services: PeerServiceInfo[]): void {
    this.serviceRows = services;
    this.rows.reload(services);
    this.isEmpty = services.length === 0;
  }

  /** Swift `observeTunnelState()` — the relay drives browseURL / browseFailed. */
  private observeTunnelState(): void {
    const service: PeerSharingService = ServiceRegistry.shared().peerSharingService;
    this.bag.add(service.observeTunnelState(this.accountId, this.peerId)
      .subscribe((state: PeerTunnelState): void => {
        this.updateBrowseState(state);
      }));
  }

  /**
   * Swift `dismissOrphanedBrowseSession()` + `updateBrowseState()` — hands the viewer the
   * loopback URL once its tunnel is established, or flags the failure when the open ended
   * without the tunnel ever becoming active.
   */
  private updateBrowseState(state: PeerTunnelState): void {
    if (!this.isBrowsing || this.browsingServiceId.length === 0) {
      return;
    }
    const tunnel: PeerTunnelInfo | undefined = state.activeTunnels.get(this.browsingServiceId);

    // Swift `dismissOrphanedBrowseSession()` — an ESTABLISHED session whose tunnel vanished.
    if (this.webView.length > 0 && tunnel === undefined) {
      this.clearBrowseState();
      return;
    }
    if (this.webView.length > 0 || this.isFailed) {
      return;
    }
    if (tunnel !== undefined) {
      const url: string | null = tunnel.browsableUrl;
      // A tunnel that is active but whose loopback URL cannot be built will not recover.
      if (url !== null) {
        this.webView = url;
      } else {
        this.isFailed = true;
      }
      return;
    }
    if (state.pendingServices.has(this.browsingServiceId)) {
      this.sawPendingForBrowse = true;
      return;
    }
    // Neither pending nor active: if it was pending before, the open failed.
    if (this.sawPendingForBrowse) {
      this.isFailed = true;
    }
  }

  /** Swift `beginBrowsing(_:)` — present the viewer loading, then open the tunnel. */
  private beginBrowsing(service: PeerServiceInfo): void {
    if (!service.isWebService) {
      return;
    }
    this.browsingServiceId = service.id;
    this.webView = '';
    this.isFailed = false;
    this.sawPendingForBrowse = false;
    this.isBrowsing = true;
    ServiceRegistry.shared().peerSharingService
      .openTunnel(this.accountId, this.peerId, service);
  }

  /** Swift `dismissBrowsingSession()` — lower the viewer AND close its tunnel. */
  private dismissBrowsingSession(): void {
    const serviceId: string = this.browsingServiceId;
    this.clearBrowseState();
    if (serviceId.length > 0) {
      ServiceRegistry.shared().peerSharingService
        .closeTunnel(this.accountId, this.peerId, serviceId);
    }
  }

  /** Swift `clearBrowseState()`. */
  private clearBrowseState(): void {
    this.isBrowsing = false;
    this.webView = '';
    this.isFailed = false;
    this.sawPendingForBrowse = false;
    this.browsingServiceId = '';
  }

  /** Swift `serviceRow(_:)` — one row per advertised service. */
  @Builder
  private serviceRow(service: PeerServiceInfo) {
    Row({ space: ROW_GAP }) {
      // Swift's leading `Image(systemName: "globe")` is `.accessibilityHidden(true)`
      // decoration. icon_resolver resolves `globe` to a CLOSED candidate shortlist with no
      // plain globe in it, so the glyph is left to S5 rather than shipped wrong here.
      Column({ space: ROW_TEXT_GAP }) {
        Text(service.name)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          // Swift `.foregroundColor(isSupported ? .label : .secondaryLabel)`.
          .fontColor(service.isWebService
            ? $r('app.color.label')
            : $r('app.color.secondary_label'))

        // Swift `if !service.description.isEmpty { Text(service.description) }`.
        if (service.description.length > 0) {
          Text(service.description)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // Swift `.font(.footnote).foregroundColor(.secondaryLabel)`.
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
        }
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      // Swift `if isSupported { chevron } else { Text(L10n.PeerServices.notSupported) }`.
      if (service.isWebService) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(ROW_GLYPH_SIZE)
          // Swift `.foregroundColor(Color(UIColor.tertiaryLabel))`.
          .fontColor([$r('sys.color.font_tertiary')])
      } else {
        Text($r('app.string.peer_services_not_supported'))
          .maxLines(1)
          // Swift `.font(.footnote).foregroundColor(.secondaryLabel)`.
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // `PlainListStyle` — edge-to-edge rows on a plain white page, standard 16/11 pt insets.
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      top: LengthMetrics.resource($r('sys.float.padding_level4')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
    })
    // The whole row is the control (Swift's `Button { … } label: { HStack … }`), so the slug
    // and the handler sit together on it, never on an inner child.
    .id('peerServicesItemroot')
    .enabled(service.isWebService)
    .onClick(() => {
      this.beginBrowsing(service);
    })
  }

  build() {
    /*
     * S6: Swift presents the viewer with `.fullScreenCover`, which lays OVER the sheet's own
     * body rather than beside it. A Column would have laid the (100%-high) viewer out below
     * the list and clipped it, so the sheet body and the cover are two layers of one Stack —
     * a layout container only; no control, binding or branch changes.
     */
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // Swift `.navigationTitle(L10n.PeerServices.title)` + the trailing refresh toolbar item.
        Row() {
          // `.inline` centres the title; the leading margin matches the trailing item's width so
          // the remaining band is symmetric (mapping-tables.md §7).
          Text($r('app.string.peer_services_title'))
            .layoutWeight(1)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.label'))
            .margin({ start: LengthMetrics.vp(NAV_ITEM) })

          Blank()

          Button() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(NAV_GLYPH_SIZE)
              .fontColor([$r('app.color.jami')])
          }
          .id('peerSharingRefresh')
          .accessibilityText($r('app.string.peer_services_refresh'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .width(NAV_ITEM)
          .height(NAV_ITEM)
          // Swift `.disabled(viewModel.isLoading)` — the source's own condition.
          .enabled(!this.isLoading)
          .onClick(() => {
            this.refresh();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: NAV_BAR_HEIGHT })
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        })
        .backgroundColor($r('sys.color.background_primary'))
        .border({ width: { bottom: HAIRLINE }, color: { bottom: $r('sys.color.comp_divider') } })

        // Swift `content` — loading / error / empty / list, four exclusive bodies.
        if (this.isLoading) {
          LoadingProgress()
            .id('peerServicesLoading')
            .width(LOADING_SIZE)
            .height(LOADING_SIZE)
            .color($r('sys.color.font_secondary'))
            .margin({ top: $r('sys.float.padding_level16') })
        } else if (this.errorText.length > 0) {
          // Swift `statusView(text:isError: true)` — centred in the body, in jamiFailure.
          Text(this.errorText)
            .id('peerServicesError')
            .textAlign(TextAlign.Center)
            .padding({ start: LengthMetrics.vp(STATUS_INSET), end: LengthMetrics.vp(STATUS_INSET) })
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor(JAMI_FAILURE)
        } else if (this.isEmpty) {
          // Swift `statusView(text:)` — the same centred body, in secondaryLabel.
          Text($r('app.string.peer_services_empty'))
            .id('peerServicesEmpty')
            .textAlign(TextAlign.Center)
            .padding({ start: LengthMetrics.vp(STATUS_INSET), end: LengthMetrics.vp(STATUS_INSET) })
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
        } else {
          List() {
            LazyForEach(this.rows, (service: PeerServiceInfo) => {
              ListItem() {
                this.serviceRow(service)
              }
            }, (service: PeerServiceInfo) => service.id)
          }
          .width('100%')
          .layoutWeight(1)
          // `PlainListStyle` — a hairline between rows, inset to the text column.
          .divider({
            strokeWidth: HAIRLINE,
            color: $r('sys.color.comp_divider'),
            startMargin: ROW_GLYPH_SIZE + ROW_GAP + 16
          })
        }

      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      // `PlainListStyle` — a plain white page, not the grouped gray one (mapping-tables.md §7).
      .backgroundColor($r('sys.color.background_primary'))

      // Swift `.fullScreenCover(item: browseSessionBinding) { PeerServiceBrowser(...) }` —
      // the second layer: it covers the body completely while a session is presented.
      if (this.isBrowsing) {
        PeerServiceBrowser({
          browseUrl: this.webView,
          browseFailed: this.isFailed,
          onDone: (): void => {
            this.dismissBrowsingSession();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_peer_sharing')
  }
}
