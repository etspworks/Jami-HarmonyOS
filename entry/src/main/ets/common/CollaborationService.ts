/*
 * Ported from Ring/Ring/Services/CollaborationService.swift:19-672 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Collaborative documents. The daemon half goes through libjami's collaborative API
 * (conversation_interface.h; napi_jami.cpp is the CollaborationAdapter.mm counterpart): the
 * Y-CRDT replica and the swarm history live in libjami, this service only relays bytes. The
 * local half - the "waiting to be read" registry, the open/closed bookkeeping and the event
 * fan-out every editor subscribes through - is ported literally.
 *
 * Two Swift fields have no counterpart: `daemonScheduler` / `deliveryScheduler` (ArkTS runs
 * this module and the napi callbacks on the one ETS thread) and `unreadLock` (the same reason).
 * The six adapter callbacks are public; JamiNative.route forwards the daemon's signals to them.
 *
 * RxSwift `Observable<T>` becomes "subscribe with an observer, get the unsubscribe closure",
 * the shape common/Observable.ts and common/CallService.ts already use.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { DisposeBag, PublishSubject } from './Observable';
import { jami, toMap } from './JamiNative';
import { CollaborativeDocument } from '../model/CollaborativeDocument';
import { CollaborativeVersion } from '../model/CollaborativeVersion';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CollaborationService';

/**
 * Swift `L10n.Collab.untitled`. The app carries the string as `collab_untitled`
 * ("Untitled document"), but a .ts module cannot call `getContext()` to resolve a resource,
 * so the name is exported for a UI layer to resolve and this literal is the fallback - the
 * same split `DaemonService.DAEMON_UNAVAILABLE_RESOURCE` uses.
 */
export const COLLAB_UNTITLED_RESOURCE: string = 'collab_untitled';
const COLLAB_UNTITLED_TEXT: string = 'Untitled document';

/** Swift `struct AwarenessUpdate` - a collaborator's cursor/selection for a document. */
export class AwarenessUpdate {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  readonly peerId: string;
  /** Swift `UInt64`; ArkTS has no UInt64, and the daemon's client ids fit a number. */
  readonly clientId: number;
  readonly state: string;

  constructor(accountId: string, conversationId: string, documentId: string, peerId: string,
              clientId: number, state: string) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.peerId = peerId;
    this.clientId = clientId;
    this.state = state;
  }
}

/** Swift `struct DocumentUpdate` - a content change, as the Y-CRDT update carrying it. */
export class DocumentUpdate {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  /** Swift `Data`. */
  readonly update: Uint8Array;

  constructor(accountId: string, conversationId: string, documentId: string,
              update: Uint8Array) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.update = update;
  }
}

/** Swift `enum CollaborativeDocumentChange` - what an update signal means. */
export enum CollaborativeDocumentChangeKind {
  /** Bytes to merge into an open editor's CRDT replica. */
  UPDATE = 'UPDATE',
  /** The document changed while no client here had it open; reopen it to fetch the content. */
  NOTIFICATION = 'NOTIFICATION'
}

/**
 * Swift's enum carried its payload in the `.update` case; ArkTS enums cannot, so the payload
 * becomes a field that is empty for `NOTIFICATION`.
 */
export class CollaborativeDocumentChange {
  readonly kind: CollaborativeDocumentChangeKind;
  readonly update: Uint8Array;

  constructor(kind: CollaborativeDocumentChangeKind, update: Uint8Array) {
    this.kind = kind;
    this.update = update;
  }

  /** Swift `.update(data)` / `.notification`, chosen by whether the daemon payload is empty. */
  static fromPayload(update: Uint8Array): CollaborativeDocumentChange {
    return update.length === 0
      ? new CollaborativeDocumentChange(CollaborativeDocumentChangeKind.NOTIFICATION,
        new Uint8Array(0))
      : new CollaborativeDocumentChange(CollaborativeDocumentChangeKind.UPDATE, update);
  }

