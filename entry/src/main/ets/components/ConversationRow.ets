/*
 * comp_conversation_row — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/ConversationsView.swift
 * `struct ConversationRowView` (line 161).
 *
 * Every value here is bound to svc_conversation_source's ConversationViewModel
 * (bindingContract: title -> ConversationModel.title, subtitle -> MessageModel.content,
 * avatar -> svc_profiles, unread badge -> the conversation's unread count). Nothing is a
 * literal transcribed from a capture.
 *
 * The source's three-way subtitle branch is reproduced exactly:
 *   isBlocked      -> "Blocked"
 *   lastMessage    -> "<date> - <message>"
 *   isSyncing      -> "Syncing…"
 *
 * S5 style, read off the source's own declarations:
 *   HStack .padding(.vertical, 8)                    -> padding_level4 (8 vp)
 *   listRowInsets leading/trailing 15                -> ROW_INSET (the app hardcodes 15)
 *   Spacer().frame(width: 12) avatar -> text         -> ohos_id_card_margin_start (12 vp)
 *   Text(nameWithSuffix) .foregroundColor(.primary)  -> Body_L + label,
 *       .fontWeight(unread > 0 ? .bold : .regular)
 *   Spacer().frame(height: 5) title -> subtitle
 *   date  .font(.footnote) .foregroundColor(.primary)   -> Body_S + label
 *   message .font(.footnote) .foregroundColor(.secondary) -> Body_S + secondary_label
 *   blocked / syncing .italic() .font(.footnote) .secondary
 *   badge .font(.footnote).fontWeight(.semibold), v4/h8, cornerRadius 5,
 *       Color.unreadMessageText #CC0022 on Color.unreadMessageBackground #EED4D8
 *   presence dot 14 pt, 2 pt systemBackground ring, .offset(x: -1, y: -1)
 *   Divider().padding(.leading, Constants.defaultAvatarSize)
 */
import { ConversationViewModel } from '../common/ConversationDataSource';
import { ConversationModel } from '../model/ConversationModel';
import { MessageModel, MessageType } from '../model/MessageModel';
import { ConversationParticipant, ParticipantRole } from '../model/ConversationParticipant';
import { AccountCallTracker } from '../model/ActiveCall';
import { PresenceStatus } from '../common/PresenceService';
import { Profile } from '../model/Profile';
import { BehaviorRelay } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
import { LookupNameResponse, LookupNameState } from '../common/NameService';
import { ContactModel } from '../model/ContactModel';
import { AvatarSize } from '../common/JamiConstants';
import { AccountModel } from '../model/AccountModel';
import {
  AvatarSwiftUIView, GroupAvatarCandidate, GroupAvatarMember, GroupAvatarSelection, selectGroupAvatar
} from './AvatarSwiftui';
import { ActiveCallIndicator } from './ActiveCallIndicator';
import { groupTitleFor } from './ExpandableAvatar';

/** Swift `listRowInsets(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))`. */
export const ROW_INSET: number = 15;
/** Swift `alignmentGuide(.listRowSeparatorLeading) { Constants.defaultAvatarSize }`. */
export const ROW_SEPARATOR_INSET: number = ROW_INSET + AvatarSize.DEFAULT_55;

/** Swift `Color.onlinePresence` / `Color.availablePresence` — hard-coded hexes in the source. */
const ONLINE_PRESENCE: string = '#0B8271';
const AVAILABLE_PRESENCE: string = '#E59028';
/** Swift `Color.unreadMessageText` / `Color.unreadMessageBackground`. */
const UNREAD_TEXT: string = '#CC0022';
const UNREAD_BACKGROUND: string = '#EED4D8';

const PRESENCE_DOT_SIZE: number = 14;
const PRESENCE_RING_WIDTH: number = 2;
/** Swift `badgeCornerRadius` on the unread counter. */
const BADGE_CORNER_RADIUS: number = 5;
/** Swift `Spacer().frame(height: 5)` between the title and the subtitle. */
const TITLE_SUBTITLE_GAP: number = 5;

