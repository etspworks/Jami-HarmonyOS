/*
 * Ported from Ring/Ring/Database/DBManager.swift:26-586 and
 * Ring/Ring/Database/DBContainer.swift:43-140 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The legacy (non-swarm) local history store: one SQLite database per account holding the
 * `conversations` and `interactions` tables, plus the conversion between an interaction row and
 * a `MessageModel`. NOT daemon-backed - `@ohos.data.relationalStore` is a real HarmonyOS
 * capability, so everything in this module works for real.
 *
 * FOUR THINGS DIFFER FROM SWIFT, ALL FORCED BY THE PLATFORM:
 *
 * 1. Async. SQLite.swift was synchronous and the service wrapped each call in an RxSwift
 *    `Completable`/`Observable`; `relationalStore` is promise-based, so every public method is
 *    `async`. The row helpers this module drives (model/ConversationRow.ts,
 *    model/InteractionRow.ts) are already promise-based for the same reason.
 *
 * 2. Context. `Constants.documentsPath` is an iOS app-group URL; here the paths hang off the
 *    ability's `filesDir` and the store off its database dir, and a `.ts` module cannot call
 *    `getContext()` - so the ability calls `setContext(...)` once at startup
 *    (the ProfileStore / ConversationsManager precedent). Until it does, every method logs and
 *    fails softly rather than throwing into a caller with no recovery.
 *
 * 3. Threading. `DBContainer.connectionsSemaphore` guarded the connection map against
 *    concurrent opens. An ArkTS module instance is confined to one VM thread, so there is no
 *    second writer and the semaphore is dropped rather than emulated.
 *
 * 4. Enums. `InteractionType` and its `toMessageType()` are OWNED BY `common/ConversationsService.ts`
 *    and imported here - declaring them again would make two nominally different types on one
 *    shared stream. `InteractionStatus` has no other owner, so it lives here and is exported.
 *    The `GeneratedMessage` case indexes stay module-private: only `convertToMessage` reads
 *    them, and the legacy body encoding is already restated where it is written
 *    (model/InteractionRow.ts, common/GeneratedInteractionsManager.ts).
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resourceManager } from '@kit.LocalizationKit';

import { Conversation, ConversationDataHelper } from '../model/ConversationRow';
import { InteractionDataHelper, InteractionRow } from '../model/InteractionRow';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import {
  DataTransferStatus, durationFormatted, MessageModel, MessageStatus, MessageType
} from '../model/MessageModel';
import { InteractionType, interactionTypeToMessageType, SavedMessageForConversation } from './ConversationsService';
import { JamiUri, UriType } from './JamiUri';
import { DisposeBag } from './Observable';
import { describeError } from './ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'DbManager';

/** Swift `enum DataAccessError: Error` (DBContainer.swift:43). */
export enum DataAccessError {
  DATASTORE_CONNECTION_ERROR = 'DATASTORE_CONNECTION_ERROR',
  DATABASE_MIGRATION_ERROR = 'DATABASE_MIGRATION_ERROR',
  DATABASE_ERROR = 'DATABASE_ERROR'
}

/** Swift `enum DBBridgingError: Error` (DBManager.swift:135). */
export enum DBBridgingError {
  SAVE_MESSAGE_FAILED = 'SAVE_MESSAGE_FAILED',
  GET_CONVERSATION_FAILED = 'GET_CONVERSATION_FAILED',
  UPDATE_INTERACTION_FAILED = 'UPDATE_INTERACTION_FAILED',
  DELETE_CONVERSATION_FAILED = 'DELETE_CONVERSATION_FAILED',
  GET_PROFILE_FAILED = 'GET_PROFILE_FAILED',
  DELETE_MESSAGE_FAILED = 'DELETE_MESSAGE_FAILED'
}

/**
 * Swift `enum InteractionStatus: String` (DBManager.swift:69) - the `interactions.status`
 * column value. Exported: it is this module's public vocabulary (`updateMessageStatus` takes
 * one) and no other module declares it.
 */
