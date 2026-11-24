/*
 * Ported from Ring/Ring/Models/RequestModel.swift:23-157 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * An incoming contact request or swarm conversation invitation. Every value in it arrives
 * from the jami daemon as a plain string map and is stored as it came - this module parses,
 * it never fetches.
 *
 * `avatar` is the base64 payload the daemon sends (or the base64 PHOTO line of the request's
 * vCard), kept as a string. The Swift model decoded it to `Data` and re-encoded it with
 * `.base64EncodedString()` in `peerProfile`; keeping the string skips a lossless round trip
 * and matches ConversationModel.avatar, which is a string too.
 */

import { ConversationAttributes, ConversationType, conversationTypeFromDaemonMode } from './ConversationModel';
import { ConversationParticipant } from './ConversationParticipant';
import { Profile, ProfileType } from './Profile';
import { JamiUri, UriType } from '../common/JamiUri';
import { VCardUtils } from '../common/VCardUtils';

/** Swift `enum RequestType`. */
export enum RequestType {
  CONTACT = 'contact',
  CONVERSATION = 'conversation'
}

/** Swift `enum RequestKey: String` - the keys of the daemon's request map. */
export enum RequestKey {
  PAYLOAD = 'payload',
  TITLE = 'title',
  DESCRIPTION = 'description',
  AVATAR = 'avatar',
  MODE = 'mode',
  CONVERSATION_ID = 'id',
  FROM = 'from',
  RECEIVED = 'received'
}

/** `dictionary["conversationId"]` in `init(withDictionary:accountId:type:)` - not a RequestKey. */
const CONVERSATION_ID_KEY: string = 'conversationId';

/** Swift `Date(timeIntervalSince1970:)` over a daemon timestamp string, null when unparseable. */
function dateFromTimestampSeconds(raw: string): Date | null {
  const seconds: number = Number.parseFloat(raw);
  if (Number.isNaN(seconds)) {
    return null;
  }
  return new Date(seconds * 1000);
}

export class RequestModel {
  readonly accountId: string;
  conversationId: string = '';
  name: string = '';
  receivedDate: Date = new Date();
  /** Base64-encoded avatar; null when the request carried none. */
  avatar: string | null = null;
  participants: ConversationParticipant[] = [];
  conversationType: ConversationType = ConversationType.ONE_TO_ONE;
  type: RequestType;

  constructor(accountId: string, type: RequestType) {
    this.accountId = accountId;
    this.type = type;
  }

  /**
   * Swift `init(with jamiId:accountId:withPayload:receivedDate:type:conversationId:)`.
   * `payload` is the vCard text of the request (the Swift parameter was the same vCard as
   * `Data`; VCardUtils decoded it to a string before parsing it either way).
   */
  static fromPayload(jamiId: string, accountId: string, payload: string, receivedDate: Date,
                     type: RequestType, conversationId: string): RequestModel {
    const request: RequestModel = new RequestModel(accountId, type);
    request.conversationId = conversationId;
    request.participants = [new ConversationParticipant(jamiId)];
    request.receivedDate = receivedDate;
    const profile: Profile | null = VCardUtils.parseProfile(payload);
    if (profile !== null) {
      if (profile.photo !== null) {
        request.avatar = profile.photo;
      }
      if (profile.alias !== null) {
        request.name = profile.alias;
      }
    }
    return request;
  }

