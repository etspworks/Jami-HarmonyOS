/*
 * comp_requests_row — ported from
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Views/RequestsView.swift
 * `struct RequestsRowView` (the invitation row) together with the two view models
 * Ring/Ring/Features/Conversations/SmartList/SwiftUI/Models/RequestsViewModel.swift declares
 * for it (`RequestRowViewModel`, `RequestStatus`).
 *
 * Swift row body:
 *   VStack(spacing: 0) {
 *     Spacer().frame(height: markedToRemove ? 30 : 20)
 *     userInfoView                 // avatar | name + receivedDate | status
 *     Spacer().frame(height: 20)
 *     actionButtonsView            // slash.circle | xmark | checkmark
 *     Spacer().frame(height: markedToRemove ? 30 : 20)
 *     Divider()
 *   }
 *   .padding(.horizontal, 15)
 *
 * S3 = STRUCTURE. Every control the source declares is here with its source slug; the visual
 * finish (the jamiRequestsBackground card, the rounded action pills, the status colours, the
 * markedToRemove bounce) is S5/S6.
 *
 * S5 style, read off the source's own declarations (RequestsView.swift `RequestsRowView`):
 *   .background(Color.jamiRequestsBackground.clipShape(RoundedRectangle(cornerRadius: 15)))
 *       -> app.color.jami_requests_background + ROW_CORNER_RADIUS (the app hardcodes 15)
 *   foregroundColor = Color(UIColor.systemBackground) on the name, the date and the divider
 *       -> sys.color.background_primary (the SAME semantic role, so it inverts with the
 *          card in dark mode exactly as the source does)
 *   Text(bestName)            no .font()        -> Body_L   (iOS body, 17 pt)
 *   Text(receivedDate)        .font(.footnote)  -> Body_S
 *   Text(status.toString())   .padding(.horizontal, buttonPadding=10) + status.color()
 *       -> pending white / accepted systemGreen / declined orange / banned systemRed,
 *          resolved from results/traversal-source/palette.json (light)
 *   actionIcon: 20 pt glyph, requestsBadgeForeground on requestsBadgeBackground,
 *       .padding(10) both axes, .frame(maxWidth: .infinity), .cornerRadius(12)
 *   Divider().background(systemBackground.opacity(0.2))
 *
 * Icons, through results/plan/icon-map.json + the SDK symbol table:
 *   xmark        -> sys.symbol.xmark      (exact)
 *   checkmark    -> sys.symbol.checkmark  (exact)
 *   slash.circle -> sys.symbol.nosign     — the map has no row for `slash.circle` and the SDK
 *                   has no `slash_circle`; `nosign` is the circle-with-a-slash block glyph,
 *                   turned 90° because its slash runs the other way.
 */
import { RequestModel } from '../model/RequestModel';
import { conversationTimestamp } from '../model/MessageModel';
import { AvatarSize } from '../common/JamiConstants';
import { curves, LengthMetrics } from '@kit.ArkUI';
import { AvatarSwiftUIView, GroupAvatarMember, GroupAvatarSelection } from './AvatarSwiftui';
import { groupMember } from './ExpandableAvatar';
import { LookupNameResponse, LookupNameState, NameService } from '../common/NameService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ConversationParticipant } from '../model/ConversationParticipant';

/** Swift `enum RequestStatus`. */
export enum RequestStatus {
  PENDING = 'PENDING',
  ACCEPTED = 'ACCEPTED',
  DECLINED = 'DECLINED',
  BANNED = 'BANNED'
}

/** Swift `private let actionIconSize: CGFloat = 20`. */
const ACTION_ICON_SIZE: number = 20;
/**
 * Swift `.resizable().aspectRatio(contentMode: .fit).frame(20, 20)` stretches each SF symbol to
 * fill the 20 pt box. An HM symbol keeps its design-grid inset: at fontSize 20 the T-0224 device
 * capture drew nosign 18.9, xmark 13.8 and checkmark 17.0 vp wide, where the iPhone draws all
 * three 20 pt wide. Each glyph gets the font size that draws it 20 vp wide.
 */
