/*
 * comp_call_banner — ported from
 * .../MessageSwiftUI/Views/CallBannerView.swift `struct CallBannerView` (line 21):
 *
 *   VStack(spacing: 12) {
 *     ForEach(viewModel.activeCalls, id: \.id) { call in
 *       VStack(spacing: 12) {
 *         Text(L10n.Calls.activeCallInConversation)
 *         HStack(spacing: 16) {
 *           Button(video)  "callBannerAcceptVideo" -> viewModel.acceptVideoCall(for: call)
 *           Button(phone)  "callBannerAcceptAudio" -> viewModel.acceptAudioCall(for: call)
 *         }
 *       }
 *     }
 *   }
 *
 * The banner exists only while `callBannerViewModel.isVisible` — one row per ACTIVE call in
 * this conversation, off svc_calls, never a literal.
 */
import { ActiveCall } from '../model/ActiveCall';
import { CallState } from '../model/CallState';
import { CallStatusKind } from '../model/CallStatus';
import { CallService } from '../common/CallService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { INCOMING_CALL_BANNER_UP } from './IncomingCallBanner';

/* ── S5 metrics, the source's own (CallBannerView.swift:25-60) ─────────────────────── */
/** Swift `VStack(spacing: 12)` and `HStack(spacing: 16)`. */
const BANNER_STACK_GAP: number = 12;
const BANNER_BUTTON_GAP: number = 16;
/** Swift `Image(systemName: ...).font(.system(size: 25)).foregroundColor(.jami)`. */
const BANNER_GLYPH_SIZE: number = 25;
/** Swift `.cornerRadius(12)` on the banner's card. */
const BANNER_CORNER_RADIUS: number = 12;

@Component
export struct CallBannerView {
  /** Swift `viewModel.activeCalls` <- svc_calls (CallBannerViewModel). */
  activeCalls: ActiveCall[] = [];
  /** Swift `viewModel.acceptVideoCall(for:)`. */
  onAcceptVideo?: (call: ActiveCall) => void;
  /** Swift `viewModel.acceptAudioCall(for:)`. */
  onAcceptAudio?: (call: ActiveCall) => void;

  private accept(call: ActiveCall, withVideo: boolean): void {
    const handler: ((call: ActiveCall) => void) | undefined =
      withVideo ? this.onAcceptVideo : this.onAcceptAudio;
    if (handler !== undefined) {
      handler(call);
    }
  }

  build() {
    // S5 — Swift: a grey card (secondarySystemBackground over chrome material, cornerRadius 12)
    // across the top of the conversation, the label in `.callout` over two 25pt accent glyphs
    // 16pt apart.
    Column({ space: BANNER_STACK_GAP }) {
      ForEach(this.activeCalls, (call: ActiveCall) => {
        Column({ space: BANNER_STACK_GAP }) {
          Text($r('app.string.calls_active_call_in_conversation'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)

          Row({ space: BANNER_BUTTON_GAP }) {
            SymbolGlyph($r('sys.symbol.video'))
              .id('callBannerAcceptVideo')
              .accessibilityText($r('app.string.calls_accept_with_video'))
              .fontSize(BANNER_GLYPH_SIZE)
              .fontColor([$r('app.color.jami')])
              .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
              .onClick(() => {
                this.accept(call, true);
              })

            SymbolGlyph($r('sys.symbol.phone'))
              .id('callBannerAcceptAudio')
              .accessibilityText($r('app.string.calls_accept_with_audio'))
              .fontSize(BANNER_GLYPH_SIZE)
              .fontColor([$r('app.color.jami')])
              .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
              .onClick(() => {
                this.accept(call, false);
              })
          }
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }, (call: ActiveCall) => call.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(BANNER_CORNER_RADIUS)
  }
}

/**
 * The way back to a call whose screen Back closed (T-1594). iOS keeps one through CallKit's
 * status-bar pill and PiP; neither exists here for every call, so the smart list and the
 * conversation show this bar while a call is live and their own call screen is not up.
 */
@Component
export struct ReturnToCallBar {
  /** Opens the host's call screen. */
  onReturn?: () => void;
  /** The peer of the call the user is in (connected), else of the first live call; '' when none. */
  @State private name: string = '';
  /** The incoming-call banner is up (T-1628): it is the way to that call, as on iOS. */
  @StorageProp(INCOMING_CALL_BANNER_UP) private bannerUp: boolean = false;
  private unsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    const calls: CallService = ServiceRegistry.shared().callService;
    const refresh = (): void => {
      const live: CallState[] = calls.stateMirror.liveCalls;
      const call: CallState | undefined = live.find((candidate: CallState): boolean =>
        candidate.status.kind === CallStatusKind.CURRENT) ?? live[0];
      this.name = call !== undefined ? call.bestName : '';
    };
    // Read now too: a host built while a call is up gets no tick until that call changes.
    refresh();
    this.unsubscribe = calls.callsUpdated.subscribe((): void => {
      refresh();
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  build() {
    if (this.name.length > 0 && !this.bannerUp) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.phone_fill'))
          .fontSize(18)
          .fontColor([Color.White])
        Text() {
          Span($r('app.string.calls_current_call_with'))
          Span(this.name)
        }
        .layoutWeight(1)
        .maxLines(1)
        .wordBreak(WordBreak.BREAK_ALL)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(Color.White)
        .fontSize($r('sys.float.Body_M'))
      }
      .id('return_to_call')
      .width('92%')
      .padding(12)
      .borderRadius(24)
      .backgroundColor('#2E7D32')
      .onClick(() => {
        if (this.onReturn !== undefined) {
          this.onReturn();
        }
      })
    }
  }
}
