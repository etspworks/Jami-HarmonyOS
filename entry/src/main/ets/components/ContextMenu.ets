/*
 * comp_context_menu — ported from
 * .../MessageSwiftUI/Views/ContextMenuView.swift `struct ContextMenuView` (line 31),
 * `struct EmojiBarView` (line 280) and `struct EmojiBarItemView` (line 368):
 *
 *   ZStack over a snapshot of the screen, dismissed by a tap on the background
 *   ("context_menu_dismiss_background"), holding, in source order:
 *     if model.isShortMsg { emoji bar }            // above a short message
 *     the message itself
 *     if !model.isShortMsg { emoji bar }           // below a long one
 *     makeActions()  — one Button per model.menuItems entry, "contextMenuItemroot",
 *                      HStack { title | Spacer | Image(item.image()) }, destructive in red,
 *                      a Divider between items
 *   EmojiBarView = ScrollView(.horizontal) { emojipalette("contextMenuEmojiPalette")
 *                                            + preferredUserReactions + uniqueAuthoredReactions }
 *                  framed emojiBarMaxWidth x emojiBarHeight, on a glass capsule
 *   makeActions()  framed menuSize.width (updateContextMenuSize), on a glass card
 *
 * The menu is raised by a long press on a message (MessagesListView captures a snapshot first),
 * so the presenting message and its item set arrive as parameters.
 *
 * SF Symbols via results/plan/icon-map.json; `xmark.bin` is in neither the map nor the SDK
 * symbol table, so the destructive rows take `sys.symbol.trash`, the delete glyph this SDK has.
 */
import { display, LengthMetrics } from '@kit.ArkUI';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { MessageAction } from '../model/MessageAction';
import { EmojiPicker, PICKER_BACKGROUND } from './EmojiPicker';
import { BUBBLE_SENT } from './MessageBubble';
import { MessageContainerModel } from './MessageContent';

/* ── S5 metrics, the source's own (ContextMenuVM.swift:78-95, ContextMenuView.swift:205) ── */
/** Swift `var itemHeight = 42` — a floor, so the row grows with the system font size. */
const MENU_ITEM_HEIGHT: number = 42;
/** Swift `let menuPadding: CGFloat = 15`. */
const MENU_PADDING: number = 15;
/** Swift `let menuCornerRadius: CGFloat = 14`. */
const MENU_RADIUS: number = 14;
/** Swift `var menuImageSize = 18`. */
const MENU_IMAGE_SIZE: number = 18;
/**
 * Swift `Image(systemName:).font(.body)` draws past that 18pt frame: about 19 x 15pt for the
 * reply arrow and 17 x 20pt for doc.on.doc on the iOS capture. HMSymbol glyphs fill less of
 * their em box, so they need a 22vp font for the same drawn size.
 */
const MENU_GLYPH_SIZE: number = 22;
/** Swift `private var minMenuWidth = 220`; `screenPadding = 100` caps it below the screen. */
const MENU_MIN_WIDTH: number = 220;
const MENU_SCREEN_PADDING: number = 100;
/** Swift `let defaultVerticalPadding: CGFloat = 6` — between the bar, the message and the menu. */
const DEFAULT_VERTICAL_PADDING: number = 6;
/**
 * Swift `updateSizes()`: `menuBottomPadding = 80`, `minMessageDisplayHeight = 400`, and the
 * 44pt navigation bar (the overlay already starts under the status bar).
 */
const MENU_BOTTOM_PADDING: number = 80;
const MIN_MESSAGE_DISPLAY_HEIGHT: number = 400;
const NAV_BAR_HEIGHT: number = 44;
/**
 * Swift `incomingMessageMarginSize = messageFrame.minX` / `outgoingMessageTrailingMargin =
 * screenWidth - messageFrame.maxX`: the bubble's own inset in a one-to-one row (MessageRow
 * edge 5 + leading 12; edge 5 + indicator 13 + gap 2), so bar and menu line up with it.
 */
const INCOMING_MARGIN: number = 17;
const OUTGOING_MARGIN: number = 20;
/** Swift `var emojiBarHeight = 68`, `.padding(.trailing, 5)` on the palette button. */
const EMOJI_BAR_HEIGHT: number = 68;
const EMOJI_PALETTE_TRAILING: number = 5;
/**
 * Swift `emojiBarMaxWidth = min(screenWidth - emojiBarHorizontalPadding(20),
 * emojiColumnWidth(62) * maxEmojiColumns(5))`, then `.padding(.vertical, 1)
 * .padding(.horizontal, 8)` around the scroll view.
 */