  /** Swift `Equatable`. */
  equals(other: CollaborativeDocumentChange): boolean {
    if (this.kind !== other.kind || this.update.length !== other.update.length) {
      return false;
    }
    for (let index: number = 0; index < this.update.length; index++) {
      if (this.update[index] !== other.update[index]) {
        return false;
      }
    }
    return true;
  }
}

/** Swift `struct DocumentChangeEvent`. */
export class DocumentChangeEvent {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  readonly change: CollaborativeDocumentChange;

  constructor(accountId: string, conversationId: string, documentId: string,
              change: CollaborativeDocumentChange) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.change = change;
  }
}

/** Swift `struct DocumentEvent` - a rename, or an attachment added. */
export class DocumentEvent {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  /** The new name, or the attachment's identifier. */
  readonly value: string;

  constructor(accountId: string, conversationId: string, documentId: string, value: string) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.value = value;
  }
}

/** Swift `struct ParticipantLeft` - a collaborator stopped editing a document. */
export class ParticipantLeft {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  readonly peerId: string;
  readonly clientId: number;

  constructor(accountId: string, conversationId: string, documentId: string, peerId: string,
              clientId: number) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.peerId = peerId;
    this.clientId = clientId;
  }
}

/** Swift `struct DocumentRemoved`. */
export class DocumentRemoved {
  readonly accountId: string;
  readonly conversationId: string;
  readonly documentId: string;
  /**
   * True when its author retired it for every member, and nothing brings it back. False when
   * this device alone dropped it: the other members keep it, and opening it again fetches it
   * back.
   */
  readonly everywhere: boolean;

  constructor(accountId: string, conversationId: string, documentId: string,
              everywhere: boolean) {
    this.accountId = accountId;
    this.conversationId = conversationId;
    this.documentId = documentId;
    this.everywhere = everywhere;
  }
}

/** Swift `enum CollaborationError: Error` - what the daemon can refuse to do with a document. */
export enum CollaborationError {
  /** The daemon declined to create the document, which it says by answering with no id. */
  REFUSED = 'REFUSED'
}

/** What `createDocument` answers with: Swift's `(id: String, name: String)` tuple. */
export class CreatedDocument {
  readonly id: string;
  readonly name: string;

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/** Swift's per-conversation unread payload: `(conversation: String, waiting: Set<String>)`. */
class UnreadUpdate {
  readonly conversation: string;
  readonly waiting: Set<string>;

