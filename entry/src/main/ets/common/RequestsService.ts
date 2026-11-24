/*
 * Ported from Ring/Ring/Services/RequestsService.swift:38-377 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Manages both kinds of incoming invitation: a CONTACT (trust) request and a swarm
 * CONVERSATION request. Depending on conversation type and swarm support on the other side:
 *  - only a contact request, when the peer does not support swarm;
 *  - only a conversation request, when the peer supports swarm and is already a contact;
 *  - both, when the peer supports swarm and is not a contact yet - only the conversation
 *    request is kept.
 *
 * DAEMON GAP. Swift held a `RequestsAdapter`, the Objective-C++ bridge
 * (Ring/Ring/Bridging/RequestsAdapter.{h,mm}) into the prebuilt C++ jami daemon:
 * `getSwarmRequestsForAccount`, `trustRequests`, `contacts`, `acceptTrustRequest`,
 * `discardTrustRequest`, `sendTrustRequest`, `acceptConversationRequest`,
 * `declineConversationRequest`. That daemon has no source on disk, so it is a `gap` (Rule 11):
 * nothing here fabricates a request, fakes an accept, or silently no-ops. Every adapter call
 * becomes `DaemonService.reportUnavailable('request.<op>')`, and the request list stays EMPTY -
 * which is the honest state when the daemon is absent.
 *
 * Everything that is purely local still works for real: the request list and its
 * BehaviorRelay, the lookups, the removals, the ServiceEvent emissions, and the two inbound
 * signal handlers `ConversationsManager` calls (`incomingTrustRequestReceived`,
 * `conversationRequestReceived`).
 *
 * `conversationReady`: Swift observed `NotificationCenter`'s
 * `ConversationNotifications.conversationReady`. HarmonyOS has no NotificationCenter, and
 * `ConversationsService` already replaced that post with
 * `conversationReadyNotifications: PublishSubject<ConversationReadyNotice>`, so that
 * subscription is the channel here. It is attached lazily rather than in the constructor: the
 * ServiceRegistry contract forbids reading a dependency from the constructor (import cycle).
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { StringMap } from 'libjami.so';
import { jami, toMap } from './JamiNative';
import { ContactModel } from '../model/ContactModel';
import { util } from '@kit.ArkTS';
import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { ConversationReadyNotice } from './ConversationsService';
import { DaemonService } from './DaemonService';
import { JamiUri, UriType } from './JamiUri';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import { Profile } from '../model/Profile';
import { RequestModel, RequestType } from '../model/RequestModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'RequestsService';

/** Swift `enum RequestServiceError: Error`. */
export enum RequestServiceError {
  ACCEPT_TRUST_REQUEST_FAILED = 'ACCEPT_TRUST_REQUEST_FAILED',
  DISCARD_TRUST_REQUEST_FAILED = 'DISCARD_TRUST_REQUEST_FAILED'
}

/** Swift `Data` payload of a trust request is a vCard; decode it to the text the parser wants. */
function decodePayload(payload: Uint8Array): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(payload);
}

export class RequestsService {
  /**
   * Swift `private let log = SwiftyBeaver.self`. SwiftyBeaver resolves to `@ohos.hilog`
   * (inventory `dependencies[]`), a module rather than an object you hold, so the field carries
   * the tag every hilog call in this module logs under.
   */
  private readonly log: string = LOG_TAG;

  private readonly disposeBag: DisposeBag = new DisposeBag();

  /** Swift `let requests = BehaviorRelay(value: [RequestModel]())`. */
  readonly requests: BehaviorRelay<RequestModel[]> = new BehaviorRelay<RequestModel[]>([]);

  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /** Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`. */
  readonly sharedResponseStream: PublishSubject<ServiceEvent> = this.responseStream;

  private conversationReadyAttached: boolean = false;

  /**
   * Swift `private let requestsAdapter: RequestsAdapter` - the daemon bridge. It has no
   * HarmonyOS counterpart (see the class doc), so the field resolves to the daemon surface,
   * whose every answer is "unavailable". Read inside method bodies only (registry rule 2).
   */
  private get requestsAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /**
   * Swift attached the `conversationReady` NotificationCenter observer in `init`. The registry
   * contract forbids touching another service from the constructor, so the subscription is
   * attached on first use instead. Idempotent.
   */
  private attachConversationReady(): void {
    if (this.conversationReadyAttached) {
      return;
    }
    this.conversationReadyAttached = true;
    const unsubscribe: () => void = ServiceRegistry.shared().conversationsService
      .conversationReadyNotifications.subscribe((notice: ConversationReadyNotice) => {
        this.conversationReady(notice);
      });
    this.disposeBag.add(unsubscribe);
  }

