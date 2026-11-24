/*
 * Ported from Ring/Ring/Models/ConversationModel.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * A one-to-one (coredialog) or swarm conversation, plus the minimal reactive plumbing the
 * Swift model got from RxSwift. RxSwift/RxRelay have no HarmonyOS equivalent, so
 * BehaviorRelay / PublishSubject / DisposeBag are plain callback lists shared from
 * ../common/Observable (the "capability, not library" rule) - same names and same
 * semantics, no operators.
 *
 * Nothing here talks to the jami daemon: every value arrives from a service as a plain
 * map and is stored as it came.
 */

import { ConversationParticipant } from './ConversationParticipant';
import { ConversationPreferences } from './ConversationPreferences';
import { LoadedMessages } from './LoadedMessages';
import { MessageModel, MessageStatus, MessageType, SwarmMessageWrap } from './MessageModel';
import { RequestModel } from './RequestModel';
import { BehaviorRelay, DisposeBag, PublishSubject } from '../common/Observable';

/** Swift `ConversationType` (raw Int values are the daemon's conversation modes). */
export enum ConversationType {
  ONE_TO_ONE = 0,
  ADMIN_INVITES_ONLY = 1,
  INVITES_ONLY = 2,
  PUBLIC_CHAT = 3,
  NON_SWARM = 100,
  SIP = 101
}

/** Swift `ConversationType.init?(daemonMode:)`. Returns null when the mode is not an Int. */
export function conversationTypeFromDaemonMode(daemonMode: string): ConversationType | null {
  const mode: number = Number.parseInt(daemonMode, 10);
  if (Number.isNaN(mode)) {
    return null;
  }
  if (mode === ConversationType.ONE_TO_ONE || mode === ConversationType.ADMIN_INVITES_ONLY ||
    mode === ConversationType.INVITES_ONLY || mode === ConversationType.PUBLIC_CHAT ||
    mode === ConversationType.NON_SWARM || mode === ConversationType.SIP) {
    return mode as ConversationType;
  }
  return null;
}

/**
 * Swift `ConversationType.stringValue` returned an L10n string. On HarmonyOS the caller
 * resolves the resource name through its own resourceManager, as JamiConstants does.
 */
export function conversationTypeStringResource(type: ConversationType): string {
  if (type === ConversationType.ONE_TO_ONE) {
    return 'swarm_one_to_one';
  }
  if (type === ConversationType.ADMIN_INVITES_ONLY) {
    return 'swarm_admin_invites_only';
  }
  if (type === ConversationType.INVITES_ONLY) {
    return 'swarm_invites_only';
  }
  if (type === ConversationType.PUBLIC_CHAT) {
    return 'swarm_public_chat';
  }
  return 'swarm_others';
}

/** Swift `ConversationAttributes` - the keys of the daemon's conversation info map. */
export enum ConversationAttributes {
  TITLE = 'title',
  DESCRIPTION = 'description',
  AVATAR = 'avatar',
  MODE = 'mode',
  CONVERSATION_ID = 'id'
}

const SYNCING_KEY: string = 'syncing';
const URI_KEY: string = 'uri';
const LAST_DISPLAYED_KEY: string = 'lastDisplayed';
const RING_URI_PREFIX: string = 'ring:';

/** `LoadedMessages(messages: [MessageModel](), fromHistory: false)` - a fresh empty page. */
function emptyLoadedMessages(): LoadedMessages {
  const messages: MessageModel[] = [];
  return new LoadedMessages(messages, false);
}

export class ConversationModel {
  newMessages: BehaviorRelay<LoadedMessages> =
    new BehaviorRelay<LoadedMessages>(emptyLoadedMessages());
  private participants: ConversationParticipant[] = [];
  messages: MessageModel[] = [];
  /** Contact hash for a dialog, conversation title for multi-participant swarms. */
  hash: string = '';
  accountId: string = '';
  id: string = '';
  lastMessage: MessageModel | null = null;
  private type: ConversationType;
  numberOfUnreadMessages: BehaviorRelay<number> = new BehaviorRelay<number>(0);
  /**
   * Swift `ConversationRecord.lastReadMarkedAsRead`: the local last-read id when the chat was
   * last marked read. A recount from this same, not yet refreshed, id would bring back the
   * badge the user just cleared (T-1631).
   */
  lastReadMarkedAsRead: string | null = null;
  disposeBag: DisposeBag = new DisposeBag();
  avatar: string = '';
  title: string = '';
  description: string = '';
  preferences: ConversationPreferences = new ConversationPreferences();
  synchronizing: BehaviorRelay<boolean> = new BehaviorRelay<boolean>(false);
  reactionsUpdated: PublishSubject<string> = new PublishSubject<string>();
  /**
   * Swift `let messageUpdated = PublishSubject<String>()`. Renamed because Swift allows a
   * property and a method to share the name `messageUpdated` and ArkTS does not; the method
   * below keeps the source name since that is what callers invoke.
   */
  messageUpdatedEvents: PublishSubject<string> = new PublishSubject<string>();

