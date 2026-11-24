/*
 * Ported from Ring/Ring/Models/CollaborativeDocument.swift:77-93 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One checkpoint in a collaborative document's history: a commit gathering a batch of updates.
 * Every value comes from the daemon's version map.
 */

export class CollaborativeVersion {
  readonly commitId: string;
  readonly author: string;
  readonly device: string;
  readonly timestamp: number;
  readonly deltas: number;

  constructor(commitId: string, author: string, device: string, timestamp: number,
              deltas: number) {
    this.commitId = commitId;
    this.author = author;
    this.device = device;
    this.timestamp = timestamp;
    this.deltas = deltas;
  }

  /** Swift `init?(fromNative map:)` - null without an `id`. */
  static fromNative(map: Map<string, string>): CollaborativeVersion | null {
    const commitId: string | undefined = map.get('id');
    if (commitId === undefined || commitId.length === 0) {
      return null;
    }

    const rawAuthor: string | undefined = map.get('author');
    const author: string = rawAuthor === undefined ? '' : rawAuthor;

    const rawDevice: string | undefined = map.get('device');
    const device: string = rawDevice === undefined ? '' : rawDevice;

    const rawTimestamp: string | undefined = map.get('timestamp');
    const parsedTimestamp: number =
      rawTimestamp === undefined ? 0 : Number.parseInt(rawTimestamp, 10);
    const timestamp: number = Number.isNaN(parsedTimestamp) ? 0 : parsedTimestamp;

    const rawDeltas: string | undefined = map.get('deltas');
    const parsedDeltas: number = rawDeltas === undefined ? 0 : Number.parseInt(rawDeltas, 10);
    const deltas: number = Number.isNaN(parsedDeltas) ? 0 : parsedDeltas;

    return new CollaborativeVersion(commitId, author, device, timestamp, deltas);
  }

  /** Swift `Equatable`. */
  equals(other: CollaborativeVersion): boolean {
    return this.commitId === other.commitId && this.author === other.author
      && this.device === other.device && this.timestamp === other.timestamp
      && this.deltas === other.deltas;
  }
}
