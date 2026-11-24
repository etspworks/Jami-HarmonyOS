/*
 * comp_reply_history — ported from
 * Ring/Ring/Features/Conversations/Conversation/MessageSwiftUI/Views/ReplyHistory.swift
 * `struct ReplyHistory` (line 38):
 *
 *   VStack(alignment: model.alignment, spacing: 4) {
 *     if let target {
 *       Text(model.inReplyTo)
 *       if target.type == .fileTransfer { MediaView(target).opacity(0.7) }
 *       else if target.type == .text {
 *         if let metadata { URLPreview(metadata) } else { Text(target.displayContent) }
 *       }
 *     }
 *   }
 *   — every branch tapping through to `model.scrollToReplyTarget()`.
 *
 * The whole component renders only when the message HAS a reply target, which is the
 * `isHistory` branch MessageContentView owns.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { MessageType } from '../model/MessageModel';

/* ── S5 metrics, the source's own (ReplyHistory.swift:38) ─────────────────────────── */
/** Swift `VStack(alignment: model.alignment, spacing: 4)`. */
const REPLY_STACK_GAP: number = 4;
/** Swift `MediaView(...)/URLPreview(...).opacity(0.7)` on the quoted target. */
const REPLY_TARGET_OPACITY: number = 0.7;
/** Swift `.cornerRadius(10)` on the quoted preview. */
const REPLY_RADIUS: number = 10;
/** Swift `MessageReplyStyle`: padding 5/10, `UIColor.lightGray`, the target's cornerRadius 15. */
const QUOTE_V_PADDING: number = 5;
const QUOTE_H_PADDING: number = 10;
const QUOTE_BACKGROUND: string = '#AAAAAA';
const QUOTE_RADIUS: number = 15;
/** Swift `Text(target.displayContent)...opacity(0.4)`. */
const QUOTE_TEXT_OPACITY: number = 0.4;
/** Swift MessageContentView `padding = 12`: `Spacer().frame(width: padding)` on the bubble's side. */
const REPLY_INSET: number = 12;
/**
 * Swift MessageContentView lifts the bubble 12 (`offset(y: -padding)`) and lowers the whole
 * content 12 (`offset(y: padding)`) across VStack's default 8pt spacing: the quote starts 12
 * below the row's top (8 of space, then a 4 offset) and the bubble covers its bottom 4.
 */
const REPLY_TOP_SPACE: number = 8;
const REPLY_OVERLAP: number = 4;

/** Swift `MessageReplyTargetVM` + its `target: MessageContentVM`, flattened to what the view reads. */
export class ReplyTargetModel {
  /** Swift `model.inReplyTo` — "In reply to <author>". */
  inReplyTo: string = '';
  /** Swift `target.displayContent` <- MessageModel.content of the replied-to message. */
  content: string = '';
  /** Swift `target.type` — a file-transfer target renders its media, a text target its text. */
  type: MessageType = MessageType.TEXT;
  /** Swift `model.alignment` — the reply preview follows the message's own side. */
  incoming: boolean = true;
  /** Swift `target.metadata` — a link preview; empty when the target is not a bare URL. */
  metadata: string = '';
}

@Component
export struct ReplyHistory {
  target: ReplyTargetModel = new ReplyTargetModel();
  /** Swift `model.scrollToReplyTarget()` — every branch carries the same tap. */
  onScrollToTarget?: () => void;

  private scrollToTarget(): void {
    const handler: (() => void) | undefined = this.onScrollToTarget;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Column({ space: REPLY_STACK_GAP }) {
      // Swift `Text(model.inReplyTo)` in `styling.secondaryFont` / `styling.textColor`, with no
      // line limit: a long name (a 40-hex Jami ID) wraps instead of truncating to "In reply to …".
      Text(this.target.inReplyTo)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))

      if (this.target.type === MessageType.FILE_TRANSFER) {
        // Swift `MediaView(message: target, ...)` — the target's own media, dimmed.
        Text(this.target.content)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .opacity(REPLY_TARGET_OPACITY)
          .borderRadius(REPLY_RADIUS)
          .onClick(() => {
            this.scrollToTarget();
          })
      } else if (this.target.type === MessageType.TEXT) {
        if (this.target.metadata.length > 0) {
          // Swift `URLPreview(metadata:maxDimension:)`.
          Text(this.target.metadata)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .borderRadius(REPLY_RADIUS)
            .onClick(() => {
              this.scrollToTarget();
            })
        } else {
          // Swift `.modifier(MessageReplyStyle(model: target)).lineLimit(nil).opacity(0.4)`.
          Text(this.target.content)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.label'))
            .padding({
              start: LengthMetrics.vp(QUOTE_H_PADDING),
              end: LengthMetrics.vp(QUOTE_H_PADDING),
              top: LengthMetrics.vp(QUOTE_V_PADDING),
              bottom: LengthMetrics.vp(QUOTE_V_PADDING)
            })
            .backgroundColor(QUOTE_BACKGROUND)
            .borderRadius(QUOTE_RADIUS)
            .opacity(QUOTE_TEXT_OPACITY)
            .onClick(() => {
              this.scrollToTarget();
            })
        }
      }
    }
    .alignItems(this.target.incoming ? HorizontalAlign.Start : HorizontalAlign.End)
    .padding({
      start: LengthMetrics.vp(this.target.incoming ? REPLY_INSET : 0),
      end: LengthMetrics.vp(this.target.incoming ? 0 : REPLY_INSET),
      top: LengthMetrics.vp(REPLY_TOP_SPACE)
    })
    // The bubble, drawn after this in MessageContentView's Column, covers the quote's bottom.
    .offset({ y: REPLY_OVERLAP })
  }
}
