/*
 * comp_buttons_view — ported from Ring/Ring/Features/Walkthrough/Views/WelcomeView.swift
 * `struct ButtonsView` (line 216). The welcome button stack, with its two disclosure groups:
 *
 *   VStack(spacing: 12) {
 *     button(L10n.CreateAccount.createAccountFormTitle)  -> model.openAccountCreation
 *       .accessibilityIdentifier(AccessibilityIdentifiers.joinJamiButton)
 *     button(L10n.Welcome.haveAccount)                   -> showImportOptions.toggle()
 *     if showImportOptions {
 *       expandedbutton(L10n.Welcome.linkDevice)          -> model.openLinkDevice
 *       expandedbutton(L10n.Welcome.linkBackup)          -> model.openImportArchive
 *     }
 *     advancedButton(L10n.Account.advancedFeatures)      -> showAdvancedOptions.toggle()
 *     if showAdvancedOptions {
 *       expandedbutton(L10n.Welcome.connectToJAMS)       -> model.openJAMS
 *       expandedbutton(L10n.Account.createSipAccount)    -> model.openSIP
 *     }
 *   }
 *
 * The two disclosure flags are the HOST's `@SwiftUI.State` bound in with `$` (WelcomeView owns
 * them), so they are `@Link` here — conditionalVariants[import_expanded] / [advanced_expanded].
 * Every action is the host's too: this component draws buttons, the view model does the work.
 */
/*
 * S5 STYLE — the three button treatments are the SOURCE's three private helpers, and the
 * WelcomeView capture agrees with every value in them:
 *
 *   button(_:)         .padding(12).frame(maxWidth: 500)
 *                      .background(Color.jamiButtonPrimary)            -> sampled #005599
 *                      .foregroundColor(Color(UIColor.systemBackground)) -> background_primary
 *                         (white in light, black on the light dark-mode #00B9E9 fill)
 *                      .cornerRadius(12)
 *   expandedbutton(_:) same, but .background(Color.jamiButtonWithOpacity),
 *                      .foregroundColor(Color.jamiButtonPrimary) and a 1 pt
 *                      RoundedRectangle(cornerRadius: 12).stroke(Color.jamiButtonPrimary)
 *                      -> a translucent fill the marbled background shows through, with a
 *                         #005599 hairline (sampled at x 17, y 516)
 *   advancedButton(_:) .padding(12).frame(maxWidth: 500).foregroundColor(Color.jami)
 *                      -> NO fill and NO border at all; label sampled #00345F
 *
 * Every label is a plain SwiftUI `Text`, i.e. the regular body weight; an ArkUI Button draws its
 * label at Medium unless told otherwise, hence `FontWeight.Normal` on each (T-1629).
 *
 * Geometry, from the capture: every button runs x 16..377 (the page's own 16 pt margin) and is
 * 44-45 high = 12 + 21 + 12, with the VStack's 12 pt gap between them
 * ([16,382][377,426], [16,438][377,482], [16,494][377,539], ...).
 *
 * The attributes are spelled out on each Button rather than shared through an `@Extend`:
 * `@Styles` cannot carry a component-specific attribute such as `fontColor`, and an `@Extend`
 * declaration reads to the structure-freeze diff as a newly added component.
 */
@Component
export struct ButtonsView {
  /** Swift `@Binding var showImportOptions: Bool` (plan: conditionalVariants[import_expanded]). */
  @Link isImportExpanded: boolean;
  /** Swift `@Binding var showAdvancedOptions: Bool` (plan: [advanced_expanded]). */
  @Link isAdvancedExpanded: boolean;

  /** Swift `model.openAccountCreation(stateHandler:)`. */
  onJoinJami: () => void = () => {
    console.debug('ButtonsView: onJoinJami not supplied');
  };
  /** Swift `model.openLinkDevice(stateHandler:)`. */
  onLinkDevice: () => void = () => {
    console.debug('ButtonsView: onLinkDevice not supplied');
  };
  /** Swift `model.openImportArchive(stateHandler:)`. */
  onImportArchive: () => void = () => {
    console.debug('ButtonsView: onImportArchive not supplied');
  };
  /** Swift `model.openJAMS(stateHandler:)`. */
  onConnectJams: () => void = () => {
    console.debug('ButtonsView: onConnectJams not supplied');
  };
  /** Swift `model.openSIP(stateHandler:)`. */
  onCreateSipAccount: () => void = () => {
    console.debug('ButtonsView: onCreateSipAccount not supplied');
  };

