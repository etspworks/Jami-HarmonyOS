/*
 * comp_avatar_swiftui — ported from Ring/Ring/Helpers/AvatarView.swift `struct AvatarSwiftUIView`
 * (line 310). Three branches, exactly as the source:
 *   1. a decoded avatar image  -> Image(...)
 *   2. a usable display name   -> the uppercased monogram
 *   3. neither (or a group)    -> person.fill / person.2.fill
 * The avatar itself is data (svc_profiles / ConversationModel.avatar), never a bundled
 * placeholder transcribed from the capture.
 *
 * S5 style, from the SOURCE's own declarations (AvatarHelpers.swift `AvatarMetrics` +
 * `avatarBackgroundColor(for:)`):
 *   - monogram / glyph background = avatarColors[md5(displayText)[0] % 16], carried into the
 *     migrated resources as app.color.avatar_color_00 .. _15 (assets pass);
 *   - monogram font = round(diameter * 0.44), semibold, white;
 *   - glyph        = round(diameter * 0.40), semibold, white;
 *   - the whole thing clipped to a circle (`.clipShape(Circle())`).
 * The 1 px `bgColor.darker(by: 1)` ring the source strokes is 1 % darker than its own fill and
 * is not reproduced — it is not distinguishable at any avatar size this app uses.
 *
 * A group without a custom avatar draws Swift's `groupAvatarSnapshot`
 * (Helpers/GroupAvatarRenderer.swift): up to three member discs, the admin's largest, and a
 * "+N" disc for the rest, laid out by `AvatarMetrics.twoCircle` / `threeCircle`. Swift paints
 * it into a UIImage; here the same geometry is laid out as a Stack.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { AvatarSize } from '../common/JamiConstants';
import { ParticipantRole, participantRoleIsActive } from '../model/ConversationParticipant';

/** Swift `AvatarMetrics.monogramFontRatio` / `iconSizeRatio` and their floors/ceilings. */
const MONOGRAM_FONT_RATIO: number = 0.44;
const ICON_SIZE_RATIO: number = 0.40;
const MIN_MONOGRAM_FONT_SIZE: number = 8;
const MAX_MONOGRAM_FONT_SIZE: number = 50;
const MIN_ICON_SIZE: number = 6;
/** Swift `.font(.system(size:, weight: .semibold))` on the monogram and the "+N" badge. */
const MONOGRAM_WEIGHT: number = 600;

/**
 * Swift `avatarColors` (Ring/Ring/Constants/AvatarsColors.swift), migrated verbatim into
 * resources by the assets pass. The ORDER is load-bearing: the index is a hash of the name,
 * so a reordering repaints every avatar in the app.
 */
const AVATAR_COLORS: Resource[] = [
  $r('app.color.avatar_color_00'), $r('app.color.avatar_color_01'),
  $r('app.color.avatar_color_02'), $r('app.color.avatar_color_03'),
  $r('app.color.avatar_color_04'), $r('app.color.avatar_color_05'),
  $r('app.color.avatar_color_06'), $r('app.color.avatar_color_07'),
  $r('app.color.avatar_color_08'), $r('app.color.avatar_color_09'),
  $r('app.color.avatar_color_10'), $r('app.color.avatar_color_11'),
  $r('app.color.avatar_color_12'), $r('app.color.avatar_color_13'),
  $r('app.color.avatar_color_14'), $r('app.color.avatar_color_15')
];

/** Swift `AvatarMetrics` group layout ratios (AvatarHelpers.swift). */
const EDGE_MARGIN_RATIO: number = 0.07;
const ADMIN_DIAMETER_RATIO: number = 0.46;
const SECONDARY_DIAMETER_RATIO: number = 0.34;
const SHADOW_OFFSET_Y_RATIO: number = 0.015;
const SHADOW_COLOR: string = 'rgba(0,0,0,0.18)';
/** Swift `AvatarMetrics.twoCircle` / `threeCircle` directions; index 0 is the admin disc. */
const TWO_CIRCLE: number[][] = [[-1, -1], [1, 1]];
const THREE_CIRCLE: number[][] = [[-7, -8], [1, 0], [-1, 6]];
/** Swift `selectForDisplay(from:maxVisible:)` default. */
const MAX_VISIBLE_MEMBERS: number = 3;

/** Swift `struct GroupAvatarMember` — base64 photo (empty = none) and resolved name. */
export class GroupAvatarMember {
  photo: string = '';
  name: string = '';
}

