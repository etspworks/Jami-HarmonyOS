/*
 * comp_loading_state — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct LoadingStateView` (line 279):
 *
 *   VStack { Text(message).multilineTextAlignment(.center); ProgressView().padding(); Spacer() }
 */
/* ── S5 metrics, the source's own (Views.swift:279-291) + the S0047 capture ─────── */
/** Swift `ProgressView().padding()` — the system 16 pt inset. */
const PROGRESS_INSET: number = 16;
/** Capture: the ActivityIndicator is 20x20 pt (x 186..206, y 232..252). */
const PROGRESS_SIZE: number = 20;

@Component
export struct LoadingStateView {
  /** Swift `let message: String`. */
  message: ResourceStr = '';

  build() {
    Column() {
      Text(this.message)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
      // Swift `ProgressView().padding()`.
      LoadingProgress()
        .width(PROGRESS_SIZE)
        .height(PROGRESS_SIZE)
        .color($r('app.color.jami'))
        .margin(PROGRESS_INSET)
      Blank()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
