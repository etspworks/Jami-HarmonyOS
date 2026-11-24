/*
 * comp_collab_doc_message — ported from Ring/Ring/Features/Collab/CollabDocMessageView.swift
 * `struct CollabDocMessageView` (line 23) + `struct CollabUnreadIndicator` (line 96):
 *
 *   Button(action: model.open) {
 *     HStack(10) { Image(systemName: "doc.richtext")
 *                  VStack { HStack { title; if hasUnreadChanges { CollabUnreadIndicator() } }
 *                           Text(detail) } }
 *   }
 *   .accessibilityIdentifier("collab_doc_message_open")
 *   .disabled(model.removed)          // a retired announcement opens nothing
 *
 *   detail = removed ? L10n.Collab.documentRemoved : L10n.Collab.editableDocument
 *   title  = removed ? Text(name).strikethrough().secondary : Text(name).label
 *
 * Swift draws it as a card that hugs its content (secondarySystemBackground, corner 12,
 * padding 14 x 8, minHeight 44), centred in the conversation by its row.
 *
 * `doc.richtext` has no exact sys.symbol (icon-map: candidates); `sys.symbol.doc_text` is the
 * text-document glyph of that shortlist and the closest match to the SF glyph.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { CollaborationService, DocumentEvent } from '../common/CollaborationService';

/* ── S5 metrics, the source's own (CollabDocMessageView.swift `enum Layout`) ─────────── */
/** Swift `Layout.spacing` — glyph to text. */
const DOC_ROW_GAP: number = 10;
/** Swift `Layout.textSpacing` — title to detail, and the card's own vertical margin. */
const DOC_TEXT_GAP: number = 2;
/** Swift `Layout.indicatorSpacing` — title to unread dot. */
const DOC_INDICATOR_GAP: number = 6;
/** Swift `Layout.padding` / `Layout.verticalPadding`. */
const DOC_PADDING_H: number = 14;
const DOC_PADDING_V: number = 8;
/** Swift `Layout.minHeight`. */
const DOC_MIN_HEIGHT: number = 44;
/** Swift `Layout.corner`. */
const DOC_CORNER: number = 12;
/** Swift MessageRowView `Layout.centeredMessageMargin` — the Spacer(minLength:) either side. */
const CENTERED_MESSAGE_MARGIN: number = 30;
/** Swift the leading `doc.richtext` glyph, `.font(.title3)`. */
const DOC_GLYPH_SIZE: number = 20;
/** Swift `CollabUnreadIndicator` — `@ScaledMetric(relativeTo: .callout) size = 8`. */
const UNREAD_DOT_SIZE: number = 8;
/** Swift `Color.unreadMessageText` — `UIColor(hexString: "CC0022")`, hard-coded in the source. */
const UNREAD_DOT_COLOR: string = '#CC0022';

/** Swift `CollabDocMessageVM` — what the announcement row reads. */
export class CollabDocMessageModel {
  /** Swift `model.name` <- CollaborativeDocument.name. */
  name: string = '';
  /** Swift `model.removed` — the document was retired; the row stops answering taps. */
  removed: boolean = false;
  /** Swift `model.waitingToBeRead` — drives CollabUnreadIndicator. */
  waitingToBeRead: boolean = false;
  /** Swift `model.open()`'s target — CollaborativeDocument.id. */
  documentId: string = '';
  /** Swift `follow(accountId:conversationId:service:)`'s conversation; the message does not say it. */
  conversationId: string = '';
}

/** Swift `struct CollabUnreadIndicator`. */
@Component
export struct CollabUnreadIndicator {
  build() {
    Circle()
      .width(UNREAD_DOT_SIZE)
      .height(UNREAD_DOT_SIZE)
      .fill(UNREAD_DOT_COLOR)
      .accessibilityLevel('no')
  }
}

@Component
export struct CollabDocMessageView {
  model: CollabDocMessageModel = new CollabDocMessageModel();
  /** Swift `model.open` — opens the collaborative editor over the conversation. */
  onOpen?: (documentId: string) => void;
  /** Swift `@Published var waitingToBeRead`, followed live as `follow()` does. */
  @State private waiting: boolean = false;
  /**
   * Swift `@Published var name` — the name the daemon holds, not the commit's: a renamed
   * document's announcement kept the name it was born with (T-1357).
   */
  @State private name: string = '';
  /**
   * Swift `@Published var removed`: the message's own answer, then `removals` — a removal for
   * every member retires the announcement while the chat is open (T-1603).
   */
  @State private removed: boolean = false;
  /** Swift `renameApplied` — a fetched name answered after a rename is stale. */
  private renameApplied: boolean = false;
  /** The row's measured width (vp); bounds the title, see textMaxWidth(). */
  @State private rowWidth: number = 0;
  private stopFollowing: (() => void)[] = [];