  /** Swift `init(type:)`. */
  constructor(type: ConversationType) {
    this.type = type;
  }

  /** Swift `convenience init(withParticipantUri:accountId:type:isLocal:)`. */
  static withParticipantUri(participantHash: string, accountId: string, type: ConversationType,
                            isLocal: boolean = false): ConversationModel {
    const conversation: ConversationModel = new ConversationModel(type);
    conversation.participants = [new ConversationParticipant(participantHash, isLocal)];
    conversation.hash = participantHash;
    conversation.accountId = accountId;
    conversation.subscribeUnreadMessages();
    return conversation;
  }

  /** Swift `convenience init(withParticipantUri:accountId:hash:type:)`. */
  static withParticipantUriAndHash(participantHash: string, accountId: string, hash: string,
                                   type: ConversationType): ConversationModel {
    const conversation: ConversationModel = new ConversationModel(type);
    conversation.participants = [new ConversationParticipant(participantHash, false)];
    conversation.hash = hash;
    conversation.accountId = accountId;
    conversation.subscribeUnreadMessages();
    return conversation;
  }

  /** Swift `convenience init(withId:accountId:type:)`. */
  static withId(conversationId: string, accountId: string, type: ConversationType): ConversationModel {
    const conversation: ConversationModel = new ConversationModel(type);
    conversation.id = conversationId;
    conversation.accountId = accountId;
    conversation.subscribeUnreadMessages();
    return conversation;
  }

  /** Swift `convenience init(request:)`. */
  static fromRequest(request: RequestModel): ConversationModel {
    const conversation: ConversationModel = new ConversationModel(request.conversationType);
    conversation.id = request.conversationId;
    conversation.accountId = request.accountId;
    conversation.participants = request.participants;
    conversation.avatar = request.avatar ?? '';
    conversation.title = request.name;
    conversation.subscribeUnreadMessages();
    return conversation;
  }

  /** Swift `convenience init(withId:accountId:info:)`. */
  static withInfo(conversationId: string, accountId: string,
                  info: Map<string, string>): ConversationModel {
    const conversation: ConversationModel = new ConversationModel(ConversationModel.parseType(info));
    conversation.id = conversationId;
    conversation.accountId = accountId;
    conversation.updateInfo(info);
    conversation.updateProfile(info);
    conversation.subscribeUnreadMessages();
    return conversation;
  }

  static parseType(info: Map<string, string>): ConversationType {
    const mode: string | undefined = info.get(ConversationAttributes.MODE);
    if (mode !== undefined) {
      const type: ConversationType | null = conversationTypeFromDaemonMode(mode);
      if (type !== null) {
        return type;
      }
    }
    // Swarm conversations default to invitesOnly when mode is missing.
    return ConversationType.INVITES_ONLY;
  }

  addParticipant(jamiId: string): void {
    const participant: ConversationParticipant = new ConversationParticipant(jamiId, false);
    participant.isLocal = false;
    this.participants.push(participant);
  }

  updateInfo(info: Map<string, string>): void {
    const syncing: string | undefined = info.get(SYNCING_KEY);
    if (syncing === 'true') {
      this.synchronizing.accept(true);
    } else if (info.get(ConversationAttributes.MODE) === undefined) {
      this.synchronizing.accept(true);
    } else {
      this.synchronizing.accept(false);
    }
    const hash: string | undefined = info.get(ConversationAttributes.TITLE);
    if (hash !== undefined && hash.length > 0) {
      this.hash = hash;
    }
    this.updateProfile(info);
    const mode: string | undefined = info.get(ConversationAttributes.MODE);
    if (mode !== undefined) {
      const conversationType: ConversationType | null = conversationTypeFromDaemonMode(mode);
      if (conversationType !== null) {
        this.type = conversationType;
      }
    }
  }

  updateProfile(profile: Map<string, string>): void {
    const avatar: string | undefined = profile.get(ConversationAttributes.AVATAR);
    if (avatar !== undefined) {
      this.avatar = avatar;
    }
    const title: string | undefined = profile.get(ConversationAttributes.TITLE);
    if (title !== undefined) {
      this.title = title;
    }
    const description: string | undefined = profile.get(ConversationAttributes.DESCRIPTION);
    if (description !== undefined) {
      this.description = description;
    }
  }

