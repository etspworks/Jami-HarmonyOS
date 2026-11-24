/*
 * screen_about — "About Jami (nav page)", ported from
 *   Ring/Ring/About/AboutSwiftUIView.swift + AboutSwiftUIVM.swift
 *   Ring/Ring/About/AboutViewController.swift (+ .storyboard)
 *
 * AboutViewController is a storyboard UIViewController that sets `navigationItem.title =
 * L10n.Smartlist.aboutJami` and hosts AboutSwiftUIView in a UIHostingController, so the page's
 * body IS AboutSwiftUIView and the title bar is the pushed page's own chrome. Pushed (.show)
 * from the smart-list overflow menu, so Back returns to the smart list and the source's own
 * Close button does the same thing. No nav edges lead out of this screen.
 *
 * S3 — the component tree of `AboutSwiftUIView.body`:
 *   VStack {
 *     ZStack { HStack { Spacer; CloseButton(closeAboutView) }; Image("jamiGnupackage") }
 *     aboutContentScrollView   // version block, declaration / no-warranty / copyright,
 *                              // then the grouped contributor card
 *     HStack { Spacer; Button(about_contribute); Spacer(30); Button(about_send_feedback) }
 *   }
 *
 * S4 binds `version` to svc_daemon (JamiConstants.fullVersion) and `contributorLists` to
 * JamiConstants.CONTRIBUTORS_* — bindingContract says neither may ever be a literal here.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { CloseButton } from '../components/CloseButton';
// Swift `Constants.fullVersion` and the `contributors*` literals both live in Constants.swift,
// ported verbatim into JamiConstants — bindingContract forbids re-typing either into this page.
import { JamiConstants } from '../common/JamiConstants';
// Swift `UIApplication.shared.open(url)` -> UIAbilityContext.openLink, already ported.
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AboutJamiNavPage';

/* ── S5 metrics, the source's own (AboutSwiftUIView.swift:22-140) ────────────────── */
/** Swift `let padding: CGFloat = 20` — the body's stack spacing and the content spacing. */
const ABOUT_PADDING: number = 20;
/** Swift `Image("jamiGnupackage").frame(height: 30)`. */
const LOGO_HEIGHT: number = 30;
/** Swift `Spacer().frame(width: 30)` between the two link buttons. */
const LINK_BUTTON_GAP: number = 30;
/** Swift the credits groups: `Spacer().frame(height: 10)` between a label and its names. */
const CREDITS_GAP: number = 10;
/** Swift `LoadingProgress` beside the version line. */
const VERSION_SPINNER_SIZE: number = 16;

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
/** Swift `mainUrlText` — hardcoded in the source, copied verbatim. */
const COPYRIGHT_PREFIX: string = 'Copyright © 2015–2026 ';
/** Swift `Text("Version: \(model.fullVersion)")` — hardcoded in the source. */
const VERSION_LABEL: string = 'Version: ';

@Entry
@Component
struct AboutJamiNavPage {
  /** Swift `AboutSwiftUIVM.fullVersion` <- svc_daemon; rendered as "Version: <x>". */
  @State version: string = '';
  /**
   * The four credit groups of `aboutContentScrollView`, in the source's own order:
   * developers, media, community management, special thanks. One array rather than four
   * fields because the plan binds ONE site (`contributor lists`) to JamiConstants — the names
   * themselves are never typed into this page.
   */
  @State contributorLists: string[] = [];
  /** True while the version lookup is in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  /**
   * Swift `AboutSwiftUIVM.init` — every stored property is read at construction time.
   * `fullVersion` reads the bundle info asynchronously here, so it is the one value that
   * arrives after the first frame and the only reason `isLoading` exists.
   */
  aboutToAppear(): void {
    this.contributorLists = [
      JamiConstants.CONTRIBUTORS_DEVELOPERS,
      JamiConstants.CONTRIBUTORS_MEDIA,
      JamiConstants.CONTRIBUTORS_COMMUNITY_MANAGEMENT,
      JamiConstants.SPECIAL_THANKS
    ];
    this.loadVersion();
  }

