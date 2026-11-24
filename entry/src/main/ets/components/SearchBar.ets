/*
 * comp_search_bar — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/SearchBar.swift
 * (`navigationBarSearch` / `NavigationSearchControllerHost` / `SearchBarWrapperController`).
 *
 * The iOS side is a UISearchController hosted in the navigation item; HarmonyOS has no
 * navigation-item search, so what survives is the search field itself plus the two signals the
 * Swift coordinator exchanged with the model: the text (`model.searchFlow.text`, written
 * through `updateSearchText`) and whether search is active (`model.searchFlow.isActive`,
 * written through `setSearchActive`).
 *
 * The field carries the source's own identifier, `searchBarTextField`.
 *
 * S5 style: UISearchBar draws its own chrome and the app never overrides it, so the values are
 * the platform's, mapped by role — a 36 pt rounded field on the system fill grey, a leading
 * magnifying-glass glyph, and `.secondaryLabel` placeholder text. The glyph is the SF Symbol
 * `magnifyingglass` the capture records inside the field (icon-map: exact ->
 * sys.symbol.magnifyingglass); it is chrome the framework paints, not a control.
 */
/** UISearchBar's field height. */
const FIELD_HEIGHT: number = 36;
/** The magnifying glass sits in a 20 pt box, 8 pt in from the field's leading edge. */
const GLYPH_SIZE: number = 20;
const GLYPH_INSET: number = 8;
/** Text clears the glyph: inset + glyph + gap. */
const TEXT_INSET: number = GLYPH_INSET + GLYPH_SIZE + 4;

/** The action contract calls this control the **Search field**. */
@Component
export struct SearchBar {
  /** Swift `searchTextBinding` — two-way onto `model.searchFlow.text`. */
  @Link text: string;
  /**
   * Swift `searchController.searchBar.placeholder`.
   *
   * S6: the smart list reaches the field through `navigationBarSearch` (SearchBar.swift:30),
   * a plain UISearchController that is never given a placeholder — so UIKit draws its own,
   * `L10n.Smartlist.searchBar` = "Search", which is what every capture shows.
   * `smartlist_search_bar_placeholder` ("Enter name…") is the CONTACT PICKER's prompt
   * (ContactPickerView.swift:50), not this screen's; S5 had it here by name similarity.
   */
  placeholder: ResourceStr = $r('app.string.smartlist_search_bar');
  /** Swift `searchActiveBinding` set to true — the search controller was presented. */
  onActivate?: () => void;
  /** Swift `Coordinator.updateSearchResults(for:)` — the query changed. */
  onTextChange?: (text: string) => void;

  private activate(): void {
    const handler: (() => void) | undefined = this.onActivate;
    if (handler !== undefined) {
      handler();
    }
  }

  private textChanged(value: string): void {
    this.text = value;
    const handler: ((text: string) => void) | undefined = this.onTextChange;
    if (handler !== undefined) {
      handler(value);
    }
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      TextInput({ text: this.text })
        .id('searchBarTextField')
        .width('100%')
        .height(FIELD_HEIGHT)
        .backgroundColor($r('sys.color.comp_background_gray'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .caretColor($r('app.color.jami'))
        .padding({ left: TEXT_INSET, right: GLYPH_INSET })
        .onChange((value: string) => {
          this.textChanged(value);
        })
        // Tap only. `.onFocus` also fires when the field REGAINS focus as the page returns
        // from the pushed search results, so activating there re-pushed search results the
        // instant Back popped them and the smart list could never come back.
        .onClick(() => {
          this.activate();
        })

      // UISearchBar's prompt, drawn as a real Text instead of TextInput's own `placeholder`:
      // `uitest dumpLayout` reports a TextInput's VALUE and never its placeholder (there is no
      // attribute in text_input.d.ts that surfaces it), so with the built-in placeholder the
      // field's prompt is absent from the dumped tree and the L3.5 state contract cannot see
      // the string the source's SearchField shows. Same metrics and role colour as the
      // placeholder it replaces.
      if (this.text.length === 0) {
        Text(this.placeholder)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: TEXT_INSET, right: GLYPH_INSET })
          .hitTestBehavior(HitTestMode.Transparent)
      }

      // UISearchBar's own leading glyph — chrome, drawn behind the field's touch area.
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(GLYPH_SIZE)
        .fontColor([$r('app.color.secondary_label')])
        .margin({ left: GLYPH_INSET })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .layoutWeight(1)
    .height(FIELD_HEIGHT)
  }
}
