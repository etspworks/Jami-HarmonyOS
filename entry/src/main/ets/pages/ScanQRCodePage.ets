/*
 * screen_scan_qr — "Scan QR Code", ported from
 *   Ring/Ring/QRCode/ScanViewController.storyboard
 *   Ring/Ring/QRCode/ScanViewController.swift
 *   Ring/Ring/QRCode/ScanViewModel.swift
 *   Ring/Ring/Features/Conversations/ConversationsCoordinator.swift
 *
 * presentation: modal, hostScreen: screen_smart_list. ConversationNavigation.openQRCode()
 * presents it with .present, so it is a @CustomDialog — NOT a routed page and NOT in
 * main_pages.json. It is mounted by SmartListConversationsHomePage (the deep link and the
 * menu) and by SmartListSearchResultsPage (the scanner affordance the source puts on the
 * in-place search results).
 *
 * The storyboard's scene, which is the S3 structure:
 *   view
 *     ├─ header view (alpha 0.6, black, full width, 85 tall)
 *     │    ├─ button  id="scan_close"  image="xmark" (system), 25x25, leading 14
 *     │    └─ label   centred — `searchTitle.text = L10n.Global.search` in viewDidLoad
 *     └─ imageView "scan" 250x250, centred  → comp_qr_scanner_overlay
 *   plus `videoPreviewLayer`, the AVCaptureVideoPreviewLayer added as the root's bottom sublayer.
 *
 * THE CAMERA IS REAL. `ohos.permission.CAMERA` is a normal user-grant permission and is
 * already declared in module.json5, so the preview is not faked: @kit.ScanKit's `customScan`
 * drives the session into an XComponent surface and hands back the decoded payload, which is
 * the same job AVCaptureMetadataOutput did. Both conditionalVariants are real branches:
 * `scanning` (session running) and `permission_denied` (authorisation refused, no preview).
 *
 * Swift `metadataOutput(_:didOutput:from:)` turns the payload into a JamiURI and calls
 * `onCodeScanned` -> `ScanViewModel.openConversation(jamiId:)` ->
 * `ConversationsCoordinator.openNewConversation(jamiId:)`, which PUSHES the conversation
 * (plan edge screen_scan_qr -> screen_conversation, kind: push). A payload that is not a jami
 * URI raises the source's `Scan.badQrCode` alert instead; its OK resumes the scan.
 *
 * S5 style, read off the storyboard verbatim (it hardcodes every value here):
 *   header  <view alpha="0.6"> + <color backgroundColor white="0.0"> , height 85
 *       -> Color.Black + HEADER_ALPHA on the header Stack (a UIView's alpha fades its
 *          subtree, which is why the title and the close glyph inherit it)
 *   label   fontDescription type="system" pointSize="20", textColor white
 *       -> fontSize(TITLE_FONT_SIZE = 20): a hardcoded non-standard size, copied verbatim
 *          rather than rounded to a Body_* token
 *   button  <color key="tintColor" white="1"> -> the xmark glyph is WHITE, not the
 *          semantic label colour, or it is black-on-black and invisible
 *   imageView "scan" alpha 0.7, tintColor white — the asset is already white-on-transparent
 *          (base/media/scan.png), so it needs no tint
 * The root is painted BLACK: it is the camera canvas, and on the permission-denied branch
 * there is no preview to cover it (arkts-and-arkui: never leave a surface unpainted).
 *
 * `isPresented` is owned by the host (screen_smart_list, and the in-place search results which
 * also raise the scanner): the CustomDialogController closes the dialog, the @Link is what puts
 * the host's own flag back to false, so a second tap re-opens it.
 */
