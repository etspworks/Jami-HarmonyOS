/*
 * comp_message_panel — ported from
 * .../MessageSwiftUI/Views/MessagePanelView.swift `struct MessagePanelView` (line 126),
 * `struct ReplyViewInMessagePanel` (line 63) and the top-view wrapper (line 35):
 *
 *   VStack(spacing: 0) {
 *     if let message = model.messageToReply { ReplyViewInMessagePanel(...) }
 *     else if let edit = model.messageToEdit { EditMessagePanel(...) }   // both carry the
 *         top view's close button, "messagePanelCloseTopView"
 *     HStack(alignment: .bottom) { moreActionsButton(); messageTextField() }
 *   }
 *
 *   moreActionsButton() = Menu(content: menuContent) { Image(systemName: "plus") }
 *       .accessibilityIdentifier("messagePanelMoreActions")
 *   messageTextField()  = HStack { UITextViewWrapper("messagePanelTextField"); sendEmojiButton() }
 *   sendEmojiButton()   = model.defaultEmoji when the draft is empty, else paperplane
 *       .accessibilityIdentifier("messagePanelSend")
 *
 *   menuContent() = the SEVEN media actions, each with its own identifier; the collaborative
 *   document entry only `if model.canWriteDocuments`.
 *
 * ONE control for the plus: the iOS dump splits a SwiftUI Menu into an outer PopUpButton and an
 * inner Button, and both are `messagePanelMoreActions`. A second "Add" button would be an
 * invented control.
 */

import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, all of them the source's own (MessagePanelView.swift:131-141) ───────── */
/** Swift `let padding: CGFloat = 10`. */
const PANEL_PADDING: number = 10;
/** Swift `let defaultControlSize: CGFloat = 42` — the plus, the pill and the send button. */
const CONTROL_SIZE: number = 42;
/** Swift `let paddingGorizontal: CGFloat = 20` — capture S0025 puts the plus at x=20. */
const PANEL_SIDE_PADDING: number = 20;
/** Swift `let textContainerLeadingInset: CGFloat = 14` — also the HStack's spacing. */
const TEXT_LEADING_INSET: number = 14;
/**
 * Swift `UITextViewWrapper`: `maxHeight: CGFloat = 100` (then the text view scrolls) and
 * `textContainerInset` top/bottom 12 (SwiftUIViews.swift:60-80).
 */
const TEXT_MAX_HEIGHT: number = 100;
const TEXT_VERTICAL_INSET: number = 12;
/** Swift `let sendIconSize: CGFloat = 25`. */
const SEND_ICON_SIZE: number = 25;
/** sys.symbol.paperplane turned to SF `paperplane`'s up-right heading. */
const PAPERPLANE_SF_ANGLE: number = 45;
/** Swift `Image(systemName: "plus").font(.system(size: 22, weight: .light))`. */
const PLUS_GLYPH_SIZE: number = 22;
const PLUS_GLYPH_WEIGHT: number = 300;
/** A menu-row tap sooner than this after the plus opened the menu is a double tap's second tap. */
const MENU_ROW_GUARD_MS: number = 500;
/** Swift `Text(model.defaultEmoji).font(.system(size: 26)).bold()`. */
const EMOJI_SIZE: number = 26;
/** Swift `cornerRadius = defaultControlSize / 2`. */
const CONTROL_RADIUS: number = CONTROL_SIZE / 2;
/** Swift the reply/edit top view: `.cornerRadius(10)`, its close button 40x40. */
const TOP_VIEW_RADIUS: number = 10;
const TOP_VIEW_CLOSE_SIZE: number = 40;
/** Swift `ReplyViewInMessagePanel`: `VStack(alignment: .leading, spacing: 6)`. */
const REPLY_LINE_GAP: number = 6;
/** Swift `EditMessagePanel`: `Spacer().frame(width: 5)` between "Editing" and the original. */
const EDIT_LABEL_GAP: number = 5;
/** Swift `.shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 1)`. */
const PANEL_SHADOW_RADIUS: number = 4;
const PANEL_SHADOW_COLOR: string = '#0D000000';
/** Capture S0028: the action sheet is ~250vp wide with ~53vp rows and a 24vp trailing glyph. */
const MENU_WIDTH: number = 250;
const MENU_ROW_HEIGHT: number = 52;
const MENU_GLYPH_SIZE: number = 24;

