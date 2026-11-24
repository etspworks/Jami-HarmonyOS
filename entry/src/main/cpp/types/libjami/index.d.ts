/** NAPI binding of libjami — see entry/src/main/cpp/napi_jami.cpp. */
export type StringMap = Record<string, string>;

export interface SwarmMessage {
  id: string;
  type: string;
  linearizedParent: string;
  body: StringMap;
  reactions: StringMap[];
  editions: StringMap[];
  status: Record<string, number>;
}

/** Daemon signal: `name` is the libjami signal name, `payload` its named arguments. */
export type EventHandler = (name: string, payload: Record<string, Object>) => void;

export const init: (dataDir: string, onEvent: EventHandler) => boolean;
export const version: () => string;
export const connectivityChanged: () => void;

export const getAccountList: () => string[];
export const getAccountDetails: (accountId: string) => StringMap;
export const getVolatileAccountDetails: (accountId: string) => StringMap;
export const getAccountTemplate: (accountType: string) => StringMap;
export const addAccount: (details: StringMap) => string;
/** Runs on the binding's serial worker, in call order with setCredentials; settles once written (T-1625). */
export const setAccountDetails: (accountId: string, details: StringMap) => Promise<void>;
/** Same serial worker as setAccountDetails, in call order (T-1627). */
export const setAccountActive: (accountId: string, active: boolean) => Promise<void>;
export const removeAccount: (accountId: string) => void;

export const lookupName: (accountId: string, nameserver: string, name: string) => boolean;
export const lookupAddress: (accountId: string, nameserver: string, address: string) => boolean;
export const registerName: (accountId: string, name: string, scheme: string, password: string) => boolean;

export const sendTrustRequest: (accountId: string, to: string, payload: ArrayBuffer) => void;
export const acceptTrustRequest: (accountId: string, from: string) => boolean;
export const discardTrustRequest: (accountId: string, from: string) => boolean;
export const getTrustRequests: (accountId: string) => StringMap[];
export const addContact: (accountId: string, uri: string) => void;
export const removeContact: (accountId: string, uri: string, ban: boolean) => void;
export const getContacts: (accountId: string) => StringMap[];

export const getConversations: (accountId: string) => string[];
export const getConversationRequests: (accountId: string) => StringMap[];
export const startConversation: (accountId: string) => string;
export const acceptConversationRequest: (accountId: string, conversationId: string) => void;
export const declineConversationRequest: (accountId: string, conversationId: string) => void;
export const removeConversation: (accountId: string, conversationId: string) => boolean;
export const conversationInfos: (accountId: string, conversationId: string) => StringMap;
export const getConversationMembers: (accountId: string, conversationId: string) => StringMap[];
// Collaborative documents (conversation_interface.h); Y-CRDT payloads are ArrayBuffers.
export const createCollaborativeDocument: (accountId: string, conversationId: string, name: string, mimeType: string) => string;
export const openCollaborativeDocument: (accountId: string, conversationId: string, documentId: string) => ArrayBuffer;
export const closeCollaborativeDocument: (accountId: string, conversationId: string, documentId: string) => void;
export const removeCollaborativeDocument: (accountId: string, conversationId: string, documentId: string) => boolean;
export const removeCollaborativeDocumentLocally: (accountId: string, conversationId: string, documentId: string) => boolean;
export const applyCollaborativeUpdate: (accountId: string, conversationId: string, documentId: string, update: ArrayBuffer) => void;
export const collaborativeDocumentState: (accountId: string, conversationId: string, documentId: string) => ArrayBuffer;
export const collaborativeDocumentStateAt: (accountId: string, conversationId: string, documentId: string, commitId: string) => ArrayBuffer;
export const setCollaborativeAwareness: (accountId: string, conversationId: string, documentId: string, state: string) => void;
export const setCollaborativeDocumentName: (accountId: string, conversationId: string, documentId: string, name: string) => void;
export const collaborativeDocumentName: (accountId: string, conversationId: string, documentId: string) => string;
export const getCollaborativeDocuments: (accountId: string, conversationId: string) => StringMap[];
export const getCollaborativeDocumentHistory: (accountId: string, conversationId: string, documentId: string, max: number) => StringMap[];
export const addCollaborativeAttachment: (accountId: string, conversationId: string, documentId: string, data: ArrayBuffer) => string;
export const collaborativeAttachment: (accountId: string, conversationId: string, documentId: string, attachmentId: string) => ArrayBuffer;
export const addConversationMember: (accountId: string, conversationId: string, uri: string) => void;
export const sendMessage: (accountId: string, conversationId: string, message: string, replyTo: string,
  flag: number) => void;
