/*
 * comp_expandable_avatar — ported from Ring/Ring/SwarmInfo/View/ExpandableAvatar.swift
 * `struct ExpandableAvatar` (line 27):
 *
 *   body        : GeometryReader { avatar(stretchedBy: overscroll, width:) }
 *                 .frame(size)                       // collapsed: provider.size.points square
 *                                                    // expanded : full width x min(width, h/2)
 *   avatar      : ZStack(alignment: .bottom) { avatarButton ; if isExpanded { bottomOverlay } }
 *                 .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 0 : side/2))
 *   avatarButton: Button(onToggle) { styledPicture.overlay { if isExpanded { blurredCopy } } }
 *                 .accessibilityIdentifier("swarm_info_avatar_toggle")
 *
 * The overscroll stretch is a GeometryReader read of the list's scroll offset; ArkUI has no
 * equivalent read inside a child, so it is dropped — it is a rubber-band flourish, not
 * structure. The blurred copy under the scrim is S5 polish (`.blur()`), also left to S5.
 *
 * The avatar itself is DATA (svc_profiles / ConversationModel.avatar), carried as the base64
 * the profile layer stores, exactly as comp_avatar_swiftui carries it — never a bundled
 * placeholder. With no picture the source still renders `provider.avatar ?? UIImage()`, i.e.
 * nothing; comp_avatar_swiftui's monogram/glyph fallback is used instead so the collapsed
 * header is not an empty square.
 *
 * S3: structure only.
 */
import { AvatarSize } from '../common/JamiConstants';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { ConversationModel } from '../model/ConversationModel';
import { ConversationParticipant, ParticipantRole, participantRoleIsActive } from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';
import {
  AvatarSwiftUIView, GroupAvatarCandidate, GroupAvatarMember, GroupAvatarSelection, selectGroupAvatar
} from './AvatarSwiftui';

/** Swift `ExpandableAvatarLayout.expandedHeightFraction`. */
const EXPANDED_HEIGHT_FRACTION: string = '50%';

/**
 * The photo as an Image source. The profile layer keeps the vCard's bare base64, which ArkUI's
 * Image reads only as a data URI (same conversion as AvatarSwiftUIView.photoSource). Shared
 * with the share extension's and the profile editor's avatars.
 */
export function photoImageSource(photo: string): string {
  // Base64 has no ':'; anything with one is already a URI.
  return photo.includes(':') ? photo
    : `data:image/${photo.startsWith('/9j/') ? 'jpeg' : 'png'};base64,${photo}`;
}

/** Swift `SwarmInfo.insertAndSortParticipants` role order: admin, member, then the rest. */
function roleRank(role: ParticipantRole | null): number {
  if (role === ParticipantRole.ADMIN) {
    return 0;
  }
  return role === ParticipantRole.MEMBER ? 1 : 2;
}

/**
 * Swift `ParticipantInfo.finalName` / `avatarData`: the vCard (the account's own for the local
 * member), else the registered name, else the id. Same resolution as ConversationRowView.
 */
export function groupMember(participant: ConversationParticipant, accountId: string): GroupAvatarMember {
  const registry: ServiceRegistry = ServiceRegistry.shared();
  const profile: Profile = participant.isLocal
    ? registry.profileService.getAccountProfile(accountId).value
    : registry.profileService.getProfile(participant.jamiId, accountId).value;
  let registeredName: string = '';
  if (participant.isLocal) {
    const account: AccountModel | null = registry.accountService.getAccount(accountId);
    registeredName = account === null ? '' : account.registeredName;
  } else {
    // Swift `ParticipantInfo.lookupName`: a member who is not a contact is named by the lookup.
    const contact: ContactModel | null = registry.contactsService.contact(participant.jamiId);
    registeredName = contact !== null && contact.userName !== null && contact.userName.length > 0
      ? contact.userName : registry.nameService.cachedName(participant.jamiId) ?? '';
  }
  const member: GroupAvatarMember = new GroupAvatarMember();
  member.photo = profile.photo === null ? '' : profile.photo;
  member.name = profile.alias !== null && profile.alias.length > 0 ? profile.alias
    : registeredName.length > 0 ? registeredName : participant.jamiId;
  return member;
}

/**
 * Swift `SwarmInfo.insertAndSortParticipants`: every member, local account included, kept when
 * invited, member, admin or left, admins first, then members; same role by finalName descending.
 * The Members tab lists exactly these, and the composite avatar is drawn from them.
 */
export function swarmMembers(conversation: ConversationModel): ConversationParticipant[] {
  const kept: ParticipantRole[] = [ParticipantRole.INVITED, ParticipantRole.MEMBER,
  ParticipantRole.ADMIN, ParticipantRole.LEFT];
  return conversation.getAllParticipants()
    .filter((participant: ConversationParticipant) => kept.includes(participant.role))
    .sort((a: ConversationParticipant, b: ConversationParticipant): number => {
      const rank: number = roleRank(a.role) - roleRank(b.role);
      return rank !== 0 ? rank : groupMember(b, conversation.accountId).name
        .localeCompare(groupMember(a, conversation.accountId).name);
    });
}

