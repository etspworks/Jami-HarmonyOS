/*
 * comp_conversations_view — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 * `struct ConversationsView` (line 76).
 *
 * Swift: `ForEach(model.filteredConversations) { Button { showConversation(...) } label:
 * { ConversationRowView(model:withSeparator:false) } }.accessibilityIdentifier("conversationsItemroot")`.
 *
 * ArkUI: the rows come off svc_conversation_source's ArrayDataSource through LazyForEach
 * (CLAUDE.md rule 7) — never a literal array. Every row shares the row-root id
 * `conversationsItemroot`, which is how the replay resolves `tap-card-N` by index.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConversationViewModel } from '../common/ConversationDataSource';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { ConversationRowView, ROW_SEPARATOR_INSET } from './ConversationRow';

/** Swift `enum ConversationDestructiveAction` (Helpers/ConversationDestructiveAction.swift). */
enum DestructiveAction {
  BLOCK_CONTACT,
  REMOVE_CONTACT,
  REMOVE_CONVERSATION
}

/** Swift swipe tints: `.jamiFailure` (0xf00000), `.jamiWarning` (UIColor.orange), systemGray. */
const BLOCK_TINT: string = '#F00000';
const REMOVE_CONTACT_TINT: string = '#FF8000';
const REMOVE_CONVERSATION_TINT: string = '#8E8E93';
const SWIPE_BUTTON_WIDTH: number = 72;
const SWIPE_ICON_SIZE: number = 22;
const SWIPE_BADGE_SIZE: number = 12;

/** Swift `ConversationDestructiveAction.availableActions(for:)`. */
function availableActions(conversation: ConversationModel | null): DestructiveAction[] {
  if (conversation === null) {
    return [];
  }
  if (conversation.isSip()) {
    return [DestructiveAction.REMOVE_CONVERSATION];
  }
  const hasPeer: boolean = conversation.getParticipants().length > 0;
  if (!conversation.isSwarm()) {
    return hasPeer ? [DestructiveAction.BLOCK_CONTACT, DestructiveAction.REMOVE_CONTACT] : [];
  }
  if (conversation.isCoredialog() && hasPeer) {
    return [DestructiveAction.BLOCK_CONTACT, DestructiveAction.REMOVE_CONTACT,
    DestructiveAction.REMOVE_CONVERSATION];
  }
  return [DestructiveAction.REMOVE_CONVERSATION];
}

/** Swift `ConversationRemovalPresentation`: `.leave` unless SIP, a dialog or note-to-self. */
function isLeave(conversation: ConversationModel | null): boolean {
  return conversation !== null &&
    !(conversation.isSip() || conversation.isDialog() || conversation.isOnlyLocalParticipant());
}

/** Renders the **Conversation row** set — one row per svc_conversation_source item. */
@Component
export struct ConversationsView {
  /**
   * Swift `model.filteredConversations` — the host's filtered row set, wrapped for LazyForEach.
   * Owned by the page (svc_conversation_source narrowed by the search query); this component
   * only renders it, so the rows are never a literal array declared here.
   */
  rows: ArrayDataSource<ConversationViewModel> = new ArrayDataSource<ConversationViewModel>([]);
  /**
   * Swift `model.showConversation(withConversationViewModel:publisher:)`, which the host
   * screen turns into its ConversationState push.
   */
  onSelect?: (conversation: ConversationViewModel) => void;

  private select(conversation: ConversationViewModel): void {
    const handler: ((conversation: ConversationViewModel) => void) | undefined = this.onSelect;
    if (handler !== undefined) {
      handler(conversation);
    }
  }

  /** Closes the revealed swipe actions once one is tapped, as SwiftUI does. */
  private scroller: ListScroller = new ListScroller();

