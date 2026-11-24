/*
 * screen_invite_participants — "Invite Participants", ported from
 *   Ring/Ring/SwarmInfo/View/AddMoreParticipantsInSwarm.swift (InviteParticipantsSheet)
 *   Ring/Ring/SwarmInfo/SwarmInfoVM.swift (participantsRows, selections, addMember,
 *     updateContactList)
 *
 * presentation: sheet, hostScreen: screen_swarm_info. SwarmInfoView raises it with
 * `isInvitingParticipants`, so it is the content of a .bindSheet() mounted by
 * SwarmConversationInfoPage (bound to that page's `Invite` control) — NOT a routed page and NOT
 * registered in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): every control and branch
 * below comes from the source only.
 *
 * S3 — the real tree of `InviteParticipantsSheet.body`:
 *   NavigationView { VStack {
 *       List { ForEach(viewModel.participantsRows) { contact in
 *                  ParticipantListCell(participant:isSelected:) { toggle the id in selections }
 *                      .accessibilityValue(selected ? inviteMembersSelected
 *                                                   : inviteMembersNotSelected) } }
 *           .listStyle(PlainListStyle())
 *       if !viewModel.selections.isEmpty { addMember().padding() }
 *   }
 *   .navigationTitle(L10n.Swarm.inviteMembers)
 *   .toolbar { ToolbarItem(.cancellationAction) { Button(L10n.Global.cancel) { dismiss() }
 *                  .accessibilityIdentifier("invite_participants_close") } } }
 *
 * bindingContract: [invitable contact list] / [rows] are svc_contacts —
 * `SwarmInfoVM.updateContactList()` maps the live `contactsService.contacts` relay to
 * `participantsRows`, minus whoever is already in the swarm. Rendered through LazyForEach over
 * an ArrayDataSource; the list starts EMPTY and is filled by the service, never seeded.
 *
 * conditionalVariants, each a real `if` on its own bound selector:
 *   has_selection — hasSelection, `!viewModel.selections.isEmpty` gates the Invite button into
 *                   existence (the source does not merely disable it)
 *   empty         — isEmpty, no invitable contacts
 *
 * The plan gives this screen NO components: the source's `ParticipantListCell` belongs to
 * screen_create_swarm_participants, whose component hardcodes that screen's own row slug, so
 * the row is built here with THIS screen's slug instead of carrying a foreign one.
 *
 * The participant row has no accessibility identifier in the source (the instrumenter pre-step
 * missed it), so per the plan its `.id()` is derived from its symbol — ParticipantListCell — as
 * the shared `…itemroot` slug a repeated row needs (Rule 12's list-row exception).
 *
 * Invite calls libjami's addConversationMember for every selected contact (no daemon gap).
 */
import { LengthMetrics, window } from '@kit.ArkUI';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { ContactsService } from '../common/ContactsService';
import { ConversationsService } from '../common/ConversationsService';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { Profile } from '../model/Profile';

/** Swift `.padding(.leading, 8.0)` between the avatar and the name. */
const NAME_LEADING: number = 8;
/** Swift `HStack(alignment: .center, spacing: nil)` — SwiftUI's default 8 pt spacing. */
const HSTACK_SPACING: number = 8;
/** Swift `.frame(width: 15, height: 15)` on both selection indicators. */
const INDICATOR_SIZE: number = 15;
/** Swift `Circle().strokeBorder(Color.gray, lineWidth: 1)`. */
const INDICATOR_STROKE: number = 1;
/**
 * Swift `ParticipantRow`'s avatar is `Constants.AvatarSize.default55`; with the plain cell's
 * vertical insets the rows are 77 pt apart (as comp_participant_list_cell). Inset by 16.
 */
const ROW_AVATAR: number = AvatarSize.DEFAULT_55;
const ROW_HEIGHT: number = 77;
const ROW_INSET: number = 16;

/* ── S5 (NO CAPTURE — the source's own, plus the iOS defaults it inherits) ────────────
 * `.navigationBarTitleDisplayMode(.inline)` + `.accentColor(.jami)` on the sheet, and
 * `swarmButtonStyle()` / `swarmButtonTextStyle()` (Button+Helpers.swift:24,
 * Text+Helpers.swift:24) for the Invite button:
 *   .background(Color.jamiButtonPrimary).clipShape(RoundedRectangle(cornerRadius: 10))
 *   .padding(.all, 15); the label .frame(maxWidth: .infinity).font(.system(size: 18))
 *   .padding().foregroundColor(.white)
 */
