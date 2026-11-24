/*
 * comp_message_bubble — ported from
 * .../MessageSwiftUI/Views/MessageBubbleView.swift `struct MessageBubbleView` (line 22) and
 * `struct MessageBubbleWithEditionWrapper` (line 128):
 *
 *   if model.messageDeleted        -> the deleted-message placeholder, in the edition colour
 *   else if model.type == .call    -> renderCallMessage()   (the call-history line)
 *   else if model.type == .fileTransfer -> MediaView(..., withPlayerControls: true)
 *   else if model.type == .text    -> renderTextContent():
 *       metadata      -> URLPreview(metadata:)
 *       isFullURL     -> the underlined, tappable URL ("message_bubble_url")
 *       otherwise     -> MessageBubbleTextRenderer(model.bubbleTextBody)
 *
 *   MessageBubbleWithEditionWrapper adds the pencil + "edited" line under the content when
 *   `messageEdited && !messageDeleted`.
 *
 * Every branch reports its long press to the host (MessagesListView raises the context menu
 * over a snapshot), so the gesture is a callback rather than an in-place menu.
 */
import { display, LengthMetrics } from '@kit.ArkUI';
import { MessageModel, MessageType } from '../model/MessageModel';
import { PlayerModel } from './PlayerView';
import { DEFAULT_SWARM_COLOR_ARGB } from '../model/ConversationPreferences';

/* ── S5 metrics, the source's own (MessageContentVM.swift:148-150, 306-343) ─────────── */
/** Swift `let cornerRadius: CGFloat = 15`. */
const BUBBLE_RADIUS: number = 15;
/** Swift `var textInset: CGFloat = 15` / `textVerticalInset: CGFloat = 10`. */
const BUBBLE_H_INSET: number = 15;
const BUBBLE_V_INSET: number = 10;
/**
 * Swift `Color.jamiMessageCellReceived` (asset `backgroundMsgReceived`, #E7EBEB) and
 * `Color.jamiMessageCellSent` (#367BC1) — the outgoing bubble takes the account's
 * preferences colour, whose shipped default is that blue. Both are hard-coded in the
 * source, so they are carried over verbatim rather than mapped to a system token.
 */
// The asset's dark appearance (25,30,30) is `app.color.background_msg_received` in dark/; a
// hard-coded light fill kept the bubble light under white dark-mode text (T-1653).
const BUBBLE_RECEIVED: Resource = $r('app.color.background_msg_received');
export const BUBBLE_SENT: string = '#367BC1';
/** Swift `editingIndicator()`: `Image(systemName: "pencil").frame(width: 15, height: 12)`. */
const EDIT_GLYPH_SIZE: number = 15;
/** Swift `HStack(spacing: 2)` on the edition line. */
const EDIT_GLYPH_GAP: number = 2;
/**
 * Swift `updateTextFont()` / `updateInset()` for an emoji-only message: 4.20 (98f11ed3)
 * uses 38pt medium with insets 0/2 (44pt is the newer source, not the reference iPhone).
 */
const EMOJI_FONT_SIZE: number = 38;
const EMOJI_V_INSET: number = 2;