  build() {
    Column({ space: 12 }) {
      // Swift `button(L10n.CreateAccount.createAccountFormTitle)`.
      Button($r('app.string.create_account_create_account_form_title'))
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ maxWidth: 500, minHeight: 44 })
        .padding(12)
        .backgroundColor($r('app.color.jami_button_primary'))
        .fontColor($r('sys.color.background_primary'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Normal)
        .borderRadius(12)
        .id('joinJamiButtonIdentifier')
        .onClick(() => {
          this.onJoinJami();
        })

      // Swift `button(L10n.Welcome.haveAccount)` — `withAnimation { showImportOptions.toggle() }`.
      Button($r('app.string.welcome_have_account'))
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ maxWidth: 500, minHeight: 44 })
        .padding(12)
        .backgroundColor($r('app.color.jami_button_primary'))
        .fontColor($r('sys.color.background_primary'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Normal)
        .borderRadius(12)
        .id('welcomeHaveAccount')
        .onClick(() => {
          animateTo({ duration: 250 }, () => {
            this.isImportExpanded = !this.isImportExpanded;
          });
        })

      // conditionalVariants[import_expanded]: `if showImportOptions { ... }`.
      if (this.isImportExpanded) {
        Button($r('app.string.welcome_link_device'))
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ maxWidth: 500, minHeight: 44 })
          .padding(12)
          .backgroundColor($r('app.color.jami_button_with_opacity'))
          .fontColor($r('app.color.jami_button_primary'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Normal)
          .border({ width: 1, color: $r('app.color.jami_button_primary'), radius: 12 })
          .id('welcomeLinkDevice')
          .onClick(() => {
            this.onLinkDevice();
          })
        Button($r('app.string.welcome_link_backup'))
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ maxWidth: 500, minHeight: 44 })
          .padding(12)
          .backgroundColor($r('app.color.jami_button_with_opacity'))
          .fontColor($r('app.color.jami_button_primary'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Normal)
          .border({ width: 1, color: $r('app.color.jami_button_primary'), radius: 12 })
          .id('welcomeLinkBackup')
          .onClick(() => {
            this.onImportArchive();
          })
      }

      // Swift `advancedButton(L10n.Account.advancedFeatures)` — a plain text button, no fill.
      Button($r('app.string.account_advanced_features'))
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ maxWidth: 500, minHeight: 44 })
        .padding(12)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.jami'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Normal)
        .id('welcomeAdvancedFeatures')
        .onClick(() => {
          animateTo({ duration: 250 }, () => {
            this.isAdvancedExpanded = !this.isAdvancedExpanded;
          });
        })

      // conditionalVariants[advanced_expanded]: `if showAdvancedOptions { ... }`.
      if (this.isAdvancedExpanded) {
        Button($r('app.string.welcome_connect_to_jams'))
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ maxWidth: 500, minHeight: 44 })
          .padding(12)
          .backgroundColor($r('app.color.jami_button_with_opacity'))
          .fontColor($r('app.color.jami_button_primary'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Normal)
          .border({ width: 1, color: $r('app.color.jami_button_primary'), radius: 12 })
          .id('welcomeConnectJams')
          .onClick(() => {
            this.onConnectJams();
          })
        Button($r('app.string.account_create_sip_account'))
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ maxWidth: 500, minHeight: 44 })
          .padding(12)
          .backgroundColor($r('app.color.jami_button_with_opacity'))
          .fontColor($r('app.color.jami_button_primary'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Normal)
          .border({ width: 1, color: $r('app.color.jami_button_primary'), radius: 12 })
          .id('welcomeCreateSipAccount')
          .onClick(() => {
            this.onCreateSipAccount();
          })
      }
    }
    .width('100%')
  }
}
