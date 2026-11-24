/*
 * comp_conference_participants — ported from
 * Ring/Ring/Calls/Views/ConferenceParticipantsView.swift (line 80) with its two row types:
 *
 *   ScrollView { LazyVStack {
 *     if !model.pendingRows.isEmpty {
 *       sectionHeader(L10n.Calls.callingParticipants(count))
 *       ForEach(model.pendingRows) { PendingParticipantRowView }     // + "…_hangup"
 *     }
 *     participantsHeader                                             // in-this-call + actions
 *     ForEach(model.participantRows) { ParticipantRowView }          // + "…_options_menu"
 *   } }
 *
 *   participantsHeader accessories:
 *     if model.canModerateConference { "conference_participants_grid_layout" }
 *     if model.canAddParticipant     { "conference_participants_add_participant" }
 *
 *   ParticipantRowView   = avatar | name (+ status icons) | actions menu
 *                          status icons: speaking / hand raised / moderator / recording /
 *                                        audio muted / video muted — each on its own flag
 *   PendingParticipantRowView = dimmed avatar | name + progress | "Stop calling"
 *
 * TWO item types with different tap effects (open the moderator menu vs cancel the invite), so
 * they are separate row components with separate identifiers, never one uniform row.
 *
 * Icon substitutions (checked against the SDK symbol table):
 *   video.slash.fill -> sys.symbol.dot_video_slash
 *   hand.raised(.fill) -> the upright palm Path of CallControls (raisedHandCommands); the
 *                       symbol table's only bare hand is the spread, tilted one (T-1596)
 *   hand.raised.slash -> sys.symbol.hand_slash
 *   shield.slash     -> sys.symbol.checkmark_shield (the menu TITLE carries set/remove, as in
 *                       the source's own `title(for:)`)
 */
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AvatarSize } from '../common/JamiConstants';
import { ConferenceLayoutMode, ConferenceState } from '../model/CallState';
import { ConferenceParticipantInfo } from '../model/ConferenceParticipantInfo';
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { HAND_FONT_SCALE, HAND_WIDTH_RATIO, raisedHandCommands } from './CallControls';
import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (ConferenceParticipantsView.swift:21-44) ────────── */
/** Swift `RosterMetrics.margin = 20`, `avatarSpacing = 12`, `elementSpacing = 8`. */
const ROSTER_MARGIN: number = 20;
const ROSTER_AVATAR_SPACING: number = 12;
const ROSTER_ELEMENT_SPACING: number = 8;
/** Swift `RosterMetrics.textSpacing = 2`, `verticalPadding = 8`, `topPadding = 8`. */
const ROSTER_TEXT_SPACING: number = 2;
const ROSTER_V_PADDING: number = 8;
/** Swift `RosterMetrics.glyph = 24`, `tapTarget = 44`. */
const ROSTER_GLYPH: number = 24;
const ROSTER_TAP_TARGET: number = 44;
/** Swift `RosterMetrics.controlInset = margin - (tapTarget - glyph) / 2`. */
const ROSTER_CONTROL_INSET: number = ROSTER_MARGIN - (ROSTER_TAP_TARGET - ROSTER_GLYPH) / 2;
/** Swift `RosterMetrics.textLeading = margin + avatar + avatarSpacing`. */
const ROSTER_TEXT_LEADING: number = ROSTER_MARGIN + ROSTER_TAP_TARGET + ROSTER_AVATAR_SPACING;
/** Swift `.background(Color.jamiCallBackdrop.opacity(0.3))` behind the roster. */
const ROSTER_BACKDROP: string = '#4D06070A';
/** Swift `RosterMetrics.pendingAvatarOpacity = 0.5`. */
const PENDING_AVATAR_OPACITY: number = 0.5;
/** The roster's secondary text over the dark backdrop. */
const STATUS_COLOR: string = '#B3FFFFFF';
/** Swift `RosterTypography.status = .footnote` — the row's status glyphs. */
const STATUS_GLYPH: number = 13;
/**
 * Swift `.green`, `.red` and `.jamiRaiseHand`, dark scheme. UIColor+Ring's
 * `init(red: Int, green: Int, blue: Int, alpha:)` divides by 255, so (0, 184, 255) is #00B8FF
 * (the iPhone 11 draws exactly that, T-1596 review), not a clamped cyan.
 */