function groupCandidates(conversation: ConversationModel): GroupAvatarCandidate[] {
  return swarmMembers(conversation)
    .map((participant: ConversationParticipant): GroupAvatarCandidate => {
      const candidate: GroupAvatarCandidate = new GroupAvatarCandidate();
      candidate.member = groupMember(participant, conversation.accountId);
      candidate.role = participant.role;
      return candidate;
    });
}

/**
 * Swift `AvatarProvider.subscribeGroupParticipants` -> `selectForDisplay`: the composite group
 * avatar for the chat header and swarm info. Empty for a dialog (AvatarSwiftUIView then draws
 * its usual fallback); a custom group photo still wins because the view checks avatarData first.
 */
export function groupAvatarFor(conversation: ConversationModel | null): GroupAvatarSelection {
  if (conversation === null || conversation.isCoredialog()) {
    return new GroupAvatarSelection();
  }
  return selectGroupAvatar(groupCandidates(conversation));
}

/**
 * Swift `SwarmInfo.buildTitleFrom(names:)` + `buildGroupTitle`: an untitled swarm is named after
 * its members (the local one suffixed), unique, shortest first, three at most, then ", + N"
 * for the remaining active members.
 */
export function groupTitleFor(conversation: ConversationModel, yourselfSuffix: string): string {
  const candidates: GroupAvatarCandidate[] = groupCandidates(conversation);
  const local: ConversationParticipant | null = conversation.getLocalParticipants();
  const localName: string = local === null ? '' : groupMember(local, conversation.accountId).name;
  const names: string[] = [];
  for (const candidate of candidates) {
    const name: string = candidate.member.name === localName
      ? `${localName} (${yourselfSuffix})` : candidate.member.name;
    if (name.length > 0 && !names.includes(name)) {
      names.push(name);
    }
  }
  names.sort((a: string, b: string): number => a.length - b.length);
  const shown: string[] = names.slice(0, 3);
  const activeCount: number = conversation.getAllParticipants()
    .filter((participant: ConversationParticipant) => participantRoleIsActive(participant.role)).length;
  const others: number = Math.max(activeCount - shown.length, 0);
  return others > 0 ? `${shown.join(', ')}, + ${others}` : shown.join(', ');
}

@Component
export struct ExpandableAvatar {
  /** Swift `provider.avatar` — the encoded picture, empty when there is none. */
  @Prop avatarData: string = '';
  /** Swift `viewModel.title`, for comp_avatar_swiftui's monogram fallback. */
  @Prop displayText: string = '';
  /** Swift `let isExpanded: Bool`. */
  @Prop isExpanded: boolean = false;
  /** Swift `let isGroup: Bool`. */
  @Prop isGroup: boolean = false;
  /** Swift `provider.size.points` — `.conversationInfo120` on this screen. */
  @Prop collapsedSide: number = AvatarSize.CONVERSATION_INFO_120;
  /** The composite group avatar (`groupAvatarFor`), drawn when there is no picture. */
  @Prop groupAvatar: GroupAvatarSelection = new GroupAvatarSelection();
  /** Swift `let onToggle: () -> Void`. */
  onToggle?: () => void;
  /** Swift `@ViewBuilder let bottomOverlay: BottomOverlay` — the scrimmed title/description. */
  @BuilderParam bottomOverlay: () => void;
  /** A photo the decoder rejected: the header falls back to the monogram, as with no photo. */
  @State private undecodable: string = '';

  private fire(): void {
    const handler: (() => void) | undefined = this.onToggle;
    if (handler !== undefined) {
      handler();
    }
  }

  build() {
    // Swift `avatar(stretchedBy:width:)` — ZStack(alignment: .bottom).
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.avatarData.length > 0 && this.avatarData !== this.undecodable) {
        Image(photoImageSource(this.avatarData))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.undecodable = this.avatarData;
          })
      } else {
        AvatarSwiftUIView({
          avatarData: '',
          displayText: this.displayText,
          isGroup: this.isGroup,
          avatarSize: this.collapsedSide,
          groupAvatar: this.groupAvatar
        })
      }

      // Swift `if isExpanded { bottomOverlay }` — the scrimmed info stack.
      if (this.isExpanded) {
        this.bottomOverlay()
      }
    }
    .width(this.isExpanded ? '100%' : this.collapsedSide)
    .height(this.isExpanded ? EXPANDED_HEIGHT_FRACTION : this.collapsedSide)
    // Swift `.clipShape(RoundedRectangle(cornerRadius: isExpanded ? 0 : collapsedSide / 2))`.
    .borderRadius(this.isExpanded ? 0 : this.collapsedSide / 2)
    .clip(true)
    .id('swarm_info_avatar_toggle')
    // Swift `.accessibilityLabel(isGroup ? swarmPicturePicker : profilePicturePicker)`.
    .accessibilityText($r('app.string.accessibility_swarm_picture_picker'))
    .onClick(() => {
      this.fire();
    })
  }
}
