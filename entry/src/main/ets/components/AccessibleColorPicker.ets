/*
 * comp_accessible_color_picker — ported from Ring/Ring/SwarmInfo/View/SettingsView.swift
 * `struct AccessibleCustomColorPicker` (line 252):
 *
 *   NavigationView { GeometryReader {
 *     VStack { Spacer
 *              LazyVGrid(columns: [.adaptive(minimum: 40 + 5*2)], spacing: 10) {
 *                ForEach(Array(Constants.swarmColors.keys), id: \.self) { CircleView(...) } }
 *                .frame(maxHeight: 300)
 *              Spacer } }
 *     .navigationTitle(L10n.Swarm.chooseColor)
 *     .navigationBarItems(leading: Button(L10n.Global.cancel) { isPresented = false }
 *                                    .accessibilityIdentifier("color_picker_cancel")) }
 *   .optionalMediumPresentationDetents()
 *
 * The colour ORDER is `Constants.swarmColors`' own key order, which JamiConstants.SWARM_COLORS
 * preserves — a re-ordering would move every swatch under the replay's index-based tap.
 *
 * S5 — STYLE. The grid's metrics are Swift's own (40 / 5 / 50 / 5 / 10, maxHeight 300); the
 * sheet chrome maps by role — a presented sheet is `systemBackground`
 * (sys.color.background_primary), its inline title is 17 pt semibold `.label`, and the
 * leading Cancel takes the app accent the source puts on this hierarchy (`Color.jami`), with
 * a `.separator` hairline under the bar where UIKit draws one.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { JamiConstants } from '../common/JamiConstants';
import { CircleView } from './CircleView';

/** Swift's `circleSize` / `circleStrokeWidth` / `circleStrokeSize` / `circlePadding` / `spacing`. */
const CIRCLE_SIZE: number = 40;
const CIRCLE_STROKE_WIDTH: number = 5;
const CIRCLE_STROKE_SIZE: number = 50;
const CIRCLE_PADDING: number = 5;
const GRID_SPACING: number = 10;
/** Swift `.frame(maxHeight: 300)`. */
const GRID_MAX_HEIGHT: number = 300;
/**
 * The iPhone's grid: `.adaptive(minimum: 50)` with 10 pt spacing fits 6 columns on its 393-414 pt
 * screen, so the 15 colours read 6 / 6 / 3 (T-1688). The same formula gives only 5 on a 374 vp
 * phone, so the column count is the iPhone's rather than the formula's.
 * ponytail: fixed 6 columns; compute them from the width if the unfolded layout should differ.
 */
const GRID_COLUMNS: string = '1fr 1fr 1fr 1fr 1fr 1fr';
/** Swift's inline navigation bar. */
const NAV_BAR_HEIGHT: number = 44;
/** SwiftUI's inline nav title is 17 pt SEMIBOLD; ArkUI spells semibold as the numeric 600. */
const TITLE_WEIGHT: number = 600;
/** UIKit's hairline under a navigation bar. */
const SEPARATOR_WIDTH: number = 0.5;

@Component
export struct AccessibleCustomColorPicker {
  /** Swift `@Binding var isPresented: Bool`. */
  @Link isPresented: boolean;
  /** Swift `@Binding var selectedColor: String`. */
  @Link selectedColor: string;
  /** Swift `let currentColor: String` — the colour in force when the sheet opened. */
  @Prop currentColor: string = '';

  /** Swift `Array(Constants.swarmColors.keys)` — insertion order, deliberately. */
  private swarmColorKeys(): string[] {
    const keys: string[] = [];
    JamiConstants.SWARM_COLORS.forEach((_name: string, hex: string): void => {
      keys.push(hex);
    });
    return keys;
  }

  build() {
    Column() {
      // Swift `.navigationTitle(chooseColor).navigationBarTitleDisplayMode(.inline)` with a
      // leading Cancel — an ArkUI overlay draws no system chrome, so it is composed here.
      Stack({ alignContent: Alignment.Start }) {
        Text($r('app.string.swarm_choose_color'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(TITLE_WEIGHT)
          .fontColor($r('app.color.label'))
        Text($r('app.string.global_cancel'))
          .id('color_picker_cancel')
          .padding({
            start: LengthMetrics.vp(GRID_SPACING),
            end: LengthMetrics.vp(GRID_SPACING)
          })
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.isPresented = false;
          })
      }
      .width('100%')
      .constraintSize({ minHeight: NAV_BAR_HEIGHT })

      // UIKit's hairline under an inline navigation bar.
      Divider()
        .color($r('sys.color.comp_divider'))
        .strokeWidth(SEPARATOR_WIDTH)

      Blank()

      // Swift `LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 10)`.
      Grid() {
        ForEach(this.swarmColorKeys(), (hex: string) => {
          GridItem() {
            CircleView({
              colorString: hex,
              selectedColor: $selectedColor,
              circleSize: CIRCLE_SIZE,
              circleStrokeWidth: CIRCLE_STROKE_WIDTH,
              // SwiftUI's `.stroke` straddles the 50 pt circle (ring 45..55, a 2.5 pt gap round
              // the 40 pt swatch); an ArkUI border is drawn INSIDE its frame, so at 50 the ring
              // touched the swatch and read as a bigger circle (T-1689). 55 gives iOS's ring.
              circleStrokeSize: CIRCLE_STROKE_SIZE + CIRCLE_STROKE_WIDTH,
              circlePadding: CIRCLE_PADDING
            })
          }
        }, (hex: string) => hex)
      }
      .columnsTemplate(GRID_COLUMNS)
      // The columns stretch (as iOS's adaptive items do), so the column width spaces them. A
      // cell is 55 tall with the ring, so rows stay iOS's 50 + 10 apart.
      .rowsGap(GRID_SPACING - CIRCLE_STROKE_WIDTH)
      .width('100%')
      .constraintSize({ maxHeight: GRID_MAX_HEIGHT })
      .padding(GRID_SPACING)

      Blank()
    }
    .width('100%')
    .height('100%')
    // A presented sheet sits on `systemBackground`, not the grouped grey behind it.
    .backgroundColor($r('sys.color.background_primary'))
  }
}