const STATUS_GREEN: string = '#30D158';
const STATUS_RED: string = '#FF453A';
const STATUS_RAISE_HAND: string = '#00B8FF';
/** The roster's hairline separator over the dark backdrop. */
const ROSTER_DIVIDER: string = '#33FFFFFF';
/** A downward drag from the roster's top closes it past this distance (vp) or speed (vp/s). */
const ROSTER_DISMISS_DRAG: number = 80;
const ROSTER_DISMISS_SPEED: number = 650;

/** The participant actions menu's width (iOS 4.20 UIMenu on a 390 pt screen). */
const ACTIONS_MENU_WIDTH: number = 250;
/** iOS 4.20's dark UIMenu surface over the roster, sampled on the iPhone (T-1729). */
const ACTIONS_MENU_BACKGROUND: string = '#FF282B26';
/** The hairline between UIMenu items: 1 px, (111,103,101) over the menu grey on the 4.20 sim. */
const ACTIONS_MENU_DIVIDER: string = '#50FFFFFF';

/** Swift `enum ConferenceMenuItem`. */
export enum ConferenceMenuItem {
  END_CALL = 'endCall',
  MINIMIZE = 'minimize',
  MAXIMIZE = 'maximize',
  SET_MODERATOR = 'setModerator',
  MUTE_AUDIO = 'muteAudio',
  RAISE_HAND = 'raiseHand',
  LOWER_HAND = 'lowerHand'
}

/** Swift `enum ConferenceRole`. */
export enum ConferenceRole {
  HOST = 'host',
  MODERATOR = 'moderator',
  REGULAR = 'regular'
}

/** Swift `ConferenceMenuBuilder` - the maximize/minimize part both menus share. */
function appendLayoutItems(menu: ConferenceMenuItem[], layout: ConferenceLayoutMode,
  isActive: boolean): void {
  if (layout === ConferenceLayoutMode.GRID) {
    menu.push(ConferenceMenuItem.MAXIMIZE);
  } else if (layout === ConferenceLayoutMode.ONE_WITH_SMALL) {
    menu.push(ConferenceMenuItem.MAXIMIZE);
    if (isActive) {
      menu.push(ConferenceMenuItem.MINIMIZE);
    }
  } else {
    menu.push(isActive ? ConferenceMenuItem.MINIMIZE : ConferenceMenuItem.MAXIMIZE);
  }
}

/** Swift `ConferenceMenuBuilder.menuForLocalTile(layout:isActive:isHandRaised:isModeratorMuted:)`. */
export function menuForLocalTile(layout: ConferenceLayoutMode, isActive: boolean,
  isHandRaised: boolean, isModeratorMuted: boolean): ConferenceMenuItem[] {
  const menu: ConferenceMenuItem[] =
    [isHandRaised ? ConferenceMenuItem.LOWER_HAND : ConferenceMenuItem.RAISE_HAND];
  appendLayoutItems(menu, layout, isActive);
  if (isModeratorMuted) {
    menu.push(ConferenceMenuItem.MUTE_AUDIO);
  }
  return menu;
}

/** Swift `ConferenceMenuBuilder.menuForParticipant(isHost:layout:isActive:role:isHandRaised:)`. */
export function menuForParticipant(isHost: boolean, layout: ConferenceLayoutMode, isActive: boolean,
  role: ConferenceRole, isHandRaised: boolean): ConferenceMenuItem[] {
  const menu: ConferenceMenuItem[] = [];
  if (isHandRaised) {
    menu.push(ConferenceMenuItem.LOWER_HAND);
  }
  appendLayoutItems(menu, layout, isActive);
  if (role === ConferenceRole.HOST) {
    menu.push(ConferenceMenuItem.MUTE_AUDIO, ConferenceMenuItem.SET_MODERATOR, ConferenceMenuItem.END_CALL);
  } else if (role === ConferenceRole.MODERATOR) {
    menu.push(ConferenceMenuItem.MUTE_AUDIO);
    if (!isHost) {
      menu.push(ConferenceMenuItem.END_CALL);
    }
  }
  return menu;
}

