/*
 * comp_call_header — ported from Ring/Ring/Calls/Views/CallHeaderView.swift
 * `struct CallHeaderView` (line 21) and `private struct RecordingIndicator` (line 117):
 *
 *   isTappable = header.showsRoster || model.canAddParticipant
 *   if isTappable { Button(showParticipants) { content }
 *                     .accessibilityIdentifier("call_header_show_participants") }
 *   else          { content }
 *
 *   content = VStack { HStack { if !header.avatars.isEmpty { avatars }      // overlapped faces
 *                               if header.isRecording { RecordingIndicator() }
 *                               Text(header.title)
 *                               if header.showsRoster { Image("chevron.down") } }
 *                      Text(model.statusLine) }
 *
 * The header is a CONTROL only when there is a roster to show — that is the source's own guard,
 * and it is what `call_header_show_participants` hangs off.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/* ── S5 metrics, the source's own (CallHeaderView.swift:22-160) ───────────────────── */
/** Swift `Metrics.minimumHeight = 46`, `verticalPadding = 8`, `lineSpacing = 4`, `spacing = 8`. */
const HEADER_MIN_HEIGHT: number = 46;
const HEADER_V_PADDING: number = 8;
const HEADER_LINE_SPACING: number = 4;
const HEADER_SPACING: number = 8;
/** Swift `Metrics.avatar = 22`, `avatarOverlap = -7`, `avatarBorder = 1`. */
const HEADER_AVATAR_SIZE: number = 22;
const HEADER_AVATAR_OVERLAP: number = -7;
const HEADER_AVATAR_BORDER: number = 1;
/** Swift `RecordingIndicator.Metrics.size = 8`, `.fill(Color.red)`. */
const RECORDING_DOT_SIZE: number = 8;
const RECORDING_RED: string = '#FF3B30';
/** Swift `.foregroundColor(.white.opacity(0.9))` on the status line, `0.3` on a face's ring. */
const STATUS_LINE_COLOR: string = '#E6FFFFFF';
const FACE_RING_COLOR: string = '#4DFFFFFF';
/** Swift the roster chevron beside the title. */
const HEADER_CHEVRON_SIZE: number = 12;
/** Swift `.font(.headline)` (17 pt semibold) on the title, `.footnote` (13 pt) on the status line. */
const HEADER_TITLE_SIZE: number = 17;
const HEADER_TITLE_WEIGHT: number = 600;
const HEADER_STATUS_SIZE: number = 13;

/** Swift `CallHeaderAvatar`. */
export class CallHeaderAvatar {
  /** Swift `avatar.uri` — also the ForEach key. */
  uri: string = '';
  /** The face <- svc_profiles. */
  avatar: string = '';
  /** The participant's name — the initial drawn when there is no photo. */
  name: string = '';
  /** Swift `avatar.isPending` — an invited participant who has not answered yet. */
  isPending: boolean = false;
}

/** Swift `CallHeaderModel`. */
@Observed
export class CallHeaderModel {
  /** bindingContract[header] <- CallState.displayName. */
  title: string = '';
  /** Swift `header.titleIsIdentifier` — a raw id truncates in the middle, a name at the tail. */
  titleIsIdentifier: boolean = false;
  /** Swift `model.statusLine` — "Calling…", the elapsed time, and so on. */
  statusLine: string = '';
  /** Swift `header.avatars` — the overlapped faces of the call's participants. */
  avatars: CallHeaderAvatar[] = [];
  /** conditionalVariants[recording]: Swift `header.isRecording` (peerIsRecording). */
  isRecording: boolean = false;
  /** Swift `header.showsRoster` — a conference with a participant list. */
  showsRoster: boolean = false;
  /** Swift `header.isInviting`. */
  isInviting: boolean = false;
}

/** Swift `private struct RecordingIndicator` — the blinking red dot. */
@Component
export struct RecordingIndicator {
  build() {
    Circle()
      .width(RECORDING_DOT_SIZE)
      .height(RECORDING_DOT_SIZE)
      .fill(RECORDING_RED)
      .accessibilityText($r('app.string.calls_peer_recording'))
  }
}