const BLOCK_ICON_SIZE: number = 21;
const REJECT_ICON_SIZE: number = 28;
const ACCEPT_ICON_SIZE: number = 23.5;
/** `nosign` slashes top-left to bottom-right, SF `slash.circle` bottom-left to top-right. */
const BLOCK_ICON_ANGLE: number = 90;
/** Swift `private let spacerWidth / spacerHeight`. */
const ROW_H_PADDING: number = 15;
const ROW_V_SPACER: number = 20;
/** Swift `VStack(alignment: .leading, spacing: 5)` inside `userInfoView`. */
const NAME_DATE_GAP: number = 5;
/** Swift `private let buttonPadding: CGFloat = 10` — the action pill's inner padding. */
const BUTTON_PADDING: number = 10;
/** Swift `private let cornerRadius: CGFloat = 12` — the action pill. */
const ACTION_CORNER_RADIUS: number = 12;
/** Swift `backgroundView`: `RoundedRectangle(cornerRadius: 15)` on the row card. */
const ROW_CORNER_RADIUS: number = 15;
/** Swift `private let dividerOpacity: Double = 0.2`. */
const DIVIDER_OPACITY: number = 0.2;
/** Swift `Spacer().frame(height: markedToRemove ? 30 : spacerHeight)`. */
const ROW_V_SPACER_MARKED: number = 30;
/** Swift `scaleFactor` on a phone (an iPad uses 1.05; the app ships for phones only). */
const MARKED_SCALE: number = 1.1;
/** Swift `.padding(.horizontal, requestRow.markedToRemove ? 22 : 0)`, outside the scaled card. */
const MARKED_INSET: number = 22;
/** Swift `backgroundView` `.shadow(color: .black.opacity(0.9), radius: 2)` while marked. */
const MARKED_SHADOW_RADIUS: number = 2;
const MARKED_SHADOW_COLOR: string = 'rgba(0, 0, 0, 0.9)';
/** Swift `handleMarkedToRemoveChange`: the bounce starts 0.2 s after the row is marked. */
const BOUNCE_DELAY_MS: number = 200;
/** Swift `bounceAnimation()`: one rotation every 0.1 s on `interpolatingSpring(120, 35)`. */
const BOUNCE_STEP_MS: number = 100;
const BOUNCE_ROTATIONS: number[] = [5, -5, 5, -5, 0];
const BOUNCE_STIFFNESS: number = 120;
const BOUNCE_DAMPING: number = 35;

/**
 * Swift `RequestStatus.color()`. `.pending` is `UIColor.white` and `.declined` the fixed
 * `UIColor.orange` (RGB 1.0, 0.5, 0.0), not systemOrange. Accepted and banned are iOS system
 * colours, resolved from results/traversal-source/palette.json (light) because the source
 * names a platform default that exists in no line of Swift.
 */
const STATUS_PENDING_COLOR: string = '#FFFFFF';
const STATUS_ACCEPTED_COLOR: string = '#34C759';
const STATUS_DECLINED_COLOR: string = '#FF8000';
const STATUS_BANNED_COLOR: string = '#FF3B30';

/**
 * Swift `RequestNameResolver.lookupUserName(jamiId:)`: asks the name service for the registered
 * name of `jamiId` and reports it once, if one is found (`take(1)`). Returns the unsubscribe
 * closure. Shared by the requests row and the smart list's requests indicator.
 */
export function lookupRegisteredName(accountId: string, jamiId: string,
  onFound: (name: string) => void): () => void {
  const names: NameService = ServiceRegistry.shared().nameService;
  const stop: () => void = names.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
    if (response.address !== jamiId) {
      return;
    }
    stop();
    if (response.state === LookupNameState.FOUND && response.name.length > 0) {
      onFound(response.name);
    }
  });
  names.lookupAddress(accountId, '', jamiId);
  return stop;
}

