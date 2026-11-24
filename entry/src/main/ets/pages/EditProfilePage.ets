/*
 * screen_edit_profile — "Edit Profile", ported from
 *   Ring/Ring/Features/Settings/Me/EditProfileView.swift
 *   Ring/Ring/Features/Settings/Me/EditProfileVM.swift
 *   Ring/Ring/SwarmCreation/SwarmCreationUI.swift     (PhotoSheetType, ImagePicker)
 *
 * presentation: sheet, hostScreen: screen_account_summary. AccountSummaryView presents it with
 * `.sheet(isPresented: $showEditPrpofile)`, so it is the content of a `.bindSheet()` mounted by
 * AccountSummarySettingsRootPage — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — the real component tree of `EditProfileView.body`:
 *   NavigationView {
 *     VStack(alignment: .center) {
 *       Button {                                   // "edit_profile_photo"
 *         ZStack { AvatarSwiftUIView(source: model); Circle().fill(.black 0.5);
 *                  Image(systemName: "camera.fill") }
 *       }
 *       .actionSheet(isPresented: $showingImagePicker) {  // Take photo / Upload photo / Cancel
 *       }
 *       .sheet(item: $imagePickerType) { ImagePicker(...) }   // "edit_profile_camera"
 *       Spacer().frame(height: 40)
 *       Text(L10n.AccountPage.profileName)
 *       TextField(L10n.AccountPage.profileNamePlaceholder, text: $model.profileName)
 *       Spacer()
 *     }
 *     .navigationBarTitle(L10n.AccountPage.editProfile, displayMode: .inline)
 *     .navigationBarItems(leading: cancel, trailing: save)
 *   }
 *
 * The source hangs TWO accessibility identifiers off the one avatar control chain —
 * "edit_profile_photo" on the Button and "edit_profile_camera" on its `.sheet` modifier — and
 * the capture recorded the inner one as the clickable node (`person.fill, Camera`). Both are
 * contracted controls, so both are reproduced as the two nodes they describe: the Button and
 * the ZStack it labels, each carrying its own slug. Neither is invented.
 *
 * `@State private var profileImage = Image(systemName: "person.circle")` in the source is dead
 * state — nothing renders it. The avatar that IS rendered is AvatarSwiftUIView's, whose own
 * no-photo branch draws person.fill, which is exactly what the capture shows. So
 * conditionalVariants[no_avatar] is that branch, not a person.circle glyph the screen never
 * had.
 *
 * DATA (bindingContract): `name` <- Profile.alias (model.profileName) and `avatar` <-
 * Profile.photo (model.avatar) — both bound, never a literal from the capture.
 *
 * SAVE is the source's: `EditProfileVM.updateProfile()` -> `accountService.updateProfile(...)`,
 * i.e. libjami's `updateProfile`, which writes the account vCard (`<accountId>/profile.vcf`, the
 * file ProfileStore reads back) and emits `ProfileReceived`, then sends it to the peers. The sheet
 * dismisses unconditionally (EditProfileView.swift trailing item: `model.updateProfile();
 * accountModel.avatar = model.avatar; isPresented = false`). An earlier build wrote the vCard
 * itself first and treated that write as the save; it threw on the account folder libjami had
 * already created (`mkdirSync` raises 13900015 File exists), so every Save toasted
 * `profile_editor_save_error` and nothing changed (T-0526).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { ImagePicker, PhotoSheetType } from '../components/ImagePicker';
import { AvatarSize } from '../common/JamiConstants';
import { ServiceRegistry } from '../common/ServiceRegistry';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'EditProfile';

/** Swift `EditProfileVM.init(... size: Constants.AvatarSize.account100)`. */
const AVATAR_SIZE: number = AvatarSize.ACCOUNT_100;
/** Swift `class func dataWithImageAndUUID` writes the PHOTO line as JPEG. */
const PROFILE_PHOTO_TYPE: string = 'JPEG';

