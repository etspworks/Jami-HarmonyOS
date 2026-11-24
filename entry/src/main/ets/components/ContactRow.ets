/*
 * comp_contact_row — ported from Ring/Ring/Calls/ContactPicker/ContactPickerView.swift:
 *   `struct ContactRowView` (line 213)              -> ContactRowView below
 *   `struct ContactPickerConversationRow` (line 246) -> ContactPickerConversationRow below
 *
 * They are the picker's two ITEM TYPES, and they differ structurally, not just visually:
 *
 *   ContactRowView                 HStack(12) { avatar | name | Spacer }
 *     - avatar is AvatarWithPresence for a single contact, a plain AvatarSwiftUIView for a
 *       multi-contact ConferencableItem (`if item.contacts.count == 1`);
 *     - tapping it selects the contact and dismisses the sheet.
 *
 *   ContactPickerConversationRow   HStack(12) { avatar | name | Spacer | selection glyph }
 *     - always AvatarWithPresence;
 *     - carries `isSelected` -> checkmark.circle.fill / circle, and tapping it TOGGLES the
 *       selection instead of dismissing.
 *
 * Both are fed from the picker's data sources (svc_contacts / svc_conversation_source), so the
 * item is a parameter and nothing here is a literal.
 */
import { PresenceStatus } from '../common/PresenceService';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { LengthMetrics } from '@kit.ArkUI';

/** Swift both rows: `HStack(spacing: 12)` and `.padding(.vertical, 8)`. */
const ROW_ITEM_GAP: number = 12;
/** Swift `Image(systemName: …).resizable().frame(width: 20, height: 20)`. */
const SELECTION_GLYPH_SIZE: number = 20;

/**
 * One picker row's data. Swift carried two different shapes — `ConferencableItem` (contacts +
 * an AvatarProvider) and `SwarmInfo` + the view model's per-id avatar/presence maps — but the
 * ROW reads the same four values out of either, so the picker resolves them once and both row
 * types take this.
 */
export class PickerItem {
  /** Swift `ConferencableItem.id` / `SwarmInfo.id` — the LazyForEach key and selection key. */
  id: string = '';
  /** Swift `avatarSource.profileName` <- svc_profiles. */
  displayName: string = '';
  /** Swift `avatarSource.avatar` <- svc_profiles. */
  avatar: string = '';
  /** Swift `avatarSource.isGroup` — a swarm with more than one participant. */
  isGroup: boolean = false;
  /** Swift `presenceTracker.status` <- svc_presence. */
  presence: PresenceStatus = PresenceStatus.OFFLINE;
  /**
   * Swift `item.contacts.count == 1` — the ContactRowView branch that decides whether the
   * presence dot is drawn at all. A conference item grouping several contacts has no single
   * presence to show.
   */
  isSingleContact: boolean = true;
}

/** Swift `ContactRowView` — the `.forCall` row. */
@Component
export struct ContactRowView {
  item: PickerItem = new PickerItem();
  /** comp_avatar_with_presence for THIS row, declared by the screen's page. */
  @BuilderParam avatarBuilder: () => void;

  build() {
    // S5 — Swift `HStack(spacing: 12) { ... }.padding(.vertical, 8)`, on the plain white list.
    Row({ space: ROW_ITEM_GAP }) {
      // Swift: `if item.contacts.count == 1 { AvatarWithPresence } else { AvatarSwiftUIView }`.
      if (this.item.isSingleContact) {
        this.avatarBuilder()
      } else {
        AvatarSwiftUIView({
          avatarData: this.item.avatar,
          displayText: this.item.displayName,
          isGroup: this.item.isGroup,
          avatarSize: AvatarSize.MEDIUM_45
        })
      }

      Text(this.item.displayName)
        .maxLines(1)
        // Swift `.truncationMode(.middle)` — a jami id truncates in the middle, not at the end.
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        // Swift `.foregroundColor(.primary)`, default `.body`.
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      top: LengthMetrics.resource($r('sys.float.padding_level4')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4')),
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    })
    .backgroundColor($r('sys.color.background_primary'))
    // Swift `.contentShape(Rectangle())` — the whole row is the tap target, not just the text.
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

/** Swift `ContactPickerConversationRow` — the `.forConversation` row. */
@Component
export struct ContactPickerConversationRow {
  item: PickerItem = new PickerItem();
  /** comp_avatar_with_presence for THIS row, declared by the screen's page. */
  @BuilderParam avatarBuilder: () => void;
  /** Swift `let isSelected: Bool` <- viewModel.selectedConversationIds.contains(id). */
  isSelected: boolean = false;

  build() {
    Row({ space: ROW_ITEM_GAP }) {
      this.avatarBuilder()

      Text(this.item.displayName)
        .maxLines(1)
        // Swift `.truncationMode(.middle)`, as ContactRowView.
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)

      Blank()

      // Swift `Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")`
      // (icon-map: both exact), 20x20, `.foregroundColor(isSelected ? .jami : .secondary)`.
      SymbolGlyph(this.isSelected
        ? $r('sys.symbol.checkmark_circle_fill')
        : $r('sys.symbol.circle'))
        .fontSize(SELECTION_GLYPH_SIZE)
        .fontColor([this.isSelected
          ? $r('app.color.jami')
          : $r('app.color.secondary_label')])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      top: LengthMetrics.resource($r('sys.float.padding_level4')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4')),
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    })
    .backgroundColor($r('sys.color.background_primary'))
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
