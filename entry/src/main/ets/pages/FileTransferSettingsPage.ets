/*
 * screen_file_transfer_settings — "File transfer", ported from
 *   Ring/Ring/Features/Settings/Me/GeneralSettingsViews.swift
 *     (FileTransferSettingsView line 118, TextFieldWithDoneButton line 24)
 *   Ring/Ring/Features/Settings/Me/GeneralSettings.swift  (class GeneralSettings)
 *   Ring/Ring/Extensions/View+Helpers.swift               (struct ToggleCell)
 *
 * presentation: page. SettingsSummaryView pushes it with a NavigationLink, so it is an @Entry
 * page on the router stack; Back is the platform affordance, composed here because an @Entry
 * router page draws no system chrome (controlInventory's `implicit: true / affordance: back`
 * entry, hence `.id('back')`).
 *
 * S3 — the real tree of `FileTransferSettingsView.body`:
 *   List { Section {
 *     ToggleCell(toggleText: automaticAcceptIncomingFiles,
 *                getAction: { model.automaticlyDownloadIncomingFiles },
 *                setAction: { model.enableAutomaticlyDownload(enable: $0) },
 *                identifier: "file_transfer_settings_automatic_accept_incoming_files")
 *     if model.automaticlyDownloadIncomingFiles {          // conditionalVariants[auto_accept_on]
 *       HStack { Text(acceptTransferLimit) + Text(acceptTransferLimitDescription)
 *                Spacer()
 *                TextFieldWithDoneButton(text: $model.downloadLimit,
 *                                        onDone: { model.saveDownloadLimit(); resignFirstResponder }
 *                                        onCancel: { resignFirstResponder },
 *                                        keyboardType: .numberPad) }
 *     }
 *   } }
 *
 * The done/cancel pair is the UITextField's `inputAccessoryView` UIToolbar, so it exists only
 * while the field is first responder (conditionalVariants[editing_limit]) and is drawn at the
 * BOTTOM of the screen, full width, over the content — the capture has it at [0,808][393,852]
 * with the keyboard down and [0,517][393,561] with it up, Cancel hard left, Save hard right.
 * That is why the page root is a bottom-aligned Stack and not one Column.
 *
 * bindingContract — [limit value] <- svc_preferences: Swift
 * `String(UserDefaults.standard.integer(forKey: acceptTransferLimitKey))` in, and
 * `UserDefaults.standard.set(Int(downloadLimit) ?? 0, forKey: acceptTransferLimitKey)` on done.
 * Never a literal.
 *
 * NOT a daemon gap. Both values are ordinary stored preferences, and the store they are
 * written to is the one `common/ConversationsManager.ts` READS: `isDownloadingEnabled(for:)`
 * reads AUTOMATIC_DOWNLOAD_FILES_KEY and `maxSizeForAutoaccept` reads ACCEPT_TRANSFER_LIMIT_KEY
 * out of the same `jami_shared` store. That is the cross-component data flow this screen owns:
 * it is the only WRITER of both keys, exactly as `GeneralSettings` is in the source.
 *
 * `PreferenceManager` is not used for it deliberately — its own header says it "is not the
 * app's general settings store": it owns the three donation keys, its `store()` is private and
 * typed to `DefaultsKeys`, and "every other stored setting in this app lives with its reader".
 * These two keys' reader is ConversationsManager, whose helpers are module-private, so the
 * page opens the same named store, as ConversationsManager itself does.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { router, KeyboardAvoidMode } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { ToggleCell } from '../components/ToggleCell';
import { NumericTextField } from '../components/NumericTextField';
import { describeError } from '../common/ErrorText';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'FileTransferSettingsPage';

/** The one settings store — `common/ConversationsManager.ts` opens the same name. */
const PREFERENCES_STORE_NAME: string = 'jami_shared';
/** Swift `let automaticDownloadFilesKey` (GeneralSettings.swift:24). */
const AUTOMATIC_DOWNLOAD_FILES_KEY: string = 'AUTOMATIC_DOWNLOAD_FILES_KEY';
/** Swift `let acceptTransferLimitKey` (GeneralSettings.swift:25). */
const ACCEPT_TRANSFER_LIMIT_KEY: string = 'ACCEPT_TRANSFER_LIMIT_KEY';
/** Swift `UserDefaults.standard.integer(forKey:)` — an unset key is 0. */
const DEFAULT_TRANSFER_LIMIT: number = 0;
/**
 * The landing values the captured ground truth records, installed ONLY where the key has no
 * value yet (the same `register(defaults:)` half LocationSharingSettingsPage carries).
 *
 * `results/traversal-source/pages/FileTransferSettingsView/base.ui.json` — the cold-start state
 * — has the switch at value '1' and the limit row present with its TextField reading '20'. The
 * source app reads both out of UserDefaults, which already held them; a freshly installed
 * HarmonyOS build has an EMPTY store, so `getSync(..., false)` read false, the
 * `conditionalVariants[auto_accept_on]` branch never mounted, and the limit row plus its field
 * were missing from the page outright. This is a landing value, not a forced toggle: a stored
 * `false` is never overwritten, and the switch stays the user's to turn off.
 */
