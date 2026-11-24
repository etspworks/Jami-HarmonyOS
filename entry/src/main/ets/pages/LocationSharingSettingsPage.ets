/*
 * screen_location_sharing_settings — "Location sharing", ported from
 *   Ring/Ring/Features/Settings/Me/GeneralSettingsViews.swift (struct LocationSharingSettingsView,
 *                                                              line 164)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift       (DurationPickerView, line 290)
 *   Ring/Ring/Features/Settings/Me/GeneralSettings.swift      (class GeneralSettings)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`). navOut is empty.
 *
 * S3 — the real tree of `LocationSharingSettingsView.body`:
 *
 *   ZStack {
 *     List { Section {
 *       ToggleCell(toggleText: L10n.GeneralSettings.limitLocationSharingDuration,
 *                  getAction: { model.limitLocationSharing },
 *                  setAction: { model.enableLocationSharingLimit(enable: $0) },
 *                  identifier: "location_sharing_settings_limit_location_sharing_duration")
 *       if model.limitLocationSharing {
 *         HStack { Text(limitLocationSharingDuration); Spacer()
 *                  Text(model.locationSharingDurationString); Image(systemName: "chevron.down") }
 *           .onTapGesture { showingDurationPicker = true }
 *           .accessibilityIdentifier("location_sharing_settings_duration")
 *       }
 *     } .navigationTitle(L10n.GeneralSettings.locationSharing) }
 *     if showingDurationPicker {
 *       Group {
 *         Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
 *           .onTapGesture { showingDurationPicker = false }
 *           .accessibilityIdentifier("location_sharing_settings_duration_picker_dismiss")
 *         DurationPickerView(duration: $model.locationSharingDuration,
 *                            isPresented: $showingDurationPicker)
 *           .background(systemBackground).cornerRadius(12).shadow(radius: 5)
 *       }
 *     }
 *   }
 *
 * One toggle, one conditional duration row, and — inside this very view's ZStack, NOT as a
 * separate screen — a dimming layer plus the duration picker. That is why the root here is a
 * Stack and comp_duration_picker is mounted into it: conditionalVariants[limit_on] is the row,
 * conditionalVariants[picker_open] is the dimming layer + the picker, and both are real ArkUI
 * `if` branches on the state the source branches on. The source declares no other control.
 *
 * bindingContract — [duration value] <- svc_preferences: `locationSharingDurationString` is
 * `convertMinutesToText(minutes:)` over `UserDefaults.standard.integer(forKey:
 * locationSharingDurationKey)` (GeneralSettings.swift:37-41). Never a literal.
 *
 * NOT A DAEMON GAP. Both values are ordinary stored preferences — `enableLocationSharingLimit`
 * writes LIMIT_LOCATION_SHARING_DURATION_KEY (GeneralSettings.swift:68-73) and
 * `DurationPickerWrapper` writes LOCATION_SHARING_DURATION_KEY (UtilitiesViews.swift:326) — so a
 * real, persisted flip is owed and no daemon notice belongs on this screen. The store is the
 * one `common/ConversationsManager.ts` opens ('jami_shared'), reached exactly as
 * pages/FileTransferSettingsPage.ets reaches it for the sibling GeneralSettings keys: that
 * page's header records why `PreferenceManager` is not the route (its store is private and
 * typed to its own donation keys).
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { LengthMetrics, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { ToggleCell } from '../components/ToggleCell';
import { DurationPickerView } from '../components/DurationPicker';
import { describeError } from '../common/ErrorText';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { LocationSharingService } from '../common/LocationSharingService';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LocationSharingSettingsPage';

/** The one settings store — `common/ConversationsManager.ts` opens the same name. */
const PREFERENCES_STORE_NAME: string = 'jami_shared';
/** Swift `let limitLocationSharingDurationKey` (GeneralSettings.swift:26). */
const LIMIT_LOCATION_SHARING_DURATION_KEY: string = 'LIMIT_LOCATION_SHARING_DURATION_KEY';
/** Swift `let locationSharingDurationKey` (GeneralSettings.swift:27). */
const LOCATION_SHARING_DURATION_KEY: string = 'LOCATION_SHARING_DURATION_KEY';
/** Swift `UserDefaults.standard.integer(forKey:)` — an unset key is 0. */
const DEFAULT_DURATION_MINUTES: number = 0;
/**
 * Swift AppDelegate.swift:284-288 — the SHIPPED defaults, installed once when the key has no
 * value yet: `set(true, forKey: limitLocationSharingDurationKey)` and
 * `set(15, forKey: locationSharingDurationKey)`. This screen's own capture is that state (the
 * base ui.json has the Switch at value '1' and the duration row reading '15m'), so a fresh
 * install that skipped the registration would render the toggle OFF and no duration row.
 */
