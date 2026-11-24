/*
 * Ported from Ring/Ring/Models/ConversationModel.swift:149-152 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One page of messages handed to the conversation view: `fromHistory` is true when the page
 * came from a history load (prepend) and false when it is newly received (append).
 * Declared in its own file because `ConversationModel` publishes it through a BehaviorRelay
 * and the call/notification layers read it without needing the conversation itself.
 */

import { MessageModel } from './MessageModel';

export class LoadedMessages {
  messages: MessageModel[];
  fromHistory: boolean;

  /** Swift memberwise `LoadedMessages(messages:fromHistory:)` - same order. */
  constructor(messages: MessageModel[], fromHistory: boolean) {
    this.messages = messages;
    this.fromHistory = fromHistory;
  }
}