const EMOJI_BAR_SCREEN_PADDING: number = 20;
const EMOJI_COLUMN_WIDTH: number = 62;
const MAX_EMOJI_COLUMNS: number = 5;
const EMOJI_BAR_H_INSET: number = 8;
const EMOJI_BAR_V_INSET: number = 1;
/** Swift `HStack` default spacing between the bar's items. */
const EMOJI_BAR_SPACING: number = 8;
/** Swift `Text(verbatim: emoji).font(.largeTitle).padding(.horizontal, 8).padding(.vertical, 1)`. */
const EMOJI_SIZE: number = 34;
const EMOJI_H_PADDING: number = 8;
const EMOJI_V_PADDING: number = 1;
/** Swift `Image(systemName: "plus.circle.fill").font(.largeTitle)`, settled at `.offset(x: 8)`. */
const EMOJI_PALETTE_SIZE: number = 34;
const EMOJI_PALETTE_OFFSET: number = 8;
/**
 * Swift `EmojiBarItemView`'s enabled notifier under a reaction we already sent: a clear bar
 * above, the preferences-colour bar below, `round(12 + w / 6)` x `round(0.5 + w / 24)` for the
 * ~57pt-wide emoji cell, corner radius 8; the VStack spacing kept small to fit the 68pt bar.
 */
const NOTIFIER_WIDTH: number = 22;
const NOTIFIER_HEIGHT: number = 3;
const NOTIFIER_SPACING: number = 4;
/** Swift `preferredUserReactions`: U+1F44D U+1F44E U+1F606 U+1F923 U+1F615. */
const PREFERRED_USER_REACTIONS: string[] = ['👍', '👎', '😆', '🤣', '😕'];
/** The UIKit popover's corner radius around MCEmojiPicker. */
const EMOJI_PICKER_RADIUS: number = 13;
/** The popup's default target space and arrow (8 + 8) plus an 8vp edge margin. */
const EMOJI_PICKER_GAP: number = 24;
/** Swift `item.isDestructive ? .red : ...` — the iOS destructive red, hard-coded there. */
const DESTRUCTIVE_RED: string = '#FF3B30';
/** Swift `makeBackground()`: `Color.jami.opacity(0.1)` over `.systemUltraThinMaterial`. */
const MENU_BACKGROUND_TINT: string = '#1A00345F';
/**
 * Swift `GlassModifier` below iOS 26: `.systemUltraThinMaterial` + white 8%, a 0.5pt rim of
 * white 25%, `.shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)`.
 */
const GLASS_RIM_WIDTH: number = 0.5;
const GLASS_RIM_COLOR: string = '#40FFFFFF';
const GLASS_SHADOW_RADIUS: number = 12;
const GLASS_SHADOW_COLOR: string = '#26000000';
const GLASS_SHADOW_Y: number = 6;

/** Swift `.modifier(GlassModifier(shape:))` on the emoji capsule and the actions card. */
@Styles
  function glass() {
  .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
    .border({ width: GLASS_RIM_WIDTH, color: GLASS_RIM_COLOR })
    .shadow({
      radius: GLASS_SHADOW_RADIUS,
      color: GLASS_SHADOW_COLOR,
      offsetX: 0,
      offsetY: GLASS_SHADOW_Y
    })
}

/** Swift `enum ContextualMenuItem` (MessageContentVM.swift:39). */
export enum ContextualMenuItem {
  PREVIEW = 'preview',
  FORWARD = 'forward',
  SHARE = 'share',
  SAVE = 'save',
  COPY = 'copy',
  REPLY = 'reply',
  DELETE_MESSAGE = 'deleteMessage',
  DELETE_FILE = 'deleteFile',
  EDIT = 'edit'
}

/** Swift `item.toString()` / `item.image()` / `item.isDestructive`, as one row. */
export class ContextMenuEntry {
  kind: ContextualMenuItem;
  title: ResourceStr;
  icon: Resource;
  isDestructive: boolean;

  constructor(kind: ContextualMenuItem, title: ResourceStr, icon: Resource,
    isDestructive: boolean = false) {
    this.kind = kind;
    this.title = title;
    this.icon = icon;
    this.isDestructive = isDestructive;
  }
}

