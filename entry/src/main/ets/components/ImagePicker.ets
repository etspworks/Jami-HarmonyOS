/*
 * comp_image_picker — ported from Ring/Ring/SwarmCreation/SwarmCreationUI.swift
 * `enum PhotoSheetType` (line 21) and `struct ImagePicker: UIViewControllerRepresentable`
 * (line 177):
 *
 *   ImagePicker(sourceType: .camera | .photoLibrary,
 *               showingType: $imagePickerType,   // set to nil to dismiss
 *               image: $model.avatar)            // the picked UIImage
 *
 *   Coordinator.imagePickerControllerDidCancel  -> showingType = nil
 *   Coordinator.didFinishPickingMediaWithInfo   -> image = info[.originalImage]; showingType = nil
 *
 * Like its source this struct has NO UI of its own: it wraps a system picker that the OS
 * presents over the caller. So it is mounted inside the caller's `if (isPickerOpen)` branch,
 * launches the system picker as it appears, and lowers `isPresented` on both outcomes —
 * which unmounts it, exactly as `showingType = nil` dismissed the represented controller.
 *
 * Capability mapping (Rule 10):
 *   .photoLibrary -> @ohos.file.picker PhotoViewPicker  (feat_photo_picker)
 *   .camera       -> @kit.CameraKit cameraPicker        (feat_camera_avatar)
 * Both are SYSTEM pickers; the gallery one needs no permission, but `cameraPicker` takes the
 * app's process down rather than erroring when `ohos.permission.CAMERA` is ungranted or the
 * device has no camera, so `takePhoto` proves both before it launches.
 *
 * The picked image is handed back BASE64-ENCODED rather than as a URI: the app's profile
 * layer (model/Profile.photo, the vCard PHOTO line) and `AvatarSwiftUIView.avatarData` both
 * carry base64, and Swift encodes at exactly this point too
 * (`image.convertToData(ofMaxSize:).base64EncodedString()`). A URI handed back instead would
 * be dangling the moment the picker's grant expires.
 */
import { camera, cameraPicker } from '@kit.CameraKit';
import { abilityAccessCtrl, bundleManager, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ImagePicker';

/** Swift `enum PhotoSheetType: Identifiable { case gallery; case picture }`. */
export enum PhotoSheetType {
  GALLERY = 'gallery',
  PICTURE = 'picture'
}

/**
 * Swift `image.convertToData(ofMaxSize: 40000).base64EncodedString()`. The source's size cap
 * belongs to the SAVE path (EditProfileVM.updateProfile), not to the picker, so nothing is
 * re-encoded here — the file is read as it was picked.
 */
function readAsBase64(uri: string): string {
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const size: number = fileIo.statSync(file.fd).size;
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const read: number = fileIo.readSync(file.fd, buffer);
    const bytes: Uint8Array = new Uint8Array(buffer.slice(0, read));
    return new util.Base64Helper().encodeToStringSync(bytes);
  } catch (error) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'could not read the picked image');
    return '';
  } finally {
    // ArkTS rule 8 — the descriptor goes whatever happened above.
    if (file !== null) {
      fileIo.closeSync(file);
    }
  }
}

@Component
export struct ImagePicker {
  /** Swift `var sourceType: UIImagePickerController.SourceType = .photoLibrary`. */
  sourceType: PhotoSheetType = PhotoSheetType.GALLERY;
  /** Swift `@Binding var image: UIImage?` — base64 here (see the header note). Empty = none. */
  @Link image: string;
  /** Swift `@Binding var showingType: PhotoSheetType?` — nil once the picker is done. */
  @Link isPresented: boolean;

  aboutToAppear(): void {
    if (this.sourceType === PhotoSheetType.PICTURE) {
      this.takePhoto();
    } else {
      this.openGallery();
    }
  }