/** Swift `MessagePanelVM` — the panel's own state. */
@Observed
export class MessagePanelModel {
  /** Swift `model.placeholder` — "Write to <peer>". */
  placeholder: ResourceStr = $r('app.string.conversation_message_placeholder');
  /** Swift `model.defaultEmoji` — sent when the draft is empty. */
  defaultEmoji: string = '👍';
  /** Swift `model.messageToReply` — the quoted message's text; empty when not replying. */
  replyContent: string = '';
  /** Swift `model.inReplyTo` — the quoted message's author, "You" for our own. */
  inReplyTo: string = '';
  /** Swift `model.messageToEdit` / `model.isEdit`. */
  isEdit: boolean = false;
  /** Swift `model.avatarImage` — the account's own avatar, read back by the host screen. */
  accountAvatar: string = '';
}

@Component
export struct MessagePanelView {
  // Shared with the page, which updates it (placeholder, reply, edit) after the first build.
  @ObjectLink model: MessagePanelModel;
  /** Swift `@SwiftUI.State private var text` — the draft, owned by the host screen. */
  @Link text: string;
  /** conditionalVariants[actions_expanded] — the media action menu is open. */
  @Link isActionsExpanded: boolean;
  /** conditionalVariants[replying_or_editing] — a reply/edit top view is showing. */
  @Link @Watch('onReplyingOrEditingChange') isReplyingOrEditing: boolean;
  /**
   * Swift `MessagePanelVM.canWriteDocuments`, set from `conversation.isSwarm()`
   * (MessagesListVM.swift:226). @Prop, not a field on `model`: a plain class member is not
   * observed, so the host resolving its conversation after mount would never re-render the
   * menu and the collaborative-document row could never appear.
   */
  @Prop canWriteDocuments: boolean;
  /**
   * Swift `@Binding var isFocused` — `UITextViewWrapper`'s `textViewDidBeginEditing` /
   * `textViewDidEndEditing` set it and refresh the placeholder (SwiftUIViews.swift:152-159),
   * and the panel grows by `padding` at the bottom while it is true
   * (MessagePanelView.swift:273). The host owns no part of it, so it stays local.
   */
  @State private isFocused: boolean = false;

  /** Swift `model.sendMessage(text:)` then `cleanState()`. */
  onSend?: (text: string) => void;
  /** Swift `model.handleTyping(message:)` — drives the peer's typing indicator. */
  onTyping?: (text: string) => void;
  /** Swift `closeAction` on the reply/edit top view. */
  onCloseTopView?: () => void;
  /** Swift `model.recordAudio()`. */
  onRecordAudio?: () => void;
  /** Swift `model.recordVideo()`. */
  onRecordVideo?: () => void;
  /** Swift `model.shareLocation()`. */
  onShareLocation?: () => void;
  /** Swift `model.sendFile()`. */
  onSendFile?: () => void;
  /** Swift `model.openGalery()`. */
  onOpenGallery?: () => void;
  /** Swift `model.sendPhoto()`. */
  onSendPhoto?: () => void;
  /** Swift `model.newCollabDocument()`. */
  onNewCollabDocument?: () => void;

  private fire(handler?: () => void): void {
    this.isActionsExpanded = false;
    if (handler !== undefined) {
      handler();
    }
  }

  /** When the plus last opened the menu (ms). */
  private menuOpenedAt: number = 0;

  /**
   * A menu row. A row tapped within MENU_ROW_GUARD_MS of the menu opening is the second tap
   * of a fast double tap on the plus: with the keyboard up, the menu takes focus, the
   * keyboard drops and the menu re-anchors over the plus's old place, so that tap lands on a
   * row. It only closes the menu (TC-CHAT-023: the menu is shown or hidden, nothing opens).
   */
  private fireMenuRow(handler?: () => void): void {
    this.fire(Date.now() - this.menuOpenedAt < MENU_ROW_GUARD_MS ? undefined : handler);
  }