/** The nine entries the source can offer; which ones appear is MessageContentVM.menuItems. */
export const CONTEXT_MENU_ENTRIES: Map<ContextualMenuItem, ContextMenuEntry> =
  new Map<ContextualMenuItem, ContextMenuEntry>([
    [ContextualMenuItem.PREVIEW, new ContextMenuEntry(ContextualMenuItem.PREVIEW,
      $r('app.string.global_preview'), $r('sys.symbol.arrow_up_left_and_arrow_down_right'))],
    [ContextualMenuItem.FORWARD, new ContextMenuEntry(ContextualMenuItem.FORWARD,
      $r('app.string.global_forward'), $r('sys.symbol.arrowshape_turn_up_right'))],
    [ContextualMenuItem.SHARE, new ContextMenuEntry(ContextualMenuItem.SHARE,
      $r('app.string.global_share'), $r('sys.symbol.arrow_right_up_and_square'))],
    [ContextualMenuItem.SAVE, new ContextMenuEntry(ContextualMenuItem.SAVE,
      $r('app.string.global_save'), $r('sys.symbol.square_and_arrow_down'))],
    [ContextualMenuItem.COPY, new ContextMenuEntry(ContextualMenuItem.COPY,
      // Swift `doc.on.doc` is two outline pages; `doc_filled_on_doc` fills the front one.
      $r('app.string.global_copy'), $r('sys.symbol.doc_text_on_doc_text'))],
    [ContextualMenuItem.REPLY, new ContextMenuEntry(ContextualMenuItem.REPLY,
      $r('app.string.global_reply'), $r('sys.symbol.arrowshape_turn_up_left'))],
    [ContextualMenuItem.DELETE_MESSAGE, new ContextMenuEntry(ContextualMenuItem.DELETE_MESSAGE,
      $r('app.string.global_delete_message'), $r('sys.symbol.trash'), true)],
    [ContextualMenuItem.DELETE_FILE, new ContextMenuEntry(ContextualMenuItem.DELETE_FILE,
      $r('app.string.global_delete_file'), $r('sys.symbol.trash'), true)],
    [ContextualMenuItem.EDIT, new ContextMenuEntry(ContextualMenuItem.EDIT,
      $r('app.string.global_edit_message'), $r('sys.symbol.pencil_line'))]
  ]);

@Component
export struct ContextMenuView {
  /** Swift `model.contentVM` — the message the menu was raised over. */
  message: MessageContainerModel = new MessageContainerModel();
  /**
   * Swift `tappableMessageBody()` — the message redrawn over the snapshot, which is
   * comp_message_content. Declared by the page, like the rest of the message composition.
   */
  @BuilderParam snapshotBuilder: () => void;
  /** Swift `model.menuItems` — the subset this message offers. */
  items: ContextualMenuItem[] = [];
  /** Swift `model.isOurMsg` — the menu hangs off the message's own side. */
  isOurMessage: boolean = false;

  /** Swift `model.contentVM?.contextMenuSelect(item:)` then animateDismiss. */
  onSelect?: (item: ContextualMenuItem) => void;
  /** Swift `cxModel.handleUpdatedReaction()` apply — the picked emoji is sent as a reaction. */
  onPickEmoji?: (emoji: string) => void;
  /** Swift `cxModel.handleUpdatedReaction()` revoke — our own reaction commit is withdrawn. */
  onRevokeReaction?: (reactionId: string) => void;
  /** Swift `animateDismiss(state: .willDismissWithoutAction)`. */
  onDismiss?: () => void;
  /** Swift `cxModel.isEmojiPickerPresented` — MCEmojiPicker under the plus. */
  @State private isEmojiPickerPresented: boolean = false;
  /** Swift `messageFrame.size` — the message's full size, measured once it is laid out. */
  @State private messageFrameWidth: number = 0;
  @State private messageFrameHeight: number = 0;
  /** Swift `screenHeight` — the overlay's height, and its bottom edge (window vp). */
  @State private overlayHeight: number = 0;
  @State private overlayBottom: number = 0;
  /** The plus's bottom edge (window vp): MCEmojiPicker hangs below it (`arrowDirection = .up`). */
  @State private paletteBottom: number = 0;

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  private select(item: ContextualMenuItem): void {
    const handler: ((item: ContextualMenuItem) => void) | undefined = this.onSelect;
    if (handler !== undefined) {
      handler(item);
    }
  }

  /** The row for a menu item. A kind with no entry cannot occur — the map holds all nine. */
  private entry(item: ContextualMenuItem): ContextMenuEntry {
    const found: ContextMenuEntry | undefined = CONTEXT_MENU_ENTRIES.get(item);
    return found === undefined
      ? new ContextMenuEntry(item, '', $r('sys.symbol.ellipsis_circle'))
      : found;
  }

