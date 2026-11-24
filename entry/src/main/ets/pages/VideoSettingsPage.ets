/*
 * screen_video_settings — "Video", ported from
 *   Ring/Ring/Features/Settings/Me/GeneralSettingsViews.swift (VideoSettingsView :223-244)
 *   Ring/Ring/Features/Settings/Me/GeneralSettings.swift      (:23, :30-33, :59-66)
 *   Ring/Ring/Extensions/View+Helpers.swift                   (struct ToggleCell)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`). navOut is empty.
 *
 * S3 — the real tree of `VideoSettingsView.body`:
 *
 *   List { Section {
 *     ToggleCell(toggleText: L10n.GeneralSettings.videoAcceleration,
 *                getAction: { model.videoAccelerationEnabled },
 *                setAction: { model.enableVideoAcceleration(enable: $0) },
 *                identifier: "video_settings_video_acceleration")
 *   } }
 *   .navigationBarTitleDisplayMode(.inline).navigationTitle(L10n.Global.video)
 *
 * One Section, one cell: the source declares no other control, so none is invented here.
 * conditionalVariants is empty — the screen renders one layout in every state.
 *
 * bindingContract — [toggle state] <- svc_preferences. Swift
 * `@Published var videoAccelerationEnabled = UserDefaults.standard.bool(forKey:
 * hardareAccelerationKey)`. Never a literal.
 *
 * THE WRITE HAS TWO HALVES AND BOTH ARE OWED (`enableVideoAcceleration`, GeneralSettings:59):
 *   (a) `UserDefaults.standard.set(enable, forKey: hardareAccelerationKey)` — a REAL local
 *       preference. It is stored through `@ohos.data.preferences` and FLUSHED, so the value
 *       survives a cold relaunch; a flush that fails says so rather than letting the switch
 *       claim a setting that never reached disk. The same `jami_shared` store the other
 *       general-settings screens use (pages/FileTransferSettingsPage.ets).
 *   (b) `videoService.setHardwareAccelerated(enable)` — `common/VideoService.ts:636-642`
 *       applies the half it owns (the default capture device / quality) and reports
 *       `video.setHardwareAccelerated` unavailable through `DaemonService`, because the
 *       libjami encode/decode switches are the gap. That is surfaced as the in-body
 *       `daemon_not_available` notice — never a silent return — and the switch still flips
 *       its own rendered state, since half (a) genuinely persisted.
 *
 * The idiom for both is already device-VERIFIED: pages/FileTransferSettingsPage.ets for the
 * preference store, pages/CallSettingsPage.ets for `observeDaemonGap` / `showDaemonNotice`.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LengthMetrics, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { ToggleCell } from '../components/ToggleCell';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'VideoSettingsPage';

/** The one settings store — `common/ConversationsManager.ts` opens the same name. */
const PREFERENCES_STORE_NAME: string = 'jami_shared';
/** Swift `let hardareAccelerationKey = "HARDWARE_ACCELERATION_KEY"` (GeneralSettings.swift:23). */
const HARDWARE_ACCELERATION_KEY: string = 'HARDWARE_ACCELERATION_KEY';
/** The gap `common/VideoService.ts` reports for the libjami encode/decode switches. */
const VIDEO_ACCELERATION_FEATURE: string = 'video.setHardwareAccelerated';
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';

/*
 * S5 — every metric below is confirmed against
 * results/traversal-source/pages/VideoSettingsView/base.ui.json (a 393x852 capture):
 *
 *   nav bar     [0,53][393,97]      -> BAR_HEIGHT 44
 *   the card    [20,132][373,176]   -> CARD_INSET 20, LIST_TOP 35 below the bar, 44 tall
 *   row label   [40,144][234,164]   -> ROW_TEXT_INSET 20 (16 of it ToggleCell's own)
 *   the switch  [304,139][353,170]  -> its trailing edge at the card's own 20 inset
 *
 * The same inset-grouped geometry the device-VERIFIED pages/CallSettingsPage.ets carries,
 * which is what this screen has to look like a sibling of.
 */
