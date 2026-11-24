/*
 * screen_swarm_profile — "Swarm Profile (name, description, picture)", ported from
 *   Ring/Ring/SwarmCreation/SwarmProfile.swift         (struct SwarmProfile :23-149)
 *   Ring/Ring/SwarmCreation/SwarmCreationUIModel.swift (the draft the sheet edits)
 *   Ring/Ring/Extensions/UITextField+Helpers.swift     (hideKeyboard)
 *
 * presentation: sheet, hostScreen: screen_swarm_creation_ui. SwarmCreationUI raises it from
 * its private `@State isPresentingProfile`, so this is the CONTENT of the `.bindSheet()`
 * pages/CreateSwarmParticipantsPage.ets mounts on its `swarm_creation_customize_profile`
 * control — NOT a routed page, and not registered in main_pages.json. navOut is empty.
 *
 * S3 — the real tree of `SwarmProfile.body`:
 *
 *   PlatformAdaptiveNavView { VStack { contentView() }
 *     .navigationTitle(L10n.Swarm.customizeProfile)
 *     .navigationBarItems(leading: leadingBarItems, trailing: trailingBarItems)
 *     .onTapGesture { self.hideKeyboard() } }
 *
 *   leadingBarItems  = Button(cancel) { model.setDataToInitial(); isPresentingProfile = false }
 *                        .accessibilityIdentifier("swarm_profile_cancel")
 *   trailingBarItems = Button(save)   { isPresentingProfile = false }
 *                        .accessibilityIdentifier("swarm_profile_save")
 *
 *   contentView = GeometryReader {
 *     Ellipse().fill(Color.jamiTertiaryControl)…            // decoration, no control
 *     HStack { Spacer
 *       VStack { imagePickerButton()                        // "swarm_profile_pick_image"
 *                VStack(alignment: .center) {
 *                  TextField(namePlaceholder, $model.swarmName)      // "swarm_profile_name"
 *                  TextField(addDescription, $model.swarmDescription)// "swarm_profile_description"
 *                }
 *                Spacer
 *                Text(L10n.Swarm.explanationText)
 *                Spacer; Spacer(height: 20) }
 *       Spacer } }
 *
 *   imagePickerButton = Button { EditImageIcon(model:, width: 100, height: 100) }
 *     .actionSheet(isPresented: $showingImagePicker) {       // changePicture
 *         .default(profileTakePhoto)  -> imagePickerType = .picture
 *         .default(profileUploadPhoto)-> imagePickerType = .gallery
 *         .cancel() }
 *     .sheet(item: $imagePickerType) { ImagePicker(sourceType:, showingType:, image:) }
 *
 * conditionalVariants[has_image] / [no_image] are `EditImageIcon`'s own two branches
 * (`if let image = model.image` -> the picture; `else` -> the grey circle), with the pencil
 * badge over both. They are built as an ArkUI `if` here, on the fields the plan names, and
 * comp_edit_image_icon draws whichever branch it is handed.
 *
 * bindingContract — [name] <- swarmNameDraft, [description] <- swarmDescriptionDraft,
 * [avatar] <- swarmAvatarDraft. All three are the HOST's draft (Swift's one shared
 * `SwarmCreationUIModel`), so they are `@Link`ed through to it: Save keeps what was typed and
 * Cancel runs `setDataToInitial()`, which is what the host then creates the swarm from.
 *
 * NO DAEMON IS INVOLVED on this screen: everything here is the local creation draft. Minting
 * the swarm is the host's job, and the host already states that ceiling.
 *
 * CAPABILITY. feat_camera_avatar / feat_photo_picker both go through comp_image_picker, which
 * proves `ohos.permission.CAMERA` and the presence of a camera before launching CameraKit —
 * an unguarded picker launch takes the process down. Only the user's own choice in the action
 * sheet reaches either picker.
 */
import { LengthMetrics } from '@kit.ArkUI';

