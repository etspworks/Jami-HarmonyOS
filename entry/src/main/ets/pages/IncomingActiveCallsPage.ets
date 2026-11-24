/*
 * screen_active_calls — "Incoming / Active Calls", ported from
 *   Ring/Ring/Features/Conversations/ActiveCalls/ActiveCallsView.swift (ActiveCallsView, CallRowView)
 *   Ring/Ring/Features/Conversations/ActiveCalls/ActiveCallsViewModel.swift
 *   Ring/Ring/Features/Conversations/ConversationsCoordinator.swift (subscribeToActiveCalls)
 *
 * presentation: modal, hostScreen: screen_smart_list. `ConversationsCoordinator
 * .subscribeToActiveCalls()` presents it `.overFullScreen` while CallService.activeCalls holds
 * an incoming, unanswered call, so it is a @CustomDialog mounted by
 * SmartListConversationsHomePage — NOT a routed page and NOT registered in main_pages.json.
 * It is raised by the service, not by a control, so the plan gives it no `navIn` edge.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): every control and branch
 * below comes from the source only.
 *
 * S3 — the real tree of `ActiveCallsView.body`:
 *   VStack(spacing: 0) {
 *       Spacer()
 *       if !(Array(viewModel.callsByAccount.keys).isEmpty) {
 *           ForEach(Array(viewModel.callsByAccount.keys), id: \.self) { accountId in
 *               if let calls = viewModel.callsByAccount[accountId] {
 *                   VStack(alignment: .leading, spacing: 8) {
 *                       ForEach(calls, id: \.call.id) { CallRowView(viewModel: $0) } } } }
 *       }
 *       Spacer()
 *   }
 *
 * bindingContract: [incoming-call list, one section per account] / [rows] are svc_calls —
 * `CallService.activeCalls`, deduplicated per remote identity exactly as
 * `ActiveCallsViewModel.updateCallViewModels(from:)` does (linked accounts sharing a swarm
 * receive the same call in each tracker, and the current account is iterated first so the
 * surviving row belongs to it). Rendered through LazyForEach over an ArrayDataSource; it
 * starts EMPTY and is filled by the service. [name/avatar] is the conversation the call
 * belongs to — never a literal.
 *
 * conditionalVariants[multi_account]: isMultiAccount — `callsByAccount.keys.count > 1` draws
 * one SECTION per account; with a single account the rows stand alone, as the source's
 * `ForEach` over one key does.
 *
 * navOut: present -> screen_call, trigger "Accept with video". screen_call is a modal whose
 * hostScreen is screen_conversation, and ConversationChatPage already mounts it (callDialog) —
 * the same indirection Swift has, where accepting hands the call to CallScreenPresenter.
 *
 * DAEMON GAP (Rule 11): accepting (`CallService.placeCall` on the call's own `rdv:` URI) and
 * refusing (`CallService.ignoreCall`) are daemon work. Each control calls the real service and
 * states the ceiling; none of them fakes a call.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ArrayDataSource } from '../common/ArrayDataSource';
// feat_voice_call: with no system call provider, the accepted call's audio route is activated
// here, exactly as screen_call does it (AudioService -> @kit.AudioKit).
import { AudioService } from '../common/AudioService';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { groupAvatarFor } from '../components/ExpandableAvatar';
import { AvatarSize } from '../common/JamiConstants';
import { CallService } from '../common/CallService';
import { ConversationsService } from '../common/ConversationsService';
import { describeError } from '../common/ErrorText';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountModel } from '../model/AccountModel';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { AccountCallTracker, ActiveCall } from '../model/ActiveCall';
import { CallDirection } from '../model/CallState';
import { ConversationModel } from '../model/ConversationModel';

/** Swift `VStack(alignment: .leading, spacing: 8)` around one account's rows. */
const SECTION_GAP: number = 8;
/** Swift `.cornerRadius(10)` on the card. */
const CARD_RADIUS: number = 10;
/** CallRowView: Swift `VStack(spacing: 12)` / `HStack(spacing: 12)`. */
const ROW_GAP: number = 12;
/** CallRowView: Swift `VStack(alignment: .leading, spacing: 10)` around title and label. */
const TEXT_GAP: number = 10;
/** CallRowView: `.font(.headline)` is 17 pt SEMIBOLD; ArkUI spells semibold as 600. */
const TITLE_WEIGHT: number = 600;
/** CallRowView: Swift `.font(.system(size: 25)).padding(10)` on each action glyph. */
const ACTION_GLYPH: number = 25;
const ACTION_PADDING: number = 10;

