/*
 * The chat's Send photo camera, ported from
 *   Ring/Ring/Features/Conversations/Conversation/ConversationViewController.swift `takePicture()`:
 *   UIImagePickerController, sourceType .camera, cameraDevice .rear, presented .overFullScreen.
 *
 * presentation: modal, hostScreen: screen_conversation, so it is a @CustomDialog mounted by
 * ConversationChatPage, NOT a routed page and NOT in main_pages.json.
 *
 * UIKit's picker drawn in-app (T-0755): the HarmonyOS system camera (cameraPicker) reviews a shot
 * with its own X / check buttons and no option relabels them. Live: the preview with Cancel, the
 * shutter and the camera switch. Shot: the photo with Retake and Use Photo, which hands the JPEG
 * to the host, and the host sends it as it sent the picker's result.
 *
 * The camera is svc_video's medium preview (the recorder's) plus a still output of the preview's
 * aspect. It goes on Cancel, Use Photo and Back (aboutToDisappear), and while the app is in the
 * background.
 */
import { abilityAccessCtrl, ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VideoPreviewLayer } from '../components/VideoPreviewLayer';
import { describeError } from '../common/ErrorText';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { VideoService } from '../common/VideoService';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'PhotoCapture';

/** The medium preview's 4:3, upright (RecordAudioVideoMessagePage's PREVIEW_ASPECT). */
const PREVIEW_ASPECT: number = 3 / 4;
/*
 * Read off the iPhone 11 reference (TC-CHAT-485-2, 414x896 pt): the shot is centred in the screen
 * at 3:4; the review bar is #131313, 72 pt over the home indicator, its two labels 18 pt white at
 * a 14 pt inset.
 */
const BAR_HEIGHT: number = 72;
const BAR_FILL: string = '#131313';
const LABEL_SIZE: number = 18;
const LABEL_INSET: number = 14;
const TOUCH_TARGET: number = 44;
/** UIKit's shutter: a white ring around a white disc. */
const SHUTTER_SIZE: number = 66;
const SHUTTER_RING: number = 4;
const SHUTTER_DISC: number = 54;
/** The camera switch, as the recorder draws it (T-1032), on UIKit's dark disc. */
const SWITCH_GLYPH_SIZE: number = 24;
const SWITCH_FILL: string = '#333333';
/** Each shot gets its own folder under cacheDir, so the review never shows a cached image. */
const SHOTS_DIR: string = 'photo-capture';
/** Swift `imageFileName = "IMG.jpeg"`, the name the chat sends it under. */
const SHOT_NAME: string = 'IMG.jpeg';

/** The camera follows the app: released in the background, back on return (Swift's session is interrupted). */
const CAMERA_FOLLOWS_APP: ApplicationStateChangeCallback = {
  onApplicationForeground(): void {
    ServiceRegistry.shared().videoService.startPreviewCapture();
  },
  onApplicationBackground(): void {
    ServiceRegistry.shared().videoService.stopPreviewCapture();
  }
};

