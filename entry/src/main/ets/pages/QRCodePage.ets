/*
 * screen_qr_code_presenter — "QR Code", ported from
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift `struct QRCodePresenter` (line 113):
 *
 *     NavigationView {
 *       QRCodeView(jamiId: jamiId, accessibilityLabel: accessibilityLabel)
 *         .padding().padding(.top, 30)
 *         .navigationBarItems(leading: Button { isPresented = false } label: { Text(cancel) }
 *                               .accessibilityIdentifier("qrCodeClose"))
 *     }
 *     .accentColor(.jami)
 *     .onTapGesture { isPresented = false }
 *     .optionalMediumPresentationDetents()
 *
 * presentation: sheet, hostScreen: screen_account_summary. AccountSummaryView presents it with
 * `.sheet(isPresented: $showQRcode)`, so it is the content of a `.bindSheet()` mounted by
 * AccountSummarySettingsRootPage — NOT a routed page and NOT in main_pages.json. `isPresented`
 * stays the HOST's state, exactly as the Swift @Binding does.
 *
 * S3 builds the REAL tree: the leading Cancel bar item plus comp_qr_code_view (QRCodeView),
 * which is the screen's declared component and owns feat_qr_generate — the bitmap is generated
 * from the account's live jami id (@kit.ScanKit generateBarcode), never a bundled placeholder
 * and never a crop from the capture.
 *
 * ONE SOURCE BEHAVIOUR DELIBERATELY NOT BUILT: the NavigationView's `.onTapGesture` that
 * dismisses on a tap anywhere. The plan's controlInventory lists exactly one control here
 * ("Close"), so a tappable root would be an interactive node no contract covers; an ArkUI
 * sheet already dismisses on swipe-down. Reported to the orchestrator.
 *
 * S5/S6 style this tree against S0295, S0296.
 */
import { QRCodeView } from '../components/QrCodeView';
import { AccountModel } from '../model/AccountModel';
import { AccountsService } from '../common/AccountsService';
import { ServiceRegistry } from '../common/ServiceRegistry';

/** No account to draw a code for — the one failure this sheet can hit on its own. */
const ACCOUNT_UNAVAILABLE: string = 'no account';

/* ── S5 metrics ───────────────────────────────────────────────────────────────────────────
 * A plain (non-grouped) sheet on `systemBackground`, a leading bar item in the source's own
 * `.accentColor(.jami)`, and the code itself under the source's `.padding().padding(.top, 30)`.
 * The 30 and the bar height are the only numbers here; everything else is a design token.
 */
/** iOS navigation-bar height — a platform constant, not an app value. */
const BAR_HEIGHT: number = 44;
/** Swift `QRCodeView(...).padding().padding(.top, 30)` — the extra top inset, verbatim. */
const QR_TOP_PADDING: number = 30;

@Component
export struct QRCodeSheet {
  /** Swift `@Binding var isPresented: Bool` — owned by screen_account_summary. */
  @Link isPresented: boolean;
  /**
   * Swift `let jamiId: String` — bindingContract[QR image] -> AccountModel.jamiId. The host
   * seeds it (`QRCodePresenter(jamiId:)` is used for a contact's id too); when it presents
   * the sheet for the account itself and passes nothing, the id is read from svc_accounts,
   * never from a bundled placeholder.
   */
  @State qRImage: string = '';
  /** Swift `let accessibilityLabel: String`. */
  accessibilityLabel: Resource = $r('app.string.accessibility_account_summary_qr_code');
  /** True while svc_accounts is being read for the account's own jami id. */
  @State isLoading: boolean = false;
  /** Why no code could be generated; empty when there is nothing to report. */
  @State errorText: string = '';

  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  aboutToAppear(): void {
    if (this.qRImage.length > 0) {
      return;
    }
    this.isLoading = true;
    try {
      const service: AccountsService = ServiceRegistry.shared().accountService;
      let account: AccountModel | null = this.currentAccountId.length > 0
        ? service.getAccount(this.currentAccountId) : null;
      if (account === null) {
        account = service.currentAccount;
      }
      if (account === null) {
        this.errorText = ACCOUNT_UNAVAILABLE;
      } else {
        this.qRImage = account.jamiId;
      }
    } finally {
      this.isLoading = false;
    }
  }

  /** Swift: the leading bar button — `isPresented = false`. */
  private close(): void {
    this.isPresented = false;
  }

  build() {
    Column() {
      // Swift `.navigationBarItems(leading: Button { ... })` — leading, so the row is
      // left-aligned and everything else is pushed away by the Blank. A bar item has no
      // chrome of its own: `.accentColor(.jami)` on the NavigationView tints its label.
      Row() {
        Button($r('app.string.global_cancel'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .id('qrCodeClose')
          .onClick(() => {
            this.close();
          })
        Blank()
      }
      .width('100%')
      .height(BAR_HEIGHT)
      .alignItems(VerticalAlign.Center)

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }

      // comp_qr_code_view — the code itself, generated from the bound jami id. Swift
      // `.padding().padding(.top, 30)`: the 16 is the column's, the 30 is the code's own.
      QRCodeView({
        jamiId: this.qRImage,
        accessibilityLabel: this.accessibilityLabel
      })
        .margin({ top: QR_TOP_PADDING })
    }
    .width('100%')
    .height('100%')
    // Swift `QRCodeView(...).padding().padding(.top, 30)` — the code's own insets. The VStack
    // inside QRCodeView ends in a Spacer, so the square sits at the top of what is left.
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
    // A plain sheet, not a grouped one: `systemBackground`.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_qr_code_presenter')
  }
}