  /**
   * Swift `init(withDictionary:accountId:type:)` plus its convenience overload that also sets
   * `conversationId`. Pass `conversationId` to get the overload's behaviour: it is applied
   * last, exactly as the convenience initializer did.
   */
  static fromDictionary(dictionary: Map<string, string>, accountId: string, type: RequestType,
                        conversationId: string | null = null): RequestModel {
    const request: RequestModel = new RequestModel(accountId, type);
    if (request.type === RequestType.CONTACT) {
      const jamiId: string | undefined = dictionary.get(RequestKey.FROM);
      if (jamiId === undefined) {
        // Swift `guard ... else { return }` - a contact request with no sender stays bare.
        return request;
      }
      request.participants = [new ConversationParticipant(jamiId)];

      const vCard: string | undefined = dictionary.get(RequestKey.PAYLOAD);
      if (vCard !== undefined && vCard.length > 0) {
        const profile: Profile | null = VCardUtils.parseProfile(vCard);
        if (profile !== null) {
          if (profile.photo !== null) {
            request.avatar = profile.photo;
          }
          if (profile.alias !== null) {
            request.name = profile.alias;
          }
        }
      }
      const received: string | undefined = dictionary.get(RequestKey.RECEIVED);
      if (received !== undefined) {
        const date: Date | null = dateFromTimestampSeconds(received);
        if (date !== null) {
          request.receivedDate = date;
        }
      }
      const dictConversationId: string | undefined = dictionary.get(CONVERSATION_ID_KEY);
      if (dictConversationId !== undefined) {
        request.conversationId = dictConversationId;
      }
    } else {
      request.updatefrom(dictionary);
    }
    if (conversationId !== null) {
      request.conversationId = conversationId;
    }
    return request;
  }

  /** Swift `func updatefrom(dictionary: [String: String])`. */
  updatefrom(dictionary: Map<string, string>): void {
    const mode: string | undefined = dictionary.get(ConversationAttributes.MODE);
    if (mode !== undefined) {
      const conversationType: ConversationType | null = conversationTypeFromDaemonMode(mode);
      if (conversationType !== null) {
        this.conversationType = conversationType;
      }
    }

    if (this.conversationType === ConversationType.ONE_TO_ONE) {
      this.type = RequestType.CONTACT;
    }
    const conversationId: string | undefined = dictionary.get(RequestKey.CONVERSATION_ID);
    if (conversationId !== undefined) {
      this.conversationId = conversationId;
    }
    const from: string | undefined = dictionary.get(RequestKey.FROM);
    if (from !== undefined) {
      this.participants.push(new ConversationParticipant(from));
    }
    const title: string | undefined = dictionary.get(RequestKey.TITLE);
    if (title !== undefined) {
      this.name = title;
    }
    const avatar: string | undefined = dictionary.get(RequestKey.AVATAR);
    if (avatar !== undefined && avatar.length > 0) {
      // Already base64; Swift decoded it here and re-encoded it in `peerProfile`.
      this.avatar = avatar;
    }
    const received: string | undefined = dictionary.get(RequestKey.RECEIVED);
    if (received !== undefined) {
      const date: Date | null = dateFromTimestampSeconds(received);
      if (date !== null) {
        this.receivedDate = date;
      }
    }
  }

  /** Swift `func getIdentifier() -> String`. */
  getIdentifier(): string {
    if (this.type === RequestType.CONVERSATION) {
      return this.conversationId;
    }
    return this.participants.length === 0 ? '' : this.participants[0].jamiId;
  }

  /** Swift `var peerURI: String?` - only a one-to-one request has a single peer. */
  get peerURI(): string | null {
    if (!this.isCoredialog() || this.participants.length === 0) {
      return null;
    }
    return JamiUri.fromInfoHash(UriType.RING, this.participants[0].jamiId).uriString;
  }

  /** Swift `var peerProfile: Profile?` - null when the request carried no name and no avatar. */
  get peerProfile(): Profile | null {
    const uri: string | null = this.peerURI;
    if (uri === null) {
      return null;
    }
    const profile: Profile = new Profile(uri, this.name.length === 0 ? null : this.name,
      this.avatar, ProfileType.RING);
    return profile.isEmpty ? null : profile;
  }

  /** Swift `func isCoredialog() -> Bool`. */
  isCoredialog(): boolean {
    return this.conversationType === ConversationType.NON_SWARM ||
      this.conversationType === ConversationType.ONE_TO_ONE;
  }

  /** Swift `func isDialog() -> Bool`. */
  isDialog(): boolean {
    return this.participants.length === 1;
  }
}
