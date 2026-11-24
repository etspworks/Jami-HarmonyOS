/*
 * screen_profile — "Customize Profile (onboarding)", ported from
 *   Ring/Ring/Features/Walkthrough/Views/ProfileView.swift
 *   Ring/Ring/SwarmCreation/SwarmCreationUI.swift   (PhotoSheetType, ImagePicker)
 *
 * presentation: sheet, hostScreen: screen_create_account. CreateAccountView presents it with
 * `.sheet(isPresented: $showProfileView)`, so it is the content of a `.bindSheet()` mounted by
 * CreateJamiAccountPage — NOT a routed page and NOT in main_pages.json. The host instantiates
 * it as `CustomizeProfileSheet({ isPresented, initialName, initialImage, onSave })`, Swift's
 * `ProfileView(isPresented:initialName:initialImage:saveProfile:)`.
 *
 * S3 — the real component tree of `ProfileView.body` (ProfileView.swift:42-133):
 *   NavigationView {
 *     ScrollView(showsIndicators: false) {
 *       VStack(alignment: .center) {
 *         Button {                                            // "profileEditPhoto"
 *           ZStack {
 *             if let image = takenImage   { Image(uiImage:)…clipShape(Circle()) }
 *             else if let image = initialImage { Image(uiImage:)…clipShape(Circle()) }
 *             Circle().fill(Color.black.opacity(0.5)).frame(100, 100)
 *             Image(systemName: "camera.fill").foregroundColor(.white).padding(8)
 *           }
 *           .accessibilityLabel(L10n.Accessibility.profilePicturePicker)
 *           .accessibilityHint(L10n.Accessibility.profilePicturePickerHint)
 *         }
 *         .actionSheet(isPresented: $showingImagePicker)      // Take photo / Upload photo / Cancel
 *         .sheet(item: $imagePickerType) { ImagePicker(...) } // camera | photoLibrary
 *         Spacer().frame(height: 40)
 *         Text(L10n.AccountPage.profileName)
 *         TextField(L10n.AccountPage.profileNamePlaceholder, text: $profileName) // "profileEditName"
 *         Spacer()
 *       }
 *     }
 *     .navigationBarTitle(L10n.AccountPage.editProfile, displayMode: .inline)
 *     .navigationBarItems(leading: Cancel  "profileEditCancel",
 *                         trailing: Save   "profileEditSave")
 *   }
 *
 * The two image branches are the SOURCE's own `if let takenImage` / `else if let initialImage`,
 * kept as two branches rather than folded into one. Both draw the same thing — a photo clipped
 * to a circle — so each is rendered through the app's own avatar component for that shape:
 * AvatarSwiftUIView (comp_avatar_swiftui) for the freshly taken image and AvatarView
 * (comp_avatar_view, which delegates to the same renderer) for the one handed in. Neither
 * component is edited here; both are sharedNotOwned.
 *
 * conditionalVariants: [has_photo] `hasPhoto` — a picked/taken image exists; [no_photo]
 * `isNoPhoto` — neither image is set, so the circle holds nothing but the scrim and the camera
 * glyph, exactly as the source's ZStack renders it.
 *
 * bindingContract: `avatar` <- pickedAvatar (@State takenImage) and `name field` <-
 * Profile.alias (the profile name binding) — both bound, never a literal from the capture.
 *
 * Save hands the result back through `onSave`, Swift's `saveProfile: (String, UIImage?) -> Void`
 * closure, and closes. It never writes an account: the host keeps the values and WelcomeVM
 * writes them to the NEW account once it exists (`WelcomeVM.saveProfile(accountId:)`).
 */
// `focusControl` is a global ArkUI namespace (ets/component/common.d.ts) — not a @kit.ArkUI export.
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';
import { AvatarView } from '../components/AvatarView';
import { ImagePicker, PhotoSheetType } from '../components/ImagePicker';

