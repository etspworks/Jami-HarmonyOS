/*
 * screen_in_call_dialpad — "In-Call Dialpad", ported from
 *   Ring/Ring/Calls/Views/CallScreenView.swift (InCallDialpadView, line 129)
 *   Ring/Ring/Calls/ViewModels/CallViewModel.swift (showsDialpad, playDTMF(_:))
 *   Ring/Ring/Extensions/View+Helpers.swift
 *
 * presentation: sheet, hostScreen: screen_call. Swift raises it with
 * `.sheet(isPresented: $model.showsDialpad) { InCallDialpadView(model: model) }` on
 * CallScreenView, so it is the content of a .bindSheet() mounted by InCallScreenPage's
 * InCallScreenOverlay — NOT a routed page and NOT registered in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): structure from source only.
 *
 * S3 — the real tree of `InCallDialpadView.body`, verbatim:
 *   VStack(spacing: 18) {
 *       Indicator(orientation: .horizontal).padding(.top, 10)
 *       Spacer()
 *       ForEach(keys, id: \.self) { row in
 *           HStack(spacing: 28) {
 *               ForEach(row, id: \.self) { key in
 *                   Button { model.playDTMF(key) } label: {
 *                       Text(key).frame(width: 72, height: 72)
 *                                .background(Color(.systemGray5)).clipShape(Circle()) }
 *                   .accessibilityIdentifier("in_call_dialpad_key_itemroot") } }
 *       }
 *       Spacer()
 *   }
 *
 * bindingContract[in-call DTMF key grid] / [keys]: `private let keys = [["1","2","3"], …]`
 * <- JamiConstants.DIALPAD_KEYS, rendered through LazyForEach over an ArrayDataSource (one
 * entry per ROW of the grid, which is exactly the source's outer ForEach). Every one of the 12
 * keys is rendered; nothing is a transcribed literal.
 *
 * Every key carries the SAME slug, `in_call_dialpad_key_itemroot` — the source gives all twelve
 * that identifier, and a repeated row is addressed by index, not by a unique id (Rule 12).
 *
 * navOut: none. Besides a key, the only affordance is the sheet's drag dismissal (swipe down).
 *
 * A key is `CallService.playDTMF` -> libjami `playDTMF`: the local tone, and the digit sent on
 * the current call (Account.dtmfType "oversip", set at SIP account creation).
 */
import { ArrayDataSource } from '../common/ArrayDataSource';
import { Indicator, IndicatorOrientation } from '../components/Indicator';
import { JamiConstants } from '../common/JamiConstants';
import { ServiceRegistry } from '../common/ServiceRegistry';

/** Swift `VStack(spacing: 18)`. */
const GRID_GAP: number = 18;
/** Swift `HStack(spacing: 28)`. */
const KEY_GAP: number = 28;
/** Swift `.frame(width: 72, height: 72)` on the key label. */
const KEY_SIZE: number = 72;
/** Swift `.padding(.top, 10)` on the grabber. */
const INDICATOR_TOP: number = 10;
/** Swift `Text(key).font(.system(size: 30, weight: .medium))`. */
const KEY_FONT_SIZE: number = 30;
/** Downward drag (vp) that dismisses the sheet; AboutJamiModalPage's sheet uses the same. */
const DISMISS_DRAG_DISTANCE: number = 100;

@Component
export struct InCallDialpadSheet {
  /** Owned by screen_call; the host's @State drives the sheet. */
  @Link isPresented: boolean;

  /** bindingContract[keys]: Swift `private let keys` <- JamiConstants.DIALPAD_KEYS. */
  @State keys: string[][] = JamiConstants.DIALPAD_KEYS;
  /** True while svc_calls is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  /**
   * bindingContract[in-call DTMF key grid]: LazyForEach's source (CLAUDE.md rule 7). One entry
   * per ROW of the key grid — Swift's outer `ForEach(keys, id: \.self)`.
   */
  @State inCallDTMFKeyGrid: ArrayDataSource<string[]> =
    new ArrayDataSource<string[]>(JamiConstants.DIALPAD_KEYS);

  /** Swift the key Button's action — `model.playDTMF(key)`, nothing else. */
  private playDTMF(key: string): void {
    ServiceRegistry.shared().callService.playDTMF(key);
  }

  /** Swift the inner `ForEach(row, id: \.self) { key in Button … }` — one grid row. */
  @Builder
  private keyRow(row: string[]) {
    Row({ space: KEY_GAP }) {
      ForEach(row, (key: string) => {
        Text(key)
          // Every key carries the source's own shared slug; the replay resolves one by index.
          .id('in_call_dialpad_key_itemroot')
          // Swift `.font(.system(size: 30, weight: .medium))`.
          .fontSize(KEY_FONT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))
          // Swift `.frame(width: 72, height: 72)` on a non-text-driven disc, so a fixed size
          // is right here: the key must stay round whatever the system font size is.
          .width(KEY_SIZE)
          .height(KEY_SIZE)
          .textAlign(TextAlign.Center)
          // Swift `.background(Color(.systemGray5)).clipShape(Circle())` under the sheet's
          // `.preferredColorScheme(.dark)`: systemGray5 dark = #2C2C2E. The sheet is always
          // dark here (InCallScreenPage WithTheme DARK), and sys comp_background_gray resolves
          // to #000000 in that theme on OpenHarmony 7.0, so the keys vanished into the sheet.
          .backgroundColor('#2C2C2E')
          .borderRadius(KEY_SIZE / 2)
          .clip(true)
          .onClick(() => {
            this.playDTMF(key);
          })
      }, (key: string) => key)
    }
    // Swift's HStack is content-sized inside a centred VStack.
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  build() {
    Column({ space: GRID_GAP }) {
      // Swift `Indicator(orientation: .horizontal).padding(.top, 10)` — the sheet grabber.
      Column() {
        Indicator({ orientation: IndicatorOrientation.HORIZONTAL })
      }
      .padding({ top: INDICATOR_TOP })

      Blank()

      // Swift `ForEach(keys, id: \.self) { row in … }` — all four rows, from the bound grid.
      // Swift `VStack(spacing: 18)` — the gap between the four key rows.
      List({ space: GRID_GAP }) {
        LazyForEach(this.inCallDTMFKeyGrid, (row: string[]) => {
          ListItem() {
            this.keyRow(row)
          }
        }, (row: string[]) => row.join(''))
      }
      .width('100%')
      // No layoutWeight: the List sizes to its four rows, so the two Blank()s split the rest
      // and centre the grid, as Swift's Spacer() / rows / Spacer().
      .alignListItem(ListItemAlign.Center)
      .scrollBar(BarState.Off)

      Blank()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.sheet(isPresented:)` with no background of its own, `.preferredColorScheme(.dark)`:
    // iOS's dark elevated systemBackground, #1C1C1E (the call canvas colour), not black.
    .backgroundColor($r('app.color.jami_call_canvas'))
    // Swift `.sheet` swipe-down-to-dismiss; parallel, so the key grid keeps its own pan.
    // ponytail: dismisses on release only; the sheet does not follow the finger.
    .parallelGesture(PanGesture({ direction: PanDirection.Down })
      .onActionEnd((event: GestureEvent) => {
        if (event.offsetY > DISMISS_DRAG_DISTANCE) {
          this.isPresented = false;
        }
      }))
    .id('screen_in_call_dialpad')
  }
}
