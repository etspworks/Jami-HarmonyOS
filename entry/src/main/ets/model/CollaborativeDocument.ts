/*
 * Ported from Ring/Ring/Models/CollaborativeDocument.swift:21-75 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * A collaborative document announced in a conversation. The daemon only ever describes a
 * document; its content lives in a Y-CRDT replica the client owns.
 */

export class CollaborativeDocument {
  /** Swift `static let mimeRichText` - the media type every editor-backed document uses. */
  static readonly MIME_RICH_TEXT: string = 'text/html';
  /** Swift `static let mimePlainText` - the daemon's fallback when no media type is given. */
  static readonly MIME_PLAIN_TEXT: string = 'text/plain';

  readonly id: string;
  readonly name: string;
  readonly mimeType: string;
  readonly author: string | null;
  readonly timestamp: number;
  /**
   * Swift `let storedLocally` - whether this device is holding the document. False for one
   * this device removed from itself: it stays announced in the conversation, and opening it
   * fetches it back.
   */
  readonly storedLocally: boolean;

  constructor(id: string, name: string, mimeType: string, author: string | null,
              timestamp: number, storedLocally: boolean) {
    this.id = id;
    this.name = name;
    this.mimeType = mimeType;
    this.author = author;
    this.timestamp = timestamp;
    this.storedLocally = storedLocally;
  }

  /** Swift `var isRichText`. */
  get isRichText(): boolean {
    return this.mimeType === CollaborativeDocument.MIME_RICH_TEXT;
  }

  /**
   * Swift `init?(fromNative map:)` - builds a document from a COLLAB_DOC commit map, as
   * returned by `documentsForAccount`. The document's own identifier is stored under `id`;
   * the announcing commit has a separate `announcement` identifier. Null without an `id`.
   */
  static fromNative(map: Map<string, string>): CollaborativeDocument | null {
    const id: string | undefined = map.get('id');
    if (id === undefined || id.length === 0) {
      return null;
    }

    const rawName: string | undefined = map.get('displayName');
    const name: string = rawName === undefined ? '' : rawName;

    const rawMime: string | undefined = map.get('mimeType');
    const mimeType: string = (rawMime === undefined || rawMime.length === 0)
      ? CollaborativeDocument.MIME_PLAIN_TEXT
      : rawMime;

    const rawAuthor: string | undefined = map.get('author');
    const author: string | null = (rawAuthor === undefined || rawAuthor.length === 0)
      ? null
      : rawAuthor;

    const rawTimestamp: string | undefined = map.get('timestamp');
    const parsedTimestamp: number =
      rawTimestamp === undefined ? 0 : Number.parseInt(rawTimestamp, 10);
    const timestamp: number = Number.isNaN(parsedTimestamp) ? 0 : parsedTimestamp;

    // Absent from a daemon that predates local removal, and from every document the daemon
    // does hold: only a removal writes it, and it writes "false".
    const storedLocally: boolean = map.get('storedLocally') !== 'false';

    return new CollaborativeDocument(id, name, mimeType, author, timestamp, storedLocally);
  }

  /** Swift `Equatable`. */
  equals(other: CollaborativeDocument): boolean {
    return this.id === other.id && this.name === other.name && this.mimeType === other.mimeType
      && this.author === other.author && this.timestamp === other.timestamp
      && this.storedLocally === other.storedLocally;
  }
}
