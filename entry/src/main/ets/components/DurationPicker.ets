/*
 * comp_duration_picker — ported from
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift  `struct DurationPickerView` (line 290)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift  `struct DurationPickerWrapper` (316)
 *   Ring/Ring/UI/DurationPicker.swift                    `class DurationPicker` (line 23)
 *
 * S3 — the real tree of `DurationPickerView.body`:
 *
 *   VStack {
 *     HStack {
 *       Spacer()
 *       Button(action: { isPresented = false }) { Text(L10n.Global.close).foregroundColor(.jami) }
 *         .accessibilityIdentifier("duration_picker_close")
 *     }
 *     DurationPickerWrapper(duration: $duration, maxHours: maxHours).frame(height: 250)
 *   }
 *   .padding()
 *
 * so: a trailing Close item, then the picker body, nothing else. `let maxHours = 10` is the
 * source's own constant and is the component's default here.
 *
 * `DurationPickerWrapper` wraps the UIKit `DurationPicker`, a two-component `UIPickerView`:
 *   numberOfComponents = 2                       -> two side-by-side pickers
 *   component 0 rows   = 0...maxHours, "N hours"
 *   component 1 rows   = 0...59,       "N minutes"
 *   didSelectRow       -> duration = hours * 60 + minutes; if duration == 0 the minutes wheel
 *                         is moved to row 1 and duration becomes 1 (a zero share is refused)
 *   setupPickerWithDuration -> selectRow(duration / 60, 0), selectRow(duration % 60, 1)
 *
 * TWO single-column TextPickers reproduce that, rather than one multi-column picker: ArkUI's
 * multi-column form hands `onChange` a `string[] | string` and a `number[] | number`, so each
 * wheel's own index is only reachable by unpicking a union on every event, while UIPickerView's
 * two components are independent wheels with independent selections anyway.
 *
 * The `UserDefaults.standard.set(duration, forKey: locationSharingDurationKey)` the Swift
 * wrapper performs is NOT done here: a `.ets` component cannot own the page's preference store
 * without opening a second handle on it, so the change is handed up through `onDurationChanged`
 * and the HOST (screen_location_sharing_settings) writes it — the same single-writer shape
 * pages/FileTransferSettingsPage.ets already uses for the sibling GeneralSettings keys.
 */
/* ── the source's own numbers (UtilitiesViews.swift:292,313 / DurationPicker.swift:37,42) ── */
/** Swift `let maxHours = 10`. */
const DEFAULT_MAX_HOURS: number = 10;
/** Swift `for index in 0...59 { minutes.append(index) }` — the last minutes row. */
const MAX_MINUTES: number = 59;
/** Swift `.frame(height: 250)` on the wrapped UIPickerView. */
const PICKER_HEIGHT: number = 250;
/** `didSelectRow`: a zero duration is refused and becomes one minute. */
const MINIMUM_DURATION: number = 1;
/** Minutes per hour — `hours[hoursIndex] * 60 + minutes[minutesIndex]`. */
const MINUTES_PER_HOUR: number = 60;

/*
 * Swift's row titles, `"\(hours[row]) hours"` / `"\(minutes[row]) minutes"`
 * (DurationPicker.swift:63,65), are user-visible text, so they are RESOURCE strings here
 * (`app.string.duration_picker_hours` / `…_minutes`, both `%d …`) formatted through the
 * resource manager rather than a suffix concatenated in code. `TextPicker.range` takes
 * `string[]`, so each row is resolved to a string; the format argument keeps the number's
 * position translatable.
 */

@Component
export struct DurationPickerView {
  /** Swift `@Binding var duration: Int` — the whole duration in MINUTES. */
  @Link duration: number;
  /** Swift `@Binding var isPresented: Bool` — the Close button writes false into it. */
  @Link isPresented: boolean;
  /** Swift `let maxHours = 10`. */
  maxHours: number = DEFAULT_MAX_HOURS;
  /**
   * Swift `picker.onDurationChanged` — the wrapper's callback, which in the source also
   * persists the value. The host does the persisting; this is the notification.
   */
  onDurationChanged?: (duration: number) => void;

  /** One formatter for both wheels — `%d hours` / `%d minutes` with the row number filled in. */
  private rowTitle(resId: number, value: number): string {
    return getContext(this).resourceManager.getStringSync(resId, value);
  }

