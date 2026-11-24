/*
 * comp_message_content — ported from
 * .../MessageSwiftUI/Views/MessageContentView.swift `struct MessageContentView` (line 217):
 *
 *   ZStack(alignment: emojiAlignment) {
 *     VStack(alignment: replyTarget.alignment) {
 *       if messageContent.isHistory { renderReplyHistory() }   // ReplyHistory over the bubble
 *       MessageBubbleView(...)
 *     }
 *     if messageModel.hasReactions() { renderReactions() }      // the reaction bubble, corner
 *   }
 *   .if(model.menuItems.contains(.reply)) { overlay(replyIndicator); swipe-to-reply gesture }
 *
 *   renderReactions() carries `.onLongPressGesture { showReactionsView(reactionsModel) }` —
 *   that is what raises the reactions overlay, and it is why the reaction bubble is a control
 *   rather than decoration.
 */
import { curves, LengthMetrics } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { ReactionRowModel } from './ReactionsView';
import { ReplyTargetModel } from './ReplyHistory';
import { BUBBLE_SENT, MessageContentModel } from './MessageBubble';

/** Swift `renderReactions()`: `.padding(5)`, `.cornerRadius(10)`, 0.8pt stroke. */
const REACTIONS_PADDING: number = 5;
const REACTIONS_RADIUS: number = 10;
const REACTIONS_STROKE: number = 0.8;
/** Swift `.padding(.trailing, 10)` / `.padding(.leading, 30)` on the reaction bubble. */
const REACTIONS_TRAILING: number = 10;
const REACTIONS_LEADING: number = 30;
/** Swift `.padding(.bottom, reactionsHeight - 6)`: the reaction overlaps the bubble by 6pt. */
const REACTIONS_OVERLAP: number = 6;
/** Swift `.shadowForConversation()`. */
const CONVERSATION_SHADOW_RADIUS: number = 4;
const CONVERSATION_SHADOW_COLOR: string = '#0D000000';
/** Swift swipe-to-reply metrics (MessageContentView.swift:242-256), in vp for pt. */
const REPLY_ACTIVATION_DISTANCE: number = 70;
const MIN_SWIPE_DISTANCE: number = 30;
const SWIPE_RESISTANCE: number = 0.6;
const MAX_DRAG: number = 90;
const REPLY_ARROW_GAP: number = 30;
const REPLY_RING_SIZE: number = 28;
const REPLY_RING_STROKE: number = 1;
const REPLY_ARROW_SIZE: number = 16;
/** The 70pt haptic: vibrator.HapticFeedback.EFFECT_HARD, else a timed pulse of this length. */
const REPLY_HAPTIC_EFFECT: string = 'haptic.effect.hard';
const REPLY_HAPTIC_FALLBACK_MS: number = 20;
/** Swift `withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { dragX = 0 }`. */
const SPRING_RESPONSE: number = 0.25;
const SPRING_DAMPING: number = 0.9;
/** Swift `startTargetReplyAnimation()`: scale 1.3 over 0.3 s, then back to 1 over 0.1 s. */
const TARGET_PULSE_SCALE: number = 1.3;
const TARGET_PULSE_UP_MS: number = 300;
const TARGET_PULSE_DOWN_MS: number = 100;

/** The pulse of every content view on screen, by message id. */
const targetReplyAnimations: Map<string, () => void> = new Map<string, () => void>();

/** Swift `MessageContainerModel.startTargetReplyAnimation()`, once the list scrolled to it. */
export function startTargetReplyAnimation(messageId: string): void {
  const start: (() => void) | undefined = targetReplyAnimations.get(messageId);
  if (start !== undefined) {
    start();
  }
}