/* ── S5 (NO CAPTURE — the source's own, ActiveCallsView.swift:26-66) ─────────────────
 *   the page  .background(Color.black.opacity(0.5)).ignoresSafeArea()
 *   the card  .padding(.vertical).background(systemBackground + chrome material +
 *             systemGroupedBackground).cornerRadius(10).shadow(radius: 5)
 *             .padding(.horizontal).padding(.bottom).offset(y: -40)
 * The three stacked background layers resolve to one opaque grouped-background surface, which
 * is the token the card takes.
 */
/** Swift `Color.black.opacity(0.5)` behind the card. */
const SCRIM: string = '#80000000';
/** Swift `.shadow(radius: 5)`. */
const CARD_SHADOW_RADIUS: number = 5;
/** SwiftUI's default shadow colour at `.shadow(radius:)` — black at one third. */
const CARD_SHADOW_COLOR: string = '#55000000';
/** Swift `.padding(.horizontal)` / `.padding(.vertical)` — SwiftUI's default 16 pt. */
const CARD_INSET: number = 16;
/** Swift `.offset(y: -40)` — the card rides above the vertical centre. */
const CARD_OFFSET_Y: number = -40;
/**
 * The source's card is content-sized between two Spacers: it wraps its rows and nothing more.
 * A List with no height of its own takes its content's height, so only this cap is needed —
 * many calls scroll inside the card instead of pushing it past the window.
 */
const CARD_MAX_HEIGHT: string = '70%';

