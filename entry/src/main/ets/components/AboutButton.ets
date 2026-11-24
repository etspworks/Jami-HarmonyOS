/*
 * comp_about_button — ported from Ring/Ring/Features/Walkthrough/Views/WelcomeView.swift
 * `struct AboutButton` (line 331):
 *
 *   Button(action: { model.openAboutJami(stateHandler: stateEmitter) },
 *          label: { Text(L10n.Smartlist.aboutJami).padding(12).foregroundColor(.jami) })
 *     .accessibilityIdentifier("welcomeAboutJami")
 *
 * The action is the host's (WelcomeVM.openAboutJami presents AboutSwiftUIView .formModal).
 */
@Component
export struct AboutButton {
  /** Swift `model.openAboutJami(stateHandler:)`. */
  onAboutJami: () => void = () => {
    console.debug('AboutButton: onAboutJami not supplied');
  };

  /*
   * S5 — Swift: `Text(...).padding(12).foregroundColor(.jami)`. No fill, no border, no width
   * frame: the button is content-sized, which the WelcomeView capture confirms exactly —
   * [141,757][251,802], i.e. 110 x 45 centred, where 45 = 12 + 21 + 12. The label pixel is
   * #00345F, which is app.color.jami.
   */
  build() {
    Button($r('app.string.smartlist_about_jami'))
      .type(ButtonType.Normal)
      .padding(12)
      .backgroundColor(Color.Transparent)
      .fontColor($r('app.color.jami'))
      .fontSize($r('sys.float.Body_L'))
      // A SwiftUI Text label is regular; an ArkUI Button defaults to Medium (T-1629).
      .fontWeight(FontWeight.Normal)
      .id('welcomeAboutJami')
      .onClick(() => {
        this.onAboutJami();
      })
  }
}