import { EditImageIcon } from '../components/EditImageIcon';
import { ImagePicker, PhotoSheetType } from '../components/ImagePicker';

/* ── layout (structure, not S5 styling) ─────────────────────────────────────────────────── */
/** Swift `EditImageIcon(model: model, width: 100, height: 100)`. */
const AVATAR_SIDE: number = 100;
/** Swift `.frame(maxWidth: 200, minHeight: 40)` on both text fields. */
const FIELD_MAX_WIDTH: number = 200;
const FIELD_MIN_HEIGHT: number = 40;
/** Swift `.padding(.vertical, 10)` around the two-field stack. */
const FIELDS_V_PADDING: number = 10;
/** Swift `Spacer().frame(height: 20)` at the foot of the content stack. */
const CONTENT_BOTTOM_SPACER: number = 20;
/*
 * S5 — measured off results/traversal-source/pages/SwarmCreationUI/
 * swarm_creation_customize_profile.{png,ui.json} (393x852; the SwarmCreationViewController
 * capture is the identical tree):
 *
 *   sheet top        y 69                  (iOS pageSheet; ArkUI's own SheetSize.LARGE)
 *   nav bar          [0,69][393,125]       -> BAR_HEIGHT 56
 *   Cancel / Save    [15,83][76,111] / [332,83][377,111] -> BAR_INSET 16, both Color.jami
 *   title            [101,86][292,107]     -> centred, bold
 *   the tint         fill sampled (213,228,239) = #D5E4EF = app.color.jami_tertiary_control,
 *                    covering the bar too (the iOS bar is transparent over the Ellipse)
 *   avatar           [146,274][246,374]    -> 100 square, centred, 149 below the bar
 *   name field       [96,401][296,423]     -> 200 wide, centred, no background of its own
 *   description      [96,449][296,471]     -> 8 below the name field's 40-high box
 *   explanation      [25,697][368,739]     -> centred, BLACK (.label), ~17pt
 */
/** The sheet's own inline navigation bar — the capture's [0,69][393,125]. */
const BAR_HEIGHT: number = 56;
const BAR_INSET: number = 16;
/**
 * Swift `.offset(y: geometry.size.height * 0.3 - 60)` on the whole content stack — what puts
 * the avatar 149 below the bar instead of at the top of the content area. The source's
 * geometry height is the sheet below the bar less the home indicator (~693 in the capture),
 * so the expression lands on 148. It is a fixed value here rather than a percentage because
 * ArkUI resolves a percentage padding against the parent's WIDTH, and `.offset` would move
 * the drawing without moving the layout the avatar's tap target is measured from.
 */
const CONTENT_TOP: number = 148;
/**
 * The content stack is the full content area PLUS that shift — a border-box height, so its
 * content box is exactly the height Swift's `GeometryReader` hands the VStack. The parent
 * Stack clips whatever hangs below, as the sheet does in the capture.
 */
const CONTENT_BOX_HEIGHT: string = `calc(100% + ${CONTENT_TOP}vp)`;
/** SwiftUI's default `VStack` spacing between the two text fields (capture: 8). */
const FIELD_GAP: number = 8;
/** Swift `.padding()` around the explanation text — SwiftUI's default 16. */
const EXPLANATION_PADDING: number = 16;
/**
 * Swift `Ellipse().fill(Color.jamiTertiaryControl).frame(width: w * 1.4, height: h * 1.1)
 * .offset(x: -w * 0.2, y: -h * 0.8)` — pure decoration behind the content, no control.
 */
const ELLIPSE_WIDTH_RATIO: string = '140%';
const ELLIPSE_HEIGHT_RATIO: string = '110%';
const ELLIPSE_OFFSET_X: string = '-20%';
const ELLIPSE_OFFSET_Y: string = '-80%';

