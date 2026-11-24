/*
 * comp_collab_new_document_button — ported from
 *   Ring/Ring/Features/Collab/CollabDocumentsView.swift `struct CollabNewDocumentButton`
 *   (line 73):
 *
 *     Button(action: viewModel.startNaming) {
 *         Label(L10n.Collab.newDocument, systemImage: "square.and.pencil")
 *             .labelStyle(.iconOnly)
 *             .frame(width: 56, height: 56)
 *             .background(Color.jami).clipShape(Circle()).shadow(radius: 4)
 *     }
 *     .padding(16)
 *     .accessibilityLabel(L10n.Collab.newDocument)
 *     .accessibilityIdentifier("collab_documents_new_document")
 *
 * Icon-only, so the label it announces is carried by `.accessibilityText()` and the control is
 * addressed by its slug. `square.and.pencil` is an exact icon-map match.
 */

/** Swift `Layout.size` / `Layout.margin`. */
const BUTTON_SIZE: number = 56;
const BUTTON_MARGIN: number = 16;
/* ── S5 (NO CAPTURE — the source's own, CollabDocumentsView.swift:73-96) ──────────────── */
/** Swift `.font(.title2)` on the icon-only label. */
const GLYPH_SIZE: number = 22;
/** Swift `Layout.shadowRadius = 4`. */
const BUTTON_SHADOW_RADIUS: number = 4;
/** SwiftUI's default shadow colour at `.shadow(radius:)` — black at one third. */
const BUTTON_SHADOW_COLOR: string = '#55000000';

@Component
export struct CollabNewDocumentButton {
  /** Swift `viewModel.startNaming` — raises CollabNewDocumentPrompt. */
  onStartNaming?: () => void;

  build() {
    Button() {
      SymbolGlyph($r('sys.symbol.square_and_pencil'))
        // Swift `.font(.title2).foregroundColor(.white)`.
        .fontSize(GLYPH_SIZE)
        .fontColor([Color.White])
    }
    .id('collab_documents_new_document')
    .type(ButtonType.Circle)
    .width(BUTTON_SIZE)
    .height(BUTTON_SIZE)
    .margin(BUTTON_MARGIN)
    // Swift `.background(Color.jami).clipShape(Circle()).shadow(radius: 4)`.
    .backgroundColor($r('app.color.jami'))
    .shadow({ radius: BUTTON_SHADOW_RADIUS, color: BUTTON_SHADOW_COLOR })
    .accessibilityText($r('app.string.collab_new_document'))
    .onClick(() => {
      const handler: (() => void) | undefined = this.onStartNaming;
      if (handler !== undefined) {
        handler();
      }
    })
  }
}