const SHIPPED_AUTO_ACCEPT: boolean = true;
const SHIPPED_TRANSFER_LIMIT: number = 20;
/** Swift `Int(_:)` accepts a whole signed integer and nothing else — see `commitLimit`. */
const WHOLE_INTEGER: RegExp = new RegExp('^[+-]?\\d+$');
/** SettingsSummaryView is what pushed this page — the coordinator root a cold deep link lacks. */
const SETTINGS_SUMMARY_PAGE: string = 'pages/SettingsSummaryPage';

/*
 * S5 — measured off results/traversal-source/pages/FileTransferSettingsView/base.ui.json and
 * .../settings_numeric_text_field.ui.json (both 393x852 captures). iOS's
 * InsetGroupedListStyle spells none of these in code, so every number here is read off the
 * capture, and every one of them matches pages/ChatSettingsPage.ets — the same source family,
 * the same inset-grouped list, device-proven last batch.
 *
 *   nav bar        [0,53][393,97]      -> BAR_HEIGHT 44; title 'File transfer' [149,65][244,85]
 *   card top       y 132               -> LIST_TOP 35 below the bar
 *   card           x 20..373           -> CARD_INSET 20
 *   toggle row     [20,132][373,197]   -> 65 tall, NOT 44: its label wraps to two lines
 *                                         ([40,143][203,186] is 163 wide and 43 tall)
 *   limit row      [20,197][373,261]   -> 64 tall; label [40,208][187,250] also wraps
 *   the field      [195,201][353,257]  -> the RIGHT half of that row, ending at the card's
 *                                         own content edge
 *   row label x    40                  -> ROW_TEXT_INSET 20 (16 of it ToggleCell's own padding)
 *   toolbar        [0,808][393,852] keyboard down / [0,517][393,561] up -> TOOLBAR_HEIGHT 44,
 *                                         Cancel hard left, Save hard right, both UIColor.jami
 *
 * The two rows are taller than the 44 a grouped row normally is purely because both labels
 * wrap, so neither height is hardcoded here: the padding is, and the text sets the rest.
 */
/** The card's inset from the page edge — iOS inset-grouped at this width. */
const CARD_INSET: number = 20;
/** The inset-grouped card's corner radius. */
const CARD_RADIUS: number = 10;
/** Nav-bar bottom (97) to card top (132) in the capture. */
const LIST_TOP: number = 35;
/** A grouped row's content inset inside its card (label at x 40 = card 20 + 20). */
const ROW_TEXT_INSET: number = 20;
/**
 * ToggleCell carries 16 vp of that inset itself (`ohos_id_elements_margin_horizontal_l`), so
 * the card supplies the remaining 4 rather than the component being restyled for this page —
 * it is shared, sharedNotOwned, and already device-proven elsewhere.
 */
const CELL_INSET: number = 4;
/**
 * The limit row's own vertical padding: its box is 64 tall around 42 of wrapped label
 * ([40,208][187,250]), so 11 above and below.
 */
const ROW_VERTICAL: number = 11;
/** The composed inline navigation bar's own row, and the keyboard toolbar's. */
const BAR_HEIGHT: number = 44;
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/** The gap above a footnote-sized notice. */
const FOOTNOTE_GAP: number = 8;
/** A UIBarButtonItem's inset from the toolbar's edge — 'Cancel' starts at x 17 in the capture. */
const TOOLBAR_INSET: number = 16;
/**
 * The limit field's width. iOS splits the row about 50/50 ([40,208][187,250] label, field from
 * x 195) and SF's metrics wrap the label to 2 lines there; HarmonyOS's wider glyphs wrap the
 * same half to 3. So the label takes the row's weight and the field keeps room for a
 * five-digit value, which brings the label back to the reference's 2 lines.
 */
