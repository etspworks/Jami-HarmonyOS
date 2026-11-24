/*
 * Ported from Ring/Ring/Models/MessageModel.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Swift's MessageModel.swift declares five things: MessageAttributes, MessageType,
 * ContactAction, MessageAction (its own module here) and MessageModel. Everything but
 * MessageAction is carried over into this file, the way the source groups it.
 *
 * MessageStatus and DataTransferStatus come from the ObjC daemon bridge
 * (Ring/CommonObjc/ObjcTypes.h, Ring/Ring/Services/DataTransferService.swift). The daemon
 * itself is a prebuilt binary with no HarmonyOS equivalent, but its VALUE enums are plain
 * data, so they are declared here - the model layer is the lowest layer that needs them,
 * and declaring them in the service would make every model import a service.
 *
 * SwiftUI/RxSwift have no part in this file: it is a value model, .ts, no UI.
 */
import { i18n, intl, resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MessageAction } from './MessageAction';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'MessageModel';

/** Swift `MessageAttributes` - the daemon's interaction-dictionary keys. */
export enum MessageAttribute {
  INTERACTION_ID = 'id',
  TYPE = 'type',
  INVITED = 'invited',
  FILE_ID = 'fileId',
  DISPLAY_NAME = 'displayName',
  BODY = 'body',
  AUTHOR = 'author',
  URI = 'uri',
  TIMESTAMP = 'timestamp',
  PARENT = 'linearizedParent',
  ACTION = 'action',
  DURATION = 'duration',
  REPLY = 'reply-to',
  REACT = 'react-to',
  TOTAL_SIZE = 'totalSize',
  TID = 'tid',
  PARENTS = 'parents'
}

/**
 * Swift `MessageType`. Swift carries the contact action INSIDE the case
 * (`.contact(ContactAction)`); ArkTS enums have no associated values, so the action lives
 * beside the type on the message (`MessageModel.contactAction`).
 */
export enum MessageType {
  TEXT = 'text/plain',
  FILE_TRANSFER = 'application/data-transfer+json',
  CONTACT = 'member',
  CALL = 'application/call-history+json',
  MERGE = 'merge',
  INITIAL = 'initial',
  PROFILE = 'application/update-profile',
  COLLAB_DOCUMENT = 'application/collab-doc+json',
  /** An admin's vote to ban/unban a member; never drawn (live iPhone Jami 4.21, T-1717, T-1625). */
  VOTE = 'vote'
}

/** Swift `MessageType.init?(rawValue:)`. */
export function messageTypeFromRaw(raw: string): MessageType | undefined {
  if (raw === 'text/plain') {
    return MessageType.TEXT;
  }
  if (raw === 'application/data-transfer+json') {
    return MessageType.FILE_TRANSFER;
  }
  if (raw === 'member') {
    return MessageType.CONTACT;
  }
  if (raw === 'application/call-history+json') {
    return MessageType.CALL;
  }
  if (raw === 'merge') {
    return MessageType.MERGE;
  }
  if (raw === 'initial') {
    return MessageType.INITIAL;
  }
  if (raw === 'application/update-profile') {
    return MessageType.PROFILE;
  }
  if (raw === 'application/collab-doc+json') {
    return MessageType.COLLAB_DOCUMENT;
  }
  if (raw === 'vote') {
    return MessageType.VOTE;
  }
  return undefined;
}

/**
 * Swift `MessageType.isCentered` - shown across the conversation rather than as a bubble:
 * it belongs to no sequence, and breaks the one it lands in.
 */
export function isCenteredMessageType(type: MessageType): boolean {
  return type === MessageType.CONTACT || type === MessageType.INITIAL
    || type === MessageType.COLLAB_DOCUMENT;
}

/**
 * Swift `UnicodeScalar.isEmoji` (Extensions/Emoji+Helpers.swift); its 127000-127600 and
 * 65024-65039 ranges sit inside the first and fourth below, so they are folded in.
 */
function isEmojiScalar(value: number): boolean {
  return (value >= 0x1F000 && value <= 0x1FFFF) // Emoticons, flags, skin tones
    || (value >= 0x2600 && value <= 0x26FF)     // Misc symbols
    || (value >= 0x2700 && value <= 0x27BF)     // Dingbats
    || (value >= 0xFE00 && value <= 0xFE0F)     // Variation selectors
    || (value >= 9100 && value <= 9300)         // Misc items
    || (value >= 8400 && value <= 8447);        // Combining diacritical marks for symbols
}

