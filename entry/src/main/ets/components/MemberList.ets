/*
 * comp_member_list — ported from Ring/Ring/SwarmInfo/View/MembersList.swift
 * `struct MemberList` (line 18) and `struct MemberItem` (line 53):
 *
 *   MemberList: Section(header: L10n.Swarm.members) {
 *                 ForEach(viewModel.swarmInfo.participants.value) { participant in
 *                   MemberItem(participant:isInvited:isLocalParticipant:)
 *                     .deleteDisabled(participant.role == .admin) }
 *                 .onDelete(perform: viewModel.isAdmin ? delete : nil) }
 *   MemberItem: HStack(spacing: 12) { AvatarSwiftUIView ; nameLabel ; Spacer ; roleLabel }
 *                 .opacity(isInvited ? 0.5 : 1)
 *
 * The rows come from `ConversationModel.participants` (bindingContract `member rows`) through
 * LazyForEach + ArrayDataSource — never a literal array. With no daemon the swarm has no
 * members, so the list is legitimately EMPTY on this build; nothing fakes a row.
 *
 * `onDelete` is a UIKit table swipe, so it is `ListItem.swipeAction` here, and it carries the
 * source's TWO guards: the whole action only exists when `viewModel.isAdmin`, and an admin
 * row is `deleteDisabled`.
 *
 * MemberItem is one row instantiated N times, so its slug is a SHARED id ending in
 * `itemroot` (Rule 12's list-row exception) derived from the symbol the source gives it —
 * the source itself sets no accessibilityIdentifier on it.
 *
 * S5 — STYLE. Swift declares the row's own metrics (`HStack(spacing: 12)`, the 40 pt avatar,
 * `.opacity(isInvited ? 0.5 : 1)`); the rest is the same GROUPED table SettingsViewSection
 * renders, mapped by role — a white `comp_background_list_card` row inset 20 on the grey
 * `background_secondary` page, a `Body_S` up-cased `secondary_label` section header, and a
 * hairline between rows that starts at the inset (List's own `.divider`, which draws one
 * between rows and none after the last — exactly what UIKit does).
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { LookupNameResponse } from '../common/NameService';
import { BehaviorRelay, DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import {
  ConversationParticipant,
  ParticipantRole,
  participantRoleLabelResource
} from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** Swift `HStack(alignment: .center, spacing: 12)`. */
const ROW_GAP: number = 12;
/** Swift `.opacity(isInvited ? 0.5 : 1)`. */
const INVITED_OPACITY: number = 0.5;
/** The grouped row's content inset, as in SettingsViewSection and the capture. */
const ROW_INSET: number = 20;
/** The grouped table's hairline. */
const SEPARATOR_WIDTH: number = 0.5;
/** UIKit's swipe button pads its title 15 pt on each side. */
const SWIPE_BUTTON_PADDING: number = 15;
/** The capture's header band above the first row. */
const SECTION_HEADER_TOP: number = 18;
const SECTION_HEADER_BOTTOM: number = 6;
/** Swift ParticipantInfo.provider is AvatarSize.default55; the grouped cell adds 11 pt above
 * and below (77 pt rows on the simulator). */
const AVATAR_ROW_HEIGHT: number = 77;

/** Swift `struct MemberItem`. */
@Component
export struct MemberItem {
  /**
   * Swift `let participant: ParticipantInfo`. A plain member, not @Prop: LazyForEach rebuilds
   * the row when its key changes, and @Prop's deep copy of a class with methods is the one
   * shape ArkUI V1 does not round-trip.
   */
  participant: ConversationParticipant = new ConversationParticipant();
  /** Swift `let isInvited: Bool` — `participant.role == .invited`. */
  @Prop isInvited: boolean = false;
  /** Swift `let isLocalParticipant: Bool`. */
  @Prop isLocalParticipant: boolean = false;
  /** The conversation's account, for the member's profile and name lookup. */
  @Prop accountId: string = '';
  /** Swift `ParticipantInfo.profileName` <- the member's vCard alias. */
  @State private profileName: string = '';
  /** Swift `ParticipantInfo.registeredName` <- the name lookup. */
  @State private registeredName: string = '';
  /** Swift `ParticipantInfo.avatarData` — the member's picture, from svc_profiles. */
  @State private avatarData: string = '';
  private bag: DisposeBag = new DisposeBag();

