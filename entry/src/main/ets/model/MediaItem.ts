/*
 * Ported from Ring/Ring/Models/Calls/MediaItem.swift (GPL-3.0, Savoir-faire Linux Inc.),
 * together with the media half of Ring/Ring/Models/Calls/LibJamiCallConstants.swift
 * (`MediaKey`, `MediaType`, the libjami boolean encoding) - that file declares no type of
 * its own here, every other constant in it belongs to the call models that use it.
 *
 * One media descriptor of a call's media list. libjami identifies streams by `label`;
 * `muted`/`enabled` reflect libjami-confirmed state, not local intent. The media themselves
 * live in the jami daemon (a prebuilt binary, no HarmonyOS build) - this file only parses
 * and re-serializes the string dictionaries the daemon exchanges.
 */

/** Swift `MediaKey` - keys of one media-attribute dictionary. */
export enum MediaKey {
  MEDIA_TYPE = 'MEDIA_TYPE',
  ENABLED = 'ENABLED',
  MUTED = 'MUTED',
  SOURCE = 'SOURCE',
  LABEL = 'LABEL',
  ON_HOLD = 'HOLD'
}

/** Swift `MediaType` - values of `MediaKey.MEDIA_TYPE`. */
export enum MediaType {
  AUDIO = 'MEDIA_TYPE_AUDIO',
  VIDEO = 'MEDIA_TYPE_VIDEO'
}

/** Swift `MediaType.init?(rawValue:)`. */
export function mediaTypeFromRaw(raw: string): MediaType | null {
  if (raw === 'MEDIA_TYPE_AUDIO') {
    return MediaType.AUDIO;
  }
  if (raw === 'MEDIA_TYPE_VIDEO') {
    return MediaType.VIDEO;
  }
  return null;
}

/**
 * Swift `Bool.init?(libJamiString:)` - libjami encodes booleans as "true"/"false", "1"/"0"
 * or "yes"/"no". Returns null for anything else, so the caller keeps its own default.
 */
export function parseLibJamiBool(raw: string | undefined): boolean | null {
  if (raw === undefined) {
    return null;
  }
  const value: string = raw.toLowerCase();
  if (value === 'true' || value === '1' || value === 'yes') {
    return true;
  }
  if (value === 'false' || value === '0' || value === 'no') {
    return false;
  }
  return null;
}

/** Swift `Bool.libJamiString`. */
export function libJamiBoolString(value: boolean): string {
  return value ? 'true' : 'false';
}

/** Which of Swift's three `MediaLabel` cases a label is. */
export enum MediaLabelKind {
  AUDIO = 'audio',
  VIDEO = 'video',
  CUSTOM = 'custom'
}

/**
 * Swift `MediaLabel` - a media stream label as used in libjami media lists ("audio_0",
 * "video_0", ...). Labels identify a stream across renegotiations. Swift's enum carries the
 * index/raw string in its cases; ArkTS enums have no associated values, so this is a value
 * class with the same three constructors.
 */
export class MediaLabel {
  readonly kind: MediaLabelKind;
  /** Stream index for `AUDIO`/`VIDEO`; 0 for `CUSTOM`. */
  readonly index: number;
  /** The raw label for `CUSTOM`; empty for `AUDIO`/`VIDEO`. */
  readonly raw: string;

  private constructor(kind: MediaLabelKind, index: number, raw: string) {
    this.kind = kind;
    this.index = index;
    this.raw = raw;
  }

  /** Swift `.audio(Int)`. */
  static audio(index: number): MediaLabel {
    return new MediaLabel(MediaLabelKind.AUDIO, index, '');
  }

  /** Swift `.video(Int)`. */
  static video(index: number): MediaLabel {
    return new MediaLabel(MediaLabelKind.VIDEO, index, '');
  }

  /** Swift `.custom(String)`. */
  static custom(raw: string): MediaLabel {
    return new MediaLabel(MediaLabelKind.CUSTOM, 0, raw);
  }

  /** Swift `static let defaultAudio = MediaLabel.audio(0)`. */
  static readonly DEFAULT_AUDIO: MediaLabel = new MediaLabel(MediaLabelKind.AUDIO, 0, '');

  /** Swift `static let defaultVideo = MediaLabel.video(0)`. */
  static readonly DEFAULT_VIDEO: MediaLabel = new MediaLabel(MediaLabelKind.VIDEO, 0, '');

  /**
   * Swift `init(_ raw: String)` - "<media>_<index>" when the two halves parse, the whole
   * string as a custom label otherwise. Splits on the FIRST underscore only, so
   * "screen_share_0" is custom rather than a mis-read index.
   */
  static fromRaw(raw: string): MediaLabel {
    const separator: number = raw.indexOf('_');
    if (separator >= 0) {
      const head: string = raw.substring(0, separator);
      const tail: string = raw.substring(separator + 1);
      const index: number = MediaLabel.parseIndex(tail);
      if (index >= 0) {
        if (head === 'audio') {
          return MediaLabel.audio(index);
        }
        if (head === 'video') {
          return MediaLabel.video(index);
        }
      }
    }
    return MediaLabel.custom(raw);
  }

  /** Swift `Int(parts[1])` - the whole string must be digits; -1 means "not an index". */
  private static parseIndex(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 0x30 || code > 0x39) {
        return -1;
      }
    }
    return Number.parseInt(text, 10);
  }

  /** Swift `var libJamiString: String`. */
  get libJamiString(): string {
    if (this.kind === MediaLabelKind.AUDIO) {
      return 'audio_' + this.index;
    }
    if (this.kind === MediaLabelKind.VIDEO) {
      return 'video_' + this.index;
    }
    return this.raw;
  }

  /** Swift `var isAudio: Bool`. */
  get isAudio(): boolean {
    return this.kind === MediaLabelKind.AUDIO;
  }

  /** Swift `var isVideo: Bool`. */
  get isVideo(): boolean {
    return this.kind === MediaLabelKind.VIDEO;
  }

  /** Swift `Hashable` conformance - the libjami string is the identity. */
  equals(other: MediaLabel): boolean {
    return this.libJamiString === other.libJamiString;
  }
}

