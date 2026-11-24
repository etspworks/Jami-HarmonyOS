/*
 * comp_scan_qr_code_view — ported from Ring/Ring/Features/Walkthrough/Views/Views.swift
 * `struct ScanQRCodeView` (line 77):
 *
 *   ZStack {
 *     QRCodeScannerView(width: width, height: height, didFindCode: { onScan($0) })
 *       .frame(width: width, height: height)
 *       .cornerRadius(12)
 *     QRCodeScannerOverlayView(size: min(width, height) * 0.5)
 *       .frame(width: width, height: height)
 *   }
 *
 * `QRCodeScannerView` is the UIKit AVCaptureSession preview. Capability mapping (Rule 10):
 * `@kit.ScanKit`'s `customScan` drives the session into an XComponent surface and hands back
 * the decoded payload, which is what `metadataOutput(_:didOutput:from:)` delivered. The same
 * mapping the app already makes on its full-screen scanner (pages/ScanQRCodePage.ets); this is
 * the reusable panel-sized view the linking screens embed.
 *
 * The camera permission is asked for on first use, as iOS's `AVCaptureDeviceInput(device:)`
 * raises its own prompt (and as pages/ScanQRCodePage.ets does, T-0317). The refusal is SAID and
 * nothing else — `showCameraDisabledMessage(in:)` (Helpers/SwiftUIViews.swift:254) adds one
 * white, centred `L10n.Global.cameraDisabled` label to a black view and adds NO control, so
 * neither does this.
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { customScan, scanBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { describeError } from '../common/ErrorText';
import { QRCodeScannerOverlayView } from './QrScannerOverlay';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ScanQRCodeView';

/** Swift `ScanQRCodeView(width: 250, height: 200)` — the linking screens' own panel size. */
const DEFAULT_WIDTH: number = 250;
const DEFAULT_HEIGHT: number = 200;
/** Swift `.cornerRadius(12)` on the preview. */
const PREVIEW_RADIUS: number = 12;
/** Swift `QRCodeScannerOverlayView(size: min(width, height) * 0.5)`. */
const VIEWFINDER_RATIO: number = 0.5;
/** The in-panel spinner while the session comes up. */
const SPINNER_SIZE: number = 32;
/* ── S5 metrics (capture S0243 / S0250 / S0253) ───────────────────────────────────────────
 * The panel is the camera surface, so it reads BLACK whatever the page behind it is, and
 * everything drawn over it — the viewfinder brackets, the refusal, the spinner — is white on
 * that black. The one inset is the refusal's own, so its three lines do not run to the edge.
 */
const PANEL_TEXT_INSET: number = 16;