  /** Swift `ScreenDimensionsManager.shared.adaptiveWidth`, in vp. */
  private screenWidth(): number {
    return this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
  }

  /** Swift `emojiBarMaxWidth` plus the 8pt horizontal padding on each side. */
  private emojiBarWidth(): number {
    return Math.min(this.screenWidth() - EMOJI_BAR_SCREEN_PADDING,
      EMOJI_COLUMN_WIDTH * MAX_EMOJI_COLUMNS) + 2 * EMOJI_BAR_H_INSET;
  }

  /**
   * Swift `updateContextMenuSize()`: the widest `.body` title plus its glyph and three
   * paddings, never under `minMenuWidth` nor wider than the screen less `screenPadding`.
   */
  private menuWidth(): number {
    const ui: UIContext = this.getUIContext();
    let width: number = MENU_MIN_WIDTH;
    this.items.forEach((item: ContextualMenuItem): void => {
      const title: number = ui.px2vp(Number(ui.getMeasureUtils().measureText({
        textContent: this.entry(item).title,
        fontSize: $r('sys.float.Body_L')
      })));
      width = Math.max(width, title + MENU_IMAGE_SIZE + MENU_PADDING * 3);
    });
    return Math.min(width, this.screenWidth() - MENU_SCREEN_PADDING);
  }

  /**
   * Swift `updateSizes()` `messageHeight`: the message cut to what leaves the nav bar, the menu
   * (`menuSize.height`, items x itemHeight + 2 x menuPadding) and `menuBottomPadding` on screen,
   * never under `minMessageDisplayHeight`. There is no outer ScrollView here, so it is also
   * capped where the bar and the menu would leave the overlay.
   */
  private messageHeight(): number {
    const menuHeight: number = this.items.length * MENU_ITEM_HEIGHT;
    const fitting: number = this.overlayHeight -
      (menuHeight + 2 * MENU_PADDING + NAV_BAR_HEIGHT + MENU_BOTTOM_PADDING);
    const fitsAll: number = this.overlayHeight - (EMOJI_BAR_HEIGHT + 2 * EMOJI_BAR_V_INSET) -
      menuHeight - 2 * DEFAULT_VERTICAL_PADDING;
    return Math.max(0, Math.min(this.messageFrameHeight,
      Math.max(fitting, MIN_MESSAGE_DISPLAY_HEIGHT), fitsAll));
  }

  /** Swift `isShortMsg = messageHeight < screenHeight / 4` — the bar above, else below. */
  private isShortMessage(): boolean {
    return this.messageHeight() < this.overlayHeight / 4;
  }

  /** The room under the plus, down to the overlay's bottom, for MCEmojiPicker's popover. */
  private emojiPickerMaxHeight(): number {
    return this.overlayBottom - this.paletteBottom - EMOJI_PICKER_GAP;
  }

  /** Swift `currentJamiAccountId` <- `accountService.currentAccount?.jamiId`. */
  private localJamiId(): string {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    return account === null ? '' : account.jamiId;
  }

  /**
   * Swift `preferredUserReactions` then `uniqueAuthoredReactions`: the emojis the local
   * account already put on this message that are not among the preferred five.
   */
  private barEmojis(): string[] {
    const jamiId: string = this.localJamiId();
    const emojis: string[] = PREFERRED_USER_REACTIONS.slice();
    this.message.content.message.reactions.forEach((reaction: MessageAction): void => {
      if (reaction.author === jamiId && !emojis.includes(reaction.content)) {
        emojis.push(reaction.content);
      }
    });
    return emojis;
  }

  /** Swift `getAuthoredReaction(withValue:)` — our own reaction with this emoji, if any. */
  private authoredReaction(emoji: string): MessageAction | undefined {
    const jamiId: string = this.localJamiId();
    return Array.from(this.message.content.message.reactions.values()).find(
      (reaction: MessageAction): boolean => reaction.author === jamiId && reaction.content === emoji);
  }

  /**
   * Swift `handleUpdatedReaction()`, for a bar tap and a picker pick alike: an emoji we already
   * put on this message is revoked, any other is applied.
   */
  private react(emoji: string): void {
    this.isEmojiPickerPresented = false;
    const own: MessageAction | undefined = this.authoredReaction(emoji);
    if (own !== undefined) {
      const revoke: ((reactionId: string) => void) | undefined = this.onRevokeReaction;
      if (revoke !== undefined) {
        revoke(own.id);
      } else {
        this.fire(this.onDismiss);
      }
      return;
    }
    const apply: ((emoji: string) => void) | undefined = this.onPickEmoji;
    if (apply !== undefined) {
      apply(emoji);
    }
  }