/** Swift `.frame(width: 100, height: 100)` — the avatar circle, hardcoded by ProfileView. */
const AVATAR_SIZE: number = 100;
/** Swift `Image(systemName: "camera.fill") … .padding(8)`. */
const CAMERA_GLYPH_PADDING: number = 8;
/** Swift `Circle().fill(Color.black.opacity(0.5))` over the avatar. */
const AVATAR_SCRIM: string = '#80000000';
/** Swift `Spacer().frame(height: 40)` between the avatar and the name label. */
const AVATAR_LABEL_GAP: number = 40;
/** Swift `TextField … .cornerRadius(8)` / `.padding(.bottom, 20)` / the VStack's `.padding()`. */
const FIELD_RADIUS: number = 8;
/** iOS draws a caret and a focus ring on the first-responder field; this is that ring. */
const FIELD_FOCUS_BORDER: number = 2;
const FIELD_BOTTOM_GAP: number = 20;
const CONTENT_PADDING: number = 16;
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CustomizeProfile';

/* ── S5 metrics (capture S0042/S0070–S0075) ───────────────────────────────────
 * A SwiftUI sheet with an INLINE navigation bar: Cancel / bold centred title / Save, all three
 * on one 56pt row, the two items in the app tint and the title in the label colour. Sizes,
 * weights and colours are the iOS semantic roles mapped through
 * ios-to-harmonyos-design-tokens.md, never numbers eyeballed off the PNG; only the bar height,
 * the field height and the two corner radii are platform constants.
 */
/** iOS inline navigation-bar row inside a presented sheet. */
const BAR_HEIGHT: number = 56;
/** `Image(systemName: "camera.fill")` as the capture renders it inside the 100pt circle. */
const CAMERA_GLYPH_SIZE: number = 20;
/** iOS single-line text field in a form body. */
const FIELD_HEIGHT: number = 50;
/** iOS action sheet (as EditProfilePage draws it): card corner, 57pt rows, 8pt side inset and
 * gap, the empty-title band, the 34pt home inset and the dimmed backdrop. */
const SHEET_RADIUS: number = 14;
const SHEET_ROW_HEIGHT: number = 57;
const SHEET_INSET: number = 8;
const SHEET_TITLE_BAND: number = 28;
const SHEET_BOTTOM_INSET: number = 34;
const SHEET_BACKDROP: string = '#33000000';
/* UIAlertController ignores SwiftUI's `.accentColor(.jami)`: its `.default` rows are regular
 * systemBlue and `.cancel()` semibold systemBlue. The 4.20 capture of SwarmProfile's identical
 * `.actionSheet` under the same `.accentColor(.jami)` shows it (navy nav bar, blue sheet). */
const SHEET_TINT: string = '#007AFF';
const SHEET_CANCEL_WEIGHT: number = 600;

