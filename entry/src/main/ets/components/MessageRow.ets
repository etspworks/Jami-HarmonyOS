/*
 * comp_message_row — ported from
 *   .../MessageSwiftUI/Views/MessageRowView.swift   `struct MessageRowView` (line 65)
 *   .../MessageSwiftUI/Views/MessageStackView.swift `struct MessageStackView` (line 23)
 *   .../MessageSwiftUI/Views/ContactMessageView.swift (line 21)
 *
 *   VStack(alignment: .leading) {
 *     if model.shouldShowTimeString { Text(model.timeString) centred }
 *     Spacer(height: model.topSpace)
 *     if model.centeredMessage {
 *        collabDocViewModel -> CollabDocMessageView   // a document announcement
 *        else               -> ContactMessageView     // a member/interaction line
 *     } else if model.incoming {
 *        HStack { if shouldDisplayAavatar { AvatarSwiftUIView(conversation30) } else { spacer }
 *                 MessageStackView }
 *     } else {
 *        HStack { Spacer; MessageStackView;
 *                 showReciveIndicator -> "messageSentIndicator"
 *                 showSentIndicator   -> an empty circle
 *                 else                -> a 13x13 spacer }
 *     }
 *     if let readIds { HStack { read-receipt avatars (conversation20) } }
 *   }
 *
 *   MessageStackView = VStack { if shouldDisplayName { Text(username) }; MessageContentView }
 *   — one file here, because the stack has no other caller and no plan entry of its own.
 *
 * This is the SINGLE polymorphic row of the conversation list: which of the ten item types it
 * renders follows from the message, and the branch set is the source's, not the capture's (the
 * capture reached this screen with no messages at all).
 *
 * The message CONTENT (comp_message_content) and the collaborative-document announcement
 * (comp_collab_doc_message) are declared by the screen's page and handed in as builders, so
 * the whole message composition is written in one place. The nesting is the source's.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView, GroupAvatarMember } from './AvatarSwiftui';

import { CollabDocMessageModel } from './CollabDocMessage';
import { MessageContainerModel } from './MessageContent';
import { MessageType } from '../model/MessageModel';

/* ── S5 metrics, the source's own (MessageRowView.swift:72-145) ────────────────────── */
/** Swift `Text(model.timeString).font(.caption).padding(10)` — capture S0025 `[172,706]`. */
const TIME_PADDING: number = 10;
/** Swift `MessageStackView`'s `Spacer().frame(height: 4)` under the author name. */
const NAME_SPACING: number = 4;
/** Swift `.padding(.leading, 5)` / `.padding(.trailing, 5)` on the whole row's VStack. */
const ROW_EDGE_INSET: number = 5;
/** Swift `.padding(.top, 1)` / `.padding(.bottom, 1)` on it: 2pt between two rows. */
const ROW_VERTICAL_INSET: number = 1;
/** Swift `.frame(width: 10)` on either side of an incoming row's avatar. */
const AVATAR_GUTTER: number = 10;
/** Swift `.padding(.trailing, 50)` / `.padding(.leading, 50)` — the opposite-side inset. */
const ROW_FAR_INSET: number = 50;
/** Swift `MessageRowVM.leadingSpace = state ? 50 : 12` — an incoming row with no avatar. */
const DIALOG_LEADING_SPACE: number = 12;
/** Swift the outgoing `HStack(alignment: .bottom, spacing: 2)`. */
const OUTGOING_GAP: number = 2;
/** Swift `Image("messageSentIndicator").frame(width: 13, height: 13)`. */
const RECEIVE_INDICATOR_SIZE: number = 13;
/** Swift `Circle().strokeBorder(Color.gray, lineWidth: 1).frame(width: 12, height: 12)`. */
const SENT_INDICATOR_SIZE: number = 12;
const SENT_INDICATOR_STROKE: number = 1;
/** Swift the read-receipt row: `HStack(alignment: .top, spacing: -3)` + a 2pt ring. */
const READ_AVATAR_OVERLAP: number = -3;
const READ_AVATAR_RING: number = 2;
/** Swift `ContactMessageView`'s `model.inset` for a member line. */
const CONTACT_MESSAGE_INSET: number = 7;
/** Swift `ContactMessageVM.height`: `message.type == .initial ? 25 : 45`. */
const INITIAL_MESSAGE_HEIGHT: number = 25;
const CONTACT_MESSAGE_HEIGHT: number = 45;