export enum InteractionStatus {
  INVALID = 'INVALID',
  UNKNOWN = 'UNKNOWN',
  SENDING = 'SENDING',
  FAILED = 'FAILED',
  SUCCEED = 'SUCCEED',
  DISPLAYED = 'DISPLAYED',
  UNREAD = 'UNREAD',
  TRANSFER_CREATED = 'TRANSFER_CREATED',
  TRANSFER_AWAITING = 'TRANSFER_AWAITING',
  TRANSFER_CANCELED = 'TRANSFER_CANCELED',
  TRANSFER_ONGOING = 'TRANSFER_ONGOING',
  TRANSFER_SUCCESS = 'TRANSFER_FINISHED',
  TRANSFER_ERROR = 'TRANSFER_ERROR'
}

/** Swift `InteractionStatus.toMessageStatus()`. */
export function interactionStatusToMessageStatus(status: InteractionStatus): MessageStatus {
  if (status === InteractionStatus.SENDING) {
    return MessageStatus.SENDING;
  }
  if (status === InteractionStatus.FAILED) {
    return MessageStatus.FAILURE;
  }
  if (status === InteractionStatus.SUCCEED) {
    return MessageStatus.SENT;
  }
  if (status === InteractionStatus.DISPLAYED) {
    return MessageStatus.DISPLAYED;
  }
  // Swift: .invalid, .unknown, .unread and every transfer case fall through to .unknown.
  return MessageStatus.UNKNOWN;
}

/** Swift `InteractionStatus.init(status: MessageStatus)`. */
export function interactionStatusFromMessageStatus(status: MessageStatus): InteractionStatus {
  if (status === MessageStatus.SENDING) {
    return InteractionStatus.SENDING;
  }
  if (status === MessageStatus.SENT) {
    return InteractionStatus.SUCCEED;
  }
  if (status === MessageStatus.DISPLAYED) {
    return InteractionStatus.DISPLAYED;
  }
  if (status === MessageStatus.FAILURE) {
    return InteractionStatus.FAILED;
  }
  // Swift: `.unknown` and `@unknown default` (which is where CANCELED lands) become .unknown.
  return InteractionStatus.UNKNOWN;
}

/** Swift `InteractionStatus.toDataTransferStatus()`. */
export function interactionStatusToTransferStatus(status: InteractionStatus): DataTransferStatus {
  if (status === InteractionStatus.TRANSFER_CREATED) {
    return DataTransferStatus.CREATED;
  }
  if (status === InteractionStatus.TRANSFER_AWAITING) {
    return DataTransferStatus.AWAITING;
  }
  if (status === InteractionStatus.TRANSFER_CANCELED) {
    return DataTransferStatus.CANCELED;
  }
  if (status === InteractionStatus.TRANSFER_ONGOING) {
    return DataTransferStatus.ONGOING;
  }
  if (status === InteractionStatus.TRANSFER_SUCCESS || status === InteractionStatus.DISPLAYED) {
    return DataTransferStatus.SUCCESS;
  }
  if (status === InteractionStatus.TRANSFER_ERROR) {
    return DataTransferStatus.ERROR;
  }
  return DataTransferStatus.UNKNOWN;
}

/** Swift `InteractionStatus.init(status: DataTransferStatus)`. */
export function interactionStatusFromTransferStatus(status: DataTransferStatus): InteractionStatus {
  if (status === DataTransferStatus.CREATED) {
    return InteractionStatus.TRANSFER_CREATED;
  }
  if (status === DataTransferStatus.AWAITING) {
    return InteractionStatus.TRANSFER_AWAITING;
  }
  if (status === DataTransferStatus.CANCELED) {
    return InteractionStatus.TRANSFER_CANCELED;
  }
  if (status === DataTransferStatus.ONGOING) {
    return InteractionStatus.TRANSFER_ONGOING;
  }
  if (status === DataTransferStatus.SUCCESS) {
    return InteractionStatus.TRANSFER_SUCCESS;
  }
  if (status === DataTransferStatus.ERROR) {
    return InteractionStatus.TRANSFER_ERROR;
  }
  return InteractionStatus.UNKNOWN;
}