/** Swift `MessageContainerModel` — one message with everything drawn around its bubble. */
export class MessageContainerModel {
  /** Swift `messageModel.messageContent`. */
  content: MessageContentModel = new MessageContentModel();
  /** Swift `messageModel.replyTarget` — null when this message replies to nothing. */
  replyTarget: ReplyTargetModel | null = null;
  /** Swift `reactionsModel.displayValue` — the emoji bubble's text. */
  reactionsDisplay: string = '';
  /** Swift `reactionsModel.reactionsRow` — the overlay's rows. */
  reactions: ReactionRowModel[] = [];
  /** Swift `messageModel.hasReactions()`. */
  hasReactions: boolean = false;
  /** Swift `model.menuItems.contains(.reply)` — swipe-to-reply exists only for those. */
  canReply: boolean = false;
  /** The LazyForEach key — MessageModel.id. */
  id: string = '';
}

@Component
export struct MessageContentView {
  model: MessageContainerModel = new MessageContainerModel();
  /** comp_message_bubble for THIS message, declared by the page. */
  @BuilderParam bubbleBuilder: () => void;
  /** comp_reply_history for THIS message's reply target, declared by the page. */
  @BuilderParam replyBuilder: () => void;
  /** Swift `showReactionsView(reactionsModel)` — raises the reactions overlay. */
  onShowReactions?: () => void;
  /** Swift the swipe-to-reply gesture's effect: MessagePanelVM.messageToReply = this message. */
  onReply?: () => void;
  /** Swift `dragX` — the visual offset, already damped by the resistance; never negative. */
  @State private dragX: number = 0;
  /** Swift `dragHapticFired` — the 70pt mark was crossed during this drag. */
  @State private dragHapticFired: boolean = false;
  /** Swift `lockedAxis == .horizontal` (and the reply guard) for the drag in progress. */
  private horizontalLock: boolean = false;
  /** Swift `reactionsHeight` (SizePreferenceKey) — the reaction bubble's measured height. */
  @State private reactionsHeight: number = 0;
  /** Swift `model.scale` — pulsed when a reply quote scrolls to this message. */
  @State private scaleValue: number = 1;
  private pulse: () => void = (): void => {
    animateTo({
      duration: TARGET_PULSE_UP_MS,
      curve: Curve.EaseInOut,
      onFinish: (): void => {
        animateTo({ duration: TARGET_PULSE_DOWN_MS, curve: Curve.EaseInOut }, (): void => {
          this.scaleValue = 1;
        });
      }
    }, (): void => {
      this.scaleValue = TARGET_PULSE_SCALE;
    });
  };

  aboutToAppear(): void {
    targetReplyAnimations.set(this.model.id, this.pulse);
  }

  aboutToDisappear(): void {
    if (targetReplyAnimations.get(this.model.id) === this.pulse) {
      targetReplyAnimations.delete(this.model.id);
    }
  }

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  /**
   * Swift `outwardSign()` — an incoming bubble swipes right, ours swipes left. ponytail: LTR
   * only, like the rest of the port; mirror it when RTL layouts are supported.
   */
  private outwardSign(): number {
    return this.model.content.message.incoming ? 1 : -1;
  }

  /** Swift `replyIndicatorProgress()` — 0 at rest, 1 once the drag reaches 70pt. */
  private replyProgress(): number {
    return Math.min(1, (this.dragX / SWIPE_RESISTANCE) / REPLY_ACTIVATION_DISTANCE);
  }

  /**
   * Swift `replySwipeGesture().onChanged` before the guard: lock the axis from the first
   * movement. The pan starts after 30vp, so the larger component already exceeds the 12pt
   * lock threshold and the source's test reduces to "more horizontal than vertical".
   */
  private onSwipeStart(event: GestureEvent): void {
    this.horizontalLock = this.model.canReply && Math.abs(event.offsetX) > Math.abs(event.offsetY);
    this.onSwipeUpdate(event);
  }

