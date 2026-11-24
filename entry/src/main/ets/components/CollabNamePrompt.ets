/*
 * comp_collab_name_prompt — ported from
 *   Ring/Ring/Features/Collab/CollabDocumentsView.swift `struct CollabNamePrompt` (line 262)
 *   and its one caller `struct CollabNewDocumentPrompt` (line 238):
 *
 *     CustomAlert(content: {
 *         VStack(spacing: 20) {
 *             Text(title).font(.headline)
 *             TextField(L10n.Collab.documentNameHint, text: $name)
 *                 .accessibilityIdentifier("collab_name_prompt_field")
 *             HStack {
 *                 Button(onCancel)  { Text(L10n.Global.cancel) }  "collab_name_prompt_cancel"
 *                 Spacer()
 *                 Button(onConfirm) { Text(confirm).bold() }      "collab_name_prompt_confirm"
 *             }
 *         }
 *     })
 *
 * `name` is a @Link, exactly as Swift binds `$viewModel.pendingName`: the prompt edits the
 * caller's value, it does not hold a copy of it.
 */

/** Swift `Layout.spacing` / `.buttonWidth` / `.buttonHeight`. */
const PROMPT_GAP: number = 20;
const BUTTON_MIN_WIDTH: number = 60;
const BUTTON_MIN_HEIGHT: number = 44;

/* ── S5 (NO CAPTURE — the source's own, UtilitiesViews.swift:140 `CustomAlert`) ────────
 *   content.padding().background(Color(UIColor.secondarySystemBackground))
 *          .cornerRadius(12).padding().shadow(radius: 10)
 * The scrim half of `CustomAlert` lives at the CALL SITE, not here: the CustomDialogController
 * that raises this prompt carries the `Color.black.opacity(0.5)` dimming. This component is
 * the card.
 */
/** Swift the inner and outer `.padding()` — SwiftUI's default 16 pt. */
const ALERT_PADDING: number = 16;
/** Swift `.cornerRadius(12)`. */
const ALERT_RADIUS: number = 12;
/** Swift `.shadow(radius: 10)`. */
const ALERT_SHADOW_RADIUS: number = 10;
/** SwiftUI's default shadow colour at `.shadow(radius:)` — black at one third. */
const ALERT_SHADOW_COLOR: string = '#55000000';
/** `RoundedBorderTextFieldStyle()` — UIKit's bordered field: hairline, ~6 pt radius. */
const FIELD_RADIUS: number = 6;
const FIELD_BORDER_WIDTH: number = 0.5;

/** UIAlertController's actions take the default tint (systemBlue) on the iPhone 4.20. */
const SYSTEM_BLUE: string = '#007AFF';

/*
 * UIAlertController with one text field, measured on the iPhone 4.20 capture (TC-CHAT-095-2):
 * a 270 pt card, corner 14, title 19 pt from the top, a 30 pt field inset 16 pt, then a
 * hairline and two 44 pt actions split by a hairline, Cancel bold on the left.
 */
const SYSTEM_ALERT_WIDTH: number = 270;
const SYSTEM_ALERT_RADIUS: number = 14;
const SYSTEM_ALERT_TOP: number = 19;
const SYSTEM_ALERT_FIELD_GAP: number = 19;
const SYSTEM_ALERT_FIELD_BOTTOM: number = 13;
const SYSTEM_ALERT_FIELD_HEIGHT: number = 30;
/** UIAlertController's text field font — 13 pt. */
const SYSTEM_ALERT_FIELD_FONT: number = 13;
const SYSTEM_ALERT_ACTION_HEIGHT: number = 44;
const HAIRLINE: number = 0.5;

@Component
export struct CollabNamePrompt {
  /** Swift `let title: String` — L10n.Collab.newDocument at the one call site. */
  title: ResourceStr = '';
  /** Swift `let confirm: String` — L10n.Collab.create. */
  confirmTitle: ResourceStr = '';
  /** Swift `@Binding var name: String` — the caller's `viewModel.pendingName`. */
  @Link name: string;
  /** Swift `let onCancel: () -> Void` — `viewModel.isNaming = false`. */
  onCancel?: () => void;
  /** Swift `let onConfirm: () -> Void` — `viewModel.create(named:)` then openDocument. */
  onConfirm?: () => void;
  /**
   * Drawn as a UIAlertController (the chat's New document, the editor's Rename) rather than
   * SwiftUI's CustomAlert: see `systemAlertCard()`.
   */
  systemAlert: boolean = false;

  private fire(handler?: () => void): void {
    if (handler !== undefined) {
      handler();
    }
  }