/**
 * Swift `ConferenceParticipants.actions(for:isLocal:conference:localInfo:builder:)`: the local
 * row's own menu or a participant's by the local role; without moderation rights the layout
 * items go.
 */
export function participantActions(info: ConferenceParticipantInfo, isLocal: boolean,
  conference: ConferenceState,
  localInfo: ConferenceParticipantInfo | undefined): ConferenceMenuItem[] {
  const isLocalModerator: boolean = localInfo !== undefined && localInfo.isModerator;
  let base: ConferenceMenuItem[];
  if (isLocal) {
    base = menuForLocalTile(conference.layout, info.isActive, info.isHandRaised, info.isAudioModeratorMuted);
  } else {
    const role: ConferenceRole = conference.isHost ? ConferenceRole.HOST
      : (isLocalModerator ? ConferenceRole.MODERATOR : ConferenceRole.REGULAR);
    base = menuForParticipant(conference.isHost, conference.layout, info.isActive, role, info.isHandRaised);
  }
  if (conference.isHost || isLocalModerator) {
    return base;
  }
  return base.filter((item: ConferenceMenuItem): boolean =>
    item !== ConferenceMenuItem.MAXIMIZE && item !== ConferenceMenuItem.MINIMIZE);
}

/** Swift `ConferenceParticipantRow` — one participant in the call. */
export class ConferenceParticipantRow {
  /** Swift `row.id` / `row.uri` <- svc_calls. */
  id: string = '';
  uri: string = '';
  /** The resolved name <- svc_profiles; empty falls back to the uri. */
  displayName: string = '';
  /** The name the avatar's initial and colour come from: displayName without '(You)'. */
  avatarName: string = '';
  avatar: string = '';
  isLocal: boolean = false;
  isSpeaking: boolean = false;
  isHandRaised: boolean = false;
  isModerator: boolean = false;
  isRecording: boolean = false;
  isAudioMuted: boolean = false;
  isAudioModeratorMuted: boolean = false;
  isVideoMuted: boolean = false;
  /** Swift `row.actions` — the moderator menu this row offers; empty means no menu at all. */
  actions: ConferenceMenuItem[] = [];
}

/** Swift `ParticipantRowView: Equatable` - the row redraws whenever any of its values changes. */
function rowKey(row: ConferenceParticipantRow): string {
  return [row.id, row.displayName, row.avatar.length, row.isSpeaking, row.isHandRaised,
  row.isModerator, row.isRecording, row.isAudioMuted, row.isAudioModeratorMuted,
  row.isVideoMuted, row.actions.join(',')].join('|');
}

/** Swift `PendingParticipantRow` — an invited participant who has not answered. */
export class PendingParticipantRow {
  id: string = '';
  uri: string = '';
  displayName: string = '';
  avatar: string = '';
  /** Swift `row.progressText` — "Calling…" and its later states. */
  progressText: string = '';
  /** Swift `row.callId` — what `cancelInvite` is called with. */
  callId: string = '';
}

/** Swift `private struct ParticipantRowView`. */
@Component
export struct ParticipantRowView {
  row: ConferenceParticipantRow = new ConferenceParticipantRow();
  /** Swift `perform($0, on: row.id)`. */
  onPerform?: (item: ConferenceMenuItem, participantId: string) => void;

  private perform(item: ConferenceMenuItem): void {
    const handler: ((item: ConferenceMenuItem, participantId: string) => void) | undefined =
      this.onPerform;
    if (handler !== undefined) {
      handler(item, this.row.id);
    }
  }

