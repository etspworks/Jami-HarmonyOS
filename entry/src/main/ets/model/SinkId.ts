/*
 * Ported from Ring/Ring/Models/Calls/SinkId.swift:25-58 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * A libjami video-sink identifier. libjami uses the bare call id for a 1:1 call's decoder and
 * "<baseId>_<media>_<index>" for per-participant conference streams. This type is the only
 * place that string is built or taken apart. Pure string handling - the sink itself lives in
 * the jami daemon.
 */

import { MediaLabel } from './MediaItem';

/** Swift's `(String, MediaLabel)` tuple return; ArkTS has no tuple destructuring. */
interface SinkIdParts {
  base: string;
  label: MediaLabel;
}

export class SinkId {
  readonly raw: string;

  /** Swift `init(raw:)`. */
  constructor(raw: string) {
    this.raw = raw;
  }

  /** Swift `init(baseId:label:)`. */
  static fromBaseId(baseId: string, label: MediaLabel): SinkId {
    return new SinkId(baseId + '_' + label.libJamiString);
  }

  /**
   * Swift `var baseId: String` - the call/participant part ("abc" in "abc_video_0"; the whole
   * string when no media suffix is recognized).
   */
  get baseId(): string {
    const parts: SinkIdParts | null = this.splitMediaSuffix();
    return parts === null ? this.raw : parts.base;
  }

  /** Swift `var mediaLabel: MediaLabel?`. */
  get mediaLabel(): MediaLabel | null {
    const parts: SinkIdParts | null = this.splitMediaSuffix();
    return parts === null ? null : parts.label;
  }

  /**
   * Swift `private func splitMediaSuffix()`. Splits "..._<media>_<index>" into (base, label);
   * null when the last two components don't form a valid media label.
   */
  private splitMediaSuffix(): SinkIdParts | null {
    const parts: string[] = this.raw.split('_');
    if (parts.length < 3) {
      return null;
    }
    const candidate: string = parts.slice(parts.length - 2).join('_');
    const label: MediaLabel = MediaLabel.fromRaw(candidate);
    if (label.libJamiString.length === 0 || (!label.isAudio && !label.isVideo)) {
      return null;
    }
    const result: SinkIdParts = {
      base: parts.slice(0, parts.length - 2).join('_'),
      label: label
    };
    return result;
  }

  /** Swift `Hashable` conformance - the raw string is the identity and the hash value. */
  equals(other: SinkId): boolean {
    return this.raw === other.raw;
  }

  hash(): string {
    return this.raw;
  }
}
