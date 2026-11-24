/*
 * Ported from Ring/Ring/Database/DBHelpers/InteractionDataHelper.swift:23-325
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One row of the local `interactions` table (legacy, non-swarm history) plus the data helper
 * that reads and writes it. SQLite.swift maps to @ohos.data.relationalStore: a `Connection`
 * becomes an `RdbStore`, a typed `SQLite.Expression` column becomes a column-name constant,
 * and a `SQLite.Expression<Bool>` filter becomes an `RdbPredicates`. Every SQLite.swift call
 * was synchronous; the RDB API is promise-based, so every query here is async.
 *
 * The legacy body encoding ("0".."5" for GeneratedMessage, "CALL"/"CONTACT" for the
 * interaction type) is carried as module-private constants: the enums themselves are
 * Ring/Ring/Database/DBManager.swift's, and DBManager ports to common/DbManager.ts, which
 * imports this module - declaring them here as well would make that import circular.
 */

import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'InteractionRow';

/** `InteractionType` raw values (DBManager.swift:144) that `migrateMessageBody` branches on. */
const INTERACTION_TYPE_CALL: string = 'CALL';
const INTERACTION_TYPE_CONTACT: string = 'CONTACT';

/** `GeneratedMessage` raw values (DBManager.swift:26) - the Int case index, as a string. */
const GENERATED_MESSAGE_OUTGOING_CALL: string = '0';
const GENERATED_MESSAGE_INCOMING_CALL: string = '1';
const GENERATED_MESSAGE_MISSED_OUTGOING_CALL: string = '2';
const GENERATED_MESSAGE_MISSED_INCOMING_CALL: string = '3';
const GENERATED_MESSAGE_CONTACT_ADDED: string = '4';
const GENERATED_MESSAGE_INVITATION_RECEIVED: string = '5';

/** `GeneratedMessageType` raw values (ConversationViewModel.swift:33) - the legacy body text. */
const LEGACY_BODY_INCOMING_CALL: string = 'Incoming call';
const LEGACY_BODY_MISSED_INCOMING_CALL: string = 'Missed incoming call';
const LEGACY_BODY_CONTACT_ADDED: string = 'Contact added';

/** Swift `struct Interaction` - one row of the `interactions` table. */
export interface InteractionRow {
  id: number;
  author: string | null;
  conversation: number;
  timestamp: number;
  duration: number;
  body: string;
  type: string;
  status: string;
  daemonID: string;
  incoming: boolean;
}

/** Swift's `(body: String, duration: Int64)` tuple; ArkTS has no tuple return. */
export interface MigratedMessageBody {
  body: string;
  duration: number;
}

/**
 * Swift `String.convertToSeconds()` (Ring/Ring/Extensions/String+Helpers.swift:97) -
 * "ss", "mm:ss" or "hh:mm:ss" to seconds. Module-private: `migrateMessageBody` is its only
 * caller, and no utility module owns the String extensions.
 */
function convertToSeconds(text: string): number {
  const parts: string[] = text.split(':');
  if (parts.length === 1) {
    return integerOrZero(parts[0]);
  }
  if (parts.length === 2) {
    return integerOrZero(parts[0]) * 60 + integerOrZero(parts[1]);
  }
  if (parts.length === 3) {
    return integerOrZero(parts[0]) * 3600 + integerOrZero(parts[1]) * 60 + integerOrZero(parts[2]);
  }
  return 0;
}

/** Swift `Int64(string) ?? 0`. */
function integerOrZero(text: string): number {
  const value: number = Number.parseInt(text.trim(), 10);
  return Number.isNaN(value) ? 0 : value;
}

export class InteractionDataHelper {
  /** Swift `let table = Table("interactions")`. */
  static readonly TABLE: string = 'interactions';

  static readonly ID: string = 'id';
  static readonly AUTHOR: string = 'author';
  static readonly DURATION: string = 'duration';
  static readonly CONVERSATION: string = 'conversation';
  static readonly TIMESTAMP: string = 'timestamp';
  static readonly BODY: string = 'body';
  static readonly TYPE: string = 'type';
  static readonly STATUS: string = 'status';
  static readonly DAEMON_ID: string = 'daemon_id';
  static readonly INCOMING: string = 'incoming';

  /** Foreign-key references. */
  static readonly TABLE_PROFILES: string = 'profiles';
  static readonly TABLE_CONVERSATIONS: string = 'conversations';
  static readonly URI: string = 'uri';

  /** Legacy-database column names, read only by `migrateToDBForAccount`. */
  static readonly AUTHOR_ID: string = 'author_id';
  static readonly CONVERSATION_ID: string = 'conversation_id';

