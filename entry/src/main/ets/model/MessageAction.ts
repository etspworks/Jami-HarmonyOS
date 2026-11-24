/**
 * One reaction or edition attached to a message.
 *
 * Ported from `Ring/Ring/Models/MessageModel.swift:139-164` (`class MessageAction:
 * Identifiable, Equatable, Hashable`). Swift stored these in a `Set<MessageAction>`
 * hashed and compared on `id` alone; ArkTS `Set` uses reference identity, so the
 * same de-duplication is obtained by keying a `Map<string, MessageAction>` on
 * `hashKey()` — see `MessageModel.reactions` / `.editions`.
 */

/** `MessageAttributes` raw values (same source file, lines 24-41) used by `fromInfo`. */
const KEY_INTERACTION_ID: string = 'id';
const KEY_BODY: string = 'body';
const KEY_AUTHOR: string = 'author';

export class MessageAction {
  /** Swift `var id: String = ""` — the interaction id of the commit that carries the action. */
  id: string = '';
  /** Swift `var author: String = ""` — jamiId of the member who reacted or edited. */
  author: string = '';
  /** Swift `var content: String = ""` — the reaction body, or the replacement text of an edition. */
  content: string = '';

  /**
   * Swift `init(withInfo info: [String: String])`. Every field is optional in the daemon
   * payload, so a key that is absent leaves its field at the empty default, exactly as the
   * `if let` chain does.
   */
  static fromInfo(info: Map<string, string>): MessageAction {
    const action: MessageAction = new MessageAction();
    const interactionId: string | undefined = info.get(KEY_INTERACTION_ID);
    if (interactionId !== undefined) {
      action.id = interactionId;
    }
    const content: string | undefined = info.get(KEY_BODY);
    if (content !== undefined) {
      action.content = content;
    }
    const author: string | undefined = info.get(KEY_AUTHOR);
    if (author !== undefined) {
      action.author = author;
    }
    return action;
  }

  /** Swift `static func == (lhs:rhs:)` — identity is the interaction id, nothing else. */
  equals(other: MessageAction): boolean {
    return this.id === other.id;
  }

  /** Swift `func hash(into:)` — `hasher.combine(id)`. The set key, consistent with `equals`. */
  hashKey(): string {
    return this.id;
  }
}