/** Swift `struct MediaItem`. */
export class MediaItem {
  type: MediaType;
  enabled: boolean;
  muted: boolean;
  source: string;
  label: MediaLabel;
  onHold: boolean;

  /**
   * Swift's memberwise `MediaItem(type:enabled:muted:source:label:onHold:)` in declaration
   * order, except that `label` is hoisted next to `type`: it is the one field with no
   * default, and ArkTS has no argument labels to skip the defaulted ones with.
   */
  constructor(type: MediaType, label: MediaLabel, enabled: boolean = true,
              muted: boolean = false, source: string = '', onHold: boolean = false) {
    this.type = type;
    this.label = label;
    this.enabled = enabled;
    this.muted = muted;
    this.source = source;
    this.onHold = onHold;
  }

  /**
   * Swift `init?(_ dict: [String: String])` - one entry of a libjami media list. Null when
   * the dictionary carries no recognized media type; the daemon's own strings only, no
   * fabricated default.
   */
  static fromDictionary(dict: Map<string, string>): MediaItem | null {
    const rawType: string | undefined = dict.get(MediaKey.MEDIA_TYPE as string);
    if (rawType === undefined) {
      return null;
    }
    const type: MediaType | null = mediaTypeFromRaw(rawType);
    if (type === null) {
      return null;
    }
    const item: MediaItem = new MediaItem(type, MediaLabel.fromRaw(dict.get(MediaKey.LABEL as string) ?? ''));
    item.enabled = parseLibJamiBool(dict.get(MediaKey.ENABLED as string)) ?? false;
    item.muted = parseLibJamiBool(dict.get(MediaKey.MUTED as string)) ?? false;
    item.source = dict.get(MediaKey.SOURCE as string) ?? '';
    item.onHold = parseLibJamiBool(dict.get(MediaKey.ON_HOLD as string)) ?? false;
    return item;
  }

  /** Swift `func toDictionary() -> [String: String]`. */
  toDictionary(): Map<string, string> {
    const dict: Map<string, string> = new Map<string, string>();
    dict.set(MediaKey.MEDIA_TYPE as string, this.type as string);
    dict.set(MediaKey.ENABLED as string, libJamiBoolString(this.enabled));
    dict.set(MediaKey.MUTED as string, libJamiBoolString(this.muted));
    dict.set(MediaKey.SOURCE as string, this.source);
    dict.set(MediaKey.LABEL as string, this.label.libJamiString);
    dict.set(MediaKey.ON_HOLD as string, libJamiBoolString(this.onHold));
    return dict;
  }

  /** Swift `static func audio(muted:label:)`. */
  static audio(muted: boolean = false, label: MediaLabel = MediaLabel.DEFAULT_AUDIO): MediaItem {
    return new MediaItem(MediaType.AUDIO, label, true, muted);
  }

  /** Swift `static func video(muted:label:)`. */
  static video(muted: boolean = false, label: MediaLabel = MediaLabel.DEFAULT_VIDEO): MediaItem {
    return new MediaItem(MediaType.VIDEO, label, true, muted);
  }

  /** Swift `Hashable` conformance. */
  equals(other: MediaItem): boolean {
    return this.type === other.type && this.enabled === other.enabled
      && this.muted === other.muted && this.source === other.source
      && this.label.equals(other.label) && this.onHold === other.onHold;
  }
}

/*
 * Swift `extension Array where Element == MediaItem` - free functions here, ArkTS cannot
 * extend a built-in type.
 */

/** Swift `init(libJamiMediaList:)` - drops entries the daemon sent without a media type. */
export function mediaItemsFromLibJami(list: Array<Map<string, string>>): MediaItem[] {
  const items: MediaItem[] = [];
  for (const dict of list) {
    const item: MediaItem | null = MediaItem.fromDictionary(dict);
    if (item !== null) {
      items.push(item);
    }
  }
  return items;
}

/** Swift `func toDictionaries()`. */
export function mediaItemsToDictionaries(items: MediaItem[]): Array<Map<string, string>> {
  const dicts: Array<Map<string, string>> = [];
  for (const item of items) {
    dicts.push(item.toDictionary());
  }
  return dicts;
}

/** Swift `var isAudioMuted` - the default audio stream's mute state, false when absent. */
export function isAudioMuted(items: MediaItem[]): boolean {
  for (const item of items) {
    if (item.label.equals(MediaLabel.DEFAULT_AUDIO)) {
      return item.muted;
    }
  }
  return false;
}

/** Swift `var isVideoMuted` - muted, disabled, or no default video stream at all. */
export function isVideoMuted(items: MediaItem[]): boolean {
  for (const item of items) {
    if (item.label.equals(MediaLabel.DEFAULT_VIDEO)) {
      return item.muted || !item.enabled;
    }
  }
  return true;
}

/** Swift `var hasVideo` - a video stream that is negotiated AND sending. */
export function hasVideo(items: MediaItem[]): boolean {
  for (const item of items) {
    if (item.type === MediaType.VIDEO && item.enabled && !item.muted) {
      return true;
    }
  }
  return false;
}

/** Swift `var hasNegotiatedVideo` - negotiated, muted or not. */
export function hasNegotiatedVideo(items: MediaItem[]): boolean {
  for (const item of items) {
    if (item.type === MediaType.VIDEO && item.enabled) {
      return true;
    }
  }
  return false;
}