import { display, LengthMetrics, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { customScan, scanBarcode, scanCore } from '@kit.ScanKit';
import { describeError } from '../common/ErrorText';
import { JamiUri } from '../common/JamiUri';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { QRCodeScannerOverlayView } from '../components/QrScannerOverlay';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ScanQRCodeOverlay';

/** Storyboard: the header strip is 85 tall, `alpha="0.6"`, over a black fill. */
const HEADER_HEIGHT: number = 85;
const HEADER_ALPHA: number = 0.6;
/** Storyboard: the close button is 25x25 with a leading inset of 14 and a top inset of 35. */
const CLOSE_SIZE: number = 25;
const CLOSE_LEADING: number = 14;
const HEADER_TOP_INSET: number = 35;
/** Storyboard `<fontDescription type="system" pointSize="20"/>` on `searchTitle`. */
const TITLE_FONT_SIZE: number = 20;
/** The scanner's chrome is white on the black canvas (storyboard `tintColor white="1"`). */
const SCANNER_FOREGROUND: string = '#FFFFFF';
/** A notice band under the 85 pt header, so it never sits behind the close button. */
const NOTICE_TOP: number = HEADER_HEIGHT + 24;
const NOTICE_SCRIM: string = '#99000000';
/** Swift `ScanViewController.invalidScanMinTime` (5 s) — at most one bad-code alert per window. */
const INVALID_SCAN_MIN_TIME_MS: number = 5000;

@CustomDialog
export struct ScanQRCodeOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /** Owned by the host; this overlay is mounted from the host's state. */
  @Link isPresented: boolean;

  /** bindingContract[camera preview] <- the running session (Swift AVCaptureVideoPreviewLayer). */
  @State cameraPreview: string = '';
  /** conditionalVariants[scanning] — Swift `captureSession.startRunning()` succeeded. */
  @State isScanning: boolean = false;
  /** conditionalVariants[permission_denied] — Swift: AVCaptureDevice authorisation refused. */
  @State isPermissionDenied: boolean = false;
  /** True between the permission prompt and the first frame. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** Swift `var scannedQrCode: Bool` — one payload is acted on, not every frame. */
  private scannedQrCode: boolean = false;
  /** Swift `var lastInvalidScanTime: Date?`, as epoch ms (0 = never). */
  private lastInvalidScanTime: number = 0;
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera permission check failed: %{public}s',
        this.errorText);
      return false;
    }
  }

  /**
   * Swift `viewDidLoad` builds `AVCaptureDeviceInput(device:)`, and iOS raises the camera
   * prompt itself on that first use: a fresh install asks once, then scans. Only reading the
   * grant left a new install on the refusal text, with no camera (T-0317). HarmonyOS shows its
   * prompt only while the user has not decided; after a refusal it answers at once.
   */
  private async askCameraPermission(): Promise<boolean> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const wanted: Array<Permissions> = ['ohos.permission.CAMERA'];
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(context, wanted);
      const results: Array<number> = result.authResults;
      return results.length > 0 && results[0] === 0;
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera permission request failed: %{public}s',
        this.errorText);
      return false;
    }
  }

  /** Swift `AVCaptureDevice.requestAccess(for: .video)` — the ask from the refusal state. */
  private async requestCameraPermission(): Promise<void> {
    if (await this.askCameraPermission()) {
      // The preview's XComponent comes back with this state and its onLoad starts the session;
      // starting here as well ran it on the old, detached surface and the camera stayed black.
      this.isPermissionDenied = false;
    }
  }

  /**
   * Swift `viewDidLoad` + `viewDidAppear`: build the session over the preview layer and start
   * it in the background. The callback form of `customScan.start` is what
   * `metadataOutput(_:didOutput:from:)` was: it fires again after every `customScan.rescan()`,
   * where the Promise form resolves once and leaves the scanner dead after a bad code.
   */
  private async startSession(): Promise<void> {
    if (this.sessionStarted) {
      return;
    }
    this.isLoading = true;
    const granted: boolean = await this.isCameraPermitted() || await this.askCameraPermission();
    if (!granted) {
      // conditionalVariants[permission_denied]: no preview at all, and the refusal is SAID.
      this.isPermissionDenied = true;
      this.isScanning = false;
      this.isLoading = false;
      return;
    }
    this.isPermissionDenied = false;
    const surfaceId: string = this.surfaceController.getXComponentSurfaceId();
    if (surfaceId.length === 0) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'preview surface not ready, camera not started');
      this.isLoading = false;
      return;
    }
    this.cameraPreview = surfaceId;
    // Swift `captureMetadataOutput.metadataObjectTypes = [.code128, .qr, .ean13, .ean8,
    // .code39, .upce, .aztec, .pdf417]`.
    const options: scanBarcode.ScanOptions = {
      scanTypes: [
        scanCore.ScanType.CODE128_CODE, scanCore.ScanType.QR_CODE,
        scanCore.ScanType.EAN13_CODE, scanCore.ScanType.EAN8_CODE,
        scanCore.ScanType.CODE39_CODE, scanCore.ScanType.UPC_E_CODE,
        scanCore.ScanType.AZTEC_CODE, scanCore.ScanType.PDF417_CODE
      ],
      enableMultiMode: false,
      enableAlbum: false
    };
    const screen: display.Display = display.getDefaultDisplaySync();
    const viewControl: customScan.ViewControl = {
      width: screen.width,
      height: screen.height,
      surfaceId: surfaceId
    };
    try {
      customScan.init(options);
      this.sessionStarted = true;
      this.isScanning = true;
      this.isLoading = false;
      customScan.start(viewControl,
        (error: BusinessError, results: Array<scanBarcode.ScanResult>): void => {
          if (error) {
            this.errorText = describeError(error);
            hilog.error(LOG_DOMAIN, LOG_TAG, 'scan failed: %{public}s', this.errorText);
            return;
          }
          this.onCodeScanned(results);
        });
    } catch (error) {
      this.isScanning = false;
      this.isLoading = false;
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'scan session failed: %{public}s', this.errorText);
    }
  }

  /** Swift `viewDidDisappear` — `captureSession?.stopRunning()`, plus the Kit's own release. */
  private stopSession(): void {
    if (!this.sessionStarted) {
      return;
    }
    try {
      customScan.stop((error: BusinessError): void => {
        if (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'stop failed: %{public}s', describeError(error));
        }
      });
    } finally {
      // CLAUDE.md rule 8 — the session's resources are released whatever stop() did.
      customScan.release((error: BusinessError): void => {
        if (error) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'release failed: %{public}s', describeError(error));
        }
      });
      this.sessionStarted = false;
      this.isScanning = false;
    }
  }

  /**
   * Swift `metadataOutput(_:didOutput:from:)`: the first payload only, turned into a JamiURI.
   * `isJami` + `hash` -> `onCodeScanned?(jamiId)`; anything else is the `Scan.badQrCode` alert.
   */
  private onCodeScanned(results: Array<scanBarcode.ScanResult>): void {
    if (this.scannedQrCode) {
      return;
    }
    if (results.length === 0) {
      this.rescan();
      return;
    }
    const payload: string = results[0].originalValue;
    const uri: JamiUri = JamiUri.parse(payload);
    const hash: string | null = uri.hash;
    if (!uri.isJami || hash === null || hash.length === 0) {
      // Swift: inside `invalidScanMinTime` of the last alert the code is ignored and the camera
      // keeps decoding; otherwise `UIAlertController(title: L10n.Scan.badQrCode)` with one OK.
      if (Date.now() - this.lastInvalidScanTime < INVALID_SCAN_MIN_TIME_MS) {
        this.rescan();
        return;
      }
      this.lastInvalidScanTime = Date.now();
      this.getUIContext().showAlertDialog({
        title: $r('app.string.scan_bad_qr_code'),
        message: '',
        autoCancel: false,
        // Back dismisses it too; either way the scanner stays up and scans again.
        cancel: () => {
          this.rescan();
        },
        confirm: {
          value: $r('app.string.global_ok'),
          action: () => {
            this.rescan();
          }
        }
      });
      return;
    }
    this.scannedQrCode = true;
    this.openConversation(hash);
  }

  /** `customScan.rescan()` — the Kit pauses after each result; this asks for the next one. */
  private rescan(): void {
    if (!this.sessionStarted) {
      return;
    }
    try {
      customScan.rescan();
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'rescan failed: %{public}s', this.errorText);
    }
  }

  /**
   * Swift `ScanViewModel.openConversation(jamiId:)` ->
   * `ConversationsCoordinator.openNewConversation(jamiId:)` — the plan's push edge
   * screen_scan_qr -> screen_conversation. The scanner closes first: the source dismissed the
   * presented controller before the coordinator pushed.
   */
  private openConversation(jamiId: string): void {
    this.stopSession();
    this.dismiss();
    const account: AccountModel | null = ServiceRegistry.shared().accountService.currentAccount;
    const accountId: string = account === null ? '' : account.id;
    router.pushUrl({
      url: 'pages/ConversationChatPage',
      params: { conversationKey: `${accountId}|${jamiId}` }
    }).catch((error: BusinessError): void => {
      this.errorText = describeError(error);
    });
  }

  /** Swift `@IBAction func closeScan(_:)` — `dismiss(animated: true)`. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  private closeScan(): void {
    this.stopSession();
    this.dismiss();
  }

  /** Storyboard: the translucent header carrying the close button and the centred title. */
  @Builder
  header() {
    Stack({ alignContent: Alignment.TopStart }) {
      // `searchTitle.text = L10n.Global.search` (viewDidLoad overrides the storyboard's text).
      Text($r('app.string.global_search'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize(TITLE_FONT_SIZE)
        .fontColor(SCANNER_FOREGROUND)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: HEADER_TOP_INSET })

      // Storyboard `<button id="Lyv-WP-6Gx" accessibility identifier="scan_close"
      // image="xmark" catalog="system"/>` with `closeScan:` on touchUpInside.
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(CLOSE_SIZE)
          // Storyboard `<color key="tintColor" white="1" alpha="1"/>`.
          .fontColor([SCANNER_FOREGROUND])
      }
      .id('scan_close')
      .width(CLOSE_SIZE)
      .height(CLOSE_SIZE)
      .backgroundColor(Color.Transparent)
      .margin({ start: LengthMetrics.vp(CLOSE_LEADING), top: LengthMetrics.vp(HEADER_TOP_INSET) })
      .accessibilityText($r('app.string.accessibility_close'))
      .onClick(() => {
        this.closeScan();
      })
    }
    .width('100%')
    // S6: the storyboard fixes the band at 85, but its content is TEXT and the project follows
    // the system font size - a hard .height() clips the title at a larger scale, so 85 is the
    // floor the band starts from (arkts-and-arkui S3, text scaling).
    .constraintSize({ minHeight: HEADER_HEIGHT })
    .backgroundColor(Color.Black)
    .opacity(HEADER_ALPHA)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Swift `view.layer.addSublayer(videoPreviewLayer!)` — the preview is the bottom layer.
      if (this.isPermissionDenied) {
        // conditionalVariants[permission_denied]: no preview. The refusal is stated, not blank.
        Column() {
          Text($r('app.string.perm_reason_camera'))
            .id('scan_permission_denied')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_M'))
            .fontColor(SCANNER_FOREGROUND)
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
            // Swift's refusal state offers the ask again, after the arrival's own ask.
            .onClick(() => {
              this.requestCameraPermission();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // conditionalVariants[scanning]: the live AVCaptureSession equivalent.
        XComponent({
          id: 'scanPreview',
          type: XComponentType.SURFACE,
          controller: this.surfaceController
        })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            this.startSession().catch((error: Object): void => {
              this.errorText = describeError(error as BusinessError);
            });
          })
      }

      // comp_qr_scanner_overlay — the storyboard's centred `scanImage` viewfinder.
      Column() {
        QRCodeScannerOverlayView()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)
      // conditionalVariants[scanning]: the viewfinder frame belongs over a RUNNING session —
      // before `customScan.start` there is no preview under it (Swift added the preview layer
      // and the frame together in viewDidAppear).
      .visibility(this.isScanning ? Visibility.Visible : Visibility.Hidden)

      // `view.bringSubviewToFront(header)` — the header sits over the preview.
      this.header()

      if (this.isLoading) {
        // Centred over the canvas like the viewfinder it replaces until the first frame.
        Column() {
          LoadingProgress()
            .width(CLOSE_SIZE)
            .height(CLOSE_SIZE)
            .color(SCANNER_FOREGROUND)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_S'))
          .fontColor(SCANNER_FOREGROUND)
          .backgroundColor(NOTICE_SCRIM)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          .margin({ top: NOTICE_TOP })
      }
    }
    .width('100%')
    .height('100%')
    // The camera canvas. The permission-denied branch has no preview to paint it.
    .backgroundColor(Color.Black)
    .id('screen_scan_qr')
  }
}
