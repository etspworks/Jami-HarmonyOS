/*
 * comp_reactions_view — ported from
 *   .../MessageSwiftUI/Views/ReactionsView.swift    `struct ReactionsView` (line 21)
 *   .../MessageSwiftUI/Views/ReactionRowView.swift  `struct ReactionRowView` (line 21)
 *
 *   ReactionsView   ScrollView { VStack { ForEach(model.reactionsRow) { ReactionRowView } } }
 *   ReactionRowView HStack { AvatarSwiftUIView(size: .medium40) | 20 | username | Spacer |
 *                            ScrollView { Text(reaction.toString()) } }
 *
 * The overlay is raised by a long press on a message's reaction bubble and dismissed by a tap
 * anywhere on it — which is why MessagesListView puts `reactions_dismiss` on this view.
 * The rows are MessageModel.react (ReactionsContainerModel), never a literal.
 */
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (ReactionsView.swift / ReactionRowView.swift) ────── */
/** Swift `ReactionRowView`'s `let padding: CGFloat = 20`. */
const REACTION_ROW_PADDING: number = 20;
/** Swift `ScrollView { ... }.frame(maxHeight: 60).frame(minWidth: 30)` on the emoji column. */
const REACTION_EMOJI_MAX_HEIGHT: number = 60;
const REACTION_EMOJI_MIN_WIDTH: number = 30;
/** Swift `ReactionsView`'s `let defailtSize: CGFloat = 300` and `.cornerRadius(15)`. */
const REACTIONS_MAX_SIZE: number = 300;
const REACTIONS_RADIUS: number = 15;
/** Swift `.shadowForConversation()`. */
const CONVERSATION_SHADOW_RADIUS: number = 4;
const CONVERSATION_SHADOW_COLOR: string = '#0D000000';
/** SwiftUI's default `VStack` spacing (8) and `.padding(.vertical)` (16). */
const REACTIONS_ROW_SPACING: number = 8;
const REACTIONS_VERTICAL_PADDING: number = 16;

/** Swift `ReactionsRowViewModel` — one author and every emoji they sent on this message. */
export class ReactionRowModel {
  /** Swift `reaction.jamiId` — also the LazyForEach key. */
  jamiId: string = '';
  /** Swift `reaction.username` <- svc_profiles / svc_name. */
  username: string = '';
  /** The author's avatar <- svc_profiles. */
  avatar: string = '';
  /** Swift `reaction.toString()` — the author's emojis, one string. */
  emojis: string = '';
}

/** Swift `ReactionRowView`. */
@Component
export struct ReactionRowView {
  reaction: ReactionRowModel = new ReactionRowModel();

  build() {
    Row({ space: REACTION_ROW_PADDING }) {
      AvatarSwiftUIView({
        avatarData: this.reaction.avatar,
        displayText: this.reaction.username,
        isGroup: false,
        avatarSize: AvatarSize.MEDIUM_40
      })

      Text(this.reaction.username)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Swift `.font(.callout)`.
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)

      Blank()

      Scroll() {
        Text(this.reaction.emojis)
          // Swift `.bold().font(.title3).multilineTextAlignment(.trailing)`.
          .fontSize($r('sys.float.Title_S'))
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.End)
      }
      .constraintSize({ maxHeight: REACTION_EMOJI_MAX_HEIGHT, minWidth: REACTION_EMOJI_MIN_WIDTH })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // Swift `.padding(.horizontal, padding)`: no vertical padding on the row itself.
    .padding({
      start: LengthMetrics.vp(REACTION_ROW_PADDING),
      end: LengthMetrics.vp(REACTION_ROW_PADDING)
    })
  }
}

/** Swift `ReactionsView` — the whole-message reactions overlay. */
@Component
export struct ReactionsView {
  /** Swift `model.reactionsRow` <- MessageModel.react. */
  rows: ArrayDataSource<ReactionRowModel> = new ArrayDataSource<ReactionRowModel>([]);

  build() {
    // Swift's `ScrollView { VStack { ForEach } }` is one scrolling column of rows, which is a
    // List here — a Scroll wrapping a List would nest two scrollables over one gesture.
    List({ space: REACTIONS_ROW_SPACING }) {
      LazyForEach(this.rows, (reaction: ReactionRowModel) => {
        ListItem() {
          ReactionRowView({ reaction: reaction })
        }
      }, (reaction: ReactionRowModel) => reaction.jamiId)
    }
    // Swift `.background(systemBackground).cornerRadius(15).shadowForConversation()
    // .frame(maxWidth: 300, maxHeight: min(contentHeight, 300))`.
    // A List takes its parent's full width and ignored the maxWidth constraint (device: 374vp
    // card), so the 300 is the width itself; the screen is always wider than that.
    .width(REACTIONS_MAX_SIZE)
    .constraintSize({ maxHeight: REACTIONS_MAX_SIZE })
    .padding({ top: REACTIONS_VERTICAL_PADDING, bottom: REACTIONS_VERTICAL_PADDING })
    .backgroundColor($r('sys.color.background_primary'))
    .borderRadius(REACTIONS_RADIUS)
    .clip(true)
    .scrollBar(BarState.Off)
    .shadow({
      radius: CONVERSATION_SHADOW_RADIUS,
      color: CONVERSATION_SHADOW_COLOR,
      offsetX: 0,
      offsetY: 1
    })
  }
}
