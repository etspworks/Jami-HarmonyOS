/*
 * comp_document_row — ported from
 *   Ring/Ring/Features/Collab/CollabDocumentsView.swift `private struct DocumentRow` (line 100)
 *   Ring/Ring/Features/Collab/CollabDocumentRemoval.swift `enum CollabDocumentRemoval`
 *   Ring/Ring/Features/Collab/CollabDocumentsVM.swift (title/detail/isWaitingToBeRead)
 *
 *   HStack(spacing: 0) {
 *       Button(action: open) { label }               "collab_documents_itemroot"
 *       actionsMenu                                  "collab_documents_options_menu"
 *   }
 *   .swipeActions(edge: .trailing) {
 *       ForEach(viewModel.removals(for: document)) { removal in
 *           Button { requestRemoval(removal, document) } …  "collab_documents_swipe_remove" } }
 *
 * ArkUI attaches a swipe to the LIST ITEM, not to the row's own subtree, so the swipe half of
 * the pair lives on the page's `ListItem(...).swipeAction(...)` over the SAME `removals` set
 * this row is handed. Both routes still end at one `onRequestRemoval`.
 *
 *   label = HStack { Image(symbol) | VStack { title ; if let detail { detail } }
 *                    | Spacer | if waiting { CollabUnreadIndicator() } }
 *   actionsMenu = Menu { Button(open) { openTitle }           "collab_documents_menu_open"
 *                        ForEach(removals) { Button … }       "collab_documents_menu_remove" }
 *                 label: Image("ellipsis.circle")
 *
 * BOTH removal routes exist and BOTH are gated on the same `removals(for:)` being non-empty
 * (conditionalVariants[has_removals]) — the source deliberately keeps the swipe for the reader
 * who knows it is there and the menu for the one who does not, and one route alone would be a
 * different screen.
 *
 * `CollabDocumentRemoval` is the SOURCE's own enum and its `available(for:localJamiId:)` rule,
 * ported verbatim: anyone may stop holding a document, but only its author may retire it for
 * everyone — the daemon refuses anyone else, so offering it would promise what cannot happen.
 *
 * Glyphs: `ellipsis.circle` and `minus.circle` are exact matches; `doc.richtext` and
 * `arrow.down.doc` resolve to CLOSED candidate shortlists, and the two picked below come from
 * inside those lists (results/plan/icon-map.json). No name is invented.
 */
import { CollaborativeDocument } from '../model/CollaborativeDocument';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';

/** Swift `DocumentsLayout.margin` / `.textSpacing` / `.rowHeight`. */
const ROW_MARGIN: number = 16;
const ROW_TEXT_GAP: number = 2;
const ROW_HEIGHT: number = 44;
/** Swift `@ScaledMetric private var menuSize: CGFloat = 44`. */
const MENU_SIZE: number = 44;
/** SwiftUI List's default vertical row inset around the label (iPhone 4.20: 11 pt). */
const LIST_ROW_VERTICAL_INSET: number = 11;
/** The grouped List's row content inset on the reference iPhone, as MemberList's. */
export const DOCUMENT_ROW_INSET: number = 20;

/* ── S5 (NO CAPTURE — the source's own, CollabDocumentsView.swift:100-200) ──────────── */
/** `Image(systemName:)` with no explicit font — SwiftUI's body size for the leading glyph. */
const ROW_GLYPH_SIZE: number = 20;
/** Where the title starts: the row inset, the glyph, the HStack spacing. */
export const DOCUMENT_ROW_TEXT_INSET: number = DOCUMENT_ROW_INSET + ROW_GLYPH_SIZE + ROW_MARGIN;
/** `Image(systemName: "ellipsis.circle")` in the trailing menu label. */
const MENU_GLYPH_SIZE: number = 20;
/**
 * Swift `CollabUnreadIndicator` (CollabDocMessageView.swift:95) — a `Color.unreadMessageText`
 * circle, `@ScaledMetric(relativeTo: .callout) size = 8`. `unreadMessageText` is
 * `UIColor(hexString: "CC0022")` (UIColor+Ring.swift:123), hard-coded in the source.
 */
const UNREAD_DOT_SIZE: number = 8;
const UNREAD_DOT_COLOR: string = '#CC0022';
/** Swift `ButtonRole.destructive` in a `Menu` — UIKit's system red, as ContextMenu.ets draws it. */
export const DESTRUCTIVE_RED: string = '#FF3B30';

