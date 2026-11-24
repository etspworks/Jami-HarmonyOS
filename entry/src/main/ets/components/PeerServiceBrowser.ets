/*
 * comp_peer_service_browser — ported from
 *   Ring/Ring/Features/Conversations/PeerSharing/PeerSharingSheet.swift
 *   `struct PeerServiceBrowser` (line 170) + `private struct WebViewRepresentable`:
 *
 *     NavigationView {
 *         content
 *             .navigationTitle(title)                  // the real loopback host:port, never
 *             .navigationBarTitleDisplayMode(.inline)  // the peer-supplied service name
 *             .toolbar { ToolbarItem(.navigationBarLeading) {
 *                 Button(L10n.PeerServices.done, action: onDone)
 *                     .accessibilityIdentifier("peer_service_browser_done") } }
 *     }
 *
 *     content = if viewModel.browseFailed { Text(errorUnreachable) }
 *               else if let url = viewModel.browseURL { WebViewRepresentable(url: url) }
 *               else { ProgressView() }
 *
 * The viewer must stay IN-APP: the tunnel is a loopback port that only answers while Jami is
 * foreground, so an external browser would background the app and kill the page. ArkWeb's
 * `Web` component is that in-app viewer.
 *
 * ORIGIN PINNING is part of the port, not a nicety — the viewer has no address bar, so the
 * source's WKNavigationDelegate cancels any navigation off the exact loopback origin. Here
 * that is `onLoadIntercept`, which returns true to CANCEL the load.
 */
import { webview } from '@kit.ArkWeb';
import { LengthMetrics } from '@kit.ArkUI';

/** Swift `.padding(.horizontal, 24)` on the error text. */
const ERROR_INSET: number = 24;

/* ── S5 metrics (NO CAPTURE — the source's own + the iOS system defaults it inherits) ── */
/** `.navigationBarTitleDisplayMode(.inline)` — the 44 pt inline bar iOS draws for free. */
const NAV_BAR_HEIGHT: number = 44;
/** The leading `Done` bar button's own width — what re-centres the inline title beside it. */
const NAV_ACTION_WIDTH: number = 60;
/** The iOS nav-bar hairline. */
const HAIRLINE: number = 0.5;
/** `ProgressView()` — the iOS default (`.medium`) activity indicator. */
const LOADING_SIZE: number = 32;

@Component
export struct PeerServiceBrowser {
  /** Swift `viewModel.browseURL` — the loopback URL, empty while the tunnel is still opening. */
  @Prop browseUrl: string = '';
  /** Swift `viewModel.browseFailed` — the tunnel could not be opened. */
  @Prop browseFailed: boolean = false;
  /** Swift `let onDone: () -> Void` — `viewModel.dismissBrowsingSession`. */
  onDone?: () => void;

  private controller: webview.WebviewController = new webview.WebviewController();

  /**
   * Swift `private var title` — the REAL loopback origin once loaded, never the peer-supplied
   * service name. Empty while loading or on error.
   */
  private originTitle(): string {
    if (this.browseFailed || this.browseUrl.length === 0) {
      return '';
    }
    const schemeEnd: number = this.browseUrl.indexOf('://');
    const rest: string = schemeEnd < 0 ? this.browseUrl : this.browseUrl.substring(schemeEnd + 3);
    const pathStart: number = rest.indexOf('/');
    return pathStart < 0 ? rest : rest.substring(0, pathStart);
  }

  /**
   * Swift `Coordinator.webView(_:decidePolicyFor:decisionHandler:)` — every navigation is
   * pinned to the tunnel's own origin (scheme + host + port). `true` cancels the load.
   */
  private isOffOrigin(url: string): boolean {
    if (this.browseUrl.length === 0) {
      return true;
    }
    const schemeEnd: number = this.browseUrl.indexOf('://');
    const origin: string = schemeEnd < 0
      ? this.browseUrl
      : this.browseUrl.substring(0, schemeEnd + 3) + this.originTitle();
    return !url.startsWith(origin);
  }

  private done(): void {
    const handler: (() => void) | undefined = this.onDone;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Column() {
      // Swift the leading toolbar item — Done closes the viewer AND its tunnel.
      Row() {
        Button($r('app.string.peer_services_done'))
          .id('peer_service_browser_done')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .padding(0)
          .constraintSize({ minWidth: NAV_ACTION_WIDTH, minHeight: NAV_BAR_HEIGHT })
          .onClick(() => {
            this.done();
          })

        Blank()

        // `.inline` centres the title; the trailing margin matches the leading Done so the
        // remaining band is symmetric (mapping-tables.md §7).
        Text(this.originTitle())
          .layoutWeight(1)
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          .margin({ end: LengthMetrics.vp(NAV_ACTION_WIDTH) })
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

      // Swift `content` — the three exclusive bodies of the viewer.
      if (this.browseFailed) {
        // Swift `.foregroundColor(Color(UIColor.secondaryLabel)).multilineTextAlignment(.center)`.
        Text($r('app.string.peer_services_error_unreachable'))
          .id('peerServiceBrowserError')
          .textAlign(TextAlign.Center)
          .padding({ start: LengthMetrics.vp(ERROR_INSET), end: LengthMetrics.vp(ERROR_INSET) })
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
      } else if (this.browseUrl.length > 0) {
        Web({ src: this.browseUrl, controller: this.controller })
          .id('peerServiceBrowserWeb')
          .width('100%')
          .layoutWeight(1)
          .domStorageAccess(false)
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            return this.isOffOrigin(event.data.getRequestUrl());
          })
      } else {
        LoadingProgress()
          .id('peerServiceBrowserLoading')
          .width(LOADING_SIZE)
          .height(LOADING_SIZE)
          .color($r('sys.color.font_secondary'))
          .margin({ top: $r('sys.float.padding_level16') })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_primary'))
  }
}
