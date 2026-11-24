/*
 * comp_messages_list — ported from
 * .../MessageSwiftUI/Views/MessagesListView.swift `struct MessagesListView` (line 53) and its
 * extracted subviews (TypingIndicatorView 415, TemporaryConversationView 433,
 * EndedConversationView 501, SyncingConversationView 516, BlockView 579):
 *
 *   body = ZStack {
 *     conversationContentView()
 *     if showReactionsView, let reactions { ReactionsView(model:).onTapGesture { dismiss } }
 *                                           .accessibilityIdentifier("reactions_dismiss")
 *     if model.isTemporary        { TemporaryConversationView }   // + sendInvitationButton
 *     if model.isConversationEnded{ EndedConversationView }
 *   }
 *
 *   conversationContentView = ZStack {
 *     createMessagesStackView().flipped()                 // the message list, newest first
 *     if !model.atTheBottom { createScrollToBottmView() }  // "conversationScrollToBottom"
 *     if !model.isBlocked   { MessagePanelView(...) }      // the panel is gone when blocked
 *     if model.shouldShowMap{ LocationSharingView(model:) }
 *     if model.isSyncing    { SyncingConversationView }
 *     if model.isBlocked    { BlockView }                  // + "conversationUnblockContact"
 *     if callBannerViewModel.isVisible { CallBannerView }
 *   }
 *
 *   createMessagesStackView = LazyVStack { typingIndicator; ForEach(model.messagesModels) {
 *       createMessageRowView(for:) .accessibilityIdentifier("messagesItemroot")
 *       .onAppear { if last { model.loadMore() } } } }
 *
 * COMPOSITION ROOT. The screen's page (ConversationChatPage) is where every component of
 * screen_conversation is instantiated: the message row arrives here as `rowBuilder`, and the
 * call banner, the compose panel and the reactions overlay — the three siblings this ZStack
 * carried in Swift — are mounted by the page around this view, in the same slots. The nesting
 * the source defines is unchanged; only the place the instantiation is WRITTEN moved.
 *
 * The conditional branches below are the source's, and the capture shows none of them: it
 * reached this screen with an empty conversation.
 */
import { MessageContentModel } from './MessageBubble';
import { display, LengthMetrics } from '@kit.ArkUI';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView, GroupAvatarMember } from './AvatarSwiftui';
import { MessageRowModel } from './MessageRow';
import { DEFAULT_SWARM_COLOR_ARGB } from '../model/ConversationPreferences';
import { startTargetReplyAnimation } from './MessageContent';
import { ReplyTargetModel } from './ReplyHistory';

/* ── S5 metrics, the source's own (MessagesListView.swift:301-620) ─────────────────── */
/** Swift `TypingIndicatorView`: `.padding(.horizontal)` + `.padding(.vertical, 5)`. */
const TYPING_V_PADDING: number = 5;
/** Swift `TypingIndicatorView.animationInterval` — 0 to 3 trailing dots, one step each 0.5 s. */
const TYPING_DOT_INTERVAL_MS: number = 500;
/** Swift `createScrollToBottmView()`: `Image(...).font(.system(size: 16)).frame(35)` in a 45 tap area. */
const SCROLL_GLYPH_SIZE: number = 16;
const SCROLL_DISC_SIZE: number = 35;
const SCROLL_TAP_SIZE: number = 45;
/** Swift `.padding(.trailing, 5)` / `.padding(.bottom, 35)` on the scroll-to-bottom button. */
const SCROLL_TRAILING: number = 5;
const SCROLL_BOTTOM: number = 35;
/**
 * Swift `.padding(.bottom, messageContainerHeight - 30)`: the iOS list runs 30pt under the
 * compose panel, where this one stops at it, so the button's bottom inset is 30 less here.
 */
const LIST_UNDER_PANEL: number = 30;
/** Swift `scrollReserved = ScreenDimensionsManager.shared.adaptiveHeight * 1.5`. */
const SCROLL_RESERVED_SCREENS: number = 1.5;
/**
 * Swift the new-messages count over the button: `.font(.system(size: 12))`, padding 6/1,
 * `.cornerRadius(9)` with a 1pt white outline, `VStack(spacing: -10)` onto the button.
 */
