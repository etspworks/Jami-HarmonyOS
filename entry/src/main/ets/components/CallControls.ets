/*
 * comp_call_controls — ported from
 *   Ring/Ring/Calls/Views/CallControlsView.swift   (CallControlIcon, ControlButton, the bars)
 *   Ring/Ring/Calls/Views/CallControlsLayout.swift (CallControlIntent, ControlAction, the plan)
 *
 *   CallControlsView = VStack { if !plan.supplemental.isEmpty { controlBar(supplemental) }
 *                               controlBar(primary) }
 *   controlBar       = HStack { ForEach(actions) { ControlButton(action) } }
 *   ControlButton    = Button { CallControlIcon(action) }
 *                        .disabled(!action.isEnabled)
 *                        .accessibilityIdentifier("call_control_\(action.intent)")
 *
 * The bar is DATA-DRIVEN: `CallControlsLayout.plan(_:)` decides which actions exist from the
 * call's state, media and conference role, so the visible buttons are a list, never a fixed row.
 * `primary` is always [audioOutput, mic, camera, flipCamera, hangUp]; `supplemental`
 * ([hold, dialpad]) exists only on a SIP account.
 *
 * Icon substitutions where this SDK's symbol table has no equivalent (checked against
 * sysResource.js, the table results/plan/icon-map.json is resolved from):
 *   video.slash.fill        -> sys.symbol.dot_video_slash
 *   hand.raised(.fill)      -> HAND_RAISED(_FILL), a Path drawn by CallControlIcon for
 *                              TOGGLE_RAISE_HAND (the plan's spread-fingers symbol is not drawn)
 *   circle.grid.3x3.fill    -> app.media.ic_dialpad_grid_3x3 (the in-call dialpad; an SVG of nine
 *                              dots, drawn by CallControlIcon for SHOW_DIALPAD)
 *   pip.enter               -> sys.symbol.rectangle_on_rectangle
 *
 * DAEMON GAP: every intent here is jami-daemon work. Each control keeps its place and the
 * screen reports the ceiling; nothing fakes a call.
 */

import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (CallControlsView.swift:20-110) ─────────────────── */
/**
 * HarmonyOS symbol glyphs fill less of their em box than SF Symbols: at the same point size the
 * speaker, mic and hang-up glyphs measured ~0.74x the iPhone's (TC-CALL-012/188 captures), so
 * the glyph is drawn at `metrics.icon` times this.
 */
const SYMBOL_SCALE: number = 1.35;
/** Swift `.foregroundColor(Color(white: 0.09))` on an ACTIVE control. */
const CONTROL_ACTIVE_FG: string = '#FF171717';
/** Swift `.white.opacity(0.92)` behind an ACTIVE control. */
const CONTROL_ACTIVE_BG: string = '#EBFFFFFF';
/** Swift `.white.opacity(0.46)` on a DISABLED control. */
const CONTROL_DISABLED_FG: string = '#75FFFFFF';
/** Swift `.red` behind the destructive (hang-up) control — the iOS system red. */
const CONTROL_DESTRUCTIVE_BG: string = '#FF3B30';
/**
 * Swift `.onVideoGlass(Circle(), tint: .jamiOnVideoGlass)` — VisualEffect(.systemMaterialDark)
 * under the 28% black tint. Solved off the iPhone capture: the disc reads rgb(25,26,26) over
 * the rgb(10,12,15) backdrop; the backdrop blur stands in for the material over video.
 */
export const ON_VIDEO_GLASS_FILL: string = '#E61B1C1B';
/** The same glass under Swift `jamiOnVideoGlass.opacity(0.75)` on a DISABLED control: rgb(27,28,28). */
const ON_VIDEO_GLASS_DISABLED_FILL: string = '#E61D1E1D';
export const ON_VIDEO_GLASS_BLUR: number = 20;

/**
 * Swift `hand.raised` / `hand.raised.fill`. The symbol table's only bare hand is the spread,
 * tilted `hand_raised_fingers_spread`; these are the upright palm of the system symbols
 * `hand_raised_hexagon` (outline) and `hand_raised_filled_hexagon` (fill) at Medium weight,
 * without the hexagon, on a 531 x 607 grid (y down).
 */