/** Swift `InteractionStatus.init?(rawValue:)` - an unrecognized column value is not a status. */
function interactionStatusFromRaw(raw: string): InteractionStatus | null {
  const known: InteractionStatus[] = [
    InteractionStatus.INVALID, InteractionStatus.UNKNOWN, InteractionStatus.SENDING,
    InteractionStatus.FAILED, InteractionStatus.SUCCEED, InteractionStatus.DISPLAYED,
    InteractionStatus.UNREAD, InteractionStatus.TRANSFER_CREATED,
    InteractionStatus.TRANSFER_AWAITING, InteractionStatus.TRANSFER_CANCELED,
    InteractionStatus.TRANSFER_ONGOING, InteractionStatus.TRANSFER_SUCCESS,
    InteractionStatus.TRANSFER_ERROR
  ];
  for (const status of known) {
    if (raw === status) {
      return status;
    }
  }
  return null;
}

/** Swift `InteractionType.init?(rawValue:)`. */
function interactionTypeFromRaw(raw: string): InteractionType | null {
  const known: InteractionType[] = [
    InteractionType.INVALID, InteractionType.TEXT, InteractionType.CALL,
    InteractionType.CONTACT, InteractionType.I_TRANSFER, InteractionType.O_TRANSFER
  ];
  for (const type of known) {
    if (raw === type) {
      return type;
    }
  }
  return null;
}

/**
 * Swift `enum GeneratedMessage: Int` (DBManager.swift:26) - the case index is what the legacy
 * `interactions.body` column stores for a CALL or CONTACT row. Module-private: only
 * `convertToMessage` reads them back (see the header note on enum ownership).
 */
const GENERATED_OUTGOING_CALL: string = '0';
const GENERATED_INCOMING_CALL: string = '1';
const GENERATED_MISSED_OUTGOING_CALL: string = '2';
const GENERATED_MISSED_INCOMING_CALL: string = '3';
const GENERATED_CONTACT_ADDED: string = '4';
const GENERATED_INVITATION_RECEIVED: string = '5';
const GENERATED_INVITATION_ACCEPTED: string = '6';

const RING_SCHEME_PREFIX: string = 'ring:';

/** Swift `Int64.random(in: 0...10000000)` (DBManager.swift:578). */
const CONVERSATION_ID_UPPER_BOUND: number = 10000000;

/**
 * Swift `final class DBContainer` (DBContainer.swift:49). One `RdbStore` per account, opened on
 * first use and kept. Swift's `userVersion = dbVersion` becomes the store config's `name` plus
 * an explicit `PRAGMA user_version`, which is the only part of the Swift `Connection` extension
 * anything read.
 */
export class DBContainer {
  private connections: Map<string, relationalStore.RdbStore> = new Map<string, relationalStore.RdbStore>();
  private context: common.UIAbilityContext | null = null;

  /** Swift `private let dbVersion = 2`. */
  private readonly dbVersion: number = 2;