const BADGE_FONT_SIZE: number = 12;
const BADGE_H_PADDING: number = 6;
const BADGE_V_PADDING: number = 1;
const BADGE_RADIUS: number = 9;
const BADGE_OVERLAP: number = 10;
/** Swift `.shadowForConversation()`: `shadow(color: quaternaryLabel, radius: 2, x: 1, y: 2)`. */
const SCROLL_SHADOW: ShadowOptions = {
  radius: 2,
  color: $r('sys.color.font_fourth'),
  offsetX: 1,
  offsetY: 2
};
/** Swift the empty-state stacks: `emptyStateSpacing = 16`, `textHorizontalPadding = 48`. */
const EMPTY_STACK_GAP: number = 16;
const EMPTY_TEXT_INSET: number = 48;
/** Swift `SyncingConversationView`: `Image(...).font(.system(size: 40)).foregroundColor(.jami)`. */
const SYNC_GLYPH_SIZE: number = 40;
/** Swift the invitation / unblock button: icon 18, `buttonIconSpacing = 6`, v-padding 10, radius 12. */
const ACTION_ICON_SIZE: number = 18;
const ACTION_ICON_GAP: number = 6;
const ACTION_V_PADDING: number = 10;
const ACTION_RADIUS: number = 12;
/** sys.symbol.paperplane_fill turned to SF `paperplane.fill`'s up-right heading. */
const PAPERPLANE_SF_ANGLE: number = 45;
/** Swift `asyncAfter(.now() + 0.1) { model.scrolledToTargetReply() }` after the scroll. */
const REPLY_TARGET_PULSE_DELAY_MS: number = 100;

/**
 * Swift `model.messagesModels`, newest first. Rows that only land on top of the loaded ones (new
 * messages) are announced as insertions at index 0, not as a reload: a reload re-lays the List
 * from its current index, shifting the history being read by a row per new message, while an
 * insertion is held off screen by `maintainVisibleContentPosition` once the list is scrolled up.
 */
export class MessageRowsDataSource implements IDataSource {
  private rows: MessageRowModel[] = [];
  private listeners: DataChangeListener[] = [];
  /** Swift `temporaryReplyTarget` — a reply target asked for before it was loaded. */
  private pendingScrollTarget: string = '';
  /** Set by the list drawing these rows: bring the row at this index into view. */
  onScrollTo?: (index: number, id: string) => void;

  /**
   * Swift `MessagesListVM.scrollToTargetReply(messageId:)`'s view half. Returns false when the
   * message is not loaded yet; the list then scrolls to it once a reload brings it in.
   */
  scrollTo(id: string): boolean {
    const index: number = this.rows.findIndex((row: MessageRowModel) => row.container.id === id);
    this.pendingScrollTarget = index < 0 ? id : '';
    if (index >= 0 && this.onScrollTo !== undefined) {
      this.onScrollTo(index, id);
    }
    return index >= 0;
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): MessageRowModel {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reload(rows: MessageRowModel[]): void {
    const old: MessageRowModel[] = this.rows;
    this.rows = rows;
    const added: number = old.length === 0 ? -1
      : rows.findIndex((row: MessageRowModel) => row.container.id === old[0].container.id);
    const prepended: boolean = added > 0 && rows.length === old.length + added;
    this.listeners.forEach((listener: DataChangeListener) => {
      if (!prepended) {
        listener.onDataReloaded();
        return;
      }
      for (let index = 0; index < added; index++) {
        listener.onDataAdd(index);
      }
      // The rows below redraw only where their key moved (read marker, delivered check).
      for (let index = added; index < rows.length; index++) {
        listener.onDataChange(index);
      }
    });
    if (this.pendingScrollTarget.length > 0) {
      this.scrollTo(this.pendingScrollTarget);
    }
  }
}

@Component
export struct MessagesListView {
  /** Swift `model.messagesModels` <- svc_conversations, paginated by `loadMore()`. */
  messages: MessageRowsDataSource = new MessageRowsDataSource();
  /** Swift `model.numberOfNewMessages` — arrivals since the list left the bottom. */
  @Prop newMessagesCount: number = 0;
  /** Swift `model.swarmColor` <- `conversation.preferences.getColor()`, `defaultSwarmColor` until set. */
  @Prop swarmColor: number = DEFAULT_SWARM_COLOR_ARGB;
  /** Swift `model.typingIndicatorText` — empty when nobody is typing. */
  @Prop typingIndicatorText: string = '';
  /** Swift `TypingIndicatorView`'s TimelineView step: the number of trailing dots. */
  @State private typingDots: number = 0;
  private typingTimer: number = -1;
  /** Swift `model.displayNameForTemporary` — the invitation line's peer name, live. */
  @Prop temporaryPeerName: string = '';
  /** Swift `model.syncMessage`. */
  syncMessage: string = '';
  /** Swift `ScrollViewReader`'s proxy and the scroll offset it reports. */
  private scroller: Scroller = new Scroller();
  /** Swift `scrollReserved` less the list's bottom edge, in vp: the scroll that hides the bottom. */
  private scrollReserved: number = 0;
  /** The temporary conversation's peer avatar <- svc_profiles. */
  @Prop temporaryPeerAvatar: string = '';

