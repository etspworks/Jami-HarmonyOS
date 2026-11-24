/*
 * comp_custom_alert — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct CustomAlert<Content>` (line 140):
 *
 *   ZStack { Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)
 *            content.padding().background(secondarySystemBackground).cornerRadius(12)... }
 *
 * An IN-APP alert: the source renders it inside its own view tree behind a `@State` flag
 * (CreateAccountView: `if showEncryptView { encryptViewAlert() }`), not as a system dialog —
 * so it stays a Stack layer here too and the caller keeps owning the flag.
 *
 * The scrim swallows taps on the content behind it, exactly as the Swift ZStack does.
 */
import { ComponentContent } from '@kit.ArkUI';

@Component
export struct CustomAlert {
  /** Swift `@ViewBuilder let content: Content`. */
  @BuilderParam content: () => void;

  build() {
    Stack() {
      // Swift `Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)`.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
      // Swift: `content.padding().background(secondarySystemBackground).cornerRadius(12)
      //         .padding().shadow(radius: 10)` — the inner padding, then the card, then the
      // outer inset that keeps it off the screen edges.
      Column() {
        this.content()
      }
      .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
      .margin($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      .shadow({ radius: 10, color: $r('app.color.shadow_color') })
    }
    .width('100%')
    .height('100%')
  }
}

/*
 * A one-button UIAlertController (`preferredStyle: .alert`, a title and one `.default` action),
 * which the HarmonyOS AlertDialog does not resemble: it is near full width with a large bold
 * title and no hairline (T-0907). Drawn as the iPhone does it: a 270 vp card, corner 14, the
 * title 17 semibold with 20 above and below, then a hairline and one 44 vp action in
 * systemBlue.
 */
const SYSTEM_ALERT_WIDTH: number = 270;
const SYSTEM_ALERT_RADIUS: number = 14;
const SYSTEM_ALERT_TITLE_INSET_V: number = 20;
const SYSTEM_ALERT_TITLE_INSET_H: number = 16;
const SYSTEM_ALERT_ACTION_HEIGHT: number = 44;
/** UIAlertAction's default tint on the iPhone 4.20. */
const SYSTEM_BLUE: string = '#007AFF';

class SystemAlertParams {
  title: ResourceStr;
  close: () => void = (): void => {};

  constructor(title: ResourceStr) {
    this.title = title;
  }
}

@Builder
  function systemAlertCard(params: SystemAlertParams) {
  Column() {
    Text(params.title)
      .width('100%')
      .textAlign(TextAlign.Center)
      .fontSize($r('sys.float.Body_L'))
      .fontWeight(600)
      .fontColor($r('app.color.label'))
      .padding({
        top: SYSTEM_ALERT_TITLE_INSET_V,
        bottom: SYSTEM_ALERT_TITLE_INSET_V,
        left: SYSTEM_ALERT_TITLE_INSET_H,
        right: SYSTEM_ALERT_TITLE_INSET_H
      })
    Divider()
      .strokeWidth(0.5)
      .color($r('sys.color.comp_divider'))
    Button($r('app.string.global_ok'))
      .id('system_alert_ok')
      .type(ButtonType.Normal)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height(SYSTEM_ALERT_ACTION_HEIGHT)
      .fontSize($r('sys.float.Body_L'))
      .fontColor(SYSTEM_BLUE)
      .onClick(() => {
        params.close();
      })
  }
  .width(SYSTEM_ALERT_WIDTH)
  .backgroundColor($r('sys.color.background_secondary'))
  .borderRadius(SYSTEM_ALERT_RADIUS)
  .clip(true)
}

/** Swift `UIAlertController(title:message: nil)` + one `UIAlertAction(title: L10n.Global.ok)`. */
export function showSystemAlert(context: UIContext, title: ResourceStr): void {
  const params: SystemAlertParams = new SystemAlertParams(title);
  const content: ComponentContent<SystemAlertParams> =
    new ComponentContent(context, wrapBuilder(systemAlertCard), params);
  params.close = (): void => {
    context.getPromptAction().closeCustomDialog(content).catch((): void => {});
  };
  context.getPromptAction().openCustomDialog(content, { alignment: DialogAlignment.Center, autoCancel: false })
    .catch((): void => {});
}