  /** Swift `title(for:)` — set/remove moderator and mute/unmute read off the row's own state. */
  private menuTitle(item: ConferenceMenuItem): ResourceStr {
    if (item === ConferenceMenuItem.SET_MODERATOR) {
      return this.row.isModerator
        ? $r('app.string.calls_remove_moderator')
        : $r('app.string.calls_set_moderator');
    }
    if (item === ConferenceMenuItem.MUTE_AUDIO) {
      return this.row.isAudioModeratorMuted
        ? $r('app.string.calls_unmute_audio')
        : $r('app.string.calls_mute_audio');
    }
    if (item === ConferenceMenuItem.MINIMIZE) {
      return $r('app.string.calls_minimize');
    }
    if (item === ConferenceMenuItem.MAXIMIZE) {
      return $r('app.string.calls_maximize');
    }
    if (item === ConferenceMenuItem.RAISE_HAND) {
      return $r('app.string.calls_raise_hand');
    }
    if (item === ConferenceMenuItem.LOWER_HAND) {
      return $r('app.string.calls_lower_hand');
    }
    return $r('app.string.accessibility_calls_default_end_call');
  }

  /** Swift `symbol(for:)`. */
  private menuIcon(item: ConferenceMenuItem): Resource {
    if (item === ConferenceMenuItem.END_CALL) {
      return $r('sys.symbol.phone_down_fill');
    }
    if (item === ConferenceMenuItem.MINIMIZE) {
      return $r('sys.symbol.arrow_down_right_and_arrow_up_left');
    }
    if (item === ConferenceMenuItem.MAXIMIZE) {
      return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
    }
    if (item === ConferenceMenuItem.SET_MODERATOR) {
      return $r('sys.symbol.checkmark_shield');
    }
    if (item === ConferenceMenuItem.MUTE_AUDIO) {
      return this.row.isAudioModeratorMuted
        ? $r('sys.symbol.mic_fill')
        : $r('sys.symbol.mic_slash_fill');
    }
    // Swift `hand.raised.slash` for Lower hand: the crossed-out hand. Raise hand's
    // `hand.raised` is the palm the menu row draws itself.
    return $r('sys.symbol.hand_slash');
  }

  /** Swift `statusIcons` — one glyph per flag the row carries. */
  @Builder
  private statusIcons() {
    // Swift `HStack(spacing: RosterMetrics.elementSpacing)` — 24pt white glyphs.
    Row({ space: ROSTER_ELEMENT_SPACING }) {
      // Swift `icon(name, color)`: `.footnote` glyphs, each in its own colour.
      if (this.row.isSpeaking) {
        // SF `waveform` is vertical level bars; HarmonyOS `waveform` is a sine line and
        // `waveform_1` is the bars (T-1426).
        SymbolGlyph($r('sys.symbol.waveform_1'))
          .fontSize(STATUS_GLYPH)
          .fontColor([STATUS_GREEN])
      }
      if (this.row.isHandRaised) {
        // Swift `hand.raised.fill`.
        Path()
          .width(STATUS_GLYPH * HAND_FONT_SCALE * HAND_WIDTH_RATIO)
          .height(STATUS_GLYPH * HAND_FONT_SCALE)
          .commands(raisedHandCommands(this.getUIContext(), STATUS_GLYPH * HAND_FONT_SCALE, true))
          .fill(STATUS_RAISE_HAND)
      }
      if (this.row.isModerator) {
        SymbolGlyph($r('sys.symbol.checkmark_shield_fill'))
          .fontSize(STATUS_GLYPH)
          .fontColor([$r('app.color.secondary_label')])
      }
      if (this.row.isRecording) {
        SymbolGlyph($r('sys.symbol.record_circle'))
          .fontSize(STATUS_GLYPH)
          .fontColor([STATUS_RED])
      }
      if (this.row.isAudioMuted) {
        SymbolGlyph($r('sys.symbol.mic_slash_fill'))
          .fontSize(STATUS_GLYPH)
          .fontColor([STATUS_RED])
      }
      if (this.row.isVideoMuted) {
        SymbolGlyph($r('sys.symbol.dot_video_slash'))
          .fontSize(STATUS_GLYPH)
          .fontColor([$r('app.color.secondary_label')])
      }
    }
    .alignItems(VerticalAlign.Center)
    .accessibilityLevel('no')
  }

