/*
 * comp_temp_conversations_view — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 * `struct TempConversationsView` (line 106): the single row for a jami id typed into the
 * search bar that has no conversation yet.
 *
 * Swift renders it only `if let conversation = model.temporaryConversation` — the same
 * conditional is the `if` below, so the row is absent (not blank) when there is none.
 */
import { ConversationViewModel } from '../common/ConversationDataSource';
import { ConversationRowView } from './ConversationRow';

@Component
export struct TempConversationsView {
  /** Swift `model.temporaryConversation` — null until the query resolves to a jami id. */
  conversation: ConversationViewModel | null = null;
  /** bindingContract row values the host resolved from the lookup/directory result. */
  titleOverride: string = '';
  subtitleOverride: string = '';
  avatarOverride: string = '';
  /** Swift `model.showConversation(withConversationViewModel:publisher:)`. */
  onSelect?: (conversation: ConversationViewModel) => void;

  private select(): void {
    const conversation: ConversationViewModel | null = this.conversation;
    const handler: ((conversation: ConversationViewModel) => void) | undefined = this.onSelect;
    if (conversation !== null && handler !== undefined) {
      handler(conversation);
    }
  }

  build() {
    Column() {
      if (this.conversation !== null) {
        ConversationRowView({
          model: this.conversation,
          withSeparator: false,
          titleOverride: this.titleOverride,
          subtitleOverride: this.subtitleOverride,
          avatarOverride: this.avatarOverride
        })
          .id('temporaryConversationRow')
          .onClick(() => {
            this.select();
          })
      }
    }
    .width('100%')
  }
}