/** Swift `enum CollabDocumentRemoval` — the two ways of letting a document go. */
export enum CollabDocumentRemoval {
  FROM_THIS_DEVICE = 'FROM_THIS_DEVICE',
  FOR_EVERYONE = 'FOR_EVERYONE'
}

/**
 * Swift `CollabDocumentRemoval.available(for:localJamiId:)`, verbatim: `fromThisDevice` only
 * while this device holds the document, `forEveryone` only for its own author. An unknown
 * identity matches nobody.
 */
export function availableRemovals(document: CollaborativeDocument,
  localJamiId: string): CollabDocumentRemoval[] {
  const removals: CollabDocumentRemoval[] = [];
  if (document.storedLocally) {
    removals.push(CollabDocumentRemoval.FROM_THIS_DEVICE);
  }
  const author: string | null = document.author;
  if (author !== null && author.length > 0 && localJamiId.length > 0 && author === localJamiId) {
    removals.push(CollabDocumentRemoval.FOR_EVERYONE);
  }
  return removals;
}

/** Swift `var menuTitle` — the row menu has the width to say which removal this is. */
export function removalMenuTitle(removal: CollabDocumentRemoval): Resource {
  return removal === CollabDocumentRemoval.FROM_THIS_DEVICE
    ? $r('app.string.collab_remove_locally_menu')
    : $r('app.string.collab_remove_everywhere_menu');
}

/** Swift `var symbol` — the glyph beside each removal in the row menu. */
export function removalSymbol(removal: CollabDocumentRemoval): Resource {
  return removal === CollabDocumentRemoval.FROM_THIS_DEVICE
    ? $r('sys.symbol.minus_circle')
    : $r('sys.symbol.trash');
}

/** Swift `Button(role: removal == .forEveryone ? .destructive : nil)` — red for everyone. */
function removalColor(removal: CollabDocumentRemoval): ResourceColor {
  return removal === CollabDocumentRemoval.FOR_EVERYONE
    ? DESTRUCTIVE_RED
    : $r('app.color.label');
}

@Component
export struct DocumentRowView {
  /** Swift `let document: CollaborativeDocument`. */
  document: CollaborativeDocument =
    new CollaborativeDocument('', '', CollaborativeDocument.MIME_RICH_TEXT, null, 0, false);
  /** bindingContract[row title]: `viewModel.title(of: document)`. */
  title: string = '';
  /** Swift `viewModel.detail(of: document)` — the author line; empty when there is none. */
  detail: string = '';
  /** Swift `viewModel.isWaitingToBeRead(document)` — the unread indicator and the bold title. */
  waiting: boolean = false;
  /** Swift `viewModel.removals(for: document)` — conditionalVariants[has_removals]. */
  removals: CollabDocumentRemoval[] = [];

  /** Swift `let open: () -> Void` — `stateEmitter.openDocument(...)`. */
  onOpen?: () => void;
  /** Swift `let requestRemoval: (CollabDocumentRemoval, CollaborativeDocument) -> Void`. */
  onRequestRemoval?: (removal: CollabDocumentRemoval) => void;

  private open(): void {
    const handler: (() => void) | undefined = this.onOpen;
    if (handler !== undefined) {
      handler();
    }
  }

  private requestRemoval(removal: CollabDocumentRemoval): void {
    const handler: ((removal: CollabDocumentRemoval) => void) | undefined = this.onRequestRemoval;
    if (handler !== undefined) {
      handler(removal);
    }
  }

  /** Swift `.accessibilityValue(waiting ? L10n.Accessibility.messageBubbleUnread : "")`. */
  private unreadValue(): string {
    return this.waiting ? getContext(this).resourceManager
      .getStringByNameSync('accessibility_message_bubble_unread') : '';
  }

  /** Swift `private var openTitle` — a document this device is not holding is fetched first. */
  private openTitle(): Resource {
    return this.document.storedLocally
      ? $r('app.string.collab_open')
      : $r('app.string.collab_download_and_open');
  }

  /** Swift `private var symbol` — `doc.richtext` while held here, `arrow.down.doc` while not. */
  private symbol(): Resource {
    return this.document.storedLocally
      ? $r('sys.symbol.doc_text')
      : $r('sys.symbol.arrow_down_circle');
  }