/** Swift `struct GroupAvatarCandidate`. */
export class GroupAvatarCandidate {
  member: GroupAvatarMember = new GroupAvatarMember();
  role: ParticipantRole | null = null;
}

/** Swift `GroupAvatarRenderer.Selection`, minus the indices only Swift's re-render diff needs. */
export class GroupAvatarSelection {
  members: GroupAvatarMember[] = [];
  overflowCount: number = 0;
}

/** Swift `isJamiHashId(_:)` — `(ring:)?([0-9a-f]{40})` anywhere in the string. */
function isJamiHashId(value: string): boolean {
  return new RegExp('[0-9a-f]{40}').test(value);
}

/** Swift `candidatePriority(_:)`: a photo beats a real name beats a bare id. */
function candidatePriority(candidate: GroupAvatarCandidate): number {
  if (candidate.member.photo.length > 0) {
    return 2;
  }
  const name: string = candidate.member.name;
  return name.length > 0 && !isJamiHashId(name) ? 1 : 0;
}

/**
 * Swift `GroupAvatarRenderer.selectForDisplay(from:maxVisible:)`: active members only, the
 * admin first, then the best-looking others; past `maxVisible` the last slot becomes "+N".
 */
export function selectGroupAvatar(candidates: GroupAvatarCandidate[]): GroupAvatarSelection {
  const selection: GroupAvatarSelection = new GroupAvatarSelection();
  const active: GroupAvatarCandidate[] = candidates.filter((candidate: GroupAvatarCandidate) =>
    candidate.role === null || participantRoleIsActive(candidate.role));
  if (active.length === 0) {
    return selection;
  }
  const maxSlots: number = active.length <= MAX_VISIBLE_MEMBERS ? active.length : MAX_VISIBLE_MEMBERS - 1;
  const admin: GroupAvatarCandidate | undefined =
    active.find((candidate: GroupAvatarCandidate) => candidate.role === ParticipantRole.ADMIN);
  const others: GroupAvatarCandidate[] = active
    .filter((candidate: GroupAvatarCandidate) => candidate !== admin)
    .sort((a: GroupAvatarCandidate, b: GroupAvatarCandidate) => candidatePriority(b) - candidatePriority(a));
  const selected: GroupAvatarCandidate[] = admin === undefined ? [] : [admin];
  selected.push(...others.slice(0, maxSlots - selected.length));
  selection.members = selected.map((candidate: GroupAvatarCandidate) => candidate.member);
  selection.overflowCount = Math.max(active.length - selected.length, 0);
  return selection;
}

/** One positioned disc of the group layout: top-left corner and diameter, in vp. */
class GroupSlot {
  x: number = 0;
  y: number = 0;
  size: number = 0;
}

/** md5(name) is stable for the lifetime of the process, so it is computed once per name. */
const COLOR_INDEX_CACHE: Map<string, number> = new Map<string, number>();

/**
 * Swift `avatarBackgroundColor(for:)` — the FIRST hex digit of md5(name), modulo the palette
 * size. Reproduced exactly (not approximated by a cheaper hash) because the same contact must
 * keep the same colour it had on iOS.
 */
function avatarColorIndex(name: string): number {
  const cached: number | undefined = COLOR_INDEX_CACHE.get(name);
  if (cached !== undefined) {
    return cached;
  }
  let index: number = 0;
  const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
  try {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(name);
    const input: cryptoFramework.DataBlob = { data: bytes };
    md.updateSync(input);
    const digest: cryptoFramework.DataBlob = md.digestSync();
    if (digest.data.length > 0) {
      // Swift took `prefix(1)` of the hex string — the HIGH nibble of the first byte.
      index = (digest.data[0] >> 4) % AVATAR_COLORS.length;
    }
  } catch (error) {
    index = 0;
  } finally {
    COLOR_INDEX_CACHE.set(name, index);
  }
  return index;
}

@Component
export struct AvatarSwiftUIView {
  /** Swift `source.avatar` — the encoded avatar the model/profile carries. Empty = none. */
  @Prop avatarData: string = '';
  /** Swift `resolvedDisplayText` — profileName ?? registeredName ?? jamiId. */
  @Prop displayText: string = '';
  /** Swift `source.isGroup`. */
  @Prop isGroup: boolean = false;
  /** Swift `effectiveSize` (`sizeOverride ?? source.size.points`). */
  @Prop avatarSize: number = AvatarSize.MEDIUM_40;
  /**
   * Swift `displayParticipants` / `overflowCount` (selectGroupAvatar's output). No members
   * keeps the person.2.fill glyph, as Swift does until the participants arrive.
   */
  @Prop groupAvatar: GroupAvatarSelection = new GroupAvatarSelection();
  /** Photos the decoder rejected: their disc falls back to the monogram, as with no photo. */
  @State private undecodable: string[] = [];