  /**
   * The camera is unusable on this build/device unless BOTH hold: `ohos.permission.CAMERA` is
   * granted (requested here when it is not — Swift's `AVCaptureDevice.requestAccess(for: .video)`
   * ahead of presenting `.camera`) and the device reports at least one camera. Launching
   * `cameraPicker.pick` without either killed the app process rather than returning an error,
   * so this runs FIRST and nothing is picked when it says no.
   */
  private async isCameraUsable(context: common.Context): Promise<boolean> {
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const bundle: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let granted: abilityAccessCtrl.GrantStatus = await manager.checkAccessToken(
        bundle.appInfo.accessTokenId, 'ohos.permission.CAMERA');
      if (granted !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        const wanted: Permissions[] = ['ohos.permission.CAMERA'];
        const asked: PermissionRequestResult =
          await manager.requestPermissionsFromUser(context, wanted);
        const results: number[] = asked.authResults;
        granted = results.length > 0 && results[0] === 0
          ? abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
          : abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
      }
      if (granted !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return false;
      }
      return camera.getCameraManager(context).getSupportedCameras().length > 0;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera availability check failed');
      return false;
    }
  }

  /**
   * The same white "camera disabled" sentence `ScanQRCodeView` shows for a refused camera, as a
   * toast — this struct deliberately renders no view of its own (header note), so a silent
   * return would be the only other outcome.
   */
  private notifyCameraUnavailable(): void {
    promptAction.showToast({ message: $r('app.string.global_camera_disabled') });
  }

  /** Swift `sourceType == .camera` — `UIImagePickerController` in camera mode. */
  private async takePhoto(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    const usable: boolean = await this.isCameraUsable(context);
    if (!usable) {
      this.notifyCameraUnavailable();
      this.finish('');
      return;
    }
    const profile: cameraPicker.PickerProfile = {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_FRONT
    };
    try {
      // `pick` can throw SYNCHRONOUSLY (no camera ability to start), which took the whole
      // process down before the promise existed to reject — so the call itself is guarded as
      // well as the promise below.
      await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile)
        .then((result: cameraPicker.PickerResult): void => {
          // `resultCode` is 0 when a photo was taken and negative when the user backed out, so
          // a cancel hands back no uri and `finish` leaves the avatar alone — Swift's
          // `imagePickerControllerDidCancel` and `didFinishPickingMediaWithInfo` in one place.
          this.finish(result.resultCode === 0 ? result.resultUri : '');
        })
        .catch((error: Object): void => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'camera picker failed');
          this.notifyCameraUnavailable();
          // Swift `imagePickerControllerDidCancel`: showingType = nil, image untouched.
          this.finish('');
        });
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'camera picker could not be launched');
      this.notifyCameraUnavailable();
      this.finish('');
    }
  }

  /** Swift `sourceType == .photoLibrary`. */
  private openGallery(): void {
    const options: picker.PhotoSelectOptions = new picker.PhotoSelectOptions();
    options.maxSelectNumber = 1;
    new picker.PhotoViewPicker().select(options)
      .then((result: picker.PhotoSelectResult): void => {
        const uris: string[] = result.photoUris;
        this.finish(uris.length > 0 ? uris[0] : '');
      })
      .catch((error: Object): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'photo picker failed');
        this.finish('');
      });
  }

  /**
   * Both Coordinator callbacks end the same way: `showingType = nil`. Only the picking one
   * writes `image`, so an empty uri (cancel or failure) leaves the caller's avatar alone.
   */
  private finish(uri: string): void {
    if (uri.length > 0) {
      const encoded: string = readAsBase64(uri);
      if (encoded.length > 0) {
        this.image = encoded;
      }
    }
    this.isPresented = false;
  }

  build() {
    // `UIViewControllerRepresentable` contributes no view of its own — the system picker is
    // presented over the caller. The zero-size root keeps that true.
    Column()
      .width(0)
      .height(0)
      .id('edit_profile_image_picker')
  }
}