  /** Swift `actionsMenu`'s `Menu { … }` content. */
  @Builder
  private actionsMenuContent() {
    Menu() {
      // Swift the menu's first item — Label(openTitle, systemImage: symbol).
      MenuItem({
        content: this.openTitle(),
        symbolStartIcon: new SymbolGlyphModifier(this.symbol())
      })
        .id('collab_documents_menu_open')
        .onClick(() => {
          this.open();
        })

      // Swift `ForEach(viewModel.removals(for: document)) { … }` — gated on the same set as
      // the swipe, so a row with no removals offers neither route.
      if (this.removals.length > 0) {
        ForEach(this.removals, (removal: CollabDocumentRemoval) => {
          MenuItem({
            content: removalMenuTitle(removal),
            symbolStartIcon: new SymbolGlyphModifier(removalSymbol(removal))
              .fontColor([removalColor(removal)])
          })
            // One id per item (T-1604): Remove is for everyone, Offload this device only.
            .id(removal === CollabDocumentRemoval.FOR_EVERYONE
              ? 'collab_documents_menu_remove' : 'collab_documents_menu_offload')
            .contentFontColor(removalColor(removal))
            .onClick(() => {
              this.requestRemoval(removal);
            })
        }, (removal: CollabDocumentRemoval) => removal)
      }
    }
  }

  build() {
    // Swift `HStack(spacing: 0) { Button(open) { label } ; actionsMenu }`.
    Row() {
      // The WHOLE label is the open control (Swift's `Button(action: open) { label }`), so the
      // slug and the handler sit on the row itself, never on an inner Text.
      Row({ space: ROW_MARGIN }) {
        /*
         * Swift `private var symbol` — `doc.richtext` while this device holds the document,
         * `arrow.down.doc` while it has to be fetched first. bindingContract[row icon] is the
         * document's own kind: both names resolve to a CLOSED candidate shortlist, and these
         * two are picked from inside it (`sys.symbol.doc_text`, `sys.symbol.arrow_down_circle`).
         */
        SymbolGlyph(this.symbol())
          // Swift `.foregroundColor(Color.jami)`.
          .fontSize(ROW_GLYPH_SIZE)
          .fontColor([$r('app.color.jami')])

        Column({ space: ROW_TEXT_GAP }) {
          // bindingContract[row title]: CollaborativeDocument.name, through the VM's title().
          // Swift sets no lineLimit on either line: a long name or author wraps (T-1297).
          Text(this.title)
            .fontWeight(this.waiting ? FontWeight.Bold : FontWeight.Regular)
            // Swift `.foregroundColor(Color(UIColor.label))` at the default body size.
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))

          // Swift `if let detail = viewModel.detail(of: document) { Text(detail) }`.
          if (this.detail.length > 0) {
            Text(this.detail)
              // Swift `.font(.caption).foregroundColor(.secondary)`.
              .fontSize($r('sys.float.Caption_M'))
              .fontColor($r('app.color.secondary_label'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // Swift `if waiting { CollabUnreadIndicator() }`.
        if (this.waiting) {
          // Swift `CollabUnreadIndicator()` — a filled 8 pt circle, nothing readable in it.
          Text('')
            .id('collabDocumentUnread')
            .width(UNREAD_DOT_SIZE)
            .height(UNREAD_DOT_SIZE)
            .borderRadius(UNREAD_DOT_SIZE / 2)
            .backgroundColor(UNREAD_DOT_COLOR)
            .accessibilityLevel('no')
        }
      }
      .id('collab_documents_itemroot')
      .accessibilityDescription(this.unreadValue())
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)
      // The 44 pt label inside SwiftUI's grouped-List row insets: rows 66 pt apart on the
      // iPhone 4.20 (Documents tab, iOS 18.7).
      .constraintSize({ minHeight: ROW_HEIGHT + 2 * LIST_ROW_VERTICAL_INSET })
      // `List` row insets — the grouped row's own content inset.
      .padding({
        start: LengthMetrics.vp(DOCUMENT_ROW_INSET),
        top: LengthMetrics.vp(LIST_ROW_VERTICAL_INSET),
        bottom: LengthMetrics.vp(LIST_ROW_VERTICAL_INSET)
      })
      .onClick(() => {
        this.open();
      })

      // Swift `actionsMenu` — the per-document overflow menu, on every row.
      Row() {
        // Swift `.foregroundColor(.secondary)`.
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.secondary_label')])
      }
      .id('collab_documents_options_menu')
      // Swift `.accessibilityLabel(L10n.Collab.menu)` — the glyph has no readable name of its
      // own, so the source's own label carries it.
      .accessibilityText($r('app.string.collab_menu'))
      .width(MENU_SIZE)
      .height(MENU_SIZE)
      .justifyContent(FlexAlign.Center)
      .bindMenu(this.actionsMenuContent)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ end: LengthMetrics.vp(DOCUMENT_ROW_INSET) })
  }
}
