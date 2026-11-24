/*
 * screen_about_jami — "About Jami (modal)", ported from
 *   Ring/Ring/About/AboutSwiftUIView.swift
 *   Ring/Ring/About/AboutSwiftUIVM.swift
 *   Ring/Ring/Extensions/View+Helpers.swift            (CloseButton)
 *   Ring/Ring/Features/Walkthrough/Models/WelcomeVM.swift
 *
 * presentation: modal, hostScreen: screen_welcome. WalkthroughCoordinator.showAboutJami()
 * wraps AboutSwiftUIView in a dismissable VC and presents it .formModal, so it is a
 * @CustomDialog mounted by WelcomeOnboardingPage — NOT a routed page and NOT in
 * main_pages.json. (screen_about / AboutJamiNavPage is the PUSHED variant of the same body;
 * both render `AboutSwiftUIView.body`, which is why the trees match.)
 *
 * S3 — the real component tree of `AboutSwiftUIView.body`:
 *   VStack(spacing: 20) {
 *     ZStack { HStack { Spacer; CloseButton(closeAboutView) }; Image("jamiGnupackage") }
 *     aboutContentScrollView   // version block, declaration / no-warranty / copyright,
 *                              // then the grouped contributor card
 *     HStack { Spacer; Button(about_contribute); Spacer(30); Button(about_send_feedback) }
 *   }
 *
 * bindingContract: `version` comes from svc_daemon's version surface (JamiConstants.fullVersion,
 * Swift `Constants.fullVersion`) and `declaration` from JamiConstants / the migrated L10n
 * strings — neither may be a literal transcribed from the capture. No styling in this pass.
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CloseButton } from '../components/CloseButton';
// Swift `Constants.fullVersion` + the `contributors*` literals, ported verbatim.
import { JamiConstants } from '../common/JamiConstants';
// Swift `UIApplication.shared.open(url)` -> UIAbilityContext.openLink, already ported.
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AboutJamiModal';

/* ── S5 metrics, the source's own (AboutSwiftUIView.swift:19-140) ────────────────── */
/** Swift `let padding: CGFloat = 20` — the body VStack spacing and the content spacing. */
const ABOUT_PADDING: number = 20;
/** Swift `Image("jamiGnupackage").resizable().aspectRatio(.fit).frame(height: 30)`. */
const LOGO_HEIGHT: number = 30;
/** Swift `Spacer().frame(width: 30)` between the two link buttons. */
const LINK_BUTTON_GAP: number = 30;
/** Swift the credits groups: `Spacer().frame(height: 10)` between a label and its names. */
const CREDITS_GAP: number = 10;
/** Swift `.cornerRadius(8)` on the credits card — a source-hardcoded value, copied verbatim. */
const CREDITS_RADIUS: number = 8;
/** Swift `LoadingProgress` beside the version line. */
const VERSION_SPINNER_SIZE: number = 16;
/** `.formModal` leaves the top of the screen showing (capture: 165 of 2556 px). */
const SHEET_HEIGHT: string = '92%';
/** iOS sheet swipe-down: a downward drag past this many vp dismisses, shorter snaps back. */
const DISMISS_DRAG_DISTANCE: number = 100;

/** Swift `AboutSwiftUIVM.openContributeLink()`. */
const CONTRIBUTE_URL: string = 'https://jami.net/contribute/';
/** Swift `AboutSwiftUIVM.sendFeedback()` — mailtoURL(email:subject:body:). */
const FEEDBACK_EMAIL: string = 'jami@gnu.org';
const FEEDBACK_SUBJECT: string = 'Feedback for the Jami';
const FEEDBACK_BODY: string = "Hello, I'd like to share some feedback…";
/** Swift `AboutSwiftUIVM` markdown links spliced into declarationText / noWarrantyText / mainUrlText. */
const JAMI_NET_URL: string = 'https://jami.net';
const GPL_URL: string = 'https://www.gnu.org/licenses/gpl-3.0.html';
const SFL_URL: string = 'https://savoirfairelinux.com';
/** Swift `AboutSwiftUIVM.mainUrlText` — hardcoded in the source, copied verbatim. */
const COPYRIGHT_PREFIX: string = 'Copyright © 2015–2026 ';
/** Swift `Text("Version: \(model.fullVersion)")` — hardcoded in the source, copied verbatim. */
const VERSION_LABEL: string = 'Version: ';
/**
 * Swift's `Constants.fullVersion ?? ""` left the line reading "Version: " when the bundle info
 * could not be read. An empty gap says nothing, so the refusal is stated instead. Chrome, not a
 * bound value — `string.json` is an orchestrator-serial edit, so it carries no resource yet.
 */
