/*
 * comp_qr_code_view — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct QRCodeView` (line 90):
 *
 *   let jamiId: String
 *   let accessibilityLabel: String
 *   var size: CGFloat = 270
 *   @SwiftUI.State var image: UIImage?
 *   VStack { if let image { Image(uiImage: image).resizable().aspectRatio(.fit)
 *              .frame(width: size, height: size).cornerRadius(10) }; Spacer() }
 *     .onAppear { image = jamiId.generateQRCode() }
 *
 * feat_qr_generate: CoreImage `generateQRCode()` -> @kit.ScanKit
 * `generateBarcode.createBarcode` (verified in the local SDK at
 * hms/ets/api/@hms.core.scan.generateBarcode.d.ts). The bitmap is BOUND, never a bundled
 * placeholder: the code encodes the caller's live value.
 *
 * The source generates synchronously in `.onAppear`, so it only ever has the filled case;
 * `createBarcode` is a promise, so the empty and failed cases are real here and occupy the
 * same square rather than resizing the screen under the user.
 *
 * ArkTS rule 8: the PixelMap is released in aboutToDisappear's `finally`.
 */
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describeError } from '../common/ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'QRCodeView';

/** Swift `var size: CGFloat = 270` and the hardcoded `.cornerRadius(10)` beside it. */
const QR_CODE_SIZE: number = 270;
const QR_CODE_RADIUS: number = 10;
/* ── S5 ─────────────────────────────────────────────────────────────────────────── */
/** The spinner inside the placeholder square, at the platform's own indicator size. */
const QR_SPINNER_SIZE: number = 32;
/**
 * The first createBarcode of a freshly started app can fail while ScanKit's service is still
 * coming up, and the code then never showed (T-0431): one retry after this pause.
 */
const QR_RETRY_DELAY_MS: number = 500;

@Component
export struct QRCodeView {
  /** Swift `let jamiId: String` — the value the code encodes (the export token here). */
  @Prop @Watch('onJamiIdChanged') jamiId: string = '';
  /** Swift `let accessibilityLabel: String`. */
  accessibilityLabel: Resource = $r('app.string.accessibility_account_summary_qr_code');
  /** Swift `var size: CGFloat = 270` — LinkToAccountView passes 200. */
  @Prop qrSize: number = QR_CODE_SIZE;
  /** Swift `@SwiftUI.State var image: UIImage?` — filled in `.onAppear`. */
  @State qrImage: image.PixelMap | undefined = undefined;
  /** Empty unless the generator failed. */
  @State qrErrorText: string = '';
  /** Set on the way out: a bitmap or a retry that lands later has nowhere to go. */
  private isGone: boolean = false;

  aboutToAppear(): void {
    this.generate();
  }

  aboutToDisappear(): void {
    this.isGone = true;
    this.release();
  }

  /** The token arrives asynchronously from the daemon, so the code is re-made when it does. */
  private onJamiIdChanged(_propName: string): void {
    this.release();
    this.generate();
  }

  private release(): void {
    const current: image.PixelMap | undefined = this.qrImage;
    try {
      if (current !== undefined) {
        current.release();
      }
    } catch (error) {
      console.error(`QRCodeView.release failed: ${describeError(error as BusinessError)}`);
    } finally {
      this.qrImage = undefined;
    }
  }

  /** Swift `image = jamiId.generateQRCode()`. */
  private generate(retries: number = 1): void {
    if (this.jamiId.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'no id to encode yet');
      return;
    }
    const options: generateBarcode.CreateOptions = {
      scanType: scanCore.ScanType.QR_CODE,
      height: this.qrSize,
      width: this.qrSize
    };
    generateBarcode.createBarcode(this.jamiId, options)
      .then((pixelMap: image.PixelMap): void => {
        if (this.isGone) {
          pixelMap.release();
          return;
        }
        this.qrImage = pixelMap;
        this.qrErrorText = '';
      })
      .catch((error: BusinessError): void => {
        const message: string = describeError(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'createBarcode failed, %{public}d retries left: %{public}s',
          retries, message);
        if (this.isGone) {
          return;
        }
        if (retries > 0) {
          setTimeout((): void => {
            this.generate(retries - 1);
          }, QR_RETRY_DELAY_MS);
          return;
        }
        this.qrErrorText = message;
      });
  }

  build() {
    // Swift `VStack { if let image { … }; Spacer() }`.
    Column() {
      if (this.qrImage !== undefined) {
        Image(this.qrImage)
          .id('qrCodeImage')
          .accessibilityText(this.accessibilityLabel)
          .width(this.qrSize)
          .height(this.qrSize)
          .objectFit(ImageFit.Contain)
          .borderRadius(QR_CODE_RADIUS)
      } else if (this.qrErrorText.length > 0) {
        Text(this.qrErrorText)
          .width(this.qrSize)
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
      } else {
        // Nothing to encode yet (no token) or the bitmap is still being made — the placeholder
        // keeps the code's square so the panel does not resize under the user.
        LoadingProgress()
          .width(QR_SPINNER_SIZE)
          .height(QR_SPINNER_SIZE)
          .color($r('app.color.jami'))
          .margin((this.qrSize - QR_SPINNER_SIZE) / 2)
      }
      Blank()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
