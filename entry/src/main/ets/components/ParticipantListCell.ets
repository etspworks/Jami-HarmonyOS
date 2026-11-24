/*
 * comp_participant_list_cell — ported from Ring/Ring/SwarmCreation/SwarmCreationUI.swift
 * `struct ParticipantListCell` (line 28):
 *
 *   Button(action: self.action) {
 *     HStack(alignment: .center) {
 *       AvatarSwiftUIView(source: participant.avatarProvider)
 *       Text(participant.name).padding(.leading, 8).lineLimit(1).truncationMode(.tail)
 *       Spacer()
 *       if isSelected { Image("messageSentIndicator").frame(15, 15) }
 *       else          { Circle().strokeBorder(Color.gray, lineWidth: 1).frame(15, 15) }
 *     }
 *   }
 *   .accessibilityIdentifier("swarm_creation_participant_itemroot")
 *
 * One row instantiated once per contact, so its slug is the SHARED `..._itemroot` id the
 * source already gives it (Rule 12's list-row exception) — the replay resolves `tap-card-N`
 * by index. The WHOLE row is Swift's Button, so the tap target is the outer Row and not the
 * text inside it.
 *
 * `messageSentIndicator` is an ASSET, not a system glyph: the icon ladder's rung 1, carried
 * over by the assets pass as `app.media.message_sent_indicator`.
 *
 * S5 — STYLE. The metrics are Swift's own (the 8 pt gap after the avatar, the 15 pt
 * indicator, the 1 pt grey stroke); the row is a `PlainListStyle` cell, so it sits on
 * `systemBackground` with a 16 pt content inset and `.label` / `.secondaryLabel` text —
 * the roles mapped to their HarmonyOS tokens, not values sampled off a screenshot.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** Swift `.padding(.leading, 8.0)` between the avatar and the name. */
const NAME_LEADING: number = 8;
/** Swift `HStack(alignment: .center, spacing: nil)` — SwiftUI's default 8 pt spacing. */
const HSTACK_SPACING: number = 8;
/** Swift `.frame(width: 15, height: 15)` on both selection indicators. */
const INDICATOR_SIZE: number = 15;
/** Swift `Circle().strokeBorder(Color.gray, lineWidth: 1)`. */
const INDICATOR_STROKE: number = 1;
/**
 * The 55 pt avatar (Swift `Constants.AvatarSize.default55`) plus the plain cell's vertical
 * insets: the iOS reference rows are 77 pt apart. A plain list cell is inset 16.
 */
const AVATAR_ROW_HEIGHT: number = 77;
const ROW_INSET: number = 16;

@Component
export struct ParticipantListCell {
  /** Swift `participant.name` <- ContactModel.userName, falling back to its hash. */
  @Prop participantName: string = '';
  /** Swift `participant.avatarProvider` <- svc_profiles. Empty means none. */
  @Prop avatarData: string = '';
  /** Swift `var isSelected: Bool` — `list.selections.contains(contact.id)`. */
  @Prop isSelected: boolean = false;
  /** Swift `var action: () -> Void` — toggles this contact in `list.selections`. */
  onTap?: () => void;

  private fire(): void {
    const handler: (() => void) | undefined = this.onTap;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    Row({ space: HSTACK_SPACING }) {
      AvatarSwiftUIView({
        avatarData: this.avatarData,
        displayText: this.participantName,
        isGroup: false,
        avatarSize: AvatarSize.DEFAULT_55
      })
      Text(this.participantName)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ start: LengthMetrics.vp(NAME_LEADING) })
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
      Blank()
      if (this.isSelected) {
        // Swift `Image("messageSentIndicator")` — a bundled asset, carried over verbatim.
        Image($r('app.media.message_sent_indicator'))
          .width(INDICATOR_SIZE)
          .height(INDICATOR_SIZE)
          .objectFit(ImageFit.Contain)
      } else {
        // Swift `Circle().strokeBorder(Color.gray, lineWidth: 1)`.
        Column()
          .width(INDICATOR_SIZE)
          .height(INDICATOR_SIZE)
          .borderRadius(INDICATOR_SIZE / 2)
          .borderWidth(INDICATOR_STROKE)
          .borderColor(Color.Gray)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: AVATAR_ROW_HEIGHT })
    .padding({
      start: LengthMetrics.vp(ROW_INSET),
      end: LengthMetrics.vp(ROW_INSET)
    })
    .backgroundColor($r('sys.color.background_primary'))
    // Rule 12's list-row exception: the source's own shared row id.
    .id('swarm_creation_participant_itemroot')
    .onClick(() => {
      this.fire();
    })
  }
}