  /**
   * Swift `SwarmInfo.createParticipant`: follow the member's profile (the account's own for
   * the local member) and look its registered name up. The row used to read both once while
   * it was built, before either had resolved, so it showed the bare jamiId (T-1132).
   */
  aboutToAppear(): void {
    if (this.accountId.length === 0) {
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const jamiId: string = this.participant.jamiId;
    const profile: BehaviorRelay<Profile> = this.isLocalParticipant
      ? registry.profileService.getAccountProfile(this.accountId)
      : registry.profileService.getProfile(jamiId, this.accountId);
    this.bag.add(profile.subscribe((value: Profile): void => {
      this.profileName = value.alias === null ? '' : value.alias;
      this.avatarData = value.photo === null ? '' : value.photo;
    }));
    this.registeredName = this.knownRegisteredName();
    // Swift `ParticipantInfo.lookupName(nameService:accountId:)`.
    this.bag.add(registry.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (response.name.length > 0 &&
          (response.requestedName === jamiId || response.address === jamiId)) {
          this.registeredName = response.name;
        }
      }));
    registry.nameService.lookupAddress(this.accountId, '', jamiId);
  }

  aboutToDisappear(): void {
    this.bag.dispose();
  }

  /** The registered name the services already hold, so a known member is named at once. */
  private knownRegisteredName(): string {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    if (this.isLocalParticipant) {
      const account: AccountModel | null = registry.accountService.getAccount(this.accountId);
      return account === null ? '' : account.registeredName;
    }
    const contact: ContactModel | null = registry.contactsService.contact(this.participant.jamiId);
    if (contact !== null && contact.userName !== null && contact.userName.length > 0) {
      return contact.userName;
    }
    return registry.nameService.cachedName(this.participant.jamiId) ?? '';
  }

  /** Swift `ContactsUtils.getFinalNameFrom(registeredName:profileName:hash:)`. */
  private finalName(): string {
    const profileName: string = this.profileName.trim();
    const registeredName: string = this.registeredName.trim();
    return profileName.length > 0 ? profileName
      : (registeredName.length > 0 ? registeredName : this.participant.jamiId);
  }

  /** Swift `displayName`: the final name with the "(You)" suffix for the local participant. */
  private displayName(): string {
    const name: string = this.finalName();
    return this.isLocalParticipant ? `${name} (${this.youSuffix()})` : name;
  }

  /** Swift `String.withYourselfSuffix()` — L10n.Conversation.yourself. */
  private youSuffix(): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync('conversation_yourself');
  }

  /** Swift `roleText`: blank for a plain member, the role's own name otherwise. */
  private hasRole(): boolean {
    return this.participant.role !== ParticipantRole.MEMBER;
  }

  /**
   * Swift `participant.role.stringValue`. The model hands back the RESOURCE NAME (`$r()`
   * takes a literal and cannot be built from a variable), so it is resolved here.
   */
  private roleLabel(): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager
      .getStringByNameSync(participantRoleLabelResource(this.participant.role));
  }

  build() {
    Row({ space: ROW_GAP }) {
      // Swift `profileImage` — AvatarSwiftUIView(source: participant.provider).
      AvatarSwiftUIView({
        avatarData: this.avatarData,
        // The bare name: with the "(You)" suffix a hash no longer reads as a jamiId, so the
        // local row drew a monogram in the wrong colour instead of the person glyph.
        displayText: this.finalName(),
        isGroup: false,
        avatarSize: AvatarSize.DEFAULT_55
      })
        // Swift dims the HStack only; the cell background stays white (the Row's opacity used
        // to grey the whole invited row).
        .opacity(this.isInvited ? INVITED_OPACITY : 1)
      // Swift `nameLabel`.
      Text(this.displayName())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Swift `.truncationMode(.middle)`.
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .opacity(this.isInvited ? INVITED_OPACITY : 1)
      Blank()
      // Swift `roleLabel` — blank for a plain member, and a read-only value, so it takes the
      // same secondary grey the swarm type's value takes one section over.
      if (this.hasRole()) {
        Text(this.roleLabel())
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .opacity(this.isInvited ? INVITED_OPACITY : 1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: AVATAR_ROW_HEIGHT })
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .padding({
      start: LengthMetrics.vp(ROW_INSET),
      end: LengthMetrics.vp(ROW_INSET)
    })
    // Rule 12's list-row exception: one shared id, resolved by index at replay.
    .id('member_item_itemroot')
  }
}