const HAND_RAISED: string = 'M222 46Q222 46 221 47Q220 47 220 48Q218 49 210 49Q178 52 157 75Q136 99 136 131' +
  'V305Q118 293 99 290Q80 286 62 292Q35 300 18 322Q0 344 0 373Q0 401 23 426L172 569Q189 586 212 596' +
  'Q236 607 261 607H402Q437 607 467 589Q496 571 513 541Q530 511 530 476V158Q529 137 519 121Q508 104 491 94' +
  'Q474 83 454 83Q448 53 425 34Q403 15 372 15Q362 16 352 18L349 19Q347 18 345 18Q323 0 295 0H289' +
  'Q267 2 250 14Q232 26 222 46ZM317 82V273Q317 279 321 284Q325 289 332 289Q338 289 342 285Q346 281 348 275' +
  'V101Q348 91 355 84Q362 76 371 76Q380 76 385 82Q391 88 393 97V273Q393 280 398 284Q403 289 410 289' +
  'Q415 289 419 285Q423 281 424 275V166Q424 156 431 149Q437 143 448 143Q456 143 462 148Q468 154 470 162' +
  'V473Q470 500 451 521Q432 542 406 545H261Q249 545 238 541Q227 536 218 528L70 386Q60 378 63 366' +
  'Q66 353 77 346Q87 339 98 346L175 396Q182 401 187 399Q193 397 195 390V134Q195 124 202 117Q208 109 217 109' +
  'Q226 109 233 115Q239 121 240 130V273Q241 280 245 284Q250 289 255 289Q261 289 266 285Q270 281 271 275' +
  'V86Q272 75 278 69Q284 63 294 63Q303 63 309 68Q315 73 317 82Z';
const HAND_RAISED_FILL: string = 'M455 153V283Q455 290 451 294Q447 299 440 299Q433 299 429 294Q425 290 425 283' +
  'V88Q425 75 416 65Q407 55 395 55Q382 55 373 64Q364 74 364 88V283Q364 290 360 294Q356 299 349 299' +
  'Q342 299 338 294Q334 290 334 283V55Q334 42 325 32Q316 23 303 23Q291 23 282 32Q273 42 273 55V283' +
  'Q273 290 269 294Q265 299 258 299Q251 299 247 294Q243 290 243 283V120Q243 107 234 97Q225 88 212 88' +
  'Q199 88 190 97Q181 107 181 120V409Q181 423 173 426Q167 430 157 425L64 370Q56 365 44 363Q31 362 22 372' +
  'Q4 392 23 415L201 580Q226 607 259 607H425Q463 607 490 578Q516 549 516 509V153Q516 139 508 129' +
  'Q499 120 486 120Q473 120 464 129Q455 139 455 153Z';
const HAND_GRID_HEIGHT: number = 607;
/** The outline's right edge on the 531-wide grid: the mirror axis is x = 530 / 2. */
const HAND_GRID_MAX_X: number = 530;
/** The palm's width over its height. */
export const HAND_WIDTH_RATIO: number = 531 / HAND_GRID_HEIGHT;
/** The iPhone capture's hand.raised: 22.5 pt tall on the 54 pt disc. */
const HAND_HEIGHT_RATIO: number = 22.5 / 54;
/** The palm's height over the font size it stands for: 22.5 pt at the disc's 0.38 x 54 pt glyph. */
export const HAND_FONT_SCALE: number = 22.5 / (54 * 0.38);

/**
 * Swift `hand.raised` / `hand.raised.fill` as Path commands for a palm `height` vp tall, scaled
 * to px, the unit a Path draws in. Every raised-hand glyph uses it (T-1596).
 */
