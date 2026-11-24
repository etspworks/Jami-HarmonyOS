/*
 * screen_dialpad — "Dialpad", ported from
 *   Ring/Ring/Dialpad/DialpadView.swift
 *   Ring/Ring/Dialpad/DialpadViewModel.swift
 *
 * presentation: modal, hostScreen: screen_smart_list. ConversationsCoordinator.showDialpad(
 * inCall: false) presents it with .present, so it is the @CustomDialog
 * SmartListConversationsHomePage already mounts — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — `DialpadView.body`:
 *   VStack(spacing: 0) { numberDisplay; Spacer; keypad; Spacer; callButton }
 *     .toolbar { cancellationAction: Button(L10n.Global.close) "dialpad_close" }
 *
 *   numberDisplay = HStack { a 44 pt spacer | Text(viewModel.phoneNumber) |
 *                            if !phoneNumber.isEmpty { "dialpad_backspace" } }
 *   keypad        = LazyVGrid(3 columns) { ForEach(keys) { DialpadKeyButton } }
 *   callButton    = if viewModel.showsCallButton { "dialpad_call" .disabled(number.isEmpty) }
 *
 * The backspace is ABSENT, not disabled, while the number is empty — captured state S0095 has
 * no digits and no backspace, S0096 has one digit and the backspace. That is the screen's one
 * conditional variant.
 *
 * DAEMON GAP: placing an outgoing SIP call is daemon work the target platform cannot run, so
 * the Call control keeps its place and reports it (plan edge screen_dialpad -> screen_call).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { JamiConstants } from '../common/JamiConstants';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { CallService } from '../common/CallService';
// feat_voice_call: with no system call provider the app activates the audio route itself.
import { AudioService } from '../common/AudioService';
import { DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountModel } from '../model/AccountModel';
import { CallDirection } from '../model/CallState';
import { DialpadKeyButton, DialpadKeyModel, dialpadKeys } from '../components/DialpadKeyButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'DialpadPage';

/* ── S5 metrics, the source's own (DialpadView.swift:21-148) ──────────────────────── */
/** Swift `Layout.touchTarget = 44`. */
const TOUCH_TARGET: number = 44;
/** Swift `Layout.largeButton = 72` — the call button and every key. */
const LARGE_BUTTON: number = 72;
/** Swift `Layout.maxContentWidth = 360`. */
const MAX_CONTENT_WIDTH: number = 360;
/** Swift `Layout.spacing = 24` — the grid's column gap and the stack's minimum spacers. */
const LAYOUT_SPACING: number = 24;
/** Swift `LazyVGrid(columns:, spacing: 16)` — capture S0095 rows are 88vp apart on 72vp keys. */
const GRID_ROW_GAP: number = 16;
/** Swift `LazyVGrid(columns: 3 flexible)` — the keypad's column count. */
const GRID_COLUMNS: number = 3;
/** Swift `Text(viewModel.phoneNumber).font(.system(size: 36, weight: .regular))`. */
const NUMBER_FONT_SIZE: number = 36;
/** Swift `numberDisplay = HStack(spacing: 8)`. */
const NUMBER_ROW_SPACING: number = 8;
/** Swift `.minimumScaleFactor(0.5)` on the composed number. */
const NUMBER_MIN_SCALE: number = 0.5;
/** Swift `Image(systemName: "delete.left").font(.system(size: 24, weight: .regular))`. */
const BACKSPACE_GLYPH_SIZE: number = 24;
/** Swift `Image(systemName: "phone.fill").font(.system(size: 30)).foregroundColor(.white)`. */
const CALL_GLYPH_SIZE: number = 30;
/** Swift `Color.jamiSuccess` = `UIColor(hex: 0x00b20b)` — hard-coded in the source. */
const JAMI_SUCCESS: string = '#00B20B';
/** Swift `.opacity(enabled ? 1 : 0.4)` on the call button. */
const CALL_DISABLED_OPACITY: number = 0.4;
/** Swift `.padding(.vertical, 20)` on the dialpad stack. */
const STACK_V_PADDING: number = 20;
/**
 * The iOS default `tintColor`. The dialpad sheet does NOT apply `.accentColor(.jami)` the way
 * the contact picker does, so capture S0095 shows `Close` in system blue, not Jami navy.
 */
const IOS_TINT_BLUE: string = '#007AFF';