/** Swift `struct MemberList`. */
@Component
export struct MemberList {
  /**
   * bindingContract `member rows` <- ConversationModel.participants, published by the page.
   * A plain member, not @State: ArrayDataSource notifies its own listeners on reload().
   */
  members: ArrayDataSource<ConversationParticipant> =
    new ArrayDataSource<ConversationParticipant>([]);
  /** The conversation's account, for each member's profile lookup. */
  @Prop accountId: string = '';
  /** Swift `localJamiId` — `accountService.currentAccount?.jamiId`. */
  @Prop localJamiId: string = '';
  /** conditionalVariants[is_admin]: Swift `viewModel.isAdmin` gates `onDelete` entirely. */
  @Prop isAdmin: boolean = false;
  /** Swift `viewModel.removeMember(indexOffset:)`. */
  onDeleteMember?: (jamiId: string) => void;

  private deleteMember(participant: ConversationParticipant): void {
    const handler: ((jamiId: string) => void) | undefined = this.onDeleteMember;
    if (handler !== undefined) {
      handler(participant.jamiId);
    }
  }

  /**
   * Swift `.onDelete(perform: viewModel.isAdmin ? delete : nil)` plus the row's own
   * `.deleteDisabled(participant.role == .admin)`: a row the source gives no delete must not
   * swipe at all, so the swipe itself is attached only when both guards pass (T-1134: a
   * non-admin row slid open onto an empty slot).
   */
  private canDelete(participant: ConversationParticipant): boolean {
    return this.isAdmin && participant.role !== ParticipantRole.ADMIN;
  }

  /**
   * SwiftUI's onDelete button: UIKit's red "Delete", full row height, white title. The Row
   * gives the button the row's height, as ConversationsView's swipe actions do.
   */
  @Builder
  private removeAction(participant: ConversationParticipant) {
    Row() {
      Button($r('app.string.actions_delete_action'))
        .id('swarm_member_remove')
        .type(ButtonType.Normal)
        .height('100%')
        .borderRadius(0)
        .padding({
          start: LengthMetrics.vp(SWIPE_BUTTON_PADDING),
          end: LengthMetrics.vp(SWIPE_BUTTON_PADDING)
        })
        .backgroundColor($r('sys.color.warning'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor(Color.White)
        .onClick(() => {
          this.deleteMember(participant);
        })
    }
    .height('100%')
  }

  build() {
    List() {
      // Swift `Section(header: Text(L10n.Swarm.members))`.
      ListItem() {
        Text($r('app.string.swarm_members'))
          .width('100%')
          .textCase(TextCase.UpperCase)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .padding({
            start: LengthMetrics.vp(ROW_INSET),
            end: LengthMetrics.vp(ROW_INSET),
            top: LengthMetrics.vp(SECTION_HEADER_TOP),
            bottom: LengthMetrics.vp(SECTION_HEADER_BOTTOM)
          })
      }

      LazyForEach(this.members, (participant: ConversationParticipant) => {
        ListItem() {
          // Swift `ParticipantInfo.finalName` / `avatarData`, resolved as the group avatar does.
          MemberItem({
            participant: participant,
            isInvited: participant.role === ParticipantRole.INVITED,
            isLocalParticipant: participant.jamiId === this.localJamiId,
            accountId: this.accountId
          })
        }
        // conditionalVariants[is_admin]: no swipe at all unless the row can be deleted.
        .swipeAction(this.canDelete(participant)
          ? {
            end: {
              builder: (): void => {
                this.removeAction(participant);
              }
            }
          }
          : {})
      }, (participant: ConversationParticipant) => participant.jamiId)
    }
    .width('100%')
    // The grouped table's hairline: between rows only, starting at the content inset.
    .divider({
      strokeWidth: SEPARATOR_WIDTH,
      color: $r('sys.color.comp_divider'),
      // UIKit insets a cell's separator to its text: past the 55 pt avatar and the 12 pt gap.
      startMargin: ROW_INSET + AvatarSize.DEFAULT_55 + ROW_GAP
    })
    .scrollBar(BarState.Off)
    // The page behind an empty or short list is the grouped grey, not white.
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
