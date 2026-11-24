/*
 * comp_qr_code_presenter_body — ported from
 * Ring/Ring/Features/Settings/Me/UtilitiesViews.swift `struct QRCodePresenter` (line 113):
 *
 *   NavigationView { QRCodeView(jamiId:) .navigationBarItems(leading: Button(cancel)) }
 *     .onTapGesture { isPresented = false }
 *
 * The sheet body AccountSummaryView presents behind its QR-code button: the code itself plus
 * the Cancel that closes it. `isPresented` stays the HOST's state, exactly as the Swift
 * @Binding does.
 *
 * S4 — feat_qr_generate. The source generates the bitmap in `.onAppear` through
 * `jamiId.generateQRCode()` (CoreImage CIQRCodeGenerator). The migrated target is
 * @kit.ScanKit `generateBarcode.createBarcode`, verified in the local SDK at
 * hms/ets/api/@hms.core.scan.generateBarcode.d.ts. The PixelMap is released in
 * aboutToDisappear's finally (ArkTS rule 8).
 */
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { describeError } from '../common/ErrorText';

/**
 * The square the source renders the code into: `QRCodeView.size` is a hardcoded 270, and its
 * `.cornerRadius(10)` is hardcoded beside it — both copied verbatim rather than tokenised.
 */
const QR_CODE_SIZE: number = 270;
const QR_CODE_RADIUS: number = 10;
/**
 * `Color.jamiFailure` from Ring/Ring/Extensions/UIColor+Ring.swift:99, verbatim — the app
 * carries no `app.color.jami_failure` resource, so it has no dark-mode variant.
 */
const JAMI_FAILURE: string = '#F00000';

@Component
export struct QRCodePresenter {
  /** Swift `@Binding var isPresented: Bool` — owned by the host screen. */
  @Link isPresented: boolean;
  /** Swift `let jamiId: String` — the uri the code encodes. */
  @Prop jamiId: string = '';
  /** Swift `let accessibilityLabel: String`. */
  accessibilityLabel: Resource = $r('app.string.accessibility_account_summary_qr_code');
  /** Swift `@SwiftUI.State var image: UIImage?` — filled in `.onAppear`. */
  @State qrImage: image.PixelMap | undefined = undefined;
  /** Empty unless the generator failed. */
  @State qrErrorText: string = '';

  aboutToAppear(): void {
    this.generate();
  }

  aboutToDisappear(): void {
    const current: image.PixelMap | undefined = this.qrImage;
    try {
      if (current !== undefined) {
        current.release();
      }
    } catch (error) {
      console.error(`QRCodePresenter.release failed: ${describeError(error as BusinessError)}`);
    } finally {
      this.qrImage = undefined;
    }
  }

  /** Swift `image = jamiId.generateQRCode()` in `QRCodeView.onAppear`. */
  private generate(): void {
    if (this.jamiId.length === 0) {
      return;
    }
    const options: generateBarcode.CreateOptions = {
      scanType: scanCore.ScanType.QR_CODE,
      height: QR_CODE_SIZE,
      width: QR_CODE_SIZE
    };
    generateBarcode.createBarcode(this.jamiId, options)
      .then((pixelMap: image.PixelMap): void => {
        this.qrImage = pixelMap;
        this.qrErrorText = '';
      })
      .catch((error: BusinessError): void => {
        this.qrErrorText = describeError(error);
        console.error(`QRCodePresenter.generate failed: ${this.qrErrorText}`);
      });
  }

  /** Swift: the leading `Button` and the sheet's own tap-to-dismiss. */
  private close(): void {
    this.isPresented = false;
  }

  build() {
    // S5 — style. Swift: `NavigationView { QRCodeView().padding().padding(.top, 30) }`
    // `.accentColor(.jami)` — a plain white sheet, the Cancel bar item tinted Jami navy, the
    // code centred under it.
    Column() {
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
      .height(44)
      .alignItems(VerticalAlign.Center)

      // Swift `QRCodeView`: `if let image = image { Image(uiImage: image) ... }`.
      //
      // S6 — the three states behind that `if`. On iOS the bitmap is produced synchronously
      // by CoreImage inside `.onAppear`, so the source only ever has the filled case and the
      // capture can only ever show it. `generateBarcode.createBarcode` is a PROMISE, so this
      // sheet really does open on an empty square, and it can really fail. All three states
      // occupy the SAME 270 x 270 box the code will land in, so the sheet does not resize
      // under the user as the bitmap arrives.
      if (this.qrImage !== undefined) {
        Image(this.qrImage)
          .accessibilityText(this.accessibilityLabel)
          .width(QR_CODE_SIZE)
          .height(QR_CODE_SIZE)
          .objectFit(ImageFit.Contain)
          .borderRadius(QR_CODE_RADIUS)
          .margin({ top: 30 })
      } else if (this.qrErrorText.length > 0) {
        Column() {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
            .fontSize(32)
            .fontColor([JAMI_FAILURE])
          Text(this.qrErrorText)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .textAlign(TextAlign.Center)
            .margin({ top: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
        }
        .width(QR_CODE_SIZE)
        .height(QR_CODE_SIZE)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(QR_CODE_RADIUS)
        .backgroundColor($r('sys.color.comp_background_gray'))
        .margin({ top: 30 })
      } else {
        // Generating — or, when the account has no id to encode, nothing to generate. Both
        // leave the same empty square, and neither is a failure to shout about.
        Column() {
          if (this.jamiId.length > 0) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('sys.color.font_secondary'))
          } else {
            SymbolGlyph($r('sys.symbol.qrcode'))
              .fontSize(48)
              .fontColor([$r('sys.color.font_tertiary')])
          }
        }
        .width(QR_CODE_SIZE)
        .height(QR_CODE_SIZE)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(QR_CODE_RADIUS)
        .backgroundColor($r('sys.color.comp_background_gray'))
        .margin({ top: 30 })
      }
      // Swift `QRCodeView` draws the code alone: no id under it.
      Blank()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
    .backgroundColor($r('sys.color.background_primary'))
  }
}