/** Swift `MessageRowVM` + `MessageStackVM` — everything drawn around one message's content. */
export class MessageRowModel {
  /** Swift `messageModel` — the bubble and everything around it. */
  container: MessageContainerModel = new MessageContainerModel();
  /** Swift `model.shouldShowTimeString` / `timeString`. */
  shouldShowTimeString: boolean = false;
  timeString: string = '';
  /**
   * Swift `topSpace` / `bottomSpace`: 2 where a sequence starts / ends (`singleMessage`,
   * `firstOfSequence` / `lastOfSequence`), 0 inside one.
   */
  topSpace: number = 0;
  bottomSpace: number = 0;
  /** Swift `model.centeredMessage` — drawn across the conversation, not as a bubble. */
  centeredMessage: boolean = false;
  /** Swift `messageModel.collabDocViewModel` — set only on a collab-document announcement. */
  collabDocument: CollabDocMessageModel | null = null;
  /** Swift `ContactMessageVM.content` — the member/interaction line. */
  contactMessageText: string = '';
  /** Swift `model.incoming`. */
  incoming: boolean = true;
  /**
   * Swift `model.shouldDisplayAavatar` (a bubble) / `ContactMessageVM.needAvatar` (a member
   * line) and the author's avatar <- svc_profiles.
   */
  shouldDisplayAvatar: boolean = false;
  avatar: string = '';
  /** Swift `shouldDisplayContactInfoForConversation` -> `leadingSpace` 50 beside no avatar. */
  groupConversation: boolean = false;
  /** Swift `model.shouldDisplayName` / `model.username`. */
  shouldDisplayName: boolean = false;
  username: string = '';
  /** Swift `model.showReciveIndicator` / `showSentIndicator` <- MessageModel.status. */
  showReceiveIndicator: boolean = false;
  showSentIndicator: boolean = false;
  /**
   * Swift `model.readIds` <- ConversationParticipant.lastDisplayed — the participants whose
   * read marker sits on THIS message. Their avatars (photo, else monogram) come from svc_profiles.
   */
  readAvatars: GroupAvatarMember[] = [];
  /** MessageModel.id — the LazyForEach key. */
  id: string = '';
}

@Component
export struct MessageRowView {
  model: MessageRowModel = new MessageRowModel();
  /** comp_message_content for THIS row's message, declared by the page. */
  @BuilderParam contentBuilder: () => void;
  /** comp_collab_doc_message for THIS row, declared by the page. */
  @BuilderParam collabDocBuilder: () => void;