  /** Swift `replySwipeGesture().onChanged` — follow with resistance, one haptic at 70pt. */
  private onSwipeUpdate(event: GestureEvent): void {
    if (!this.horizontalLock) {
      return;
    }
    const clamped: number = Math.min(Math.max(0, this.outwardSign() * event.offsetX), MAX_DRAG);
    this.dragX = clamped * SWIPE_RESISTANCE;
    if (!this.dragHapticFired && clamped >= REPLY_ACTIVATION_DISTANCE) {
      this.dragHapticFired = true;
      // Swift `UIImpactFeedbackGenerator(style: .medium).impactOccurred()`. The hard preset is
      // the closest to .medium (soft is iOS .soft, too faint to feel); a vibrator without the
      // preset gets a short timed pulse instead of silently rejecting it.
      try {
        const effect: vibrator.VibrateEffect = vibrator.isSupportEffectSync(REPLY_HAPTIC_EFFECT)
          ? { type: 'preset', effectId: REPLY_HAPTIC_EFFECT, count: 1 }
          : { type: 'time', duration: REPLY_HAPTIC_FALLBACK_MS };
        vibrator.startVibration(effect, { usage: 'touch' }).catch((): void => {});
      } catch (e) {
        // No vibrator or no preset: the swipe works without the haptic.
      }
    }
  }

  /** Swift `replySwipeGesture().onEnded` — reply only past 70pt, spring back in every case. */
  private onSwipeEnd(): void {
    if (this.horizontalLock && this.dragX / SWIPE_RESISTANCE > REPLY_ACTIVATION_DISTANCE) {
      this.fire(this.onReply);
    }
    this.horizontalLock = false;
    this.dragHapticFired = false;
    animateTo({ curve: curves.springMotion(SPRING_RESPONSE, SPRING_DAMPING) }, (): void => {
      this.dragX = 0;
    });
  }

