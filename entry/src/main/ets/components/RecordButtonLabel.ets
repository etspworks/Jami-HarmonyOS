/*
 * comp_record_button_label — ported from
 * Ring/Ring/Features/Conversations/MediaRecord/MediaRecordView.swift
 * `private struct RecordButtonLabel` (line 322):
 *
 *   ZStack {
 *     Circle().stroke(.white.opacity(0.6), lineWidth: 3).frame(72)
 *     if isRecording { RoundedRectangle(cornerRadius: 6).fill(.white).frame(24) }
 *     else           { Circle().fill(.red).frame(48) }
 *   }
 *   .frame(72).glassCircleBackground()
 *   .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)
 *
 * The ring, the stop square and the record dot are the source's own GEOMETRY (a stroked
 * circle and two filled rects), not icon glyphs — so they are containers with a border and a
 * corner radius, which is what the ladder's "never hand-author icon geometry" leaves alone:
 * there is no SF Symbol here to resolve.
 *
 * The LABEL only. Its tap target, its Rule-12 slug (`mediaRecordToggleRecording`) and its
 * handler belong to the Button in MediaRecordView, so they live on the page.
 *
 * S5 — STYLE. Every value is Swift's own (`Layout.primaryButtonSize` 72,
 * `Style.ringStrokeWidth` 3 at `ringStrokeOpacity` 0.6, `recordDotSize` 48,
 * `stopSquareSize` 24 at corner 6) plus the two things S3 deferred: the
 * `.glassCircleBackground()` behind the ring — GLASS_FILL, the record screen's dark glass,
 * with ArkUI's `.backdropBlur` for the UIBlurEffect(.dark) half — and the
 * `.spring(response: 0.3, dampingFraction: 0.6)` the dot/square swap rides on.
 * The capture agrees: [159,704]-[234,779] is 75 x 75 on a 393 pt screen.
 */

/** Swift `Layout.primaryButtonSize`. */
const BUTTON_SIZE: number = 72;
/** Swift `Style.ringStrokeWidth` / `ringStrokeOpacity`. */
const RING_STROKE_WIDTH: number = 3;
const RING_STROKE_COLOR: string = '#99FFFFFF';
/** Swift `Style.recordDotSize`. */
const RECORD_DOT_SIZE: number = 48;
/** Swift `Style.stopSquareSize` / `stopSquareCornerRadius`. */
const STOP_SQUARE_SIZE: number = 24;
const STOP_SQUARE_RADIUS: number = 6;
/** iOS `Color.red`, which is not ArkUI's `Color.Red` (#FF0000). */
const IOS_RED: string = '#FF3B30';
/*
 * Swift `.glassCircleBackground()` — UIBlurEffect(.dark) plus a black gradient, hairlined in
 * white 0.2. The hairline is NOT drawn here: this control already carries a 3 pt white ring
 * of its own (`Style.ringStrokeWidth`), and ArkUI gives a node one border, so the ring wins.
 */
const GLASS_BLUR: number = 20;
/** UIBlurEffect(.dark)'s tint — the record screen's GLASS_FILL (TC-CHAT-375). */
// UIBlurEffect(.dark) solved from the sim: rgb 19 over black, ~84 over white (both met).
const GLASS_FILL: string = '#BD1A1A1A';
/** Swift `.animation(.spring(response: 0.3, dampingFraction: 0.6), value: isRecording)`. */
const SWAP_ANIMATION_MS: number = 300;

@Component
export struct RecordButtonLabel {
  /** Swift `let isRecording: Bool`. */
  @Prop isRecording: boolean = false;

  build() {
    Stack() {
      if (this.isRecording) {
        // Swift `RoundedRectangle(cornerRadius: 6).fill(.white).frame(24)`.
        Column()
          .width(STOP_SQUARE_SIZE)
          .height(STOP_SQUARE_SIZE)
          .borderRadius(STOP_SQUARE_RADIUS)
          .backgroundColor(Color.White)
      } else {
        // Swift `Circle().fill(.red).frame(48)`.
        Column()
          .width(RECORD_DOT_SIZE)
          .height(RECORD_DOT_SIZE)
          .borderRadius(RECORD_DOT_SIZE / 2)
          .backgroundColor(IOS_RED)
      }
    }
    .width(BUTTON_SIZE)
    .height(BUTTON_SIZE)
    // Swift `.glassCircleBackground()` UNDER the ring: the blurred dark disc is what makes
    // the ring and the dot read against a bright camera frame as well as a black one.
    .backgroundColor(GLASS_FILL)
    .backdropBlur(GLASS_BLUR)
    // Swift `Circle().stroke(Color.white.opacity(0.6), lineWidth: 3)`.
    .borderWidth(RING_STROKE_WIDTH)
    .borderColor(RING_STROKE_COLOR)
    .borderRadius(BUTTON_SIZE / 2)
    // Swift `.animation(.spring(...), value: isRecording)` — the dot morphs into the stop
    // square rather than cutting to it.
    .animation({ duration: SWAP_ANIMATION_MS, curve: Curve.Friction })
  }
}