  /** Swift `MessageStackView` — the author line over the message content. */
  @Builder
  private messageStack() {
    Column() {
      if (this.model.shouldDisplayName) {
        Text(this.model.username)
          // Swift `MessageStackView`'s author line — `model.styling.secondaryFont`.
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: NAME_SPACING })
      }
      this.contentBuilder()
    }
    .alignItems(this.model.incoming ? HorizontalAlign.Start : HorizontalAlign.End)
  }

  private isInitial(): boolean {
    return this.model.container.content.type === MessageType.INITIAL;
  }

  /** Swift `ContactMessageView` — a member/interaction line; it has no tap action (T-1587). */
  @Builder
  private contactMessage() {
    // Swift `model.inset`: 0 for "Conversation created", 7 for a member line, which is also
    // drawn in `secondaryFont` (.footnote) and the secondary colour.
    Row({ space: this.isInitial() ? 0 : CONTACT_MESSAGE_INSET }) {
      if (this.model.shouldDisplayAvatar) {
        AvatarSwiftUIView({
          avatarData: this.model.avatar,
          displayText: this.model.username,
          isGroup: false,
          avatarSize: AvatarSize.CONVERSATION_20
        })
      }
      Text(this.model.contactMessageText)
        .maxLines(1)
        // Swift `.font(model.styling.textFont)`, `.truncationMode(.middle)`.
        .fontSize(this.isInitial() ? $r('sys.float.Body_L') : $r('sys.float.Body_S'))
        .fontColor(this.isInitial() ? $r('app.color.label') : $r('app.color.secondary_label'))
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .flexShrink(1)
    }
    // Swift `.frame(maxWidth: .infinity, alignment: .center)`.
    .width('100%')
    // Swift `.frame(minHeight: model.height)`: 25 for "Conversation created", 45 for a member line.
    .constraintSize({ minHeight: this.isInitial() ? INITIAL_MESSAGE_HEIGHT : CONTACT_MESSAGE_HEIGHT })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(this.isInitial() ? 0 : CONTACT_MESSAGE_INSET),
      end: LengthMetrics.vp(this.isInitial() ? 0 : CONTACT_MESSAGE_INSET)
    })
  }

  build() {
    Column() {
      // Swift `if model.shouldShowTimeString { Text(model.timeString) }`.
      if (this.model.shouldShowTimeString) {
        Text(this.model.timeString)
          .width('100%')
          .textAlign(TextAlign.Center)
          // Swift `.font(.caption).foregroundColor(model.styling.secondaryTextColor)`.
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .padding(TIME_PADDING)
      }

      if (this.model.centeredMessage) {
        // Swift: a collab-document announcement, else the contact/interaction line.
        if (this.model.collabDocument !== null) {
          this.collabDocBuilder()
        } else {
          this.contactMessage()
        }
      } else if (this.model.incoming) {
        // Swift `HStack(alignment: .bottom) { ... }.padding(.trailing, 50)`, the avatar in a
        // 10pt gutter on either side.
        Row({ space: AVATAR_GUTTER }) {
          // Swift: the author's avatar only on the first message of a sequence.
          if (this.model.shouldDisplayAvatar) {
            AvatarSwiftUIView({
              avatarData: this.model.avatar,
              displayText: this.model.username,
              isGroup: false,
              avatarSize: AvatarSize.CONVERSATION_30
            })
          }
          this.messageStack()
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({
          start: LengthMetrics.vp(this.model.shouldDisplayAvatar ? AVATAR_GUTTER
            : this.model.groupConversation ? ROW_FAR_INSET : DIALOG_LEADING_SPACE),
          end: LengthMetrics.vp(ROW_FAR_INSET)
        })
      } else {
        // Swift `HStack(alignment: .bottom, spacing: 2) { ... }.padding(.leading, 50)`.
        Row({ space: OUTGOING_GAP }) {
          // The content takes the full row width (MessageContentView is 100% wide), so it gets
          // the space left after the 13vp indicator slot; otherwise the indicator is pushed off
          // the screen edge (T-0822 device review).
          Column() {
            this.messageStack()
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.End)
          // Swift: received -> the sent-indicator asset; sent -> an outline circle; else a gap.
          if (this.model.showReceiveIndicator) {
            Image($r('app.media.message_sent_indicator'))
              .width(RECEIVE_INDICATOR_SIZE)
              .height(RECEIVE_INDICATOR_SIZE)
              .objectFit(ImageFit.Contain)
              .accessibilityLevel('no')
          } else if (this.model.showSentIndicator) {
            Circle()
              .width(SENT_INDICATOR_SIZE)
              .height(SENT_INDICATOR_SIZE)
              .fill(Color.Transparent)
              .stroke($r('app.color.secondary_label'))
              .strokeWidth(SENT_INDICATOR_STROKE)
              .accessibilityLevel('no')
          } else {
            // Swift `Spacer().frame(width: 13, height: 13)`: bubbles line up with or without one.
            Column()
              .width(RECEIVE_INDICATOR_SIZE)
              .height(RECEIVE_INDICATOR_SIZE)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({ start: LengthMetrics.vp(ROW_FAR_INSET) })
      }

      // Swift `if let readIds, !readIds.isEmpty` — the read receipts under the message.
      if (this.model.readAvatars.length > 0) {
        // Swift `HStack(alignment: .top, spacing: -3)` — the read avatars overlap, each with
        // a 2pt ring in the conversation background so the stack reads as separate discs.
        Row({ space: READ_AVATAR_OVERLAP }) {
          Blank()
          ForEach(this.model.readAvatars, (reader: GroupAvatarMember) => {
            AvatarSwiftUIView({
              avatarData: reader.photo,
              displayText: reader.name,
              isGroup: false,
              avatarSize: AvatarSize.CONVERSATION_20
            })
              .borderRadius(AvatarSize.CONVERSATION_20 / 2)
              .border({ width: READ_AVATAR_RING, color: $r('sys.color.background_primary') })
          }, (reader: GroupAvatarMember, index: number) => `${this.model.id}-${index}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        // Swift `.offset(x: 1)`.
        .offset({ x: 1 })
        .accessibilityLevel('no')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // The outgoing indicator ends 5vp from the screen edge, its bubble 20vp (T-1605). Swift's
    // `Spacer().frame(height: model.topSpace)` / `bottomSpace` sit inside the 1pt top/bottom
    // padding, so two rows of one sequence are 2pt apart and two sequences 6pt (T-0704).
    .padding({
      start: LengthMetrics.vp(ROW_EDGE_INSET),
      end: LengthMetrics.vp(ROW_EDGE_INSET),
      top: LengthMetrics.vp(ROW_VERTICAL_INSET + this.model.topSpace),
      bottom: LengthMetrics.vp(ROW_VERTICAL_INSET + this.model.bottomSpace)
    })
  }
}
