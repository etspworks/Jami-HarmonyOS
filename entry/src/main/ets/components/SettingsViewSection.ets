/*
 * comp_settings_view_section — ported from Ring/Ring/SwarmInfo/View/SettingsView.swift
 * `struct SettingsView` (line 20), the About tab of SwarmInfoView:
 *
 *   body = contactSection ; conversationSection
 *
 *   contactSection (only when viewmodel.getContactJamiId() != nil — a coredialog):
 *     Section(header: L10n.Swarm.contactHeader) {
 *       identifierView(L10n.Swarm.identifier, jamiId)
 *       qrCodeButton      -> showQRcode = true, .sheet { QRCodePresenter }
 *       shareContactButton-> ShareButtonView(infoToShare: createShareInfo(for: jamiId))
 *       removeContactButton -> presentingAlert = .removeContact
 *       blockContactButton  -> presentingAlert = .blockContact }
 *
 *   conversationSection:
 *     Section(header: L10n.Swarm.conversationHeader) {
 *       identifierView(L10n.Swarm.conversationId, swarmInfo.id)
 *       swarmTypeView      HStack { typeOfSwarm ; Spacer ; type.stringValue }
 *       colorPickerView    HStack { chooseColor ; Spacer ; colorCircle }
 *       removeConversationButton -> presentingAlert = .removeConversation }
 *
 *   colorCircle = ZStack { Circle(finalColor).onTapGesture { showColorPicker = true }
 *                            .accessibilityIdentifier("swarm_settings_color_circle")
 *                            .sheet { AccessibleCustomColorPicker }
 *                          Circle().stroke(finalColor) }
 *                 .accessibilityIdentifier("swarm_settings_choose_color")
 *
 * TWO CONTROLS, ONE ROW. The source gives the filled circle and the ZStack around it separate
 * identifiers, and `controlInventory` carries both ("Conversation colour" / "Choose colour"),
 * so BOTH are tappable here and both open the picker — a slug on a wrapper whose handler sits
 * on a descendant reads as an inert control.
 *
 * The three destructive rows raise the host's confirmation alert rather than acting straight
 * away, exactly as `presentingAlert` does; the host owns the alert because Swift hangs it off
 * `removeConversationButton` for all three.
 *
 * conditionalVariants[one_to_one] is the contact section: a group conversation has no contact
 * and Swift renders nothing for it.
 *
 * S5 — STYLE. The source declares its own metrics (`textSpacing` 10, the colour circle's
 * 15 / 5 / 25 / 10) and its own colours (`Color.jami` for the contact actions,
 * `Color.jamiFailure` #F00000 for the two destructive ones, `.secondaryLabel` for the swarm
 * type's value); everything else is the iOS GROUPED table this screen uses, mapped by role:
 *   the page it sits on is systemGroupedBackground -> sys.color.background_secondary
 *   a row is secondarySystemGroupedBackground      -> sys.color.comp_background_list_card
 *   the header is a .footnote, up-cased by the platform -> Body_S / secondary_label
 * The capture (S0098, 393x852 pt) confirms the geometry, and it is the PLAIN grouped style,
 * not the inset one: the rows run edge to edge (x 0..393) with their content inset 20, the
 * separators start at x 20, and the "Conversation" header sits at [20,289]-[120,304]. Row
 * heights are 44 (type / colour / remove) with the two-line identifier at 67.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { describeError } from '../common/ErrorText';
import { ShareActions, ShareOutcome } from '../common/ShareActions';
import { QRCodePresenter } from './QrCodePresenterBody';
import { AccessibleCustomColorPicker } from './AccessibleColorPicker';

/** Swift `private let textSpacing`. */
const TEXT_SPACING: number = 10;
/** The floor an identifier shrinks to before the middle ellipsis takes over. */
const ID_MIN_FONT_SIZE: number = 9;
/** Swift `private let iconSize` — the filled colour circle. */
const COLOR_CIRCLE_SIZE: number = 15;
/** Swift `private let iconStrokeWidth` / `iconFrameSize`. */
const COLOR_RING_WIDTH: number = 5;
// SwiftUI strokes on the path's centre, so Swift's 25pt frame draws the ring from 20 to 30pt and
// leaves a 2.5pt white gap round the 15pt fill. An ArkUI border draws INSIDE its box, so the
// box is iconFrameSize + iconStrokeWidth for the same ring (T-1109).
const COLOR_RING_SIZE: number = 30;
/** Swift `private let iconPadding`. */
const COLOR_CIRCLE_PADDING: number = 10;
/** A grouped row's minimum height; the text may grow past it with the system font size. */
const ROW_MIN_HEIGHT: number = 44;
/** The leading glyph of a grouped action row. */
const ROW_ICON_SIZE: number = 20;
const ROW_ICON_GAP: number = 12;
/** The drawn `square.and.arrow.up`: DiagnosticsLogPage's 22x28 trace scaled to the row's 20. */
const SHARE_GLYPH_WIDTH: number = 16;
const SHARE_GLYPH_STROKE: number = 1.5;
/** The grouped row's content inset — the capture puts every label at x 20. */
const ROW_INSET: number = 20;
/** UIKit insets a cell's separator to its text label: under an icon row that is past the glyph. */
const ICON_ROW_SEPARATOR_INSET: number = ROW_INSET + ROW_ICON_SIZE + ROW_ICON_GAP;
/** Swift `Color.jamiFailure` (`UIColor(hex: 0xf00000)`); the app carries no resource for it. */
const JAMI_FAILURE: string = '#F00000';
/** The grouped table's hairline. */
const SEPARATOR_WIDTH: number = 0.5;
/** The capture's header band: 272..310, with the label's baseline 17 pt down. */
const SECTION_HEADER_TOP: number = 18;
const SECTION_HEADER_BOTTOM: number = 6;