  /** CALL ONCE at startup, before any other method. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** Swift `Constants.documentsPath` - the iOS app-group documents folder. */
  private documentsPath(): string | null {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'no context: the account database cannot be reached (call setContext at startup)');
      return null;
    }
    return context.filesDir;
  }

  /**
   * Swift `func forAccount(account:) -> Connection?`. The Swift path
   * `<documents>/<accountId>/<accountId>.db` becomes the store config's `customDir` plus
   * `name`, because `relationalStore` owns the database directory.
   */
  async forAccount(account: string): Promise<relationalStore.RdbStore | null> {
    const cached: relationalStore.RdbStore | undefined = this.connections.get(account);
    if (cached !== undefined) {
      return cached;
    }
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no context: unable to open database');
      return null;
    }
    const config: relationalStore.StoreConfig = {
      name: account + '.db',
      securityLevel: relationalStore.SecurityLevel.S3,
      customDir: account
    };
    try {
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      // Swift `connections[account]??.userVersion = dbVersion`.
      store.version = this.dbVersion;
      this.connections.set(account, store);
      return store;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'Unable to open database: %{public}s',
        describeError(error as BusinessError));
      return null;
    }
  }

  /** Swift `func removeDBForAccount(account:removeFolder:)`. */
  removeDBForAccount(account: string, removeFolder: boolean): void {
    const store: relationalStore.RdbStore | undefined = this.connections.get(account);
    if (store !== undefined) {
      this.connections.delete(account);
      // The Swift just dropped the Connection; ArkTS holds an OS handle, so close it.
      store.close().catch((error: BusinessError) => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'close %{public}s failed: %{public}s', account,
          describeError(error));
      });
    }
    if (!removeFolder) {
      return;
    }
    this.removeAccountFolder(account);
  }

  /** Swift `private func accountFolderPath(accountId:)`. */
  private accountFolderPath(accountId: string): string | null {
    const documents: string | null = this.documentsPath();
    return documents === null ? null : documents + '/' + accountId + '/';
  }

  /** Swift `func contactsPath(accountId:createIfNotExists:)`. */
  contactsPath(accountId: string, createIfNotExists: boolean): string | null {
    const accountFolder: string | null = this.accountFolderPath(accountId);
    if (accountFolder === null) {
      return null;
    }
    const profilesFolder: string = accountFolder + 'profiles/';
    if (DBContainer.pathExists(profilesFolder)) {
      return profilesFolder;
    }
    if (!createIfNotExists) {
      return null;
    }
    try {
      fs.mkdirSync(profilesFolder, true);
      return profilesFolder;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'contactsPath %{public}s: %{public}s', profilesFolder,
        describeError(error as BusinessError));
      return null;
    }
  }

  /** Swift `func createAccountfolder(for:)` - the source spelling is kept. */
  createAccountfolder(accountId: string): void {
    const accountFolder: string | null = this.accountFolderPath(accountId);
    if (accountFolder === null || DBContainer.pathExists(accountFolder)) {
      return;
    }
    try {
      fs.mkdirSync(accountFolder, true);
    } catch (error) {
      // Swift's `catch { return }`.
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'createAccountfolder %{public}s: %{public}s', accountFolder,
        describeError(error as BusinessError));
    }
  }

  /** Swift `func removeContacts(accountId:)`. */
  removeContacts(accountId: string): void {
    const contacts: string | null = this.contactsPath(accountId, false);
    if (contacts === null) {
      return;
    }
    DBContainer.removeTree(contacts);
  }

  /** Swift `func removeAccountFolder(accountId:)`. */
  removeAccountFolder(accountId: string): void {
    const accountFolder: string | null = this.accountFolderPath(accountId);
    if (accountFolder === null) {
      return;
    }
    DBContainer.removeTree(accountFolder);
  }

  private static pathExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  /** Swift `try? FileManager.default.removeItem(atPath:)` - a missing folder is not an error. */
  private static removeTree(path: string): void {
    try {
      fs.rmdirSync(path);
    } catch (error) {
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'remove %{public}s: %{public}s', path,
        describeError(error as BusinessError));
    }
  }
}

/**
 * Swift `class DBManager`.
 *
 * Constructed with NO arguments (the `ServiceRegistry` contract, even though the registry does
 * not vend it): the two row helpers and the connection container are built here rather than
 * injected, because nothing else in the app holds one. The ability calls `setContext(...)` once
 * at startup and hands this instance to the four services that need it:
 *
 *   const db = new DBManager();
 *   db.setContext(this.context);
 *   registry.accountService.setDbManager(db);
 *   registry.conversationsService.setDatabase(db);
 *   registry.contactsService.setDatabase(db);
 *   registry.dataTransferService.setDatabase(db);
 */
export class DBManager {
  /** Swift `let conversationHelper: ConversationDataHelper`. */
  readonly conversationHelper: ConversationDataHelper = new ConversationDataHelper();
  /** Swift `let interactionHepler: InteractionDataHelper` - the source's spelling. */
  readonly interactionHepler: InteractionDataHelper = new InteractionDataHelper();
  /** Swift `let dbConnections: DBContainer`. */
  readonly dbConnections: DBContainer = new DBContainer();
  /** Swift `let disposeBag = DisposeBag()`. */
  readonly disposeBag: DisposeBag = new DisposeBag();

  /**
   * Swift `let defaultID: Int64 = 1` - "used to create object to save to db. When inserting in
   * table defaultID will be replaced by autoincrementedID".
   */
  readonly defaultID: number = 1;

  private context: common.UIAbilityContext | null = null;

  /** CALL ONCE at startup: `setContext(this.context)` in `EntryAbility.onCreate`. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
    this.dbConnections.setContext(context);
  }

  /** Drops every subscription this object took out. */
  dispose(): void {
    this.disposeBag.dispose();
  }