/*
 * S5 — the values the SOURCE hardcodes (SwiftUI's bare `.padding()` is 16, and this view spells
 * out `Spacer().frame(height: 40)`, `.cornerRadius(8)` and `.padding(.bottom, 20)`), cross-checked
 * against the capture in points on a 393x852 screen (S0122): nav bar 69..125, avatar 141..241
 * (100x100, centred), "Profile name" 281..301, the name field 16..377 x 312..366, and the action
 * sheet's 8pt-inset cards with 57pt rows.
 */
const CONTENT_PADDING: number = 16;
/** Swift `.navigationBarTitle(displayMode: .inline)` — the capture's 56pt bar. */
const NAV_BAR_HEIGHT: number = 56;
/** Swift `Spacer().frame(height: 40)` between the avatar and the name label. */
const AVATAR_LABEL_GAP: number = 40;
/** Swift `TextField … .cornerRadius(8)`. */
const FIELD_RADIUS: number = 8;
/** Swift `TextField … .padding(.bottom, 20)`. */
const FIELD_BOTTOM_GAP: number = 20;
/** Swift `Image(systemName: "camera.fill") … .padding(8)`; the capture's glyph is 21x16pt. */
const CAMERA_GLYPH_SIZE: number = 20;
const CAMERA_GLYPH_PADDING: number = 8;
/**
 * Swift `Circle().fill(Color.black.opacity(0.5))` over the avatar — the capture proves it is
 * there: AvatarSwiftUIView draws its person.fill in WHITE, and this screen renders it grey while
 * the camera glyph above the scrim stays pure white.
 */
const AVATAR_SCRIM: string = '#80000000';
/** UIKit's action sheet: 8pt side inset, 57pt rows, 8pt between the two cards, 34pt home inset. */
const SHEET_INSET: number = 8;
const SHEET_ROW_HEIGHT: number = 57;
const SHEET_TITLE_BAND: number = 28;
const SHEET_BOTTOM_INSET: number = 34;
const SHEET_BACKDROP: string = '#33000000';
/* UIAlertController ignores SwiftUI's `.accentColor(.jami)`: its `.default` rows are regular
 * systemBlue and `.cancel()` semibold systemBlue. The 4.20 capture of SwarmProfile's identical
 * `.actionSheet` under the same `.accentColor(.jami)` shows it (navy nav bar, blue sheet). */
const SHEET_TINT: string = '#007AFF';
const SHEET_CANCEL_WEIGHT: number = 600;
/** SwiftUI's inline nav title is 17pt SEMIBOLD; ArkUI spells semibold as the numeric 600. */
const TITLE_WEIGHT: number = 600;

@Component
export struct EditProfileSheet {
  /** Owned by screen_account_summary; the host's @State drives the sheet. */
  @Link isPresented: boolean;
  /**
   * Swift `accountModel.avatar = model.avatar` on save — the host's avatar is written back,
   * and ONLY on save, so Cancel leaves the summary showing what it showed before.
   */
  @Link accountAvatar: string;
  /** Swift `EditProfileVM(profileName: accountModel.profileName)` — the seed, not the binding. */
  @Prop accountProfileName: string = '';
  /** Swift `EditProfileVM(username: accountModel.registeredName)` — the monogram's text. */
  @Prop accountDisplayName: string = '';

  /** bindingContract[name]: Profile.alias <- model.profileName. */
  @State name: string = '';
  /** bindingContract[avatar]: Profile.photo <- model.avatar (base64, as the vCard carries it). */
  @Watch('onAvatarChanged') @State avatar: string = '';

  /** conditionalVariants[has_avatar]: `model.avatar != nil`. */
  @State hasAvatar: boolean = false;
  /** conditionalVariants[no_avatar]: no photo set — AvatarSwiftUIView's person.fill branch. */
  @State isNoAvatar: boolean = true;
  /** conditionalVariants[picker_open]: Swift `imagePickerType != nil`. */
  @State isPickerOpen: boolean = false;