/** A grouped row's surface: the white cell and its 20 pt content inset. */
@Styles function groupedRow() {
  .width('100%')
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .padding({
      start: LengthMetrics.vp(ROW_INSET),
      end: LengthMetrics.vp(ROW_INSET)
    })
}

@Component
export struct SettingsViewSection {
  /** Swift `viewmodel.getContactJamiId()` — empty for a group (no contact section). */
  @Prop contactJamiId: string = '';
  /** conditionalVariants[one_to_one]: Swift renders `contactSection` only for a coredialog. */
  @Prop isOneToOne: boolean = false;
  /** Swift `viewmodel.swarmInfo.id` <- ConversationModel.id. */
  @Prop conversationId: string = '';
  /** Swift `viewmodel.swarmInfo.type.value.stringValue`, already resolved by the page. */
  @Prop conversationTypeLabel: string = '';
  /** Swift `viewmodel.finalColor` <- ConversationPreferences.color. */
  @Prop finalColor: string = '';
  /** Swift `@Binding viewmodel.selectedColor` — the picker writes it, the page persists it. */
  @Link selectedColor: string;
  /** Swift `viewmodel.createShareInfo(for: jamiId)`. */
  @Prop shareInfo: string = '';
  /** Swift `viewmodel.removeConversationText`, resolved by the page. */
  @Prop removeConversationLabel: string = '';
  /** Swift `ConversationRemovalPresentation == .leave` — picks `removeConversationIcon`. */
  @Prop isLeave: boolean = false;

  /**
   * Swift `@SwiftUI.State private var showQRcode`. Lifted to the host page (`@Link`, same
   * shape as `isColorPickerOpen` below) so the page's onBackPress can close this sheet
   * instead of hardware Back popping the whole page.
   */
  @Link showQRcode: boolean;
  /** conditionalVariants[color_picker_open]: Swift `showColorPicker == true`. */
  @Link isColorPickerOpen: boolean;

  /** Swift `presentingAlert = .removeContact`. */
  onRemoveContact?: () => void;
  /** Swift `presentingAlert = .blockContact`. */
  onBlockContact?: () => void;
  /** Swift `presentingAlert = .removeConversation`. */
  onRemoveConversation?: () => void;