/**
 * Swift `class RequestRowViewModel: ObservableObject` — one row of `RequestsViewModel.requestsRow`.
 *
 * The Swift row resolved its display name through `RequestNameResolver`: the request's own
 * `name`, else every participant's registered name from a NameService lookup, else its jami id
 * (`resolveName()`). The `rowName` / `rowAvatar` values are the bindingContract's
 * `RequestModel.name` / `RequestModel.avatar` — never a literal from the capture.
 */
@Observed
export class RequestRowViewModel {
  readonly request: RequestModel;
  /** Swift `let id: String` = `request.getIdentifier()`. */
  readonly id: string;
  /** bindingContract[row name] <- `RequestModel.name` (Swift `nameResolver.bestName`). */
  rowName: string = '';
  /** bindingContract[row avatar] <- `RequestModel.avatar` (Swift `Image(uiImage: avatar)`). */
  rowAvatar: string = '';
  /** Swift `@Published var receivedDate: String` = `request.receivedDate.conversationTimestamp()`. */
  receivedDate: string = '';
  /** Swift `@Published var status: RequestStatus = .pending`. */
  status: RequestStatus = RequestStatus.PENDING;
  /** Swift `@Published var markedToRemove: Bool`. */
  markedToRemove: boolean = false;
  /**
   * Swift `createAvatar()` for a group invitation with no picture of its own:
   * `GroupAvatarRenderer.render(members: [senderMember, selfMember])`, the composite the
   * iPhone draws (T-1582). Filled by `resolveName()`; empty for a 1:1 request.
   */
  groupAvatar: GroupAvatarSelection = new GroupAvatarSelection();
  /** Swift `RequestNameResolver.registeredNames` — jami id -> registered name ('' until found). */
  private registeredNames: Map<string, string> = new Map<string, string>();
  /** The open name lookups (Swift `take(1)` per participant); `dispose()` drops them. */
  private lookups: Array<() => void> = [];

  constructor(request: RequestModel) {
    this.request = request;
    this.id = request.getIdentifier();
    this.rowName = RequestRowViewModel.bestName(request);
    this.rowAvatar = request.avatar === null ? '' : request.avatar;
    this.receivedDate = conversationTimestamp(request.receivedDate);
  }

  /**
   * Swift `RequestNameResolver.setName()` / `constructNameFromRegisteredNames()`: the swarm
   * title when the invitation carries one, otherwise the participants, comma separated.
   */
  private static bestName(request: RequestModel): string {
    if (request.name.length > 0) {
      return request.name;
    }
    const names: string[] = [];
    // A 1:1 request can list the requester twice; a repeated id also breaks the SHA1 avatar test.
    for (const participant of request.participants) {
      if (names.indexOf(participant.jamiId) < 0) {
        names.push(participant.jamiId);
      }
    }
    return names.join(', ');
  }

  /**
   * Swift `RequestNameResolver.handleNoInvitationName()` -> `performLookup()`: with no title of
   * its own, the row shows each participant's registered name in place of its jami id once the
   * name service finds it (`constructNameFromRegisteredNames`). Called on the observed row,
   * never from the constructor: a callback that captured the constructor's `this` would update
   * the raw object and the UI would not see it. A group invitation's composite avatar is started
   * here for the same reason.
   */
  resolveName(): void {
    const titled: boolean = this.request.name.length > 0;
    const composite: boolean = !this.request.isCoredialog() && this.request.participants.length > 0 &&
      this.rowAvatar.length === 0;
    if (composite) {
      this.resolveGroupAvatar();
    }
    // Swift `subscribeSenderRegisteredName`: a titled group invitation still looks its sender up,
    // for the sender's disc; the row name stays the title.
    const lookedUp: ConversationParticipant[] = !titled ? this.request.participants
      : composite ? [this.request.participants[0]] : [];
    for (const participant of lookedUp) {
      const jamiId: string = participant.jamiId;
      if (this.registeredNames.has(jamiId)) {
        continue;
      }
      this.registeredNames.set(jamiId, '');
      this.lookups.push(lookupRegisteredName(this.request.accountId, jamiId, (found: string): void => {
        this.registeredNames.set(jamiId, found);
        if (!titled) {
          const shown: string[] = [];
          this.registeredNames.forEach((name: string, id: string) => {
            shown.push(name.length > 0 ? name : id);
          });
          this.rowName = shown.join(', ');
        }
        if (composite) {
          this.renderGroupAvatar();
        }
      }));
    }
  }