  /** Swift `@State private var showingImagePicker` — the avatar-source action sheet. */
  @State private showingImagePicker: boolean = false;
  /** Swift `@State private var imagePickerType: PhotoSheetType?` — which source was chosen. */
  @State private pickerSource: PhotoSheetType = PhotoSheetType.GALLERY;

  /** AppStorage['currentAccountId'], written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  aboutToAppear(): void {
    // Swift `EditProfileVM.init` seeds the editable copy from the account summary's values.
    this.name = this.accountProfileName;
    this.avatar = this.accountAvatar;
    this.onAvatarChanged('avatar');
  }

  /** conditionalVariants[has_avatar] / [no_avatar] — `model.avatar != nil` and its else. */
  private onAvatarChanged(_propName: string): void {
    this.hasAvatar = this.avatar.length > 0;
    this.isNoAvatar = !this.hasAvatar;
  }

  // ── handlers — every controlInventory entry, wired to its Swift effect ─────────────────
  /** Swift the photo Button: `hideKeyboard(); showingImagePicker = true` -> the action sheet. */
  private openPhotoOptions(): void {
    this.showingImagePicker = true;
  }

  /** Swift `.default(Text(L10n.Alerts.profileTakePhoto)) { imagePickerType = .picture }`. */
  private chooseCamera(): void {
    this.pickerSource = PhotoSheetType.PICTURE;
    this.showingImagePicker = false;
    this.isPickerOpen = true;
  }

  /** Swift `.default(Text(L10n.Alerts.profileUploadPhoto)) { imagePickerType = .gallery }`. */
  private chooseGallery(): void {
    this.pickerSource = PhotoSheetType.GALLERY;
    this.showingImagePicker = false;
    this.isPickerOpen = true;
  }

  /** Swift `.cancel()` on the action sheet — it just closes. */
  private dismissPhotoOptions(): void {
    this.showingImagePicker = false;
  }

