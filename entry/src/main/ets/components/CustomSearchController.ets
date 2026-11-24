/*
 * comp_custom_search_controller — ported from Ring/Ring/UI/CustomSearchController.swift
 * (`class CustomSearchController: UISearchController`) together with the CustomSearchBar it
 * owns (Ring/Ring/UI/CustomSearchBar.swift).
 *
 * The trailing scanner button the Swift subclass adds belongs to the in-place search results
 * screen (screen_smart_list_search), not to the smart list's search bar, so it is not built
 * here. This wraps the field (comp_search_bar) with the search bar's own layout metrics.
 */
import { SearchBar } from './SearchBar';

/** Swift `searchTextField.topAnchor.constraint(..., constant: 7)`. */
const SEARCH_BAR_TOP_GAP: number = 7;

@Component
export struct CustomSearchController {
  /** Swift `searchBar.text`, two-way onto the hosting model's search text. */
  @Link text: string;
  /**
   * Swift `searchController.searchBar.placeholder` — forwarded to the field. The smart list's
   * UISearchController is never given one, so UIKit's own `L10n.Smartlist.searchBar` is the
   * default; SwarmCreation sets `swarmcreation_search_bar` and passes it in.
   */
  placeholder: ResourceStr = $r('app.string.smartlist_search_bar');
  /** Swift `searchActiveBinding` — forwarded from the field. */
  onActivate?: () => void;
  /** Swift `updateSearchResults(for:)` — forwarded from the field. */
  onTextChange?: (text: string) => void;

  private activated(): void {
    const handler: (() => void) | undefined = this.onActivate;
    if (handler !== undefined) {
      handler();
    }
  }

  private textChanged(value: string): void {
    const handler: ((text: string) => void) | undefined = this.onTextChange;
    if (handler !== undefined) {
      handler(value);
    }
  }

  build() {
    Row() {
      SearchBar({
        text: $text,
        placeholder: this.placeholder,
        onActivate: (): void => {
          this.activated();
        },
        onTextChange: (value: string): void => {
          this.textChanged(value);
        }
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // Swift `searchFieldLeading = 15` plus the navigation bar's own 16 pt side margin; the
    // capture puts the field at x = 16 .. 377 on a 393 pt screen.
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
    .margin({
      top: SEARCH_BAR_TOP_GAP,
      bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }
}