@CustomDialog
export struct IncomingActiveCallsOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /**
   * Swift `ConversationsCoordinator.subscribeToActiveCalls()` owns the presentation — the
   * overlay is raised and lowered by the SERVICE, not by a control, so the host's flag is the
   * one place that knows whether it is up.
   */
  @Link isPresented: boolean;
  /**
   * Swift: the coordinator presents the call screen as soon as the joined call is placed. This
   * overlay is gone by then, so the host raises screen_call.
   */
  onJoined?: () => void;

  /** bindingContract[incoming-call list] / [rows]: svc_calls <- `viewModel.callsByAccount`. */
  @State incomingCallListOneSectionPerAccount: ActiveCall[] = [];
  /** bindingContract[name/avatar]: CallState.displayName <- the call's conversation. */
  @State nameAvatar: string = '';
  /** conditionalVariants[multi_account]: Swift `callsByAccount.keys.count > 1`. */
  @State isMultiAccount: boolean = false;
  /** Swift `!Array(viewModel.callsByAccount.keys).isEmpty`. */
  @State hasCalls: boolean = false;
  /** True while svc_calls / svc_call_ui are in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** bindingContract[rows]: LazyForEach's source (CLAUDE.md rule 7), reloaded from the
   * activeCalls relay — `CallService.activeCalls`. */
  @State rows: ArrayDataSource<ActiveCall> = new ArrayDataSource<ActiveCall>([]);
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** The account each surviving row belongs to — Swift's `grouped` keys, per call. */
  private accountOfCall: Map<string, string> = new Map<string, string>();

  /** Swift `init(...)` — the current value, then every change. */
  aboutToAppear(): void {
    const calls: CallService = ServiceRegistry.shared().callService;
    this.applyTrackers(calls.activeCalls.value);
    this.bag.add(calls.activeCalls.subscribe(
      (trackers: Map<string, AccountCallTracker>): void => {
        this.applyTrackers(trackers);
      }));
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription goes whatever happens on the way out.
    this.bag.dispose();
  }

  /**
   * Swift `updateCallViewModels(from:)`, verbatim: the CURRENT account is iterated first, and
   * a call already seen under another account is dropped, so a swarm call that reached two
   * linked accounts leaves exactly one row and it belongs to the current account.
   */
  private applyTrackers(trackers: Map<string, AccountCallTracker>): void {
    const ordered: string[] = [];
    if (this.currentAccountId.length > 0 && trackers.has(this.currentAccountId)) {
      ordered.push(this.currentAccountId);
    }
    trackers.forEach((tracker: AccountCallTracker, accountId: string): void => {
      if (accountId !== this.currentAccountId) {
        ordered.push(accountId);
      }
    });

    const seen: string[] = [];
    const grouped: ActiveCall[] = [];
    const accounts: string[] = [];
    this.accountOfCall = new Map<string, string>();
    for (const accountId of ordered) {
      const tracker: AccountCallTracker | undefined = trackers.get(accountId);
      if (tracker === undefined) {
        continue;
      }
      for (const call of tracker.incomingNotAcceptedNotIgnoredCalls()) {
        const identity: string = call.remoteIdentity.hash();
        if (seen.includes(identity)) {
          continue;
        }
        seen.push(identity);
        grouped.push(call);
        this.accountOfCall.set(call.id, accountId);
        if (!accounts.includes(accountId)) {
          accounts.push(accountId);
        }
      }
    }

    this.incomingCallListOneSectionPerAccount = grouped;
    this.rows.reload(grouped);
    this.hasCalls = grouped.length > 0;
    this.isMultiAccount = accounts.length > 1;
    this.nameAvatar = grouped.length === 0 ? '' : this.titleFor(grouped[0]);

    // Swift `if grouped.isEmpty { onNoRenderableCalls?() }` — the coordinator dismisses.
    if (grouped.length === 0) {
      this.dismiss();
    }
  }

  /** Swift `findConversation(for:)` — the conversation the call belongs to. */
  private conversationFor(call: ActiveCall): ConversationModel | null {
    const conversations: ConversationsService = ServiceRegistry.shared().conversationsService;
    for (const conversation of conversations.conversations.value) {
      if (conversation.id === call.conversationId) {
        return conversation;
      }
    }
    return null;
  }

  /** Swift `swarmInfo` of a swarm with more than one peer — AvatarSwiftUIView's `isGroup`. */
  private isGroupCall(call: ActiveCall): boolean {
    const conversation: ConversationModel | null = this.conversationFor(call);
    return conversation !== null && !conversation.isCoredialog();
  }

  /**
   * Swift `ActiveCallRowViewModel.title` <- `swarmInfo.finalTitle`: the conversation the call
   * is in. Without a conversation the call's own peer uri is what the source would have shown.
   */
  private titleFor(call: ActiveCall): string {
    const conversation: ConversationModel | null = this.conversationFor(call);
    // Swift `swarmInfo.finalTitle` — the swarm's own title, the peer uri without one.
    return conversation !== null && conversation.title.length > 0 ? conversation.title : call.uri;
  }

  /**
   * S6: Swift's section is keyed by the account id but never PRINTS one — the keys only group
   * the rows. The grouped header this screen draws for conditionalVariants[multi_account]
   * therefore reads the account the way every other account surface in the app does (its
   * registered name), and keeps the raw id only when the account has no name yet.
   */
  private accountLabel(): string {
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(this.currentAccountId);
    if (account === null) {
      return this.currentAccountId;
    }
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    const helper: AccountModelHelper = new AccountModelHelper(
      details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
    const name: string = helper.registeredName;
    return name.length > 0 ? name : this.currentAccountId;
  }

  /** The account a row belongs to — Swift's `callsByAccount` key for it. */
  private accountFor(call: ActiveCall): string {
    const accountId: string | undefined = this.accountOfCall.get(call.id);
    return accountId === undefined ? this.currentAccountId : accountId;
  }

  /**
   * Swift `AvatarProvider.from(swarmInfo:)`: the CONVERSATION's avatar. A group without a
   * picture of its own draws the member composite (groupAvatarFor), never the photo of
   * whichever member hosts the call; only a dialog falls back on its peer's profile picture.
   */
  private avatarFor(call: ActiveCall, conversation: ConversationModel | null): string {
    if (conversation !== null && (conversation.avatar.length > 0 || !conversation.isCoredialog())) {
      return conversation.avatar;
    }
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    if (call.uri.length === 0 || account === null) {
      return '';
    }
    const photo: string | null =
      ServiceRegistry.shared().profileService.getProfile(call.uri, account.id).value.photo;
    return photo === null ? '' : photo;
  }

  /** Swift `.overFullScreen` dismissal — the overlay is not a stack entry. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /**
   * Swift `acceptCall()` / `acceptAudioCall()` — `ConversationState.startCall(contactRingId:)`
   * on the call's own `rdv:` URI, which the coordinator turns into a placeCall and the call
   * screen.
   */
  private answer(call: ActiveCall, audioOnly: boolean): void {
    const accountId: string = this.accountFor(call);
    this.isLoading = true;
    this.dismiss();
    ServiceRegistry.shared().callService
      .placeCall(accountId, call.constructURI(), audioOnly)
      .then((): void => {
        this.isLoading = false;
        const joined: (() => void) | undefined = this.onJoined;
        if (joined !== undefined) {
          joined();
        }
      })
      .catch((error: BusinessError): void => {
        this.isLoading = false;
        this.errorText = describeError(error);
      });
    // feat_voice_call: Swift's CallKit activated the session on accept; with no system
    // provider the in-app call UI does it, exactly as screen_call does on arrival.
    const audio: AudioService = ServiceRegistry.shared().audioService;
    audio.callKitActivated(!audioOnly, CallDirection.INCOMING);
  }

  /** Swift `rejectCall()` — `callService.ignoreCall(call:)`. Real: the tracker is local. */
  private rejectCall(call: ActiveCall): void {
    ServiceRegistry.shared().callService.ignoreCall(call);
    this.dismiss();
  }

  /** One of CallRowView's three icon-only actions — Swift `Image(systemName:)` in `.jami`. */
  @Builder
  private callAction(id: string, glyph: Resource, label: Resource, action: () => void) {
    Button() {
      // Swift `.font(.system(size: 25)).foregroundColor(.jami).padding(10)`.
      SymbolGlyph(glyph)
        .fontSize(ACTION_GLYPH)
        .fontColor([$r('app.color.jami')])
    }
    .id(id)
    .type(ButtonType.Normal)
    .backgroundColor(Color.Transparent)
    .padding(ACTION_PADDING)
    .accessibilityText(label)
    .onClick(action)
  }

  /**
   * Swift `CallRowView(viewModel:)` (ActiveCallsView.swift:67), one row per incoming call:
   *   VStack(spacing: 12) {
   *       HStack(spacing: 12) {
   *           AvatarSwiftUIView(source: viewModel.avatarProvider)        // default55
   *           VStack(alignment: .leading, spacing: 10) {
   *               Text(viewModel.title).font(.headline)
   *               Text(L10n.Calls.activeCallLabel) } }
   *       .padding(.horizontal)
   *       HStack { Spacer; video; Spacer; phone; Spacer; xmark; Spacer } }
   * SwiftUI's Text has no line limit, so the title and the label wrap in full.
   */
  @Builder
  private callRow(call: ActiveCall) {
    Column({ space: ROW_GAP }) {
      Row({ space: ROW_GAP }) {
        AvatarSwiftUIView({
          avatarData: this.avatarFor(call, this.conversationFor(call)),
          displayText: this.titleFor(call),
          isGroup: this.isGroupCall(call),
          avatarSize: AvatarSize.DEFAULT_55,
          groupAvatar: groupAvatarFor(this.conversationFor(call))
        })

        Column({ space: TEXT_GAP }) {
          // Swift `.font(.headline)`.
          Text(this.titleFor(call))
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(TITLE_WEIGHT)
            .fontColor($r('app.color.label'))

          // Swift spells no font or colour here — SwiftUI's `.body` in `.label`.
          Text($r('app.string.calls_active_call_label'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // Swift `.padding(.horizontal)`.
      .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })

      // Swift's Spacers either side of every button space the three evenly.
      Row() {
        Blank()
        this.callAction('activeCallAcceptVideo', $r('sys.symbol.video'),
          $r('app.string.calls_accept_with_video'), (): void => {
            this.answer(call, false);
          })
        Blank()
        this.callAction('activeCallAcceptAudio', $r('sys.symbol.phone'),
          $r('app.string.calls_accept_with_audio'), (): void => {
            this.answer(call, true);
          })
        Blank()
        this.callAction('activeCallReject', $r('sys.symbol.xmark'),
          $r('app.string.global_decline'), (): void => {
            this.rejectCall(call);
          })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  build() {
    Column() {
      Blank()

      // Swift `if !(Array(viewModel.callsByAccount.keys).isEmpty) { … }` — the card exists
      // only while there is a call to show.
      if (this.hasCalls) {
        Column({ space: SECTION_GAP }) {
          // conditionalVariants[multi_account]: Swift's outer `ForEach` over the account keys
          // draws a SECTION per account; one account draws the rows alone.
          if (this.isMultiAccount) {
            // The grouped section header over one account's rows.
            Text(this.accountLabel())
              .id('activeCallsAccountSection')
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.secondary_label'))
              .padding({
                start: LengthMetrics.vp(CARD_INSET),
                end: LengthMetrics.vp(CARD_INSET)
              })
          }

          // Swift `VStack(alignment: .leading, spacing: 8)` between one account's rows.
          List({ space: SECTION_GAP }) {
            LazyForEach(this.rows, (call: ActiveCall) => {
              ListItem() {
                this.callRow(call)
              }
            }, (call: ActiveCall) => call.hash())
          }
          .width('100%')
          // Content height; shrinks (and scrolls) only once the card reaches its cap.
          .flexShrink(1)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .constraintSize({ maxHeight: CARD_MAX_HEIGHT })
        // Swift `.padding(.vertical)` inside the card.
        .padding({ top: LengthMetrics.vp(CARD_INSET), bottom: LengthMetrics.vp(CARD_INSET) })
        // Swift's three stacked layers resolve to the grouped-background surface.
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius(CARD_RADIUS)
        .clip(true)
        .shadow({ radius: CARD_SHADOW_RADIUS, color: CARD_SHADOW_COLOR })
        // Swift `.offset(y: -40)`.
        .offset({ y: CARD_OFFSET_Y })
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    // Swift `.padding(.horizontal)` around the card, carried by the page so a percentage
    // width plus a horizontal margin never overflows.
    .padding({ start: LengthMetrics.vp(CARD_INSET), end: LengthMetrics.vp(CARD_INSET) })
    .justifyContent(FlexAlign.Center)
    // Swift `.background(Color.black.opacity(0.5)).ignoresSafeArea()`.
    .backgroundColor(SCRIM)
    .id('screen_active_calls')
  }
}