export const loadConversation: (accountId: string, conversationId: string, fromMessage: string, n: number) => number;
export const clearCache: (accountId: string, conversationId: string) => void;
export const setMessageDisplayed: (accountId: string, conversationUri: string, messageId: string,
  status: number) => boolean;
export const setIsComposing: (accountId: string, conversationUri: string, composing: boolean) => void;
export const countInteractions: (accountId: string, conversationId: string, from: string, to: string,
  authorUri: string) => number;
export const getConversationPreferences: (accountId: string, conversationId: string) => StringMap;
export const getContactDetails: (accountId: string, uri: string) => StringMap;

export const placeCallWithMedia: (accountId: string, to: string, mediaList: StringMap[]) => string;
export const acceptWithMedia: (accountId: string, callId: string, mediaList: StringMap[]) => boolean;
export const refuse: (accountId: string, callId: string) => boolean;
export const hangUp: (accountId: string, callId: string) => boolean;
export const hold: (accountId: string, callId: string) => boolean;
export const resume: (accountId: string, callId: string) => boolean;
export const muteLocalMedia: (accountId: string, callId: string, mediaType: string, mute: boolean) => boolean;
export const getCallDetails: (accountId: string, callId: string) => StringMap;
export const getCallList: (accountId: string) => string[];
export const answerMediaChangeRequest: (accountId: string, callId: string, mediaList: StringMap[]) => boolean;
export const playDTMF: (key: string) => void;
export const requestMediaChange: (accountId: string, callId: string, mediaList: StringMap[]) => boolean;
export const currentMediaList: (accountId: string, callId: string) => StringMap[];
export const setAudioOutputDevice: (index: number) => void;

export const attachSink: (sinkId: string, surfaceId: string) => boolean;
export const detachSink: (sinkId: string) => void;
export const setSinkScaling: (sinkId: string, policy: number) => void;
export const startCapture: (inputId: string, width: number, height: number, rotation: number) => string;
export const stopCapture: () => void;
export const openVideoInput: (path: string) => string;
export const closeVideoInput: (id: string) => boolean;
export const startLocalMediaRecorder: (videoInputId: string, filepath: string) => string;
export const stopLocalRecorder: (filepath: string) => void;
export const addVideoDevice: (name: string, devInfo: StringMap[]) => void;
export const setDefaultDevice: (name: string) => void;
export const getDefaultDevice: () => string;
export const setDecodingAccelerated: (state: boolean) => void;
export const setEncodingAccelerated: (state: boolean) => void;
export const getDecodingAccelerated: () => boolean;
export const getEncodingAccelerated: () => boolean;

export interface TransferInfo { code: number; path: string; total: number; progress: number; }
export const updateConversationInfos: (accountId: string, conversationId: string, infos: StringMap) => void;
export const setConversationPreferences: (accountId: string, conversationId: string, prefs: StringMap) => void;
export const removeConversationMember: (accountId: string, conversationId: string, uri: string) => void;
export const loadConversationUntil: (accountId: string, conversationId: string, from: string, to: string) => number;
export const sendAccountTextMessage: (accountId: string, to: string, payloads: StringMap, flags: number) => number;
export const sendFile: (accountId: string, conversationId: string, path: string, displayName: string, replyTo: string) => void;
export const downloadFile: (accountId: string, conversationId: string, interactionId: string, fileId: string,
  path: string) => boolean;