  /**
   * Swift `.onChange(of: model.isEdit) { isFocused = model.isEdit }`: `configureReplyTo` and
   * `configureEdit` both set `isEdit`, so a swipe-reply, a menu Reply and an Edit each focus
   * the field (cursor up, keyboard shown). The same line unfocuses it when `isEdit` goes false
   * (`cancelReply` / `cancelEdit`, i.e. the reply or edit was sent or closed), which drops the
   * keyboard.
   */
  private onReplyingOrEditingChange(): void {
    if (this.isReplyingOrEditing) {
      focusControl.requestFocus('messagePanelTextField');
    } else {
      this.getUIContext().getFocusController().clearFocus();
    }
  }

  private send(): void {
    const handler: ((text: string) => void) | undefined = this.onSend;
    if (handler !== undefined) {
      handler(this.text);
    }
  }

  private typing(value: string): void {
    this.text = value;
    const handler: ((text: string) => void) | undefined = this.onTyping;
    if (handler !== undefined) {
      handler(value);
    }
  }

  /**
   * Swift `menuContent()` — the seven media actions behind the plus.
   *
   * S5 — capture S0028/S0029: an iOS Menu anchored ABOVE its button renders its items in
   * REVERSE declaration order, so the sheet reads New document / Send photo / Open gallery /
   * Send file / Share my location / Record video / Record audio. HarmonyOS's `bindMenu` does
   * not reverse, so the rows are written in the order the capture shows them. Each row is
   * label-left, glyph-right on a light rounded card with hairline separators.
   */
  @Builder
  private menuContent() {
    Column() {
      // Swift `if model.canWriteDocuments` — the entry is absent, not disabled.
      if (this.canWriteDocuments) {
        Row() {
          Text($r('app.string.collab_new_document'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(MENU_GLYPH_SIZE)
            .fontColor([$r('app.color.label')])
        }
        .id('messagePanelNewCollabDocument')
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: MENU_ROW_HEIGHT })
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
          end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        })
        .border({
          width: { bottom: 0.5 },
          color: { bottom: $r('sys.color.comp_divider') }
        })
        .onClick(() => {
          this.fireMenuRow(this.onNewCollabDocument);
        })
      }