@CustomDialog
export struct PhotoCaptureOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /** Swift `imagePickerController(_:didFinishPickingMediaWithInfo:)`: the JPEG's path. */
  onUsePhoto?: (path: string) => void;

  /** The shot under review; empty while the preview is live. */
  @State private shotPath: string = '';
  /** The camera grant was refused: ScanQRCodePage's refusal text, tap to ask again. */
  @State private isDenied: boolean = false;
  @State private isCapturing: boolean = false;
  @State private bottomInset: number = 0;
  @State private boxWidth: number = 0;
  @State private boxHeight: number = 0;
  private cameraStarted: boolean = false;
  private unsubscribeDenied: (() => void) | null = null;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.unsubscribeDenied = ServiceRegistry.shared().videoService.mediaPermissionDenied
      .subscribe((_denied: boolean): void => {
        this.isDenied = true;
      });
    context.getApplicationContext().on('applicationStateChange', CAMERA_FOLLOWS_APP);
    window.getLastWindow(context).then((win: window.Window): void => {
      this.bottomInset = px2vp(
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'window unavailable: %{public}d', error.code);
    });
  }

  /** Cancel, Use Photo and Back all end here: the camera, the listeners and the shots go. */
  aboutToDisappear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    try {
      context.getApplicationContext().off('applicationStateChange', CAMERA_FOLLOWS_APP);
      if (this.unsubscribeDenied !== null) {
        this.unsubscribeDenied();
      }
      // The host has already staged a used shot into the conversation (a synchronous copy).
      const shots: string = `${context.cacheDir}/${SHOTS_DIR}`;
      if (fs.accessSync(shots)) {
        fs.rmdirSync(shots);
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cleanup: %{public}s', describeError(error as BusinessError));
    } finally {
      const video: VideoService = ServiceRegistry.shared().videoService;
      video.setPreviewSurface(null);
      video.stopPhotoCamera();
    }
  }

  /** The recorder's previewAppeared: the surface, then the camera once. */
  private previewAppeared(surfaceId: string): void {
    const video: VideoService = ServiceRegistry.shared().videoService;
    video.setPreviewSurface(surfaceId);
    if (!this.cameraStarted) {
      this.cameraStarted = true;
      video.startPhotoCamera();
    }
  }

  /** Swift `.scaledToFit()` of the 3:4 frame, turned with the screen. */
  private fitBox(area: Area): void {
    const width: number = Number(area.width);
    const height: number = Number(area.height);
    if (width <= 0 || height <= 0) {
      return;
    }
    const aspect: number = width > height ? 1 / PREVIEW_ASPECT : PREVIEW_ASPECT;
    this.boxWidth = Math.min(width, height * aspect);
    this.boxHeight = this.boxWidth / aspect;
  }

  private shoot(): void {
    if (this.isCapturing || this.isDenied) {
      return;
    }
    this.isCapturing = true;
    const directory: string =
      `${getContext(this).cacheDir}/${SHOTS_DIR}/${Date.now()}`;
    const path: string = `${directory}/${SHOT_NAME}`;
    try {
      fs.mkdirSync(directory, true);
    } catch (error) {
      this.isCapturing = false;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no shot folder: %{public}s', describeError(error as BusinessError));
      return;
    }
    ServiceRegistry.shared().videoService.capturePhoto(path)
      .then((taken: boolean): void => {
        this.isCapturing = false;
        if (taken) {
          this.shotPath = path;
        }
      })
      .catch((error: BusinessError): void => {
        this.isCapturing = false;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'shot not saved: %{public}s', describeError(error));
      });
  }

  /**
   * ScanQRCodePage's refusal tap: ask again. Once the user has refused, requestPermissionsFromUser
   * no longer prompts, so the system's on-setting dialog asks (iOS sends the user to Settings).
   */
  private askAgain(): void {
    abilityAccessCtrl.createAtManager()
      .requestPermissionOnSetting(getContext(this), ['ohos.permission.CAMERA'])
      .then((statuses: Array<abilityAccessCtrl.GrantStatus>): void => {
        if (statuses[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          this.restartCamera();
        }
      })
      .catch((error: BusinessError): void => {
        // 12100011 granted meanwhile, 12100012 never refused: the ordinary request handles both.
        hilog.info(LOG_DOMAIN, LOG_TAG, 'on-setting request: %{public}s', describeError(error));
        this.restartCamera();
      });
  }

  private restartCamera(): void {
    this.isDenied = false;
    ServiceRegistry.shared().videoService.startPreviewCapture();
  }

  private usePhoto(): void {
    const use: ((path: string) => void) | undefined = this.onUsePhoto;
    if (use !== undefined) {
      use(this.shotPath);
    }
    this.dismiss();
  }

  private dismiss(): void {
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  @Builder
  private label(text: ResourceStr, id: string, action: () => void) {
    Text(text)
      .fontSize(LABEL_SIZE)
      .fontColor(Color.White)
      .constraintSize({ minHeight: TOUCH_TARGET })
      .padding({ start: LengthMetrics.vp(LABEL_INSET), end: LengthMetrics.vp(LABEL_INSET) })
      .id(id)
      .onClick(action)
  }

  /** Live: Cancel, the shutter, the camera switch. */
  @Builder
  private captureBar() {
    Stack() {
      Row() {
        this.label($r('app.string.global_cancel'), 'photo_capture_cancel', (): void => {
          this.dismiss();
        })
        Blank()
        Stack() {
          SymbolGlyph($r('sys.symbol.arrow_triangle_2_circlepath_camera'))
            .fontSize(SWITCH_GLYPH_SIZE)
            .fontColor([Color.White])
        }
        .width(TOUCH_TARGET)
        .height(TOUCH_TARGET)
        .borderRadius(TOUCH_TARGET / 2)
        .backgroundColor(SWITCH_FILL)
        .margin({ end: LengthMetrics.vp(LABEL_INSET) })
        .id('photo_capture_switch')
        .accessibilityText($r('app.string.accessibility_calls_default_switch_camera'))
        .onClick(() => {
          ServiceRegistry.shared().videoService.switchCamera();
        })
      }
      .width('100%')

      Stack() {
        Column()
          .width(SHUTTER_DISC)
          .height(SHUTTER_DISC)
          .borderRadius(SHUTTER_DISC / 2)
          .backgroundColor(Color.White)
      }
      .width(SHUTTER_SIZE)
      .height(SHUTTER_SIZE)
      .borderRadius(SHUTTER_SIZE / 2)
      .borderWidth(SHUTTER_RING)
      .borderColor(Color.White)
      .opacity(this.isCapturing ? 0.5 : 1)
      .id('photo_capture_shutter')
      .accessibilityText($r('app.string.alerts_profile_take_photo'))
      .onClick(() => {
        this.shoot();
      })
    }
    .width('100%')
    .height(BAR_HEIGHT)
  }

  /** Shot: Retake back to the preview, Use Photo to the chat. */
  @Builder
  private reviewBar() {
    Row() {
      this.label($r('app.string.photo_capture_retake'), 'photo_capture_retake',
        (): void => {
          this.shotPath = '';
        })
      Blank()
      this.label($r('app.string.photo_capture_use_photo'), 'photo_capture_use',
        (): void => {
          this.usePhoto();
        })
    }
    .width('100%')
    .height(BAR_HEIGHT)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Stack() {
          // Mounted throughout, so Retake is the live preview again at once.
          VideoPreviewLayer({
            onSurfaceReady: (surfaceId: string): void => {
              this.previewAppeared(surfaceId);
            },
            onSurfaceReleased: (): void => {
              ServiceRegistry.shared().videoService.setPreviewSurface(null);
            }
          })
          if (this.shotPath.length > 0) {
            Image('file://' + this.shotPath)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              // A rotation carried as EXIF is applied, as in MessageBubble (aab6869).
              .orientation(ImageRotateOrientation.AUTO)
              .backgroundColor(Color.Black)
          }
          if (this.isDenied) {
            Text($r('app.string.perm_reason_camera'))
              .id('photo_capture_permission_denied')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_M'))
              .fontColor(Color.White)
              .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
              .onClick(() => {
                this.askAgain();
              })
          }
        }
        .width(this.boxWidth)
        .height(this.boxHeight)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      Column() {
        if (this.shotPath.length > 0) {
          this.reviewBar()
        } else {
          this.captureBar()
        }
      }
      .width('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(this.shotPath.length > 0 ? BAR_FILL : Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .onAreaChange((_old: Area, area: Area): void => {
      this.fitBox(area);
    })
    .id('screen_photo_capture')
  }
}