@Component
export struct ScanQRCodeView {
  /** Swift `let width: CGFloat`. */
  previewWidth: number = DEFAULT_WIDTH;
  /** Swift `let height: CGFloat`. */
  previewHeight: number = DEFAULT_HEIGHT;
  /** Swift `var onScan: (String) -> Void` — `didFindCode`'s payload, raw. */
  onScan: (code: string) => void = (code: string): void => {
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'no onScan supplied');
  };

  /**
   * bindingContract[camera] <- scanSessionActive: Swift's `captureSession.isRunning`. It is
   * the SESSION's state, never a literal — the panel shows a preview only once one is running.
   * A @Link so the hosting screen can render against the live session rather than a copy.
   */
  @Link isSessionActive: boolean;
  /** No camera permission: the preview is replaced by the refusal and the control that asks. */
  @State isPermissionDenied: boolean = false;
  /** Between the permission read and the first frame. */
  @State isStarting: boolean = false;
  /** describeError() output; empty when there is no failure. */
  @State errorText: string = '';

  private surfaceController: XComponentController = new XComponentController();
  private sessionStarted: boolean = false;

  aboutToDisappear(): void {
    this.stopSession();
  }

  /** Swift `AVCaptureDevice.authorizationStatus(for: .video)` — the current grant. */
  private async isCameraPermitted(): Promise<boolean> {
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const bundle: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const granted: abilityAccessCtrl.GrantStatus = await manager.checkAccessToken(
        bundle.appInfo.accessTokenId, 'ohos.permission.CAMERA');
      return granted === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera permission check failed');
      return false;
    }
  }

  /**
   * Swift `AVCaptureDeviceInput(device:)`: iOS raises the camera prompt on that first use, so a
   * fresh install asks once, then scans. Only reading the grant left a new install on the
   * refusal text (T-1609). HarmonyOS shows its prompt only while the user has not decided.
   */
  private async askCameraPermission(): Promise<boolean> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const wanted: Array<Permissions> = ['ohos.permission.CAMERA'];
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult = await manager.requestPermissionsFromUser(context, wanted);
      const results: Array<number> = result.authResults;
      return results.length > 0 && results[0] === 0;
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera permission request failed');
      return false;
    }
  }

  /** Swift `QRCodeScannerView` building its AVCaptureSession over the preview layer. */
  private async startSession(): Promise<void> {
    if (this.sessionStarted) {
      return;
    }
    this.isStarting = true;
    const granted: boolean = await this.isCameraPermitted() || await this.askCameraPermission();
    if (!granted) {
      this.isPermissionDenied = true;
      this.isSessionActive = false;
      this.isStarting = false;
      return;
    }
    this.isPermissionDenied = false;
    const surfaceId: string = this.surfaceController.getXComponentSurfaceId();
    if (surfaceId.length === 0) {
      this.isStarting = false;
      return;
    }
    // Swift `metadataObjectTypes = [.qr]` — this panel scans jami-auth QR codes only.
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: false
    };
    const viewControl: customScan.ViewControl = {
      width: this.previewWidth,
      height: this.previewHeight,
      surfaceId: surfaceId
    };
    try {
      customScan.init(options);
      this.sessionStarted = true;
      this.isSessionActive = true;
      this.isStarting = false;
      const results: Array<scanBarcode.ScanResult> = await customScan.start(viewControl);
      this.onCodeScanned(results);
    } catch (error) {
      this.isSessionActive = false;
      this.isStarting = false;
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'scan session failed');
    }
  }

  /** Swift `captureSession?.stopRunning()`, plus the Kit's own release. */
  private stopSession(): void {
    if (!this.sessionStarted) {
      return;
    }
    try {
      customScan.stop((error: BusinessError): void => {
        if (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'stop failed');
        }
      });
    } finally {
      // CLAUDE.md rule 8 — the session's resources go whatever stop() did.
      customScan.release((error: BusinessError): void => {
        if (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'release failed');
        }
      });
      this.sessionStarted = false;
      this.isSessionActive = false;
    }
  }

  /** Swift `didFindCode(scannedCode)` — the payload handed up, unparsed, exactly as Swift did. */
  private onCodeScanned(results: Array<scanBarcode.ScanResult>): void {
    if (results.length === 0) {
      return;
    }
    this.onScan(results[0].originalValue);
  }

  build() {
    // Swift `ZStack { QRCodeScannerView; QRCodeScannerOverlayView }`.
    Stack({ alignContent: Alignment.Center }) {
      XComponent({
        id: 'scanQrCodePreview',
        type: XComponentType.SURFACE,
        controller: this.surfaceController
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.startSession();
        })

      // Swift `QRCodeScannerOverlayView(size: min(width, height) * 0.5)`.
      QRCodeScannerOverlayView({
        sideLength: Math.min(this.previewWidth, this.previewHeight) * VIEWFINDER_RATIO
      })

      // No preview is possible without the camera: say so, and ONLY that. Swift
      // `showCameraDisabledMessage(in:)` (Helpers/SwiftUIViews.swift:254) adds a single white,
      // centred `L10n.Global.cameraDisabled` label to the black view and no control at all —
      // and the capture (S0243 / S0250) shows the same: the sentence and the segments, nothing
      // else. Any grant button here is a control the source does not have.
      if (this.isPermissionDenied) {
        Column({ space: PANEL_TEXT_INSET }) {
          Text($r('app.string.global_camera_disabled'))
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_L'))
            .fontColor(Color.White)
        }
        .width('100%')
        .padding(PANEL_TEXT_INSET)
      } else if (this.isStarting) {
        LoadingProgress()
          .id('scanQrCodeStarting')
          .width(SPINNER_SIZE)
          .height(SPINNER_SIZE)
          .color(Color.White)
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .id('scanQrCodeError')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_S'))
          .fontColor(Color.White)
          .padding(PANEL_TEXT_INSET)
      }
    }
    .width(this.previewWidth)
    .height(this.previewHeight)
    // The camera surface reads black behind everything drawn over it, in every state.
    .backgroundColor(Color.Black)
    // Swift `.cornerRadius(12)` on the preview.
    .borderRadius(PREVIEW_RADIUS)
    .clip(true)
  }
}