/** Swift `MessageContentVM` — the values one bubble renders. */
export class MessageContentModel {
  /** The message itself <- svc_conversations. */
  message: MessageModel = new MessageModel('', new Date(), '', '', true);
  /** Swift `model.type`. */
  type: MessageType = MessageType.TEXT;
  /** Swift `model.content` / `bubbleTextBody` <- MessageModel.content. */
  content: string = '';
  /** Swift `model.messageDeleted` / `messageDeletedText`. */
  messageDeleted: boolean = false;
  messageDeletedText: string = '';
  /** Swift `model.messageEdited` / `editIndicator`. */
  messageEdited: boolean = false;
  editIndicator: string = '';
  /** Swift `model.metadata` — a link preview; empty when there is none. */
  metadata: string = '';
  /** Swift `model.isFullURL` + `getURL()`. */
  isFullUrl: boolean = false;
  url: string = '';
  /** Swift `model.menuItems` — empty means a long press does nothing. */
  menuItems: string[] = [];
  /** Swift `model.accessibilityLabelValue`. */
  accessibilityLabelValue: string = '';
  /** The media player's state, for a fileTransfer bubble. */
  player: PlayerModel = new PlayerModel();
  /** Swift `hasPlayer` — the transfer is a playable media file. */
  hasPlayer: boolean = false;
  /** The video's shown width / height, from the file; 0 until read, and for audio. */
  playerRatio: number = 0;
  /** Swift `model.url` for a transfer — the local file once it is on this device, else ''. */
  filePath: string = '';
  /** Swift `fileSize` — the transfer's total size in bytes. */
  fileSize: number = 0;
  /** Swift `url.pathExtension.isImageExtension()` — drawn inline once downloaded. */
  isImage: boolean = false;
  /** Swift `preferencesColor` — the conversation's colour, an outgoing bubble's fill (ARGB). */
  swarmColor: number = DEFAULT_SWARM_COLOR_ARGB;
  /** Swift `fileInfo` — "225 bytes - Completed"; '' while there is nothing to say. */
  transferText: string = '';
  /** Swift `transferActions` — the text buttons under the file line. */
  transferActions: TransferAction[] = [];
  /** Swift `showProgress` / `fileProgress` (0...1) — the bar under an ongoing transfer. */
  showProgress: boolean = false;
  fileProgress: number = 0;
}

/** Swift `TransferAction`; the value is its `toString()`, hard-coded English in 4.20. */
export enum TransferAction {
  ACCEPT = 'Accept',
  CANCEL = 'Cancel'
}