export function raisedHandCommands(ui: UIContext, height: number, filled: boolean): string {
  const scale: number = ui.vp2px(height) / HAND_GRID_HEIGHT;
  // SF `hand.raised` has its thumb on the right (iPhone 11 capture, T-1596 review); the hexagon
  // symbols' palm has it on the left, so every x is mirrored on the grid. The paths use only
  // absolute M/L/Q/H/V/Z: H takes an x, V a y, the others x,y pairs.
  let command: string = '';
  let index: number = 0;
  return (filled ? HAND_RAISED_FILL : HAND_RAISED)
    .replace(/[A-Z]|\d+(\.\d+)?/g, (token: string): string => {
      if (/[A-Z]/.test(token)) {
        command = token;
        index = 0;
        return token;
      }
      const isX: boolean = command === 'H' || (command !== 'V' && index % 2 === 0);
      index++;
      return `${(isX ? HAND_GRID_MAX_X - Number(token) : Number(token)) * scale}`;
    });
}

/**
 * Swift `struct BarMetrics` — the bar sizes itself from the width it is given: buttons between
 * 46 and 54, gaps between 7 and 12, the glyph 0.38 of the button.
 */
export class BarMetrics {
  static readonly COMPACT_SLOT_COUNT: number = 5;
  static readonly MINIMUM_BUTTON: number = 46;
  static readonly MAXIMUM_BUTTON: number = 54;
  static readonly MINIMUM_GAP: number = 7;
  static readonly MAXIMUM_GAP: number = 12;
  static readonly ICON_RATIO: number = 0.38;

  button: number = BarMetrics.MINIMUM_BUTTON;
  icon: number = Math.round(BarMetrics.MINIMUM_BUTTON * BarMetrics.ICON_RATIO);
  gap: number = BarMetrics.MINIMUM_GAP;
  horizontalPadding: number =
    (BarMetrics.MINIMUM_BUTTON - Math.round(BarMetrics.MINIMUM_BUTTON * BarMetrics.ICON_RATIO)) / 2;

  /** Swift `init(availableWidth:slots:)`. */
  constructor(availableWidth: number, slotCount: number = BarMetrics.COMPACT_SLOT_COUNT) {
    if (availableWidth <= 0) {
      return;
    }
    const slots: number = Math.max(1, slotCount);
    const interButtonSlots: number = Math.max(0, slots - 1);
    const fittingButton: number = (availableWidth - interButtonSlots * BarMetrics.MINIMUM_GAP) /
      (slots + 1 - BarMetrics.ICON_RATIO);
    const preferred: number = Math.max(BarMetrics.MINIMUM_BUTTON,
      Math.min(BarMetrics.MAXIMUM_BUTTON, fittingButton));
    this.button = Math.min(preferred, availableWidth / slots);
    this.icon = Math.round(this.button * BarMetrics.ICON_RATIO);
    this.horizontalPadding = Math.min((this.button - this.icon) / 2,
      Math.max(0, (availableWidth - slots * this.button) / 2));
    this.gap = interButtonSlots > 0 ? Math.min(BarMetrics.MAXIMUM_GAP,
      Math.max(0, (availableWidth - slots * this.button - 2 * this.horizontalPadding) / interButtonSlots))
      : 0;
  }

  /** The glyph's point size, SF Symbol-equivalent. */
  get glyphSize(): number {
    return this.icon * SYMBOL_SCALE;
  }
}

/** Swift `enum CallControlIntent` (CallControlsLayout.swift:21). The id suffix is this name. */
export enum CallControlIntent {
  TOGGLE_MIC = 'toggleMic',
  TOGGLE_CAMERA = 'toggleCamera',
  TOGGLE_AUDIO_OUTPUT = 'toggleAudioOutput',
  HANG_UP = 'hangUp',
  FLIP_CAMERA = 'flipCamera',
  TOGGLE_HOLD = 'toggleHold',
  START_PICTURE_IN_PICTURE = 'startPictureInPicture',
  SHOW_DIALPAD = 'showDialpad',
  TOGGLE_RAISE_HAND = 'toggleRaiseHand'
}

/** Swift `ControlAction.Style`. */
export enum ControlActionStyle {
  NORMAL = 'normal',
  ACTIVE = 'active',
  DESTRUCTIVE = 'destructive'
}