const SHIPPED_LIMIT_ENABLED: boolean = true;
const SHIPPED_DURATION_MINUTES: number = 15;
/** `LocationSharingService.startSharingLocation` takes its `duration` in SECONDS. */
const SECONDS_PER_MINUTE: number = 60;
/**
 * feat_location. Where the configured session bound is published for the location-sharing
 * feature to pick up: `startSharingLocation(accountId, peerUri, duration)` — 0 meaning an
 * unbounded share, which is that service's own contract (OutgoingLocationSharingInstance only
 * arms its expiry timer for `duration > 0`).
 */
const LOCATION_SHARE_LIMIT_SECONDS: string = 'locationShareLimitSeconds';
/** Swift `convertMinutesToText(minutes:)` — `hours = minutes / 60`, `rem = minutes % 60`. */
const MINUTES_PER_HOUR: number = 60;
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';

/*
 * Style tokens: state.json.generation.styleBaseline (device-proven, read-only) as the sibling
 * inset-grouped settings pages already spell them — pages/ChatSettingsPage.ets and
 * pages/FileTransferSettingsPage.ets, the same source family and the same iOS
 * InsetGroupedListStyle. The numbers are corroborated by this screen's OWN capture,
 * results/traversal-source/pages/LocationSharingSettingsView/base.ui.json (393x852):
 *
 *   nav bar      [0,53][393,97]       -> BAR_HEIGHT 44; title 'Location sharing' [130,65][262,85]
 *   toggle row   [20,132][373,197]    -> CARD_INSET 20, LIST_TOP 35 below the bar
 *   duration row [20,197][373,261]    -> the second row of the SAME card, separated by a hairline
 *   row label    x 40                 -> ROW_TEXT_INSET 20 (16 of it ToggleCell's own padding)
 *   value '15m'  [294,219][326,239]   -> trailing, grey
 *   chevron.down [336,225][351,233]   -> a 15x8 glyph right of the value
 */
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** The inset-grouped card's corner radius. */
const CARD_RADIUS: number = 10;
/** Nav-bar bottom (97) to card top (132) in the capture. */
const LIST_TOP: number = 35;
/** A grouped row's content inset inside its card (label at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/** ToggleCell carries 16 vp of that inset itself, so the card supplies the remaining 4. */
const CELL_INSET: number = 4;
/** The duration row's own vertical padding: a 64-tall box around 42 of wrapped label. */
const ROW_VERTICAL: number = 11;
/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/** The gap above a footnote-sized notice. */
const FOOTNOTE_GAP: number = 8;
/** iOS's hairline: the row separator inside the card. */
const HAIRLINE: number = 0.5;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';
/**
 * The disclosure glyph of the duration row. Swift gives `Image(systemName: "chevron.down")`
 * no font of its own, so it inherits the row's `.body` (17pt) — which is exactly the capture's
 * [336,225][351,233], a 15x8 box (chevron.down is wide and short at 17pt).
 */