  /** Swift `swipeActionTitle(for:)` — the button's accessible name. */
  private swipeTitle(action: DestructiveAction, conversation: ConversationModel | null): Resource {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return $r('app.string.global_block');
    }
    if (action === DestructiveAction.REMOVE_CONTACT) {
      return $r('app.string.global_remove');
    }
    return isLeave(conversation) ? $r('app.string.global_leave') : $r('app.string.actions_delete_action');
  }

  /** Stable test id per action; iOS exposes the SF Symbol name, which has no ArkUI twin. */
  private swipeId(action: DestructiveAction): string {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return 'swipeBlock';
    }
    return action === DestructiveAction.REMOVE_CONTACT ? 'swipeRemove' : 'swipeDelete';
  }

  /**
   * Swift `icon(for:)`. HarmonyOS has no person.crop.circle.badge.{xmark,minus} glyph, so
   * those two are composed in swipeGlyph; this returns the badge for them.
   */
  private swipeIcon(action: DestructiveAction, conversation: ConversationModel | null): Resource {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return $r('sys.symbol.xmark_circle_fill');
    }
    if (action === DestructiveAction.REMOVE_CONTACT) {
      return $r('sys.symbol.minus_circle_fill');
    }
    return isLeave(conversation) ? $r('sys.symbol.arrow_right_circle') : $r('sys.symbol.trash_fill');
  }

  private tint(action: DestructiveAction): string {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return BLOCK_TINT;
    }
    return action === DestructiveAction.REMOVE_CONTACT ? REMOVE_CONTACT_TINT : REMOVE_CONVERSATION_TINT;
  }

  /** Swift `title(for:)`. */
  private alertTitle(action: DestructiveAction, conversation: ConversationModel): Resource {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return $r('app.string.global_block_contact');
    }
    if (action === DestructiveAction.REMOVE_CONTACT) {
      return $r('app.string.swarm_remove_contact');
    }
    return isLeave(conversation) ? $r('app.string.swarm_leave_conversation')
      : $r('app.string.swarm_remove_conversation');
  }

  /** Swift `confirmationMessage(for:)`. */
  private alertMessage(action: DestructiveAction, conversation: ConversationModel): Resource {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return $r('app.string.alerts_confirm_block_contact');
    }
    if (action === DestructiveAction.REMOVE_CONTACT) {
      return $r('app.string.alerts_confim_remove_contact');
    }
    if (conversation.isSip()) {
      return $r('app.string.alerts_confirm_delete_conversation');
    }
    if (conversation.isCoredialog()) {
      return $r('app.string.alerts_confirm_remove_one_to_one_conversation');
    }
    return isLeave(conversation) ? $r('app.string.alerts_confirm_leave_conversation')
      : $r('app.string.alerts_confirm_delete_conversation');
  }

  /** Swift `confirmationButtonTitle(for:)`. */
  private confirmTitle(action: DestructiveAction, conversation: ConversationModel): Resource {
    if (action === DestructiveAction.BLOCK_CONTACT) {
      return $r('app.string.global_block');
    }
    if (action === DestructiveAction.REMOVE_CONTACT) {
      return $r('app.string.global_remove');
    }
    return isLeave(conversation) ? $r('app.string.global_leave') : $r('app.string.global_remove');
  }

  /**
   * Swift `SwipeActionsModifier.alertForAction`: the destructive confirm runs the action,
   * `.cancel()` closes the alert and changes nothing.
   */
  private confirm(action: DestructiveAction, row: ConversationViewModel): void {
    try {
      this.scroller.closeAllSwipeActions();
    } catch (error) {
      // Only throws while the List is unbound; the alert still has to come up.
    }
    const conversation: ConversationModel | null = row.conversation;
    if (conversation === null) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.alertTitle(action, conversation),
      message: this.alertMessage(action, conversation),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: this.confirmTitle(action, conversation),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.perform(action, conversation);
        }
      }
    });
  }

  /** Swift `ConversationDestructiveActionExecutor.perform(_:on:)` with its default flags. */
  private perform(action: DestructiveAction, conversation: ConversationModel): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const peer: ConversationParticipant | undefined = conversation.getParticipants()[0];
    // Swift `removeContact` falls back to `removeConversation` without a 1:1 peer.
    if (action === DestructiveAction.REMOVE_CONVERSATION || !conversation.isCoredialog() ||
      peer === undefined) {
      if (conversation.isSip()) {
        // SIP conversations are local DB rows, not daemon swarms.
        registry.conversationsService.removeConversationFromDB(conversation, false);
      } else {
        registry.conversationsService.removeConversation(conversation.id, conversation.accountId);
      }
      return;
    }
    registry.contactsService
      .removeContact(peer.jamiId, action === DestructiveAction.BLOCK_CONTACT, conversation.accountId)
      .then((): Promise<void> => registry.conversationsService.removeConversationFromDB(conversation, false))
      .catch((error: Object): void => {
        hilog.error(0x0001, 'ConversationsView', 'contact removal failed: %{public}s', JSON.stringify(error));
      });
  }

  /**
   * person.crop.circle.badge.* stand-in: a filled person circle with the badge at its
   * bottom-leading corner, ringed in the button tint so it reads as SF Symbols' cut-out.
   */
  @Builder
  private swipeGlyph(action: DestructiveAction, conversation: ConversationModel | null) {
    if (action === DestructiveAction.REMOVE_CONVERSATION) {
      SymbolGlyph(this.swipeIcon(action, conversation))
        .fontSize(SWIPE_ICON_SIZE)
        .fontColor([Color.White])
    } else {
      Stack({ alignContent: Alignment.BottomStart }) {
        // sys person_crop_circle_fill draws a ring, not SwiftUI's solid .fill disc: compose it.
        Stack({ alignContent: Alignment.Top }) {
          Circle()
            .width(10)
            .height(10)
            .fill(this.tint(action))
            .margin({ top: 5 })
          Circle()
            .width(20)
            .height(20)
            .fill(this.tint(action))
            .margin({ top: 17 })
        }
        .width(SWIPE_ICON_SIZE + 4)
        .height(SWIPE_ICON_SIZE + 4)
        .backgroundColor(Color.White)
        .borderRadius((SWIPE_ICON_SIZE + 4) / 2)
        .clip(true)
        SymbolGlyph(this.swipeIcon(action, conversation))
          .fontSize(SWIPE_BADGE_SIZE)
          .fontColor([Color.White])
          .backgroundColor(this.tint(action))
          .borderRadius(SWIPE_BADGE_SIZE / 2)
          .offset({ x: -3, y: 2 })
      }
    }
  }

  /**
   * Swift `.swipeActions(edge: .trailing, allowsFullSwipe: false) { ForEach(actions) { … } }`.
   * SwiftUI lays the first action at the trailing edge, so the Row runs reversed: block sits
   * outermost on the right, then remove, then remove conversation.
   */
  @Builder
  private swipeActions(row: ConversationViewModel) {
    Row() {
      ForEach(availableActions(row.conversation).reverse(), (action: DestructiveAction) => {
        // SwiftUI shows a swipe Label as its icon only; the title is the accessible name.
        Button({ type: ButtonType.Normal }) {
          this.swipeGlyph(action, row.conversation)
        }
        .width(SWIPE_BUTTON_WIDTH)
        .height('100%')
        .borderRadius(0)
        .backgroundColor(this.tint(action))
        .id(this.swipeId(action))
        // One node like the SwiftUI Label; the glyph children are not separately focusable.
        .accessibilityGroup(true)
        .accessibilityText(this.swipeTitle(action, row.conversation))
        .onClick(() => {
          this.confirm(action, row);
        })
      }, (action: DestructiveAction) => `${action}`)
    }
    .height('100%')
  }

  build() {
    List({ scroller: this.scroller }) {
      LazyForEach(this.rows, (conversation: ConversationViewModel) => {
        ListItem() {
          // Swift passed withSeparator: false — the List owns the separator so it does not
          // slide with the row during a swipe.
          ConversationRowView({ model: conversation, withSeparator: false })
        }
        .id('conversationsItemroot')
        .onClick(() => {
          this.select(conversation);
        })
        .swipeAction({
          end: {
            builder: (): void => {
              this.swipeActions(conversation);
            }
          }
        })
      }, (conversation: ConversationViewModel) => conversation.key)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    // Swift `conversationRowSeparator`: a hairline under every row, inset past the avatar by
    // `Constants.defaultAvatarSize`, and none above the first row. A List divider is drawn
    // between items only, which is exactly that rule.
    .divider({
      strokeWidth: 0.5,
      color: $r('sys.color.comp_divider'),
      startMargin: ROW_SEPARATOR_INSET,
      endMargin: 0
    })
  }
}