  /** Swift `.emojiPicker(isPresented:selectedEmoji:)` — a pick is sent like a bar tap. */
  @Builder
  private emojiPicker() {
    EmojiPicker({
      maxHeight: this.emojiPickerMaxHeight(),
      onPick: (emoji: string): void => {
        this.react(emoji);
      }
    })
  }

  /** Swift `EmojiBarView` — the palette button plus the preferred / already-sent reactions. */
  @Builder
  private emojiBar() {
    // Swift `EmojiBarView` — a horizontal strip `emojiBarHeight` tall, `emojiBarMaxWidth`
    // wide, on a glass capsule; the palette button in the preferences colour first, then the
    // five preferred reactions (the fifth scrolls in, as on the iPhone), then our own others.
    Scroll() {
      Row({ space: EMOJI_BAR_SPACING }) {
        SymbolGlyph($r('sys.symbol.plus_circle_fill'))
          .id('contextMenuEmojiPalette')
          .fontSize(EMOJI_PALETTE_SIZE)
          // Swift `Color(cxModel.preferencesColor)` — the outgoing bubble's colour.
          .fontColor([BUBBLE_SENT])
          .margin({ end: LengthMetrics.vp(EMOJI_PALETTE_TRAILING) })
          // Swift `.offset(x: emojiPaletteButtonOffset)` — an offset, so it takes no layout.
          .translate({ x: EMOJI_PALETTE_OFFSET })
          // Swift `cxModel.isEmojiPickerPresented.toggle()`; the popover's mask takes the
          // second tap, which closes it.
          .onClick(() => {
            this.isEmojiPickerPresented = !this.isEmojiPickerPresented;
          })
          .onAreaChange((_old: Area, area: Area) => {
            this.paletteBottom = Number(area.globalPosition.y) + Number(area.height);
          })
          .bindPopup(this.isEmojiPickerPresented, {
            builder: this.emojiPicker,
            placement: Placement.Bottom,
            popupColor: PICKER_BACKGROUND,
            backgroundBlurStyle: BlurStyle.NONE,
            radius: EMOJI_PICKER_RADIUS,
            mask: true,
            onStateChange: (event: PopupStateChangeParam) => {
              if (!event.isVisible) {
                this.isEmojiPickerPresented = false;
              }
            }
          })

        ForEach(this.barEmojis(), (emoji: string) => {
          // Swift `EmojiBarItemView` — the emoji over its enabled notifier, which shows only
          // when `localUserAuthoredReaction(emoji:)`.
          Column({ space: NOTIFIER_SPACING }) {
            Text(emoji)
              .fontSize(EMOJI_SIZE)
              .padding({
                left: EMOJI_H_PADDING,
                right: EMOJI_H_PADDING,
                top: EMOJI_V_PADDING,
                bottom: EMOJI_V_PADDING
              })
            Row()
              .width(NOTIFIER_WIDTH)
              .height(NOTIFIER_HEIGHT)
              .borderRadius(NOTIFIER_HEIGHT / 2)
              .backgroundColor(this.authoredReaction(emoji) !== undefined ? BUBBLE_SENT
                : Color.Transparent)
          }
          // The clear bar above the glyph, so the glyph stays centred.
          .padding({ top: NOTIFIER_HEIGHT + NOTIFIER_SPACING })
          .onClick(() => {
            this.react(emoji);
          })
        }, (emoji: string) => emoji)
      }
      .height(EMOJI_BAR_HEIGHT)
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width(this.emojiBarWidth())
    .height(EMOJI_BAR_HEIGHT + 2 * EMOJI_BAR_V_INSET)
    .constraintSize({ maxWidth: '100%' })
    .padding({
      left: EMOJI_BAR_H_INSET,
      right: EMOJI_BAR_H_INSET,
      top: EMOJI_BAR_V_INSET,
      bottom: EMOJI_BAR_V_INSET
    })
    // Swift `GlassModifier(shape: Capsule())`.
    .borderRadius(EMOJI_BAR_HEIGHT / 2 + EMOJI_BAR_V_INSET)
    .glass()
  }

  /** Swift `makeActions()` — the menu items, a divider between them. */
  @Builder
  private actions() {
    // Swift `makeActions()` — a `menuCornerRadius` glass card `menuSize.width` wide, one
    // `itemHeight` row per item, title-left / glyph-right, destructive rows in red, a divider
    // inset by `menuPadding`.
    Column() {
      ForEach(this.items, (item: ContextualMenuItem) => {
        Row() {
          Text(this.entry(item).title)
            // Swift `.font(.body)`.
            .fontSize($r('sys.float.Body_L'))
            .fontColor(this.entry(item).isDestructive
              ? DESTRUCTIVE_RED
              : $r('app.color.label'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
          SymbolGlyph(this.entry(item).icon)
            .fontSize(MENU_GLYPH_SIZE)
            .fontColor([this.entry(item).isDestructive
              ? DESTRUCTIVE_RED
              : $r('app.color.secondary_label')])
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: MENU_ITEM_HEIGHT })
        .padding({
          start: LengthMetrics.vp(MENU_PADDING),
          end: LengthMetrics.vp(MENU_PADDING)
        })
        .id('contextMenuItemroot')
        .onClick(() => {
          this.select(item);
        })

        if (this.items[this.items.length - 1] !== item) {
          Divider()
            .color($r('sys.color.comp_divider'))
            .margin({ start: LengthMetrics.vp(MENU_PADDING) })
        }
      }, (item: ContextualMenuItem) => item)
    }
    .width(this.menuWidth())
    .borderRadius(MENU_RADIUS)
    .glass()
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // Swift `.background(makeBackground())`; its `.onTapGesture` is on the whole overlay below.
      Column()
        .width('100%')
        .height('100%')
        // Swift `makeBackground()` — the conversation under `.systemUltraThinMaterial` and a
        // 10% jami tint, not a dark scrim.
        .backgroundBlurStyle(BlurStyle.Thin)
        .backgroundColor(MENU_BACKGROUND_TINT)
        .id('context_menu_dismiss_background')

      // Swift: each element `defaultVerticalPadding` apart, hung off the bubble's own side.
      Column({ space: DEFAULT_VERTICAL_PADDING }) {
        // Swift: above a short message, below a long one — the menu must not push the
        // message off screen.
        if (this.isShortMessage()) {
          this.emojiBar()
        }

        // Swift `tappableMessageBody()` — the message, redrawn over the snapshot, in a
        // `menuCornerRadius` clip `messageHeight` tall: a long one shows its top part only.
        Scroll() {
          Column() {
            this.snapshotBuilder()
          }
          .onAreaChange((_old: Area, area: Area) => {
            this.messageFrameWidth = Number(area.width);
            this.messageFrameHeight = Number(area.height);
          })
        }
        // Swift `.frame(width: messageFrame.width, height: scrollViewHeight)`.
        .width(this.messageFrameWidth > 0 ? this.messageFrameWidth : '100%')
        .constraintSize({ maxHeight: this.messageHeight() })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .enableScrollInteraction(false)
        .borderRadius(MENU_RADIUS)
        // Swift's clear Rectangle over `tappableMessageBody()`: a tap on the message dismisses
        // the menu instead of reaching the bubble's own links, file opening or swipe.
        .hitTestBehavior(HitTestMode.Block)
        // The Scroll takes the tap itself, so it never bubbles to the overlay's onClick (T-1623
        // review: a tap on a long message left the menu open); dismiss here, as that Rectangle does.
        .onClick(() => {
          this.fire(this.onDismiss);
        })

        if (!this.isShortMessage()) {
          this.emojiBar()
        }

        this.actions()
      }
      .width('100%')
      .alignItems(this.isOurMessage ? HorizontalAlign.End : HorizontalAlign.Start)
      .padding({
        start: LengthMetrics.vp(INCOMING_MARGIN),
        end: LengthMetrics.vp(OUTGOING_MARGIN)
      })
      // Hidden until the message and the overlay are measured, so the bar does not jump.
      .opacity(this.messageFrameHeight > 0 && this.overlayHeight > 0 ? 1 : 0)
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.overlayHeight = Number(area.height);
      this.overlayBottom = Number(area.globalPosition.y) + this.overlayHeight;
    })
    // Swift `ZStack { ... }.onTapGesture { animateDismiss(.willDismissWithoutAction) }`: any tap
    // the bar's emojis or the menu's rows do not take closes both. On the background Column
    // alone, a tap beside the message, bar or menu landed on the full-width column holding them
    // and was lost — most of the screen for a long message (T-1623).
    .onClick(() => {
      this.fire(this.onDismiss);
    })
  }
}