export const cancelDataTransfer: (accountId: string, conversationId: string, fileId: string) => number;
export const fileTransferInfo: (accountId: string, conversationId: string, fileId: string) => TransferInfo;
export const subscribeBuddy: (accountId: string, uri: string, flag: boolean) => void;
export const publishPresence: (accountId: string, status: boolean, note: string) => void;
export const updateProfile: (accountId: string, displayName: string, avatar: string, fileType: string, flag: number) => void;
export const searchUser: (accountId: string, query: string) => boolean;
export const changeAccountPassword: (accountId: string, oldPassword: string, newPassword: string) => boolean;
export const isPasswordValid: (accountId: string, password: string) => boolean;
export const exportToFile: (accountId: string, path: string, scheme: string, password: string) => boolean;
export const revokeDevice: (accountId: string, deviceId: string, scheme: string, password: string) => boolean;
export const getKnownRingDevices: (accountId: string) => StringMap;
export const addDevice: (accountId: string, uri: string) => number;
export const confirmAddDevice: (accountId: string, opId: number) => boolean;
export const cancelAddDevice: (accountId: string, opId: number) => boolean;
export const provideAccountAuthentication: (accountId: string, credentials: string, scheme: string) => boolean;
export const getActiveCalls: (accountId: string, conversationId: string) => StringMap[];
export const joinParticipant: (accountId: string, callId: string, account2Id: string, call2Id: string) => boolean;
export const addParticipant: (accountId: string, callId: string, account2Id: string, confId: string) => boolean;
export const joinConference: (accountId: string, confId: string, account2Id: string, conf2Id: string) => boolean;
export const hangUpConference: (accountId: string, confId: string) => boolean;
export const holdConference: (accountId: string, confId: string) => boolean;
export const resumeConference: (accountId: string, confId: string) => boolean;
export const getConferenceList: (accountId: string) => string[];
export const getParticipantList: (accountId: string, confId: string) => string[];
export const getConferenceId: (accountId: string, callId: string) => string;
export const getConferenceDetails: (accountId: string, confId: string) => StringMap;
export const getConferenceInfos: (accountId: string, confId: string) => StringMap[];
export const setConferenceLayout: (accountId: string, confId: string, layout: number) => void;
export const setModerator: (accountId: string, confId: string, uri: string, state: boolean) => void;
export const muteStream: (accountId: string, confId: string, uri: string, deviceId: string, streamId: string,
  state: boolean) => void;
export const setActiveStream: (accountId: string, confId: string, uri: string, deviceId: string, streamId: string,
  state: boolean) => void;
export const setActiveParticipant: (accountId: string, confId: string, callId: string) => void;
export const hangupParticipant: (accountId: string, confId: string, uri: string, deviceId: string) => void;
export const raiseHand: (accountId: string, confId: string, uri: string, deviceId: string, state: boolean) => void;
export const sendCallTextMessage: (accountId: string, callId: string, messages: StringMap, from: string,
  isMixed: boolean) => void;
export const toggleRecording: (accountId: string, callId: string) => boolean;
export const getCredentials: (accountId: string) => StringMap[];
export const setCredentials: (accountId: string, credentials: StringMap[]) => Promise<void>;
/** Same serial worker as setAccountDetails, in call order (T-1627). */
export const sendRegister: (accountId: string, enable: boolean) => Promise<void>;
export const queryPeerServices: (accountId: string, peerUri: string) => number;
export const openServiceTunnel: (accountId: string, peerUri: string, deviceId: string, serviceId: string,
  serviceName: string, localPort: number) => string;
export const closeServiceTunnel: (accountId: string, tunnelId: string) => boolean;
export const monitor: (continuous: boolean) => void;
