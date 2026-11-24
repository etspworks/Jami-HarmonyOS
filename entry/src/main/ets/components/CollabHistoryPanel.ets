/*
 * comp_collab_history_panel — ported from
 * Ring/Ring/Features/Collab/CollabHistoryPanel.swift `class CollabHistoryPanel: UIView` (line 28):
 *
 *   titleLabel  L10n.Collab.history
 *   close       L10n.Global.close, "collab_history_close"  -> onClose()
 *   separator
 *   table       one row per (version, label); the row being READ carries a checkmark accessory
 *               and the accessibility label L10n.Collab.versionShown(label);
 *               didSelectRowAt -> onSelect(version)
 *
 * The rows are svc_collaboration's CollaborativeVersion list — never a literal — and the marked
 * row is whichever commit the editor is currently showing.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';

import { CollaborativeVersion } from '../model/CollaborativeVersion';

/* ── S5 metrics, the source's own (CollabEditorViewController.swift:494-501) ─────── */
/** Swift `barHeight = 48` on the panel's own title band. */
const PANEL_BAR_HEIGHT: number = 48;
/** Swift `margin = 8`. */
const PANEL_MARGIN: number = 8;
/** A UITableView row's minimum height. */
const PANEL_ROW_HEIGHT: number = 44;
/** The checkmark accessory on the row being read. */
const PANEL_CHECK_SIZE: number = 16;

/** Swift `entries: [(version: CollaborativeVersion, label: String)]`. */
export class CollabVersionEntry {
  version: CollaborativeVersion;
  /** Swift `entry.label` — the date/author line the panel renders. */
  label: string;

  constructor(version: CollaborativeVersion, label: string) {
    this.version = version;
    this.label = label;
  }
}

@Component
export struct CollabHistoryPanel {
  /** bindingContract[history rows] <- svc_collaboration. */
  entries: ArrayDataSource<CollabVersionEntry> = new ArrayDataSource<CollabVersionEntry>([]);
  /** Swift `shownCommitId` — the version being read, marked in the list. */
  @Prop shownCommitId: string = '';
  /** Swift `onSelect` — show that version. */
  onSelect?: (version: CollaborativeVersion) => void;
  /** Swift `onClose` — the reading is over. */
  onClose?: () => void;

  private select(entry: CollabVersionEntry): void {
    const handler: ((version: CollaborativeVersion) => void) | undefined = this.onSelect;
    if (handler !== undefined) {
      handler(entry.version);
    }
  }

  build() {
    Column() {
      Row() {
        // Swift `.preferredFont(forTextStyle: .headline)` (semibold).
        Text($r('app.string.collab_history'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(600)
          .fontColor($r('app.color.label'))
        Blank()
        // Swift `UIButton(type: .system)` with no tint set: systemBlue (iPhone 4.20).
        Text($r('app.string.global_close'))
          .id('collab_history_close')
          .fontSize($r('sys.float.Body_L'))
          .fontColor('#007AFF')
          .onClick(() => {
            const handler: (() => void) | undefined = this.onClose;
            if (handler !== undefined) {
              handler();
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: PANEL_BAR_HEIGHT })
      .padding({
        start: LengthMetrics.vp(PANEL_MARGIN),
        end: LengthMetrics.vp(PANEL_MARGIN)
      })

      // Swift `separator`.
      Divider()
        .color($r('sys.color.comp_divider'))

      List() {
        LazyForEach(this.entries, (entry: CollabVersionEntry) => {
          ListItem() {
            Row() {
              Text(entry.label)
                .fontSize($r('sys.float.Body_M'))
                .fontColor($r('app.color.label'))
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Blank()
              // Swift `cell.accessoryType = shown ? .checkmark : .none`.
              if (entry.version.commitId === this.shownCommitId) {
                // UITableViewCell's checkmark accessory takes the default tint (systemBlue).
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(PANEL_CHECK_SIZE)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(['#007AFF'])
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .constraintSize({ minHeight: PANEL_ROW_HEIGHT })
            .padding({
              start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
              end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
              top: LengthMetrics.resource($r('sys.float.padding_level4')),
              bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
            })
          }
          .id('collab_history_itemroot')
          .onClick(() => {
            this.select(entry);
          })
        }, (entry: CollabVersionEntry) => entry.version.commitId)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({
        strokeWidth: 0.5,
        color: $r('sys.color.comp_divider'),
        startMargin: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    // Swift `self.backgroundColor = .jamiFormBackground` (the table is .clear).
    .backgroundColor($r('app.color.jami_form_background'))
  }
}