  /** Swift `actionsMenu` — the Menu behind the ellipsis. */
  @Builder
  private actionsMenu() {
    Column() {
      ForEach(this.row.actions, (item: ConferenceMenuItem, index: number) => {
        if (index > 0) {
          Divider()
            .strokeWidth('1px')
            .color(ACTIONS_MENU_DIVIDER)
        }
        Row() {
          Text(this.menuTitle(item))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item === ConferenceMenuItem.RAISE_HAND) {
            // Swift `hand.raised`.
            Path()
              .width(ROSTER_GLYPH * HAND_FONT_SCALE * HAND_WIDTH_RATIO)
              .height(ROSTER_GLYPH * HAND_FONT_SCALE)
              .commands(raisedHandCommands(this.getUIContext(), ROSTER_GLYPH * HAND_FONT_SCALE, false))
              .fill($r('app.color.label'))
          } else {
            SymbolGlyph(this.menuIcon(item))
              .fontSize(ROSTER_GLYPH)
              .fontColor([$r('app.color.label')])
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: ROSTER_TAP_TARGET })
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        })
        .id('conference_participants_menu_itemroot')
        .onClick(() => {
          this.perform(item);
        })
      }, (item: ConferenceMenuItem) => item)
    }
    // A width of its own: '100%' rows in an unsized menu overflowed it and lost their edges.
    // iOS 4.20's menu is ~250 pt wide on a 390 pt screen.
    .width(ACTIONS_MENU_WIDTH)
    .backgroundColor(ACTIONS_MENU_BACKGROUND)
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .clip(true)
  }

  build() {
    // Swift `HStack(spacing: RosterMetrics.avatarSpacing)` + `rosterRowInsets()`.
    Row({ space: ROSTER_AVATAR_SPACING }) {
      AvatarSwiftUIView({
        avatarData: this.row.avatar,
        displayText: this.row.avatarName.length > 0 ? this.row.avatarName : this.row.displayName,
        isGroup: false,
        avatarSize: AvatarSize.MEDIUM_45
      })

      Column() {
        Text(this.row.displayName)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // Swift `RosterTypography.name = .subheadline.weight(.medium)`, white on the roster.
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.statusIcons()

      // Swift `if row.actions.isEmpty { Color.clear } else { actionsMenu }` — a row with no
      // moderator actions gets a spacer, not a dead button.
      if (this.row.actions.length > 0) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .id('conference_participants_options_menu')
          .accessibilityText($r('app.string.calls_participant_options', this.row.displayName))
          .fontSize(ROSTER_GLYPH)
          // Swift `RosterControlIcon(systemImage: "ellipsis.circle", color: .secondary)`.
          .fontColor([$r('app.color.secondary_label')])
          .width(ROSTER_TAP_TARGET)
          .height(ROSTER_TAP_TARGET)
          // T-1729: iOS 4.20 opens the menu above the row, trailing-aligned, with no outline. The
          // menu shell sits outside the roster's dark WithTheme, so its own light surface showed
          // as a ring around the dark content; shell and content share the iOS grey.
          .bindMenu(this.actionsMenu(), {
            placement: Placement.TopRight,
            backgroundColor: ACTIONS_MENU_BACKGROUND,
            backgroundBlurStyle: BlurStyle.NONE,
            outlineWidth: 0
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // Swift `rosterRowInsets()`.
    .padding({
      start: LengthMetrics.vp(ROSTER_MARGIN),
      end: LengthMetrics.vp(ROSTER_CONTROL_INSET),
      top: LengthMetrics.vp(ROSTER_V_PADDING),
      bottom: LengthMetrics.vp(ROSTER_V_PADDING)
    })
  }
}

/** Swift `private struct PendingParticipantRowView`. */
@Component
export struct PendingParticipantRowView {
  row: PendingParticipantRow = new PendingParticipantRow();
  /** Swift `model.cancelInvite(row.callId)`. */
  onCancel?: (callId: string) => void;

  build() {
    Row({ space: ROSTER_AVATAR_SPACING }) {
      AvatarSwiftUIView({
        avatarData: this.row.avatar,
        displayText: this.row.displayName,
        isGroup: false,
        avatarSize: AvatarSize.MEDIUM_45
      })
        // Swift `RosterMetrics.pendingAvatarOpacity = 0.5` — an invitee who has not answered.
        .opacity(PENDING_AVATAR_OPACITY)

      Column({ space: ROSTER_TEXT_SPACING }) {
        Text(this.row.displayName)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
        Text(this.row.progressText)
          // Swift `RosterTypography.status = .footnote`.
          .fontSize($r('sys.float.Body_S'))
          .fontColor(STATUS_COLOR)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Blank()

      SymbolGlyph($r('sys.symbol.phone_down_fill'))
        .id('conference_participants_hangup')
        .accessibilityText($r('app.string.calls_stop_calling', this.row.displayName))
        .fontSize(ROSTER_GLYPH)
        // Swift `RosterControlIcon(systemImage: "phone.down.fill", color: .red)`.
        .fontColor([STATUS_RED])
        .width(ROSTER_TAP_TARGET)
        .height(ROSTER_TAP_TARGET)
        .onClick(() => {
          const handler: ((callId: string) => void) | undefined = this.onCancel;
          if (handler !== undefined) {
            handler(this.row.callId);
          }
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      start: LengthMetrics.vp(ROSTER_MARGIN),
      end: LengthMetrics.vp(ROSTER_CONTROL_INSET),
      top: LengthMetrics.vp(ROSTER_V_PADDING),
      bottom: LengthMetrics.vp(ROSTER_V_PADDING)
    })
  }
}

@Component
export struct ConferenceParticipantsView {
  /** bindingContract[conference participant list] <- svc_calls. */
  participants: ArrayDataSource<ConferenceParticipantRow> =
    new ArrayDataSource<ConferenceParticipantRow>([]);
  /** Swift `model.pendingRows`. */
  pending: ArrayDataSource<PendingParticipantRow> =
    new ArrayDataSource<PendingParticipantRow>([]);
  // @Prop, not plain fields: a plain field is read once, so the open roster kept stale values.
  /** Swift `model.pendingRows.isEmpty` — the pending section exists only when there are any. */
  @Prop hasPending: boolean = false;
  /** Swift `model.pendingRows.count` — the "Calling (n)" title. */
  @Prop pendingCount: number = 0;
  /** Swift `model.participantRows.count` — the "In this call (n)" title. */
  @Prop participantCount: number = 0;
  /** conditionalVariants[conference_host]: Swift `model.canModerateConference`. */
  @Prop canModerateConference: boolean = false;
  /** Swift `model.canAddParticipant`. */
  @Prop canAddParticipant: boolean = false;

  onPerform?: (item: ConferenceMenuItem, participantId: string) => void;
  onCancelInvite?: (callId: string) => void;
  /** Swift `model.showGridLayout`. */
  onShowGridLayout?: () => void;
  /** Swift `model.addParticipantTapped`. */
  onAddParticipant?: () => void;
  /** Swift `.sheet(isPresented:)`'s interactive dismissal: the host closes the roster. */
  onDismiss?: () => void;

  private scroller: Scroller = new Scroller();
  /** The drag began with the list at its top, so it pulls the sheet rather than the rows. */
  private dragFromTop: boolean = false;

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  /** Swift `participantsHeader` — the count plus the moderator's own two actions. */
  @Builder
  private participantsHeader() {
    // Swift `HStack(spacing: RosterMetrics.elementSpacing)` at `minHeight: tapTarget`, its
    // title `.headline` white and the two moderator glyphs `.title3`.
    Row({ space: ROSTER_ELEMENT_SPACING }) {
      Text($r('app.string.calls_in_this_call', this.participantCount.toString()))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
      Blank()
      if (this.canModerateConference) {
        SymbolGlyph($r('sys.symbol.square_grid_2x2'))
          .id('conference_participants_grid_layout')
          .accessibilityText($r('app.string.calls_grid_layout'))
          .fontSize(ROSTER_GLYPH)
          .fontColor([Color.White])
          .width(ROSTER_TAP_TARGET)
          .height(ROSTER_TAP_TARGET)
          .onClick(() => {
            this.fire(this.onShowGridLayout);
          })
      }
      if (this.canAddParticipant) {
        SymbolGlyph($r('sys.symbol.person_badge_plus'))
          .id('conference_participants_add_participant')
          .accessibilityText($r('app.string.accessibility_calls_default_add_participant'))
          .fontSize(ROSTER_GLYPH)
          .fontColor([Color.White])
          .width(ROSTER_TAP_TARGET)
          .height(ROSTER_TAP_TARGET)
          .onClick(() => {
            this.fire(this.onAddParticipant);
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROSTER_TAP_TARGET })
    .padding({
      start: LengthMetrics.vp(ROSTER_MARGIN),
      end: LengthMetrics.vp(ROSTER_CONTROL_INSET),
      top: LengthMetrics.vp(ROSTER_V_PADDING),
      bottom: LengthMetrics.vp(ROSTER_V_PADDING)
    })
  }

  build() {
    List({ scroller: this.scroller }) {
      // Swift `if !model.pendingRows.isEmpty` — header and rows together, or neither.
      if (this.hasPending) {
        ListItem() {
          // Swift `sectionTitle` — flush with 'In this call (n)', as the iPhone 4.20 draws it.
          Text($r('app.string.calls_calling_participants', this.pendingCount.toString()))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({
              start: LengthMetrics.vp(ROSTER_MARGIN),
              end: LengthMetrics.vp(ROSTER_MARGIN),
              top: LengthMetrics.vp(ROSTER_V_PADDING),
              bottom: LengthMetrics.vp(ROSTER_V_PADDING)
            })
        }
        LazyForEach(this.pending, (row: PendingParticipantRow) => {
          ListItem() {
            PendingParticipantRowView({ row: row, onCancel: this.onCancelInvite })
          }
        }, (row: PendingParticipantRow) => row.id + row.displayName + row.progressText)
      }

      ListItem() {
        this.participantsHeader()
      }

      LazyForEach(this.participants, (row: ConferenceParticipantRow) => {
        ListItem() {
          ParticipantRowView({ row: row, onPerform: this.onPerform })
        }
      }, (row: ConferenceParticipantRow) => rowKey(row))
    }
    .width('100%')
    .height('100%')
    // Swift `.background(Color.jamiCallBackdrop.opacity(0.3))`.
    .backgroundColor(ROSTER_BACKDROP)
    .scrollBar(BarState.Off)
    .divider({ strokeWidth: 0.5, color: ROSTER_DIVIDER, startMargin: ROSTER_TEXT_LEADING })
    // Swift: a sheet is swiped down to close it, uncovering the call controls under the
    // medium detent, hang-up included (T-1595).
    .parallelGesture(PanGesture({ direction: PanDirection.Down })
      .onActionStart(() => {
        this.dragFromTop = this.scroller.currentOffset().yOffset <= 0;
      })
      .onActionEnd((event: GestureEvent) => {
        if (this.dragFromTop &&
          (event.offsetY > ROSTER_DISMISS_DRAG || event.velocityY > ROSTER_DISMISS_SPEED)) {
          this.fire(this.onDismiss);
        }
      }))
  }
}
