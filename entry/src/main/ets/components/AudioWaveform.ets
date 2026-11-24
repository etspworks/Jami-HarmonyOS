/*
 * comp_audio_waveform — ported from
 * Ring/Ring/Features/Conversations/MediaRecord/MediaRecordView.swift
 * `private struct AudioWaveformView` (line 349) and `private struct WaveformBar` (line 362):
 *
 *   AudioWaveformView: HStack(spacing: 4) { ForEach(0..<20) { WaveformBar(index:isAnimating:) } }
 *   WaveformBar:       RoundedRectangle(cornerRadius: 3).fill(Color.jami)
 *                        .frame(width: 4, height: height)
 *                      startAnimation(): withAnimation(.easeInOut(
 *                          duration: .random(in: 0.5...0.8))
 *                          .repeatForever(autoreverses: true)
 *                          .delay(index * 0.06)) { height = .random(in: 8...60) }
 *                      isAnimating false -> easeInOut(0.3) back to 8
 *
 * THE SOURCE READS NO AUDIO LEVELS. The plan's bindingContract calls this site
 * `svc_audio <- AudioWaveformView levels`, but `WaveformBar` takes only `index` and
 * `isAnimating` — the heights are a per-bar RANDOM duration, not a measured level. The one
 * invariant says the source wins, so this is the source's animation, not an invented meter;
 * reported to the orchestrator as a bindingContract that overstates the source.
 *
 * The random duration is drawn ONCE per bar (Swift draws it once per `startAnimation()`, and
 * re-drawing it on every re-render would make the bars jitter their own tempo).
 *
 * S3: structure + the source's own animation parameters. Colour/size polish is S5.
 */

/** Swift `private let barCount = 20`. */
const BAR_COUNT: number = 20;
/** Swift `HStack(spacing: 4)`. */
const BAR_GAP: number = 4;
/** Swift `.frame(width: 4, ...)`. */
const BAR_WIDTH: number = 4;
/** Swift `RoundedRectangle(cornerRadius: 3)`. */
const BAR_RADIUS: number = 3;
/** Swift `Animation.waveformBarMinHeight` / `waveformBarMaxHeight`. */
const BAR_MIN_HEIGHT: number = 8;
const BAR_MAX_HEIGHT: number = 60;
/** Swift `Animation.waveformBarMinDuration` / `waveformBarMaxDuration`, in ms. */
const BAR_MIN_DURATION: number = 500;
const BAR_MAX_DURATION: number = 800;
/** Swift `Animation.waveformBarStaggerDelay` (0.06s), in ms. */
const BAR_STAGGER_DELAY: number = 60;
/** Swift `Animation.durationNormal` — the ease back to the min height. */
const SETTLE_DURATION: number = 300;

/** Swift `private struct WaveformBar`. */
@Component
export struct WaveformBar {
  /** Swift `let index: Int` — only the stagger delay depends on it. */
  @Prop index: number = 0;
  /** Swift `let isAnimating: Bool`. */
  @Prop @Watch('onAnimatingChanged') isAnimating: boolean = false;

  /** Swift `@SwiftUI.State private var height: CGFloat = Animation.waveformBarMinHeight`. */
  @State private barHeight: number = BAR_MIN_HEIGHT;
  /** Swift `Double.random(in: 0.5...0.8)`, drawn once so the bar keeps its own tempo. */
  private beatDuration: number = BAR_MIN_DURATION;

  aboutToAppear(): void {
    this.beatDuration = BAR_MIN_DURATION +
      Math.floor(Math.random() * (BAR_MAX_DURATION - BAR_MIN_DURATION));
  }

  /**
   * Swift `.onChange(of: isAnimating)` — start, or ease back down. `startAnimation()` aims each
   * bar at its own `CGFloat.random(in: 8...60)`, so the bars differ in height, not only in phase.
   */
  private onAnimatingChanged(): void {
    this.barHeight = this.isAnimating
      ? BAR_MIN_HEIGHT + Math.random() * (BAR_MAX_HEIGHT - BAR_MIN_HEIGHT) : BAR_MIN_HEIGHT;
  }

  build() {
    // `iterations: -1` + `PlayMode.Alternate` is `.repeatForever(autoreverses: true)`.
    Column()
      .width(BAR_WIDTH)
      .height(this.barHeight)
      .borderRadius(BAR_RADIUS)
      .backgroundColor($r('app.color.jami'))
      .animation({
        duration: this.isAnimating ? this.beatDuration : SETTLE_DURATION,
        curve: Curve.EaseInOut,
        delay: this.isAnimating ? this.index * BAR_STAGGER_DELAY : 0,
        iterations: this.isAnimating ? -1 : 1,
        playMode: this.isAnimating ? PlayMode.Alternate : PlayMode.Normal
      })
      // Swift `.onAppear { if isAnimating { startAnimation() } }`. Set in aboutToAppear the
      // height was already at its target on the first frame, so nothing animated (TC-CHAT-480).
      .onAppear(() => {
        this.onAnimatingChanged();
      })
  }
}

/** Swift `private struct AudioWaveformView`. */
@Component
export struct AudioWaveformView {
  /** Swift `let isAnimating: Bool` — true only while the recorder is running. */
  @Prop isAnimating: boolean = false;

  /** Swift `ForEach(0..<barCount, id: \.self)` — a fixed 20, so ForEach, not LazyForEach. */
  private barIndexes(): number[] {
    const indexes: number[] = [];
    for (let i: number = 0; i < BAR_COUNT; i++) {
      indexes.push(i);
    }
    return indexes;
  }

  build() {
    Row({ space: BAR_GAP }) {
      ForEach(this.barIndexes(), (index: number) => {
        WaveformBar({ index: index, isAnimating: this.isAnimating })
      }, (index: number) => index.toString())
    }
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