/* The in-app action sheet, the same shape pages/EditProfilePage.ets ships for the identical
 * Swift `.actionSheet(isPresented:)` — this one carries a title (`L10n.Swarm.changePicture`),
 * where the profile editor's is empty. */
const SHEET_INSET: number = 8;
const SHEET_BOTTOM_INSET: number = 16;
const SHEET_ROW_HEIGHT: number = 57;
const SHEET_TITLE_BAND: number = 28;
const SHEET_BACKDROP: string = '#33000000';
/* UIAlertController ignores SwiftUI's `.accentColor(.jami)` (the nav bar above it is navy): its
 * `.default` rows are regular systemBlue and `.cancel()` semibold systemBlue (iOS 4.20 capture). */
const SHEET_TINT: string = '#007AFF';
const SHEET_CANCEL_WEIGHT: number = 600;

@Component
export struct SwarmProfileSheet {
  /** Swift `@Binding var isPresentingProfile` — owned by screen_swarm_creation_ui. */
  @Link isPresented: boolean;

  /** bindingContract[name] — Swift `$model.swarmName` on the host's shared draft. */
  @Link name: string;
  /** bindingContract[description] — Swift `$model.swarmDescription`. */
  @Link description: string;
  /**
   * bindingContract[avatar] — Swift `$model.image`, base64 here (comp_image_picker encodes).
   * Watched because comp_image_picker writes it from outside this component's own handlers,
   * and the two branch selectors below have to follow it.
   */
  @Watch('onAvatarChanged') @Link avatar: string;

  /** conditionalVariants[has_image] — Swift `if let image = model.image`. */
  @State hasImage: boolean = false;
  /** conditionalVariants[no_image] — Swift's `else`: the grey circle + the pencil badge. */
  @State isNoImage: boolean = true;
  /** Swift `@SwiftUI.State private var showingImagePicker` — the action sheet. */
  @State showingImagePicker: boolean = false;
  /** Swift `@SwiftUI.State private var imagePickerType: PhotoSheetType?` — nil = closed. */
  @State isPickerOpen: boolean = false;
  /** Which source the user chose in the action sheet. */
  @State pickerSource: PhotoSheetType = PhotoSheetType.GALLERY;
  /** True while svc_profiles is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';

  /*
   * Swift `var initialSwarmName / initialSwarmDescription / initialImage`, which
   * `setDataToInitial()` restores. `takeCurrentDataSnapshot()` has NO caller anywhere in the
   * source, so these never move off their initial empty values — which is why Cancel clears
   * the draft rather than restoring a previous one. Ported as the source is, not as it reads
   * like it was meant to be. There is no `initialDescription` field because the source's own
   * `setDataToInitial()` never reads one — see `cancel()`.
   */
  private initialName: string = '';
  private initialAvatar: string = '';

  /** @Watch on avatar — comp_image_picker handed back a picture, or Cancel cleared one. */
  private onAvatarChanged(_propName: string): void {
    this.refreshAvatarBranch();
  }

  aboutToAppear(): void {
    // The two branch selectors follow the draft the host handed in.
    this.refreshAvatarBranch();
  }

  /** conditionalVariants[has_image] / [no_image] — kept complementary from the one value. */
  private refreshAvatarBranch(): void {
    this.hasImage = this.avatar.length > 0;
    this.isNoImage = !this.hasImage;
  }