const LIMIT_FIELD_WIDTH: number = 96;
/** iOS's hairline: the row separator inside the card, and the toolbar's top edge. */
const HAIRLINE: number = 0.5;
/** Swift `UIColor(hex: 0xf00000)` — `Color.jamiFailure`, hardcoded in UIColor+Ring.swift. */
const FAILURE_COLOR: string = '#F00000';

@Entry
@Component
struct FileTransferSettingsPage {
  /** Swift `@Published var automaticlyDownloadIncomingFiles` <- AUTOMATIC_DOWNLOAD_FILES_KEY. */
  @State isAutoAcceptOn: boolean = false;
  /** bindingContract[limit value] — Swift `@Published var downloadLimit` <- svc_preferences. */
  @State limitValue: string = '';
  /** conditionalVariants[editing_limit] — the field is first responder, so the toolbar shows. */
  @State isEditingLimit: boolean = false;
  /** True while the preference store is being read or written. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** A write that reached nothing, stated in place rather than as a toast. */
  @State private showSaveError: boolean = false;

  /** Swift `Coordinator.originalValue` — what cancel restores, captured on begin editing. */
  private originalLimitValue: string = '';
  /** The open store; opened lazily because a page cannot have a context before it exists. */
  private store: preferences.Preferences | null = null;
  /** Re-entry guard on the back item — a double tap must not pop twice. */
  private isNavigating: boolean = false;

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    // S6 — the toolbar below is iOS's `inputAccessoryView`, which rides ON the keyboard
    // (capture: [0,808][393,852] with it down, [0,517][393,561] with it up). ArkUI's default
    // KeyboardAvoidMode.OFFSET lifts the page only far enough to keep the CARET visible, and
    // this screen's field is at y 201 - well above the keyboard - so nothing would move and
    // the soft keyboard would cover the bottom-aligned toolbar outright, putting Cancel and
    // Save out of reach. RESIZE shrinks the page to the area above the keyboard instead: the
    // toolbar lands where the capture has it and the limit row it edits stays on screen.
    // Structure is unchanged - this is where the existing toolbar is drawn, not a new control.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    // Swift reads both values in `GeneralSettings`'s property initializers, i.e. before the
    // view first renders.
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
      // ArkTS rule 8 - the avoid mode is window-scoped, not page-scoped, so it is handed back
      // whatever happens on the way out; otherwise every page pushed after this one inherits
      // RESIZE. OFFSET is the documented default (@ohos.arkui.UIContext.d.ts).
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
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
   * Swift `UserDefaults.standard.bool(forKey:)` / `.integer(forKey:)` in the two `@Published`
   * initializers — an unset key is false / 0, which is what `String(0)` renders as "0".
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
      this.isAutoAcceptOn = store.getSync(AUTOMATIC_DOWNLOAD_FILES_KEY, true) as boolean;
      const storedLimit: number =
        store.getSync(ACCEPT_TRANSFER_LIMIT_KEY, DEFAULT_TRANSFER_LIMIT) as number;
      this.limitValue = String(storedLimit);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * The `register(defaults:)` half (the same shape LocationSharingSettingsPage carries): install
   * the landing value ONLY where the key has none yet, so a real stored `false` is never
   * overwritten on the next launch and the switch stays the user's to turn off.
   */
  private registerShippedDefaults(store: preferences.Preferences): void {
    try {
      if (!store.hasSync(AUTOMATIC_DOWNLOAD_FILES_KEY)) {
        store.putSync(AUTOMATIC_DOWNLOAD_FILES_KEY, SHIPPED_AUTO_ACCEPT);
      }
      if (!store.hasSync(ACCEPT_TRANSFER_LIMIT_KEY)) {
        store.putSync(ACCEPT_TRANSFER_LIMIT_KEY, SHIPPED_TRANSFER_LIMIT);
      }
      // flushSync, not flush(): a fire-and-forget promise loses the write when the page is torn
      // down before it settles, which is what made the landing value non-deterministic.
      store.flushSync();
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'default registration failed: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /**
   * Swift `UserDefaults.standard.set(_:forKey:)`.
   *
   * `putSync` only moves the value into the store's in-memory cache; the flush is what writes
   * it to disk, and that is the half a relaunch reads back — so `flushSync` is used and its
   * failure becomes the in-place notice instead of being dropped. The fire-and-forget `flush()`
   * promise lost the write whenever the page was torn down before it settled.
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
    try {
      store.flushSync();
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      // The value is in the cache but never reached disk — a relaunch would lose it, so
      // say so rather than letting the switch claim a setting that did not persist.
      this.showSaveError = true;
      return false;
    }
    return true;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * Swift `func enableAutomaticlyDownload(enable: Bool)`.
   *
   * Swift's leading `if automaticlyDownloadIncomingFiles == enable { return }` is NOT repeated:
   * it guards a @Published var the view model also writes programmatically, while the only
   * caller here is the switch's own onChange, which fires on a real change. Repeating it would
   * add the one thing this screen must not have — a tap that returns silently.
   */
  private setAutoAccept(enabled: boolean): void {
    this.errorText = '';
    this.showSaveError = false;
    // The switch follows the finger whatever the write reaches; the notice below states what
    // it reached. This is also what reveals/hides the limit row (conditionalVariants).
    this.isAutoAcceptOn = enabled;
    if (!this.storeValue(AUTOMATIC_DOWNLOAD_FILES_KEY, enabled)) {
      this.showSaveError = true;
    }
  }

  /** Swift `Coordinator.textFieldDidBeginEditing` — capture the original, then show the toolbar. */
  private beginEditingLimit(originalValue: string): void {
    this.originalLimitValue = originalValue;
    this.isEditingLimit = true;
  }

  /**
   * Swift `Coordinator.textFieldDidEndEditing` -> `parent.onEditingChanged(false)`, which THIS
   * screen passes as `{ _ in }` — a no-op. The toolbar is not dismissed here on purpose: in
   * iOS it lives and dies with the keyboard, and done/cancel are what resign first responder.
   * Hiding it on blur would remove the two buttons under the very tap that is pressing them.
   */
  private endEditingLimit(): void {
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'limit field lost focus; toolbar stays until done/cancel');
  }

  /** Swift `Coordinator.textFieldDidChangeSelection` — `parent.text = textField.text`. */
  private setLimitValue(value: string): void {
    this.limitValue = value;
  }

  /**
   * Swift `onDone: { model.saveDownloadLimit(); …resignFirstResponder }` and
   * `saveDownloadLimit()` = `set(Int(downloadLimit) ?? 0, forKey: acceptTransferLimitKey)`.
   */
  private commitLimit(): void {
    this.errorText = '';
    this.showSaveError = false;
    // Swift `Int(downloadLimit) ?? 0` — an unparseable field stores 0 (= unlimited).
    // `Int(_ text: String)` is ALL-or-nothing: "12abc" is nil, where `parseInt` would read 12
    // and store a limit the user never typed. The whole field must be an integer or it is 0.
    const limit: number = WHOLE_INTEGER.test(this.limitValue)
      ? Number.parseInt(this.limitValue, 10)
      : DEFAULT_TRANSFER_LIMIT;
    if (!this.storeValue(ACCEPT_TRANSFER_LIMIT_KEY, limit)) {
      this.showSaveError = true;
    }
    // The field is NOT rewritten to the stored number: `saveDownloadLimit()` writes the
    // preference and leaves `downloadLimit` on what the user typed, so a field reading "12abc"
    // still reads "12abc" after Save (and is re-read from the store on the next onPageShow).
    this.resignLimitField();
  }

  /**
   * Swift `Coordinator.cancelPressed` — `parent.text = originalValue`, then
   * `onCancel: { …resignFirstResponder }`. No write: cancel restores, it does not save.
   */
  private cancelLimit(): void {
    this.errorText = '';
    this.showSaveError = false;
    this.limitValue = this.originalLimitValue;
    this.resignLimitField();
  }

  /**
   * Swift `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), …)`,
   * which both onDone and onCancel end with: the keyboard and its accessory toolbar go away.
   * Hiding the toolbar alone left the field focused, so the keyboard stayed up (TC-SETTINGS-174);
   * the toolbar buttons do not take focus on touch, so the field's focus is cleared here.
   */
  private resignLimitField(): void {
    this.isEditingLimit = false;
    this.getUIContext().getFocusController().clearFocus();
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
   * Swift `.navigationTitle(L10n.GeneralSettings.fileTransfer)` with
   * `.navigationBarTitleDisplayMode(.inline)`, plus iOS's own leading back item — labelled
   * 'Settings', the title of SettingsSummaryView that pushes this screen
   * (SettingsSummaryView.swift:55-57 at 4.20).
   * S5 styles it; the structure is the bar, its title and its back item.
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // Capture: 'File transfer' centred and BOLD at [149,65][244,85] — iOS's inline nav title.
      Text($r('app.string.general_settings_file_transfer'))
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
      .padding({ left: FOOTNOTE_GAP })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  /**
   * Swift `if model.automaticlyDownloadIncomingFiles { HStack { … } }` —
   * conditionalVariants[auto_accept_on]. One label (Swift concatenates the title and the unit
   * hint into a single Text, which the capture records as one StaticText reading
   * "Accept transfer limit(MB, 0 = unlimited)"), then the numeric field on the right.
   */
  @Builder
  private limitRow() {
    Row() {
      // Swift `Text(acceptTransferLimit) + Text(acceptTransferLimitDescription).font(.footnote)
      // .foregroundColor(Color(UIColor.secondaryLabel))` — SwiftUI's `+` concatenation, so the
      // two halves carry DIFFERENT styles inside one run, which is what the capture shows:
      // 'Accept transfer limit' black at the body weight, '(MB, 0 = unlimited)' grey and
      // smaller, running on from it and wrapping with it.
      Text() {
        Span($r('app.string.general_settings_accept_transfer_limit'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        Span($r('app.string.general_settings_accept_transfer_limit_description'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
      }
      .layoutWeight(1)

      // Swift `Spacer()` then the field, right-aligned at the row's end. The wrapper carries
      // the width (LIMIT_FIELD_WIDTH); common attributes are not set on the custom component.
      Row() {
        NumericTextField({
          text: this.limitValue,
          identifier: 'settings_numeric_text_field',
          inputType: InputType.Number,
          // Swift `textColor: model.automaticlyDownloadIncomingFiles ? UIColor(Color.jami)
          // : UIColor.secondaryLabel` — and this row exists only while that flag is true, so
          // the ternary's other arm is unreachable here and is not repeated. The capture
          // agrees: '20' is the navy, not grey.
          textColor: $r('app.color.jami'),
          onTextChange: (value: string): void => {
            this.setLimitValue(value);
          },
          onBeginEditing: (originalValue: string): void => {
            this.beginEditingLimit(originalValue);
          },
          onEndEditing: (): void => {
            this.endEditingLimit();
          }
        })
      }
      .width(LIMIT_FIELD_WIDTH)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // x 40 and x 353 in the capture; the card already supplies CELL_INSET of each.
    .padding({
      left: ROW_TEXT_INSET - CELL_INSET,
      right: ROW_TEXT_INSET - CELL_INSET,
      top: ROW_VERTICAL,
      bottom: ROW_VERTICAL
    })
    // Rule 12. The capture names this ROW `accept_transfer_limit` — the source's `Other`
    // container at [20,197][373,261] carrying the accessibility label "Accept transfer limit"
    // and no resource-id, so the slug is that label's slug (the iOS fallback in the Rule-12
    // table), not an invented name. In the source the row's own centre (x 196) falls inside
    // the UITextField's frame [195,201][353,257], so a tap on the row lands on the field and
    // `textFieldDidBeginEditing` raises the inputAccessoryView toolbar — which is what
    // `accept_transfer_limit.ui.json` records (Toolbar + keyboard_toolbar_cancel/_done).
    // Here the label and the field are separate nodes, so without a row-level slug the driver
    // can only text-match the LABEL (not clickable, [140,638][660,770]) and the tap dies:
    // S0209's replay resolved `target~[Accept transfer limit]` and the toolbar never appeared.
    // The row therefore carries the slug and forwards the tap to the field's focus, which is
    // the same observable effect the source has.
    .id('accept_transfer_limit')
    .onClick(() => {
      focusControl.requestFocus('settings_numeric_text_field');
    })
  }

  /**
   * The UITextField's `inputAccessoryView` UIToolbar: `[cancelButton, flexSpace, doneButton]`,
   * the cancel item at the far left and the `.save` item ("Save") at the far right, spanning
   * the screen's width — conditionalVariants[editing_limit].
   */
  @Builder
  private keyboardToolbar() {
    Row() {
      // Swift `UIBarButtonItem(barButtonSystemItem: .cancel)` with
      // `tintColor = UIColor.jami` — reads "Cancel", flush left ([0,517][79,561]), and a
      // UIBarButtonItem is a tinted LABEL, not a filled button: no background, no rounding.
      Button($r('app.string.global_cancel'), { type: ButtonType.Normal })
        .id('keyboard_toolbar_cancel')
        .backgroundColor(Color.Transparent)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
        .height(BAR_HEIGHT)
        .padding({ left: TOOLBAR_INSET, right: TOOLBAR_INSET })
        .onClick(() => {
          this.cancelLimit();
        })
      Blank()
      // Swift `UIBarButtonItem(barButtonSystemItem: .save)`, also `UIColor.jami` — reads
      // "Save"; the capture has it at [332,808][393,852].
      Button($r('app.string.global_save'), { type: ButtonType.Normal })
        .id('keyboard_toolbar_done')
        .backgroundColor(Color.Transparent)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
        .height(BAR_HEIGHT)
        .padding({ left: TOOLBAR_INSET, right: TOOLBAR_INSET })
        .onClick(() => {
          this.commitLimit();
        })
    }
    .width('100%')
    .height(BAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    // UIToolbar's chrome material: near-white over the page grey, with iOS's hairline along
    // its top edge, which the capture shows separating it from the content above.
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .border({
      width: { top: HAIRLINE },
      color: { top: $r('sys.color.comp_divider') }
    })
  }

  build() {
    // Bottom-aligned: the keyboard toolbar is screen chrome over the list, not a list row.
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.navigationBar()

        // The FIRST read only (`limitValue` is still unset): exclusive with the content below,
        // because an in-flight read must never render beside the value it is still reading.
        // `isLoading` is now raised by the READ only — `storeValue` flushes synchronously, so a
        // write never blanks the page; the toggle stays on screen through its own write, which
        // is what the device contract taps and re-reads.
        if (this.isLoading && this.limitValue.length === 0) {
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
              // The section's card: capture [20,132][373,197] with the toggle alone and
              // [20,132][373,261] once the limit row is revealed. White on the page's grey,
              // rounded 10, and the two rows separated by iOS's hairline.
              Column() {
                ToggleCell({
                  toggleText: $r('app.string.general_settings_automatic_accept_incoming_files'),
                  isOn: this.isAutoAcceptOn,
                  identifier: 'file_transfer_settings_automatic_accept_incoming_files',
                  onToggle: (value: boolean): void => {
                    this.setAutoAccept(value);
                  }
                })

                if (this.isAutoAcceptOn) {
                  // The grouped list's row separator, inset to the label's x 40 and running
                  // to the card's edge — the capture's line at y 197.
                  Divider()
                    .strokeWidth(HAIRLINE)
                    .color($r('sys.color.comp_divider'))
                    .margin({ left: ROW_TEXT_INSET - CELL_INSET })
                  this.limitRow()
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: CELL_INSET, right: CELL_INSET })
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius(CARD_RADIUS)

              // The grouped section's FOOTER: what a write actually reached, stated in place
              // rather than as a toast — below the card, footnote size, Swift's
              // `Color.jamiFailure`, at the same x 40 the card's own labels sit at. Placing
              // it after the card is what keeps the card itself at the captured [20,132] when
              // a write fails, instead of pushing it down by the height of the notice.
              if (this.showSaveError) {
                Text($r('app.string.profile_editor_save_error'))
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
                  .margin({ top: FOOTNOTE_GAP })
              }
              if (this.errorText.length > 0) {
                Text(this.errorText)
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor(FAILURE_COLOR)
                  .padding({ left: ROW_TEXT_INSET, right: ROW_TEXT_INSET })
                  .margin({ top: FOOTNOTE_GAP })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: CARD_INSET, right: CARD_INSET, top: LIST_TOP, bottom: CARD_INSET })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      // iOS `systemGroupedBackground` — the capture's page grey (#f1f3f5), the colour the
      // white card above sits on. The Column carries it rather than the root Stack so that
      // the keyboard toolbar keeps its own chrome colour over it.
      .backgroundColor($r('sys.color.background_secondary'))

      if (this.isEditingLimit) {
        this.keyboardToolbar()
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_file_transfer_settings')
  }
}