const VERSION_UNAVAILABLE: string = 'unavailable';
/** The toast shown when no installed app handles the link; the URL goes to hilog, not the page. */
const LINK_FAILED_TOAST: string = 'No app on this device can open that link.';

@CustomDialog
export struct AboutJamiModalOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /**
   * Owned by screen_welcome (Swift: WalkthroughCoordinator owns the presented VC), so the
   * overlay can dismiss itself while the host stays the single writer of "is it up".
   */
  @Link isPresented: boolean;

  /** Swift `AboutSwiftUIVM.fullVersion` <- svc_daemon; rendered as "Version: <x>". */
  @State version: string = '';
  /**
   * The four credit groups of `aboutContentScrollView`, in the source's own order:
   * developers, media, community management, special thanks. One array rather than four
   * fields because the plan binds ONE site to JamiConstants — the names are never typed here.
   */
  @State contributorLists: string[] = [];
  /** True while the version lookup is in flight. */
  @State isLoading: boolean = true;
  /** Live downward drag of the sheet (vp) — Swift gets this from the .formModal sheet itself. */
  @State dragOffset: number = 0;
  /** The body Scroll, read to tell whether a drag on the body starts at its top. */
  private scroller: Scroller = new Scroller();
  /** True when the current body drag began with the Scroll at its top, so it moves the sheet. */
  private bodyDragMovesSheet: boolean = false;

  /**
   * Swift `AboutSwiftUIVM.init` — every stored property is read at construction time.
   * `fullVersion` reads the bundle info asynchronously, so it is the one value that arrives
   * after the first frame and the only reason `isLoading` exists.
   */
  aboutToAppear(): void {
    this.loadVersion();
    this.contributorLists = [
      JamiConstants.CONTRIBUTORS_DEVELOPERS,
      JamiConstants.CONTRIBUTORS_MEDIA,
      JamiConstants.CONTRIBUTORS_COMMUNITY_MANAGEMENT,
      JamiConstants.SPECIAL_THANKS
    ];
  }

  /** Swift `let fullVersion: String = Constants.fullVersion ?? ""`. */
  private loadVersion(): void {
    JamiConstants.fullVersion()
      .then((value: string): void => {
        this.version = value;
        this.isLoading = false;
      })
      .catch((error: BusinessError): void => {
        // Swift's `?? ""` left the line blank; here the empty version renders the explicit
        // "unavailable" fallback below, and the reason goes to hilog only.
        this.version = '';
        this.isLoading = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'fullVersion failed: %{public}s', describeError(error));
      });
  }

  private hostContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** Swift `dismissHandler.dismissView()` behind CloseButton(closeAboutView). */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** Finger lifted: past the threshold dismisses, shorter snaps the sheet back. */
  private endSheetDrag(): void {
    if (this.dragOffset > DISMISS_DRAG_DISTANCE) {
      this.dismiss();
    } else {
      animateTo({ duration: 200 }, () => {
        this.dragOffset = 0;
      });
    }
  }

  /** Swift `mailtoURL(email:subject:body:)` — URLComponents with the two query items. */
  private mailtoUrl(): string {
    const subject: string = encodeURIComponent(FEEDBACK_SUBJECT);
    const body: string = encodeURIComponent(FEEDBACK_BODY);
    return `mailto:${FEEDBACK_EMAIL}?subject=${subject}&body=${body}`;
  }

  /** Swift `AboutSwiftUIVM.openContributeLink()` — UIApplication.shared.open(url). */
  private openContributeLink(): void {
    this.open(CONTRIBUTE_URL);
  }

  /** Swift `AboutSwiftUIVM.sendFeedback()` — opens the mailto: URL it composes. */
  private sendFeedback(): void {
    this.open(this.mailtoUrl());
  }

  /**
   * Swift's `UIApplication.shared.open(url)` silently does nothing when no app handles the
   * scheme; here the refusal is surfaced as a toast, because a button that appears to do nothing
   * is the defect this sheet would otherwise ship (no mail client => no mailto handler). The URL
   * itself is log material — never page content.
   */
  private open(url: string): void {
    ShareActions.openLink(this.hostContext(), url)
      .then((opened: boolean): void => {
        if (!opened) {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'openLink refused: %{public}s', url);
          this.notifyLinkFailed();
        }
      })
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'openLink failed for %{public}s: %{public}s',
          url, describeError(error));
        this.notifyLinkFailed();
      });
  }

  /** The project's own failure idiom (ImagePicker.notifyCameraUnavailable): one toast. */
  private notifyLinkFailed(): void {
    promptAction.showToast({ message: LINK_FAILED_TOAST, duration: 2000 });
  }

  /**
   * Swift `aboutContentScrollView`'s grouped credits card: a label / list pair per contributor
   * group, all of them off JamiConstants, none of them a literal in this file.
   */
  @Builder
  private creditsGroup(label: ResourceStr, index: number) {
    // Swift: `Text(label).bold().font(.caption)` over `Text(names).font(.caption)`, 10pt apart.
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.label'))
      .margin({ top: CREDITS_GAP })
    Text(index < this.contributorLists.length ? this.contributorLists[index] : '')
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.label'))
      .margin({ top: CREDITS_GAP })
  }

  build() {
    // Swift `VStack(spacing: padding) { … }.padding(.vertical)`.
    Column({ space: ABOUT_PADDING }) {
      // Swift ZStack { HStack { Spacer; CloseButton }; Image("jamiGnupackage") } — the close
      // button sits trailing, the logo is centred over the same band.
      Stack({ alignContent: Alignment.Center }) {
        Row() {
          Blank()
          CloseButton({
            accessibilityIdentifier: 'closeAboutView',
            onAction: () => {
              this.dismiss();
            }
          })
        }
        .width('100%')
        .padding({
          left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
          right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
        })

        Image($r('app.media.jami_gnupackage'))
          // Swift `.resizable().aspectRatio(contentMode: .fit).frame(height: 30)`.
          .height(LOGO_HEIGHT)
          .objectFit(ImageFit.Contain)
          // Decorative, and the LAST child of the Stack — so it is the topmost hit target over
          // the close button's band. Transparent to touch, or it can swallow `closeAboutView`.
          .hitTestBehavior(HitTestMode.None)
          .accessibilityText($r('app.string.accessibility_about_jami_title'))
      }
      .width('100%')

      // Swift `aboutContentScrollView` — `.padding(.horizontal)` around a leading VStack
      // spaced by `padding` (20).
      Scroll(this.scroller) {
        Column({ space: ABOUT_PADDING }) {
          Column() {
            // Swift `Text(Constants.versionName).bold()` — default body face, centred.
            Text(JamiConstants.VERSION_NAME)
              .fontSize($r('sys.float.Body_L'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.label'))
            // Swift `Text("Version: \(model.fullVersion)")` <- svc_daemon, `.caption` in
            // `secondaryLabel` (capture: #8A8A8E on white).
            Text(`${VERSION_LABEL}${this.version.length > 0 ? this.version : VERSION_UNAVAILABLE}`)
              .id('about_version')
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.secondary_label'))
            // The version is the one value that arrives asynchronously (bundleManager).
            if (this.isLoading) {
              LoadingProgress()
                .width(VERSION_SPINNER_SIZE)
                .height(VERSION_SPINNER_SIZE)
                .color($r('app.color.jami'))
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          // Swift `Text(.init(declarationText / noWarrantyText / mainUrlText))` — one `.body`
          // paragraph each, the markdown links drawn inline in the accent tint and tappable.
          Text() {
            Span($r('app.string.about_jami_declaration1'))
            Span(' jami.net ')
              .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
              .onClick(() => {
                this.open(JAMI_NET_URL);
              })
            Span($r('app.string.about_jami_declaration2'))
          }
          .id('about_declaration')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          Text() {
            Span($r('app.string.about_jami_no_warranty1'))
            Span(' GNU General Public License')
              .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
              .onClick(() => {
                this.open(GPL_URL);
              })
            Span(', ')
            Span($r('app.string.about_jami_no_warranty2'))
          }
          .id('about_no_warranty')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          Text() {
            Span(COPYRIGHT_PREFIX)
            Span('Savoir-faire Linux Inc.')
              .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
              .onClick(() => {
                this.open(SFL_URL);
              })
          }
          .id('about_copyright')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))

          // Swift: the credits VStack inside `.padding().background(systemGroupedBackground)
          // .cornerRadius(8)` — the capture's #F2F2F7 card on the white sheet.
          Column() {
            Text($r('app.string.about_jami_header'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.label'))
            this.creditsGroup($r('app.string.about_jami_developers'), 0)
            this.creditsGroup($r('app.string.about_jami_media'), 1)
            this.creditsGroup($r('app.string.about_jami_community_management'), 2)
            this.creditsGroup($r('app.string.about_jami_special_thanks'), 3)
            // Swift `Spacer().frame(height: 20)` before the closing note.
            Text($r('app.string.about_jami_info'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.label'))
              .margin({ top: ABOUT_PADDING })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          .backgroundColor($r('sys.color.comp_background_gray'))
          .borderRadius(CREDITS_RADIUS)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
          right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
        })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      // iOS: with the body scrolled to its top, a downward drag on it moves the sheet instead.
      // Runs beside the Scroll's own pan; Scroll's default EdgeEffect.None keeps the body still.
      .parallelGesture(PanGesture({ direction: PanDirection.Down })
        .onActionStart(() => {
          this.bodyDragMovesSheet = this.scroller.currentOffset().yOffset <= 0;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.bodyDragMovesSheet) {
            this.dragOffset = Math.max(0, event.offsetY);
          }
        })
        .onActionEnd(() => {
          if (this.bodyDragMovesSheet) {
            this.bodyDragMovesSheet = false;
            this.endSheetDrag();
          }
        })
        .onActionCancel(() => {
          this.bodyDragMovesSheet = false;
          this.dragOffset = 0;
        }))

      // Swift: the trailing HStack of the two link buttons — plain tinted text buttons
      // 30pt apart, inset horizontally. AboutSwiftUIView sets NO `.accentColor`, so these
      // take the iOS default tint (#007AFF in the capture), not Color.jami.
      Row({ space: LINK_BUTTON_GAP }) {
        Blank()
        Button($r('app.string.about_jami_contribute'))
          .id('about_contribute')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .padding(0)
          .onClick(() => {
            this.openContributeLink();
          })
        Button($r('app.string.about_jami_feedback'))
          .id('about_send_feedback')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
          .padding(0)
          .onClick(() => {
            this.sendFeedback();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })
    }
    .width('100%')
    // `.formModal` leaves the top of the screen showing, so the sheet is a rounded-top white
    // panel over the walkthrough wallpaper, not a full-bleed page.
    .height(SHEET_HEIGHT)
    .backgroundColor($r('sys.color.background_primary'))
    .borderRadius({
      topLeft: $r('sys.float.ohos_id_corner_radius_default_m'),
      topRight: $r('sys.float.ohos_id_corner_radius_default_m')
    })
    .clip(true)
    // Swift `.padding(.vertical)` on the body VStack.
    .padding({ top: ABOUT_PADDING, bottom: ABOUT_PADDING })
    // iOS sheet swipe-down-to-dismiss from the header band and footer; the body Scroll has its
    // own parallel pan above that only moves the sheet while scrolled to its top.
    .translate({ y: this.dragOffset })
    .gesture(PanGesture({ direction: PanDirection.Down })
      .onActionUpdate((event: GestureEvent) => {
        this.dragOffset = Math.max(0, event.offsetY);
      })
      .onActionEnd(() => {
        this.endSheetDrag();
      })
      .onActionCancel(() => {
        this.dragOffset = 0;
      }))
    .id('screen_about_jami')
  }
}