  /**
   * Swift `subscribeSenderProfile()` + `subscribeSharedSelfProfile()`: profiles resolve after
   * the row is built, so the composite is redrawn whenever either one changes.
   */
  private resolveGroupAvatar(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const accountId: string = this.request.accountId;
    this.lookups.push(registry.profileService.getProfile(this.request.participants[0].jamiId, accountId)
      .subscribe((): void => {
        this.renderGroupAvatar();
      }));
    this.lookups.push(registry.profileService.getAccountProfile(accountId)
      .subscribe((): void => {
        this.renderGroupAvatar();
      }));
  }

  /**
   * Swift `[senderMember, selfMember]`, each `GroupAvatarMember.resolve`d: profile photo and
   * alias, else the registered name, else the jami id.
   */
  private renderGroupAvatar(): void {
    const accountId: string = this.request.accountId;
    const sender: ConversationParticipant = this.request.participants[0];
    const senderMember: GroupAvatarMember = groupMember(sender, accountId);
    const registered: string = this.registeredNames.get(sender.jamiId) ?? '';
    if (senderMember.name === sender.jamiId && registered.length > 0) {
      senderMember.name = registered;
    }
    const selection: GroupAvatarSelection = new GroupAvatarSelection();
    selection.members = [senderMember];
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(accountId);
    if (account !== null) {
      selection.members.push(groupMember(new ConversationParticipant(account.jamiId, true), accountId));
    }
    this.groupAvatar = selection;
  }

  /** Drops the pending name lookups; the sheet calls it when the row leaves the list. */
  dispose(): void {
    this.lookups.forEach((stop: () => void) => stop());
    this.lookups = [];
  }

  /** Swift `func requestAccepted()`. */
  requestAccepted(): void {
    this.status = RequestStatus.ACCEPTED;
  }

  /** Swift `func requestDiscarded()`. */
  requestDiscarded(): void {
    this.status = RequestStatus.DECLINED;
  }

  /** Swift `func requestBlocked()`. */
  requestBlocked(): void {
    this.status = RequestStatus.BANNED;
  }

  /** Swift `RequestStatus.toString()` — `.pending` returns "", so nothing is rendered. */
  hasStatusText(): boolean {
    return this.status !== RequestStatus.PENDING;
  }

  /** Swift `RequestStatus.color()` — the status label's tint. */
  statusColor(): ResourceColor {
    if (this.status === RequestStatus.ACCEPTED) {
      return STATUS_ACCEPTED_COLOR;
    }
    if (this.status === RequestStatus.DECLINED) {
      return STATUS_DECLINED_COLOR;
    }
    if (this.status === RequestStatus.BANNED) {
      return STATUS_BANNED_COLOR;
    }
    return STATUS_PENDING_COLOR;
  }

  /** Swift `RequestStatus.toString()`. */
  statusText(): ResourceStr {
    if (this.status === RequestStatus.ACCEPTED) {
      return $r('app.string.invitations_accepted');
    }
    if (this.status === RequestStatus.DECLINED) {
      return $r('app.string.invitations_declined');
    }
    if (this.status === RequestStatus.BANNED) {
      return $r('app.string.invitations_blocked');
    }
    return '';
  }
}