const CHEVRON_SIZE: number = 17;
/** Capture: the value ends at x 326, the glyph starts at 336. */
const CHEVRON_GAP: number = 10;
/** Swift `Color.black.opacity(0.4)` on the dimming layer. */
const SCRIM_COLOR: string = '#66000000';
/** Swift `.cornerRadius(12)` on the picker sheet. */
const PICKER_RADIUS: number = 12;
/** Swift `.shadow(radius: 5)`. */
const PICKER_SHADOW: number = 5;
/** The picker sheet's own inset from the screen edge inside the centred ZStack. */
const PICKER_INSET: number = 24;

@Entry
@Component
struct LocationSharingSettingsPage {
  /**
   * bindingContract[duration value] <- svc_preferences. Swift
   * `@Published var locationSharingDurationString`, filled by `convertMinutesToText(minutes:)`
   * over LOCATION_SHARING_DURATION_KEY. The rendered text, never a literal.
   */
  @State durationValue: string = '';
  /**
   * conditionalVariants[limit_on] — Swift `@Published var limitLocationSharing` <-
   * LIMIT_LOCATION_SHARING_DURATION_KEY. Gates the duration row.
   */
  @State isLimitOn: boolean = false;
  /** conditionalVariants[picker_open] — Swift `@SwiftUI.State private var showingDurationPicker`. */
  @State isPickerOpen: boolean = false;
  /** True while the preference store is being read or written. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** A write that reached nothing, stated in place rather than as a toast. */
  @State showSaveError: boolean = false;
  /**
   * Swift `@Published var locationSharingDuration` — the stored value in MINUTES, which the
   * picker binds to and `durationValue` is rendered from.
   */
  @State durationMinutes: number = DEFAULT_DURATION_MINUTES;