/* ── layout ─────────────────────────────────────────────────────────────────────────────── */
const BAR_HEIGHT: number = 44;
const CARD_INSET: number = 20;
const CARD_RADIUS: number = 10;
const LIST_TOP: number = 35;
const ROW_TEXT_INSET: number = 20;
/** ToggleCell carries 16 of that inset itself; the card supplies the remaining 4. */
const CELL_INSET: number = 4;
const BACK_GLYPH_GAP: number = 6;
const FOOTNOTE_GAP: number = 8;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';

@Entry
@Component
struct VideoSettingsPage {
  /** bindingContract[toggle state] <- svc_preferences (`HARDWARE_ACCELERATION_KEY`). */
  @State toggleState: boolean = false;
  /** True while the preference store is being read or written. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The daemon gap half (b) of the write hits, stated in place rather than as a toast. */
  @State showDaemonNotice: boolean = false;
  /** A preference that never reached disk — a relaunch would lose it, so the page says so. */
  @State showSaveError: boolean = false;

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** The open store; opened lazily because a page cannot have a context before it exists. */
  private store: preferences.Preferences | null = null;
  /** True once the stored value has been read at least once — gates the first-read spinner. */
  private loaded: boolean = false;
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift reads the value in `GeneralSettings`'s property initializer, i.e. before the view
    // first renders.
    this.loadFromPreferences();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
  }

  /** The page is pushed, so it is re-shown after a Back from anywhere above it. */
  onPageShow(): void {
    this.loadFromPreferences();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription and the store handle go whatever happens on the way out.
    // No write can be in flight here: `storeValue` flushes synchronously, so every value the
    // page accepted is already on disk by the time it leaves.
    try {
      this.bag.dispose();
    } finally {
      this.store = null;
      this.isLoading = false;
    }
  }

  /* ── svc_video ────────────────────────────────────────────────────────────────────────── */
  /** Half (b)'s gap — `video.setHardwareAccelerated`, reported by `common/VideoService.ts`. */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((error: DaemonUnavailableError): void => {
      if (error.feature === VIDEO_ACCELERATION_FEATURE) {
        this.isLoading = false;
        this.showDaemonNotice = true;
      }
    }));
  }

  /* ── svc_preferences ──────────────────────────────────────────────────────────────────── */
  private settingsStore(): preferences.Preferences | null {
    if (this.store !== null) {
      return this.store;
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const options: preferences.Options = { name: PREFERENCES_STORE_NAME };
      this.store = preferences.getPreferencesSync(context, options);
    } catch (error) {
      this.store = null;
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings store unavailable: %{public}s', this.errorText);
    }
    return this.store;
  }

  /** Swift `UserDefaults.standard.bool(forKey: hardareAccelerationKey)` — unset is false. */
  private loadFromPreferences(): void {
    this.isLoading = true;
    try {
      const store: preferences.Preferences | null = this.settingsStore();
      if (store === null) {
        this.showSaveError = true;
        return;
      }
      this.toggleState = store.getSync(HARDWARE_ACCELERATION_KEY, false) as boolean;
      this.loaded = true;
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift `UserDefaults.standard.set(enable, forKey: hardareAccelerationKey)`.
   *
   * `putSync` only moves the value into the store's in-memory cache, and the cache dies with
   * the process — so the file write is what a cold relaunch reads back and it has to be DONE
   * before this handler returns. `flushSync()` (`@ohos.data.preferences`, since API 14; the
   * project targets 24) writes it in place; the previous `flush().then()` left the value
   * durable only if nothing killed the app first, which is a race a force-stop a second after
   * the tap wins often enough to lose the setting. Its failure throws here, so it still
   * becomes the in-place notice instead of being dropped. The row is NOT blanked by the write:
   * the switch has to stay on screen through it, and a synchronous write has no in-flight
   * state to show.
   */
  private storeValue(enable: boolean): boolean {
    const store: preferences.Preferences | null = this.settingsStore();
    if (store === null) {
      return false;
    }
    try {
      store.putSync(HARDWARE_ACCELERATION_KEY, enable);
      store.flushSync();
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      return false;
    }
    return true;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * Swift `func enableVideoAcceleration(enable: Bool)` (GeneralSettings.swift:59-66), both
   * halves, in the source's own order: the video service first, then the preference.
   *
   * Swift's leading `if videoAccelerationEnabled == enable { return }` is NOT repeated: it
   * guards a @Published var the model also writes programmatically, while the only caller
   * here is the switch's own onChange, which fires on a real change. Repeating it would add
   * the one thing this screen must not have — a tap that returns silently.
   */
  private setVideoAcceleration(enable: boolean): void {
    this.errorText = '';
    this.showDaemonNotice = false;
    this.showSaveError = false;
    // The switch follows the finger whatever the two writes reach; the notices below state
    // what they reached.
    this.toggleState = enable;
    // (b) Swift `self.videoService.setHardwareAccelerated(withState: enable)` — the capture
    // device/quality half applies for real; the libjami half reports the gap, which
    // `observeDaemonGap` turns into the in-body notice.
    try {
      ServiceRegistry.shared().videoService.setHardwareAccelerated(enable);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    }
    // (a) Swift `UserDefaults.standard.set(enable, forKey: hardareAccelerationKey)` — a real
    // local preference that must survive a cold relaunch.
    if (!this.storeValue(enable)) {
      this.showSaveError = true;
    }
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    if (this.isNavigating) {
      return;
    }
    this.isNavigating = true;
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: SETTINGS_SUMMARY_PAGE }).catch((error: Error): void => {
        this.isNavigating = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s',
          SETTINGS_SUMMARY_PAGE, error.message);
      });
      return;
    }
    router.back();
    this.isNavigating = false;
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * Swift `.navigationTitle(L10n.Global.video)` with `.navigationBarTitleDisplayMode(.inline)`,
   * plus iOS's own leading back item, labelled with the pushing SettingsSummaryView's title
   * "Settings" (SettingsSummaryView.swift:28-70), not "Account".
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Text($r('app.string.global_video'))
        .width('100%')
        .height(BAR_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text($r('app.string.account_page_settings_header'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  build() {
    Column() {
      this.navigationBar()

      if (this.isLoading && !this.loaded) {
        // The FIRST read only: exclusive with the content below, so an in-flight read never
        // renders beside the value it is still reading. A write raises no loading state at
        // all (it is synchronous), so the switch always stays on screen through its own
        // write, which is what the device contract taps and re-reads.
        Row() {
          LoadingProgress()
            .width(BAR_HEIGHT)
            .height(BAR_HEIGHT)
            .color($r('sys.color.font_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          // Swift `List { Section { ToggleCell } }` — one static section, not a collection.
          Column() {
            Column() {
              ToggleCell({
                toggleText: $r('app.string.general_settings_video_acceleration'),
                isOn: this.toggleState,
                identifier: 'video_settings_video_acceleration',
                onToggle: (value: boolean): void => {
                  this.setVideoAcceleration(value);
                }
              })
            }
            .width('100%')
            .padding({ start: LengthMetrics.vp(CELL_INSET), end: LengthMetrics.vp(CELL_INSET) })
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(CARD_RADIUS)

            // The grouped section's FOOTER: what each half of the write actually reached,
            // stated in place rather than as a toast. Below the card, so a notice does not
            // push the card off the captured position.
            if (this.showDaemonNotice) {
              Text($r('app.string.daemon_not_available'))
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(FAILURE_COLOR)
                .padding({
                  start: LengthMetrics.vp(ROW_TEXT_INSET),
                  end: LengthMetrics.vp(ROW_TEXT_INSET)
                })
                .margin({ top: FOOTNOTE_GAP })
            }
            if (this.showSaveError) {
              Text($r('app.string.profile_editor_save_error'))
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(FAILURE_COLOR)
                .padding({
                  start: LengthMetrics.vp(ROW_TEXT_INSET),
                  end: LengthMetrics.vp(ROW_TEXT_INSET)
                })
                .margin({ top: FOOTNOTE_GAP })
            }
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor(FAILURE_COLOR)
                .padding({
                  start: LengthMetrics.vp(ROW_TEXT_INSET),
                  end: LengthMetrics.vp(ROW_TEXT_INSET)
                })
                .margin({ top: FOOTNOTE_GAP })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({
            start: LengthMetrics.vp(CARD_INSET),
            end: LengthMetrics.vp(CARD_INSET),
            top: LengthMetrics.vp(LIST_TOP),
            bottom: LengthMetrics.vp(CARD_INSET)
          })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the page grey the white card sits on.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_video_settings')
  }
}
