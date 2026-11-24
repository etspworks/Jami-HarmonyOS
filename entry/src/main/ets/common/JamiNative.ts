/*
 * The libjami NAPI binding (entry/src/main/cpp/napi_jami.cpp) and the routing of its signals
 * into the services - the HarmonyOS counterpart of the iOS adapters' delegate callbacks
 * (Ring/Ring/Bridging/*Adapter.mm -> *Service).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import jami, { StringMap, SwarmMessage } from 'libjami.so';

import { ServiceRegistry } from './ServiceRegistry';
import { ConversationEvent, ConversationEventKind } from './ConversationsService';
import {
  LookupNameResponse, LookupNameState, NameRegistrationResponse, NameRegistrationState, UserSearchResponse,
  UserSearchState
} from './NameService';
import { MessageStatus, SwarmMessageWrap } from '../model/MessageModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'JamiNative';

export { jami };

/** Record -> Map, the shape the ported services take. */
export function toMap(record: StringMap | undefined): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  if (record !== undefined) {
    Object.keys(record).forEach((key: string) => map.set(key, record[key]));
  }
  return map;
}

/** Map -> Record, the shape the binding takes. */
export function toRecord(map: Map<string, string>): StringMap {
  const record: StringMap = {};
  map.forEach((value: string, key: string) => {
    record[key] = value;
  });
  return record;
}

export function toSwarmWrap(message: SwarmMessage): SwarmMessageWrap {
  const status: Map<string, number> = new Map<string, number>();
  Object.keys(message.status).forEach((key: string) => status.set(key, message.status[key]));
  return {
    id: message.id,
    type: message.type,
    linearizedParent: message.linearizedParent,
    body: toMap(message.body),
    reactions: message.reactions.map((r: StringMap) => toMap(r)),
    editions: message.editions.map((e: StringMap) => toMap(e)),
    status: status
  };
}

function lookupState(raw: number): LookupNameState {
  switch (raw) {
    case 0: return LookupNameState.FOUND;
    case 1: return LookupNameState.INVALID_NAME;
    case 2: return LookupNameState.NOT_FOUND;
    default: return LookupNameState.ERROR;
  }
}

function userSearchState(raw: number): UserSearchState {
  switch (raw) {
    case 0: return UserSearchState.FOUND;
    case 1: return UserSearchState.INVALID_NAME;
    case 2: return UserSearchState.NOT_FOUND;
    default: return UserSearchState.ERROR;
  }
}

function registrationState(raw: number): NameRegistrationState {
  switch (raw) {
    case 0: return NameRegistrationState.SUCCESS;
    case 1: return NameRegistrationState.INVALID_NAME;
    case 2: return NameRegistrationState.ALREADY_TAKEN;
    default: return NameRegistrationState.ERROR;
  }
}

function str(payload: Record<string, Object>, key: string): string {
  const value: Object | undefined = payload[key];
  return value === undefined ? '' : value as string;
}

function num(payload: Record<string, Object>, key: string): number {
  const value: Object | undefined = payload[key];
  return value === undefined ? 0 : value as number;
}

function conversationEvent(kind: ConversationEventKind, payload: Record<string, Object>): ConversationEvent {
  const event: ConversationEvent = new ConversationEvent(kind);
  event.accountId = str(payload, 'accountId');
  event.conversationId = str(payload, 'conversationId');
  return event;
}

/** ConversationsManager (owned by the ability, not the registry) takes account messages. */
let accountMessageHandler: ((payloads: Map<string, string>, from: string, messageId: string,
  accountId: string) => void) | null = null;

export function setAccountMessageHandler(handler: ((payloads: Map<string, string>, from: string,
  messageId: string, accountId: string) => void) | null): void {
  accountMessageHandler = handler;
}

