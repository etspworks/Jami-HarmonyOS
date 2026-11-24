/*
 * comp_media_seek_slider — ported from
 * Ring/Ring/Features/Conversations/views/MediaViewHelpers.swift `struct MediaSeekSlider`
 * (line 58), a UISlider wrapped for SwiftUI:
 *
 *   slider.accessibilityIdentifier = "mediaSeekSlider"
 *   minimumValue 0, maximumValue 1
 *   touchDown      -> onSeekStart()      (coordinator.isSeeking = true)
 *   valueChanged   -> onSeekChange(v)
 *   touchUp*       -> onSeekEnd()
 *   onRegister(sink) — the player pushes ~10 positions a second straight into the slider,
 *                      and the sink IGNORES them while a seek is in progress.
 *
 * ArkUI's Slider already gives the three phases through one `onChange(value, mode)`, so the
 * seeking flag lives here rather than in a coordinator object.
 */

/** Track resolution: 0.1 % of the media's duration per step. */
const SLIDER_SCALE: number = 1000;
/** Swift `maximumTrackTintColor = color.withAlphaComponent(0.35)` on white. */
const SLIDER_TRACK_COLOR: string = '#59FFFFFF';
/**
 * Jami 4.21 `ScrubberSlider` (MediaViewHelpers.swift), the media preview's: no thumb, a 4 pt
 * capsule track that thickens to 8 while dragged, white 35% under a white 70% fill that turns
 * full white while dragged.
 */
const SCRUBBER_REST: number = 4;
const SCRUBBER_ACTIVE: number = 8;
const SCRUBBER_FILL: string = '#B3FFFFFF';
const SCRUBBER_SIZE_MS: number = 150;

@Component
export struct MediaSeekSlider {
  /** Swift `slider.value` — 0..1, pushed by the player between seeks. */
  @Prop positionRatio: number = 0;
  /** Swift `coordinator.onSeekStart`. */
  onSeekStart?: () => void;
  /** Swift `coordinator.onSeekChange`. */
  onSeekChange?: (value: number) => void;
  /** Swift `coordinator.onSeekEnd`. */
  onSeekEnd?: () => void;

  /** 4.21's thumbless ScrubberSlider (media preview) instead of the 4.20 UISlider look. */
  scrubber: boolean = false;
  /** Swift `coordinator.isSeeking` — while true the player's pushes are dropped. */
  @State private isSeeking: boolean = false;

  private handle(raw: number, mode: SliderChangeMode): void {
    const value: number = raw / SLIDER_SCALE;
    if (mode === SliderChangeMode.Begin) {
      this.isSeeking = true;
      const start: (() => void) | undefined = this.onSeekStart;
      if (start !== undefined) {
        start();
      }
      return;
    }
    // The release (End) and a tap on the track (Click, which jumps the thumb with no Moving
    // event) carry the final value too: dropping it left the player where it was and the
    // next position push snapped the thumb back.
    const change: ((value: number) => void) | undefined = this.onSeekChange;
    if (change !== undefined) {
      change(value);
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.isSeeking = false;
      const end: (() => void) | undefined = this.onSeekEnd;
      if (end !== undefined) {
        end();
      }
    }
  }

  build() {
    // Swift's sink drops the player's pushes while a seek is in progress; here the same rule
    // holds one level up — onSeekStart tells the player to stop pushing until onSeekEnd.
    // ArkUI's step must be >= 0.01 (else it falls back to 1), and a 0..1 slider with step 1
    // snapped to the ends (device: a drag to 2/3 seeked to the end and the video completed).
    // The track runs 0..SLIDER_SCALE in unit steps; callers keep the 0..1 ratio.
    if (this.scrubber) {
      Slider({ value: this.positionRatio * SLIDER_SCALE, min: 0, max: SLIDER_SCALE, step: 1 })
        .id('mediaSeekSlider')
        .width('100%')
        .selectedColor(this.isSeeking ? Color.White : SCRUBBER_FILL)
        .trackColor(SLIDER_TRACK_COLOR)
        .blockColor(Color.Transparent)
        .blockSize({ width: 0, height: 0 })
        .trackThickness(this.isSeeking ? SCRUBBER_ACTIVE : SCRUBBER_REST)
        .animation({ duration: SCRUBBER_SIZE_MS })
        .onChange((value: number, mode: SliderChangeMode) => {
          this.handle(value, mode);
        })
    } else {
      Slider({ value: this.positionRatio * SLIDER_SCALE, min: 0, max: SLIDER_SCALE, step: 1 })
        .id('mediaSeekSlider')
        // Swift `applyStyle(color: trackColor)`, trackColor defaulting to .white and no caller
        // passing another: white played part and thumb, the rest white at 0.35 (T-1722).
        .width('100%')
        .selectedColor(Color.White)
        .trackColor(SLIDER_TRACK_COLOR)
        .blockColor(Color.White)
        .onChange((value: number, mode: SliderChangeMode) => {
          this.handle(value, mode);
        })
    }
  }
}
