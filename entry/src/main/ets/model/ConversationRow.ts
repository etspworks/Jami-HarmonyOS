/*
 * Ported from Ring/Ring/Database/DBHelpers/ConversationDataHepler.swift:23-153
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The `conversations` table of an account database, and the mapping between one of its rows
 * and the `Conversation` value the rest of the app uses. SQLite.swift maps to
 * `@ohos.data.relationalStore`: a `Table`/`Expression` pair becomes a table name plus a column
 * name, and a query becomes an `RdbPredicates` (or raw SQL where the Swift used a join).
 */

import relationalStore from '@ohos.data.relationalStore';

/** Swift `typealias Conversation = (id: Int64, participant: String)`. */
export interface Conversation {
  id: number;
  participant: string;
}

const RING_URI_PREFIX: string = 'ring:';

export class ConversationDataHelper {
  /** Swift `let table = Table("conversations")`. */
  readonly table: string = 'conversations';
  /** Swift `let id = SQLite.Expression<Int64>("id")`. */
  readonly id: string = 'id';
  /** Swift `let participant = SQLite.Expression<String>("participant")`. */
  readonly participant: string = 'participant';
  /** Swift `let tableProfiles = Table("profiles")` - the foreign-key target. */
  readonly tableProfiles: string = 'profiles';
  /** Swift `let uri = SQLite.Expression<String>(value: "uri")` - the referenced profile column. */
  readonly uri: string = 'uri';
  /** Swift `let participantId` - present only in the legacy database being migrated from. */
  readonly participantId: string = 'participant_id';

  /** Swift `func createTable(accountDb:)`. */
  async createTable(accountDb: relationalStore.RdbStore): Promise<void> {
    const sql: string = 'CREATE TABLE IF NOT EXISTS ' + this.table + ' ('
      + this.id + ' INTEGER, '
      + this.participant + ' TEXT, '
      + 'FOREIGN KEY(' + this.participant + ') REFERENCES '
      + this.tableProfiles + '(' + this.uri + ') ON DELETE NO ACTION)';
    await accountDb.executeSql(sql);
  }

  /** Swift `func insert(item:dataBase:)` - false when the row was not written. */
  async insert(item: Conversation, dataBase: relationalStore.RdbStore): Promise<boolean> {
    const values: relationalStore.ValuesBucket = {
      'id': item.id,
      'participant': item.participant
    };
    try {
      const rowId: number = await dataBase.insert(this.table, values);
      return rowId > 0;
    } catch (error) {
      return false;
    }
  }

  /** Swift `func delete(item:dataBase:)` - true only when exactly one row was removed. */
  async delete(item: Conversation, dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    predicates.equalTo(this.id, item.id);
    try {
      const deletedRows: number = await dataBase.delete(predicates);
      return deletedRows === 1;
    } catch (error) {
      return false;
    }
  }

  /** Swift `func selectConversations(conversationId:dataBase:)`. */
  async selectConversations(conversationId: number,
                            dataBase: relationalStore.RdbStore): Promise<Conversation[]> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    predicates.equalTo(this.id, conversationId);
    return await this.query(predicates, dataBase);
  }

  /** Swift `func selectAll(dataBase:)`. */
  async selectAll(dataBase: relationalStore.RdbStore): Promise<Conversation[]> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    return await this.query(predicates, dataBase);
  }

  /** Swift `func selectConversationsForProfile(profileUri:dataBase:)` - rethrows, as Swift did. */
  async selectConversationsForProfile(profileUri: string,
                                      dataBase: relationalStore.RdbStore): Promise<Conversation[]> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    predicates.equalTo(this.participant, profileUri);
    return await this.query(predicates, dataBase);
  }

  /** Swift `func deleteConversations(conversationID:dataBase:)`. */
  async deleteConversations(conversationID: number,
                            dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    predicates.equalTo(this.id, conversationID);
    try {
      const deleted: number = await dataBase.delete(predicates);
      return deleted > 0;
    } catch (error) {
      return false;
    }
  }

  /** Swift `func deleteAll(dataBase:)`. */
  async deleteAll(dataBase: relationalStore.RdbStore): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    try {
      const deleted: number = await dataBase.delete(predicates);
      return deleted > 0;
    } catch (error) {
      return false;
    }
  }

  /**
   * Swift `func migrateToDBForAccount(from:to:accountProfileId:contactsMap:) throws`. The legacy
   * database stored the peer as a profile row id; the new one stores the `ring:` URI, so a row
   * whose participant id is not in `contactsMap` is skipped exactly as the Swift did.
   */
  async migrateToDBForAccount(oldDB: relationalStore.RdbStore,
                              newDB: relationalStore.RdbStore,
                              accountProfileId: number,
                              contactsMap: Map<number, string>): Promise<void> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(this.table);
    predicates.notEqualTo(this.participantId, accountProfileId);
    const resultSet: relationalStore.ResultSet = await oldDB.query(predicates);
    try {
      while (resultSet.goToNextRow()) {
        const legacyParticipantId: number =
          resultSet.getLong(resultSet.getColumnIndex(this.participantId));
        const uri: string | undefined = contactsMap.get(legacyParticipantId);
        if (uri === undefined) {
          continue;
        }
        const item: Conversation = {
          id: resultSet.getLong(resultSet.getColumnIndex(this.id)),
          participant: RING_URI_PREFIX + uri
        };
        await this.insert(item, newDB);
      }
    } finally {
      resultSet.close();
    }
  }

  /** The one read path every `select…` method above goes through. */
  private async query(predicates: relationalStore.RdbPredicates,
                      dataBase: relationalStore.RdbStore): Promise<Conversation[]> {
    const conversations: Conversation[] = [];
    const resultSet: relationalStore.ResultSet = await dataBase.query(predicates);
    try {
      while (resultSet.goToNextRow()) {
        const row: Conversation = {
          id: resultSet.getLong(resultSet.getColumnIndex(this.id)),
          participant: resultSet.getString(resultSet.getColumnIndex(this.participant))
        };
        conversations.push(row);
      }
    } finally {
      resultSet.close();
    }
    return conversations;
  }
}