/** The action contract calls this control the **Conversation row**. */
@Component
export struct ConversationRowView {
  /** Swift `@ObservedObject var model: ConversationViewModel`. */
  model: ConversationViewModel = new ConversationViewModel();
  /** Swift `var withSeparator: Bool = true`. */
  withSeparator: boolean = true;
  /**
   * bindingContract[row title/subtitle/avatar] for a TEMPORARY row: the value comes from the
   * directory / name-lookup result the host resolved, not from the (still empty) conversation
   * model. Empty means "read it off the model", which is what every persisted row does.
   */
  titleOverride: string = '';
  subtitleOverride: string = '';
  avatarOverride: string = '';
  /** Swift `ConversationRowVM.userName` — the peer's registered name, once known. */
  @State private registeredName: string = '';
  private stopLookup: (() => void) | null = null;
  /** Swift `ConversationRowVM.lastMessage` / `lastMessageDate` / `unreadMessages`. */
  @State private lastMessage: string = '';
  @State private lastMessageDate: string = '';
  @State private lastMessageDeleted: boolean = false;
  @State private unreadCount: number = 0;
  @State private syncing: boolean = false;
  /** Swift `model.isBlocked`, re-read whenever the contacts relay (block / unblock) emits. */
  @State private blocked: boolean = false;
  /** Swift `callBannerViewModel.isVisible`, followed live through callService.activeCalls. */
  @State private activeCall: boolean = false;
  /** Swift `ConversationRowVM.presence`, followed live through the peer's presence relay. */
  @State private presenceStatus: PresenceStatus = PresenceStatus.OFFLINE;
  /**
   * Bumped when the conversation's members or profile change after the row first draws (a
   * joined swarm's members, a just-created swarm's title and invitees).
   */
  @State private refreshTick: number = 0;
  private stopUpdates: Array<() => void> = [];
  /** Member Jami IDs whose profile this group row already follows. */
  private followedMembers: Set<string> = new Set<string>();

  /** Re-reads the row's message-derived values off the model. */
  private refreshMessages(): void {
    this.lastMessage = this.model.lastMessage;
    this.lastMessageDate = this.model.lastMessageDate;
    this.lastMessageDeleted = this.model.lastMessageDeleted;
    this.unreadCount = this.model.unreadCount;
    const conversation: ConversationModel | null = this.model.conversation;
    this.syncing = conversation !== null && conversation.synchronizing.value;
  }

