/*
 * comp_indicator — ported from Ring/Ring/Helpers/SwiftUIViews.swift `struct Indicator`
 * (line 28): the sheet grabber bar, horizontal or vertical.
 */
export enum IndicatorOrientation {
  HORIZONTAL = 'HORIZONTAL',
  VERTICAL = 'VERTICAL'
}

const INDICATOR_HEIGHT: number = 5;
const INDICATOR_LENGTH: number = 60;

@Component
export struct Indicator {
  /** Swift `let orientation: IndicatorOrientation`. */
  orientation: IndicatorOrientation = IndicatorOrientation.HORIZONTAL;

  build() {
    Row()
      .width(this.orientation === IndicatorOrientation.HORIZONTAL ? INDICATOR_LENGTH : INDICATOR_HEIGHT)
      .height(this.orientation === IndicatorOrientation.HORIZONTAL ? INDICATOR_HEIGHT : INDICATOR_LENGTH)
      .borderRadius(INDICATOR_HEIGHT / 2)
      .backgroundColor('#99FFFFFF')
  }
}