@CustomDialog
export struct DialpadOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /**
   * Swift dismissed the sheet through its presentation binding; the host owns the flag so the
   * dialpad can close itself and the host stay in step.
   */
  @Link isPresented: boolean;

  /** bindingContract[dialled number] <- DialpadViewModel.phoneNumber. */
  @State dialledNumber: string = '';
  /**
   * bindingContract[dialpad key grid] <- JamiConstants.DIALPAD_KEYS (the migrated Constants
   * table), with the letters and the "+" long press DialpadView keeps in the view itself.
   */
  @State dialpadKeyGrid: ArrayDataSource<DialpadKeyModel> =
    new ArrayDataSource<DialpadKeyModel>(dialpadKeys(JamiConstants.DIALPAD_KEYS));
  /** conditionalVariants[has_digits]: Swift `!viewModel.phoneNumber.isEmpty`. */
  @State hasDigits: boolean = false;
  /** Swift `viewModel.showsCallButton` — false for the in-call dialpad. */
  @State private showsCallButton: boolean = true;
  /** Swift `viewModel.inCallDialpad` — suppresses the "+" long press. */
  @State private inCallDialpad: boolean = false;
  /** True while svc_calls is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** Written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /**
   * The disclosed daemon gap: placing a SIP call is daemon work. Rendered as a visible notice
   * so the Call control is never a silent no-op; the next attempt clears it.
   */
  @State showDaemonNotice: boolean = false;

  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** Swift `viewModel.numberPressed(_:)` — appends the key in place. */
  private numberPressed(value: string): void {
    this.dialledNumber = this.dialledNumber + value;
    this.hasDigits = this.dialledNumber.length > 0;
  }

  /** Swift `viewModel.deleteLast()`. */
  private deleteLast(): void {
    this.dialledNumber = this.dialledNumber.substring(0, this.dialledNumber.length - 1);
    this.hasDigits = this.dialledNumber.length > 0;
  }

  /**
   * Swift: the Call button places an outgoing call and CallsCoordinator shows CallScreenView
   * (plan edge screen_dialpad -> screen_call, kind: present). Both halves are daemon work.
   */
  private placeCall(): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    if (!this.hasDigits) {
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.getAccount(this.currentAccountId);
    if (account === null) {
      // No account resolves while the daemon gap stands, so the call can never be placed. Report
      // it through the same disclosed notice the DaemonUnavailableError branch raises, never a
      // silent return — that made the Call control a dead tap.
      this.showDaemonNotice = true;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'placeCall: no account for %{public}s — daemon unavailable',
        this.currentAccountId);
      return;
    }
    this.isLoading = true;
    const calls: CallService = registry.callService;
    // Swift `viewModel.placeCall()` — an audio-only outgoing call to the dialled number.
    calls.placeCall(account.id, this.dialledNumber, true)
      .then((): void => {
        this.isLoading = false;
        // Swift: CallKit activated the session; with no system provider the app does it.
        const audio: AudioService = registry.audioService;
        audio.callKitActivated(false, CallDirection.OUTGOING);
        // screen_dialpad -> screen_call (kind: present): the host raises the call screen once
        // the dialpad closes, so the dialpad's own job ends here.
        this.dismiss();
      })
      .catch((error: Object): void => {
        this.isLoading = false;
        if (error instanceof DaemonUnavailableError) {
          this.showDaemonNotice = true;
          return;
        }
        this.errorText = describeError(error as BusinessError);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'placeCall failed: %{public}s', this.errorText);
      });
  }

  /** Swift `numberDisplay`. */
  @Builder
  private numberDisplay() {
    // Swift `HStack(spacing: 8)` — without it the backspace sat flush against the digits.
    Row({ space: NUMBER_ROW_SPACING }) {
      // Swift `Color.clear.frame(width: 44, height: 44)` — the number stays centred whether or
      // not the backspace is there.
      Column()
        .width(44)
        .height(44)

      Text(this.dialledNumber)
        .layoutWeight(1)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        // Swift `.font(.system(size: 36, weight: .regular)).minimumScaleFactor(0.5)`.
        .fontSize(NUMBER_FONT_SIZE)
        .fontColor($r('app.color.label'))
        .minFontSize(NUMBER_FONT_SIZE * NUMBER_MIN_SCALE)
        .maxFontSize(NUMBER_FONT_SIZE)
        // Swift `.truncationMode(.head)` — a long number keeps its tail visible. A bare
        // Ellipsis elides the TAIL, hiding the digits just typed; START elides the head.
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.START)

      // Swift `if !viewModel.phoneNumber.isEmpty` — conditionalVariants[has_digits].
      if (this.hasDigits) {
        // A SymbolGlyph draws its glyph at the START of its own frame, so the 44vp touch target
        // is a Stack that centres the glyph, as Swift's `.frame(width: 44, height: 44)` does.
        Stack() {
          SymbolGlyph($r('sys.symbol.delete_left'))
            .fontSize(BACKSPACE_GLYPH_SIZE)
            // Swift `.foregroundColor(.primary)`.
            .fontColor([$r('app.color.label')])
        }
        .id('dialpad_backspace')
        .accessibilityText($r('app.string.actions_delete_action'))
        .width(TOUCH_TARGET)
        .height(TOUCH_TARGET)
        .onClick(() => {
          this.deleteLast();
        })
      } else {
        Column()
          .width(TOUCH_TARGET)
          .height(TOUCH_TARGET)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: TOUCH_TARGET, maxWidth: MAX_CONTENT_WIDTH })
    // Swift `.padding(.horizontal, Layout.touchTarget).padding(.top, Layout.spacing)`.
    .padding({
      start: LengthMetrics.vp(TOUCH_TARGET),
      end: LengthMetrics.vp(TOUCH_TARGET),
      top: LengthMetrics.vp(LAYOUT_SPACING)
    })
  }

  /**
   * A Grid in an unconstrained Column fills the whole remaining height, which pushed the Call
   * button, the daemon notice and the error text off-screen (S0095/S0096: the Grid claimed
   * [23,481][1193,2688] while its last key row ended at y=1573). Swift's LazyVGrid is
   * content-sized inside the VStack, so give the Grid exactly its content height: one
   * LARGE_BUTTON per key row plus GRID_ROW_GAP between them.
   */
  private keypadHeight(): number {
    const rows: number = Math.ceil(this.dialpadKeyGrid.totalCount() / GRID_COLUMNS);
    if (rows <= 0) {
      return 0;
    }
    return rows * LARGE_BUTTON + (rows - 1) * GRID_ROW_GAP;
  }

  /** Swift `keypad` — LazyVGrid over three flexible columns. */
  @Builder
  private keypad() {
    Grid() {
      LazyForEach(this.dialpadKeyGrid, (key: DialpadKeyModel) => {
        GridItem() {
          DialpadKeyButton({
            model: key,
            inCallDialpad: this.inCallDialpad,
            onTap: (value: string) => {
              this.numberPressed(value);
            },
            onLongPress: (value: string) => {
              this.numberPressed(value);
            }
          })
        }
      }, (key: DialpadKeyModel) => key.value)
    }
    .columnsTemplate('1fr 1fr 1fr')
    // Swift `LazyVGrid(columns: 3 flexible, spacing: 16)` with `Layout.spacing = 24` between
    // the columns, the whole grid inset by `Layout.touchTarget` and capped at 360.
    .columnsGap(LAYOUT_SPACING)
    .rowsGap(GRID_ROW_GAP)
    .width('100%')
    // Content height, not the Column's leftovers — see keypadHeight().
    .height(this.keypadHeight())
    .constraintSize({ maxWidth: MAX_CONTENT_WIDTH })
    .padding({
      start: LengthMetrics.vp(TOUCH_TARGET),
      end: LengthMetrics.vp(TOUCH_TARGET)
    })
  }

  build() {
    Column() {
      // Swift `.toolbar { cancellationAction }`.
      Row() {
        // Capture S0095: `Close` is a plain text bar-button at `[16,83][67,111]`, in the iOS
        // default tint — the dialpad does NOT re-tint its toolbar the way the picker does.
        Button($r('app.string.global_close'))
          .id('dialpad_close')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor(IOS_TINT_BLUE)
          .padding(0)
          .onClick(() => {
            this.dismiss();
          })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        top: LengthMetrics.resource($r('sys.float.ohos_id_card_margin_start')),
        bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
      })

      this.numberDisplay()

      Blank()

      this.keypad()

      Blank()

      // Swift `if viewModel.showsCallButton` — the in-call dialpad has none.
      if (this.showsCallButton) {
        // Capture S0095: a 72vp `jamiSuccess` green disc with a white 30pt handset, centred.
        // The disc is a Stack: sized itself, a SymbolGlyph draws the handset at its start edge.
        Stack() {
          SymbolGlyph($r('sys.symbol.phone_fill'))
            .fontSize(CALL_GLYPH_SIZE)
            .fontColor([Color.White])
        }
        .id('dialpad_call')
        .accessibilityText($r('app.string.global_call'))
        .width(LARGE_BUTTON)
        .height(LARGE_BUTTON)
        .backgroundColor(JAMI_SUCCESS)
        .borderRadius(LARGE_BUTTON / 2)
        .clip(true)
        // Swift `.opacity(enabled ? 1 : 0.4)`.
        .opacity(this.hasDigits ? 1 : CALL_DISABLED_OPACITY)
        // Swift `.disabled(!enabled)` where `enabled = !phoneNumber.isEmpty` — the SOURCE's
        // own guard.
        .enabled(this.hasDigits)
        .onClick(() => {
          this.placeCall();
        })
      }

      // The disclosed daemon gap raised by the Call control.
      if (this.showDaemonNotice) {
        Text($r('app.string.daemon_not_available'))
          .width('100%')
          .id('dialpad_daemon_notice')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_on_primary'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_card_margin_start'))
          .backgroundColor($r('app.color.jami'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .margin($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    // Swift `.padding(.vertical, 20)` and `.background(Color(.systemBackground))`.
    .padding({ top: LengthMetrics.vp(STACK_V_PADDING), bottom: LengthMetrics.vp(STACK_V_PADDING) })
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_dialpad')
  }
}