/** Swift `MessageContentVM.getFileSizeString(bytes:)` — whole units, as DefaultTransferView shows. */
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} bytes`;
  }
  if (bytes < 1024 * 1024) {
    return `${Math.floor(bytes / 1024)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${Math.floor(bytes / (1024 * 1024))} MB`;
  }
  return `${Math.floor(bytes / (1024 * 1024 * 1024))} GB`;
}

const IMAGE_MAX_WIDTH: number = 240;
/** The image box's shape until the picture's own size is read. */
const IMAGE_PLACEHOLDER_ASPECT: number = 4 / 3;
/** Swift `MediaView(..., minHeight: 50, maxHeight: 300, ...)` in MessageBubbleView. */
const IMAGE_MAX_HEIGHT: number = 300;
/** Swift `playerHeight = 80` — the player's height until a video frame sizes it. */
const PLAYER_DEFAULT_HEIGHT: number = 80;
/** Swift `maxDimension`'s phone value (and its fallback). */
const PLAYER_DEFAULT_DIMENSION: number = 250;
/** Swift DefaultTransferView: `Image(systemName: "doc").frame(width: 20, height: 20)`. */
const FILE_ICON_SIZE: number = 20;
/** Swift DefaultTransferView's spacers: 10 under the name, 15/10 round the bar, 20 between buttons. */
const FILE_INFO_GAP: number = 10;
const FILE_PROGRESS_TOP: number = 15;
const FILE_ACTION_GAP: number = 20;

@Component
export struct MessageBubbleView {
  model: MessageContentModel = new MessageContentModel();
  /** comp_player_view for a fileTransfer bubble (Swift `MediaView`), declared by the page. */
  @BuilderParam playerBuilder: () => void;
  /** Swift `onLongPress(frame, message)` — the host raises ContextMenuView. */
  onLongPress?: () => void;
  /** Swift `openURL(url)`. */
  onOpenUrl?: (url: string) => void;
  /** Opens a file that is on this device. */
  onOpenFile?: () => void;
  /** Swift `model.transferAction(action:)` — Accept downloads, Cancel cancels the transfer. */
  onTransferAction?: (action: TransferAction) => void;
  /** The image's width / height as drawn (EXIF applied), once ArkUI has read it; 0 before. */
  @State private imageAspect: number = 0;

  /** Swift `receivedLongPress()` — a message with no menu items answers no long press. */
  private receivedLongPress(): void {
    if (this.model.menuItems.length === 0) {
      return;
    }
    const handler: (() => void) | undefined = this.onLongPress;
    if (handler !== undefined) {
      handler();
    }
  }

  private openUrl(): void {
    const handler: ((url: string) => void) | undefined = this.onOpenUrl;
    if (handler !== undefined) {
      handler(this.model.url);
    }
  }

  /**
   * Swift `model.backgroundColor` — received keeps `jamiMessageCellReceived`, sent takes the
   * conversation's preferences colour (`preferencesColor`, T-1689).
   */
  private bubbleColor(): ResourceColor {
    return this.model.message.incoming ? BUBBLE_RECEIVED : this.model.swarmColor;
  }

  /** Swift `isEmojiOnly()` — large glyphs, no bubble fill, insets 0/2. */
  private emojiOnly(): boolean {
    return this.model.message.isEmojiOnly();
  }

  /** Swift `styling.textColor` — `.label` on the light received bubble, white on the sent one. */
  private bubbleTextColor(): ResourceColor {
    return this.model.message.incoming ? $r('app.color.label') : Color.White;
  }

  /** Swift `model.editionColor` — secondary on an incoming bubble, near-white on ours. */
  private editionColor(): ResourceColor {
    return this.model.message.incoming ? $r('app.color.secondary_label') : Color.White;
  }

  /** Swift `MessageBubbleWithEditionWrapper.editingIndicator()` — `HStack(spacing: 2)`. */
  @Builder
  private editionIndicator() {
    Row({ space: EDIT_GLYPH_GAP }) {
      SymbolGlyph($r('sys.symbol.pencil_line'))
        .fontSize(EDIT_GLYPH_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor([this.editionColor()])
      Text(this.model.editIndicator)
        // Swift `.font(.footnote)`.
        .fontSize($r('sys.float.Body_S'))
        .fontColor(this.editionColor())
    }
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(BUBBLE_H_INSET),
      end: LengthMetrics.vp(BUBBLE_H_INSET),
      bottom: LengthMetrics.vp(BUBBLE_V_INSET)
    })
  }

  /** Swift `renderCallMessage()` — the same bubble metrics as a text message. */
  @Builder
  private callMessage() {
    Text(this.model.content)
      // Swift `model.styling.textFont` = `.callout.weight(.regular)`.
      .fontSize($r('sys.float.Body_L'))
      .fontColor(this.bubbleTextColor())
      .padding({
        start: LengthMetrics.vp(BUBBLE_H_INSET),
        end: LengthMetrics.vp(BUBBLE_H_INSET),
        top: LengthMetrics.vp(BUBBLE_V_INSET),
        bottom: LengthMetrics.vp(BUBBLE_V_INSET)
      })
  }

  private openFile(): void {
    const handler: (() => void) | undefined = this.onOpenFile;
    if (handler !== undefined) {
      handler();
    }
  }

  private transferAction(action: TransferAction): void {
    const handler: ((action: TransferAction) => void) | undefined = this.onTransferAction;
    if (handler !== undefined) {
      handler(action);
    }
  }

  /**
   * Swift `ImageOrGifView`: `Image(uiImage:).resizable().scaledToFit().frame(maxHeight: 300)`,
   * so the bubble is the picture's own shape: as wide as the row offers unless 300 tall comes
   * first (no width cap, T-1683). Without a size the ArkUI Image filled the whole max box and
   * Contain left blank bands round the picture. Until the source size is read, a 4:3 box.
   */
  private imageAspectRatio(): number {
    return this.imageAspect > 0 ? this.imageAspect : IMAGE_PLACEHOLDER_ASPECT;
  }

  /** Swift `MessageContentVM.maxDimension`: 200 / 250 / 300 by screen width. */
  private maxDimension(): number {
    let screenWidth: number = 0;
    try {
      screenWidth = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    } catch (error) {
      return PLAYER_DEFAULT_DIMENSION;
    }
    return screenWidth <= 320 ? 200 : screenWidth <= 414 ? PLAYER_DEFAULT_DIMENSION : 300;
  }

  /**
   * Swift `playerWidth x playerHeight`: `maxDimension x 80` until a video's frame is known,
   * then that frame fitted into a `maxDimension` square (`getNewSize(of:)`).
   */
  private playerSize(): SizeOptions {
    const side: number = this.maxDimension();
    const ratio: number = this.model.playerRatio;
    if (ratio <= 0) {
      return { width: side, height: PLAYER_DEFAULT_HEIGHT };
    }
    return ratio >= 1 ? { width: side, height: side / ratio } : { width: side * ratio, height: side };
  }

  /** Swift `MediaView`: the player, else an image, else `DefaultTransferView`. */
  @Builder
  private mediaMessage() {
    if (this.model.hasPlayer) {
      // Swift `PlayerSwiftUI` — the in-message player, rounded as the bubble.
      Column() {
        this.playerBuilder()
      }
      .size(this.playerSize())
      .borderRadius(BUBBLE_RADIUS)
      .clip(true)
      // Swift audioMessageControls' clear long-press layer (a video's own layer has one too).
      .gesture(LongPressGesture().onAction(() => {
        this.receivedLongPress();
      }))
    } else if (this.model.isImage && this.model.filePath.length > 0) {
      Image('file://' + this.model.filePath)
        .id('message_bubble_image')
        // UIImage applies the EXIF orientation; ArkUI's default (UP) draws the raw pixels, so
        // a photo tagged Orientation 3 showed upside down (as MediaPreviewPage, aab6869).
        .orientation(ImageRotateOrientation.AUTO)
        .objectFit(ImageFit.Contain)
        .width('100%')
        .constraintSize({ maxWidth: IMAGE_MAX_HEIGHT * this.imageAspectRatio(), maxHeight: IMAGE_MAX_HEIGHT })
        .aspectRatio(this.imageAspectRatio())
        // The source size in px, reported once the data is read (before the decode).
        .onComplete((event) => {
          if (event !== undefined && event.width > 0 && event.height > 0) {
            this.imageAspect = event.width / event.height;
          }
        })
        .borderRadius(BUBBLE_RADIUS)
        // An Image is draggable by default: its drag start took the long press, so a held
        // image never raised the context menu (device: AceDrag status 2 -> 3, no menu).
        .draggable(false)
        .onClick(() => {
          this.openFile();
        })
        .gesture(LongPressGesture().onAction(() => {
          this.receivedLongPress();
        }))
    } else {
      // Swift `DefaultTransferView`: the doc glyph, then the name (one line, middle-truncated),
      // `fileInfo`, the bar while ongoing, and the Accept / Cancel text buttons.
      Row({ space: FILE_INFO_GAP }) {
        SymbolGlyph($r('sys.symbol.doc_plaintext'))
          .fontSize(FILE_ICON_SIZE)
          .fontColor([this.bubbleTextColor()])
        Column() {
          Text(this.model.content)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .ellipsisMode(EllipsisMode.CENTER)
            .fontSize($r('sys.float.Body_L'))
            .fontColor(this.bubbleTextColor())
          if (this.model.transferText.length > 0) {
            Text(this.model.transferText)
              .fontSize($r('sys.float.Body_S'))
              .fontColor(this.bubbleTextColor())
              .margin({ top: FILE_INFO_GAP })
          }
          if (this.model.showProgress) {
            Progress({ value: this.model.fileProgress, total: 1, type: ProgressType.Linear })
              .width('100%')
              .margin({ top: FILE_PROGRESS_TOP, bottom: FILE_INFO_GAP })
          }
          if (this.model.transferActions.length > 0) {
            // Swift `Button(action.toString())` — plain text buttons in the default tint.
            Row({ space: FILE_ACTION_GAP }) {
              ForEach(this.model.transferActions, (action: TransferAction) => {
                Text(action)
                  .id(action === TransferAction.ACCEPT ? 'message_transfer_accept'
                    : 'message_transfer_cancel')
                  .fontSize($r('sys.float.Body_L'))
                  .fontColor($r('sys.color.font_emphasize'))
                  .padding({ top: FILE_INFO_GAP })
                  .onClick(() => {
                    this.transferAction(action);
                  })
              }, (action: TransferAction) => action)
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .id('message_bubble_file')
      .constraintSize({ maxWidth: IMAGE_MAX_WIDTH + 40 })
      .padding({
        start: LengthMetrics.vp(BUBBLE_H_INSET),
        end: LengthMetrics.vp(BUBBLE_H_INSET),
        top: LengthMetrics.vp(BUBBLE_V_INSET),
        bottom: LengthMetrics.vp(BUBBLE_V_INSET)
      })
      .backgroundColor(this.bubbleColor())
      .borderRadius(BUBBLE_RADIUS)
      .onClick(() => {
        this.openFile();
      })
      .gesture(LongPressGesture().onAction(() => {
        this.receivedLongPress();
      }))
    }
  }

  /** Swift `renderTextContent()` — three shapes, only one of which is a plain bubble. */
  @Builder
  private textMessage() {
    if (this.model.metadata.length > 0) {
      // Swift `URLPreview(metadata:maxDimension:)`.
      Text(this.model.metadata)
        .fontSize($r('sys.float.Body_L'))
        .fontColor(this.bubbleTextColor())
        .padding({
          start: LengthMetrics.vp(BUBBLE_H_INSET),
          end: LengthMetrics.vp(BUBBLE_H_INSET),
          top: LengthMetrics.vp(BUBBLE_V_INSET),
          bottom: LengthMetrics.vp(BUBBLE_V_INSET)
        })
        .gesture(LongPressGesture().onAction(() => {
          this.receivedLongPress();
        }))
    } else if (this.model.isFullUrl) {
      Text(this.model.content)
        .id('message_bubble_url')
        .decoration({ type: TextDecorationType.Underline })
        .fontSize($r('sys.float.Body_L'))
        .fontColor(this.bubbleTextColor())
        .padding({
          start: LengthMetrics.vp(BUBBLE_H_INSET),
          end: LengthMetrics.vp(BUBBLE_H_INSET),
          top: LengthMetrics.vp(BUBBLE_V_INSET),
          bottom: LengthMetrics.vp(BUBBLE_V_INSET)
        })
        .onClick(() => {
          this.openUrl();
        })
        .gesture(LongPressGesture().onAction(() => {
          this.receivedLongPress();
        }))
    } else {
      // Swift `MessageBubbleTextRenderer(textBody:font:)` — the message text, bound.
      Text(this.model.content)
        .fontSize(this.emojiOnly() ? EMOJI_FONT_SIZE : $r('sys.float.Body_L'))
        .fontWeight(this.emojiOnly() ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.bubbleTextColor())
        .padding({
          start: LengthMetrics.vp(this.emojiOnly() ? 0 : BUBBLE_H_INSET),
          end: LengthMetrics.vp(this.emojiOnly() ? 0 : BUBBLE_H_INSET),
          top: LengthMetrics.vp(this.emojiOnly() ? EMOJI_V_INSET : BUBBLE_V_INSET),
          bottom: LengthMetrics.vp(this.emojiOnly() ? EMOJI_V_INSET : BUBBLE_V_INSET)
        })
        .gesture(LongPressGesture().onAction(() => {
          this.receivedLongPress();
        }))
    }
  }

  build() {
    Column() {
      if (this.model.messageDeleted) {
        Text(this.model.messageDeletedText)
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.editionColor())
          .padding({
            start: LengthMetrics.vp(BUBBLE_H_INSET),
            end: LengthMetrics.vp(BUBBLE_H_INSET),
            top: LengthMetrics.vp(BUBBLE_V_INSET),
            bottom: LengthMetrics.vp(BUBBLE_V_INSET)
          })
      } else if (this.model.type === MessageType.CALL) {
        this.callMessage()
      } else if (this.model.type === MessageType.FILE_TRANSFER) {
        this.mediaMessage()
      } else if (this.model.type === MessageType.TEXT) {
        this.textMessage()
      }

      // Swift: the edition line rides with the content, and never with a deleted message.
      if (this.model.messageEdited && !this.model.messageDeleted) {
        this.editionIndicator()
      }
    }
    .alignItems(HorizontalAlign.Start)
    // Swift `.applyMessageStyle(model:)` — `model.backgroundColor` clipped to the message
    // corner radius. A fileTransfer bubble carries its own media chrome
    // (`MediaView(..., cornerRadius: 0)`) and the source clears the bubble fill for it, as
    // `updateBackgroundColor()` does for an emoji-only message. A DELETED transfer is the
    // placeholder text in MessageBubbleWithEditionWrapper, which keeps the bubble fill.
    .backgroundColor((this.model.type === MessageType.FILE_TRANSFER && !this.model.messageDeleted)
      || this.emojiOnly()
      ? Color.Transparent
      : this.bubbleColor())
    .borderRadius(BUBBLE_RADIUS)
    .clip(true)
    .accessibilityText(this.model.accessibilityLabelValue)
  }
}