/**
 * Swift `String.containsOnlyEmoji` — non-empty and every scalar is an emoji or the
 * zero-width joiner, so ZWJ sequences, flags and skin tones pass; letters, digits and
 * spaces do not.
 */
export function containsOnlyEmoji(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (const scalar of text) {
    const value: number = scalar.codePointAt(0) as number;
    if (!isEmojiScalar(value) && value !== 0x200D) {
      return false;
    }
  }
  return true;
}

/**
 * Swift `ContactAction`, as the App Store Jami 4.21 the testers' iPhones run (T-1625 review):
 * the daemon's 'ban' parses, so a removed member reads "<name> was blocked from the
 * conversation." on the admin's and the other members' devices (iOS bbac5925).
 */
export enum ContactAction {
  ADD = 'add',
  REMOVE = 'remove',
  JOIN = 'join',
  BANNED = 'ban',
  UNBAN = 'unban'
}

export function contactActionFromRaw(raw: string): ContactAction | undefined {
  if (raw === 'add') {
    return ContactAction.ADD;
  }
  if (raw === 'remove') {
    return ContactAction.REMOVE;
  }
  if (raw === 'join') {
    return ContactAction.JOIN;
  }
  if (raw === 'ban') {
    return ContactAction.BANNED;
  }
  if (raw === 'unban') {
    return ContactAction.UNBAN;
  }
  return undefined;
}

/** Swift `ContactAction.getInteractionString(name:isIncomig:)`. */
export function contactActionInteractionString(action: ContactAction, name: string,
  isIncoming: boolean): string {
  if (action === ContactAction.ADD) {
    return isIncoming ? tr1('generated_message_invitation_received', name)
      : tr('generated_message_contact_added');
  }
  if (action === ContactAction.JOIN) {
    return isIncoming ? tr1('generated_message_invitation_accepted', name)
      : tr('generated_message_you_joined');
  }
  if (action === ContactAction.REMOVE) {
    return tr1('generated_message_contact_left_conversation', name);
  }
  if (action === ContactAction.BANNED) {
    return tr1('generated_message_contact_blocked', name);
  }
  return tr1('generated_message_contact_unblocked', name);
}

/** ObjC `MessageStatus` (Ring/CommonObjc/ObjcTypes.h) - the raw values are the daemon's. */
export enum MessageStatus {
  UNKNOWN = 0,
  SENDING = 1,
  SENT = 2,
  DISPLAYED = 3,
  FAILURE = 4,
  CANCELED = 5
}

export function messageStatusFromRaw(raw: number): MessageStatus | undefined {
  if (raw === 0) {
    return MessageStatus.UNKNOWN;
  }
  if (raw === 1) {
    return MessageStatus.SENDING;
  }
  if (raw === 2) {
    return MessageStatus.SENT;
  }
  if (raw === 3) {
    return MessageStatus.DISPLAYED;
  }
  if (raw === 4) {
    return MessageStatus.FAILURE;
  }
  if (raw === 5) {
    return MessageStatus.CANCELED;
  }
  return undefined;
}

/** Swift `DataTransferStatus` (Ring/Ring/Services/DataTransferService.swift). */
export enum DataTransferStatus {
  CREATED = 'created',
  AWAITING = 'awaiting',
  CANCELED = 'canceled',
  ONGOING = 'ongoing',
  SUCCESS = 'success',
  ERROR = 'error',
  UNKNOWN = 'unknown'
}

/**
 * ObjC `SwarmMessageWrap` (Ring/CommonObjc/ObjcTypes.h): one swarm commit as the daemon
 * hands it over. The daemon is a `gap` on HarmonyOS - nothing produces this yet - so it is
 * declared as the shape the port expects, not as a fabricated source of messages.
 */
export interface SwarmMessageWrap {
  id: string;
  type: string;
  linearizedParent: string;
  body: Map<string, string>;
  reactions: Array<Map<string, string>>;
  editions: Array<Map<string, string>>;
  status: Map<string, number>;
}

/*
 * Localized generated-message text. Swift reaches L10n (a compile-time table) from the
 * model; on HarmonyOS an app string needs a ResourceManager, and `getContext()` is an
 * ArkUI-only global that a .ts module cannot call - so the ability hands it in once.
 */
