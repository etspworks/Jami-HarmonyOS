/*
 * comp_header_view — ported from Ring/Ring/Features/Walkthrough/Views/WelcomeView.swift
 * `struct HeaderView` (line 200):
 *
 *   VStack {
 *     Image("jamiGnupackage").resizable().aspectRatio(contentMode: .fit).frame(height: 80)
 *       .accessibilityLabel(L10n.Accessibility.welcomeToJamiTitle).accessibilityHidden(true)
 *     Text(L10n.Welcome.title).font(.headline).multilineTextAlignment(.center)
 *       .frame(maxWidth: 250).padding(.bottom, 30).padding(.top, 20)
 *   }
 *
 * The logo and the title are the welcome screen's bindingContract sites, so both arrive from
 * the host rather than being written into this component.
 */
@Component
export struct HeaderView {
  /** Swift `Image("jamiGnupackage")` — resources/base/media/jami_gnupackage. */
  logo: Resource = $r('app.media.jami_gnupackage');
  /** Swift `Text(L10n.Welcome.title)`. */
  title: ResourceStr = $r('app.string.welcome_title');

  /*
   * S5 — WelcomeView capture (S0035 and every other welcome state; all 12 render this header
   * identically):
   *   logo    [76,193][316,273]  -> 240 x 80, centred. Swift pins only the HEIGHT (80) and lets
   *                                `.aspectRatio(.fit)` choose the width, so the box is full
   *                                width and ImageFit.Contain does the same job (and stays
   *                                correct if the asset's aspect ratio ever differs).
   *   title   [90,301][302,343]  -> two 21 pt lines, centred, inside the 250 pt frame.
   *                                301 - 273 = 28 = the VStack's 8 pt default + `.padding(.top,
   *                                20)`; `.padding(.bottom, 30)` separates it from the buttons.
   * `.font(.headline)` is 17 pt semibold -> Body_L + FontWeight.Medium.
   */
  build() {
    Column() {
      Image(this.logo)
        .width('100%')
        .height(80)
        .objectFit(ImageFit.Contain)
        // Swift `.accessibilityHidden(true)` — the title beside it carries the meaning.
        .accessibilityLevel('no')
      Text(this.title)
        .textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 250 })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .margin({ top: 20, bottom: 30 })
    }
    .width('100%')
  }
}