  /** Swift `follow(...)`'s subscriptions, released with the row. */
  aboutToAppear(): void {
    this.waiting = this.model.waitingToBeRead;
    this.name = this.model.name;
    this.removed = this.model.removed;
    const accountId: string = AppStorage.get<string>('currentAccountId') ?? '';
    const documentId: string = this.model.documentId;
    if (accountId.length === 0 || documentId.length === 0) {
      return;
    }
    const service: CollaborationService = ServiceRegistry.shared().collaborationService;
    this.stopFollowing.push(service.documentWaitingToBeRead(accountId, documentId,
      (waiting: boolean): void => {
        this.waiting = waiting;
      }));
    // Swift `documentsRenamed`: the daemon's setName announces a local rename too, and
    // ConversationsService forwards one fetched from another member (T-1617, no conversation id).
    // A document id names one document within an account, so the conversation is not needed.
    this.stopFollowing.push(service.documentsRenamed.subscribe((event: DocumentEvent): void => {
      if (event.accountId === accountId && event.documentId === documentId
        && event.value.length > 0) {
        this.renameApplied = true;
        this.name = event.value;
      }
    }));
    // Swift `service.name(...)`: the current name, for a rename made before this row was built.
    const conversationId: string = this.model.conversationId;
    if (conversationId.length > 0) {
      service.name(accountId, conversationId, documentId)
        .then((name: string): void => {
          // T-1617: 0 chars = the document is not on this device yet; the card keeps the commit's
          // until CollaborationService.documentReplicated announces the stored name (T-1634).
          hilog.info(0x0001, 'JamiF4', 'card %{public}s: daemon name %{public}d chars', documentId,
            name.length);
          if (name.length > 0 && !this.renameApplied) {
            this.name = name;
          }
        })
        .catch((): void => {});
      // Swift `removals(...).filter { $0 }`: one that took the document off this device alone
      // leaves it announced, and opening it fetches it back.
      this.stopFollowing.push(service.removals(accountId, conversationId, documentId,
        (everywhere: boolean): void => {
          if (everywhere) {
            this.removed = true;
          }
        }));
    }
  }

  aboutToDisappear(): void {
    this.stopFollowing.forEach((stop: () => void): void => {
      stop();
    });
    this.stopFollowing = [];
  }

  /** Swift `hasUnreadChanges` — `!removed && waitingToBeRead`. */
  private hasUnreadChanges(): boolean {
    return !this.removed && this.waiting;
  }

  /** Swift `detail`. */
  private detail(): ResourceStr {
    return this.removed
      ? $r('app.string.collab_document_removed')
      : $r('app.string.collab_editable_document');
  }

  /**
   * The widest the title may be: the row minus the margins, the card padding, the glyph and its
   * gap (and the unread dot). A wrap-content Row never re-measures a child it shrinks, so the
   * card's flexShrink narrowed the card but left the title at full width, over its right edge
   * (T-1098 review). +1 vp: the glyph's box is a hair wider than its font size.
   */
  private textMaxWidth(): number | undefined {
    if (this.rowWidth <= 0) {
      return undefined;
    }
    const dot: number = this.hasUnreadChanges() ? DOC_INDICATOR_GAP + UNREAD_DOT_SIZE : 0;
    return this.rowWidth - 2 * CENTERED_MESSAGE_MARGIN - 2 * DOC_PADDING_H
      - DOC_GLYPH_SIZE - 1 - DOC_ROW_GAP - dot;
  }

  private open(): void {
    const handler: ((documentId: string) => void) | undefined = this.onOpen;
    if (handler !== undefined) {
      handler(this.model.documentId);
    }
  }

  build() {
    // Swift: the Button's card hugs its content and the conversation centres it.
    Row() {
      Row({ space: DOC_ROW_GAP }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(DOC_GLYPH_SIZE)
          // Swift: a retired document goes grey with its struck-through title.
          .fontColor([this.removed
            ? $r('app.color.secondary_label')
            : $r('app.color.jami')])

        Column({ space: DOC_TEXT_GAP }) {
          Row({ space: DOC_INDICATOR_GAP }) {
            // Swift `title`: `.callout`, one line truncated in the middle, struck through once
            // the document is removed.
            Text(this.name)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .ellipsisMode(EllipsisMode.CENTER)
              .fontSize($r('sys.float.Body_L'))
              .fontColor(this.removed
                ? $r('app.color.secondary_label')
                : $r('app.color.label'))
              .decoration({ type: this.removed ? TextDecorationType.LineThrough : TextDecorationType.None })
              .flexShrink(1)
              .constraintSize({ maxWidth: this.textMaxWidth() })
            if (this.hasUnreadChanges()) {
              CollabUnreadIndicator()
            }
          }
          // Swift `detail`: `.caption`, secondary.
          Text(this.detail())
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.secondary_label'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .flexShrink(1)
      }
      .id('collab_doc_message_open')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: DOC_MIN_HEIGHT })
      .padding({
        start: LengthMetrics.vp(DOC_PADDING_H),
        end: LengthMetrics.vp(DOC_PADDING_H),
        top: LengthMetrics.vp(DOC_PADDING_V),
        bottom: LengthMetrics.vp(DOC_PADDING_V)
      })
      // Swift `RoundedRectangle(cornerRadius: 12).fill(secondarySystemBackground)`.
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius(DOC_CORNER)
      // Swift `.disabled(model.removed)` — the SOURCE's own guard, not an invented one.
      .enabled(!this.removed)
      .onClick(() => {
        this.open();
      })
      // Swift `.layoutPriority(1)` between the margins: a long name narrows the card to the row
      // and its title truncates; without it the card ran off the screen (T-1098).
      .flexShrink(1)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .onAreaChange((_old: Area, area: Area): void => {
      this.rowWidth = Number(area.width);
    })
    // Swift MessageRowView's `Spacer(minLength: centeredMessageMargin)` either side, and
    // `.padding(.vertical, Layout.textSpacing)` around the Button.
    .padding({
      start: LengthMetrics.vp(CENTERED_MESSAGE_MARGIN),
      end: LengthMetrics.vp(CENTERED_MESSAGE_MARGIN),
      top: LengthMetrics.vp(DOC_TEXT_GAP),
      bottom: LengthMetrics.vp(DOC_TEXT_GAP)
    })
  }
}