  /** Swift `for index in 0...maxHours { hours.append(index) }`, as row titles. */
  private hourRows(): string[] {
    const resId: number = $r('app.string.duration_picker_hours').id;
    const rows: string[] = [];
    for (let index: number = 0; index <= this.maxHours; index++) {
      rows.push(this.rowTitle(resId, index));
    }
    return rows;
  }

  /** Swift `for index in 0...59 { minutes.append(index) }`, as row titles. */
  private minuteRows(): string[] {
    const resId: number = $r('app.string.duration_picker_minutes').id;
    const rows: string[] = [];
    for (let index: number = 0; index <= MAX_MINUTES; index++) {
      rows.push(this.rowTitle(resId, index));
    }
    return rows;
  }

  /** Swift `setupPickerWithDuration()` — `selectRow(duration / 60, inComponent: 0)`. */
  private selectedHour(): number {
    const hour: number = Math.floor(this.duration / MINUTES_PER_HOUR);
    return hour > this.maxHours ? this.maxHours : hour;
  }

  /** Swift `setupPickerWithDuration()` — `selectRow(duration % 60, inComponent: 1)`. */
  private selectedMinute(): number {
    return this.duration % MINUTES_PER_HOUR;
  }

  /**
   * ArkUI hands a single-column picker's index as `number | number[]`; the declared union is
   * shared with the multi-column form. One narrowing, in one place.
   */
  private rowIndex(index: number | number[]): number {
    if (typeof index === 'number') {
      return index;
    }
    return index.length > 0 ? index[0] : 0;
  }

  /**
   * Swift `pickerView(_:didSelectRow:inComponent:)` — recompute from BOTH wheels, refuse a
   * zero duration, then report. The hour/minute pair is read back off `this.duration` rather
   * than kept in a second copy, so the two wheels cannot disagree with the bound value.
   */
  private select(hour: number, minute: number): void {
    let next: number = hour * MINUTES_PER_HOUR + minute;
    if (next === 0) {
      // Swift `pickerView.selectRow(1, inComponent: 1, animated: true); duration = 1`.
      next = MINIMUM_DURATION;
    }
    if (next === this.duration) {
      // Swift `if self.duration == duration { return }` — the wrapper's own guard, before it
      // writes the preference. Re-selecting the same row is not a change.
      return;
    }
    this.duration = next;
    const notify: ((duration: number) => void) | undefined = this.onDurationChanged;
    if (notify !== undefined) {
      notify(next);
    }
  }

  /** Swift `Button(action: { withAnimation { isPresented = false } })`. */
  private close(): void {
    this.isPresented = false;
  }

  build() {
    // Swift `VStack { HStack { Spacer(); closeButton }; DurationPickerWrapper… }.padding()`.
    Column() {
      Row() {
        // Swift `Spacer()` — the Close item is trailing.
        Blank()
        // A SwiftUI `Button` whose label is a bare tinted `Text` is a tinted label, not a
        // filled control. The slug sits on the Button itself, which is the clickable node
        // (a slug on a wrapper with the handler beneath it reads `contract-control-inert`).
        Button($r('app.string.global_close'), { type: ButtonType.Normal })
          .id('duration_picker_close')
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.close();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // `DurationPickerWrapper(duration:maxHours:).frame(height: 250)` — the two UIPickerView
      // components, side by side and equally wide, inside that 250. A UIPickerView does not
      // wrap: '10 hours' / '59 minutes' are the last rows, with nothing below them. TextPicker
      // loops by default, which put '0 hours' / '0 minutes' under them (TC-SETTINGS-288).
      Row() {
        TextPicker({ range: this.hourRows(), selected: this.selectedHour() })
          .id('duration_picker_hours')
          .canLoop(false)
          .layoutWeight(1)
          .onChange((_value: string | string[], index: number | number[]) => {
            this.select(this.rowIndex(index), this.selectedMinute());
          })
        TextPicker({ range: this.minuteRows(), selected: this.selectedMinute() })
          .id('duration_picker_minutes')
          .canLoop(false)
          .layoutWeight(1)
          .onChange((_value: string | string[], index: number | number[]) => {
            this.select(this.selectedHour(), this.rowIndex(index));
          })
      }
      .width('100%')
      .height(PICKER_HEIGHT)
    }
    .width('100%')
    // Swift `.padding()` — the system 16pt inset on all four edges.
    .padding($r('sys.float.padding_level8'))
  }
}