  /**
   * Swift `func createTable(accountDb:)`. `table.create(ifNotExists:)` with two foreign keys
   * and an autoincrementing primary key, spelled as SQL because the RDB API has no builder.
   */
  async createTable(accountDb: relationalStore.RdbStore): Promise<void> {
    const sql: string = 'CREATE TABLE IF NOT EXISTS ' + InteractionDataHelper.TABLE + ' ('
      + InteractionDataHelper.ID + ' INTEGER PRIMARY KEY AUTOINCREMENT, '
      + InteractionDataHelper.AUTHOR + ' TEXT, '
      + InteractionDataHelper.CONVERSATION + ' INTEGER NOT NULL, '
      + InteractionDataHelper.TIMESTAMP + ' INTEGER NOT NULL, '
      + InteractionDataHelper.DURATION + ' INTEGER NOT NULL, '
      + InteractionDataHelper.BODY + ' TEXT NOT NULL, '
      + InteractionDataHelper.TYPE + ' TEXT NOT NULL, '
      + InteractionDataHelper.STATUS + ' TEXT NOT NULL, '
      + InteractionDataHelper.DAEMON_ID + ' TEXT NOT NULL, '
      + InteractionDataHelper.INCOMING + ' INTEGER NOT NULL, '
      + 'FOREIGN KEY(' + InteractionDataHelper.AUTHOR + ') REFERENCES '
      + InteractionDataHelper.TABLE_PROFILES + '(' + InteractionDataHelper.URI + ') ON DELETE NO ACTION, '
      + 'FOREIGN KEY(' + InteractionDataHelper.CONVERSATION + ') REFERENCES '
      + InteractionDataHelper.TABLE_CONVERSATIONS + '(' + InteractionDataHelper.ID + ') ON DELETE NO ACTION)';
    try {
      await accountDb.executeSql(sql);
    } catch (error) {
      // Swift swallows this too ("Table already exists").
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'createTable failed: %{public}s', JSON.stringify(error));
    }
  }

  /** Swift `func insert(item:dataBase:) -> Int64?` - the new row id, null on failure. */
  async insert(item: InteractionRow, dataBase: relationalStore.RdbStore): Promise<number | null> {
    try {
      const rowId: number = await dataBase.insert(InteractionDataHelper.TABLE,
        InteractionDataHelper.valuesOf(item));
      return rowId > 0 ? rowId : null;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insert failed: %{public}s', JSON.stringify(error));
      return null;
    }
  }

  /**
   * Swift `func insertIfNotExist(item:dataBase:) -> Int64?` - inserts only when no row with
   * the same conversation, body and type exists; null when one already does.
   */
  async insertIfNotExist(item: InteractionRow,
                         dataBase: relationalStore.RdbStore): Promise<number | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.CONVERSATION, item.conversation)
      .and().equalTo(InteractionDataHelper.BODY, item.body)
      .and().equalTo(InteractionDataHelper.TYPE, item.type);
    try {
      const existing: InteractionRow[] = await this.selectInteractions(predicates, dataBase);
      if (existing.length > 0) {
        return null;
      }
      const rowId: number = await dataBase.insert(InteractionDataHelper.TABLE,
        InteractionDataHelper.valuesOf(item));
      return rowId > 0 ? rowId : null;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'insertIfNotExist failed: %{public}s', JSON.stringify(error));
      return null;
    }
  }

  /** Swift `func selectInteraction(interactionId:dataBase:) throws -> Interaction?`. */
  async selectInteraction(interactionId: number,
                          dataBase: relationalStore.RdbStore): Promise<InteractionRow | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.ID, interactionId);
    const rows: InteractionRow[] = await this.selectInteractions(predicates, dataBase);
    return rows.length > 0 ? rows[0] : null;
  }

  /** Swift `func selectAll(dataBase:) throws -> [Interaction]?`. */
  async selectAll(dataBase: relationalStore.RdbStore): Promise<InteractionRow[]> {
    return await this.selectInteractions(
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE), dataBase);
  }

  /**
   * Swift `func selectInteractions(where:dataBase:) throws -> [Interaction]`. The Swift
   * `SQLite.Expression<Bool>` filter becomes the caller's `RdbPredicates`.
   */
  async selectInteractions(predicates: relationalStore.RdbPredicates,
                           dataBase: relationalStore.RdbStore): Promise<InteractionRow[]> {
    const rows: InteractionRow[] = [];
    const resultSet: relationalStore.ResultSet = await dataBase.query(predicates);
    try {
      while (true) {
        if (!resultSet.goToNextRow()) {
          break;
        }
        const authorIndex: number = resultSet.getColumnIndex(InteractionDataHelper.AUTHOR);
        const row: InteractionRow = {
          id: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.ID)),
          author: resultSet.isColumnNull(authorIndex) ? null : resultSet.getString(authorIndex),
          conversation: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.CONVERSATION)),
          timestamp: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.TIMESTAMP)),
          duration: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.DURATION)),
          body: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.BODY)),
          type: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.TYPE)),
          status: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.STATUS)),
          daemonID: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.DAEMON_ID)),
          incoming: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.INCOMING)) !== 0
        };
        rows.push(row);
      }
      return rows;
    } finally {
      resultSet.close();
    }
  }

  /** Swift `func selectInteractionsForConversation(conv:dataBase:) throws -> [Interaction]?`. */
  async selectInteractionsForConversation(conv: number,
                                          dataBase: relationalStore.RdbStore): Promise<InteractionRow[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.CONVERSATION, conv);
    return await this.selectInteractions(predicates, dataBase);
  }

  /**
   * Swift `func selectInteractionWithDaemonId(interactionDaemonID:dataBase:)` - null unless
   * exactly one row carries that daemon id (an ambiguous id is not a match).
   */
  async selectInteractionWithDaemonId(interactionDaemonID: string,
                                      dataBase: relationalStore.RdbStore): Promise<InteractionRow | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.DAEMON_ID, interactionDaemonID);
    const rows: InteractionRow[] = await this.selectInteractions(predicates, dataBase);
    if (rows.length === 0 || rows.length > 1) {
      return null;
    }
    return rows[0];
  }

  /** Swift `func updateInteractionWithDaemonID(interactionDaemonID:interactionStatus:dataBase:)`. */
  async updateInteractionWithDaemonID(interactionDaemonID: string, interactionStatus: string,
                                      dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.DAEMON_ID, interactionDaemonID);
    return await this.updateColumn(InteractionDataHelper.STATUS, interactionStatus,
      predicates, dataBase);
  }

  /** Swift `func updateInteractionStatusWithID(interactionID:interactionStatus:dataBase:)`. */
  async updateInteractionStatusWithID(interactionID: number, interactionStatus: string,
                                      dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.ID, interactionID);
    return await this.updateColumn(InteractionDataHelper.STATUS, interactionStatus,
      predicates, dataBase);
  }

  /** Swift `func updateInteractionContentWithID(daemonID:content:dataBase:)`. */
  async updateInteractionContentWithID(daemonID: string, content: string,
                                       dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.DAEMON_ID, daemonID);
    return await this.updateColumn(InteractionDataHelper.BODY, content, predicates, dataBase);
  }

  /** The `query.update(column <- value)` the three updaters share. */
  private async updateColumn(column: string, value: string,
                             predicates: relationalStore.RdbPredicates,
                             dataBase: relationalStore.RdbStore): Promise<boolean> {
    const values: relationalStore.ValuesBucket = {};
    values[column] = value;
    try {
      const updated: number = await dataBase.update(values, predicates);
      return updated > 0;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'update %{public}s failed: %{public}s', column,
        JSON.stringify(error));
      return false;
    }
  }

  /** Swift `func deleteInteractions(where:dataBase:) throws -> Bool`. */
  async deleteInteractions(predicates: relationalStore.RdbPredicates,
                           dataBase: relationalStore.RdbStore): Promise<boolean> {
    const deletedRows: number = await dataBase.delete(predicates);
    return deletedRows > 0;
  }

  /** Swift `func deleteAllInteractions(conv:dataBase:) -> Bool`. */
  async deleteAllInteractions(conv: number, dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.CONVERSATION, conv);
    try {
      return await this.deleteInteractions(predicates, dataBase);
    } catch (error) {
      return false;
    }
  }

  /** Swift `func delete(interactionId:dataBase:) -> Bool`. */
  async delete(interactionId: number, dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE);
    predicates.equalTo(InteractionDataHelper.ID, interactionId);
    try {
      return await this.deleteInteractions(predicates, dataBase);
    } catch (error) {
      return false;
    }
  }

  /** Swift `func deleteAll(dataBase:) -> Bool`. */
  async deleteAll(dataBase: relationalStore.RdbStore): Promise<boolean> {
    try {
      return await this.deleteInteractions(
        new relationalStore.RdbPredicates(InteractionDataHelper.TABLE), dataBase);
    } catch (error) {
      return false;
    }
  }

  /**
   * Swift `func migrateToDBForAccount(from:to:accountProfileId:contactsMap:)` - copies every
   * legacy row into the current schema, resolving the legacy numeric author into a
   * "ring:<hash>" uri through `contactsMap` and rewriting the message body. `accountProfileId`
   * is part of the source signature and unused in its body; kept for the same reason.
   */
  async migrateToDBForAccount(oldDB: relationalStore.RdbStore, newDB: relationalStore.RdbStore,
                              accountProfileId: number,
                              contactsMap: Map<number, string>): Promise<void> {
    const resultSet: relationalStore.ResultSet = await oldDB.query(
      new relationalStore.RdbPredicates(InteractionDataHelper.TABLE));
    try {
      while (true) {
        if (!resultSet.goToNextRow()) {
          break;
        }
        const legacyAuthorId: number =
          resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.AUTHOR_ID));
        const contact: string | undefined = contactsMap.get(legacyAuthorId);
        const uri: string | null = contact === undefined ? null : 'ring:' + contact;
        const legacyBody: string =
          resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.BODY));
        const legacyType: string =
          resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.TYPE));
        const migrated: MigratedMessageBody = this.migrateMessageBody(legacyBody, legacyType);
        const row: InteractionRow = {
          id: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.ID)),
          author: uri,
          conversation: resultSet.getLong(
            resultSet.getColumnIndex(InteractionDataHelper.CONVERSATION_ID)),
          timestamp: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.TIMESTAMP)),
          duration: migrated.duration,
          body: migrated.body,
          type: legacyType,
          status: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.STATUS)),
          daemonID: resultSet.getString(resultSet.getColumnIndex(InteractionDataHelper.DAEMON_ID)),
          incoming: resultSet.getLong(resultSet.getColumnIndex(InteractionDataHelper.INCOMING)) !== 0
        };
        const values: relationalStore.ValuesBucket = InteractionDataHelper.valuesOf(row);
        // The legacy id is carried over; `insert` (the normal path) lets SQLite assign one.
        values[InteractionDataHelper.ID] = row.id;
        await newDB.insert(InteractionDataHelper.TABLE, values);
      }
    } finally {
      resultSet.close();
    }
  }

  /**
   * Swift `func migrateMessageBody(body:type:)` - the legacy free-text body becomes a
   * generated-message code plus, for a call, its duration in seconds.
   */
  migrateMessageBody(body: string, type: string): MigratedMessageBody {
    if (type === INTERACTION_TYPE_CALL) {
      const separator: number = body.indexOf('-');
      if (separator >= 0) {
        // Swift: index(separator, offsetBy: 2) - skips "- " between label and duration.
        const time: number = convertToSeconds(body.substring(separator + 2));
        const messageBody: string = body.substring(0, separator);
        const code: string = messageBody.includes(LEGACY_BODY_INCOMING_CALL)
          ? GENERATED_MESSAGE_INCOMING_CALL : GENERATED_MESSAGE_OUTGOING_CALL;
        const called: MigratedMessageBody = { body: code, duration: time };
        return called;
      }
      const missed: MigratedMessageBody = {
        body: body === LEGACY_BODY_MISSED_INCOMING_CALL
          ? GENERATED_MESSAGE_MISSED_INCOMING_CALL : GENERATED_MESSAGE_MISSED_OUTGOING_CALL,
        duration: 0
      };
      return missed;
    }
    if (type === INTERACTION_TYPE_CONTACT) {
      const contact: MigratedMessageBody = {
        body: body === LEGACY_BODY_CONTACT_ADDED
          ? GENERATED_MESSAGE_CONTACT_ADDED : GENERATED_MESSAGE_INVITATION_RECEIVED,
        duration: 0
      };
      return contact;
    }
    const unchanged: MigratedMessageBody = { body: body, duration: 0 };
    return unchanged;
  }

  /** The insert side of the same mapping - every column the Swift insert binds. */
  static valuesOf(item: InteractionRow): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {};
    values[InteractionDataHelper.AUTHOR] = item.author;
    values[InteractionDataHelper.CONVERSATION] = item.conversation;
    values[InteractionDataHelper.TIMESTAMP] = item.timestamp;
    values[InteractionDataHelper.DURATION] = item.duration;
    values[InteractionDataHelper.BODY] = item.body;
    values[InteractionDataHelper.TYPE] = item.type;
    values[InteractionDataHelper.STATUS] = item.status;
    values[InteractionDataHelper.DAEMON_ID] = item.daemonID;
    values[InteractionDataHelper.INCOMING] = item.incoming;
    return values;
  }
}