  /**
   * Swift `createMessageRowView(for:)` — the polymorphic row, composed by the page so the
   * whole message composition (row -> content -> bubble -> player -> slider) is declared in
   * one place. Called once per LazyForEach item, with that item's model.
   */
  @BuilderParam rowBuilder: (model: MessageRowModel) => void;

  /* ── the branch selectors, every one of them a conditionalVariants entry ── */
  /** conditionalVariants[empty]: no messages loaded — the captured state. */
  @Link isEmpty: boolean;
  /** conditionalVariants[typing]. */
  @Link isTyping: boolean;
  /** conditionalVariants[scrolled_up]: Swift `!model.atTheBottom`. */
  @Link isScrolledUp: boolean;
  /** conditionalVariants[temporary_conversation]: Swift `model.isTemporary`. */
  @Link isTemporaryConversation: boolean;
  /** conditionalVariants[ended]: Swift `model.isConversationEnded`. */
  @Link isEnded: boolean;
  /** conditionalVariants[syncing]: Swift `model.isSyncing`. */
  @Link isSyncing: boolean;
  /** conditionalVariants[blocked]: Swift `model.isBlocked`. */
  @Link isBlocked: boolean;

  /* ── effects, all of them the host's ── */
  onLoadMore?: () => void;
  onScrollToBottom?: () => void;
  onSendInvitation?: () => void;
  onUnblock?: () => void;

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  aboutToAppear(): void {
    // Swift `.onReceive(model.$scrollToReplyTarget) { scrollView.scrollTo(target) }`: the least
    // scroll that shows the row (the typing indicator, when shown, is the list's index 0),
    // then the target's pulse.
    this.messages.onScrollTo = (index: number, id: string): void => {
      this.scroller.scrollToIndex(index + (this.isTyping ? 1 : 0), false, ScrollAlign.AUTO);
      setTimeout(() => {
        startTargetReplyAnimation(id);
      }, REPLY_TARGET_PULSE_DELAY_MS);
    };
  }

  aboutToDisappear(): void {
    this.messages.onScrollTo = undefined;
  }