  constructor(conversation: string, waiting: Set<string>) {
    this.conversation = conversation;
    this.waiting = waiting;
  }
}

/** Snapshot of a set, so a subscriber cannot be handed the live registry entry. */
function copySet(values: Set<string>): Set<string> {
  const copy: Set<string> = new Set<string>();
  values.forEach((value: string): void => {
    copy.add(value);
  });
  return copy;
}

/** RxSwift `distinctUntilChanged` over a `Set<String>`. */
function sameSet(left: Set<string>, right: Set<string>): boolean {
  if (left.size !== right.size) {
    return false;
  }
  let equal: boolean = true;
  left.forEach((value: string): void => {
    if (!right.has(value)) {
      equal = false;
    }
  });
  return equal;
}

/** Uint8Array -> the ArrayBuffer the binding takes, without the view's surrounding bytes. */
function toBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export class CollaborationService {
  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  // MARK: - The unread registry (local, no daemon involved)

  /** Swift `private var unreadDocumentIds = [String: Set<String>]()`, keyed by conversation. */
  private readonly unreadDocumentIds: Map<string, Set<string>> = new Map<string, Set<string>>();

  /** Swift `private var openDocumentKeys = Set<String>()`, keyed by document. */
  private readonly openDocumentKeys: Set<string> = new Set<string>();

  /** Swift `private let unreadSubject = PublishSubject<(conversation:waiting:)>()`. */
  private readonly unreadSubject: PublishSubject<UnreadUpdate> =
    new PublishSubject<UnreadUpdate>();

  // MARK: - Event subjects, fed by the adapter callbacks

  /** Swift `private let documentChangeSubject = PublishSubject<DocumentChangeEvent>()`. */
  private readonly documentChangeSubject: PublishSubject<DocumentChangeEvent> =
    new PublishSubject<DocumentChangeEvent>();

  /** Swift `private let awarenessSubject = PublishSubject<AwarenessUpdate>()`. */
  private readonly awarenessSubject: PublishSubject<AwarenessUpdate> =
    new PublishSubject<AwarenessUpdate>();

  /** Swift `private let participantLeftSubject = PublishSubject<ParticipantLeft>()`. */
  private readonly participantLeftSubject: PublishSubject<ParticipantLeft> =
    new PublishSubject<ParticipantLeft>();

  /** Swift `private let renamedSubject = PublishSubject<DocumentEvent>()`. */
  private readonly renamedSubject: PublishSubject<DocumentEvent> =
    new PublishSubject<DocumentEvent>();

  /** Swift `private let attachmentSubject = PublishSubject<DocumentEvent>()`. */
  private readonly attachmentSubject: PublishSubject<DocumentEvent> =
    new PublishSubject<DocumentEvent>();

  /** Swift `private let removedSubject = PublishSubject<DocumentRemoved>()`. */
  private readonly removedSubject: PublishSubject<DocumentRemoved> =
    new PublishSubject<DocumentRemoved>();

  /*
   * Swift's `lazy var` public streams were `subject.observe(on: deliveryScheduler)`. There is
   * one ETS thread here, so the public stream IS the subject.
   */

  /** Swift `lazy var documentChanges`. */
  readonly documentChanges: PublishSubject<DocumentChangeEvent> = this.documentChangeSubject;

  /** Swift `lazy var awarenessUpdates`. */
  readonly awarenessUpdates: PublishSubject<AwarenessUpdate> = this.awarenessSubject;

  /** Swift `lazy var participantsLeft`. */
  readonly participantsLeft: PublishSubject<ParticipantLeft> = this.participantLeftSubject;

  /** Swift `lazy var documentsRenamed`. */
  readonly documentsRenamed: PublishSubject<DocumentEvent> = this.renamedSubject;

  /** Swift `lazy var attachmentsAdded`. */
  readonly attachmentsAdded: PublishSubject<DocumentEvent> = this.attachmentSubject;

  /** Swift `lazy var documentsRemoved`. */
  readonly documentsRemoved: PublishSubject<DocumentRemoved> = this.removedSubject;

  /**
   * Swift `lazy var documentUpdates = documentChanges.compactMap { ... }` - the content
   * changes alone, notifications dropped. Derived by a standing subscription rather than an
   * operator, since common/Observable.ts has no `compactMap`.
   */
  readonly documentUpdates: PublishSubject<DocumentUpdate> = new PublishSubject<DocumentUpdate>();

  constructor() {
    // Local wiring only - the registry contract forbids reading a dependency here.
    this.disposeBag.add(this.documentChanges.subscribe((event: DocumentChangeEvent): void => {
      if (event.change.kind === CollaborativeDocumentChangeKind.UPDATE) {
        this.documentUpdates.onNext(new DocumentUpdate(event.accountId, event.conversationId,
          event.documentId, event.change.update));
      }
    }));
  }

  // MARK: - Streams for one open document

  /** Swift `updates(forAccount:conversationId:documentId:)` - what an editor subscribes to. */
  updates(accountId: string, conversationId: string, documentId: string,
          observer: (update: Uint8Array) => void): () => void {
    return this.documentUpdates.subscribe((event: DocumentUpdate): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event.update);
      }
    });
  }

  /**
   * Swift `changes(forAccount:conversationId:documentId:)` - every change signal for one
   * document. A non-empty daemon payload is an update to merge; an empty one is a
   * notification that the document changed while it was not open here.
   */
  changes(accountId: string, conversationId: string, documentId: string,
          observer: (change: CollaborativeDocumentChange) => void): () => void {
    return this.documentChanges.subscribe((event: DocumentChangeEvent): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event.change);
      }
    });
  }

  /** Swift `awareness(forAccount:conversationId:documentId:)`. */
  awareness(accountId: string, conversationId: string, documentId: string,
            observer: (update: AwarenessUpdate) => void): () => void {
    return this.awarenessUpdates.subscribe((event: AwarenessUpdate): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event);
      }
    });
  }

  /** Swift `departures(forAccount:conversationId:documentId:)`. */
  departures(accountId: string, conversationId: string, documentId: string,
             observer: (departure: ParticipantLeft) => void): () => void {
    return this.participantsLeft.subscribe((event: ParticipantLeft): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event);
      }
    });
  }

  /** Swift `attachments(forAccount:conversationId:documentId:)` - the attachment ids added. */
  attachments(accountId: string, conversationId: string, documentId: string,
              observer: (attachmentId: string) => void): () => void {
    return this.attachmentsAdded.subscribe((event: DocumentEvent): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event.value);
      }
    });
  }

  /**
   * Swift `removals(forAccount:conversationId:documentId:)` - removals of one document, for a
   * screen showing that document alone. The value tells the two removals apart.
   */
  removals(accountId: string, conversationId: string, documentId: string,
           observer: (everywhere: boolean) => void): () => void {
    return this.documentsRemoved.subscribe((event: DocumentRemoved): void => {
      if (event.accountId === accountId && event.conversationId === conversationId
        && event.documentId === documentId) {
        observer(event.everywhere);
      }
    });
  }

  // MARK: - Documents waiting to be read

  /**
   * Swift `documentsWaitingToBeRead(forAccount:conversationId:)` - which of a conversation's
   * documents changed without being opened since, starting with what it stands at now
   * (`startWith` + `distinctUntilChanged`).
   */
  documentsWaitingToBeRead(accountId: string, conversationId: string,
                           observer: (waiting: Set<string>) => void): () => void {
    const conversation: string =
      CollaborationService.conversationKey(accountId, conversationId);
    let last: Set<string> = this.waiting(conversation);
    // Register before replaying, so no update is missed between the two.
    const dispose: () => void = this.unreadSubject.subscribe((update: UnreadUpdate): void => {
      if (update.conversation === conversation && !sameSet(update.waiting, last)) {
        last = update.waiting;
        observer(update.waiting);
      }
    });
    observer(last);
    return dispose;
  }

  /**
   * Swift `unreadDocumentCount(forAccount:conversationId:)`. The conversation list's unread
   * badge adds this to its message count (see common/ConversationDataSource.ts).
   */
  unreadDocumentCount(accountId: string, conversationId: string,
                      observer: (count: number) => void): () => void {
    let last: number = -1;
    return this.documentsWaitingToBeRead(accountId, conversationId,
      (waiting: Set<string>): void => {
        if (waiting.size !== last) {
          last = waiting.size;
          observer(waiting.size);
        }
      });
  }

  /** Swift `isWaitingToBeRead(forAccount:conversationId:documentId:)`. */
  isWaitingToBeRead(accountId: string, conversationId: string, documentId: string,
                    observer: (waiting: boolean) => void): () => void {
    let last: boolean | null = null;
    return this.documentsWaitingToBeRead(accountId, conversationId,
      (waiting: Set<string>): void => {
        const contains: boolean = waiting.has(documentId);
        if (last === null || contains !== last) {
          last = contains;
          observer(contains);
        }
      });
  }

  /**
   * `isWaitingToBeRead` for an announcement row, which knows its account and its document but
   * not its conversation. A document id is its own repository's id, so within an account it
   * names one document of one conversation. Starts with what it stands at now.
   */
  documentWaitingToBeRead(accountId: string, documentId: string,
                          observer: (waiting: boolean) => void): () => void {
    const prefix: string = accountId + '|';
    const waitingNow = (): boolean => {
      let waiting: boolean = false;
      this.unreadDocumentIds.forEach((documents: Set<string>, conversation: string): void => {
        if (conversation.startsWith(prefix) && documents.has(documentId)) {
          waiting = true;
        }
      });
      return waiting;
    };
    let last: boolean = waitingNow();
    const dispose: () => void = this.unreadSubject.subscribe((): void => {
      const waiting: boolean = waitingNow();
      if (waiting !== last) {
        last = waiting;
        observer(waiting);
      }
    });
    observer(last);
    return dispose;
  }

  /** Swift `markDocumentRead(...)` - the document has been opened, so it is no longer waiting. */
  markDocumentRead(accountId: string, conversationId: string, documentId: string): void {
    this.clearUnread(CollaborationService.conversationKey(accountId, conversationId), documentId);
  }

  /** Swift `private static func conversationKey(_:_:)`. */
  private static conversationKey(accountId: string, conversationId: string): string {
    return accountId + '|' + conversationId;
  }

  /** Swift `private static func documentKey(_:_:_:)`. */
  private static documentKey(accountId: string, conversationId: string,
                             documentId: string): string {
    return CollaborationService.conversationKey(accountId, conversationId) + '|' + documentId;
  }

  /** Swift `private func waiting(in:)`. */
  private waiting(conversation: string): Set<string> {
    const waiting: Set<string> | undefined = this.unreadDocumentIds.get(conversation);
    // Swift's Set is a value type, so the caller never held the registry's own entry.
    return waiting === undefined ? new Set<string>() : copySet(waiting);
  }

  /**
   * Swift `private func markUnread(accountId:conversationId:documentId:)` - a document that
   * changed is waiting to be read, unless it is open here. Publishes only on a real insert.
   */
  private markUnread(accountId: string, conversationId: string, documentId: string): void {
    const conversation: string =
      CollaborationService.conversationKey(accountId, conversationId);
    const document: string =
      CollaborationService.documentKey(accountId, conversationId, documentId);
    if (this.openDocumentKeys.has(document)) {
      return;
    }
    let waiting: Set<string> | undefined = this.unreadDocumentIds.get(conversation);
    if (waiting === undefined) {
      waiting = new Set<string>();
      this.unreadDocumentIds.set(conversation, waiting);
    }
    if (waiting.has(documentId)) {
      return;
    }
    waiting.add(documentId);
    this.unreadSubject.onNext(new UnreadUpdate(conversation, copySet(waiting)));
  }

  /** Swift `private func clearUnread(in:documentId:)`. */
  private clearUnread(conversation: string, documentId: string): void {
    const waiting: Set<string> | undefined = this.unreadDocumentIds.get(conversation);
    if (waiting === undefined || !waiting.delete(documentId)) {
      return;
    }
    if (waiting.size === 0) {
      this.unreadDocumentIds.delete(conversation);
    }
    this.unreadSubject.onNext(new UnreadUpdate(conversation, copySet(waiting)));
  }

  /** Swift `private func setDocument(_:openForAccount:conversationId:isOpen:)`. */
  private setDocument(documentId: string, accountId: string, conversationId: string,
                      isOpen: boolean): void {
    const document: string =
      CollaborationService.documentKey(accountId, conversationId, documentId);
    if (isOpen) {
      this.openDocumentKeys.add(document);
    } else {
      this.openDocumentKeys.delete(document);
    }
  }

  // MARK: - Documents

  /**
   * Swift `createDocument(accountId:conversationId:name:mimeType:)` - announce a document under
   * the name asked for, trimmed, or the default for one asked for without.
   */
  async createDocument(accountId: string, conversationId: string, name: string,
                       mimeType: string = CollaborativeDocument.MIME_RICH_TEXT):
    Promise<CreatedDocument> {
    const title: string = name.trim();
    const named: string = title.length === 0 ? COLLAB_UNTITLED_TEXT : title;
    const documentId: string =
      jami.createCollaborativeDocument(accountId, conversationId, named, mimeType);
    if (documentId.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'createDocument refused');
      throw new Error(CollaborationError.REFUSED);
    }
    return new CreatedDocument(documentId, named);
  }

  /**
   * Swift `openDocument(accountId:conversationId:documentId:)` - start an editing session and
   * get the whole document as one Y-CRDT update. Must be paired with `closeDocument`.
   */
  async openDocument(accountId: string, conversationId: string,
                     documentId: string): Promise<Uint8Array> {
    const state: Uint8Array =
      new Uint8Array(jami.openCollaborativeDocument(accountId, conversationId, documentId));
    if (state.length > 0) {
      this.setDocument(documentId, accountId, conversationId, true);
      this.markDocumentRead(accountId, conversationId, documentId);
    }
    return state;
  }

  /** Swift `closeDocument(accountId:conversationId:documentId:)`. */
  async closeDocument(accountId: string, conversationId: string,
                      documentId: string): Promise<void> {
    this.setDocument(documentId, accountId, conversationId, false);
    jami.closeCollaborativeDocument(accountId, conversationId, documentId);
  }

  /** Swift `removeDocument(...)` - retire a document for every member; only its author can. */
  async removeDocument(accountId: string, conversationId: string,
                       documentId: string): Promise<boolean> {
    return jami.removeCollaborativeDocument(accountId, conversationId, documentId);
  }

  /** Swift `removeDocumentLocally(...)` - drop a document from this device alone. */
  async removeDocumentLocally(accountId: string, conversationId: string,
                              documentId: string): Promise<boolean> {
    return jami.removeCollaborativeDocumentLocally(accountId, conversationId, documentId);
  }

  /** Swift `applyUpdate(...)` - broadcast a local edit (Y-CRDT update, lib0 v1 encoding). */
  async applyUpdate(accountId: string, conversationId: string, documentId: string,
                    update: Uint8Array): Promise<void> {
    // The proof a local edit left the editor: one line per update handed to the daemon.
    hilog.info(LOG_DOMAIN, LOG_TAG, 'applyUpdate %{public}s: %{public}d bytes to the daemon',
      documentId, update.length);
    jami.applyCollaborativeUpdate(accountId, conversationId, documentId, toBuffer(update));
  }

  /** Swift `documentState(accountId:conversationId:documentId:)`. */
  async documentState(accountId: string, conversationId: string,
                      documentId: string): Promise<Uint8Array> {
    return new Uint8Array(jami.collaborativeDocumentState(accountId, conversationId, documentId));
  }

  /** Swift `setAwareness(...)` - publish this device's ephemeral state; empty withdraws it. */
  async setAwareness(accountId: string, conversationId: string, documentId: string,
                     state: string): Promise<void> {
    jami.setCollaborativeAwareness(accountId, conversationId, documentId, state);
  }

  /** Swift `setName(accountId:conversationId:documentId:name:)`. */
  async setName(accountId: string, conversationId: string, documentId: string,
                name: string): Promise<void> {
    jami.setCollaborativeDocumentName(accountId, conversationId, documentId, name);
  }

  /** Swift `name(accountId:conversationId:documentId:)`. */
  async name(accountId: string, conversationId: string, documentId: string): Promise<string> {
    return jami.collaborativeDocumentName(accountId, conversationId, documentId);
  }

  /** Swift `documents(accountId:conversationId:)` - every document announced in a conversation. */
  async documents(accountId: string, conversationId: string): Promise<CollaborativeDocument[]> {
    const documents: CollaborativeDocument[] = [];
    for (const raw of jami.getCollaborativeDocuments(accountId, conversationId)) {
      const document: CollaborativeDocument | null = CollaborativeDocument.fromNative(toMap(raw));
      if (document !== null) {
        documents.push(document);
      }
    }
    return documents;
  }

  /** Swift `history(accountId:conversationId:documentId:max:)` - newest first; 0 = all. */
  async history(accountId: string, conversationId: string, documentId: string,
                max: number = 0): Promise<CollaborativeVersion[]> {
    const versions: CollaborativeVersion[] = [];
    for (const raw of jami.getCollaborativeDocumentHistory(accountId, conversationId, documentId,
      max)) {
      const version: CollaborativeVersion | null = CollaborativeVersion.fromNative(toMap(raw));
      if (version !== null) {
        versions.push(version);
      }
    }
    return versions;
  }

  /** Swift `stateAt(accountId:conversationId:documentId:commitId:)`. */
  async stateAt(accountId: string, conversationId: string, documentId: string,
                commitId: string): Promise<Uint8Array> {
    return new Uint8Array(
      jami.collaborativeDocumentStateAt(accountId, conversationId, documentId, commitId));
  }

  // MARK: - Attachments

  /** Swift `addAttachment(...)` - the attachment id, empty on refusal. */
  async addAttachment(accountId: string, conversationId: string, documentId: string,
                      data: Uint8Array): Promise<string> {
    return jami.addCollaborativeAttachment(accountId, conversationId, documentId, toBuffer(data));
  }

  /** Swift `attachment(...)` - empty while it has not reached this device yet. */
  async attachment(accountId: string, conversationId: string, documentId: string,
                   attachmentId: string): Promise<Uint8Array> {
    return new Uint8Array(
      jami.collaborativeAttachment(accountId, conversationId, documentId, attachmentId));
  }

  // MARK: - CollaborationAdapterDelegate
  //
  // Swift's `extension CollaborationService: CollaborationAdapterDelegate`, driven by
  // JamiNative.route from the daemon's ConversationSignal::Collaborative* signals.

  /** Swift `documentUpdate(withAccountId:conversationId:documentId:update:)`. */
  documentUpdate(accountId: string, conversationId: string, documentId: string,
                 update: Uint8Array): void {
    this.markUnread(accountId, conversationId, documentId);
    this.documentChangeSubject.onNext(new DocumentChangeEvent(accountId, conversationId,
      documentId, CollaborativeDocumentChange.fromPayload(update)));
  }

  /** Swift `awarenessChanged(withAccountId:conversationId:documentId:peerId:clientId:state:)`. */
  awarenessChanged(accountId: string, conversationId: string, documentId: string, peerId: string,
                   clientId: number, state: string): void {
    this.awarenessSubject.onNext(new AwarenessUpdate(accountId, conversationId, documentId,
      peerId, clientId, state));
  }

  /** Swift `participantLeft(withAccountId:conversationId:documentId:peerId:clientId:)`. */
  participantLeft(accountId: string, conversationId: string, documentId: string, peerId: string,
                  clientId: number): void {
    this.participantLeftSubject.onNext(new ParticipantLeft(accountId, conversationId, documentId,
      peerId, clientId));
  }

  /** Swift `documentRenamed(withAccountId:conversationId:documentId:name:)`. */
  documentRenamed(accountId: string, conversationId: string, documentId: string,
                  name: string): void {
    hilog.info(LOG_DOMAIN, 'JamiF4', 'documentRenamed %{public}s: %{public}d chars', documentId,
      name.length);
    this.renamedSubject.onNext(new DocumentEvent(accountId, conversationId, documentId, name));
  }

  /**
   * libjami `CollaborativeDocumentReplicated` (iOS 4.21 binds it in its notification extension
   * only). A card built before the document reached this device showed the announcement's name,
   * which a rename made before the download outdated; the stored copy carries the current one,
   * so it is read now and announced like a rename (T-1634).
   */
  documentReplicated(accountId: string, conversationId: string, documentId: string,
                     stored: boolean): void {
    hilog.info(LOG_DOMAIN, 'JamiF5', 'documentReplicated %{public}s: stored %{public}s', documentId,
      String(stored));
    if (!stored) {
      return;
    }
    this.name(accountId, conversationId, documentId)
      .then((name: string): void => {
        if (name.length > 0) {
          this.documentRenamed(accountId, conversationId, documentId, name);
        }
      })
      .catch((): void => {});
  }

  /** Swift `attachmentAdded(withAccountId:conversationId:documentId:attachmentId:)`. */
  attachmentAdded(accountId: string, conversationId: string, documentId: string,
                  attachmentId: string): void {
    this.attachmentSubject.onNext(new DocumentEvent(accountId, conversationId, documentId,
      attachmentId));
  }

  /** Swift `documentRemoved(withAccountId:conversationId:documentId:everywhere:)`. */
  documentRemoved(accountId: string, conversationId: string, documentId: string,
                  everywhere: boolean): void {
    this.setDocument(documentId, accountId, conversationId, false);
    this.markDocumentRead(accountId, conversationId, documentId);
    this.removedSubject.onNext(new DocumentRemoved(accountId, conversationId, documentId,
      everywhere));
  }

  /** Not in the Swift class: releases the standing `documentUpdates` subscription. */
  dispose(): void {
    this.disposeBag.dispose();
  }
}