/** Swift `struct ControlAction`. */
export class ControlAction {
  intent: CallControlIntent;
  icon: Resource;
  accessibilityLabel: Resource;
  style: ControlActionStyle;
  isEnabled: boolean;

  constructor(intent: CallControlIntent, icon: Resource, accessibilityLabel: Resource,
    style: ControlActionStyle = ControlActionStyle.NORMAL, isEnabled: boolean = true) {
    this.intent = intent;
    this.icon = icon;
    this.accessibilityLabel = accessibilityLabel;
    this.style = style;
    this.isEnabled = isEnabled;
  }

  /** Swift `"call_control_\(action.intent)"` / `"call_top_action_\(action.intent)"`. */
  slug(prefix: string): string {
    return `${prefix}${this.intent}`;
  }
}

/** Swift `CallControlIcon` — the glyph, its enabled state and its style. */
@Component
export struct CallControlIcon {
  @Prop action: ControlAction = new ControlAction(CallControlIntent.HANG_UP,
    $r('sys.symbol.phone_down_fill'), $r('app.string.accessibility_calls_default_end_call'));
  /** Swift `metrics.button` / `metrics.icon`. */
  @Prop button: number = BarMetrics.MINIMUM_BUTTON;
  @Prop glyphSize: number = new BarMetrics(0).glyphSize;

  /** Swift `CallControlIcon.foreground`. */
  private glyphColor(): ResourceColor {
    if (!this.action.isEnabled) {
      return CONTROL_DISABLED_FG;
    }
    return this.action.style === ControlActionStyle.ACTIVE ? CONTROL_ACTIVE_FG : Color.White;
  }

  /** Swift `CallControlIcon.background` — `.onVideoGlass(Circle(), tint:)`. */
  private glassTint(): ResourceColor {
    if (!this.action.isEnabled) {
      return ON_VIDEO_GLASS_DISABLED_FILL;
    }
    if (this.action.style === ControlActionStyle.DESTRUCTIVE) {
      return CONTROL_DESTRUCTIVE_BG;
    }
    if (this.action.style === ControlActionStyle.ACTIVE) {
      return CONTROL_ACTIVE_BG;
    }
    return ON_VIDEO_GLASS_FILL;
  }

  build() {
    // The circle is a Stack: a SymbolGlyph framed larger than its glyph draws it at the top
    // left instead of centring it.
    Stack() {
      if (this.action.intent === CallControlIntent.SHOW_DIALPAD) {
        // Swift `circle.grid.3x3.fill`: this SDK has no 3x3 grid symbol, so a bundled SVG of nine
        // dots, framed at the symbols' glyph size and tinted like them. The plan's 2x2 symbol for
        // this intent is not drawn.
        Image($r('app.media.ic_dialpad_grid_3x3'))
          .width(this.glyphSize)
          .height(this.glyphSize)
          .objectFit(ImageFit.Contain)
          .fillColor(this.glyphColor())
      } else if (this.action.intent === CallControlIntent.TOGGLE_RAISE_HAND) {
        // Swift `isRaised ? "hand.raised.fill" : "hand.raised"`.
        Path()
          .width(this.button * HAND_HEIGHT_RATIO * HAND_WIDTH_RATIO)
          .height(this.button * HAND_HEIGHT_RATIO)
          .commands(raisedHandCommands(this.getUIContext(), this.button * HAND_HEIGHT_RATIO,
            this.action.style === ControlActionStyle.ACTIVE))
          .fill(this.glyphColor())
      } else {
        SymbolGlyph(this.action.icon)
          // Swift `.font(.system(size: metrics.icon, weight: .medium))`.
          .fontSize(this.glyphSize)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.glyphColor()])
      }
    }
    .width(this.button)
    .height(this.button)
    .backgroundColor(this.glassTint())
    // Glass only. An opaque iOS tint hides the material, and the blur here also blurs this disc's
    // own fill into its dark surroundings: white and red discs got grey/dark rims (T-1120).
    .backdropBlur(this.action.isEnabled && this.action.style !== ControlActionStyle.NORMAL
      ? 0 : ON_VIDEO_GLASS_BLUR)
    .borderRadius(this.button / 2)
    .clip(true)
  }
}