  /** Drops the conversation-ready subscription. */
  dispose(): void {
    try {
      this.disposeBag.dispose();
    } finally {
      this.conversationReadyAttached = false;
    }
  }

  // MARK: initial loading

  /**
   * Swift `func updateConversationsRequests(withAccount:)`. The swarm request list comes from
   * `requestsAdapter.getSwarmRequests(forAccount:)`, which is the daemon: unavailable, so
   * nothing is appended and the relay keeps whatever locally-signalled requests it holds.
   */
  updateConversationsRequests(accountId: string): void {
    this.attachConversationReady();
    const conversationRequests: RequestModel[] = this.swarmRequests(accountId)
      .filter((newModel: RequestModel) => !this.requests.value.some((existing: RequestModel) =>
        existing.conversationId === newModel.conversationId));
    if (conversationRequests.length > 0) {
      this.requests.accept(this.requests.value.concat(conversationRequests));
    }
  }

  private swarmRequests(accountId: string): RequestModel[] {
    return jami.getConversationRequests(accountId).map((dictionary: StringMap) =>
      RequestModel.fromDictionary(toMap(dictionary), accountId, RequestType.CONVERSATION));
  }

  private contactIds(accountId: string): string[] {
    return jami.getContacts(accountId)
      .map((contact: StringMap) => ContactModel.fromDictionary(toMap(contact)).hash);
  }

  /**
   * Swift `func loadRequests(withAccount:accountURI:)` - called at app start and on account
   * change. The local half is real: the relay is cleared. Both daemon fetches (swarm requests
   * and trust requests, plus the accepted-contact filter that reads `requestsAdapter.contacts`)
   * are unavailable, so the loaded list is empty.
   */
  loadRequests(accountId: string, accountURI: string): void {
    this.attachConversationReady();
    this.requests.accept([]);
    const currentRequests: RequestModel[] = this.swarmRequests(accountId);
    const contactRequests: RequestModel[] = jami.getTrustRequests(accountId).map((dictionary: StringMap) =>
      RequestModel.fromDictionary(toMap(dictionary), accountId, RequestType.CONTACT));
    const contactsId: string[] = this.contactIds(accountId);
    for (const contactRequest of contactRequests) {
      if (contactRequest.conversationId.length > 0) {
        continue;
      }
      const participant: string = contactRequest.participants.length === 0 ? ''
        : contactRequest.participants[0].jamiId;
      if (currentRequests.some((r: RequestModel) => r.accountId === accountId && r.isCoredialog() &&
        r.participants.length > 0 && r.participants[0].jamiId === participant)) {
        continue;
      }
      // Swift `return`s here (stopping the loop) when the request was already accepted.
      if (contactsId.includes(participant)) {
        break;
      }
      currentRequests.push(contactRequest);
    }
    this.requests.accept(currentRequests);
  }

  // MARK: conversation-ready signal (Swift: NotificationCenter action)