  updatePreferences(preferences: Map<string, string>): void {
    this.preferences.update(preferences);
  }

  /**
   * Swift `static func == (lhs:rhs:)`. Swarm conversations have a unique id unless the
   * conversation is a temporary oneToOne; for non-swarm and temporary swarm conversations
   * the participant and the accountId decide.
   */
  equals(other: ConversationModel): boolean {
    if (this.type !== other.type) {
      return false;
    }
    if ((!this.isSwarm() && !other.isSwarm()) || this.id.length === 0 || other.id.length === 0) {
      const localFirst: ConversationParticipant | undefined = this.getParticipants()[0];
      const otherFirst: ConversationParticipant | undefined = other.getParticipants()[0];
      if (localFirst !== undefined && otherFirst !== undefined) {
        return localFirst.jamiId === otherFirst.jamiId && this.accountId === other.accountId;
      }
      return false;
    }
    return this.id === other.id;
  }

  private subscribeUnreadMessages(): void {
    if (this.isSwarm()) {
      return;
    }
    this.disposeBag.add(this.newMessages.subscribe(() => {
      this.numberOfUnreadMessages.accept(this.countUnreadMessages());
    }));
  }

  private countUnreadMessages(): number {
    return this.messages.filter((message: MessageModel) => {
      return message.status !== MessageStatus.DISPLAYED && message.type === MessageType.TEXT &&
        message.incoming;
    }).length;
  }

  /** Swift `getMessage(withDaemonID:)`. */
  getMessageByDaemonId(daemonId: string): MessageModel | null {
    const found: MessageModel | undefined = this.messages.find((message: MessageModel) => {
      return message.daemonId === daemonId;
    });
    return found ?? null;
  }

  getMessage(messageId: string): MessageModel | null {
    const found: MessageModel | undefined = this.messages.find((message: MessageModel) => {
      return message.id === messageId;
    });
    return found ?? null;
  }

  getLastReadMessage(): string | null {
    const local: ConversationParticipant | undefined =
      this.participants.find((participant: ConversationParticipant) => participant.isLocal);
    return local === undefined ? null : local.lastDisplayed;
  }

  getLastDisplayedMessageForDialog(): string | null {
    const peer: ConversationParticipant | undefined =
      this.participants.find((participant: ConversationParticipant) => !participant.isLocal);
    if (peer === undefined) {
      return null;
    }
    const last: string = peer.lastDisplayed;
    const message: MessageModel | undefined = this.messages.find((item: MessageModel) => {
      return item.id === last;
    });
    if (message !== undefined) {
      if (!message.incoming) {
        return last;
      }
      const index: number = this.messages.findIndex((item: MessageModel) => item.id === last);
      if (index >= 0) {
        const earlier: MessageModel[] = this.messages.slice(0, index).reverse();
        const newMessage: MessageModel | undefined =
          earlier.find((item: MessageModel) => !item.incoming);
        if (newMessage !== undefined) {
          return newMessage.id;
        }
      }
    }
    return last;
  }

  addParticipantsFromArray(participantsInfo: Array<Map<string, string>>, accountURI: string): void {
    this.participants = [];
    const localUri: string = accountURI.replace(RING_URI_PREFIX, '');
    for (const participantInfo of participantsInfo) {
      const uri: string | undefined = participantInfo.get(URI_KEY);
      if (uri === undefined || uri.length === 0) {
        continue;
      }
      const isLocal: boolean = uri.replace(RING_URI_PREFIX, '') === localUri;
      this.participants.push(ConversationParticipant.fromInfo(participantInfo, isLocal));
    }
  }

  setMessageAsRead(messageId: string, daemonId: string): void {
    const message: MessageModel | undefined = this.messages.find((item: MessageModel) => {
      return item.id === messageId && item.daemonId === daemonId;
    });
    if (message !== undefined) {
      message.status = MessageStatus.DISPLAYED;
    }
    if (!this.isSwarm()) {
      this.numberOfUnreadMessages.accept(this.countUnreadMessages());
    }
  }

  setAllMessagesAsRead(): void {
    const unreadMessages: MessageModel[] = this.messages.filter((message: MessageModel) => {
      return message.status !== MessageStatus.DISPLAYED && message.incoming &&
        message.type === MessageType.TEXT;
    });
    for (const message of unreadMessages) {
      message.status = MessageStatus.DISPLAYED;
    }
    this.lastReadMarkedAsRead = this.getLastReadMessage();
    this.numberOfUnreadMessages.accept(0);
  }