  /**
   * Swift `ConversationRowVM` for a dialog: the contact's known user name, else an
   * address lookup on the name server.
   */
  aboutToAppear(): void {
    const conversation: ConversationModel | null = this.model.conversation;
    this.refreshMessages();
    // Swift's row observes `isBlocked`. Its owner refreshes the flag on the contacts relay and
    // subscribed before this row existed, so the row reads the refreshed value (T-1603). The
    // flag itself is not recomputed here: a group keeps the one it was created with.
    // A member event's preview names its member, so it is re-read when a name lands too.
    this.stopUpdates.push(ServiceRegistry.shared().contactsService.contacts.subscribe(
      (): void => {
        this.blocked = this.model.isBlocked;
        this.refreshMessages();
      }));
    if (conversation !== null) {
      // Swift `ConversationRowVM` follows the conversation's messages and unread count.
      this.stopUpdates.push(conversation.newMessages.subscribe((): void => {
        this.refreshMessages();
        this.followMemberProfiles(conversation);
      }));
      this.stopUpdates.push(conversation.numberOfUnreadMessages.subscribe((): void => this.refreshMessages()));
      this.stopUpdates.push(conversation.synchronizing.subscribe((): void => this.refreshMessages()));
      // Swift `CallBannerViewModel.setupCallSubscription()`: the phone glyph shows when a call
      // starts in this conversation and goes when it ends or is joined (T-1583).
      this.stopUpdates.push(ServiceRegistry.shared().callService.activeCalls.subscribe(
        (trackers: Map<string, AccountCallTracker>): void => {
          this.activeCall = this.hasActiveCall(trackers);
        }));
      this.stopUpdates.push(ServiceRegistry.shared().conversationsService.conversationReadyEvents.subscribe(
        (id: string): void => {
          if (id === conversation.id) {
            this.refreshTick++;
            this.followMemberProfiles(conversation);
          }
        }));
      this.stopUpdates.push(ServiceRegistry.shared().conversationsService.sharedResponseStream.subscribe(
        (event: ServiceEvent): void => {
          if (event.getEventInput(ServiceEventInput.CONVERSATION_ID) === conversation.id &&
            (event.eventType === ServiceEventType.CONVERSATION_PROFILE_UPDATED ||
              event.eventType === ServiceEventType.CONVERSATION_MEMBER_EVENT)) {
            this.refreshTick++;
            this.followMemberProfiles(conversation);
          }
        }));
      this.followMemberProfiles(conversation);
    }
    const jamiId: string = this.peerJamiId();
    if (conversation === null || !conversation.isCoredialog() || jamiId.length === 0) {
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // Swift `ConversationRowVM.subscribePresence(contactId:)`: the dot follows the peer (T-1635).
    this.stopUpdates.push(registry.presenceService.presenceFor(jamiId)
      .subscribe((status: PresenceStatus): void => {
        this.presenceStatus = status;
      }));
    // Swift `ConversationRowVM` follows the peer's profile (displayName -> bestName). getProfile
    // starts empty and resolves 100 ms later, so a row read once kept the hash/registered name.
    this.stopUpdates.push(registry.profileService.getProfile(jamiId, conversation.accountId)
      .subscribe((): void => {
        this.refreshTick++;
        this.refreshMessages();
      }));
    const contact: ContactModel | null = registry.contactsService.contact(jamiId);
    if (contact !== null && contact.userName !== null && contact.userName.length > 0) {
      this.registeredName = contact.userName;
      return;
    }
    this.stopLookup = registry.nameService.usernameLookupStatus.subscribe(
      (response: LookupNameResponse): void => {
        if (response.address === jamiId && response.state === LookupNameState.FOUND) {
          this.registeredName = response.name;
        }
      });
    registry.nameService.lookupAddress(conversation.accountId, '', jamiId);
  }

  aboutToDisappear(): void {
    this.stopUpdates.forEach((stop: () => void) => stop());
    this.stopUpdates = [];
    this.followedMembers.clear();
    if (this.stopLookup !== null) {
      this.stopLookup();
      this.stopLookup = null;
    }
  }

  /**
   * Swift `SwarmInfo.createParticipant` follows every member's profile (the account's own for
   * the local member); the smart-list row's group avatar and member-event preview
   * (`ContactMessageVM.getName`) re-render on it. getProfile starts empty after a cold start,
   * so a group row read once kept the member's Jami ID and a grey disc (T-1648). Re-run when
   * the members or the last message change.
   */
  private followMemberProfiles(conversation: ConversationModel): void {
    if (conversation.isCoredialog()) {
      return;
    }
    const ids: string[] = conversation.getAllParticipants()
      .map((participant: ConversationParticipant): string => participant.jamiId);
    const messages: MessageModel[] = conversation.messages;
    const last: MessageModel | null = conversation.lastMessage !== null ? conversation.lastMessage
      : messages.length > 0 ? messages[messages.length - 1] : null;
    if (last !== null && last.type === MessageType.CONTACT && last.incoming) {
      ids.push(last.uri.length > 0 ? last.uri : last.authorId);
    }
    const local: ConversationParticipant | null = conversation.getLocalParticipants();
    const registry: ServiceRegistry = ServiceRegistry.shared();
    for (const id of ids) {
      if (id.length === 0 || this.followedMembers.has(id)) {
        continue;
      }
      this.followedMembers.add(id);
      const relay: BehaviorRelay<Profile> = local !== null && local.jamiId === id
        ? registry.profileService.getAccountProfile(conversation.accountId)
        : registry.profileService.getProfile(id, conversation.accountId);
      this.stopUpdates.push(relay.subscribe((): void => {
        this.refreshTick++;
        this.refreshMessages();
      }));
    }
  }

  /**
   * bindingContract[row title] <- ConversationModel.title, with Swift's `bestName` tail.
   *
   * S6 end-to-end completion. `ConversationViewModel.title` falls back to the peer's 40-char
   * jami id, because `ConversationModel.title` is only ever filled by `updateProfile()` —
   * the SWARM conversation profile. A one-to-one dialog carries no conversation profile at
   * all: Swift resolved its name from the PEER's vCard, which is `svc_profiles`, exactly as
   * `bindingContract[row avatar]` says. Without this hop every dialog row renders a raw hash
   * for the lifetime of the app, and nothing upstream can see it — the port populates every
   * field it declares, the id simply is not the name.
   */
  private displayTitle(): string {
    if (this.refreshTick < 0 || this.titleOverride.length > 0) {
      return this.titleOverride;
    }
    // Swift `SwarmInfo.buildTitleFrom(names:)`: an untitled swarm is named after its members,
    // "<peer>, <me> (You)", as the chat header already does.
    const conversation: ConversationModel | null = this.model.conversation;
    if (conversation !== null && !conversation.isCoredialog() && conversation.title.trim().length === 0) {
      const members: string = groupTitleFor(conversation, this.yourself());
      if (members.length > 0) {
        return members;
      }
    }
    const alias: string = this.peerProfileAlias();
    if (alias.length > 0) {
      return alias;
    }
    return this.registeredName.length > 0 ? this.registeredName : this.model.title;
  }

  /** Swift `nameWithSuffix`: a swarm with no one but the local member reads "<name> (You)". */
  private titleWithSuffix(): string {
    const name: string = this.displayTitle();
    const conversation: ConversationModel | null = this.model.conversation;
    if (name.length === 0 || this.titleOverride.length > 0 || conversation === null ||
      !conversation.isOnlyLocalParticipant()) {
      return name;
    }
    const suffix: string = ` (${this.yourself()})`;
    return name.endsWith(suffix) ? name : name + suffix;
  }

  /** Swift `L10n.Conversation.yourself`. */
  private yourself(): string {
    return getContext(this).resourceManager.getStringByNameSync('conversation_yourself');
  }

  /**
   * bindingContract[row avatar] <- svc_profiles. Same gap as the title: `model.avatar` is the
   * SWARM avatar (`ConversationModel.updateProfile`), so a dialog row would show a permanent
   * monogram even when the contact's vCard has a photo.
   */
  private displayAvatar(): string {
    if (this.refreshTick < 0 || this.avatarOverride.length > 0) {
      return this.avatarOverride;
    }
    if (this.model.avatar.length > 0) {
      return this.model.avatar;
    }
    const profile: Profile | null = this.peerProfile();
    if (profile === null || profile.photo === null) {
      return '';
    }
    return profile.photo;
  }

  /** Swift `ProfileService.getProfile(uri:accountId:)` for the dialog's single peer. */
  private peerProfile(): Profile | null {
    const conversation: ConversationModel | null = this.model.conversation;
    if (conversation === null || !conversation.isCoredialog()) {
      return null;
    }
    const jamiId: string = this.peerJamiId();
    if (jamiId.length === 0) {
      return null;
    }
    return ServiceRegistry.shared().profileService
      .getProfile(jamiId, conversation.accountId).value;
  }

  private peerProfileAlias(): string {
    const profile: Profile | null = this.peerProfile();
    if (profile === null || profile.alias === null) {
      return '';
    }
    return profile.alias;
  }

  /** Swift `model.presence` — PresenceService's relay for the row's peer. */
  private presence(): PresenceStatus | null {
    const jamiId: string = this.peerJamiId();
    // Swift shows presence for one-to-one rows only, never on a group's composite avatar.
    if (jamiId.length === 0 || this.isGroupConversation()) {
      return null;
    }
    return this.presenceStatus;
  }

  private peerJamiId(): string {
    const conversation: ConversationModel | null = this.model.conversation;
    if (conversation === null) {
      return '';
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    return participants.length > 0 ? participants[0].jamiId : '';
  }

  /**
   * Swift `model.swiftUIModel.callBannerViewModel.isVisible` — bindingContract itemField
   * `hasActiveCall`: `accountTrackers[accountId]?.incomingNotAcceptedCalls(for: id)` not empty.
   */
  private hasActiveCall(trackers: Map<string, AccountCallTracker>): boolean {
    const conversation: ConversationModel | null = this.model.conversation;
    if (conversation === null || conversation.id.length === 0) {
      return false;
    }
    const tracker: AccountCallTracker | undefined = trackers.get(conversation.accountId);
    if (tracker === undefined) {
      return false;
    }
    return tracker.incomingNotAcceptedCalls(conversation.id).length > 0;
  }

  /**
   * Swift `source.isGroup` — a swarm renders the group avatar, a dialog the peer's. Keyed on the
   * conversation mode, not the member count: a two-member group is still a group (iOS draws it
   * as the two-disc composite).
   */
  private isGroupConversation(): boolean {
    const conversation: ConversationModel | null = this.model.conversation;
    // Reading refreshTick makes the avatar re-evaluate once the members are known.
    return this.refreshTick >= 0 && conversation !== null && !conversation.isCoredialog();
  }

  /** Swift `SwarmInfo.insertAndSortParticipants` role order: admin, member, then the rest. */
  private static roleRank(role: ParticipantRole): number {
    if (role === ParticipantRole.ADMIN) {
      return 0;
    }
    return role === ParticipantRole.MEMBER ? 1 : 2;
  }

  /**
   * Swift `ParticipantInfo.finalName` / `avatarData`: the vCard (the account's own for the
   * local member), else the registered name, else the id.
   */
  private groupMember(participant: ConversationParticipant, accountId: string): GroupAvatarMember {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const profile: Profile = participant.isLocal
      ? registry.profileService.getAccountProfile(accountId).value
      : registry.profileService.getProfile(participant.jamiId, accountId).value;
    let registeredName: string = '';
    if (participant.isLocal) {
      const account: AccountModel | null = registry.accountService.getAccount(accountId);
      registeredName = account === null ? '' : account.registeredName;
    } else {
      const contact: ContactModel | null = registry.contactsService.contact(participant.jamiId);
      registeredName = contact === null || contact.userName === null ? '' : contact.userName;
    }
    const member: GroupAvatarMember = new GroupAvatarMember();
    member.photo = profile.photo === null ? '' : profile.photo;
    member.name = profile.alias !== null && profile.alias.length > 0 ? profile.alias
      : registeredName.length > 0 ? registeredName : participant.jamiId;
    return member;
  }

  /**
   * Swift `AvatarProvider.subscribeGroupParticipants` -> `updateDisplay`: every member,
   * local account included, sorted as SwarmInfo does, then `selectForDisplay`.
   */
  private groupSelection(): GroupAvatarSelection {
    const conversation: ConversationModel | null = this.model.conversation;
    if (conversation === null || !this.isGroupConversation() || this.displayAvatar().length > 0) {
      return new GroupAvatarSelection();
    }
    const kept: ParticipantRole[] = [ParticipantRole.INVITED, ParticipantRole.MEMBER,
    ParticipantRole.ADMIN, ParticipantRole.LEFT];
    const candidates: GroupAvatarCandidate[] = conversation.getAllParticipants()
      .filter((participant: ConversationParticipant) => kept.includes(participant.role))
      .map((participant: ConversationParticipant): GroupAvatarCandidate => {
        const candidate: GroupAvatarCandidate = new GroupAvatarCandidate();
        candidate.member = this.groupMember(participant, conversation.accountId);
        candidate.role = participant.role;
        return candidate;
      })
      .sort((a: GroupAvatarCandidate, b: GroupAvatarCandidate): number => {
        const rank: number = ConversationRowView.roleRank(a.role as ParticipantRole) -
          ConversationRowView.roleRank(b.role as ParticipantRole);
        // Same role: Swift sorts by finalName descending.
        return rank !== 0 ? rank : b.member.name.localeCompare(a.member.name);
      });
    return selectGroupAvatar(candidates);
  }

  /** Swift `model.swiftUIModel.isSyncing`, followed live through `synchronizing`. */
  private isSyncing(): boolean {
    return this.syncing;
  }

  private presenceColor(status: PresenceStatus): ResourceColor {
    return status === PresenceStatus.CONNECTED ? ONLINE_PRESENCE : AVAILABLE_PRESENCE;
  }

  private showPresence(): boolean {
    const status: PresenceStatus | null = this.presence();
    return status !== null &&
      (status === PresenceStatus.CONNECTED || status === PresenceStatus.AVAILABLE);
  }

  /** Swift `.fontWeight(model.unreadMessages > 0 ? .bold : .regular)`. */
  private titleWeight(): FontWeight {
    return this.unreadCount > 0 ? FontWeight.Bold : FontWeight.Regular;
  }

  @Builder
  subtitle() {
    if (this.subtitleOverride.length > 0) {
      Text(this.subtitleOverride)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
    } else if (this.blocked) {
      Text($r('app.string.swarm_blocked'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_S'))
        .fontStyle(FontStyle.Italic)
        .fontColor($r('app.color.secondary_label'))
    } else if (this.lastMessageDeleted) {
      Text($r('app.string.conversation_last_message_deleted'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_S'))
        .fontStyle(FontStyle.Italic)
        .fontColor($r('app.color.secondary_label'))
    } else if (this.lastMessage.length > 0) {
      Row({ space: 4 }) {
        Text(this.lastMessageDate + ' -')
          .maxLines(1)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.label'))
        Text(this.lastMessage)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Bottom)
      .width('100%')
    } else if (this.isSyncing()) {
      Text($r('app.string.smartlist_in_synchronization'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_S'))
        .fontStyle(FontStyle.Italic)
        .fontColor($r('app.color.secondary_label'))
    }
  }

  build() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          AvatarSwiftUIView({
            avatarData: this.displayAvatar(),
            displayText: this.displayTitle(),
            isGroup: this.isGroupConversation(),
            avatarSize: AvatarSize.DEFAULT_55,
            groupAvatar: this.groupSelection()
          })
          if (this.showPresence()) {
            Circle()
              .width(PRESENCE_DOT_SIZE)
              .height(PRESENCE_DOT_SIZE)
              .fill(this.presenceColor(this.presence() as PresenceStatus))
              .stroke($r('sys.color.background_primary'))
              .strokeWidth(PRESENCE_RING_WIDTH)
              .offset({ x: -1, y: -1 })
          }
        }

        Column({ space: TITLE_SUBTITLE_GAP }) {
          Text(this.titleWithSuffix())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(this.titleWeight())
            .fontColor($r('app.color.label'))
            .width('100%')
          this.subtitle()
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: $r('sys.float.ohos_id_card_margin_start') })

        if (this.activeCall) {
          ActiveCallIndicator()
        }
        if (this.unreadCount > 0) {
          Text(this.unreadCount.toString())
            .fontSize($r('sys.float.Body_S'))
            .fontWeight(FontWeight.Medium)
            .fontColor(UNREAD_TEXT)
            .backgroundColor(UNREAD_BACKGROUND)
            .borderRadius(BADGE_CORNER_RADIUS)
            .padding({
              top: $r('sys.float.ohos_id_elements_margin_horizontal_s'),
              bottom: $r('sys.float.ohos_id_elements_margin_horizontal_s'),
              left: $r('sys.float.ohos_id_elements_margin_horizontal_m'),
              right: $r('sys.float.ohos_id_elements_margin_horizontal_m')
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4')
      })

      if (this.withSeparator) {
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))
          .margin({ left: AvatarSize.DEFAULT_55 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: ROW_INSET, right: ROW_INSET })
  }
}