/** iOS inline navigation-bar height. */
const NAV_BAR_HEIGHT: number = 44;
/** The leading `Cancel` bar button's own width — what re-centres the inline title beside it. */
const NAV_ACTION_WIDTH: number = 60;
/** The iOS nav-bar hairline, and the plain list's row separator. */
const HAIRLINE: number = 0.5;
/** Swift `swarmButtonStyle()` — `cornerRadius: 10`, `.padding(.all, 15)`. */
const INVITE_RADIUS: number = 10;
const INVITE_OUTER_PADDING: number = 15;
/** Swift `addMember().padding()` — SwiftUI's default 16 around the styled button. */
const INVITE_SHEET_PADDING: number = 16;
/** Swift `swarmButtonTextStyle()` — `.font(.system(size: 18))` with SwiftUI's default padding. */
const INVITE_FONT_SIZE: number = 18;
const INVITE_INNER_PADDING: number = 16;

@Component
export struct InviteParticipantsSheet {
  /** Owned by screen_swarm_info; the host's @State drives the sheet. */
  @Link isPresented: boolean;
  /** Swift `viewModel.conversation` — the swarm the members are invited into. */
  @Prop accountId: string = '';
  @Prop conversationId: string = '';
  /** Swift `swarmInfo.contacts` already excludes the swarm's own members. */
  @Prop existingMembers: string[] = [];

  /** bindingContract[invitable contact list] / [rows]: svc_contacts <- `participantsRows`. */
  @State invitableContactList: ContactModel[] = [];
  /** Swift `@Published var selections: [String]`. */
  @State selections: string[] = [];
  /** conditionalVariants[has_selection]: Swift `!viewModel.selections.isEmpty`. */
  @State hasSelection: boolean = false;
  /** conditionalVariants[empty]: Swift `viewModel.participantsRows.isEmpty`. */
  @State isEmpty: boolean = true;
  /** True while svc_contacts / svc_conversations are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * The navigation indicator's height: the LARGE sheet runs to the screen bottom, and SwiftUI
   * pads the button inside the safe area, so the 31 inset is measured above the indicator.
   */
  @State private navigationInset: number = 0;

  /** bindingContract[rows]: LazyForEach's source (CLAUDE.md rule 7), reloaded from the
   * contacts relay — `SwarmInfoVM.updateContactList()`. */
  @State rows: ArrayDataSource<ContactModel> = new ArrayDataSource<ContactModel>([]);
  /** Swift `private var contactsSubscriptionsDisposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** Bumped when a listed contact's profile lands, so rows re-read name and picture. */
  @State private profileTick: number = 0;
  /** Contact URIs whose profile this page already follows. */
  private followedProfiles: Set<string> = new Set<string>();

  /** Swift `updateContactList()` — the live relay, applied now and on every change. */
  aboutToAppear(): void {
    const contacts: ContactsService = ServiceRegistry.shared().contactsService;
    this.isLoading = true;
    this.applyContacts(contacts.contacts.value);
    this.bag.add(contacts.contacts.subscribe((values: ContactModel[]): void => {
      this.applyContacts(values);
    }));
    this.isLoading = false;
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      this.navigationInset = px2vp(win.getWindowAvoidArea(
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
    }).catch((): void => {
      // No avoid area: the button keeps the plain 31 inset.
    });
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — Swift's `removeExistingSubscription()`.
    this.bag.dispose();
  }

  /** Swift `swarmInfo.contacts` — every contact that is not already in this swarm. */
  private applyContacts(values: ContactModel[]): void {
    const invitable: ContactModel[] = values.filter((contact: ContactModel) =>
      !contact.banned && !this.existingMembers.includes(contact.hash));
    this.invitableContactList = invitable;
    this.followProfiles(invitable);
    this.rows.reload(invitable);
    this.isEmpty = invitable.length === 0;
  }