/** Swift `private struct ControlButton`. */
@Component
export struct ControlButton {
  @Prop action: ControlAction = new ControlAction(CallControlIntent.HANG_UP,
    $r('sys.symbol.phone_down_fill'), $r('app.string.accessibility_calls_default_end_call'));
  /** Swift `"call_control_"` for the bottom bar, `"call_top_action_"` for the top one. */
  slugPrefix: string = 'call_control_';
  /** Swift `metrics.button` / `metrics.icon`. */
  @Prop button: number = BarMetrics.MINIMUM_BUTTON;
  @Prop glyphSize: number = new BarMetrics(0).glyphSize;
  /** Swift `model.perform(action.intent)`. */
  onPerform?: (intent: CallControlIntent) => void;

  private perform(): void {
    const handler: ((intent: CallControlIntent) => void) | undefined = this.onPerform;
    if (handler !== undefined) {
      handler(this.action.intent);
    }
  }

  build() {
    // The tap target wraps the glyph, so the identifier and the guard sit on a container
    // rather than on a custom component's own attributes.
    Row() {
      CallControlIcon({ action: this.action, button: this.button, glyphSize: this.glyphSize })
    }
    .width(this.button)
    .height(this.button)
    .justifyContent(FlexAlign.Center)
    .id(this.action.slug(this.slugPrefix))
    .accessibilityText(this.action.accessibilityLabel)
    // Swift `.disabled(!action.isEnabled)` — the plan's own guard, not an invented one.
    .enabled(this.action.isEnabled)
    .onClick(() => {
      this.perform();
    })
  }
}

interface ControlBarParam {
  actions: ControlAction[];
}

@Component
export struct CallControlsView {
  /** Swift `plan.primary` — [audioOutput, mic, camera, flipCamera, hangUp]. */
  @Prop primary: ControlAction[] = [];
  /** Swift `plan.supplemental` — [hold, dialpad], SIP accounts only. */
  @Prop supplemental: ControlAction[] = [];
  /** Swift `model.perform(_:)`. */
  onPerform?: (intent: CallControlIntent) => void;
  /** Swift `availableWidth` — the chrome's width, measured. */
  @State private availableWidth: number = 0;

  /** Swift `BarMetrics(availableWidth:plan:)`. */
  private metrics(): BarMetrics {
    return new BarMetrics(this.availableWidth, this.primary.length);
  }

  // By-reference parameter: a by-value @Builder argument never re-renders when the plan changes.
  @Builder
  private controlBar(bar: ControlBarParam) {
    // Swift `HStack(spacing: metrics.gap).padding(.horizontal, metrics.horizontalPadding)`.
    Row({ space: this.metrics().gap }) {
      // The key carries everything the plan can change: a reused item never re-reads `action`,
      // so a glyph or enabled change left out of the key never reached the screen.
      ForEach(bar.actions, (action: ControlAction) => {
        ControlButton({
          action: action,
          slugPrefix: 'call_control_',
          button: this.metrics().button,
          glyphSize: this.metrics().glyphSize,
          onPerform: this.onPerform
        })
      }, (action: ControlAction) =>
        `${action.intent}_${action.style}_${action.isEnabled}_${action.icon.id}_${this.metrics().button}`)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(this.metrics().horizontalPadding),
      end: LengthMetrics.vp(this.metrics().horizontalPadding)
    })
  }

  build() {
    // Swift `VStack(spacing: metrics.gap)` over the video, full width.
    Column({ space: this.metrics().gap }) {
      // Swift `if !plan.supplemental.isEmpty` — the second bar exists only on a SIP account.
      if (this.supplemental.length > 0) {
        this.controlBar({ actions: this.supplemental })
      }
      this.controlBar({ actions: this.primary })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.availableWidth = Number(newArea.width);
    })
  }
}