  /**
   * The photo as an Image source, '' for none. The profile layer keeps the vCard's bare base64,
   * which ArkUI's Image only reads as a data URI; a bare string was taken for a file path and
   * drew an empty disc (no photo, no monogram).
   */
  private photoSource(photo: string): string {
    if (photo.length === 0 || this.undecodable.includes(photo)) {
      return '';
    }
    // Base64 has no ':'; anything with one is already a URI.
    return photo.includes(':') ? photo
      : `data:image/${photo.startsWith('/9j/') ? 'jpeg' : 'png'};base64,${photo}`;
  }

  /** Swift `String.isSHA1()` — a 40-character hex hash is an id, not a name to monogram. */
  private isSha1(value: string): boolean {
    if (value.length !== 40) {
      return false;
    }
    return new RegExp('^[0-9a-fA-F]{40}$').test(value);
  }

  /** Swift: monogram only when the text is neither empty nor a SHA1, and this is not a group. */
  private hasMonogram(text: string, isGroup: boolean): boolean {
    return !isGroup && text.length > 0 && !this.isSha1(text);
  }

  /** Swift `AvatarMetrics.monogramFontSize(for:)`. */
  private monogramFontSize(size: number): number {
    const raw: number = Math.round(size * MONOGRAM_FONT_RATIO);
    return Math.min(Math.max(raw, MIN_MONOGRAM_FONT_SIZE), MAX_MONOGRAM_FONT_SIZE);
  }

  /** Swift `AvatarMetrics.iconSize(for:)`. */
  private iconFontSize(size: number): number {
    return Math.max(Math.round(size * ICON_SIZE_RATIO), MIN_ICON_SIZE);
  }

  /** Swift `avatarBackgroundColor(for: displayText)`; transparent behind a real avatar image. */
  private discBackground(photo: string, text: string): ResourceColor {
    return this.photoSource(photo).length > 0 ? Color.Transparent : AVATAR_COLORS[avatarColorIndex(text)];
  }

  /** Swift `source.isGroup && !source.hasCustomAvatar` with a snapshot to show. */
  private showsGroupLayout(): boolean {
    return this.isGroup && this.avatarData.length === 0 && this.groupAvatar.members.length > 0;
  }

  /** Swift `drawMultiMemberLayout`'s positions, from `LayoutPreset.offsets(margin:)`. */
  private groupSlots(): GroupSlot[] {
    const total: number = this.avatarSize;
    const hasThird: boolean = this.groupAvatar.members.length > 2 || this.groupAvatar.overflowCount > 0;
    const preset: number[][] = hasThird ? THREE_CIRCLE : TWO_CIRCLE;
    return preset.map((dir: number[], index: number): GroupSlot => {
      const ratio: number = index === 0 ? ADMIN_DIAMETER_RATIO : SECONDARY_DIAMETER_RATIO;
      const dist: number = 0.5 - ratio / 2 - EDGE_MARGIN_RATIO;
      const len: number = Math.sqrt(dir[0] * dir[0] + dir[1] * dir[1]);
      const slot: GroupSlot = new GroupSlot();
      slot.size = total * ratio;
      slot.x = total * (0.5 + dist * dir[0] / len) - slot.size / 2;
      slot.y = total * (0.5 + dist * dir[1] / len) - slot.size / 2;
      return slot;
    });
  }