  /** Swift `TypingIndicatorView` — the peer's name with the animated dots. */
  @Builder
  private typingIndicator() {
    Row() {
      Text(this.typingIndicatorText + '.'.repeat(this.typingDots))
        // Swift `.font(.footnote).foregroundColor(Color(UIColor.secondaryLabel))`.
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
      Blank()
    }
    .width('100%')
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      top: LengthMetrics.vp(TYPING_V_PADDING),
      bottom: LengthMetrics.vp(TYPING_V_PADDING)
    })
    // Swift `.accessibilityElement().accessibilityLabel(text)` — read without the dots.
    .accessibilityGroup(true)
    .accessibilityText(this.typingIndicatorText)
    .onAppear(() => {
      this.typingTimer = setInterval(() => {
        this.typingDots = (this.typingDots + 1) % 4;
      },
        TYPING_DOT_INTERVAL_MS);
    })
    .onDisAppear(() => {
      clearInterval(this.typingTimer);
      this.typingDots = 0;
    })
  }

  /** Swift `createMessagesStackView()` — the flipped message list. */
  @Builder
  private messagesStack() {
    List({ scroller: this.scroller }) {
      if (this.isTyping) {
        ListItem() {
          this.typingIndicator()
        }
        .rotate({ angle: 180 })
      }

      LazyForEach(this.messages, (message: MessageRowModel) => {
        ListItem() {
          // comp_message_row, declared by the page.
          this.rowBuilder(message)
        }
        // Un-flips the row inside the flipped list.
        .rotate({ angle: 180 })
        .id('messagesItemroot')
      }, (message: MessageRowModel) => {
        // The row redraws when what it shows changes (edition, deletion, reaction, transfer,
        // delivery status, read receipts, the reply quote).
        const c: MessageContentModel = message.container.content;
        const reply: ReplyTargetModel | null = message.container.replyTarget;
        return `${message.container.id}|${c.content}|${c.messageDeleted}|${c.messageEdited}|` +
          (reply === null ? '' : `${reply.inReplyTo}|${reply.content}|`) +
          `${message.container.reactionsDisplay}|${c.filePath}|${c.transferText}|` +
          `${c.transferActions.join(',')}|${c.showProgress}|${c.fileProgress}|` +
          // The duration read from the file lands after the row is drawn; an audio row has no
          // ratio to change, so without it the row kept its blank duration until played (T-1720).
          `${c.hasPlayer}|${c.player.hasVideo}|${c.playerRatio}|${c.player.durationText}|${c.swarmColor}|` +
          `${message.showSentIndicator}|${message.showReceiveIndicator}|` +
          // The author's name and avatar, which a late vCard or name lookup fills in (T-0894).
          `${message.username}|${message.contactMessageText}|${message.avatar.length}|` +
          `${message.shouldDisplayAvatar}|${message.shouldDisplayName}|` +
          // The time header is re-sequenced whenever older history or a new message lands; a key
          // without it kept a row's stale header, so two opens of one chat differed (T-1657).
          `${message.shouldShowTimeString}|${message.timeString}|` +
          `${message.topSpace}|${message.bottomSpace}|` +
          message.readAvatars.map((reader: GroupAvatarMember) => `${reader.name}:${reader.photo.length}`)
            .join(',');
      })
    }
    .width('100%')
    .height('100%')
    // Swift `.flipped()` — the newest message sits at the bottom and the list grows upward.
    // The rows are newest-first, so the list is turned upside down and each row turned back.
    .listDirection(Axis.Vertical)
    .rotate({ angle: 180 })
    .backgroundColor($r('sys.color.background_primary'))
    .scrollBar(BarState.Off)
    // Swift keeps the history being read in place while new messages land under it; at the
    // bottom the newest stays in view instead.
    .maintainVisibleContentPosition(this.isScrolledUp)
    // Swift `.onAppear { if message == messagesModels.last { model.loadMore() } }` — the
    // bindingContract marks this list paginated.
    // The oldest row is the list's end, which the flip puts at the top of the screen.
    .onReachEnd(() => {
      this.fire(this.onLoadMore);
    })
    // Swift `adaptiveHeight` follows the window, so it is re-read whenever the list resizes
    // (first layout, fold, rotation, keyboard). Swift's offset is the flipped content's GLOBAL
    // minY (no "scroll" coordinate space is declared), which at rest already sits at the list's
    // bottom edge: the button shows once the scroll passes 1.5 screens minus that edge, about
    // half a screen (iOS 4.20 simulator: shown at ~525pt of scroll, hidden at ~425pt).
    .onAreaChange((oldArea: Area, newArea: Area) => {
      try {
        const listBottom: number = Number(newArea.globalPosition.y ?? 0) + Number(newArea.height);
        this.scrollReserved = SCROLL_RESERVED_SCREENS *
          this.getUIContext().px2vp(display.getDefaultDisplaySync().height) - listBottom;
      } catch (error) {
        this.scrollReserved = 0;
      }
      // A resize with no scroll (the keyboard closing) moves the threshold under a resting
      // offset; SwiftUI re-runs the preference then too (T-1682).
      this.updateAtTheBottom();
    })
    .onDidScroll(() => {
      this.updateAtTheBottom();
    })
  }

  /**
   * Swift `.onPreferenceChange(ScrollViewOffsetPreferenceKey.self)`: `atTheBottom` is an
   * offset under `scrollReserved`. The flip keeps the offset's origin at index 0, the newest.
   */
  private updateAtTheBottom(): void {
    const scrolledUp: boolean = this.scrollReserved > 0 &&
      this.scroller.currentOffset().yOffset >= this.scrollReserved;
    if (scrolledUp !== this.isScrolledUp) {
      this.isScrolledUp = scrolledUp;
    }
  }

  /** Swift `createScrollToBottmView()`. */
  @Builder
  private scrollToBottom() {
    // Swift `VStack(alignment: .trailing, spacing: -10) { count; button }`, 5pt off the
    // trailing edge and 35pt clear of the list's bottom.
    Column() {
      // Swift `if model.numberOfNewMessages > 0`: white on the swarm colour, over the button.
      if (this.newMessagesCount > 0) {
        Text(String(this.newMessagesCount))
          .fontSize(BADGE_FONT_SIZE)
          .fontColor(Color.White)
          .padding({
            start: LengthMetrics.vp(BADGE_H_PADDING),
            end: LengthMetrics.vp(BADGE_H_PADDING),
            top: LengthMetrics.vp(BADGE_V_PADDING),
            bottom: LengthMetrics.vp(BADGE_V_PADDING)
          })
          .backgroundColor(this.swarmColor)
          .borderRadius(BADGE_RADIUS)
          .border({ width: 1, color: Color.White, radius: BADGE_RADIUS })
          .shadow(SCROLL_SHADOW)
          .offset({ y: BADGE_OVERLAP })
          .zIndex(1)
      }
      // Swift: a 16pt arrow on a 35pt material disc outlined in the swarm colour, centred in
      // the button's 45pt tap area.
      // The disc is its own Stack: a SymbolGlyph framed at 35vp draws its 16vp glyph off-centre.
      // `.regular` material reads white on the light chat and dark grey on the dark one (sim
      // FFFFFF / 141414); comp_background_gray went grey / black.
      Stack() {
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(SCROLL_GLYPH_SIZE)
            .fontColor([this.swarmColor])
        }
        .width(SCROLL_DISC_SIZE)
        .height(SCROLL_DISC_SIZE)
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(SCROLL_DISC_SIZE / 2)
        .border({ width: 1, color: this.swarmColor })
        .shadow(SCROLL_SHADOW)
      }
      .id('conversationScrollToBottom')
      .width(SCROLL_TAP_SIZE)
      .height(SCROLL_TAP_SIZE)
      // Swift `scrollToTheBottom()` -> `scrollView.scrollTo("lastMessage")`, unanimated: the
      // anchor ahead of the typing indicator, i.e. offset 0 of the flipped list.
      .onClick(() => {
        this.scroller.scrollEdge(Edge.Top);
        this.fire(this.onScrollToBottom);
      })
    }
    .alignItems(HorizontalAlign.End)
    .margin({
      end: LengthMetrics.vp(SCROLL_TRAILING),
      bottom: LengthMetrics.vp(SCROLL_BOTTOM - LIST_UNDER_PANEL)
    })
  }

  /** Swift `TemporaryConversationView` — the not-yet-a-contact invitation panel. */
  @Builder
  private temporaryConversation() {
    // Swift `VStack(spacing: emptyStateSpacing)` on an opaque systemBackground.
    Column({ space: EMPTY_STACK_GAP }) {
      Blank()
      // Swift `AvatarSwiftUIView(source: factory.provider(for: jamiId, size: .conversationInfo80))`:
      // the peer's photo, else its monogram. The person.crop.circle glyph is Swift's no-participant
      // branch, which a one-to-one search result never takes.
      AvatarSwiftUIView({
        avatarData: this.temporaryPeerAvatar,
        displayText: this.temporaryPeerName,
        isGroup: false,
        avatarSize: AvatarSize.CONVERSATION_INFO_80
      })
      // Swift `L10n.Conversation.notContactLabel(model.displayNameForTemporary)`.
      Text($r('app.string.conversation_not_contact_label', this.temporaryPeerName))
        // Swift `.font(.footnote).foregroundColor(secondaryLabel).multilineTextAlignment(.center)`.
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .textAlign(TextAlign.Center)
        .padding({
          start: LengthMetrics.vp(EMPTY_TEXT_INSET),
          end: LengthMetrics.vp(EMPTY_TEXT_INSET)
        })
      // Swift: a jamiTertiaryControl pill, 12pt radius, icon in .jami, label in .label;
      // `.frame(maxWidth: .infinity)` inside `.padding(.horizontal, textHorizontalPadding)`.
      Row({ space: ACTION_ICON_GAP }) {
        SymbolGlyph($r('sys.symbol.paperplane_fill'))
          .fontSize(ACTION_ICON_SIZE)
          .fontColor([$r('app.color.jami')])
          // The HarmonyOS paperplane points straight up; SF `paperplane.fill` points up-right.
          .rotate({ angle: PAPERPLANE_SF_ANGLE })
          .accessibilityLevel('no')
        Text($r('app.string.conversation_send_invitation_button'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
      }
      .id('sendInvitationButton')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        top: LengthMetrics.vp(ACTION_V_PADDING),
        bottom: LengthMetrics.vp(ACTION_V_PADDING)
      })
      .width(`calc(100% - ${EMPTY_TEXT_INSET * 2}vp)`)
      .backgroundColor($r('app.color.jami_tertiary_control'))
      .borderRadius(ACTION_RADIUS)
      .onClick(() => {
        this.fire(this.onSendInvitation);
      })
      // Swift `Spacer(); ...; Spacer(); Spacer()`: the block sits a third of the way down.
      Blank()
      Blank()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_primary'))
  }

  /** Swift `SyncingConversationView`. */
  @Builder
  private syncingConversation() {
    Column({ space: EMPTY_STACK_GAP }) {
      // Swift `Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 40))`.
      SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
        .fontSize(SYNC_GLYPH_SIZE)
        .fontColor([$r('app.color.jami')])
        .accessibilityLevel('no')
      Text($r('app.string.conversation_syncing_title'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
      Text(this.syncMessage)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .textAlign(TextAlign.Center)
        .padding({
          start: LengthMetrics.vp(EMPTY_TEXT_INSET),
          end: LengthMetrics.vp(EMPTY_TEXT_INSET)
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_primary'))
  }

  /** Swift `BlockView` — the blocked notice with its unblock action. */
  @Builder
  private blockView() {
    Column({ space: EMPTY_STACK_GAP }) {
      Text($r('app.string.conversation_contact_blocked'))
        .width('100%')
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
      // Swift: the same jamiTertiaryControl pill as the invitation button.
      Row({ space: ACTION_ICON_GAP }) {
        SymbolGlyph($r('sys.symbol.person_badge_plus'))
          .fontSize(ACTION_ICON_SIZE)
          .fontColor([$r('app.color.jami')])
          .accessibilityLevel('no')
        Text($r('app.string.account_page_unblock_contact'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
      }
      .id('conversationUnblockContact')
      .alignItems(VerticalAlign.Center)
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        top: LengthMetrics.vp(ACTION_V_PADDING),
        bottom: LengthMetrics.vp(ACTION_V_PADDING)
      })
      .backgroundColor($r('app.color.jami_tertiary_control'))
      .borderRadius(ACTION_RADIUS)
      .onClick(() => {
        this.fire(this.onUnblock);
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .backgroundColor($r('sys.color.background_primary'))
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // ── conversationContentView() ──────────────────────────────────────────────────
      Stack({ alignContent: Alignment.BottomEnd }) {
        this.messagesStack()

        // Swift `if !model.atTheBottom { createScrollToBottmView() }`.
        if (this.isScrolledUp) {
          this.scrollToBottom()
        }
      }
      .width('100%')
      .height('100%')

      if (this.isSyncing) {
        this.syncingConversation()
      }

      if (this.isBlocked) {
        this.blockView()
      }

      // Swift: the temporary / ended panels cover the conversation entirely, so they are
      // exclusive with the empty message list rather than drawn beside it.
      if (this.isTemporaryConversation) {
        this.temporaryConversation()
      } else if (this.isEnded) {
        // Swift `EndedConversationView` — a secondarySystemBackground banner at the top, the
        // conversation still visible beneath it.
        Column() {
          Text($r('app.string.swarm_conversation_ended'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
            .backgroundColor($r('sys.color.comp_background_gray'))
          Blank()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      } else if (this.isEmpty) {
        // The captured state: an accepted conversation with nothing in it yet. The list stays
        // mounted above; nothing else is drawn over it.
        Column()
          .width('100%')
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
  }
}
