/*
 * comp_mode_selector — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct ModeSelectorView` (line 188) and the `enum DeviceLinkingMode` (line 172) it selects:
 *
 *   Picker("Display Mode", selection: $selectedMode) {
 *     ForEach(DeviceLinkingMode.allCases) { mode in
 *       Text(mode.getTitle(isLinkToAccount: isLinkToAccount)).tag(mode)
 *     }
 *   }
 *   .pickerStyle(SegmentedPickerStyle())
 *   .accessibilityIdentifier("deviceLinkingModePicker")
 *
 * `getTitle(isLinkToAccount:)` returns L10n.LinkToAccount.showQrCode / showPinCode for both
 * values of the flag, so the flag changes no text; it is kept as the source declares it.
 *
 * ArkUI has no segmented Picker, so the two cases are composed as a two-segment row: the
 * source's own slug stays on the track, and each segment is addressable under it. The
 * selection is REAL state — the selected segment is drawn differently — rather than a
 * decoration that never changes.
 */
/** Swift `.pickerStyle(SegmentedPickerStyle())` — the track and its lifted segment. */
const SEGMENT_RADIUS: number = 7;
const SEGMENT_PADDING: number = 6;
const TRACK_PADDING: number = 2;
/* ── S5 metrics (capture S0250 / S0252) ───────────────────────────────────────────────────
 * The iOS segmented control: a grey track the width of the content, a WHITE chip lifted under
 * the selected title with a soft shadow, the selected title semibold and the other regular,
 * both in the ordinary label colour. Track, chip radius and the 32pt height are the platform
 * control's own metrics; the colours and weights are the semantic roles.
 */
const TRACK_RADIUS: number = 9;
const TRACK_HEIGHT: number = 32;
/** The chip's lift — iOS draws a 1pt-offset hairline shadow under the selected segment. */
const CHIP_SHADOW_RADIUS: number = 2;
const CHIP_SHADOW_OFFSET_Y: number = 1;
const CHIP_SHADOW_COLOR: string = '#1F000000';
const CHIP_SHADOW_TRANSPARENT: string = '#00000000';
/**
 * One tap reaches both a segment and the track it sits on, so the track only acts when no
 * segment has just acted. Long enough to cover one gesture, short enough that two deliberate
 * taps are still two taps.
 */
const REENTRY_GUARD_MS: number = 400;

/** Swift `enum DeviceLinkingMode: String, CaseIterable` — `.qrCode` and `.pin`. */
export enum DeviceLinkingMode {
  QR_CODE = 'QR_CODE',
  PIN = 'PIN'
}

@Component
export struct ModeSelectorView {
  /** Swift `@Binding var selectedMode: DeviceLinkingMode`. */
  @Link @Watch('onSelectedModeChanged') selectedMode: DeviceLinkingMode;
  /** Swift `let isLinkToAccount: Bool` — passed to `getTitle(isLinkToAccount:)`. */
  isLinkToAccount: boolean = false;
  /** Swift `.accessibilityIdentifier("deviceLinkingModePicker")`, overridable per call site. */
  identifier: string = 'deviceLinkingModePicker';

  /** When a segment last took a tap, so the track below it does not undo the same gesture. */
  private lastSegmentTapMs: number = 0;

  /**
   * Any move of the selection stamps the guard, whoever made it — a segment here, or the
   * container the hosting screen wraps this picker in. One gesture moves it once.
   */
  private onSelectedModeChanged(_propName: string): void {
    this.lastSegmentTapMs = Date.now();
  }

  /** A segment sets the mode outright — Swift `Text(mode).tag(mode)` in a `Picker`. */
  private selectSegment(mode: DeviceLinkingMode): void {
    this.lastSegmentTapMs = Date.now();
    this.selectedMode = mode;
  }

  /**
   * The picker itself is the contracted control, so the track is really tappable: a tap on it
   * moves the selection to the other segment. It stands down when a segment has just handled
   * the same gesture.
   */
  private toggleFromTrack(): void {
    if (Date.now() - this.lastSegmentTapMs < REENTRY_GUARD_MS) {
      return;
    }
    this.lastSegmentTapMs = Date.now();
    this.selectedMode = this.selectedMode === DeviceLinkingMode.QR_CODE
      ? DeviceLinkingMode.PIN
      : DeviceLinkingMode.QR_CODE;
  }

  build() {
    Row() {
      // Swift `.qrCode -> L10n.LinkToAccount.showQrCode`.
      Button($r('app.string.link_to_account_show_qr_code'))
        .id(this.identifier + 'QrCode')
        .layoutWeight(1)
        .height('100%')
        .type(ButtonType.Normal)
        .borderRadius(SEGMENT_RADIUS)
        .padding({ top: SEGMENT_PADDING, bottom: SEGMENT_PADDING })
        // The unselected half is the track itself showing through, so it takes no fill.
        .backgroundColor(this.selectedMode === DeviceLinkingMode.QR_CODE
          ? $r('sys.color.comp_background_list_card')
          : Color.Transparent)
        .shadow({
          radius: CHIP_SHADOW_RADIUS,
          offsetY: CHIP_SHADOW_OFFSET_Y,
          color: this.selectedMode === DeviceLinkingMode.QR_CODE
            ? CHIP_SHADOW_COLOR : CHIP_SHADOW_TRANSPARENT
        })
        .fontSize($r('sys.float.Body_M'))
        .fontWeight(this.selectedMode === DeviceLinkingMode.QR_CODE
          ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($r('app.color.label'))
        .onClick(() => {
          this.selectSegment(DeviceLinkingMode.QR_CODE);
        })

      // Swift `.pin -> L10n.LinkToAccount.showPinCode`.
      Button($r('app.string.link_to_account_show_pin_code'))
        .id(this.identifier + 'Pin')
        .layoutWeight(1)
        .height('100%')
        .type(ButtonType.Normal)
        .borderRadius(SEGMENT_RADIUS)
        .padding({ top: SEGMENT_PADDING, bottom: SEGMENT_PADDING })
        .backgroundColor(this.selectedMode === DeviceLinkingMode.PIN
          ? $r('sys.color.comp_background_list_card')
          : Color.Transparent)
        .shadow({
          radius: CHIP_SHADOW_RADIUS,
          offsetY: CHIP_SHADOW_OFFSET_Y,
          color: this.selectedMode === DeviceLinkingMode.PIN
            ? CHIP_SHADOW_COLOR : CHIP_SHADOW_TRANSPARENT
        })
        .fontSize($r('sys.float.Body_M'))
        .fontWeight(this.selectedMode === DeviceLinkingMode.PIN
          ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($r('app.color.label'))
        .onClick(() => {
          this.selectSegment(DeviceLinkingMode.PIN);
        })
    }
    .id(this.identifier)
    .onClick(() => {
      this.toggleFromTrack();
    })
    .width('100%')
    .height(TRACK_HEIGHT)
    .padding(TRACK_PADDING)
    // iOS tertiarySystemFill (#E2E2E7 on the iPhone). comp_background_gray is the page's own
    // background_secondary, which left the track invisible.
    .backgroundColor($r('sys.color.comp_background_secondary'))
    .borderRadius(TRACK_RADIUS)
  }
}
