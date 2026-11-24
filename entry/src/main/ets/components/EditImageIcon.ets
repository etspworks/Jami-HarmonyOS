/*
 * comp_edit_image_icon — ported from Ring/Ring/SwarmCreation/SwarmProfile.swift
 * `struct EditImageIcon` (line 151):
 *
 *   ZStack(alignment: .topTrailing) {
 *     if let image = model.image { Image(uiImage:).resizable().scaledToFill()
 *                                   .frame(width,height).clipShape(Circle()) }
 *     else                       { Circle().fill(Color(UIColor.systemGray2))
 *                                   .frame(width,height) }
 *     Image(systemName: "pencil").frame(12,12).padding(6)
 *       .background(systemBackground).clipShape(Circle())
 *       .overlay(Circle().stroke(Color.jamiTertiaryControl, lineWidth: 3))
 *   }
 *   .frame(width: width, height: height)
 *
 * The picture is DATA (`SwarmCreationUIModel.image`, the swarm profile draft), carried as the
 * base64 the profile layer stores — never a bundled placeholder.
 *
 * The badge is a SYSTEM glyph with no asset file, so it goes through the icon ladder's rung 2:
 * `pencil` resolves to a candidate shortlist and `sys.symbol.pencil_line` is the plain pencil
 * this app already ships on its other edit affordances (comp_context_menu, comp_message_bubble).
 *
 * The component carries NO tap of its own — Swift wraps it in `imagePickerButton()`, which is
 * where the slug and the handler live — so it has no `.id()`.
 *
 * S5 — STYLE. Every value is Swift's own (100 square, the 12 pt pencil padded 6, the 3 pt
 * ring), and the ring's colour is the source's `Color.jamiTertiaryControl`, which the app
 * already carries as `app.color.jami_tertiary_control` (#D5E4EF) — the same resource the
 * customize row on this screen's page is filled with.
 */

/** Swift `EditImageIcon(model:width:height:)` is always called with 100 x 100. */
const DEFAULT_SIDE: number = 100;
/** Swift `.frame(width: 12, height: 12).padding(6)` on the pencil. */
const BADGE_GLYPH_SIZE: number = 12;
const BADGE_PADDING: number = 6;
/** Swift `.overlay(Circle().stroke(Color.jamiTertiaryControl, lineWidth: 3))`. */
const BADGE_RING_WIDTH: number = 3;
/**
 * S5 — Swift `Circle().fill(Color(UIColor.systemGray2))`. `systemGray2` has no HarmonyOS
 * `sys.color.*` counterpart (the grey ladder maps to component roles, not to a fixed step),
 * and every candidate is far lighter than the source's, so the iOS value is carried over
 * verbatim. Confirmed against the capture:
 * results/traversal-source/pages/SwarmCreationUI/swarm_creation_customize_profile.png samples
 * (174,174,178) inside the circle at [146,274][246,374].
 */
const PLACEHOLDER_GRAY: string = '#AEAEB2';

@Component
export struct EditImageIcon {
  /** Swift `model.image` — the swarm profile draft's picture. Empty means none. */
  @Prop imageData: string = '';
  /** Swift `@SwiftUI.State var width` / `height` — square at every call site. */
  @Prop side: number = DEFAULT_SIDE;

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.imageData.length > 0) {
        Image(this.imageData)
          .width(this.side)
          .height(this.side)
          .borderRadius(this.side / 2)
          .clip(true)
          .objectFit(ImageFit.Cover)
      } else {
        // Swift `Circle().fill(Color(UIColor.systemGray2))`.
        Column()
          .width(this.side)
          .height(this.side)
          .borderRadius(this.side / 2)
          .backgroundColor(PLACEHOLDER_GRAY)
      }

      // Swift's pencil badge.
      Stack() {
        SymbolGlyph($r('sys.symbol.pencil_line'))
          .fontSize(BADGE_GLYPH_SIZE)
          .fontColor([$r('app.color.jami')])
      }
      .padding(BADGE_PADDING)
      .backgroundColor($r('sys.color.background_primary'))
      .borderRadius(BADGE_GLYPH_SIZE / 2 + BADGE_PADDING)
      .borderWidth(BADGE_RING_WIDTH)
      // Swift `.overlay(Circle().stroke(Color.jamiTertiaryControl, lineWidth: 3))`.
      .borderColor($r('app.color.jami_tertiary_control'))
    }
    .width(this.side)
    .height(this.side)
  }
}