/** Swift: each adapter delegate method forwarded its signal to one service method. */
function route(name: string, payload: Record<string, Object>): void {
  const registry: ServiceRegistry = ServiceRegistry.shared();
  const deliver = (event: ConversationEvent): void => registry.conversationsService.eventSource.deliver(event);
  switch (name) {
    case 'AccountsChanged':
      registry.accountService.accountsChanged();
      break;
    case 'AccountDetailsChanged':
      registry.accountService.accountDetailsChanged(str(payload, 'accountId'),
        toMap(payload['details'] as StringMap));
      break;
    case 'VolatileDetailsChanged':
      registry.accountService.accountVoaltileDetailsChanged(str(payload, 'accountId'),
        toMap(payload['details'] as StringMap));
      break;
    case 'RegistrationStateChanged':
      registry.accountService.registrationStateChanged(str(payload, 'accountId'), str(payload, 'state'));
      break;
    case 'RegisteredNameFound':
      registry.nameService.registeredNameFound(new LookupNameResponse(str(payload, 'accountId'),
        lookupState(num(payload, 'state')), str(payload, 'address'), str(payload, 'name'), str(payload, 'query')));
      break;
    case 'NameRegistrationEnded':
      registry.nameService.nameRegistrationEnded(new NameRegistrationResponse(str(payload, 'accountId'),
        registrationState(num(payload, 'state')), '', str(payload, 'name')));
      break;
    case 'IncomingTrustRequest':
      registry.requestsService.incomingTrustRequestReceived(str(payload, 'from'), str(payload, 'accountId'),
        str(payload, 'conversationId'), new Uint8Array(payload['payload'] as ArrayBuffer),
        new Date(num(payload, 'received') * 1000));
      break;
    case 'ConversationRequestReceived':
      registry.requestsService.conversationRequestReceived(str(payload, 'conversationId'),
        str(payload, 'accountId'), toMap(payload['metadata'] as StringMap));
      break;
    case 'ContactAdded':
      registry.contactsService.contactAdded(str(payload, 'uri'), str(payload, 'accountId'),
        payload['confirmed'] as boolean);
      break;
    case 'ContactRemoved':
      registry.contactsService.contactRemoved(str(payload, 'uri'), str(payload, 'accountId'),
        payload['banned'] as boolean);
      break;
    case 'ConversationReady':
      deliver(conversationEvent(ConversationEventKind.CONVERSATION_READY, payload));
      break;
    case 'ConversationRemoved':
      deliver(conversationEvent(ConversationEventKind.CONVERSATION_REMOVED, payload));
      break;
    case 'ConversationRequestDeclined':
      deliver(conversationEvent(ConversationEventKind.CONVERSATION_DECLINED, payload));
      break;
    case 'ConversationMemberEvent': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.CONVERSATION_MEMBER_EVENT, payload);
      event.memberUri = str(payload, 'memberUri');
      event.status = num(payload, 'event');
      deliver(event);
      break;
    }
    case 'ConversationProfileUpdated': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.CONVERSATION_PROFILE_UPDATED, payload);
      event.profile = toMap(payload['profile'] as StringMap);
      deliver(event);
      break;
    }
    case 'ConversationPreferencesUpdated': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.CONVERSATION_PREFERENCES_UPDATED, payload);
      event.preferences = toMap(payload['preferences'] as StringMap);
      deliver(event);
      break;
    }
    case 'SwarmLoaded': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.SWARM_LOADED, payload);
      event.requestId = num(payload, 'requestId');
      event.messages = (payload['messages'] as SwarmMessage[]).map((m: SwarmMessage) => toSwarmWrap(m));
      deliver(event);
      break;
    }
    case 'SwarmMessageReceived':
    case 'SwarmMessageUpdated': {
      const event: ConversationEvent = conversationEvent(name === 'SwarmMessageReceived'
        ? ConversationEventKind.SWARM_MESSAGE_RECEIVED : ConversationEventKind.SWARM_MESSAGE_UPDATED, payload);
      event.message = toSwarmWrap(payload['message'] as SwarmMessage);
      deliver(event);
      break;
    }
    case 'ReactionAdded': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.REACTION_ADDED, payload);
      event.messageId = str(payload, 'messageId');
      event.reaction = toMap(payload['reaction'] as StringMap);
      deliver(event);
      break;
    }
    case 'ReactionRemoved': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.REACTION_REMOVED, payload);
      event.messageId = str(payload, 'messageId');
      event.reactionId = str(payload, 'reactionId');
      deliver(event);
      break;
    }
    case 'AccountMessageStatusChanged': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.MESSAGE_STATUS_CHANGED, payload);
      event.peer = str(payload, 'peer');
      event.messageId = str(payload, 'messageId');
      event.messageStatus = num(payload, 'state') as MessageStatus;
      deliver(event);
      break;
    }
    case 'ComposingStatusChanged': {
      const event: ConversationEvent = conversationEvent(ConversationEventKind.COMPOSING_STATUS_CHANGED, payload);
      event.from = str(payload, 'from');
      event.status = num(payload, 'status');
      deliver(event);
      break;
    }
    case 'IncomingCall':
      registry.callService.callEvents.receivingCall(str(payload, 'accountId'), str(payload, 'callId'),
        str(payload, 'from'), mapList(payload['mediaList']));
      break;
    case 'CallStateChanged':
      registry.callService.callEvents.didChangeCallState(str(payload, 'callId'), str(payload, 'state'),
        str(payload, 'accountId'), num(payload, 'code'));
      break;
    case 'MediaNegotiationStatus':
      registry.callService.callEvents.didChangeMediaNegotiationStatus(str(payload, 'callId'),
        str(payload, 'event'), mapList(payload['mediaList']));
      break;
    case 'MediaChangeRequested':
      registry.callService.callEvents.didReceiveMediaChangeRequest(str(payload, 'accountId'),
        str(payload, 'callId'), mapList(payload['mediaList']));
      break;
    case 'PeerHold':
      registry.callService.callEvents.callPlacedOnHold(str(payload, 'callId'), payload['hold'] as boolean);
      break;
    case 'AudioMuted':
      registry.callService.callEvents.audioMuted(str(payload, 'callId'), payload['muted'] as boolean);
      break;
    case 'VideoMuted':
      registry.callService.callEvents.videoMuted(str(payload, 'callId'), payload['muted'] as boolean);
      break;
    case 'ConferenceCreated':
      registry.callService.callEvents.conferenceCreated(str(payload, 'confId'), str(payload, 'conversationId'),
        str(payload, 'accountId'));
      break;
    case 'ConferenceChanged':
      registry.callService.callEvents.conferenceChanged(str(payload, 'confId'), str(payload, 'accountId'),
        str(payload, 'state'), jami.getParticipantList(str(payload, 'accountId'), str(payload, 'confId')));
      break;
    case 'ConferenceRemoved':
      registry.callService.callEvents.conferenceRemoved(str(payload, 'confId'));
      break;
    case 'OnConferenceInfosUpdated':
      registry.callService.callEvents.conferenceInfoUpdated(str(payload, 'confId'), mapList(payload['infos']));
      break;
    case 'RemoteRecordingChanged':
      registry.callService.callEvents.remoteRecordingChanged(str(payload, 'callId'), payload['state'] as boolean);
      break;
    case 'CallIncomingMessage':
      registry.callService.callEvents.didReceiveMessage(str(payload, 'callId'), str(payload, 'from'),
        toMap(payload['message'] as StringMap));
      break;
    case 'ActiveCallsChanged': {
      const account = registry.accountService.getAccount(str(payload, 'accountId'));
      if (account !== null) {
        registry.callService.activeCallsChanged(str(payload, 'conversationId'), mapList(payload['activeCalls']),
          account);
      }
      break;
    }
    case 'KnownDevicesChanged':
      registry.accountService.knownDevicesChanged(str(payload, 'accountId'), toMap(payload['devices'] as StringMap));
      break;
    case 'DeviceRevocationEnded':
      registry.accountService.deviceRevocationEnded(str(payload, 'accountId'), num(payload, 'status'),
        str(payload, 'device'));
      break;
    case 'AddDeviceStateChanged':
      registry.accountService.addDeviceStateChanged(str(payload, 'accountId'), num(payload, 'opId'),
        num(payload, 'state'), toMap(payload['detail'] as StringMap));
      break;
    case 'DeviceAuthStateChanged':
      registry.accountService.deviceAuthStateChanged(str(payload, 'accountId'), num(payload, 'state'),
        toMap(payload['detail'] as StringMap));
      break;
    case 'UserSearchEnded':
      registry.nameService.userSearchEnded(new UserSearchResponse(str(payload, 'accountId'),
        userSearchState(num(payload, 'state')), str(payload, 'query'), mapList(payload['results'])));
      break;
    case 'NewBuddyNotification':
      registry.presenceService.newBuddyNotification(str(payload, 'accountId'), str(payload, 'uri'),
        num(payload, 'status'), str(payload, 'lineStatus'));
      break;
    case 'ProfileReceived': {
      // Swift ConversationsManager.profileReceived: our own vCard (another device) or a peer's.
      const accountId: string = str(payload, 'accountId');
      const from: string = str(payload, 'from');
      const account = registry.accountService.getAccount(accountId);
      if (account !== null && (from.length === 0 || from === account.jamiId)) {
        registry.profileService.accountProfileUpdated(accountId);
      } else {
        registry.profileService.profileReceived(from, accountId, str(payload, 'path'));
      }
      break;
    }
    case 'IncomingAccountMessage':
      if (accountMessageHandler !== null) {
        accountMessageHandler(toMap(payload['payloads'] as StringMap), str(payload, 'from'),
          str(payload, 'messageId'), str(payload, 'accountId'));
      }
      break;
    case 'PeerServicesReceived':
      registry.peerSharingService.peerServicesReceived(num(payload, 'requestId'), str(payload, 'accountId'),
        str(payload, 'peerId'), num(payload, 'status'), str(payload, 'servicesJson'));
      break;
    case 'ServiceTunnelOpened':
      registry.peerSharingService.serviceTunnelOpened(str(payload, 'accountId'), str(payload, 'tunnelId'),
        num(payload, 'localPort'));
      break;
    case 'ServiceTunnelClosed':
      registry.peerSharingService.serviceTunnelClosed(str(payload, 'accountId'), str(payload, 'tunnelId'),
        str(payload, 'reason'));
      break;
    case 'MessageSend':
      registry.systemService.messageReceived(str(payload, 'message'));
      break;
    case 'DataTransferEvent':
      registry.dataTransferService.dataTransferEvent(str(payload, 'fileId'), num(payload, 'eventCode'),
        str(payload, 'accountId'), str(payload, 'conversationId'), str(payload, 'interactionId'));
      break;
    case 'DecodingStarted':
      registry.videoService.decodingStarted(str(payload, 'sinkId'));
      break;
    case 'DecodingStopped':
      registry.videoService.decodingStopped(str(payload, 'sinkId'));
      break;
    case 'SinkFrameSize':
      registry.videoService.frameSizeChanged(str(payload, 'sinkId'), num(payload, 'width'),
        num(payload, 'height'));
      break;
    case 'StartCapture':
      registry.videoService.startCapture(str(payload, 'device'));
      break;
    case 'StopCapture':
      registry.videoService.stopCapture(str(payload, 'device'));
      break;
    // Swift CollaborationAdapter.mm: the six ConversationSignal::Collaborative* callbacks, plus
    // CollaborativeDocumentReplicated (T-1634).
    case 'CollaborativeDocumentUpdate':
      registry.collaborationService.documentUpdate(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), new Uint8Array(payload['update'] as ArrayBuffer));
      break;
    case 'CollaborativeAwarenessChanged':
      registry.collaborationService.awarenessChanged(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), str(payload, 'peerId'), num(payload, 'clientId'), str(payload, 'state'));
      break;
    case 'CollaborativeParticipantLeft':
      registry.collaborationService.participantLeft(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), str(payload, 'peerId'), num(payload, 'clientId'));
      break;
    case 'CollaborativeDocumentRenamed':
      registry.collaborationService.documentRenamed(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), str(payload, 'name'));
      break;
    case 'CollaborativeDocumentRemoved':
      registry.collaborationService.documentRemoved(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), payload['everywhere'] as boolean);
      break;
    case 'CollaborativeAttachmentAdded':
      registry.collaborationService.attachmentAdded(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), str(payload, 'attachmentId'));
      break;
    case 'CollaborativeDocumentReplicated':
      registry.collaborationService.documentReplicated(str(payload, 'accountId'), str(payload, 'conversationId'),
        str(payload, 'documentId'), payload['stored'] as boolean);
      break;
    default:
      break;
  }
}

function mapList(value: Object | undefined): Array<Map<string, string>> {
  return value === undefined ? [] : (value as StringMap[]).map((m: StringMap) => toMap(m));
}

/** libjami's data directory: XDG_DATA_HOME (`<root>/data`, set by the binding) + `/jami`. */
export function jamiDataPath(filesDir: string): string {
  return filesDir + '/jami/data/jami';
}

/** Starts the daemon once; its files live under the app's sandbox `filesDir`. */
export function startJami(filesDir: string): boolean {
  const started: boolean = jami.init(filesDir + '/jami', (name: string, payload: Record<string, Object>) => {
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'signal %{public}s', name);
    try {
      route(name, payload);
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'signal %{public}s failed: %{public}s', name, JSON.stringify(error));
    }
  });
  if (started) {
    ServiceRegistry.shared().videoService.registerCameraDevices();
  }
  return started;
}