/** Swift `struct RequestsRowView: View`. */
@Component
export struct RequestsRowView {
  /** Swift `@ObservedObject var requestRow: RequestRowViewModel`. */
  @ObjectLink @Watch('onRowChange') row: RequestRowViewModel;
  /** Swift `@SwiftUI.State private var rotationDegrees: Double = 0`. */
  @State rotationDegrees: number = 0;
  private bounceStarted: boolean = false;
  private timers: number[] = [];
  /** Swift `listModel.accept(requestRow:)`. */
  onAccept?: (row: RequestRowViewModel) => void;
  /** Swift `listModel.discard(requestRow:)`. */
  onReject?: (row: RequestRowViewModel) => void;
  /** Swift `listModel.block(requestRow:)`. */
  onBlock?: (row: RequestRowViewModel) => void;

  aboutToDisappear(): void {
    this.timers.forEach((timer: number) => clearTimeout(timer));
  }

  /** Swift `.onChange(of: requestRow.markedToRemove)` -> `handleMarkedToRemoveChange(true)`. */
  onRowChange(): void {
    if (!this.row.markedToRemove || this.bounceStarted) {
      return;
    }
    this.bounceStarted = true;
    this.timers.push(setTimeout(() => {
      this.bounceAnimation();
    }, BOUNCE_DELAY_MS));
  }

  /** Swift `bounceAnimation()`: rock 5, -5, 5, -5 degrees and settle at 0. */
  private bounceAnimation(): void {
    BOUNCE_ROTATIONS.forEach((angle: number, index: number) => {
      this.timers.push(setTimeout(() => {
        const spring: ICurve = curves.interpolatingSpring(0, 1, BOUNCE_STIFFNESS, BOUNCE_DAMPING);
        this.getUIContext().animateTo({ curve: spring }, () => {
          this.rotationDegrees = angle;
        });
      }, index * BOUNCE_STEP_MS));
    });
  }

  private accept(): void {
    const handler: ((row: RequestRowViewModel) => void) | undefined = this.onAccept;
    if (handler !== undefined) {
      handler(this.row);
    }
  }

  private reject(): void {
    const handler: ((row: RequestRowViewModel) => void) | undefined = this.onReject;
    if (handler !== undefined) {
      handler(this.row);
    }
  }

  private block(): void {
    const handler: ((row: RequestRowViewModel) => void) | undefined = this.onBlock;
    if (handler !== undefined) {
      handler(this.row);
    }
  }