let appResources: resourceManager.ResourceManager | undefined = undefined;

/** Call once from the ability's `onCreate`: `setModelResources(this.context.resourceManager)`. */
export function setModelResources(manager: resourceManager.ResourceManager): void {
  appResources = manager;
}

function tr(name: string): string {
  if (appResources === undefined) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager set; string %{public}s unresolved', name);
    return '';
  }
  return appResources.getStringByNameSync(name);
}

function tr1(name: string, first: string): string {
  if (appResources === undefined) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager set; string %{public}s unresolved', name);
    return '';
  }
  return appResources.getStringByNameSync(name, first);
}

function tr2(name: string, first: string, second: string): string {
  if (appResources === undefined) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager set; string %{public}s unresolved', name);
    return '';
  }
  return appResources.getStringByNameSync(name, first, second);
}

/** Swift `String.durationFormatted(seconds:)` (Ring/Ring/Extensions/String+Helpers.swift). */
export function durationFormatted(seconds: number): string {
  const whole: number = Math.trunc(seconds);
  const sec: number = whole % 60;
  const min: number = Math.trunc(whole / 60) % 60;
  const hours: number = Math.trunc(whole / 3600);
  return hours > 0 ? `${pad2(hours)}:${pad2(min)}:${pad2(sec)}` : `${pad2(min)}:${pad2(sec)}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

/**
 * Swift `Date.getTimeLabelString()` (Ring/Ring/Extensions/Date+Helpers.swift). Swift picks
 * a `DateFormatter` pattern per age bucket; the same buckets here pick `DateTimeOptions`,
 * because a hand-written pattern would not follow the device locale.
 */
export function timeLabelString(date: Date): string {
  const now: Date = new Date();
  const locale: string = i18n.System.getSystemLocale();
  const dayStart: number = startOfDay(date);
  const todayStart: number = startOfDay(now);
  // Calendar's week starts on Sunday, and getDay() is Sunday-based too.
  const weekStart: number = todayStart - now.getDay() * 86400000;
  let options: intl.DateTimeOptions;
  if (dayStart === todayStart) {
    options = { hour: 'numeric', minute: '2-digit', hour12: true };
  } else if (dayStart >= weekStart && dayStart <= todayStart) {
    options = { weekday: 'short', hour: 'numeric', minute: '2-digit', hour12: true };
  } else if (date.getFullYear() === now.getFullYear()) {
    options = { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true };
  } else {
    options = {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: 'numeric', minute: '2-digit', hour12: true
    };
  }
  return new intl.DateTimeFormat(locale, options).format(date).toUpperCase();
}

/**
 * Swift `Date.conversationTimestamp()` (Date+Helpers.swift) - the smart list row's date:
 * "HH:mm" today, "Yesterday", the weekday name this week, else the medium date.
 */
export function conversationTimestamp(date: Date): string {
  const now: Date = new Date();
  const locale: string = i18n.System.getSystemLocale();
  if (startOfDay(date) === startOfDay(now)) {
    return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  }
  // Swift compares the day of the month alone, whatever the month.
  if (date.getDate() === now.getDate() - 1) {
    return tr('smartlist_yesterday');
  }
  const weekStart: number = startOfDay(now) - now.getDay() * 86400000;
  if (date.getFullYear() === now.getFullYear() && startOfDay(date) >= weekStart) {
    return new intl.DateTimeFormat(locale, { weekday: 'long' }).format(date);
  }
  return new intl.DateTimeFormat(locale, { dateStyle: 'medium' }).format(date);
}

function infoValue(info: Map<string, string>, key: MessageAttribute): string | undefined {
  return info.get(key as string);
}

export class MessageModel {
  id: string = '';
  /** daemonId for dht messages, file transfer id for datatransfer */
  daemonId: string = '';
  receivedDate: Date = new Date();
  /**
   * message to display for text, call and contact message. File name for swarm data
   * transfer. file name with identifier from photo library for non swarm file transfer
   */
  content: string = '';
  /** jamiId for sender. For outgoing message authorId is empty */
  authorId: string = '';
  uri: string = '';
  status: MessageStatus = MessageStatus.SENDING;
  transferStatus: DataTransferStatus = DataTransferStatus.UNKNOWN;
  incoming: boolean;
  parentId: string = '';
  type: MessageType = MessageType.TEXT;
  /** Swift keeps this inside `MessageType.contact(_:)`; ArkTS enums carry no payload. */
  contactAction: ContactAction | undefined = undefined;
  reply: string = '';
  react: string = '';
  totalSize: number = 0;
  parents: Array<string> = [];
  /**
   * Swift uses `Set<MessageAction>` hashed on `id`; an ArkTS Set is identity-based and
   * would let the same reaction in twice, so the de-duplication is keyed explicitly.
   */
  reactions: Map<string, MessageAction> = new Map<string, MessageAction>();
  editions: Map<string, MessageAction> = new Map<string, MessageAction>();
  statusForParticipant: Map<string, MessageStatus> = new Map<string, MessageStatus>();
  accessibilityLabelValue: string = '';
  tid: string = '';
  /** Set for `COLLAB_DOCUMENT` only: the document this commit announces. */
  collabDocumentId: string = '';
  /** The name the document was created with; it can be renamed afterwards. */
  collabDocumentName: string = '';

  /* Swift guards statusForParticipant with an NSLock because the daemon delivers status on
   * its own thread. An ArkTS module instance is confined to one VM thread, so there is no
   * concurrent writer to lock out; statusForParticipantSnapshot() still copies, so a caller
   * iterating cannot be surprised by a later write. */

  /** Swift `init(withId:receivedDate:content:authorURI:incoming:)`. */
  constructor(id: string, receivedDate: Date, content: string, authorURI: string,
    incoming: boolean) {
    this.daemonId = id;
    this.receivedDate = receivedDate;
    this.content = content;
    this.authorId = authorURI;
    this.incoming = incoming;
  }

  /** Swift `init(withInfo:localJamiId:)`. */
  static fromInfo(info: Map<string, string>, localJamiId: string): MessageModel {
    const message: MessageModel = new MessageModel('', new Date(), '', '', false);
    const interactionId: string | undefined = infoValue(info, MessageAttribute.INTERACTION_ID);
    if (interactionId !== undefined) {
      message.id = interactionId;
    }
    const author: string | undefined = infoValue(info, MessageAttribute.AUTHOR);
    if (author !== undefined) {
      message.authorId = author;
    }
    const rawType: string | undefined = infoValue(info, MessageAttribute.TYPE);
    if (rawType !== undefined) {
      const messageType: MessageType | undefined = messageTypeFromRaw(rawType);
      if (messageType !== undefined) {
        message.type = messageType;
      }
    }
    if (message.type === MessageType.COLLAB_DOCUMENT) {
      // A document announcement puts the document's id in "uri", not the author's; taking
      // it for one would make every document look as if it came from a stranger.
      const documentId: string | undefined = infoValue(info, MessageAttribute.URI);
      message.collabDocumentId = documentId !== undefined ? documentId : '';
      const documentName: string | undefined = infoValue(info, MessageAttribute.DISPLAY_NAME);
      message.collabDocumentName = documentName !== undefined ? documentName : '';
    } else {
      const uri: string | undefined = infoValue(info, MessageAttribute.URI);
      if (uri !== undefined) {
        message.uri = uri;
      }
    }
    const body: string | undefined = infoValue(info, MessageAttribute.BODY);
    if (body !== undefined && message.type === MessageType.TEXT) {
      message.content = body;
    }
    const reply: string | undefined = infoValue(info, MessageAttribute.REPLY);
    if (reply !== undefined) {
      message.reply = reply;
    }
    const react: string | undefined = infoValue(info, MessageAttribute.REACT);
    if (react !== undefined) {
      message.react = react;
    }
    const tid: string | undefined = infoValue(info, MessageAttribute.TID);
    if (tid !== undefined) {
      message.tid = tid;
    }
    message.incoming = message.uri.length === 0
      ? (message.authorId.length === 0 ? true : message.authorId !== localJamiId)
      : message.uri !== localJamiId;
    const parent: string | undefined = infoValue(info, MessageAttribute.PARENT);
    if (parent !== undefined) {
      message.parentId = parent;
    }
    message.appendParents(info);
    const totalSizeString: string | undefined = infoValue(info, MessageAttribute.TOTAL_SIZE);
    if (totalSizeString !== undefined) {
      const totalSize: number = Number.parseInt(totalSizeString, 10);
      if (!Number.isNaN(totalSize)) {
        message.totalSize = totalSize;
      }
    }
    message.applyTimestamp(info);
    message.applyTypeContent(info);
    message.updateAccessibilityLabel(message.type, message.receivedDate);
    return message;
  }

  /** Swift `convenience init(with swarmMessage:localJamiId:)`. */
  static fromSwarmMessage(swarmMessage: SwarmMessageWrap, localJamiId: string): MessageModel {
    const message: MessageModel = MessageModel.fromInfo(swarmMessage.body, localJamiId);
    for (const reaction of swarmMessage.reactions) {
      message.insertReaction(MessageAction.fromInfo(reaction));
    }
    for (const edition of swarmMessage.editions) {
      message.insertEdition(MessageAction.fromInfo(edition));
    }
    message.updateStatus(swarmMessage, localJamiId);
    return message;
  }

  private appendParents(info: Map<string, string>): void {
    const rawParents: string | undefined = info.get(MessageAttribute.PARENTS as string);
    if (rawParents === undefined) {
      return;
    }
    for (const parentId of rawParents.split(',')) {
      if (parentId.length > 0) {
        this.parents.push(parentId);
      }
    }
  }

  private applyTimestamp(info: Map<string, string>): void {
    const timestamp: string | undefined = infoValue(info, MessageAttribute.TIMESTAMP);
    if (timestamp === undefined) {
      return;
    }
    const seconds: number = Number.parseFloat(timestamp);
    if (!Number.isNaN(seconds)) {
      // The daemon's timestamp is seconds since the epoch; Date takes milliseconds.
      this.receivedDate = new Date(seconds * 1000);
    }
  }

  /** The per-type content branch of Swift's `init(withInfo:localJamiId:)`. */
  private applyTypeContent(info: Map<string, string>): void {
    if (this.type === MessageType.TEXT) {
      const body: string | undefined = infoValue(info, MessageAttribute.BODY);
      if (body !== undefined) {
        this.content = body;
      }
      return;
    }
    if (this.type === MessageType.CALL) {
      this.applyCallContent(info);
      return;
    }
    if (this.type === MessageType.CONTACT) {
      // Swift `MessageType(rawValue: "member")` is `.contact(.add)`; an action it cannot
      // parse leaves that `.add` in place.
      const action: string | undefined = infoValue(info, MessageAttribute.ACTION);
      this.contactAction = (action === undefined ? undefined : contactActionFromRaw(action)) ??
        ContactAction.ADD;
      return;
    }
    if (this.type === MessageType.FILE_TRANSFER) {
      const fileId: string | undefined = infoValue(info, MessageAttribute.FILE_ID);
      if (fileId !== undefined) {
        this.daemonId = fileId;
      }
      const displayName: string | undefined = infoValue(info, MessageAttribute.DISPLAY_NAME);
      if (displayName !== undefined) {
        this.content = displayName;
      }
      return;
    }
    if (this.type === MessageType.INITIAL) {
      this.content = tr('generated_message_swarm_created');
      return;
    }
    if (this.type === MessageType.COLLAB_DOCUMENT) {
      // The name the document was announced with, so that a conversation whose latest
      // event is a document still has a preview line to show.
      this.content = this.collabDocumentName.length === 0 ? tr('collab_untitled')
        : this.collabDocumentName;
    }
  }

  private applyCallContent(info: Map<string, string>): void {
    const duration: string | undefined = infoValue(info, MessageAttribute.DURATION);
    const durationMillis: number = duration !== undefined ? Number.parseFloat(duration) : Number.NaN;
    if (duration === undefined || Number.isNaN(durationMillis)) {
      this.content = this.incoming ? tr('generated_message_missed_incoming_call')
        : tr('generated_message_missed_outgoing_call');
      return;
    }
    if (durationMillis < 0) {
      this.content = this.incoming ? tr('global_incoming_call')
        : tr('generated_message_outgoing_call');
      return;
    }
    const durationSeconds: number = durationMillis * 0.001;
    const time: string = durationFormatted(durationSeconds);
    this.content = this.incoming ? `${tr('global_incoming_call')} - ${time}`
      : `${tr('generated_message_outgoing_call')} - ${time}`;
  }

  /** Swift `updateStatus(with:localJamiId:)`. */
  updateStatus(swarmMessage: SwarmMessageWrap, localJamiId: string): void {
    swarmMessage.status.forEach((value: number, key: string) => {
      if (key === localJamiId) {
        return;
      }
      const status: MessageStatus | undefined = messageStatusFromRaw(value);
      if (status === undefined) {
        return;
      }
      this.statusForParticipant.set(key, status);
      /*
       The message status is set to 'displayed' if at least one participant has seen the
       message, and it is set to 'sent' if at least one participant has received it.
       */
      if (status === MessageStatus.DISPLAYED) {
        this.status = MessageStatus.DISPLAYED;
      } else if (status === MessageStatus.SENT && this.status !== MessageStatus.DISPLAYED) {
        this.status = MessageStatus.SENT;
      }
    });
    this.updateAccessibilityLabel(this.type, this.receivedDate);
  }

  /**
   * Swift `getContactInteractionString(name:)`. An own member event (uri = this account) draws
   * its own line too, as the live iPhone (Jami 4.21) does: "Invitation received", "You joined the
   * conversation." (T-1625 review). The home preview keeps `content` for those (lastMessage).
   */
  getContactInteractionString(name: string): string | undefined {
    if (this.type !== MessageType.CONTACT || this.contactAction === undefined) {
      return undefined;
    }
    return contactActionInteractionString(this.contactAction, name, this.incoming);
  }

  /** Swift `updateFrom(info:)`. */
  updateFrom(info: Map<string, string>): void {
    const body: string | undefined = infoValue(info, MessageAttribute.BODY);
    if (body !== undefined && this.type === MessageType.TEXT) {
      this.content = body;
    }
    const tid: string | undefined = infoValue(info, MessageAttribute.TID);
    if (tid !== undefined) {
      this.tid = tid;
    }
    this.applyTimestamp(info);
    const parent: string | undefined = infoValue(info, MessageAttribute.PARENT);
    if (parent !== undefined) {
      this.parentId = parent;
    }
    this.appendParents(info);
    this.updateAccessibilityLabel(this.type, this.receivedDate);
  }

  isReply(): boolean {
    return this.reply.length > 0;
  }

  /** Swift `reactionAdded(reaction:)`. */
  reactionAdded(reaction: Map<string, string>): void {
    this.insertReaction(MessageAction.fromInfo(reaction));
  }

  private insertReaction(action: MessageAction): void {
    this.reactions.set(action.id, action);
  }

  private insertEdition(action: MessageAction): void {
    this.editions.set(action.id, action);
  }

  reactionRemoved(reactionId: string): void {
    this.reactions.delete(reactionId);
  }

  isMessageDeleted(): boolean {
    if (this.type === MessageType.FILE_TRANSFER) {
      return this.tid.length === 0 && this.editions.size > 0;
    }
    if (this.type === MessageType.COLLAB_DOCUMENT) {
      // The content holds the document's name, so its emptiness says nothing. An
      // announcement is only ever edited to retire what it announces, which makes an
      // edited one a removed document.
      return this.editions.size > 0;
    }
    return this.content.length === 0 && this.editions.size > 0;
  }

  isMessageEdited(): boolean {
    return this.editions.size > 0;
  }

  /** Swift `isEmojiOnly()` — drawn large with no bubble. */
  isEmojiOnly(): boolean {
    return this.type === MessageType.TEXT && containsOnlyEmoji(this.content)
      && !this.isMessageDeleted() && !this.isMessageEdited();
  }

  /** Swift `messageUpdated(message:localJamiId:)`. */
  messageUpdated(message: SwarmMessageWrap, localJamiId: string): void {
    this.editions = new Map<string, MessageAction>();
    this.reactions = new Map<string, MessageAction>();
    this.updateFrom(message.body);
    for (const reaction of message.reactions) {
      this.insertReaction(MessageAction.fromInfo(reaction));
    }
    for (const edition of message.editions) {
      this.insertEdition(MessageAction.fromInfo(edition));
    }
    this.updateStatus(message, localJamiId);
  }

  /** Swift `messageStatusUpdated(status:messageId:jamiId:)` - messageId is unused there too. */
  messageStatusUpdated(status: MessageStatus, messageId: string, jamiId: string): void {
    this.statusForParticipant.set(jamiId, status);
    if (status <= MessageStatus.DISPLAYED && this.status < status) {
      this.status = status;
    }
  }

  statusForParticipantValue(jamiId: string): MessageStatus | undefined {
    return this.statusForParticipant.get(jamiId);
  }

  statusForParticipantSnapshot(): Map<string, MessageStatus> {
    const snapshot: Map<string, MessageStatus> = new Map<string, MessageStatus>();
    this.statusForParticipant.forEach((value: MessageStatus, key: string) => {
      snapshot.set(key, value);
    });
    return snapshot;
  }

  isSending(): boolean {
    if (this.incoming) {
      return false;
    }
    if (this.type === MessageType.TEXT) {
      return this.status === MessageStatus.SENDING;
    }
    if (this.type === MessageType.FILE_TRANSFER) {
      return this.transferStatus !== DataTransferStatus.SUCCESS
        && this.transferStatus !== DataTransferStatus.CANCELED
        && this.transferStatus !== DataTransferStatus.ERROR;
    }
    return false;
  }

  isDelivered(): boolean {
    if (this.incoming) {
      return false;
    }
    if (this.type === MessageType.TEXT) {
      return this.status === MessageStatus.SENT || this.status === MessageStatus.DISPLAYED;
    }
    if (this.type === MessageType.FILE_TRANSFER) {
      return this.transferStatus === DataTransferStatus.SUCCESS;
    }
    return false;
  }

  /* The render sites bind these by name (bindingContract: sending, delivered,
   * messageDeleted, messageEdited); Swift reads the methods directly. */
  get sending(): boolean {
    return this.isSending();
  }

  get delivered(): boolean {
    return this.isDelivered();
  }

  get messageDeleted(): boolean {
    return this.isMessageDeleted();
  }

  get messageEdited(): boolean {
    return this.isMessageEdited();
  }

  reactionsMessageIdsBySender(jamiId: string): Array<string> {
    const ids: Array<string> = [];
    this.reactions.forEach((action: MessageAction) => {
      if (action.author === jamiId) {
        ids.push(action.id);
      }
    });
    return ids;
  }

  /** Swift `updateAccessibilityLabel(for:receivedDate:)`. */
  private updateAccessibilityLabel(messageType: MessageType, receivedDate: Date): void {
    const timestamp: string = timeLabelString(receivedDate);

    if (messageType === MessageType.TEXT) {
      // Swift speaks the markdown-stripped body (MessageMarkdown.displayText). The markdown
      // helper is not in this run's module set, so the raw body is spoken until it is.
      const spokenBody: string = this.content;
      this.accessibilityLabelValue = this.content.length === 0
        ? tr1('accessibility_text_not_available', timestamp)
        : (this.incoming ? tr2('accessibility_text_received_on', spokenBody, timestamp)
          : tr2('accessibility_text_sent_on', spokenBody, timestamp));
    } else if (messageType === MessageType.CALL) {
      if (this.content.includes(' - ')) {
        const components: Array<string> = this.content.split(' - ');
        const callType: string = components[0];
        const duration: string = components[1];
        this.accessibilityLabelValue = `${callType}.${tr1('accessibility_call_lasted', duration)}`;
      } else {
        this.accessibilityLabelValue = this.content;
      }
    } else if (messageType === MessageType.FILE_TRANSFER) {
      this.accessibilityLabelValue = this.content.length === 0
        ? tr1('accessibility_file_transfer_no_name', timestamp)
        : (this.incoming ? tr2('accessibility_file_transfer_received_on', this.content, timestamp)
          : tr2('accessibility_file_transfer_sent_on', this.content, timestamp));
    } else {
      return;
    }

    // TODO: add reply target
    if (this.isReply()) {
      this.accessibilityLabelValue += `. ${tr('accessibility_in_reply')}`;
    }

    this.updateReadStatusAccessibilityLabel();
    this.updateEditedStatusAccessibilityLabel();
    this.updateDeletedStatusAccessibilityLabel();
  }

  private updateReadStatusAccessibilityLabel(): void {
    if (this.incoming) {
      return;
    }
    if (this.status === MessageStatus.DISPLAYED) {
      this.accessibilityLabelValue += `. ${tr('accessibility_message_bubble_read')}`;
    } else if (this.status === MessageStatus.SENT) {
      this.accessibilityLabelValue += tr('accessibility_message_bubble_unread');
    }
  }

  private updateEditedStatusAccessibilityLabel(): void {
    if (this.isMessageEdited()) {
      this.accessibilityLabelValue += `. ${tr('accessibility_message_bubble_edited')}`;
    }
  }

  private updateDeletedStatusAccessibilityLabel(): void {
    if (this.isMessageDeleted()) {
      this.accessibilityLabelValue = tr('accessibility_message_bubble_deleted');
    }
  }
}