  /**
   * Swift `replyIndicator()` — the reply arrow 30pt beyond the bubble's outer edge, fading
   * in with the drag; the ring traces round it once the 70pt haptic has fired. It rides the
   * content's translate, so it follows the bubble as in the source.
   */
  @Builder
  private replyIndicator() {
    Stack() {
      // Swift `Circle().trim(from: 0, to: ringProgress).rotation(-90)`, animated 0 -> 1 when
      // the haptic fires: a ring progress that starts at 12 o'clock and fills smoothly.
      Progress({ value: this.dragHapticFired ? 100 : 0, total: 100, type: ProgressType.Ring })
        .width(REPLY_RING_SIZE)
        .height(REPLY_RING_SIZE)
        .color(BUBBLE_SENT)
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: REPLY_RING_STROKE, enableSmoothEffect: true })
        .opacity(this.dragHapticFired ? this.replyProgress() : 0)
      SymbolGlyph(this.model.content.message.incoming ? $r('sys.symbol.arrowshape_turn_up_left')
        : $r('sys.symbol.arrowshape_turn_up_right'))
        .fontSize(REPLY_ARROW_SIZE)
        .fontColor([BUBBLE_SENT])
        .opacity(this.replyProgress())
    }
    .width(REPLY_RING_SIZE)
    .height(REPLY_RING_SIZE)
    // The bubble hugs the start (incoming) or end (ours) of this stack, so the
    // view's edge is the bubble's edge; the offset puts the centre 30vp past it, vertically
    // centred like the Swift overlay. Not `.position({ x: '100%', y: '50%' })`: inside the
    // List a percentage there resolves against the list's size, not this wrap-content stack,
    // which drew the indicator ~320vp below its row (and off-screen for ours), never in view.
    .layoutGravity(this.model.content.message.incoming ? LocalizedAlignment.START
      : LocalizedAlignment.END)
    .offset({
      x: this.outwardSign() * -(REPLY_RING_SIZE / 2 + REPLY_ARROW_GAP)
    })
    // Swift `.allowsHitTesting(false)`.
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }

  /**
   * Swift `renderReactions()` — the emoji bubble, long-pressed to open the overlay. A
   * `.callout` string on a systemBackground card, corner radius 10 with a 0.8pt outline in
   * the bubble's own colour, and the conversation shadow.
   */
  @Builder
  private reactionsBubble() {
    Text(this.model.reactionsDisplay)
      .fontSize($r('sys.float.Body_L'))
      .fontColor($r('app.color.label'))
      .lineSpacing(LengthMetrics.vp(REACTIONS_PADDING))
      .padding(REACTIONS_PADDING)
      .backgroundColor($r('sys.color.background_primary'))
      .borderRadius(REACTIONS_RADIUS)
      .border({ width: REACTIONS_STROKE, color: $r('sys.color.comp_divider') })
      .shadow({
        radius: CONVERSATION_SHADOW_RADIUS,
        color: CONVERSATION_SHADOW_COLOR,
        offsetX: 0,
        offsetY: 1
      })
      .margin({
        start: LengthMetrics.vp(REACTIONS_LEADING),
        end: LengthMetrics.vp(REACTIONS_TRAILING)
      })
      .gesture(LongPressGesture().onAction(() => {
        this.fire(this.onShowReactions);
      }))
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.reactionsHeight = Number(newArea.height);
      })
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // Swift `if messageModel.messageContent.isHistory { renderReplyHistory() }`.
        if (this.model.replyTarget !== null) {
          this.replyBuilder()
        }

        this.bubbleBuilder()
      }
      .alignItems(this.model.content.message.incoming ? HorizontalAlign.Start : HorizontalAlign.End)
      // Swift `ZStack(alignment: emojiAlignment)` hugs the bubble, so `.bottomTrailing` is the
      // BUBBLE's corner and the reaction hangs 10pt in from it. A full-width column put an
      // incoming bubble's reaction at the far side of the row (T-0930). An incoming bubble
      // narrower than its reaction keeps to the leading edge (Swift `.bottomLeading`), where
      // the reaction, the widest child, starts 30pt in.
      .layoutGravity(this.model.content.message.incoming ? LocalizedAlignment.BOTTOM_START
        : LocalizedAlignment.BOTTOM_END)
      // Swift `.padding(.bottom, !hasReactions() ? 0 : reactionsHeight - 6)` — the reaction
      // bubble hangs off the bubble's bottom corner, so the stack reserves room for it.
      .padding({
        bottom: LengthMetrics.vp(this.model.hasReactions
          ? Math.max(0, this.reactionsHeight - REACTIONS_OVERLAP) : 0)
      })

      // Swift `if messageModel.hasReactions() { renderReactions() }` — the bubble's corner.
      if (this.model.hasReactions) {
        this.reactionsBubble()
      }

      // Swift `.overlay(replyIndicator().allowsHitTesting(false))`, reply-capable only.
      if (this.model.canReply) {
        this.replyIndicator()
      }
    }
    // Swift `.offset(x: outwardSign() * dragX)`.
    .translate({ x: this.outwardSign() * this.dragX })
    // Swift `.scaleEffect(model.scale)`.
    .scale({ x: this.scaleValue, y: this.scaleValue })
    // Swift `.if(model.menuItems.contains(.reply)) { simultaneousGesture(replySwipeGesture()) }`
    // — swipe-to-reply exists only for a message the menu would let you reply to. ArkUI has no
    // conditional attribute, so the source's guard sits in the axis lock. A horizontal-only
    // pan leaves vertical drags to the list's scroll, and once it is recognised the bubble's
    // long press fails, which is the source's `suppressLongPress`.
    .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: MIN_SWIPE_DISTANCE })
      .onActionStart((event: GestureEvent) => {
        this.onSwipeStart(event);
      })
      .onActionUpdate((event: GestureEvent) => {
        this.onSwipeUpdate(event);
      })
      .onActionEnd(() => {
        this.onSwipeEnd();
      })
      // A cancelled pan (interrupted by the system) springs back without replying.
      .onActionCancel(() => {
        this.horizontalLock = false;
        this.onSwipeEnd();
      }))
  }
}