  /**
   * UIAlertController's own look (T-0997): the field focused as it appears, the two actions
   * side by side under hairlines, the `.cancel` one bold and the confirm regular.
   */
  @Builder
  private systemAlertCard() {
    Column() {
      Text(this.title)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(600)
        .fontColor($r('app.color.label'))
        .padding({ left: ALERT_PADDING, right: ALERT_PADDING })

      TextInput({
        placeholder: $r('app.string.collab_document_name_hint'),
        text: this.name
      })
        .id('collab_name_prompt_field')
        .height(SYSTEM_ALERT_FIELD_HEIGHT)
        .fontSize(SYSTEM_ALERT_FIELD_FONT)
        .placeholderFont({ size: SYSTEM_ALERT_FIELD_FONT })
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .backgroundColor($r('sys.color.background_primary'))
        .borderRadius(FIELD_RADIUS)
        .borderWidth(FIELD_BORDER_WIDTH)
        .borderColor($r('sys.color.comp_divider'))
        .margin({
          left: ALERT_PADDING,
          right: ALERT_PADDING,
          top: SYSTEM_ALERT_FIELD_GAP,
          bottom: SYSTEM_ALERT_FIELD_BOTTOM
        })
        // UIAlertController focuses its text field as it appears.
        .defaultFocus(true)
        .onAppear((): void => {
          focusControl.requestFocus('collab_name_prompt_field');
        })
        .onChange((value: string) => {
          this.name = value;
        })

      Divider()
        .strokeWidth(HAIRLINE)
        .color($r('sys.color.comp_divider'))
      Row() {
        Button($r('app.string.global_cancel'))
          .id('collab_name_prompt_cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(600)
          .fontColor(SYSTEM_BLUE)
          .layoutWeight(1)
          .height('100%')
          .onClick(() => {
            this.fire(this.onCancel);
          })
        Divider()
          .vertical(true)
          .height('100%')
          .strokeWidth(HAIRLINE)
          .color($r('sys.color.comp_divider'))
        Button(this.confirmTitle)
          .id('collab_name_prompt_confirm')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Regular)
          .fontColor(SYSTEM_BLUE)
          .layoutWeight(1)
          .height('100%')
          .onClick(() => {
            this.fire(this.onConfirm);
          })
      }
      .width('100%')
      .height(SYSTEM_ALERT_ACTION_HEIGHT)
    }
    .width(SYSTEM_ALERT_WIDTH)
    .padding({ top: SYSTEM_ALERT_TOP })
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(SYSTEM_ALERT_RADIUS)
    .clip(true)
  }

  build() {
    if (this.systemAlert) {
      this.systemAlertCard()
    } else {
      this.customAlertCard()
    }
  }

  /** Swift `CollabNamePrompt` — SwiftUI's CustomAlert card. */
  @Builder
  private customAlertCard() {
    Column({ space: PROMPT_GAP }) {
      // Swift `.font(.headline)`, centred by the VStack.
      Text(this.title)
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(600)
        .fontColor($r('app.color.label'))

      // Swift `.padding(.horizontal)` — the field is inset from the card's own edges.
      Column() {
        TextInput({
          placeholder: $r('app.string.collab_document_name_hint'),
          text: this.name
        })
          .id('collab_name_prompt_field')
          // Swift `.textFieldStyle(RoundedBorderTextFieldStyle())`.
          .width('100%')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius(FIELD_RADIUS)
          .borderWidth(FIELD_BORDER_WIDTH)
          .borderColor($r('sys.color.comp_divider'))
          .onChange((value: string) => {
            this.name = value;
          })
      }
      .width('100%')
      .padding({ left: ALERT_PADDING, right: ALERT_PADDING })

      Row() {
        // Swift `Text(L10n.Global.cancel).foregroundColor(.jami)` — a bare tinted label.
        Button($r('app.string.global_cancel'))
          .id('collab_name_prompt_cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Regular)
          .fontColor($r('app.color.jami'))
          .constraintSize({ minWidth: BUTTON_MIN_WIDTH, minHeight: BUTTON_MIN_HEIGHT })
          .onClick(() => {
            this.fire(this.onCancel);
          })

        Blank()

        // Swift `Text(confirm).bold().foregroundColor(.jami)`.
        Button(this.confirmTitle)
          .id('collab_name_prompt_confirm')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.jami'))
          .constraintSize({ minWidth: BUTTON_MIN_WIDTH, minHeight: BUTTON_MIN_HEIGHT })
          .onClick(() => {
            this.fire(this.onConfirm);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // Swift `CustomAlert`'s card.
    .padding(ALERT_PADDING)
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius(ALERT_RADIUS)
    .shadow({ radius: ALERT_SHADOW_RADIUS, color: ALERT_SHADOW_COLOR })
  }
}