  /** Swift `.onTapGesture { self.hideKeyboard() }` — UITextField+Helpers' resignFirstResponder. */
  private hideKeyboard(): void {
    this.getUIContext().getFocusController().clearFocus();
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /** Swift `imagePickerButton`'s action: `hideKeyboard(); showingImagePicker = true`. */
  private pickImage(): void {
    this.hideKeyboard();
    this.showingImagePicker = true;
  }

  /** Swift `.default(L10n.Alerts.profileTakePhoto) { imagePickerType = .picture }`. */
  private chooseCamera(): void {
    this.pickerSource = PhotoSheetType.PICTURE;
    this.showingImagePicker = false;
    // comp_image_picker proves the permission and the hardware before it launches CameraKit.
    this.isPickerOpen = true;
  }

  /** Swift `.default(L10n.Alerts.profileUploadPhoto) { imagePickerType = .gallery }`. */
  private chooseGallery(): void {
    this.pickerSource = PhotoSheetType.GALLERY;
    this.showingImagePicker = false;
    this.isPickerOpen = true;
  }

  /** Swift `.cancel()` — the action sheet closes and nothing is picked. */
  private dismissPhotoOptions(): void {
    this.showingImagePicker = false;
  }

  /** Swift `TextField(L10n.Swarm.namePlaceholder, text: $model.swarmName)`. */
  private setName(value: string): void {
    this.name = value;
  }

  /** Swift `TextField(L10n.Swarmcreation.addDescription, text: $model.swarmDescription)`. */
  private setDescription(value: string): void {
    this.description = value;
  }

  /**
   * Swift `trailingBarItems` — `isPresentingProfile = false`. The draft stays on the shared
   * model, which is what the host creates the swarm from, so Save writes nothing of its own.
   */
  private save(): void {
    this.hideKeyboard();
    this.isPresented = false;
  }

  /**
   * Swift `leadingBarItems` — `model.setDataToInitial(); isPresentingProfile = false`, where
   *
   *   func setDataToInitial() {
   *       self.image = initialImage
   *       self.swarmName = initialSwarmName
   *       self.swarmDescription = initialSwarmName   // the source's own slip, kept verbatim
   *   }
   */
  private cancel(): void {
    this.hideKeyboard();
    this.avatar = this.initialAvatar;
    this.name = this.initialName;
    // Verbatim: the source assigns `initialSwarmName` here, not `initialSwarmDescription`.
    this.description = this.initialName;
    this.refreshAvatarBranch();
    this.isPresented = false;
  }

  /* ── tree ─────────────────────────────────────────────────────────────────────────────── */
  /**
   * Swift `.navigationTitle(L10n.Swarm.customizeProfile)` with
   * `.navigationBarItems(leading:trailing:)` — Cancel on the left, Save on the right, both
   * `Color.jami`. They are the sheet's own bar items, which is why `.bindSheet` is mounted
   * with `showClose: false`: a system close would be a second, invented dismiss control.
   */
  @Builder
  private navigationBar() {
    Row() {
      // A UIBarButtonItem is a tinted LABEL, so the button carries no background of its
      // own — but it IS a Button, so the node the slug sits on is unambiguously clickable.
      Button($r('app.string.global_cancel'), { type: ButtonType.Normal })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
        .constraintSize({ minHeight: BAR_HEIGHT })
        .id('swarm_profile_cancel')
        .onClick(() => {
          this.cancel();
        })

      Text($r('app.string.swarm_customize_profile'))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      Button($r('app.string.global_save'), { type: ButtonType.Normal })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
        .constraintSize({ minHeight: BAR_HEIGHT })
        .id('swarm_profile_save')
        .onClick(() => {
          this.save();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: BAR_HEIGHT })
    .padding({ start: LengthMetrics.vp(BAR_INSET), end: LengthMetrics.vp(BAR_INSET) })
    // The iOS navigation bar is transparent, so `contentView()`'s Ellipse shows THROUGH it —
    // the capture's bar band samples the same #D5E4EF as the tint below it. Here the bar is a
    // sibling of that Stack rather than a layer over it, so it carries the tint itself.
    .backgroundColor($r('app.color.jami_tertiary_control'))
  }

  /**
   * Swift `imagePickerButton()` — the whole button is the tappable control, so its slug and
   * its handler sit on that node, not on a descendant (a slug on a wrapper whose handler is
   * below it reads `contract-control-inert`).
   */
  @Builder
  private imagePickerButton() {
    Column() {
      // conditionalVariants[has_image] — Swift `EditImageIcon`'s `if let image = model.image`.
      if (this.hasImage) {
        EditImageIcon({ imageData: this.avatar, side: AVATAR_SIDE })
      } else if (this.isNoImage) {
        // conditionalVariants[no_image] — Swift's `else { Circle().fill(systemGray2) }`,
        // which comp_edit_image_icon draws when it is handed no picture. The pencil badge is
        // over both branches, as in the source.
        EditImageIcon({ imageData: '', side: AVATAR_SIDE })
      }
    }
    .width(AVATAR_SIDE)
    .height(AVATAR_SIDE)
    .id('swarm_profile_pick_image')
    // Swift `.accessibilityLabel(L10n.Accessibility.swarmPicturePicker)` / `.accessibilityHint`
    // — the source's own strings for a control whose only visible content is a glyph.
    .accessibilityText($r('app.string.accessibility_swarm_picture_picker'))
    .accessibilityDescription($r('app.string.accessibility_profile_picture_picker_hint'))
    .onClick(() => {
      this.pickImage();
    })
  }

  /**
   * Swift `.actionSheet(isPresented: $showingImagePicker)` — titled `L10n.Swarm.changePicture`,
   * then `.default(profileTakePhoto)`, `.default(profileUploadPhoto)`, `.cancel()`. This is
   * the `dialog` effect `swarm_profile_pick_image` is contracted to produce; only a choice
   * made here reaches a system picker.
   */
  @Builder
  private photoSourceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      // UIKit dims the screen behind an action sheet; the content stays visible through it.
      // A tap on the dimmed area closes the action sheet like Cancel, leaving this sheet up.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SHEET_BACKDROP)
        .accessibilityLevel('no')
        .onClick(() => {
          this.dismissPhotoOptions();
        })

      Column({ space: SHEET_INSET }) {
        Column() {
          // Swift `ActionSheet(title: Text(L10n.Swarm.changePicture), …)`.
          Text($r('app.string.swarm_change_picture'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_S'))
            // An action sheet's title is semibold.
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.secondary_label'))
            .padding({ top: SHEET_TITLE_BAND / 2, bottom: SHEET_TITLE_BAND / 2 })

          Divider()
            .color($r('sys.color.comp_divider'))
          Button($r('app.string.alerts_profile_take_photo'))
            .id('swarm_profile_photo_source_camera')
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
            .id('swarm_profile_photo_source_gallery')
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
        .backgroundColor($r('sys.color.background_secondary'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
        .clip(true)

        // Swift `.cancel()` — its own card, as the profile editor's sheet already ships it.
        Button($r('app.string.global_cancel'))
          .id('swarm_profile_photo_source_cancel')
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

  /** Swift `contentView()` — the decoration, then the centred stack it sits behind. */
  @Builder
  private contentView() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Swift `Ellipse().fill(Color.jamiTertiaryControl)` — decoration only; it takes no
      // touches, so the stack below stays tappable (ArkUI's topmost hit target wins).
      Ellipse()
        .width(ELLIPSE_WIDTH_RATIO)
        .height(ELLIPSE_HEIGHT_RATIO)
        .fill($r('app.color.jami_tertiary_control'))
        .offset({ x: ELLIPSE_OFFSET_X, y: ELLIPSE_OFFSET_Y })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      // Swift `HStack { Spacer; VStack { … }; Spacer }` — a centred column.
      Column() {
        this.imagePickerButton()

        // Swift `VStack(alignment: .center) { TextField; TextField }.padding(.vertical, 10)`.
        // A bare SwiftUI `TextField` draws NO control chrome: the capture shows the two fields
        // as centred text straight on the sheet, with only the grey placeholder visible.
        // ArkUI's TextInput ships a filled, rounded box by default, so it is cleared here.
        Column({ space: FIELD_GAP }) {
          TextInput({
            placeholder: $r('app.string.swarm_name_placeholder'),
            text: this.name
          })
            .id('swarm_profile_name')
            .constraintSize({ maxWidth: FIELD_MAX_WIDTH, minHeight: FIELD_MIN_HEIGHT })
            .textAlign(TextAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding(0)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .placeholderFont({ size: $r('sys.float.Body_L') })
            // Capture: the placeholder samples (197,197,199) — iOS placeholderText, lighter
            // than the secondary label the rest of this app's fields use.
            .placeholderColor($r('app.color.placeholder_text'))
            .caretColor($r('app.color.jami'))
            // S6: the whole stack carries Swift's `.onTapGesture { hideKeyboard() }`, and an
            // ArkUI click on a child can also reach the ancestor's handler — which would clear
            // the focus this tap just gave the field, leaving it impossible to type into.
            // SwiftUI's TextField consumes its own tap; this is how ArkUI spells that.
            .monopolizeEvents(true)
            .onChange((value: string) => {
              this.setName(value);
            })

          TextInput({
            placeholder: $r('app.string.swarmcreation_add_description'),
            text: this.description
          })
            .id('swarm_profile_description')
            .constraintSize({ maxWidth: FIELD_MAX_WIDTH, minHeight: FIELD_MIN_HEIGHT })
            .textAlign(TextAlign.Center)
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding(0)
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .placeholderFont({ size: $r('sys.float.Body_L') })
            .placeholderColor($r('app.color.placeholder_text'))
            .caretColor($r('app.color.jami'))
            // Same as the name field above: the tap stays on the field.
            .monopolizeEvents(true)
            .onChange((value: string) => {
              this.setDescription(value);
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: FIELDS_V_PADDING, bottom: FIELDS_V_PADDING })

        // Swift `Spacer()`.
        Blank()

        // Swift `Text(L10n.Swarm.explanationText).lineLimit(nil).multilineTextAlignment(.center)
        // .padding()`.
        // The source sets no foreground colour, so it is `.label`: the capture's ink samples
        // pure black, not the grey a footnote would be, and it is `.body`-sized like the
        // fields above it.
        Text($r('app.string.swarm_explanation_text'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .padding(EXPLANATION_PADDING)

        // Swift `Spacer(); Spacer().frame(height: 20)`.
        Blank()
        Column()
          .width('100%')
          .height(CONTENT_BOTTOM_SPACER)

        // The failure slot — under the content, so nothing it reports hides the fields.
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.warning'))
            .padding(EXPLANATION_PADDING)
        }
      }
      .width('100%')
      // S6 — Swift OFFSETS this stack by 148; it does not inset it, so the stack keeps the
      // FULL content height and simply hangs 148 below (the parent Stack clips the overflow).
      // Carrying the 148 as padding alone shortened the box by 148, and the two Spacers either
      // side of the explanation text split what was left: the explanation came out ~128 above
      // the capture's [25,697][368,739]. Height + padding restores the source's own geometry
      // while the avatar's tap target stays where it is laid out (an `.offset` would move the
      // drawing only).
      .height(CONTENT_BOX_HEIGHT)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: LengthMetrics.vp(CONTENT_TOP) })
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
  }

  build() {
    // Swift `PlatformAdaptiveNavView { VStack { contentView() } }`, plus the two things it
    // presents OVER that stack.
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.navigationBar()
        this.contentView()
      }
      .width('100%')
      .height('100%')
      // Swift `.onTapGesture { self.hideKeyboard() }` on the whole stack.
      .onClick(() => {
        this.hideKeyboard();
      })

      // Swift `.actionSheet(isPresented: $showingImagePicker)`.
      if (this.showingImagePicker) {
        this.photoSourceSheet()
      }

      // Swift `.sheet(item: $imagePickerType) { type in ImagePicker(sourceType: type ==
      // .picture ? .camera : .photoLibrary, showingType: $imagePickerType, image: $model.image) }
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
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_swarm_profile')
  }
}