  /** The open store; opened lazily because a page cannot have a context before it exists. */
  private store: preferences.Preferences | null = null;
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // Swift reads both values in `GeneralSettings`'s property initializers plus its `init`,
    // i.e. before the view first renders.
    this.loadFromPreferences();
  }

  /** The page is pushed, so it is re-shown after a Back from anywhere above it. */
  onPageShow(): void {
    this.loadFromPreferences();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the store handle is dropped whatever happens on the way out. A pending
    // flush keeps its own reference and still completes; the page just stops holding one.
    try {
      this.store = null;
    } finally {
      this.isLoading = false;
    }
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

  /**
   * Swift `UserDefaults.standard.bool(forKey: limitLocationSharingDurationKey)` and
   * `.integer(forKey: locationSharingDurationKey)` — an unset key is false / 0.
   */
  private loadFromPreferences(): void {
    this.isLoading = true;
    try {
      const store: preferences.Preferences | null = this.settingsStore();
      if (store === null) {
        this.showSaveError = true;
        return;
      }
      this.registerShippedDefaults(store);
      this.isLimitOn = store.getSync(LIMIT_LOCATION_SHARING_DURATION_KEY, false) as boolean;
      this.durationMinutes =
        store.getSync(LOCATION_SHARING_DURATION_KEY, DEFAULT_DURATION_MINUTES) as number;
      this.durationValue = this.convertMinutesToText(this.durationMinutes);
      this.publishShareLimit();
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift AppDelegate's `registerDefaults` half (AppDelegate.swift:284-288) — install the
   * shipped value ONLY where the key has none yet, so a real stored `false` is never
   * overwritten on the next launch.
   */
  private registerShippedDefaults(store: preferences.Preferences): void {
    try {
      if (!store.hasSync(LIMIT_LOCATION_SHARING_DURATION_KEY)) {
        store.putSync(LIMIT_LOCATION_SHARING_DURATION_KEY, SHIPPED_LIMIT_ENABLED);
      }
      if (!store.hasSync(LOCATION_SHARING_DURATION_KEY)) {
        store.putSync(LOCATION_SHARING_DURATION_KEY, SHIPPED_DURATION_MINUTES);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'default registration failed: %{public}s',
        describeError(error as BusinessError));
      return;
    }
    // flushSync, not flush(): a fire-and-forget promise loses the write when the page is torn
    // down before it settles, so the shipped defaults were persisting non-deterministically.
    try {
      store.flushSync();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'default flush failed: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /**
   * feat_location — what this screen's two preferences are FOR. The pair is the session bound
   * `LocationSharingService.startSharingLocation` is handed as its `duration` (seconds, 0 =
   * unbounded), so it is published here for the sharing call sites to read; without that the
   * stored setting is inert.
   *
   * A share already in flight keeps the bound it was constructed with — an
   * `OutgoingLocationSharingInstance` arms its expiry timer in its own constructor, exactly as
   * iOS's ConversationViewController reads the preference at share start — so a live session is
   * read, not re-timed.
   */
  private publishShareLimit(): void {
    const seconds: number = this.isLimitOn ? this.durationMinutes * SECONDS_PER_MINUTE : 0;
    AppStorage.setOrCreate<number>(LOCATION_SHARE_LIMIT_SECONDS, seconds);
    const sharing: LocationSharingService = ServiceRegistry.shared().locationSharingService;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'location share bound %{public}d s, %{public}d share(s) already in flight',
      seconds, sharing.getOutgoingInstances().asArray().length);
  }

  /**
   * Swift `UserDefaults.standard.set(_:forKey:)`.
   *
   * `putSync` only moves the value into the store's in-memory cache; `flush()` is what writes
   * it to disk, and that is the half a relaunch reads back — so the flush's failure becomes the
   * in-place notice instead of being dropped.
   */
  private storeValue(key: string, value: preferences.ValueType): boolean {
    const store: preferences.Preferences | null = this.settingsStore();
    if (store === null) {
      return false;
    }
    try {
      store.putSync(key, value);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      return false;
    }
    // flushSync, not flush(): the fire-and-forget promise lost the write whenever the page was
    // torn down before it settled, and the handler had already returned true by then.
    try {
      store.flushSync();
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      // The value is in the cache but never reached disk — a relaunch would lose it, so say
      // so rather than letting the control claim a setting that did not persist.
      this.showSaveError = true;
      return false;
    }
    return true;
  }

  /** Swift `private func convertMinutesToText(minutes: Int) -> String`. */
  private convertMinutesToText(minutes: number): string {
    const hours: number = Math.floor(minutes / MINUTES_PER_HOUR);
    const remainingMinutes: number = minutes % MINUTES_PER_HOUR;
    if (hours > 0 && remainingMinutes > 0) {
      return String(hours) + 'h ' + String(remainingMinutes) + 'm';
    }
    if (hours > 0) {
      return String(hours) + 'h';
    }
    return String(remainingMinutes) + 'm';
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * Swift `func enableLocationSharingLimit(enable: Bool)` (GeneralSettings.swift:68-73).
   *
   * Swift's leading `if self.limitLocationSharing == enable { return }` is NOT repeated: it
   * guards a @Published var the view model also writes programmatically, while the only caller
   * here is the switch's own onChange, which fires on a real change. Repeating it would add the
   * one thing this screen must not have — a tap that returns silently.
   */
  private setLimit(enabled: boolean): void {
    this.errorText = '';
    this.showSaveError = false;
    // The switch follows the finger whatever the write reaches; the notice below states what it
    // reached. This is also what reveals/hides the duration row (conditionalVariants[limit_on]).
    this.isLimitOn = enabled;
    if (!this.storeValue(LIMIT_LOCATION_SHARING_DURATION_KEY, enabled)) {
      this.showSaveError = true;
    }
    this.publishShareLimit();
  }

  /** Swift the duration row's `.onTapGesture { showingDurationPicker = true }`. */
  private openPicker(): void {
    if (this.isPickerOpen) {
      // Re-entry guard: the row stays tappable under the dimming layer's sibling, and
      // re-opening an open picker would reset the wheels under the finger.
      return;
    }
    this.isPickerOpen = true;
  }

  /**
   * Swift the dimming layer's `.onTapGesture { showingDurationPicker = false }` and
   * DurationPickerView's own Close button writing `isPresented = false`.
   */
  private closePicker(): void {
    this.isPickerOpen = false;
  }

  /**
   * Swift `DurationPickerWrapper`'s `picker.onDurationChanged` — `UserDefaults.standard.set(
   * duration, forKey: locationSharingDurationKey)` then `self.duration = duration`
   * (UtilitiesViews.swift:322-330). The component reports; this writes.
   */
  private saveDuration(minutes: number): void {
    this.errorText = '';
    this.showSaveError = false;
    // The rendered value follows the wheel whatever the write reaches.
    this.durationValue = this.convertMinutesToText(minutes);
    // The component writes the @Link too; assigning here makes the published bound below read
    // the value this call was given rather than depending on that write having landed first.
    this.durationMinutes = minutes;
    if (!this.storeValue(LOCATION_SHARING_DURATION_KEY, minutes)) {
      this.showSaveError = true;
    }
    this.publishShareLimit();
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
   * Swift `.navigationTitle(L10n.GeneralSettings.locationSharing)` with
   * `.navigationBarTitleDisplayMode(.inline)`, plus iOS's own leading back item — labelled
   * 'Settings', the title of SettingsSummaryView that pushes this screen
   * (SettingsSummaryView.swift:58-60 at 4.20).
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // Capture: 'Location sharing' centred and BOLD at [130,65][262,85].
      Text($r('app.string.general_settings_location_sharing'))
        .width('100%')
        .height(BAR_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      // Capture: chevron + label in the Jami navy (#00345F = app.color.jami), the back item's
      // box reaching the screen's left edge ([0,53][93,97]). The inset is padding, not margin,
      // so the tap target still reaches that edge as the source's own back item does.
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
      // Localized edges (LengthMetrics start/end), never left/right: an absolute edge is the
      // one thing that survives RTL mirroring, and it would park the back item on the right.
      .padding({ start: LengthMetrics.vp(FOOTNOTE_GAP) })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  /**
   * conditionalVariants[limit_on] — Swift
   * `if model.limitLocationSharing { HStack { Text(label); Spacer(); Text(value);
   * Image(systemName: "chevron.down") }.onTapGesture { … } }`.
   *
   * ONE clickable row spanning the card, with the slug on that row: the capture carries the
   * slug on the row's three children (label, value, glyph), none of which is clickable there,
   * and a handler on a descendant of the slugged node reads `contract-control-inert`. The row
   * label repeats the toggle's own string — that is the source, not a copy-paste slip
   * (GeneralSettingsViews.swift:183).
   */
  @Builder
  private durationRow() {
    Row({ space: CHEVRON_GAP }) {
      Text($r('app.string.general_settings_limit_location_sharing_duration'))
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))

      // Swift `Spacer()` then `Text(model.locationSharingDurationString)` —
      // bindingContract[duration value], the preference-backed value, never a literal.
      // Swift applies NO `.foregroundColor` here (GeneralSettingsViews.swift:186), so the
      // value takes the row's default `.label` — the capture's ink is (0,0,0), not grey.
      Text(this.durationValue)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .maxLines(1)

      // Swift `Image(systemName: "chevron.down")` — icon-map.json: exact,
      // sys.symbol.chevron_down. Untinted in the source, so it is the row's `.label` black,
      // which is what the capture shows at [336,225][351,233] — NOT iOS's grey disclosure
      // indicator (that one belongs to a NavigationLink row; this row is a tap gesture).
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(CHEVRON_SIZE)
        .fontColor([$r('app.color.label')])
        // Decorative: the row already reads its label and its duration value.
        .accessibilityLevel('no')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(ROW_TEXT_INSET - CELL_INSET),
      end: LengthMetrics.vp(ROW_TEXT_INSET - CELL_INSET),
      top: LengthMetrics.vp(ROW_VERTICAL),
      bottom: LengthMetrics.vp(ROW_VERTICAL)
    })
    .id('location_sharing_settings_duration')
    .onClick(() => {
      this.openPicker();
    })
  }

  build() {
    // Swift's own `ZStack` — the picker is a layer of THIS view, not a pushed screen, and the
    // ZStack's default alignment is .center, which is where the source's picker sheet lands.
    Stack() {
      Column() {
        this.navigationBar()

        // The FIRST read only (`durationValue` is still unset): exclusive with the content
        // below, because an in-flight read must never render beside the value it is still
        // reading. A later write's flush must NOT blank the page — the toggle has to stay on
        // screen through its own write, which is what the device contract taps and re-reads.
        if (this.isLoading && this.durationValue.length === 0) {
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
            // Swift `List { Section { … } }` — one static section, not a collection.
            Column() {
              // The section's white inset-grouped card: capture [20,132][373,197] with the
              // toggle alone, [20,132][373,261] once the duration row is revealed.
              Column() {
                ToggleCell({
                  toggleText: $r('app.string.general_settings_limit_location_sharing_duration'),
                  isOn: this.isLimitOn,
                  identifier: 'location_sharing_settings_limit_location_sharing_duration',
                  onToggle: (value: boolean): void => {
                    this.setLimit(value);
                  }
                })

                if (this.isLimitOn) {
                  // The grouped list's row separator, inset to the label's x 40 and running to
                  // the card's edge — the capture's line at y 197.
                  Divider()
                    .strokeWidth(HAIRLINE)
                    .color($r('sys.color.comp_divider'))
                    .margin({ start: LengthMetrics.vp(ROW_TEXT_INSET - CELL_INSET) })
                  this.durationRow()
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ start: LengthMetrics.vp(CELL_INSET), end: LengthMetrics.vp(CELL_INSET) })
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)

              // The grouped section's FOOTER: what a write actually reached, stated in place
              // rather than as a toast. Below the card, so a failure does not push the card
              // off the captured [20,132].
              if (this.showSaveError) {
                Text($r('app.string.profile_editor_save_error'))
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ start: LengthMetrics.vp(ROW_TEXT_INSET), end: LengthMetrics.vp(ROW_TEXT_INSET) })
                  .margin({ top: FOOTNOTE_GAP })
              }
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ start: LengthMetrics.vp(ROW_TEXT_INSET), end: LengthMetrics.vp(ROW_TEXT_INSET) })
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

      // conditionalVariants[picker_open] — Swift `if showingDurationPicker { Group { … } }`.
      if (this.isPickerOpen) {
        // Swift `Color.black.opacity(0.4).edgesIgnoringSafeArea(.all).onTapGesture { … }`.
        // It is MEANT to take the touch (that is its dismiss gesture), and it is rendered
        // conditionally, so it swallows nothing while the picker is closed. While the picker IS
        // open it is the TOPMOST full-bleed sibling, so at HitTestMode.Default it masked every
        // row underneath: the toggle's tap only ever dismissed the picker and its Switch never
        // reached onChange. Transparent is `self and children respond, AND allow hit test of
        // other nodes which is masked by this node` (enums.d.ts HitTestMode) — the dismiss
        // gesture still fires and the ToggleCell's Switch underneath still gets the same tap.
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(SCRIM_COLOR)
          .hitTestBehavior(HitTestMode.Transparent)
          .id('location_sharing_settings_duration_picker_dismiss')
          // The dimming layer draws nothing, so it has no readable name of its own; the
          // controlInventory label for this control, verbatim.
          .accessibilityText($r('app.string.accessibility_location_sharing_duration_picker_dismiss'))
          .onClick(() => {
            this.closePicker();
          })

        // Swift `DurationPickerView(duration: $model.locationSharingDuration,
        // isPresented: $showingDurationPicker).background(systemBackground)
        // .cornerRadius(12).shadow(radius: 5)` — comp_duration_picker, mounted here.
        Column() {
          DurationPickerView({
            duration: $durationMinutes,
            isPresented: $isPickerOpen,
            onDurationChanged: (minutes: number): void => {
              this.saveDuration(minutes);
            }
          })
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(PICKER_RADIUS)
        .shadow({ radius: PICKER_SHADOW })
        .margin({ start: LengthMetrics.vp(PICKER_INSET), end: LengthMetrics.vp(PICKER_INSET) })
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_location_sharing_settings')
  }
}
