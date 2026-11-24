/*
 * comp_dialpad_key_button — ported from Ring/Ring/Dialpad/DialpadView.swift
 * `private struct DialpadKeyButton` (line 158) and `DialpadKeyModel` (line 148):
 *
 *   Button(action: onTap) {
 *     VStack(spacing: 1) { Text(key.value)
 *                          if !key.letters.isEmpty { Text(key.letters).tracking(1.5) } }
 *   }
 *   .accessibilityIdentifier("dialpad_key_itemroot")     // SHARED across the 12 keys
 *   .accessibilityLabel(key.value == displayStar ? "*" : key.value)
 *   if let onLongPress { .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress) }
 *
 * The long press is the SECONDARY value — only "0" has one ("+"), and DialpadView suppresses
 * it during a call, where "+" is not a valid DTMF tone.
 */

import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (DialpadView.swift:21-25, 188-230) ──────────────── */
/** Swift `Layout.largeButton = 72` — capture S0095 keys are `[62,301][134,373]`. */
const KEY_SIZE: number = 72;
/** Swift `Text(key.value).font(.system(size: 32, weight: .regular))`. */
const KEY_DIGIT_SIZE: number = 32;
/** Swift `Text(key.letters).font(.system(size: 10, weight: .semibold)).tracking(1.5)`. */
const KEY_LETTERS_SIZE: number = 10;
const KEY_LETTERS_TRACKING: number = 1.5;
/** Swift `VStack(spacing: 1)`. */
const KEY_STACK_GAP: number = 1;
/**
 * Swift `DialpadKeyStyle`: `Circle().fill(Color(.secondarySystemFill))`. iOS resolves that to
 * #78788028 over white, which is the light grey disc the capture shows.
 */
const KEY_FILL: string = '#28787880';
/** UIKit dims a `Button`'s content while it is held; the dialpad key is the one control on
 *  this screen with no other press feedback at all. */
const KEY_PRESSED_OPACITY: number = 0.4;

/** Swift `private struct DialpadKeyModel` — the digit, its letters and its long-press value. */
export class DialpadKeyModel {
  value: string;
  letters: string;
  /** Swift `longPressValue: String?` — empty means the key has no secondary value. */
  longPressValue: string;

  constructor(value: string, letters: string, longPressValue: string = '') {
    this.value = value;
    this.letters = letters;
    this.longPressValue = longPressValue;
  }
}

/**
 * Swift `DialpadView.keys` — the letters and the "+" long press live in the VIEW there, not in
 * Constants, so they live with the key component here. The digit ORDER comes from
 * `JamiConstants.DIALPAD_KEYS` (the migrated Constants table), which is what the screen's
 * bindingContract binds the grid to.
 */
const KEY_LETTERS: Map<string, string> = new Map<string, string>([
  ['1', ''], ['2', 'ABC'], ['3', 'DEF'],
  ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'],
  ['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ'],
  ['*', ''], ['0', '+'], ['#', '']
]);

/** Swift `DialpadViewModel.displayStar`'s key: "0" is the one key with a long-press value. */
const KEY_LONG_PRESS: Map<string, string> = new Map<string, string>([['0', '+']]);

/** Builds the 12 key models from the migrated digit table. */
export function dialpadKeys(rows: string[][]): DialpadKeyModel[] {
  const keys: DialpadKeyModel[] = [];
  for (const row of rows) {
    for (const digit of row) {
      const letters: string | undefined = KEY_LETTERS.get(digit);
      const longPress: string | undefined = KEY_LONG_PRESS.get(digit);
      keys.push(new DialpadKeyModel(digit, letters === undefined ? '' : letters,
        longPress === undefined ? '' : longPress));
    }
  }
  return keys;
}

@Component
export struct DialpadKeyButton {
  model: DialpadKeyModel = new DialpadKeyModel('', '');
  /** Swift `inCallDialpad` — suppresses the "+" long press during a call. */
  inCallDialpad: boolean = false;
  /** Swift `onTap` — viewModel.numberPressed(key.value). */
  onTap?: (value: string) => void;
  /** Swift `onLongPress` — viewModel.numberPressed(key.longPressValue). */
  onLongPress?: (value: string) => void;

  /** S6 — pressed feedback: a plain Column has none, where the source's Button dims. */
  @State private isPressed: boolean = false;

  private press(value: string, handler?: (value: string) => void): void {
    if (handler !== undefined) {
      handler(value);
    }
  }

  build() {
    // S5 — capture S0095/S0096: a 72vp `secondarySystemFill` disc holding a 32pt digit over a
    // 10pt letter-spaced grey caption.
    Column({ space: KEY_STACK_GAP }) {
      Text(this.model.value)
        .fontSize(KEY_DIGIT_SIZE)
        .fontColor($r('app.color.label'))
      // Swift `if !key.letters.isEmpty`.
      if (this.model.letters.length > 0) {
        Text(this.model.letters)
          .fontSize(KEY_LETTERS_SIZE)
          .fontWeight(FontWeight.Medium)
          .letterSpacing(KEY_LETTERS_TRACKING)
          .fontColor($r('app.color.secondary_label'))
      }
    }
    .width(KEY_SIZE)
    .height(KEY_SIZE)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(KEY_FILL)
    .borderRadius(KEY_SIZE / 2)
    .clip(true)
    // Swift: a SwiftUI `Button` dims its label while held. Driven off the raw touch rather
    // than `.stateStyles`, whose style bundles are typed `any` in the SDK.
    .opacity(this.isPressed ? KEY_PRESSED_OPACITY : 1)
    .onTouch((event: TouchEvent) => {
      this.isPressed = event.type === TouchType.Down || event.type === TouchType.Move;
    })
    // Rule 12's list-row exception: the 12 keys deliberately SHARE this id, so the replay
    // resolves a key by index.
    .id('dialpad_key_itemroot')
    .accessibilityText(this.model.value)
    .onClick(() => {
      this.press(this.model.value, this.onTap);
    })
    .gesture(LongPressGesture({ duration: 400 }).onAction(() => {
      // Swift: no secondary value, or an in-call dialpad -> the long press does nothing.
      if (this.model.longPressValue.length > 0 && !this.inCallDialpad) {
        this.press(this.model.longPressValue, this.onLongPress);
      }
    }))
  }
}
