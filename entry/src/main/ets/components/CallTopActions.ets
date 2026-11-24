/*
 * comp_call_top_actions — ported from Ring/Ring/Calls/Views/CallTopActionsView.swift
 * `struct CallTopActionsView` (line 20):
 *
 *   ZStack(alignment: .top) {
 *     CallHeaderView(model:horizontalInset:)                 // centred, width-limited
 *     HStack(alignment: .top) {
 *       if let action = plan?.pictureInPicture { topButton(action) }   // leading
 *       Spacer()
 *       VStack { if model.canAddParticipant { addParticipantButton() }  // trailing column
 *                if let action = plan?.raiseHand { topButton(action) } }
 *     }
 *   }
 *
 *   topButton            -> "call_top_action_\(action.intent)"
 *   addParticipantButton -> "call_top_action_add_participant", Label(person.badge.plus)
 *
 * Three optional controls, each with its own source guard: PiP only when the call can start it,
 * Add participant only for a conference host, Raise hand only in a conference.
 */
import { LengthMetrics } from '@kit.ArkUI';
import {
  BarMetrics, CallControlIntent, ControlAction, ControlButton, ON_VIDEO_GLASS_BLUR, ON_VIDEO_GLASS_FILL
} from './CallControls';
import { CallHeaderModel } from './CallHeader';

@Component
export struct CallTopActionsView {
  header: CallHeaderModel = new CallHeaderModel();
  /** comp_call_header — Swift `CallHeaderView(model:horizontalInset:)`, declared by the page. */
  @BuilderParam headerBuilder: () => void;
  // @Prop, not plain fields: a plain field is read once at construction, so PiP never appeared
  // after an audio call was upgraded to video.
  /** Swift `plan?.pictureInPicture` — null when the call cannot start PiP. */
  @Prop pictureInPicture: ControlAction | null = null;
  /** Swift `plan?.raiseHand` — null outside a conference. */
  @Prop raiseHand: ControlAction | null = null;
  /** conditionalVariants[conference_host]: Swift `model.canAddParticipant`. */
  @Prop canAddParticipant: boolean = false;
  /** Swift `model.perform(action.intent)`. */
  onPerform?: (intent: CallControlIntent) => void;
  /** Swift `model.addParticipantTapped` -> ContactPicker(.forCall). */
  onAddParticipant?: () => void;
  /** Swift `model.showsParticipants = true`. */
  onShowParticipants?: () => void;
  /** Swift `availableWidth` — the chrome's width, measured. */
  @State private availableWidth: number = 0;

  /** Swift `BarMetrics(availableWidth:plan:)` — the same discs as the bottom bar. */
  private metrics(): BarMetrics {
    return new BarMetrics(this.availableWidth);
  }

  private addParticipant(): void {
    const handler: (() => void) | undefined = this.onAddParticipant;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      this.headerBuilder()

      Row() {
        // Swift: the picture-in-picture button leads the bar when the plan offers it.
        if (this.pictureInPicture !== null) {
          ControlButton({
            action: this.pictureInPicture,
            slugPrefix: 'call_top_action_',
            button: this.metrics().button,
            glyphSize: this.metrics().glyphSize,
            onPerform: this.onPerform
          })
        }

        Blank()

        // Swift `VStack(spacing: metrics.gap)`.
        Column({ space: this.metrics().gap }) {
          // Swift `if model.canAddParticipant` — the conference host's own control.
          if (this.canAddParticipant) {
            // Stack-centred, like CallControlIcon: a SymbolGlyph framed larger than its glyph
            // draws it at the top left.
            Stack() {
              // Swift `.font(.system(size: metrics.icon, weight: .medium))`.
              SymbolGlyph($r('sys.symbol.person_badge_plus'))
                .fontSize(this.metrics().glyphSize)
                .fontWeight(FontWeight.Medium)
                .fontColor([Color.White])
                // SF `person.badge.plus` has its plus bottom-LEFT, HarmonyOS's bottom-right (as c46f423).
                .scale({ x: -1 })
            }
            .id('call_top_action_add_participant')
            .accessibilityText($r('app.string.accessibility_calls_default_add_participant'))
            .width(this.metrics().button)
            .height(this.metrics().button)
            // Swift `.onVideoGlass(Circle())`.
            .backgroundColor(ON_VIDEO_GLASS_FILL)
            .backdropBlur(ON_VIDEO_GLASS_BLUR)
            .borderRadius(this.metrics().button / 2)
            .clip(true)
            .onClick(() => {
              this.addParticipant();
            })
          }

          // Swift `if let action = plan?.raiseHand` — conferences only.
          if (this.raiseHand !== null) {
            ControlButton({
              action: this.raiseHand,
              slugPrefix: 'call_top_action_',
              button: this.metrics().button,
              glyphSize: this.metrics().glyphSize,
              onPerform: this.onPerform
            })
          }
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      // Drawn over the header: Transparent so a tap between the discs reaches the header below.
      .hitTestBehavior(HitTestMode.Transparent)
      // Swift: no inset of its own — the chrome's `.padding()` puts the discs 16 from the edge.
      .padding({ top: LengthMetrics.resource($r('sys.float.padding_level4')) })
    }
    .width('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.availableWidth = Number(newArea.width);
    })
  }
}