  /** Swift `private var userInfoView: some View`. */
  @Builder
  userInfoView() {
    Row() {
      // Swift `avatarView` — `Image(uiImage: requestRow.avatar)`, the bindingContract image.
      AvatarSwiftUIView({
        avatarData: this.row.rowAvatar,
        displayText: this.row.rowName,
        isGroup: !this.row.request.isCoredialog(),
        avatarSize: AvatarSize.DEFAULT_55,
        groupAvatar: this.row.groupAvatar
      })

      Column() {
        // bindingContract[row name]. Swift: no .font() -> body; systemBackground foreground.
        Text(this.row.rowName)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.background_primary'))
          .width('100%')
        // Swift `.font(.footnote)`.
        Text(this.row.receivedDate)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.background_primary'))
          .margin({ top: NAME_DATE_GAP })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ start: LengthMetrics.vp(ROW_H_PADDING) })

      // Swift `Text(requestRow.status.toString())` — `.pending` has no text at all.
      if (this.row.hasStatusText()) {
        Text(this.row.statusText())
          .maxLines(1)
          .fontSize($r('sys.float.Body_L'))
          .fontColor(this.row.statusColor())
          .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * Swift `actionIcon(_:_:)`: the glyph CENTRED in a full-width pill
   * (`.padding(10).frame(maxWidth: .infinity)`). A weighted SymbolGlyph stretches its frame
   * but draws the glyph at the start edge, so the pill is the container and the glyph sits
   * centred inside it. The pill keeps the source's 20 pt box + 10 pt padding height whatever
   * font size the glyph needs to draw 20 vp.
   */
  @Builder
  actionIcon(symbol: Resource, size: number, angle: number, id: string, label: Resource,
    action: () => void) {
    Row() {
      SymbolGlyph(symbol)
        .fontSize(size)
        .fontColor([$r('app.color.requests_badge_foreground')])
        .rotate({ angle: angle })
    }
    .id(id)
    .accessibilityGroup(true)
    .accessibilityText(label)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .height(ACTION_ICON_SIZE + 2 * BUTTON_PADDING)
    .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
    .backgroundColor($r('app.color.requests_badge_background'))
    .borderRadius(ACTION_CORNER_RADIUS)
    .onClick(action)
  }

  /** Swift `private var actionButtonsView: some View`. */
  @Builder
  actionButtonsView() {
    Row() {
      // Swift `actionIcon("slash.circle", L10n.Accessibility.pendingRequestsListBlockUser)`.
      this.actionIcon($r('sys.symbol.nosign'), BLOCK_ICON_SIZE, BLOCK_ICON_ANGLE, 'requestsRowBlock',
        $r('app.string.accessibility_pending_requests_list_block_user'), () => {
          this.block();
        })

      Column()
        .width(ROW_H_PADDING)

      // Swift `actionIcon("xmark", L10n.Accessibility.pendingRequestsListRejectInvitation)`.
      this.actionIcon($r('sys.symbol.xmark'), REJECT_ICON_SIZE, 0, 'requestsRowReject',
        $r('app.string.accessibility_pending_requests_list_reject_invitation'), () => {
          this.reject();
        })

      Column()
        .width(ROW_H_PADDING)

      // Swift `actionIcon("checkmark", L10n.Accessibility.pendingRequestsListAcceptInvitation)`.
      this.actionIcon($r('sys.symbol.checkmark'), ACCEPT_ICON_SIZE, 0, 'requestsRowAccept',
        $r('app.string.accessibility_pending_requests_list_accept_invitation'), () => {
          this.accept();
        })
    }
    .width('100%')
  }

  build() {
    Column() {
      Column() {
        Column()
          .height(this.row.markedToRemove ? ROW_V_SPACER_MARKED : ROW_V_SPACER)
        this.userInfoView()
        Column()
          .height(ROW_V_SPACER)
        this.actionButtonsView()
        Column()
          .height(this.row.markedToRemove ? ROW_V_SPACER_MARKED : ROW_V_SPACER)
        // Swift `Divider().background(...opacity(markedToRemove ? 0 : 0.2))`.
        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.background_primary'))
          .opacity(this.row.markedToRemove ? 0 : DIVIDER_OPACITY)
      }
      .width('100%')
      .padding({ left: ROW_H_PADDING, right: ROW_H_PADDING })
      // Swift `backgroundView`: jamiRequestsBackground clipped to a 15 pt rounded rectangle,
      // shadowed while the row is marked to remove.
      .backgroundColor($r('app.color.jami_requests_background'))
      .borderRadius(ROW_CORNER_RADIUS)
      .shadow({
        radius: this.row.markedToRemove ? this.getUIContext().vp2px(MARKED_SHADOW_RADIUS) : 0,
        color: this.row.markedToRemove ? MARKED_SHADOW_COLOR : Color.Transparent
      })
      // Swift `.scaleEffect(markedToRemove ? scaleFactor : 1)` then `.rotationEffect`.
      .scale(this.row.markedToRemove ? { x: MARKED_SCALE, y: MARKED_SCALE } : { x: 1, y: 1 })
      .rotate({ angle: this.rotationDegrees })
    }
    .width('100%')
    .padding({
      left: this.row.markedToRemove ? MARKED_INSET : 0,
      right: this.row.markedToRemove ? MARKED_INSET : 0
    })
  }
}