  /**
   * The hairline BETWEEN two rows. The cell stays full-bleed white while the rule itself
   * starts at the content inset, which is why the inset is PADDING and not a margin: a
   * margin would leave the gap transparent and the grey page would show through it.
   */
  @Builder
  private rowSeparator(inset: number = ROW_INSET) {
    Divider()
      .color($r('sys.color.comp_divider'))
      .strokeWidth(SEPARATOR_WIDTH)
      .padding({ start: LengthMetrics.vp(inset) })
      .backgroundColor($r('sys.color.comp_background_list_card'))
  }

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  /** Swift `identifierView(label:value:)`. */
  @Builder
  private identifierView(label: ResourceStr, value: string) {
    Column({ space: TEXT_SPACING }) {
      // Swift `Text(label + ":")` — the colon is part of the RENDER, not of the localized
      // string (the capture reads "Conversation ID:"), and a ResourceStr cannot be
      // concatenated, so the separator is its own Text beside the bound label.
      Row() {
        Text(label)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        Text(':')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // Swift `selectableText(value)` — read-only, so a Text and never a button.
      // `.truncationMode(.middle)`: a long id keeps its head and tail (T-1706).
      // Swift `.font(.footnote)` is Body_S; on a narrow fold the 40-hex id shrinks to fit
      // before it would elide, so it reads in full as on iOS (T-1067, T-1069).
      Text(value)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .ellipsisMode(EllipsisMode.CENTER)
        .maxFontSize($r('sys.float.Body_S'))
        .minFontSize(ID_MIN_FONT_SIZE)
        .fontColor($r('app.color.secondary_label'))
    }
    .alignItems(HorizontalAlign.Start)
    .groupedRow()
    .padding({
      start: LengthMetrics.vp(ROW_INSET),
      end: LengthMetrics.vp(ROW_INSET),
      top: LengthMetrics.vp(TEXT_SPACING),
      bottom: LengthMetrics.vp(TEXT_SPACING)
    })
  }

  /**
   * One grouped action row: a leading glyph then its title, the whole row tappable. Swift
   * tints the glyph AND the label with the same colour — `Color.jami` for the two contact
   * actions, `Color.jamiFailure` for the destructive ones — so the tint is a parameter.
   */
  @Builder
  private actionRow(icon: Resource, title: ResourceStr, slug: string, tint: ResourceColor,
    action: () => void) {
    Row({ space: ROW_ICON_GAP }) {
      SymbolGlyph(icon)
        .fontSize(ROW_ICON_SIZE)
        .fontColor([tint])
      Text(title)
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor(tint)
    }
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .groupedRow()
    .id(slug)
    // The whole row is Swift's Button, so the handler is here and not on the glyph inside it.
    .onClick(() => {
      action();
    })
  }

  /**
   * Swift `person.crop.circle.badge.minus` / `.badge.xmark`: HM symbols have neither, so the
   * glyph is composed - the filled person circle with the badge at its bottom-leading corner,
   * cut out of the row by a ring in the row colour (review T-1222/T-1224).
   */
  @Builder
  private personBadgeRow(badge: Resource, title: ResourceStr, slug: string, tint: ResourceColor,
    action: () => void) {
    Row({ space: ROW_ICON_GAP }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(ROW_ICON_SIZE)
          .fontColor([tint])
        SymbolGlyph(badge)
          .fontSize(ROW_ICON_SIZE / 2)
          .fontColor([tint])
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(ROW_ICON_SIZE / 4)
          .margin({ start: LengthMetrics.vp(-ROW_ICON_SIZE / 8) })
      }
      .width(ROW_ICON_SIZE)
      .height(ROW_ICON_SIZE)
      Text(title)
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor(tint)
    }
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .groupedRow()
    .id(slug)
    .onClick(() => {
      action();
    })
  }