  /**
   * Swift `@objc private func conversationReady(_ notification: NSNotification)`. After an
   * accept the request stays in synchronization until the peer comes online and the
   * conversation syncs; when that happens the request can be removed.
   */
  private conversationReady(notice: ConversationReadyNotice): void {
    const index: number = this.requests.value.findIndex((request: RequestModel) => {
      return request.accountId === notice.accountId &&
        request.conversationId === notice.conversationId;
    });
    if (index < 0) {
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    const request: RequestModel = values[index];
    values.splice(index, 1);
    this.requests.accept(values);
    this.emit(ServiceEventType.CONTACT_REQUEST_ACCEPTED, request);
  }

  /**
   * Swift `RequestsViewModel.filterRequestsNotInConversations(requests:conversations:accountId:)`:
   * the account's invitations that are not already a conversation.
   */
  pendingRequests(requests: RequestModel[], accountId: string): RequestModel[] {
    const conversationIds: Set<string> = new Set<string>(
      ServiceRegistry.shared().conversationsService.conversations.value
        .map((conversation: ConversationModel) => conversation.id));
    return requests.filter((request: RequestModel) =>
      request.accountId === accountId && !conversationIds.has(request.conversationId));
  }

  /** Swift `func getRequest(withId conversationId:accountId:) -> RequestModel?`. */
  getRequest(conversationId: string, accountId: string): RequestModel | null {
    const matches: RequestModel[] = this.requests.value.filter((request: RequestModel) => {
      return request.conversationId === conversationId && request.accountId === accountId;
    });
    return matches.length === 0 ? null : matches[0];
  }

  // MARK: Private helpers

  /** Swift `private func getRequest(withJamiId participantId:accountId:)`. */
  private getRequestByJamiId(participantId: string, accountId: string): RequestModel | null {
    const matches: RequestModel[] = this.requests.value.filter((request: RequestModel) => {
      return request.participants.length > 0 &&
        request.participants[0].jamiId === participantId &&
        request.accountId === accountId && request.isCoredialog();
    });
    return matches.length === 0 ? null : matches[0];
  }

  /** Swift `private func removeRequest(withJamiId jamiId:accountId:)`. */
  private removeRequestByJamiId(jamiId: string, accountId: string): void {
    const index: number = this.requests.value.findIndex((request: RequestModel) => {
      return request.participants.length > 0 && request.participants[0].jamiId === jamiId &&
        request.accountId === accountId;
    });
    if (index < 0) {
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    values.splice(index, 1);
    this.requests.accept(values);
  }

  /** Swift `private func removeRequest(with conversationId:accountId:)`. */
  private removeRequest(conversationId: string, accountId: string): void {
    const index: number = this.requests.value.findIndex((request: RequestModel) => {
      return request.conversationId === conversationId && request.accountId === accountId;
    });
    if (index < 0) {
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    values.splice(index, 1);
    this.requests.accept(values);
  }

  /** Swift `private func hasConversationRequestForParticipant(partisipant:) -> Bool`. */
  hasConversationRequestForParticipant(participant: ConversationParticipant | null): boolean {
    if (participant === null) {
      return false;
    }
    return this.requests.value.some((request: RequestModel) => {
      return request.participants.length > 0 &&
        request.participants[0].jamiId === participant.jamiId &&
        request.type === RequestType.CONVERSATION &&
        request.conversationType === ConversationType.ONE_TO_ONE;
    });
  }

  /** Swift `private func hasContactRequestForParticipant(partisipant:) -> Bool`. */
  hasContactRequestForParticipant(participant: ConversationParticipant | null): boolean {
    if (participant === null) {
      return false;
    }
    return this.requests.value.some((request: RequestModel) => {
      return request.participants.length > 0 &&
        request.participants[0].jamiId === participant.jamiId &&
        request.type === RequestType.CONTACT;
    });
  }

  /** Swift `private func emit(_ eventType:for request:)` - no peer URI, no event. */
  private emit(eventType: ServiceEventType, request: RequestModel | null): void {
    if (request === null) {
      return;
    }
    const uri: string | null = request.peerURI;
    if (uri === null) {
      return;
    }
    const event: ServiceEvent = new ServiceEvent(eventType);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, request.accountId);
    event.addEventInput(ServiceEventInput.PEER_URI, uri);
    const profile: Profile | null = request.peerProfile;
    if (profile !== null) {
      event.addProfile(ServiceEventInput.PROFILE, profile);
    }
    this.responseStream.onNext(event);
  }

  // MARK: Request actions

  /**
   * Swift `func acceptContactRequest(jamiId:withAccount:) -> Observable<Void>`, for contact
   * requests. Swift removed the request and emitted only when
   * `requestsAdapter.acceptTrustRequest` returned true; without a daemon it never can, so this
   * rejects with the gap and changes nothing - a local removal here would look like an accept
   * that never reached the peer.
   */
  acceptContactRequest(jamiId: string, accountId: string): Promise<void> {
    this.attachConversationReady();
    const request: RequestModel | null = this.getRequestByJamiId(jamiId, accountId);
    if (!jami.acceptTrustRequest(accountId, jamiId)) {
      return Promise.reject(new Error(RequestServiceError.ACCEPT_TRUST_REQUEST_FAILED));
    }
    if (request !== null) {
      this.removeRequestByJamiId(jamiId, accountId);
      this.emit(ServiceEventType.CONTACT_REQUEST_ACCEPTED, request);
      if (request.conversationId.length === 0) {
        // Emit so a message can be generated for the db.
        const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_ADDED);
        event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
        event.addEventInput(ServiceEventInput.URI, jamiId);
        this.responseStream.onNext(event);
      }
    }
    return Promise.resolve();
  }

  /** Swift `func requestAccepted(conversationId:withAccount:conversationType:)`. */
  requestAccepted(conversationId: string, accountId: string,
    conversationType: ConversationType): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.REQUEST_ACCEPTED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    // Swift passed the enum itself; ConversationType is an Int enum and ConversationsManager
    // reads this key with `getNumber`, so it travels as its raw value.
    event.addNumber(ServiceEventInput.CONVERSATION_TYPE, conversationType as number);
    this.responseStream.onNext(event);
  }