  /** Swift `singleAvatarView` / `drawMemberCircle`: photo, else monogram, else glyph. */
  @Builder
  private disc(photo: string, text: string, isGroup: boolean, size: number) {
    Stack() {
      if (this.photoSource(photo).length > 0) {
        Image(this.photoSource(photo))
          .width(size)
          .height(size)
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.undecodable.push(photo);
          })
      } else if (this.hasMonogram(text, isGroup)) {
        Text(text.substring(0, 1).toUpperCase())
          .fontSize(this.monogramFontSize(size))
          .fontWeight(MONOGRAM_WEIGHT)
          .fontColor(Color.White)
      } else {
        SymbolGlyph(isGroup ? $r('sys.symbol.person_2_fill') : $r('sys.symbol.person_fill'))
          .fontSize(this.iconFontSize(size))
          .fontWeight(FontWeight.Medium)
          .fontColor([Color.White])
      }
    }
    .width(size)
    .height(size)
    .backgroundColor(this.discBackground(photo, text))
    .borderRadius(size / 2)
    .clip(true)
  }

  /** A secondary disc (member or "+N") with Swift's drop shadow. */
  @Builder
  private groupMemberDisc(member: GroupAvatarMember, slot: GroupSlot) {
    Stack() {
      this.disc(member.photo, member.name, false, slot.size)
    }
    .position({ x: slot.x, y: slot.y })
    // Round the wrapper too, or its square bounds cast a square shadow around the disc.
    .borderRadius(slot.size / 2)
    .shadow({
      radius: this.avatarSize * SHADOW_OFFSET_Y_RATIO * 2, color: SHADOW_COLOR,
      offsetX: 0, offsetY: this.avatarSize * SHADOW_OFFSET_Y_RATIO
    })
  }

  /**
   * Swift `GroupAvatarRenderer.render(members:overflowCount:totalSize:)`. Draw order is the
   * source's: third slot, second, then the admin on top.
   */
  @Builder
  private groupLayout() {
    if (this.groupAvatar.members.length === 1 && this.groupAvatar.overflowCount === 0) {
      this.disc(this.groupAvatar.members[0].photo, this.groupAvatar.members[0].name, false, this.avatarSize)
    } else {
      // @Builder params are by value and do not refresh: when the members change (a joined
      // group's list arrives after first draw) the old discs keep stale slots. Keying on the
      // selection rebuilds the composite instead.
      ForEach([this.groupLayoutKey()], (_key: string) => {
        Stack() {
          if (this.groupAvatar.overflowCount > 0) {
            // Swift `drawOverflowBadge`: systemGray3 disc, white semibold "+N".
            Text(`+${this.groupAvatar.overflowCount}`)
              .fontSize(this.monogramFontSize(this.groupSlots()[2].size))
              .fontWeight(MONOGRAM_WEIGHT)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .width(this.groupSlots()[2].size)
              .height(this.groupSlots()[2].size)
              .borderRadius(this.groupSlots()[2].size / 2)
              // systemGray3 equivalent: icon_fourth over an opaque background, so it adapts to
              // dark mode the way UIColor.systemGray3 does.
              .backgroundColor($r('sys.color.background_primary'))
              .linearGradient({ colors: [[$r('sys.color.icon_fourth'), 0], [$r('sys.color.icon_fourth'), 1]] })
              .position({ x: this.groupSlots()[2].x, y: this.groupSlots()[2].y })
              .shadow({
                radius: this.avatarSize * SHADOW_OFFSET_Y_RATIO * 2, color: SHADOW_COLOR,
                offsetX: 0, offsetY: this.avatarSize * SHADOW_OFFSET_Y_RATIO
              })
          } else if (this.groupAvatar.members.length > 2) {
            this.groupMemberDisc(this.groupAvatar.members[2], this.groupSlots()[2])
          }
          if (this.groupAvatar.members.length > 1) {
            this.groupMemberDisc(this.groupAvatar.members[1], this.groupSlots()[1])
          }
          this.groupMemberDisc(this.groupAvatar.members[0], this.groupSlots()[0])
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        // Swift `drawBackgroundGradient`: systemGray6 (2 % darker in light, lighter in dark),
        // lighter at the centre. The translucent fill tokens over an opaque background give the
        // same light/dark behaviour without a new colour resource.
        .backgroundColor($r('sys.color.background_primary'))
        .radialGradient({
          center: [this.avatarSize / 2, this.avatarSize / 2],
          radius: this.avatarSize / 2,
          colors: [[$r('sys.color.comp_background_tertiary'), 0], [$r('sys.color.comp_background_secondary'), 1]]
        })
        .borderRadius(this.avatarSize / 2)
        .clip(true)
      }, (key: string) => key)
    }
  }

  private groupLayoutKey(): string {
    return `${this.avatarSize}|${this.groupAvatar.overflowCount}|${this.undecodable.length}|` + this.groupAvatar.members
      .map((member: GroupAvatarMember) => `${member.name}:${member.photo.length}`).join(',');
  }

  build() {
    if (this.showsGroupLayout()) {
      this.groupLayout()
    } else {
      // By-value @Builder params do not refresh (see groupLayout): key the disc on its inputs
      // so a name or photo that arrives after first draw rebuilds it.
      ForEach([`${this.isGroup}|${this.avatarSize}|${this.displayText}|${this.avatarData}|${this.undecodable.length}`],
        (_key: string) => {
          this.disc(this.avatarData, this.displayText, this.isGroup, this.avatarSize)
        }, (key: string) => key)
    }
  }
}
