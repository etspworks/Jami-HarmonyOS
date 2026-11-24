/*
 * Ported from Ring/Ring/Models/ConversationModel.swift:80-103 (ConversationPreferences and
 * ConversationPreferenceAttributes) - GPL-3.0, Savoir-faire Linux Inc.
 *
 * The preference values themselves are stored by the jami daemon
 * (`getConversationPreferences`); this module models and parses them.
 */

/** Swift `enum ConversationPreferenceAttributes: String`. */
export enum ConversationPreferenceAttribute {
  COLOR = 'color',
  IGNORE_NOTIFICATIONS = 'ignoreNotifications'
}

/** Swift `UIColor.defaultSwarmColorHex` (Ring/Ring/Extensions/UIColor+Ring.swift:140). */
export const DEFAULT_SWARM_COLOR_HEX: string = '#00BCD4';

/** Swift `UIColor.defaultSwarmColor` as an opaque ARGB value. */
export const DEFAULT_SWARM_COLOR_ARGB: number = 0xFF00BCD4;

/**
 * Swift `(string as NSString).boolValue`: leading whitespace and sign are skipped, "Y"/"y"/"T"/"t"
 * and any non-zero leading integer are true, everything else false.
 */
function nsStringBoolValue(value: string): boolean {
  const trimmed: string = value.trim();
  let index: number = 0;
  if (index < trimmed.length && (trimmed.charAt(index) === '+' || trimmed.charAt(index) === '-')) {
    index += 1;
  }
  if (index >= trimmed.length) {
    return false;
  }
  const first: string = trimmed.charAt(index).toLowerCase();
  if (first === 'y' || first === 't') {
    return true;
  }
  let digits: string = '';
  while (index < trimmed.length && trimmed.charAt(index) >= '0' && trimmed.charAt(index) <= '9') {
    digits += trimmed.charAt(index);
    index += 1;
  }
  if (digits.length === 0) {
    return false;
  }
  return parseInt(digits, 10) !== 0;
}

/**
 * Swift `UIColor(hexString:)` (Ring/Ring/Extensions/UIColor+Ring.swift:52-68): an optional '#',
 * then a hex scan whose low 24 bits are RGB at full alpha. A string the scanner cannot read
 * scanned as 0, i.e. opaque black - kept here rather than guessing a nicer fallback.
 */
export function argbFromHexString(hexString: string): number {
  const trimmed: string = hexString.trim();
  const body: string = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
  let digits: string = '';
  for (let i: number = 0; i < body.length; i++) {
    const c: string = body.charAt(i).toLowerCase();
    const isHex: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!isHex) {
      break;
    }
    digits += c;
  }
  const scanned: number = digits.length === 0 ? 0 : parseInt(digits, 16);
  const rgb: number = scanned & 0x00FFFFFF;
  return 0xFF000000 + rgb;
}

export class ConversationPreferences {
  color: string = DEFAULT_SWARM_COLOR_HEX;
  ignoreNotifications: boolean = false;

  /** Swift `mutating func update(info:)`. */
  update(info: Map<string, string>): void {
    const color: string | undefined = info.get(ConversationPreferenceAttribute.COLOR);
    if (color !== undefined) {
      this.color = color;
    }
    const ignore: string | undefined = info.get(ConversationPreferenceAttribute.IGNORE_NOTIFICATIONS);
    if (ignore !== undefined) {
      this.ignoreNotifications = nsStringBoolValue(ignore);
    }
  }

  /**
   * Swift `func getColor() -> UIColor`. ArkUI takes a colour as an ARGB number, so that is what
   * this returns; `color` stays the hex string the daemon stores.
   */
  getColor(): number {
    return argbFromHexString(this.color);
  }
}