@Component
export struct CallHeaderView {
  @ObjectLink header: CallHeaderModel;
  /** Swift `model.canAddParticipant` — the other half of `isTappable`; @Prop so it follows the call. */
  @Prop canAddParticipant: boolean = false;
  /** Swift `showParticipants()` — `model.showsParticipants = true`. */
  onShowParticipants?: () => void;

  /** Swift `isTappable` — the header answers a tap only when there is a roster to show. */
  private isTappable(): boolean {
    return this.header.showsRoster || this.canAddParticipant;
  }

  private showParticipants(): void {
    const handler: (() => void) | undefined = this.onShowParticipants;
    if (handler !== undefined) {
      handler();
    }
  }

  /** Swift `avatars` — the overlapping faces, the first one on top. */
  @Builder
  private avatars() {
    // Swift `HStack(spacing: Metrics.avatarOverlap)` — the faces overlap by 7pt, each ringed
    // 1pt (the Jami accent while the invitee is still pending).
    Row({ space: HEADER_AVATAR_OVERLAP }) {
      ForEach(this.header.avatars, (avatar: CallHeaderAvatar) => {
        AvatarSwiftUIView({
          avatarData: avatar.avatar,
          displayText: avatar.name,
          isGroup: false,
          avatarSize: HEADER_AVATAR_SIZE
        })
          .borderRadius(HEADER_AVATAR_SIZE / 2)
          .border({
            width: HEADER_AVATAR_BORDER,
            color: avatar.isPending ? $r('app.color.jami') : FACE_RING_COLOR
          })
      }, (avatar: CallHeaderAvatar) => avatar.uri)
    }
    .accessibilityLevel('no')
  }

  /** Swift `content`. */
  @Builder
  private content() {
    // Swift `VStack(spacing: Metrics.lineSpacing) { HStack(spacing: Metrics.spacing); status }`,
    // on the dark call canvas: a white `.headline` title over a 0.9-white monospaced status.
    Column({ space: HEADER_LINE_SPACING }) {
      Row({ space: HEADER_SPACING }) {
        if (this.header.avatars.length > 0) {
          this.avatars()
        }
        if (this.header.isRecording) {
          RecordingIndicator()
        }
        // ArkUI has no middle truncation: a raw id keeps its head and tail, as Swift `.middle`.
        Text(this.header.titleIsIdentifier && this.header.title.length > 20
          ? this.header.title.slice(0, 8) + '…' + this.header.title.slice(-8) : this.header.title)
          .maxLines(1)
          // Swift `.font(.headline).foregroundColor(.white)`; a raw id truncates in the middle.
          .fontSize(HEADER_TITLE_SIZE)
          .fontWeight(HEADER_TITLE_WEIGHT)
          .fontColor(Color.White)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Swift: the chevron only where a roster can be opened.
        if (this.header.showsRoster) {
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(HEADER_CHEVRON_SIZE)
            .fontColor([Color.White])
            .accessibilityLevel('no')
        }
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)

      Text(this.header.statusLine)
        .maxLines(1)
        // Swift `.font(.footnote.monospacedDigit()).foregroundColor(.white.opacity(0.9))`.
        .fontSize(HEADER_STATUS_SIZE)
        .fontColor(STATUS_LINE_COLOR)
        .textAlign(TextAlign.Center)
    }
    .alignItems(HorizontalAlign.Center)
    .constraintSize({ minHeight: HEADER_MIN_HEIGHT })
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      top: LengthMetrics.vp(HEADER_V_PADDING),
      bottom: LengthMetrics.vp(HEADER_V_PADDING)
    })
  }

  build() {
    // Swift wraps the SAME content in a Button when it is tappable; ArkUI cannot swap a
    // component's own type, so the tap and the identifier carry the source's guard instead.
    Column() {
      this.content()
    }
    .id(this.isTappable() ? 'call_header_show_participants' : 'call_header')
    .enabled(this.isTappable())
    .onClick(() => {
      this.showParticipants();
    })
  }
}