  /**
   * Swift `func acceptConverversationRequest(conversationId:withAccount:) -> Observable<Void>`
   * (source spelling kept). The accept itself is
   * `requestsAdapter.acceptConversationRequest` - daemon-only - so this rejects with the gap.
   * Neither the removal nor `requestAccepted` runs: both announce an acceptance that did not
   * happen.
   */
  acceptConverversationRequest(conversationId: string, accountId: string): Promise<void> {
    this.attachConversationReady();
    const request: RequestModel | null = this.getRequest(conversationId, accountId);
    const type: ConversationType = request === null ? ConversationType.INVITES_ONLY : request.conversationType;
    jami.acceptConversationRequest(accountId, conversationId);
    this.removeRequest(conversationId, accountId);
    this.emit(ServiceEventType.CONTACT_REQUEST_ACCEPTED, request);
    this.requestAccepted(conversationId, accountId, type);
    return Promise.resolve();
  }

  /**
   * Swift `func discardContactRequest(jamiId:withAccount:) -> Observable<Void>` - used for
   * contact requests, and for a one-to-one conversation request whose peer is not a contact
   * yet. `requestsAdapter.discardTrustRequest` is daemon-only, so this rejects with the gap.
   */
  discardContactRequest(jamiId: string, accountId: string): Promise<void> {
    this.attachConversationReady();
    const request: RequestModel | null = this.getRequestByJamiId(jamiId, accountId);
    if (!jami.discardTrustRequest(accountId, jamiId)) {
      return Promise.reject(new Error(RequestServiceError.DISCARD_TRUST_REQUEST_FAILED));
    }
    this.removeRequestByJamiId(jamiId, accountId);
    this.emit(ServiceEventType.CONTACT_REQUEST_REMOVED, request);
    if (request !== null && request.conversationId.length === 0) {
      // Emit so a message can be generated for the db.
      const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_REQUEST_DISCARDED);
      event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
      event.addEventInput(ServiceEventInput.URI, jamiId);
      this.responseStream.onNext(event);
    }
    return Promise.resolve();
  }

  /**
   * Swift `func discardConverversationRequest(conversationId:withAccount:)` (source spelling
   * kept). `requestsAdapter.declineConversationRequest` is daemon-only, so this rejects with
   * the gap rather than dropping the request locally while the peer still sees it pending.
   */
  discardConverversationRequest(conversationId: string, accountId: string): Promise<void> {
    this.attachConversationReady();
    const request: RequestModel | null = this.getRequest(conversationId, accountId);
    jami.declineConversationRequest(accountId, conversationId);
    this.removeRequest(conversationId, accountId);
    this.emit(ServiceEventType.CONTACT_REQUEST_REMOVED, request);
    return Promise.resolve();
  }

  /**
   * Swift `func sendContactRequest(to:withAccountId:payload:peerProfile:) -> Completable`.
   * `requestsAdapter.sendTrustRequest` is daemon-only. The `contactRequestSent` event is NOT
   * emitted: nothing was sent, and the event is what drives `ProfilesService.invitationSent`.
   * The URI is still computed so the log names the peer the way Swift's event did.
   */
  sendContactRequest(jamiId: string, accountId: string, payload: Uint8Array | null,
    peerProfile: Profile | null = null): Promise<void> {
    this.attachConversationReady();
    const bytes: ArrayBuffer = payload === null ? new ArrayBuffer(0)
      : payload.buffer.slice(payload.byteOffset, payload.byteOffset + payload.byteLength) as ArrayBuffer;
    jami.sendTrustRequest(accountId, jamiId, bytes);
    const uri: string | null = JamiUri.fromInfoHash(UriType.RING, jamiId).uriString;
    if (uri !== null) {
      const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_REQUEST_SENT);
      event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
      event.addEventInput(ServiceEventInput.PEER_URI, uri);
      if (peerProfile !== null) {
        peerProfile.uri = uri;
        event.addProfile(ServiceEventInput.PROFILE, peerProfile);
      }
      this.responseStream.onNext(event);
    }
    return Promise.resolve();
  }

  /** Swift `func conversationRemoved(conversationId:accountId:)` - purely local. */
  conversationRemoved(conversationId: string, accountId: string): void {
    const index: number = this.requests.value.findIndex((request: RequestModel) => {
      return request.conversationId === conversationId && request.accountId === accountId;
    });
    if (index < 0) {
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    const request: RequestModel = values[index];
    values.splice(index, 1);
    this.requests.accept(values);
    this.emit(ServiceEventType.CONTACT_REQUEST_REMOVED, request);
  }

  // MARK: extension RequestsService: RequestsAdapterDelegate
  // Both handlers below are INBOUND signals, pushed in by ConversationsManager. They are local
  // work and run for real.

  /**
   * Swift `func incomingTrustRequestReceived(from:to:conversationId:withPayload:receivedDate:)`
   * - a newly received contact request. `payload` is the peer's vCard (Swift `Data`).
   *
   * The "already accepted?" guard reads `requestsAdapter.contacts(withAccountId:)`, which is
   * daemon-only: with no contact list to check against, the guard cannot exclude anything, so
   * the request is added. That is the safe direction - the alternative drops a real request.
   */
  incomingTrustRequestReceived(jamiId: string, accountId: string, conversationId: string,
    payload: Uint8Array, receivedDate: Date): void {
    this.attachConversationReady();
    const contactsId: string[] = this.contactIds(accountId);
    const request: RequestModel = RequestModel.fromPayload(jamiId, accountId,
      decodePayload(payload), receivedDate, RequestType.CONTACT, conversationId);
    const firstJamiId: string =
      request.participants.length === 0 ? '' : request.participants[0].jamiId;
    if (contactsId.includes(firstJamiId)) {
      return;
    }
    // Add the request only if it is not there yet.
    if (conversationId.length === 0) {
      if (this.getRequestByJamiId(jamiId, accountId) !== null) {
        return;
      }
    } else if (this.getRequest(conversationId, accountId) !== null) {
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    values.push(request);
    this.requests.accept(values);
    if (conversationId.length === 0) {
      // Emit so a message can be generated for the db.
      const event: ServiceEvent = new ServiceEvent(ServiceEventType.CONTACT_REQUEST_RECEIVED);
      event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
      event.addEventInput(ServiceEventInput.URI, jamiId);
      // Swift put the Date itself in `.date`; ServiceEvent has no date bucket, so it travels
      // as epoch milliseconds.
      event.addNumber(ServiceEventInput.DATE, receivedDate.getTime());
      this.responseStream.onNext(event);
    }
  }

  /**
   * Swift `func conversationRequestReceived(conversationId:accountId:metadata:)` - adds a
   * conversation request; if a contact request already exists for the same conversation it is
   * updated in place instead (which is how the contact request stops being shown separately).
   */
  conversationRequestReceived(conversationId: string, accountId: string,
    metadata: Map<string, string>): void {
    this.attachConversationReady();
    const conversationRequest: RequestModel = RequestModel.fromDictionary(metadata, accountId,
      RequestType.CONVERSATION, conversationId);
    const existing: RequestModel | null = this.getRequest(conversationId, accountId);
    if (existing !== null) {
      existing.updatefrom(metadata);
      existing.type = RequestType.CONVERSATION;
      return;
    }
    const values: RequestModel[] = this.requests.value.slice();
    values.push(conversationRequest);
    this.requests.accept(values);
  }
}
