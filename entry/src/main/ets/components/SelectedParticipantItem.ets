/*
 * comp_selected_participant_item — ported from
 * Ring/Ring/SwarmCreation/SwarmCreationUI.swift `struct SelectedParticipantItem` (line 57):
 *
 *   Button(action: self.action) {
 *     VStack(alignment: .center) {
 *       ZStack(alignment: .topTrailing) {
 *         AvatarSwiftUIView(source: participant.avatarProvider)
 *         Image(systemName: "xmark").frame(6, 6).padding(4)
 *           .background(Color(UIColor.systemBackground)).clipShape(Circle())
 *       }
 *       Text(participant.name).font(.caption).lineLimit(1).truncationMode(.tail)
 *     }
 *     .frame(width: 50)
 *   }
 *   .accessibilityIdentifier("swarm_creation_selected_participant_itemroot")
 *
 * One chip per selected participant, so its slug is the source's own SHARED `..._itemroot`
 * id (Rule 12's list-row exception). The whole chip is Swift's Button — tapping it removes
 * the participant — so the handler is on the outer container, not on the xmark inside it.
 *
 * `xmark` is a system glyph with no asset file: the icon ladder's rung 2, resolved exactly
 * (`sys.symbol.xmark`) by results/plan/icon-map.json.
 *
 * S5 — STYLE. Swift declares every value here (the 50 pt chip, the 6 pt xmark padded 4 on a
 * `systemBackground` circle, `.font(.caption)` on the name in `Color(UIColor.label)`), so the
 * only mapping is iOS role to HarmonyOS token. Nothing is measured off the capture — the
 * chip strip is only drawn once something is selected, and the captured states show none.
 */
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** Swift `.frame(width: 50)` on the whole chip. */
const CHIP_WIDTH: number = 50;
/** Swift `Image(systemName: "xmark").frame(width: 6, height: 6).padding(4)`. */
const BADGE_GLYPH_SIZE: number = 6;
const BADGE_PADDING: number = 4;
/** A 6 pt glyph needs weight to stay readable; SwiftUI's default here renders solid. */
const BADGE_GLYPH_WEIGHT: number = 600;
/** The VStack's default spacing between the avatar and its caption. */
const CHIP_NAME_GAP: number = 4;

@Component
export struct SelectedParticipantItem {
  /** Swift `participant.name` <- ContactModel.userName, falling back to its hash. */
  @Prop participantName: string = '';
  /** Swift `participant.avatarProvider` <- svc_profiles. Empty means none. */
  @Prop avatarData: string = '';
  /** Swift `var action: () -> Void` — removes this participant from `list.selections`. */
  onTap?: () => void;

  private fire(): void {
    const handler: (() => void) | undefined = this.onTap;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        AvatarSwiftUIView({
          avatarData: this.avatarData,
          displayText: this.participantName,
          isGroup: false,
          avatarSize: AvatarSize.DEFAULT_55
        })
        Stack() {
          // Swift `.foregroundColor(Color(UIColor.label))` on the glyph, over a
          // `Color(UIColor.systemBackground)` circle — so it stays visible on any avatar.
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(BADGE_GLYPH_SIZE)
            .fontWeight(BADGE_GLYPH_WEIGHT)
            .fontColor([$r('app.color.label')])
        }
        .padding(BADGE_PADDING)
        .backgroundColor($r('sys.color.background_primary'))
        .borderRadius(BADGE_GLYPH_SIZE / 2 + BADGE_PADDING)
      }

      // Swift `.font(.caption).foregroundColor(Color(UIColor.label))`.
      Text(this.participantName)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: CHIP_NAME_GAP })
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.label'))
    }
    .width(CHIP_WIDTH)
    .alignItems(HorizontalAlign.Center)
    // Rule 12's list-row exception: the source's own shared chip id.
    .id('swarm_creation_selected_participant_itemroot')
    .onClick(() => {
      this.fire();
    })
  }
}