      Row() {
        Text($r('app.string.alerts_send_photo'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.camera_fill'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelSendPhoto')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onSendPhoto);
      })

      Row() {
        Text($r('app.string.alerts_upload_photo'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.ohos_photo'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelOpenGallery')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onOpenGallery);
      })

      Row() {
        Text($r('app.string.alerts_upload_file'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.doc'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelSendFile')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onSendFile);
      })

      Row() {
        Text($r('app.string.alerts_location_sharing'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.location_up_fill'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelShareLocation')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onShareLocation);
      })

      Row() {
        Text($r('app.string.alerts_record_video_message'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.camera_fill'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelRecordVideo')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onRecordVideo);
      })

      Row() {
        Text($r('app.string.alerts_record_audio_message'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.mic'))
          .fontSize(MENU_GLYPH_SIZE)
          .fontColor([$r('app.color.label')])
      }
      .id('messagePanelRecordAudio')
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: MENU_ROW_HEIGHT })
      .padding({
        start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
        end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      })
      .border({
        width: { bottom: 0.5 },
        color: { bottom: $r('sys.color.comp_divider') }
      })
      .onClick(() => {
        this.fireMenuRow(this.onRecordAudio);
      })

    }
    .width(MENU_WIDTH)
    // The plus disc's fill: comp_background_gray turns black in dark mode, iOS's menu is dark
    // grey there (T-1653).
    .backgroundColor($r('sys.color.ohos_id_color_panel_bg'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .clip(true)
  }

  build() {
    Column() {
      // Swift: the reply / edit top view, with the close button both share. `MessageTopBaseView`
      // — a 1pt rule, 10pt vertical padding, systemBackground, cornerRadius 10.
      if (this.isReplyingOrEditing) {
        Column() {
          Divider()
            .strokeWidth(1)
            .color($r('app.color.secondary_label'))
            .margin({
              start: LengthMetrics.vp(PANEL_PADDING * 0.5),
              end: LengthMetrics.vp(PANEL_PADDING * 0.5)
            })

          Row() {
            if (this.model.isEdit) {
              // Swift `EditMessagePanel`: "Editing" in `UIColor.systemBlue`, then the original
              // text on the same line in the secondary colour, both `.footnote`
              // (`model.styling.secondaryFont`); the original truncates in the middle.
              Text($r('app.string.global_editing'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_emphasize'))
                .flexShrink(0)
              Text(this.model.replyContent)
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('app.color.secondary_label'))
                .layoutWeight(1)
                .margin({ start: LengthMetrics.vp(EDIT_LABEL_GAP) })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .ellipsisMode(EllipsisMode.CENTER)
            } else {
              // Swift `ReplyViewInMessagePanel`: `Text(inReplyTo) + Text(" \(author)").bold()` in
              // the text colour, the quoted message under it in the secondary colour, both
              // `.footnote`, one line each; the quote truncates in the middle.
              Column({ space: REPLY_LINE_GAP }) {
                Text() {
                  Span($r('app.string.conversation_in_reply_to'))
                  Span(` ${this.model.inReplyTo}`)
                    .fontWeight(FontWeight.Bold)
                }
                .width('100%')
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('app.color.label'))
                .maxLines(1)
                // A bare Jami ID is one long word: without BREAK_ALL it wraps whole to the
                // hidden second line and the row reads "In reply to …" (iOS: "In reply to 45576f8a…").
                .wordBreak(WordBreak.BREAK_ALL)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.model.replyContent)
                  .width('100%')
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor($r('app.color.secondary_label'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .ellipsisMode(EllipsisMode.CENTER)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            Blank()
            SymbolGlyph($r('sys.symbol.xmark_circle'))
              .id('messagePanelCloseTopView')
              .fontSize(SEND_ICON_SIZE)
              .fontWeight(FontWeight.Lighter)
              .fontColor([$r('app.color.secondary_label')])
              .width(TOP_VIEW_CLOSE_SIZE)
              .height(TOP_VIEW_CLOSE_SIZE)
              .onClick(() => {
                this.fire(this.onCloseTopView);
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({
            start: LengthMetrics.vp(PANEL_PADDING),
            top: LengthMetrics.vp(PANEL_PADDING),
            bottom: LengthMetrics.vp(PANEL_PADDING)
          })
        }
        .width('100%')
        .backgroundColor($r('sys.color.background_primary'))
        .borderRadius(TOP_VIEW_RADIUS)
      }

      // Swift `HStack(alignment: .bottom, spacing: textContainerLeadingInset)`.
      Row({ space: TEXT_LEADING_INSET }) {
        // Swift `moreActionsButton()` — ONE control; the menu is its content. A 42pt circle
        // of ultra-thin material with a 22pt light plus in the secondary text colour.
        // `.light` is weight 300: FontWeight.Lighter drew a hairline that read as disabled.
        // The Stack centres the glyph: a SymbolGlyph sized 42vp draws it at its start edge.
        Stack() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(PLUS_GLYPH_SIZE)
            .fontWeight(PLUS_GLYPH_WEIGHT)
            .fontColor([$r('app.color.secondary_label')])
        }
        .id('messagePanelMoreActions')
        .accessibilityText($r('app.string.accessibility_conversation_share_media'))
        .width(CONTROL_SIZE)
        .height(CONTROL_SIZE)
        // Swift `VisualEffect(style: .systemUltraThinMaterial)`: over the chat it reads as
        // the same grey as the pill (sim: 245 on white, 31 on black). panel_bg is #F1F3F5 /
        // #202224; comp_background_gray went pure black in dark mode and vanished.
        .backgroundColor($r('sys.color.ohos_id_color_panel_bg'))
        .borderRadius(CONTROL_RADIUS)
        .clip(true)
        .shadow({ radius: PANEL_SHADOW_RADIUS, color: PANEL_SHADOW_COLOR, offsetX: 0, offsetY: 1 })
        .bindMenu(this.isActionsExpanded, this.menuContent(), {
          onDisappear: () => {
            this.isActionsExpanded = false;
          }
        })
        .onClick(() => {
          this.menuOpenedAt = Date.now();
          this.isActionsExpanded = true;
        })

        // Swift `messageTextField()` — the draft field and the send button share ONE pill of
        // `defaultControlSize / 2` radius; capture S0025 has it at `[76,773][373,818]`.
        Row() {
          // Swift `placeholderLabel` — a UILabel the coordinator ADDS to the text view
          // (SwiftUIViews.swift:111-122), not the field's own attribute. Kept a real node here
          // for the same reason: the capture renders it as its own StaticText. Swift
          // `placeholderLabel.isHidden = !textView.text.isEmpty` — it stays while the field is
          // focused and clears only once there is a draft. The TextArea is declared after it,
          // so the tap lands on the field.
          Stack({ alignContent: Alignment.Start }) {
            if (this.text.length === 0) {
              Text(this.model.placeholder)
                .width('100%')
                .maxLines(1)
                // A 40-character id is one "word"; without this it is pushed off the line.
                .wordBreak(WordBreak.BREAK_ALL)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize($r('sys.float.Body_L'))
                // Swift `placeholderLabel.textColor = .placeholderText` — UIKit's own value,
                // light and dark (T-1718).
                .fontColor($r('app.color.placeholder_text'))
                .padding({ start: LengthMetrics.vp(TEXT_LEADING_INSET) })
                .hitTestBehavior(HitTestMode.None)
            }

            // Swift `UITextViewWrapper` — a multi-line UITextView: Return inserts a newline, the
            // field grows with its lines up to 100pt, then scrolls. The pill and the send button
            // grow with it; the outer HStack keeps the plus at the bottom.
            TextArea({ text: this.text })
              .id('messagePanelTextField')
              .accessibilityText($r('app.string.accessibility_conversation_compose_message'))
              .width('100%')
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.label'))
              .enterKeyType(EnterKeyType.NEW_LINE)
              .constraintSize({ maxHeight: TEXT_MAX_HEIGHT })
              // Swift `leadingInset: textContainerLeadingInset`, `textContainerInset` 12 / 12.
              .padding({
                start: LengthMetrics.vp(TEXT_LEADING_INSET),
                end: LengthMetrics.vp(0),
                top: LengthMetrics.vp(TEXT_VERTICAL_INSET),
                bottom: LengthMetrics.vp(TEXT_VERTICAL_INSET)
              })
              .onChange((value: string) => {
                this.typing(value);
              })
              // Swift `textViewDidBeginEditing` / `textViewDidEndEditing`.
              .onFocus(() => {
                this.isFocused = true;
              })
              .onBlur(() => {
                this.isFocused = false;
              })
          }
          .layoutWeight(1)

          // Swift `sendEmojiButton()` — ONE control; the default emoji until there is a draft
          // to send, the paperplane once there is. The id lives on the tap target that wraps
          // both glyphs, so it stays unique in tree order (Rule 12).
          Row() {
            if (this.text.length === 0) {
              Text(this.model.defaultEmoji)
                .fontSize(EMOJI_SIZE)
                .fontWeight(FontWeight.Bold)
            } else {
              SymbolGlyph($r('sys.symbol.paperplane'))
                .fontSize(SEND_ICON_SIZE)
                .fontColor([$r('app.color.secondary_label')])
                // The HarmonyOS paperplane points straight up; SF `paperplane` points up-right.
                .rotate({ angle: PAPERPLANE_SF_ANGLE })
            }
          }
          .id('messagePanelSend')
          .width(CONTROL_SIZE)
          .height(CONTROL_SIZE)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.send();
          })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: CONTROL_SIZE })
        .backgroundColor($r('sys.color.ohos_id_color_panel_bg'))
        .borderRadius(CONTROL_RADIUS)
        .clip(true)
        .shadow({ radius: PANEL_SHADOW_RADIUS, color: PANEL_SHADOW_COLOR, offsetX: 0, offsetY: 1 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      // Swift `.padding(.top, padding)`.
      // Swift `.padding(.top, padding).padding(.bottom, isFocused ? padding : 0)`.
      .padding({
        top: LengthMetrics.vp(PANEL_PADDING),
        bottom: LengthMetrics.vp(this.isFocused ? PANEL_PADDING : 0)
      })
    }
    .width('100%')
    // Swift `.padding(.horizontal, paddingGorizontal)`.
    .padding({
      start: LengthMetrics.vp(PANEL_SIDE_PADDING),
      end: LengthMetrics.vp(PANEL_SIDE_PADDING)
    })
    .backgroundColor($r('sys.color.background_primary'))
  }
}