  /** Swift `private var colorCircle`. */
  @Builder
  private colorCircle() {
    Stack() {
      // Swift `Circle().fill(Color(hex: finalColor) ?? .gray).onTapGesture { ... }`.
      Column()
        .width(COLOR_CIRCLE_SIZE)
        .height(COLOR_CIRCLE_SIZE)
        .borderRadius(COLOR_CIRCLE_SIZE / 2)
        .backgroundColor(this.finalColor.length > 0 ? this.finalColor : Color.Gray)
        .margin(COLOR_CIRCLE_PADDING)
        .id('swarm_settings_color_circle')
        .onClick(() => {
          this.isColorPickerOpen = true;
        })

      // Swift `Circle().stroke(Color(hex: finalColor) ?? .gray, lineWidth: iconStrokeWidth)`.
      Column()
        .width(COLOR_RING_SIZE)
        .height(COLOR_RING_SIZE)
        .borderRadius(COLOR_RING_SIZE / 2)
        .borderWidth(COLOR_RING_WIDTH)
        .borderColor(this.finalColor.length > 0 ? this.finalColor : Color.Gray)
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .id('swarm_settings_choose_color')
    // Swift `.accessibilityLabel(L10n.Swarm.chooseColor).accessibilityValue(finalColor)`.
    .accessibilityText($r('app.string.swarm_choose_color'))
    .onClick(() => {
      this.isColorPickerOpen = true;
    })
    // Swift hangs the picker sheet off this element; the picker's own
    // `.optionalMediumPresentationDetents()` is `presentationDetents([.medium])` (T-1687).
    .bindSheet($$this.isColorPickerOpen, this.colorPickerSheet(),
      { detents: [SheetSize.MEDIUM], showClose: false })
  }

  /**
   * comp_accessible_color_picker — Swift's `.sheet { AccessibleCustomColorPicker(...) }`.
   *
   * conditionalVariants[color_picker_open]: SwiftUI builds a `.sheet`'s content lazily, only
   * once it is presented, so the swatch grid does not exist while the picker is closed. The
   * `if` is that same contract — and it is what keeps the picker's own state from being
   * carried over from a previous presentation.
   */
  @Builder
  private colorPickerSheet() {
    // No `if (isColorPickerOpen)` around the picker: when the picker's own Cancel lowered the
    // flag, the `if` emptied the sheet before bindSheet saw the change and the empty sheet
    // stayed up until a second Back (review T-1689). The picker keeps no state of its own.
    AccessibleCustomColorPicker({
      isPresented: $isColorPickerOpen,
      selectedColor: $selectedColor,
      currentColor: this.finalColor
    })
  }

  /** comp_qr_code_presenter_body — Swift's `.sheet(isPresented: $showQRcode)`. */
  @Builder
  private qrCodeSheet() {
    QRCodePresenter({
      isPresented: $showQRcode,
      jamiId: this.contactJamiId,
      accessibilityLabel: $r('app.string.swarm_accessibility_contact_qr_code')
    })
  }

  /**
   * Swift `ShareButtonView(infoToShare:)` — the iOS share-sheet presenter. On HarmonyOS that
   * is `ShareActions.share` (@kit.ShareKit systemShare, with the MANDATORY pasteboard + toast
   * fallback the utility already owns), so the row raises it directly rather than through a
   * second wrapper: the wrapper's whole job was to carry this one call and the caller's slug,
   * both of which this row has.
   */
  private shareContact(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ShareActions.share(context, this.shareInfo,
      context.resourceManager.getStringByNameSync('swarm_share_contact_info'))
      .then((outcome: ShareOutcome): void => {
        if (outcome === ShareOutcome.FAILED) {
          // ShareActions already announced it; nothing here may claim it was shared.
          console.warn('SettingsViewSection: the contact could not be shared');
        }
      })
      .catch((error: BusinessError): void => {
        console.error(`SettingsViewSection.shareContact failed: ${describeError(error)}`);
      });
  }

  /**
   * SF `square.and.arrow.up` on a SHARE_GLYPH_WIDTH x ROW_ICON_SIZE box (DiagnosticsLogPage's
   * trace): a rounded box over the lower 69% whose top edge stops a third of the way in from
   * each side, and an arrow from its middle up through that gap. Path commands are px.
   */
  private shareGlyphCommands(): string {
    const p = (vp: number): string => this.getUIContext().vp2px(vp).toFixed(2);
    const w: number = SHARE_GLYPH_WIDTH;
    const h: number = ROW_ICON_SIZE;
    const s: number = SHARE_GLYPH_STROKE / 2;
    const top: number = h * 0.31;
    const r: number = 2;
    const mid: number = w / 2;
    const head: number = w * 0.21;
    return `M${p(w * 0.34)} ${p(top)} L${p(s + r)} ${p(top)} ` +
      `Q${p(s)} ${p(top)} ${p(s)} ${p(top + r)} ` +
      `L${p(s)} ${p(h - s - r)} Q${p(s)} ${p(h - s)} ${p(s + r)} ${p(h - s)} ` +
      `L${p(w - s - r)} ${p(h - s)} Q${p(w - s)} ${p(h - s)} ${p(w - s)} ${p(h - s - r)} ` +
      `L${p(w - s)} ${p(top + r)} Q${p(w - s)} ${p(top)} ${p(w - s - r)} ${p(top)} ` +
      `L${p(w * 0.66)} ${p(top)} M${p(mid)} ${p(s)} L${p(mid)} ${p(h * 0.62)} ` +
      `M${p(mid - head)} ${p(h * 0.19)} L${p(mid)} ${p(s)} L${p(mid + head)} ${p(h * 0.19)}`;
  }

  /** Swift's `ShareButtonView { HStack { ... } }` label. */
  @Builder
  private shareContactLabel() {
    Row({ space: ROW_ICON_GAP }) {
      // SF `square.and.arrow.up`: HMSymbolVF has none (`arrow_right_up_and_square` is the
      // external-link box, T-1268), so it is drawn as DiagnosticsLogPage draws it.
      Stack() {
        Path()
          .width(SHARE_GLYPH_WIDTH)
          .height(ROW_ICON_SIZE)
          .commands(this.shareGlyphCommands())
          .fillOpacity(0)
          .stroke($r('app.color.jami'))
          .strokeWidth(SHARE_GLYPH_STROKE)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(ROW_ICON_SIZE)
      .height(ROW_ICON_SIZE)
      Text($r('app.string.swarm_share_contact_info'))
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
  }

  build() {
    Column() {
      // conditionalVariants[one_to_one]: Swift `if let jamiId = viewmodel.getContactJamiId()`.
      if (this.isOneToOne && this.contactJamiId.length > 0) {
        Text($r('app.string.swarm_contact_header'))
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
        this.identifierView($r('app.string.swarm_identifier'), this.contactJamiId)
        this.rowSeparator()

        // Swift `qrCodeButton(jamiId:)` — the sheet hangs off this row, as in the source.
        Row({ space: ROW_ICON_GAP }) {
          SymbolGlyph($r('sys.symbol.qrcode'))
            .fontSize(ROW_ICON_SIZE)
            .fontColor([$r('app.color.jami')])
          Text($r('app.string.swarm_show_contact_qr_code'))
            .layoutWeight(1)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
        }
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: ROW_MIN_HEIGHT })
        .groupedRow()
        .id('swarm_settings_show_contact_qrcode')
        .accessibilityDescription($r('app.string.swarm_accessibility_contact_qr_code_hint'))
        .onClick(() => {
          this.showQRcode = true;
        })
        .bindSheet($$this.showQRcode, this.qrCodeSheet(),
          // Swift QRCodePresenter `.optionalMediumPresentationDetents()` (review T-1258).
          { detents: [SheetSize.MEDIUM], showClose: false })
        this.rowSeparator(ICON_ROW_SEPARATOR_INSET)

        // Swift `shareContactButton(jamiId:)`. The whole row is the source's Button, so the
        // slug and the handler are on it and not on the glyph inside it.
        Column() {
          this.shareContactLabel()
        }
        .groupedRow()
        .id('swarm_settings_share_contact')
        .accessibilityDescription($r('app.string.swarm_accessibility_contact_share_hint'))
        .onClick(() => {
          this.shareContact();
        })
        this.rowSeparator(ICON_ROW_SEPARATOR_INSET)

        // Swift `removeContactButton()` — person.crop.circle.badge.minus (icon-map:
        // candidates; minus_circle is the only candidate that carries "remove"). Swift tints
        // this one `Color.jami`, NOT the failure red the block row below takes.
        this.personBadgeRow($r('sys.symbol.minus_circle_fill'),
          $r('app.string.swarm_remove_contact'),
          'swarm_settings_remove_contact',
          $r('app.color.jami'),
          (): void => {
            this.fire(this.onRemoveContact);
          })
        this.rowSeparator(ICON_ROW_SEPARATOR_INSET)

        // Swift `blockContactButton()` — person.crop.circle.badge.xmark (icon-map: candidates),
        // `.foregroundColor(Color.jamiFailure)`.
        this.personBadgeRow($r('sys.symbol.xmark_circle_fill'),
          $r('app.string.global_block_contact'),
          'swarm_settings_block_contact',
          JAMI_FAILURE,
          (): void => {
            this.fire(this.onBlockContact);
          })
      }

      // Swift `conversationSection` — always rendered, group or not.
      Text($r('app.string.swarm_conversation_header'))
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
      this.identifierView($r('app.string.swarm_conversation_id'), this.conversationId)
      this.rowSeparator()

      // Swift `swarmTypeView`.
      Row() {
        Text($r('app.string.swarm_type_of_swarm'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        Blank()
        // Swift `.foregroundColor(Color(UIColor.secondaryLabel))` — a read-only value.
        Text(this.conversationTypeLabel)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.secondary_label'))
      }
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: ROW_MIN_HEIGHT })
      .groupedRow()
      this.rowSeparator()

      // Swift `colorPickerView`.
      Row() {
        Text($r('app.string.swarm_choose_color'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        Blank()
        this.colorCircle()
      }
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: ROW_MIN_HEIGHT })
      .groupedRow()
      this.rowSeparator()

      // Swift `removeConversationButton` — `.foregroundColor(Color.jamiFailure)`, which is
      // the red the capture shows on the title and its glyph.
      // Swift `removeConversationIcon`: "arrow.right.circle" to leave, "trash" to remove.
      this.actionRow(this.isLeave ? $r('sys.symbol.arrow_right_circle') : $r('sys.symbol.trash'),
        this.removeConversationLabel,
        'swarm_settings_remove_conversation',
        JAMI_FAILURE,
        (): void => {
          this.fire(this.onRemoveConversation);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