  updateLastDisplayedMessage(participantsInfo: Array<Map<string, string>>): void {
    for (const participant of this.participants) {
      for (const info of participantsInfo) {
        const jamiId: string | undefined = info.get(URI_KEY);
        const lastDisplayed: string | undefined = info.get(LAST_DISPLAYED_KEY);
        if (jamiId === undefined || lastDisplayed === undefined || jamiId !== participant.jamiId) {
          continue;
        }
        participant.lastDisplayed = lastDisplayed;
      }
    }
  }

  isCoredialog(): boolean {
    if (this.participants.length > 2) {
      return false;
    }
    return this.type === ConversationType.NON_SWARM || this.type === ConversationType.ONE_TO_ONE ||
      this.type === ConversationType.SIP;
  }

  isCoreDialogMatch(conversation: ConversationModel): boolean {
    const localFirst: ConversationParticipant | undefined = this.getParticipants()[0];
    const otherFirst: ConversationParticipant | undefined = conversation.getParticipants()[0];
    const sameParticipant: boolean = (localFirst === undefined && otherFirst === undefined) ||
      (localFirst !== undefined && otherFirst !== undefined && localFirst.jamiId === otherFirst.jamiId);
    return this.isCoredialog() && conversation.isCoredialog() && sameParticipant;
  }

  getParticipants(): ConversationParticipant[] {
    return this.participants.filter((participant: ConversationParticipant) => !participant.isLocal);
  }

  getAllLocalParticipants(): ConversationParticipant[] {
    return this.participants.filter((participant: ConversationParticipant) => participant.isLocal);
  }

  getAllParticipants(): ConversationParticipant[] {
    return this.participants;
  }

  getLocalParticipants(): ConversationParticipant | null {
    const local: ConversationParticipant | undefined =
      this.participants.find((participant: ConversationParticipant) => participant.isLocal);
    return local ?? null;
  }

  isDialog(): boolean {
    return this.participants.length <= 2;
  }

  isOnlyLocalParticipant(): boolean {
    return this.getParticipants().length === 0;
  }

  containsParticipant(participant: string): boolean {
    return this.getParticipants()
      .map((item: ConversationParticipant) => item.jamiId)
      .includes(participant);
  }

  getConversationURI(): string | null {
    if (this.type === ConversationType.NON_SWARM) {
      const first: ConversationParticipant | undefined = this.getParticipants()[0];
      if (first === undefined) {
        return null;
      }
      return 'jami:' + first.jamiId;
    }
    return 'swarm:' + this.id;
  }

  allMessagesLoaded(): boolean {
    const firstMessage: MessageModel | undefined = this.messages[0];
    if (firstMessage === undefined) {
      return false;
    }
    return firstMessage.parentId.length === 0;
  }

  appendNonSwarm(message: MessageModel): void {
    this.messages.push(message);
    const appended: MessageModel[] = [message];
    this.newMessages.accept(new LoadedMessages(appended, false));
  }

  isSwarm(): boolean {
    return this.type !== ConversationType.NON_SWARM && this.type !== ConversationType.SIP;
  }

  isSip(): boolean {
    return this.type === ConversationType.SIP;
  }

  clearMessages(): void {
    this.messages = [];
    this.newMessages.accept(emptyLoadedMessages());
    this.lastMessage = null;
    this.numberOfUnreadMessages.accept(0);
  }

  reactionAdded(messageId: string, reaction: Map<string, string>): void {
    const message: MessageModel | null = this.getMessage(messageId);
    if (message === null) {
      return;
    }
    message.reactionAdded(reaction);
    this.reactionsUpdated.onNext(messageId);
  }

  reactionRemoved(messageId: string, reactionId: string): void {
    const message: MessageModel | null = this.getMessage(messageId);
    if (message === null) {
      return;
    }
    message.reactionRemoved(reactionId);
    this.reactionsUpdated.onNext(messageId);
  }

  messageUpdated(swarmMessage: SwarmMessageWrap, localJamiId: string): void {
    const message: MessageModel | null = this.getMessage(swarmMessage.id);
    if (message === null) {
      return;
    }
    message.messageUpdated(swarmMessage, localJamiId);
    this.messageUpdatedEvents.onNext(swarmMessage.id);
  }

  messageStatusUpdated(status: MessageStatus, messageId: string, jamiId: string): void {
    const message: MessageModel | null = this.getMessage(messageId);
    if (message === null) {
      return;
    }
    message.messageStatusUpdated(status, messageId, jamiId);
    this.messageUpdatedEvents.onNext(messageId);
  }

  updateUnreadMessages(count: number): void {
    this.numberOfUnreadMessages.accept(this.numberOfUnreadMessages.value + count);
  }
}