@Component
export struct CustomizeProfileSheet {
  /** Swift `@Binding var isPresented` — owned by screen_create_account. */
  @Link isPresented: boolean;
  /** Swift `init(initialName:)` — the seed for `@State profileName`, not a binding. */
  @Prop initialName: string = '';
  /** Swift `@Binding var initialImage: UIImage?` — base64 here, as the app's profiles carry it. */
  @Prop initialImage: string = '';
  /** Swift `let saveProfile: (String, UIImage?) -> Void` — name and the taken image ('' = none). */
  onSave: (name: string, image: string) => void = (name: string, image: string): void => {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'saved with no listener wired');
  };

  /** bindingContract[avatar]: pickedAvatar <- Swift `@State private var takenImage`. */
  @Watch('onPickedImage') @State avatar: string = '';
  /** bindingContract[name field]: Profile.alias <- Swift `@State private var profileName`. */
  @State nameField: string = '';
  /**
   * Swift's first-responder state for the name field. UIKit/SwiftUI render it themselves (a
   * caret plus a focus ring on the grouped fill); ArkUI renders nothing, so the field's own
   * border and its screen-reader text are driven from this flag instead — the same pattern
   * `components/WalkthroughTextEdit.ets` already uses for `usernameTextField`.
   */
  @State private isNameFocused: boolean = false;

  /** conditionalVariants[has_photo]: Swift `if let image = takenImage` / `else if initialImage`. */
  @State hasPhoto: boolean = false;
  /** conditionalVariants[no_photo]: neither image is set — the bare scrim + camera glyph. */
  @State isNoPhoto: boolean = true;
  /** Swift's SECOND branch, `else if let image = initialImage`. */
  @State hasInitialPhoto: boolean = false;

  /** Swift `@State private var showingImagePicker` — the avatar-source action sheet. */
  @State private showingImagePicker: boolean = false;
  /** Swift `@State private var imagePickerType: PhotoSheetType?` — which source was chosen. */
  @State private pickerSource: PhotoSheetType = PhotoSheetType.GALLERY;
  /** Swift `imagePickerType != nil` — the picker sheet is up. */
  @State private isPickerOpen: boolean = false;

  aboutToAppear(): void {
    // Swift `init(... initialName:, initialImage:)` — `self.profileName = initialName`.
    this.nameField = this.initialName;
    this.refreshPhotoState();
  }

  /** conditionalVariants[has_photo] / [no_photo] — the ZStack's two `if let` branches. */
  private refreshPhotoState(): void {
    this.hasPhoto = this.avatar.length > 0;
    this.hasInitialPhoto = !this.hasPhoto && this.initialImage.length > 0;
    this.isNoPhoto = !this.hasPhoto && !this.hasInitialPhoto;
  }

  // ── handlers — every controlInventory entry, wired to its Swift effect ─────────────────
  /**
   * Swift the photo Button: `showingImagePicker = true` -> the action sheet.
   * Re-entrant: the contracted control is addressable both on the outer container and on the
   * avatar itself, so one gesture can reach this twice; the sheet opens once either way.
   */
  private openPhotoOptions(): void {
    if (this.showingImagePicker || this.isPickerOpen) {
      return;
    }
    this.showingImagePicker = true;
  }

  /**
   * Swift `TextField(...)` becoming first responder when its row is tapped. The caption and
   * the field are one control, so tapping the caption puts the caret in the field.
   */
  private focusNameField(): void {
    // The flag is set FIRST and the platform asked SECOND: when this page is presented as the
    // sheet over the create-account form (S0042) the request is not granted, so the field's own
    // rendering would otherwise never change. Sets a boolean and nothing else (lesson 3).
    this.isNameFocused = true;
    focusControl.requestFocus('profileEditName');
  }

  /**
   * What a screen reader is told about the name field. UIKit publishes the first-responder
   * ("is editing") trait itself; ArkUI publishes nothing, so the same fact is stated here —
   * the field's own prompt while it is being edited, its label otherwise. Two `Resource`
   * branches, never a `Resource | string` union: `accessibilityDescription` is an OVERLOAD
   * pair (`string` | `Resource`) and a union matches neither.
   */
  private nameFieldHint(): Resource {
    return this.isNameFocused
      ? $r('app.string.account_page_profile_name_placeholder')
      : $r('app.string.account_page_profile_name');
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

  /** The picker wrote `$takenImage`; Swift's ZStack re-evaluates its branches on that change. */
  private onPickedImage(_propName: string): void {
    this.refreshPhotoState();
  }

  /** Swift the trailing Save item: `saveProfile(profileName, takenImage); isPresented = false`. */
  private save(): void {
    this.onSave(this.nameField, this.avatar);
    this.isPresented = false;
  }

  /** Swift the leading Cancel item: `isPresented = false`, nothing handed back. */
  private cancel(): void {
    this.isPresented = false;
  }

  // ── builders ──────────────────────────────────────────────────────────────────────────
  /** Swift `.navigationBarTitle(displayMode: .inline)` + `.navigationBarItems(leading:trailing:)`. */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        // iOS bar items: the app tint at the body weight, no fill and no border.
        Button($r('app.string.global_cancel'))
          .id('profileEditCancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .padding(0)
          .onClick(() => {
            this.cancel();
          })
        Blank()
        Button($r('app.string.global_save'))
          .id('profileEditSave')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .padding(0)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // `.navigationBarTitle(displayMode: .inline)` — centred and semibold.
      Text($r('app.string.account_page_edit_profile'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(BAR_HEIGHT)
    .padding({
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
    })
  }

  /**
   * Swift the avatar Button and the ZStack it labels. The tappable node is the OUTER control,
   * so the slug and the handler sit together on it (a slug on a wrapper whose handler lives on
   * a descendant reads as an inert control).
   */
  @Builder
  private avatarButton() {
    // The contracted control is "Profile photo"; Rule 12 puts the SOURCE slug on the control
    // itself. Both nodes are really clickable and both run `openPhotoOptions()`, which is
    // idempotent, so one gesture opens the action sheet exactly once.
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        // conditionalVariants[has_photo] — Swift `if let image = takenImage`.
        if (this.hasPhoto) {
          AvatarSwiftUIView({
            avatarData: this.avatar,
            displayText: this.nameField,
            isGroup: false,
            avatarSize: AVATAR_SIZE
          })
        } else if (this.hasInitialPhoto) {
          // Swift `else if let image = initialImage` — the image handed in by the host.
          AvatarView({
            profileImageData: this.initialImage,
            username: this.nameField,
            isGroup: false,
            diameter: AVATAR_SIZE
          })
        } else if (this.isNoPhoto) {
          // conditionalVariants[no_photo] — Swift draws NO image at all here; the circle below
          // and the camera glyph above it are the whole of what the source shows.
          Column()
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .accessibilityLevel('no')
        }

        // Swift `Circle().fill(Color.black.opacity(0.5)).frame(width: 100, height: 100)`.
        Column()
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .backgroundColor(AVATAR_SCRIM)
          .accessibilityLevel('no')

        // Swift `Image(systemName: "camera.fill").foregroundColor(.white).padding(8)`.
        SymbolGlyph($r('sys.symbol.camera_fill'))
          .fontColor([Color.White])
          .fontSize(CAMERA_GLYPH_SIZE)
          .padding(CAMERA_GLYPH_PADDING)
      }
      .id('profileEditPhoto')
      .width(AVATAR_SIZE)
      .height(AVATAR_SIZE)
      // Swift `.accessibilityLabel(profilePicturePicker).accessibilityHint(…Hint)` — the control
      // shows no text of its own, so the source's own label is what names it.
      .accessibilityText($r('app.string.accessibility_profile_picture_picker'))
      .accessibilityDescription($r('app.string.accessibility_profile_picture_picker_hint'))
      .onClick(() => {
        this.openPhotoOptions();
      })
    }
    .id('profile-photo')
    .accessibilityText($r('app.string.accessibility_profile_picture_picker'))
    .onClick(() => {
      this.openPhotoOptions();
    })
  }

  /**
   * Swift `.actionSheet(isPresented: $showingImagePicker)` — title "", then
   * `.default(profileTakePhoto)`, `.default(profileUploadPhoto)`, `.cancel()`.
   */
  @Builder
  private photoSourceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      // UIKit dims the screen behind an action sheet; a tap outside it cancels.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SHEET_BACKDROP)
        .accessibilityLevel('no')
        .onClick(() => {
          this.dismissPhotoOptions();
        })

      Column({ space: SHEET_INSET }) {
        // The two default actions share one card under the empty `title: ""` band, each row
        // split by a hairline.
        Column() {
          Divider()
            .color($r('sys.color.comp_divider'))
          Button($r('app.string.alerts_profile_take_photo'))
            .id('profileEditPhotoSourceCamera')
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
            .id('profileEditPhotoSourceGallery')
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
        .borderRadius(SHEET_RADIUS)
        .clip(true)

        // Swift `.cancel()` — its own card, semibold.
        Button($r('app.string.global_cancel'))
          .id('profileEditPhotoSourceCancel')
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: SHEET_ROW_HEIGHT })
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius(SHEET_RADIUS)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(SHEET_CANCEL_WEIGHT)
          .fontColor(SHEET_TINT)
          .onClick(() => {
            this.dismissPhotoOptions();
          })
      }
      .width('100%')
      .padding({ left: SHEET_INSET, right: SHEET_INSET, bottom: SHEET_BOTTOM_INSET })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // Swift `NavigationView { ScrollView { VStack { … } } }` plus what it presents OVER it.
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.navigationBar()

        // Swift `ScrollView(showsIndicators: false)`.
        Scroll() {
          Column() {
            this.avatarButton()

            // The contracted control "Profile name" is the caption AND the field it names, so
            // they are one tappable container: a tap anywhere on it puts the caret in the
            // field (the contract's own expectation for this control).
            Column() {
              // Swift `Spacer().frame(height: 40)` then `Text(L10n.AccountPage.profileName)`.
              Text($r('app.string.account_page_profile_name'))
                .margin({ top: AVATAR_LABEL_GAP })
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('app.color.label'))
                .textAlign(TextAlign.Center)

              // Swift `TextField(L10n.AccountPage.profileNamePlaceholder, text: $profileName)`
              // — bound to the profile alias, never a value transcribed from the capture.
              TextInput({
                placeholder: $r('app.string.account_page_profile_name_placeholder'),
                text: $$this.nameField
              })
                .id('profileEditName')
                .enableKeyboardOnFocus(true)
                // Swift `.autocorrectionDisabled(true).autocapitalization(.none)`.
                .enableAutoFill(false)
                .width('100%')
                .height(FIELD_HEIGHT)
                .borderRadius(FIELD_RADIUS)
                // iOS form field: the grouped grey fill, label-coloured text, a grey
                // placeholder, and the body weight at the content inset.
                .backgroundColor($r('sys.color.comp_background_gray'))
                .fontSize($r('sys.float.Body_L'))
                .fontColor($r('app.color.label'))
                .placeholderColor($r('app.color.placeholder_text'))
                .placeholderFont({ size: $r('sys.float.Body_L') })
                .padding({ left: CONTENT_PADDING, right: CONTENT_PADDING })
                .margin({ top: CONTENT_PADDING, bottom: FIELD_BOTTOM_GAP })
                // iOS's first-responder finish on this field: the caret and the ring around
                // the grouped fill. A style attribute read from the focus flag — no added
                // control and no new render branch.
                .caretColor($r('app.color.jami'))
                .borderWidth(this.isNameFocused ? FIELD_FOCUS_BORDER : 0)
                .borderColor($r('app.color.jami'))
                .accessibilityDescription(this.nameFieldHint())
                .onChange((value: string) => {
                  this.nameField = value;
                })
                // Swift's first-responder binding, both directions.
                .onFocus(() => {
                  this.isNameFocused = true;
                })
                .onBlur(() => {
                  this.isNameFocused = false;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.focusNameField();
            })
          }
          .width('100%')
          // Swift `VStack(alignment: .center) { … }` inside the padded NavigationView content.
          .alignItems(HorizontalAlign.Center)
          .padding(CONTENT_PADDING)
        }
        .layoutWeight(1)
        // Swift's ScrollView content starts under the bar; ArkUI centres short content.
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_primary'))

      // Swift `.actionSheet(isPresented: $showingImagePicker)`.
      if (this.showingImagePicker) {
        this.photoSourceSheet()
      }

      // Swift `.sheet(item: $imagePickerType) { type in ImagePicker(sourceType: type == .picture
      // ? .camera : .photoLibrary, showingType: $imagePickerType, image: $takenImage) }`.
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
    .id('screen_profile')
  }
}