  /** Swift `let fullVersion: String = Constants.fullVersion ?? ""`. */
  private loadVersion(): void {
    JamiConstants.fullVersion()
      .then((value: string): void => {
        this.version = value;
        this.isLoading = false;
      })
      .catch((error: BusinessError): void => {
        // Swift's `?? ""` — a version that cannot be read leaves the label empty rather than
        // taking the screen down, but the failure is still shown and logged.
        this.version = '';
        this.errorText = describeError(error);
        this.isLoading = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'fullVersion failed: %{public}s', this.errorText);
      });
  }

  private hostContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** Swift `mailtoURL(email:subject:body:)` — URLComponents with the two query items. */
  private mailtoUrl(): string {
    const subject: string = encodeURIComponent(FEEDBACK_SUBJECT);
    const body: string = encodeURIComponent(FEEDBACK_BODY);
    return `mailto:${FEEDBACK_EMAIL}?subject=${subject}&body=${body}`;
  }

  /** Swift `dismissHandler.dismissView()` — the pushed page pops back to its origin. */
  private dismissView(): void {
    router.back();
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
   * scheme; here the refusal is surfaced, because a button that appears to do nothing is the
   * defect this screen would otherwise ship (no mail client => no mailto handler).
   */
  private open(url: string): void {
    this.errorText = '';
    ShareActions.openLink(this.hostContext(), url)
      .then((opened: boolean): void => {
        if (!opened) {
          this.errorText = url;
        }
      })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'openLink failed: %{public}s', this.errorText);
      });
  }

  /**
   * Swift `aboutContentScrollView`'s grouped credits card: a label / list pair per contributor
   * group, all of them off JamiConstants, none of them a literal in this page.
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
              this.dismissView();
            }
          })
        }
        .width('100%')

        Image($r('app.media.jami_gnupackage'))
          // Swift `.resizable().aspectRatio(contentMode: .fit).frame(height: 30)`.
          .height(LOGO_HEIGHT)
          .objectFit(ImageFit.Contain)
          .accessibilityText($r('app.string.accessibility_about_jami_title'))
      }
      .width('100%')

      // Swift `aboutContentScrollView`.
      Scroll() {
        Column({ space: ABOUT_PADDING }) {
          Column() {
            // Swift `Text(Constants.versionName).bold()`.
            Text(JamiConstants.VERSION_NAME)
              .fontSize($r('sys.float.Body_L'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.label'))
            // Swift `Text("Version: \(model.fullVersion)")` <- svc_daemon, `.caption` in
            // `secondaryLabel`.
            Text(`${VERSION_LABEL}${this.version}`)
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

          // Swift: the credits VStack inside `.background(systemGroupedBackground).cornerRadius(8)`.
          Column() {
            Text($r('app.string.about_jami_header'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.label'))
            this.creditsGroup($r('app.string.about_jami_developers'), 0)
            this.creditsGroup($r('app.string.about_jami_media'), 1)
            this.creditsGroup($r('app.string.about_jami_community_management'), 2)
            this.creditsGroup($r('app.string.about_jami_special_thanks'), 3)
            Text($r('app.string.about_jami_info'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.label'))
              .margin({ top: CREDITS_GAP * 2 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          // Swift `.padding().background(systemGroupedBackground).cornerRadius(8)` — grey on the
          // white page.
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          .backgroundColor($r('sys.color.comp_background_gray'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // Swift `VStack(alignment: .leading, spacing: padding)` inside `.padding(.horizontal)`.
        .padding({
          left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
          right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
        })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }

      // Swift: HStack { Spacer; Button; Spacer(30); Button } — plain text buttons pushed to the
      // trailing edge. AboutSwiftUIView sets no `.accentColor`, so they take the default blue
      // tint at regular weight, not Color.jami.
      Row({ space: LINK_BUTTON_GAP }) {
        Blank()
        Button($r('app.string.about_jami_contribute'))
          .id('about_contribute')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Normal)
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
          .fontWeight(FontWeight.Normal)
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
    .height('100%')
    // Swift `.padding(.vertical)` with `VStack(spacing: padding)`.
    .padding({ top: ABOUT_PADDING, bottom: ABOUT_PADDING })
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_about')
  }
}