  /**
   * Swift `SwarmInfo.createParticipant` follows each contact's profile. getProfile starts empty
   * and resolves 100 ms later, so rows read once kept the Jami ID (T-1741).
   */
  private followProfiles(contacts: ContactModel[]): void {
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (account === null) {
      return;
    }
    for (const contact of contacts) {
      const uri: string | null = contact.uriString;
      if (uri === null || uri.length === 0 || this.followedProfiles.has(uri)) {
        continue;
      }
      this.followedProfiles.add(uri);
      this.bag.add(ServiceRegistry.shared().profileService.getProfile(uri, account.id)
        .subscribe((): void => {
          this.profileTick++;
        }));
    }
  }

  /** The contact's svc_profiles entry; reading profileTick re-renders the rows when it lands. */
  private profileFor(contact: ContactModel): Profile | null {
    const uri: string | null = contact.uriString;
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (this.profileTick < 0 || uri === null || uri.length === 0 || account === null) {
      return null;
    }
    return ServiceRegistry.shared().profileService.getProfile(uri, account.id).value;
  }

  /**
   * Swift `participant.name` = `ParticipantInfo.finalName` (`ContactsUtils.getFinalNameFrom`):
   * the profile name, else the registered name, else the hash.
   */
  private contactName(contact: ContactModel): string {
    const profile: Profile | null = this.profileFor(contact);
    const alias: string = profile === null || profile.alias === null ? '' : profile.alias.trim();
    if (alias.length > 0) {
      return alias;
    }
    const userName: string | null = contact.userName;
    return userName === null || userName.length === 0 ? contact.hash : userName;
  }

  /** Swift `participant.avatarProvider` <- svc_profiles. */
  private avatarFor(contact: ContactModel): string {
    const profile: Profile | null = this.profileFor(contact);
    return profile === null || profile.photo === null ? '' : profile.photo;
  }

  private isSelected(contact: ContactModel): boolean {
    return this.selections.includes(contact.hash);
  }