  /**
   * Swift `func createDatabaseForAccount(accountId:createFolder:) throws -> Bool`.
   *
   * `createFolder` keeps its Swift default of `false`, which is what lets this satisfy
   * `ConversationsService.ConversationsDb.createDatabaseForAccount(accountId)`.
   */
  async createDatabaseForAccount(accountId: string, createFolder: boolean = false): Promise<boolean> {
    if (createFolder) {
      this.dbConnections.createAccountfolder(accountId);
    }
    const newDB: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (newDB === null) {
      return false;
    }
    newDB.beginTransaction();
    try {
      await this.conversationHelper.createTable(newDB);
      await this.interactionHepler.createTable(newDB);
      newDB.commit();
    } catch (error) {
      newDB.rollBack();
      throw new Error(DataAccessError.DATABASE_ERROR);
    }
    return true;
  }

  /** Swift `func removeDBForAccount(accountId:removeFolder:)`. */
  removeDBForAccount(accountId: string, removeFolder: boolean): void {
    this.dbConnections.removeDBForAccount(accountId, removeFolder);
  }

  /** Swift `func createConversationsFor(contactUri:accountId:) -> String`. */
  async createConversationsFor(contactUri: string, accountId: string): Promise<string> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      return '';
    }
    try {
      const result: number | null = await this.getConversationsFor(contactUri, true, dataBase);
      // Swift `"\(result ?? -1)"`.
      return `${result === null ? -1 : result}`;
    } catch (error) {
      // Swift's `catch {}` then `return ""`.
      hilog.error(LOG_DOMAIN, LOG_TAG, 'createConversationsFor failed: %{public}s',
        describeError(error as BusinessError));
    }
    return '';
  }

  /**
   * Swift `func saveMessage(for:with:message:incoming:interactionType:duration:) ->
   * Observable<SavedMessageForConversation>`.
   *
   * `interactionType` is typed `string` rather than `InteractionType` so that this satisfies
   * `ConversationsService.ConversationsDb`; the values it carries are the enum's.
   */
  async saveMessage(accountId: string, contactUri: string, message: MessageModel,
                    incoming: boolean, interactionType: string,
                    duration: number): Promise<SavedMessageForConversation> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DataAccessError.DATASTORE_CONNECTION_ERROR);
    }
    dataBase.beginTransaction();
    try {
      const author: string | null = incoming ? contactUri : null;
      const conversationID: number | null =
        await this.getConversationsFor(contactUri, true, dataBase);
      if (conversationID === null) {
        throw new Error(DBBridgingError.SAVE_MESSAGE_FAILED);
      }
      const messageID: string | null = await this.addMessageTo(conversationID, author,
        interactionType, message, duration, dataBase);
      if (messageID === null) {
        throw new Error(DBBridgingError.SAVE_MESSAGE_FAILED);
      }
      dataBase.commit();
      const saved: SavedMessageForConversation = {
        messageID: messageID,
        conversationID: `${conversationID}`
      };
      return saved;
    } catch (error) {
      dataBase.rollBack();
      throw new Error(DBBridgingError.SAVE_MESSAGE_FAILED);
    }
  }

  /** Swift `func getConversationsObservable(for:) -> Observable<[ConversationModel]>`. */
  async getConversationsObservable(accountId: string): Promise<ConversationModel[]> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.GET_CONVERSATION_FAILED);
    }
    try {
      return await this.buildConversationsForAccount(accountId);
    } catch (error) {
      throw new Error(DBBridgingError.GET_CONVERSATION_FAILED);
    }
  }

  /** Swift `func updateMessageStatus(daemonID:withStatus:accountId:) -> Completable`. */
  async updateMessageStatus(daemonID: string, status: InteractionStatus,
                            accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
    const success: boolean = await this.interactionHepler
      .updateInteractionWithDaemonID(daemonID, status, dataBase);
    if (!success) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
  }

  /** Swift `func conversationParticipants(accountId:) -> [String]`. */
  async conversationParticipants(accountId: string): Promise<string[]> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      return [];
    }
    try {
      const conversations: Conversation[] = await this.conversationHelper.selectAll(dataBase);
      return conversations.map((conversation: Conversation) => conversation.participant);
    } catch (error) {
      // Swift `try?` - an unreadable table is an empty participant list, not a throw.
      hilog.error(LOG_DOMAIN, LOG_TAG, 'conversationParticipants failed: %{public}s',
        describeError(error as BusinessError));
      return [];
    }
  }

  /** Swift `func updateFileName(daemonID:name:accountId:) -> Completable`. */
  async updateFileName(daemonID: string, name: string, accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
    const success: boolean = await this.interactionHepler
      .updateInteractionContentWithID(daemonID, name, dataBase);
    if (!success) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
  }

  /**
   * Swift `func updateTransferStatus(daemonID:withStatus:accountId:) -> Completable`.
   * `transferStatus` is typed `string` to satisfy `ConversationsDb`; its values are
   * `DataTransferStatus`.
   */
  async updateTransferStatus(daemonID: string, transferStatus: string,
                             accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
    const status: InteractionStatus =
      interactionStatusFromTransferStatus(transferStatus as DataTransferStatus);
    const success: boolean = await this.interactionHepler
      .updateInteractionWithDaemonID(daemonID, status, dataBase);
    if (!success) {
      throw new Error(DBBridgingError.UPDATE_INTERACTION_FAILED);
    }
  }

  /**
   * Swift `func setMessagesAsRead(messagesIDs:withStatus:accountId:) -> Completable`.
   * `status` is the numeric `MessageStatus`, which is what `ConversationsDb` declares.
   */
  async setMessagesAsRead(messagesIDs: string[], status: number, accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.SAVE_MESSAGE_FAILED);
    }
    const interactionStatus: InteractionStatus =
      interactionStatusFromMessageStatus(status as MessageStatus);
    let success: boolean = true;
    for (const messageId of messagesIDs) {
      // Swift `Int64(messageId) ?? -1` - an unparseable id updates nothing.
      const parsed: number = Number.parseInt(messageId, 10);
      const interactionID: number = Number.isNaN(parsed) ? -1 : parsed;
      const updated: boolean = await this.interactionHepler
        .updateInteractionStatusWithID(interactionID, interactionStatus, dataBase);
      if (!updated) {
        success = false;
      }
    }
    if (!success) {
      throw new Error(DBBridgingError.SAVE_MESSAGE_FAILED);
    }
  }

  /** Swift `func deleteMessage(messagesId:accountId:) -> Completable`. */
  async deleteMessage(messagesId: number, accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.DELETE_MESSAGE_FAILED);
    }
    const deleted: boolean = await this.interactionHepler.delete(messagesId, dataBase);
    if (!deleted) {
      throw new Error(DBBridgingError.DELETE_MESSAGE_FAILED);
    }
  }

  /** Swift `func clearAllHistoryFor(accountId:) -> Completable`. */
  async clearAllHistoryFor(accountId: string): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
    }
    dataBase.beginTransaction();
    try {
      // Swift signalled the error and CARRIED ON to the next delete; only the final
      // `completable(.completed)` decided the outcome, so a failed delete is not fatal here
      // either - it is reported and the rest of the teardown still runs.
      const interactionsCleared: boolean = await this.interactionHepler.deleteAll(dataBase);
      const conversationsCleared: boolean = await this.conversationHelper.deleteAll(dataBase);
      this.dbConnections.removeContacts(accountId);
      dataBase.commit();
      if (!interactionsCleared || !conversationsCleared) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'clearAllHistoryFor %{public}s: nothing to delete in one of the tables', accountId);
      }
    } catch (error) {
      dataBase.rollBack();
      throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
    }
  }

  /** Swift `func clearHistoryFor(accountId:and:keepConversation:) -> Completable`. */
  async clearHistoryFor(accountId: string, participantUri: string,
                        keepConversation: boolean): Promise<void> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
    }
    dataBase.beginTransaction();
    try {
      const conversationsId: number | null =
        await this.getConversationsFor(participantUri, false, dataBase);
      if (conversationsId === null) {
        throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
      }
      const interactions: InteractionRow[] = await this.interactionHepler
        .selectInteractionsForConversation(conversationsId, dataBase);
      if (interactions.length > 0) {
        const cleared: boolean = await this.interactionHepler
          .deleteAllInteractions(conversationsId, dataBase);
        if (!cleared) {
          throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
        }
      }
      if (!keepConversation) {
        const removed: boolean = await this.conversationHelper
          .deleteConversations(conversationsId, dataBase);
        if (!removed) {
          throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
        }
      }
      dataBase.commit();
    } catch (error) {
      dataBase.rollBack();
      throw new Error(DBBridgingError.DELETE_CONVERSATION_FAILED);
    }
  }

  // MARK: Private functions

  /** Swift `private func buildConversationsForAccount(accountId:) throws -> [ConversationModel]`. */
  private async buildConversationsForAccount(accountId: string): Promise<ConversationModel[]> {
    const dataBase: relationalStore.RdbStore | null = await this.dbConnections.forAccount(accountId);
    if (dataBase === null) {
      throw new Error(DBBridgingError.GET_CONVERSATION_FAILED);
    }
    const conversationsToReturn: ConversationModel[] = [];
    const conversations: Conversation[] = await this.conversationHelper.selectAll(dataBase);
    if (conversations.length === 0) {
      // No conversation for this account: an empty list, not an error.
      return conversationsToReturn;
    }
    for (const row of conversations) {
      const conversationID: number = row.id;
      const participants: string[] | null =
        await this.getParticipantsForConversation(conversationID, dataBase);
      if (participants === null || participants.length === 0) {
        continue;
      }
      const participant: string = participants[0];
      const uriType: UriType = participant.includes(RING_SCHEME_PREFIX) ? UriType.RING : UriType.SIP;
      const uri: JamiUri = JamiUri.fromInfoHash(uriType, participant);
      const participantHash: string | null = uri.hash;
      const conversationModel: ConversationModel = ConversationModel.withParticipantUri(
        participantHash === null ? participant : participantHash, accountId,
        uriType === UriType.SIP ? ConversationType.SIP : ConversationType.NON_SWARM);
      conversationModel.id = `${conversationID}`;
      const messages: MessageModel[] = [];
      const interactions: InteractionRow[] = await this.interactionHepler
        .selectInteractionsForConversation(conversationID, dataBase);
      let lastMessage: MessageModel | null = null;
      for (const interaction of interactions) {
        const author: string = interaction.author === participant ? participant : '';
        const message: MessageModel | null = this.convertToMessage(interaction, author);
        if (message === null) {
          continue;
        }
        messages.push(message);
        if (lastMessage === null
          || lastMessage.receivedDate.getTime() < message.receivedDate.getTime()) {
          lastMessage = message;
        }
      }
      conversationModel.messages = messages;
      conversationModel.lastMessage = lastMessage;
      conversationsToReturn.push(conversationModel);
    }
    return conversationsToReturn;
  }

  /** Swift `private func getParticipantsForConversation(conversationID:dataBase:)`. */
  private async getParticipantsForConversation(conversationID: number,
                                               dataBase: relationalStore.RdbStore): Promise<string[] | null> {
    const conversations: Conversation[] =
      await this.conversationHelper.selectConversations(conversationID, dataBase);
    return conversations.map((conversation: Conversation) => conversation.participant);
  }

  /** Swift `private func convertToMessage(interaction:author:) -> MessageModel?`. */
  private convertToMessage(interaction: InteractionRow, author: string): MessageModel | null {
    const type: InteractionType | null = interactionTypeFromRaw(interaction.type);
    if (type === null || type === InteractionType.INVALID) {
      // Swift returns nil for anything that is not text/contact/call/transfer.
      return null;
    }
    const content: string = (type === InteractionType.CALL || type === InteractionType.CONTACT)
      ? this.generatedMessageText(interaction.body, interaction.duration)
      : interaction.body;
    // Swift `Date(timeIntervalSince1970:)` - the column holds SECONDS, JS Date takes ms.
    const date: Date = new Date(interaction.timestamp * 1000);
    const message: MessageModel =
      new MessageModel(interaction.daemonID, date, content, author, interaction.incoming);
    const isTransfer: boolean =
      type === InteractionType.I_TRANSFER || type === InteractionType.O_TRANSFER;
    const messageType: MessageType = interactionTypeToMessageType(type);
    message.type = messageType;
    const status: InteractionStatus | null = interactionStatusFromRaw(interaction.status);
    if (status !== null) {
      if (isTransfer) {
        message.transferStatus = interactionStatusToTransferStatus(status);
      } else {
        message.status = interactionStatusToMessageStatus(status);
      }
    }
    message.id = `${interaction.id}`;
    return message;
  }

  /**
   * Swift `private func addMessageTo(conversation:author:interactionType:message:duration:
   * dataBase:) -> String?`.
   */
  private async addMessageTo(conversationID: number, author: string | null,
                             interactionType: string, message: MessageModel, duration: number,
                             dataBase: relationalStore.RdbStore): Promise<string | null> {
    let status: string = InteractionStatus.UNKNOWN;
    if (interactionType === InteractionType.O_TRANSFER) {
      status = interactionStatusFromTransferStatus(message.transferStatus);
    }
    // Swift `message.receivedDate.timeIntervalSince1970` - SECONDS, and the column is seconds.
    const timeInterval: number = Math.trunc(message.receivedDate.getTime() / 1000);
    const interaction: InteractionRow = {
      id: this.defaultID,
      author: author,
      conversation: conversationID,
      timestamp: timeInterval,
      duration: duration,
      body: message.content,
      type: interactionType,
      status: status,
      daemonID: message.daemonId,
      incoming: message.incoming
    };
    const result: number | null = await this.interactionHepler.insert(interaction, dataBase);
    return result === null ? null : `${result}`;
  }

  /** Swift `private func getConversationsFor(contactUri:createIfNotExists:dataBase:)`. */
  private async getConversationsFor(contactUri: string, createIfNotExists: boolean,
                                    dataBase: relationalStore.RdbStore): Promise<number | null> {
    const existing: Conversation[] =
      await this.conversationHelper.selectConversationsForProfile(contactUri, dataBase);
    if (existing.length > 0) {
      return existing[0].id;
    }
    if (!createIfNotExists) {
      return null;
    }
    const conversationID: number = Math.floor(Math.random() * (CONVERSATION_ID_UPPER_BOUND + 1));
    const conversationForContact: Conversation = { id: conversationID, participant: contactUri };
    const inserted: boolean =
      await this.conversationHelper.insert(conversationForContact, dataBase);
    if (!inserted) {
      return null;
    }
    const created: Conversation[] =
      await this.conversationHelper.selectConversationsForProfile(contactUri, dataBase);
    return created.length > 0 ? created[0].id : null;
  }

  /**
   * Swift `GeneratedMessage(from: body).toMessage(with: duration)` (DBManager.swift:46). The
   * legacy CALL/CONTACT rows store the case index as their body; this turns it back into
   * display text. `L10n` is a compile-time table in Swift; here it is an app string resource,
   * which needs the ResourceManager `setContext` supplied.
   */
  private generatedMessageText(code: string, durationSeconds: number): string {
    const time: string = durationFormatted(durationSeconds);
    if (code === GENERATED_CONTACT_ADDED) {
      return this.localized('generated_message_contact_added');
    }
    if (code === GENERATED_INVITATION_RECEIVED) {
      return this.localized('generated_message_non_swarm_invitation_received');
    }
    if (code === GENERATED_INVITATION_ACCEPTED) {
      return this.localized('generated_message_non_swarm_invitation_accepted');
    }
    if (code === GENERATED_MISSED_OUTGOING_CALL) {
      return this.localized('generated_message_missed_outgoing_call');
    }
    if (code === GENERATED_MISSED_INCOMING_CALL) {
      return this.localized('generated_message_missed_incoming_call');
    }
    if (code === GENERATED_OUTGOING_CALL) {
      return this.localized('generated_message_outgoing_call') + ' - ' + time;
    }
    if (code === GENERATED_INCOMING_CALL) {
      // Swift takes this one from L10n.Global, not L10n.GeneratedMessage.
      return this.localized('global_incoming_call') + ' - ' + time;
    }
    // Swift's `default: return ""`.
    return '';
  }

  private localized(name: string): string {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager; %{public}s unresolved', name);
      return '';
    }
    try {
      const manager: resourceManager.ResourceManager = context.resourceManager;
      return manager.getStringByNameSync(name);
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'string %{public}s failed: %{public}s', name,
        describeError(error as BusinessError));
      return '';
    }
  }
}