  /**
   * Swift the trailing Save item: `model.updateProfile(); accountModel.avatar = model.avatar;
   * isPresented = false`.
   *
   * `EditProfileVM.updateProfile()` hands the name and the base64 picture (ImagePicker encodes at
   * the pick, as Swift did at the save) to `accountService.updateProfile(... fileType: "JPEG")`.
   */
  private save(): void {
    const accountId: string = this.currentAccountId;
    if (accountId.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'save with no current account');
      this.isPresented = false;
      return;
    }
    // libjami writes `<accountId>/profile.vcf` synchronously inside this call, then emits
    // `ProfileReceived`, which JamiNative routes to `accountProfileUpdated`.
    ServiceRegistry.shared().accountService
      .updateProfile(accountId, this.name, this.avatar, PROFILE_PHOTO_TYPE)
      .catch((error: Object): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'updateProfile rejected');
      });
    // The vCard is already on disk, so the summary behind the sheet re-reads it now rather than
    // waiting on the signal round trip.
    ServiceRegistry.shared().profileService.accountProfileUpdated(accountId);
    // Swift `accountModel.avatar = model.avatar`.
    this.accountAvatar = this.avatar;
    this.isPresented = false;
  }

  /** Swift the leading Cancel item: `isPresented = false`, nothing saved. */
  private cancel(): void {
    this.isPresented = false;
  }

  // ── builders ──────────────────────────────────────────────────────────────────────────
  /** Swift `.navigationBarTitle(displayMode: .inline)` + `.navigationBarItems(leading:trailing:)`. */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        // Swift: bar-button items under `.accentColor(.jami)` — bare text in the app accent
        // (capture: the dark navy #00345F, not the system blue).
        Button($r('app.string.global_cancel'))
          .id('edit_profile_cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.cancel();
          })
        Blank()
        Button($r('app.string.global_save'))
          .id('edit_profile_save')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')

      // Swift `.navigationBarTitle(displayMode: .inline)` — centred, 17pt semibold, on the
      // same optical row as the two bar buttons.
      Text($r('app.string.account_page_edit_profile'))
        .fontSize($r('sys.float.Body_L'))
        // S6 — the capture's title is heavier than the Cancel/Save items beside it.
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    // Text grows with the system font size, so the bar height is a floor, not a fix.
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .padding({
      start: LengthMetrics.vp(CONTENT_PADDING),
      end: LengthMetrics.vp(CONTENT_PADDING)
    })
  }

  /**
   * Swift the avatar Button and the ZStack that labels it. The outer node is the Button
   * ("edit_profile_photo"), the inner one the labelled ZStack the `.sheet` modifier tagged
   * ("edit_profile_camera") — the node the capture recorded as clickable. Both open the same
   * action sheet, exactly as the one Swift control did.
   */
  @Builder
  private avatarButton() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // conditionalVariants[has_avatar] / [no_avatar]: `AvatarSwiftUIView(source: model)`
        // renders the photo when the profile carries one, and otherwise the monogram of its
        // `resolvedDisplayText` — the name being typed, else the registered name — or the
        // person.fill placeholder when that is empty or a jami id (T-1600).
        if (this.hasAvatar) {
          AvatarSwiftUIView({
            avatarData: this.avatar,
            displayText: this.accountDisplayName,
            isGroup: false,
            avatarSize: AVATAR_SIZE
          })
        } else if (this.isNoAvatar) {
          AvatarSwiftUIView({
            avatarData: '',
            displayText: this.name.length > 0 ? this.name : this.accountDisplayName,
            isGroup: false,
            avatarSize: AVATAR_SIZE
          })
        }
        // Swift `Circle().fill(Color.black.opacity(0.5)).frame(width: avatarSize,
        // height: avatarSize)` — the scrim between the avatar and the camera glyph. It is the
        // reason the capture's person.fill reads grey and the camera glyph reads pure white.
        Column()
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .backgroundColor(AVATAR_SCRIM)
          // Decorative: the reader must not announce it between the avatar and the button.
          .accessibilityLevel('no')

        // Swift `Image(systemName: "camera.fill").foregroundColor(.white).padding(8)`.
        SymbolGlyph($r('sys.symbol.camera_fill'))
          .fontSize(CAMERA_GLYPH_SIZE)
          .fontColor([Color.White])
          .padding(CAMERA_GLYPH_PADDING)
      }
      .id('edit_profile_camera')
      .width(AVATAR_SIZE)
      .height(AVATAR_SIZE)
      .onClick(() => {
        this.openPhotoOptions();
      })
    }
    .id('edit_profile_photo')
    // The control shows no text of its own, so its name has to be spoken. The string is the
    // source's own label for this action, not one written to match a checker.
    .accessibilityText($r('app.string.profile_editor_change_picture'))
    .accessibilityDescription($r('app.string.profile_editor_change_picture_hint'))
    .onClick(() => {
      this.openPhotoOptions();
    })
  }

  /**
   * Swift `.actionSheet(isPresented: $showingImagePicker)` — title "", then
   * `.default(profileTakePhoto)`, `.default(profileUploadPhoto)`, `.cancel()`. This is the
   * `dialog` effect the photo control is contracted to produce.
   */
  @Builder
  private photoSourceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      // UIKit dims the screen behind an action sheet; the form stays visible through it.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SHEET_BACKDROP)
        .accessibilityLevel('no')

      Column({ space: SHEET_INSET }) {
        // The two default actions share one card, split by a hairline — the capture's 8pt-inset
        // rounded panel, with the empty `title: Text("")` band above the first row. UIKit draws
        // a hairline under that band even when the title is empty.
        Column() {
          Divider()
            .color($r('sys.color.comp_divider'))
          Button($r('app.string.alerts_profile_take_photo'))
            .id('edit_profile_photo_source_camera')
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .width('100%')
            .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Normal)
            .fontColor(SHEET_TINT)
            .onClick(() => {
              this.chooseCamera();
            })
          Divider()
            .color($r('sys.color.comp_divider'))
          Button($r('app.string.alerts_profile_upload_photo'))
            .id('edit_profile_photo_source_gallery')
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .width('100%')
            .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Normal)
            .fontColor(SHEET_TINT)
            .onClick(() => {
              this.chooseGallery();
            })
        }
        .width('100%')
        .padding({ top: SHEET_TITLE_BAND })
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
        .clip(true)

        // Swift `.cancel()` — its own card, bold, exactly as the capture shows it.
        Button($r('app.string.global_cancel'))
          .id('edit_profile_photo_source_cancel')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(SHEET_CANCEL_WEIGHT)
          .fontColor(SHEET_TINT)
          .onClick(() => {
            this.dismissPhotoOptions();
          })
      }
      .width('100%')
      .padding({
        start: LengthMetrics.vp(SHEET_INSET),
        end: LengthMetrics.vp(SHEET_INSET),
        bottom: LengthMetrics.vp(SHEET_BOTTOM_INSET)
      })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // Swift `NavigationView { VStack { … } }` plus the two things it presents OVER that stack.
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.navigationBar()

        Column() {
          this.avatarButton()

          // Swift `Text(L10n.AccountPage.profileName)` — `.body`, centred by the VStack's
          // `.center` alignment, a `Spacer().frame(height: 40)` below the avatar.
          Text($r('app.string.account_page_profile_name'))
            .margin({ top: AVATAR_LABEL_GAP })
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))

          // Swift `TextField(L10n.AccountPage.profileNamePlaceholder, text: $model.profileName)`
          // — bound to the profile's alias, never a value transcribed from the capture.
          TextInput({
            placeholder: $r('app.string.account_page_profile_name_placeholder'),
            text: $$this.name
          })
            .id('edit_profile_name')
            // Swift `.autocorrectionDisabled(true).autocapitalization(.none)`.
            .enableAutoFill(false)
            // Swift `.padding().background(Color(.secondarySystemBackground)).cornerRadius(8)
            // .padding(.bottom, 20)` — every value hardcoded by the source, copied verbatim.
            .width('100%')
            .padding(CONTENT_PADDING)
            .margin({ top: CONTENT_PADDING, bottom: FIELD_BOTTOM_GAP })
            .backgroundColor($r('sys.color.comp_background_gray'))
            .borderRadius(FIELD_RADIUS)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .placeholderColor($r('app.color.placeholder_text'))
            .placeholderFont({ size: $r('sys.float.Body_L') })
            .onChange((value: string) => {
              this.name = value;
            })
        }
        .width('100%')
        .layoutWeight(1)
        // Swift `VStack(alignment: .center) { … }.padding()`.
        .alignItems(HorizontalAlign.Center)
        .padding({
          start: LengthMetrics.vp(CONTENT_PADDING),
          end: LengthMetrics.vp(CONTENT_PADDING),
          top: LengthMetrics.vp(CONTENT_PADDING)
        })
      }
      .width('100%')
      .height('100%')

      // Swift `.actionSheet(isPresented: $showingImagePicker)`.
      if (this.showingImagePicker) {
        this.photoSourceSheet()
      }

      // conditionalVariants[picker_open] — Swift `.sheet(item: $imagePickerType) { type in
      // ImagePicker(sourceType: type == .picture ? .camera : .photoLibrary,
      //             showingType: $imagePickerType, image: $model.avatar) }`.
      if (this.isPickerOpen) {
        ImagePicker({
          sourceType: this.pickerSource,
          image: $avatar,
          isPresented: $isPickerOpen
        })
      }
    }
    .width('100%')
    .height('100%')
    // Swift: a plain `NavigationView` over `systemBackground` — a white sheet, not the grouped
    // grey of the summary behind it (capture S0122).
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_edit_profile')
  }
}