  /**
   * Swift the cell's action — `if selections.contains(id) { removeAll } else { append }`.
   * A fresh array, so the @State really changes and the row repaints.
   */
  private toggleParticipant(contact: ContactModel): void {
    const next: string[] = this.selections.slice();
    const index: number = next.indexOf(contact.hash);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(contact.hash);
    }
    this.selections = next;
    this.hasSelection = next.length > 0;
  }

  /**
   * Swift `addMember()` — `dismiss()`, then one
   * `conversationService.addConversationMember(accountId:conversationId:memberId:)` per
   * selection, then `selections.removeAll()`. libjami sends the invitations; Swift shows
   * nothing on success, so neither does this (the old daemon-gap toast was false, T-1686).
   */
  private inviteMembers(): void {
    const service: ConversationsService = ServiceRegistry.shared().conversationsService;
    for (const memberId of this.selections) {
      service.addConversationMember(this.accountId, this.conversationId, memberId);
    }
    this.selections = [];
    this.hasSelection = false;
    this.isPresented = false;
  }

  /** Swift the cancellationAction toolbar item — `dismiss()`. */
  private close(): void {
    this.isPresented = false;
  }

  /** Swift `ParticipantListCell(participant:isSelected:action:)`, with THIS screen's slug. */
  @Builder
  private participantRow(contact: ContactModel) {
    Row({ space: HSTACK_SPACING }) {
      AvatarSwiftUIView({
        avatarData: this.avatarFor(contact),
        displayText: this.contactName(contact),
        isGroup: false,
        avatarSize: ROW_AVATAR
      })

      Text(this.contactName(contact))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ start: LengthMetrics.vp(NAME_LEADING) })
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))

      Blank()

      // Swift `if isSelected { Image("messageSentIndicator") } else { Circle().strokeBorder }`.
      if (this.isSelected(contact)) {
        Image($r('app.media.message_sent_indicator'))
          .width(INDICATOR_SIZE)
          .height(INDICATOR_SIZE)
          .objectFit(ImageFit.Contain)
      } else {
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
    .constraintSize({ minHeight: ROW_HEIGHT })
    .padding({ start: LengthMetrics.vp(ROW_INSET), end: LengthMetrics.vp(ROW_INSET) })
    // The WHOLE cell is Swift's Button, so the slug and the handler sit on the row itself.
    .id('participant_list_cell_itemroot')
    // Swift `.accessibilityLabel(Text(contact.name))` — the row reads as the CONTACT, …
    .accessibilityText(this.contactName(contact))
    // … and Swift `.accessibilityValue(selected ? inviteMembersSelected :
    // inviteMembersNotSelected)` is the state it reads after the name. Folding the two into
    // one label would have dropped whose row it is.
    .accessibilityDescription(this.isSelected(contact)
      ? $r('app.string.swarm_invite_members_selected')
      : $r('app.string.swarm_invite_members_not_selected'))
    .onClick(() => {
      this.toggleParticipant(contact);
    })
  }

  build() {
    Column() {
      // Swift `.navigationTitle(L10n.Swarm.inviteMembers)` + the cancellation toolbar item.
      Row() {
        // Swift `.accentColor(.jami)` on the sheet — its bar buttons take the Jami tint.
        Button($r('app.string.global_cancel'))
          .id('invite_participants_close')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .constraintSize({ minWidth: NAV_ACTION_WIDTH, minHeight: NAV_BAR_HEIGHT })
          .onClick(() => {
            this.close();
          })

        Blank()

        // `.inline` centres the title between the two Blanks that already flank it.
        Text($r('app.string.swarm_invite_members'))
          .maxLines(1)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.label'))

        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: NAV_BAR_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .backgroundColor($r('sys.color.background_primary'))
      .border({ width: { bottom: HAIRLINE }, color: { bottom: $r('sys.color.comp_divider') } })

      // Swift `List { ForEach(viewModel.participantsRows) { … } }` — the empty state and the
      // list are exclusive branches of the same bound row set.
      if (this.isEmpty) {
        Column()
          .id('inviteParticipantsEmpty')
          .width('100%')
          .layoutWeight(1)
      } else {
        List() {
          LazyForEach(this.rows, (contact: ContactModel) => {
            ListItem() {
              this.participantRow(contact)
            }
          }, (contact: ContactModel) => contact.hash)
        }
        .width('100%')
        .layoutWeight(1)
        // `.listStyle(PlainListStyle())` — edge-to-edge rows, a hairline inset to the name.
        .divider({
          strokeWidth: HAIRLINE,
          color: $r('sys.color.comp_divider'),
          startMargin: ROW_INSET + ROW_AVATAR + HSTACK_SPACING + NAME_LEADING
        })
      }

      // Swift `if !viewModel.selections.isEmpty { addMember().padding() }`.
      if (this.hasSelection) {
        // Swift `.padding(.all, 15)` (swarmButtonStyle) inside `.padding()`: the button is inset
        // 31 on every side. A percentage width plus a margin overflows the Column in ArkUI, so
        // the inset is this wrapper's padding and the button fills what is left of it.
        Column() {
          Button($r('app.string.swarm_invite_members'))
            .id('invite_participants_sheet_invite_members')
            .accessibilityText($r('app.string.swarm_invite_selected_members'))
            // Swift `swarmButtonStyle()` + `swarmButtonTextStyle()`; the label is
            // `.frame(maxWidth: .infinity)`.
            .type(ButtonType.Normal)
            .width('100%')
            .constraintSize({ minHeight: NAV_BAR_HEIGHT })
            .backgroundColor($r('app.color.jami_button_primary'))
            .borderRadius(INVITE_RADIUS)
            .fontSize(INVITE_FONT_SIZE)
            .fontColor($r('sys.color.font_on_primary'))
            .padding(INVITE_INNER_PADDING)
            .onClick(() => {
              this.inviteMembers();
            })
        }
        .width('100%')
        .padding({
          left: INVITE_OUTER_PADDING + INVITE_SHEET_PADDING,
          right: INVITE_OUTER_PADDING + INVITE_SHEET_PADDING,
          top: INVITE_OUTER_PADDING + INVITE_SHEET_PADDING,
          bottom: INVITE_OUTER_PADDING + INVITE_SHEET_PADDING + this.navigationInset
        })
      }
    }
    .width('100%')
    .height('100%')
    // `PlainListStyle` — a plain white page, not the grouped gray one (mapping-tables.md §7).
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_invite_participants')
  }
}
