/*
 * comp_circle_view — ported from Ring/Ring/SwarmInfo/View/SettingsView.swift
 * `struct CircleView` (line 300):
 *
 *   ZStack {
 *     Circle().fill(Color(hex: colorString) ?? .gray).frame(circleSize)
 *       .onTapGesture { selectedColor = colorString }
 *       .accessibilityIdentifier("color_picker_swatch_itemroot")
 *       .padding(circlePadding)
 *     if selectedColor == colorString {
 *       Circle().stroke(Color(hex: colorString) ?? .gray, lineWidth: circleStrokeWidth)
 *         .frame(circleStrokeSize)
 *     }
 *   }
 *   .accessibilityLabel(Constants.swarmColors[colorString] ?? "")
 *
 * One swatch of the swarm colour grid, instantiated once per colour — so its slug is the
 * SHARED row id the source already gives it (`..._itemroot`), which is what lets the replay
 * resolve `tap-card-N` by index (Rule 12's list-row exception).
 *
 * `Color(hex:) ?? .gray` is `argbFromHexString`, which the ported model already carries.
 *
 * S3: structure only.
 */
import { common } from '@kit.AbilityKit';
import { JamiConstants } from '../common/JamiConstants';

@Component
export struct CircleView {
  /** Swift `let colorString: String` — the '#RRGGBB' key of Constants.swarmColors. */
  @Prop colorString: string = '';
  /** Swift `@Binding var selectedColor: String`. */
  @Link selectedColor: string;
  /** Swift `let circleSize` / `circleStrokeWidth` / `circleStrokeSize` / `circlePadding`. */
  @Prop circleSize: number = 40;
  @Prop circleStrokeWidth: number = 5;
  @Prop circleStrokeSize: number = 50;
  @Prop circlePadding: number = 5;

  /**
   * Swift `Constants.swarmColors[colorString] ?? ""` — the colour's spoken name. The map
   * holds the resource NAME, so it is resolved through the resourceManager: `$r()` takes a
   * literal and cannot be built from a variable.
   */
  private colorName(): string {
    const name: string | undefined = JamiConstants.SWARM_COLORS.get(this.colorString);
    if (name === undefined) {
      return '';
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  build() {
    Stack() {
      // Swift `Circle().fill(Color(hex: colorString) ?? .gray)`.
      Column()
        .width(this.circleSize)
        .height(this.circleSize)
        .borderRadius(this.circleSize / 2)
        .backgroundColor(this.colorString)
        .margin(this.circlePadding)
        .id('color_picker_swatch_itemroot')
        .onClick(() => {
          this.selectedColor = this.colorString;
        })

      // Swift `if selectedColor == colorString { Circle().stroke(...) }` — the selection ring.
      if (this.selectedColor === this.colorString) {
        Column()
          .width(this.circleStrokeSize)
          .height(this.circleStrokeSize)
          .borderRadius(this.circleStrokeSize / 2)
          .borderWidth(this.circleStrokeWidth)
          .borderColor(this.colorString)
          // The ring is decoration over the swatch; it must not eat the swatch's tap.
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width(this.circleStrokeSize)
    .height(this.circleStrokeSize)
    .accessibilityText(this.colorName())
  }
}
