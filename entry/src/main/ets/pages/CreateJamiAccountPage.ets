/*
 * screen_create_account — "Create Jami Account" (PILOT), ported from
 *   Ring/Ring/Features/Walkthrough/Views/CreateAccountView.swift
 *   Ring/Ring/Features/Walkthrough/Models/CreateAccountVM.swift
 *   Ring/Ring/Features/Walkthrough/Views/Views.swift (WalkthroughFocusableTextView)
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (CustomAlert, PasswordFieldView)
 *   Ring/Ring/Features/Walkthrough/WalkthroughCoordinator.swift (showAccountCreation)
 *
 * presentation: modal, hostScreen: screen_welcome. WalkthroughCoordinator.showAccountCreation
 * wraps CreateAccountView in a dismissable VC and presents it .formModal, so it is a
 * @CustomDialog mounted by WelcomeOnboardingPage — NOT a routed page and NOT in
 * main_pages.json.
 *
 * S3: the real tree of `CreateAccountView.body` —
 *   ZStack { VStack { header(cancel | title | create) ;
 *            ScrollView { if profileCustomized() { profileStatus } ;
 *                         if encryptionEnabled { encryptionStatus } ;
 *                         nameExplanation ; userNameView ; footerView ; buttons } }
 *            if showEncryptView { CustomAlert { encryptView() } } }
 * unstyled. Every rendered value stays BOUND (the username draft, the live lookup message).
 *
 * S4: the username field forwards each edit to `CreateAccountVM.usernameUpdated(to:)` ->
 * NameService.lookupName (feat_name_service, svc_name), and the validation stream drives the
 * free / taken branches, the error label and the Join button's guard — Swift's
 * `bindUsernameValidationStatus` / `updateValidationState` / `updateJoinButtonAvailability`,
 * ported verbatim.
 *
 * Create hands the request to the host (Swift `createAction` -> `WelcomeVM.createAccount`):
 * the sheet dismisses itself and the welcome screen shows the progress and any error (T-1620).
 *
 * OUTGOING EDGE screen_create_account -> screen_profile (kind: present). Swift keeps
 * `@State showProfileView` on THIS view and presents ProfileView as a .sheet from it, so the
 * flag lives here.
 *
 * S5 styles that structure against results/traversal-source/pages/CreateAccountView/*.
 * The screen is `.background(Color(UIColor.systemGroupedBackground))` presented `.formModal`,
 * so it reads as a sheet inset from the top with rounded top corners over the walkthrough
 * wallpaper. Values come from the iOS semantic role (ios-to-harmonyos-design-tokens.md); the
 * literals are the ones the Swift itself hardcodes — the field box's `cornerRadius(10)` +
 * 10/12 pt padding (Views.swift), the 10 pt xmark and the 500 pt max content width
 * (CreateAccountView.swift), and the two app colour constants `Color.jamiSuccess` (#00B20B)
 * and `Color.jamiFailure` (#F00000) from Extensions/UIColor+Ring.swift, which have no
 * `app.color.*` resource yet.
 *
 * Deviations from state.json's styleBaseline: `pageBackground` is the baseline's white, but
 * this screen is grouped, so it uses `background_secondary`; `fieldBackground` is the
 * baseline's grey, but the source's field is `secondarySystemGroupedBackground` (white on the
 * grey page), so the fields use the baseline's `cardBackground` instead.
 *
 * S6 finalizes it. The action-contract controls this screen owes, with the shipped string
 * each one actually renders and the source slug it carries — the contract's labels are the
 * analyst's description of the control, not the app's own wording:
 *
 *   Choose a username -> the username field, placeholder `global_username` ("Username"),
 *                        slug usernameTextField
 *   Join              -> `global_create` ("Create"), slug joinButton
 *   Cancel            -> `global_cancel`, slug cancelCreatingAccount
 *   Encrypt account   -> `create_account_encrypt` ("Password protect"),
 *                        slug createAccountEncrypt
 *   Customize profile -> `create_account_customize` ("Customize"),
 *                        slug createAccountCustomize
 *   Reset profile     -> the xmark in the profile pill, slug createAccountResetProfile
 *   Save (encrypt)    -> `global_save`, slug createAccountEncryptSave
 *   Cancel (encrypt)  -> `global_cancel`, slug createAccountEncryptCancel
 *
 * The four username-availability states are the SOURCE's, not a design decision taken here
 * (`UsernameValidationState.textColor`, CreateAccountVM.swift:76-87):
 *   available  -> checkmark.circle.fill + the message in jamiSuccess
 *   unavailable / invalid -> the message in jamiFailure, no glyph
 *   lookingForAvailability -> the message is rendered in `.clear`. That is deliberate in the
 *                             source: the lookup is silent, and the invisible line only holds
 *                             the row's height. No spinner is added here — one would be a
 *                             control the source does not draw and a divergence from the
 *                             capture of exactly this state (usernameTextField.png).
 *   unknown    -> Swift's invisible "valid name" placeholder, which carries the screen-reader
 *                 prompt and nothing else.
 */

import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { describeError } from '../common/ErrorText';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
// feat_name_service (svc_name): the live username-availability lookup this screen is built
// around. Imported directly — the field's every edit goes through it.
import { NameService, UsernameValidationStatus } from '../common/NameService';
import { CustomAlert } from '../components/CustomAlert';
import { WalkthroughPasswordView } from '../components/WalkthroughPassword';
import { WalkthroughTextEditView } from '../components/WalkthroughTextEdit';
import { CustomizeProfileSheet } from './CustomizeProfileOnboardingPage';
import { AvatarSwiftUIView } from '../components/AvatarSwiftui';

/** Swift `UIColor.jamiSuccess` / `UIColor.jamiFailure` — app constants, hardcoded hexes. */
const VALIDATION_OK_COLOR: string = '#00B20B';
const VALIDATION_FAIL_COLOR: string = '#F00000';
/** Swift `ScrollView { … }.frame(maxWidth: 500)`. */
const CONTENT_MAX_WIDTH: number = 500;
/** `.formModal`: the sheet leaves the top of the screen showing (capture: 69 of 852 pt). */
const SHEET_HEIGHT: string = '92%';

@CustomDialog
export struct CreateJamiAccountOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;

  /** Owned by screen_welcome — the host's @State that mounts this overlay. */
  @Link isPresented: boolean;

  /** Swift: `@State private var name` — the chosen username draft. */
  @State usernameField: string = '';
  /** Swift: `viewModel.usernameValidationState.message` (svc_name lookup result). */
  @State errorLabel: string = '';
  /** Swift: `@State private var password`. */
  @State password: string = '';
  /** Swift: `@State private var passwordConfirm`. */
  @State passwordConfirm: string = '';
  /** Swift: `@State private var profileName` — set by the ProfileView sheet. */
  @State profileName: string = '';
  /** Swift: `@State private var profileImage: UIImage?` — base64, '' = none. */
  @State profileImage: string = '';

  /**
   * Swift: `@State private var isTextFieldFocused` — the username field's first-responder
   * flag, two-way bound into WalkthroughFocusableTextView and cleared by the encrypt button.
   * Starts true as in Swift: the field takes focus (and the keyboard) when the sheet opens.
   */
  @State isUsernameFocused: boolean = true;

  /** Swift: `@State private var showEncryptView` (conditionalVariants[encrypt_expanded]). */
  @State isEncryptExpanded: boolean = false;
  /** Swift: `profileCustomized()` (conditionalVariants[profile_chosen]). */
  @State isProfileChosen: boolean = false;
  /** Swift: `usernameValidationState.isAvailable` (conditionalVariants[username_free]). */
  @State isUsernameFree: boolean = false;
  /** Swift: `usernameValidationState == .unavailable` (conditionalVariants[username_taken]). */
  @State isUsernameTaken: boolean = false;
  /** Swift: `@State private var encryptionEnabled` — set when the password alert is saved. */
  @State isEncryptionEnabled: boolean = false;
  /** Swift: `viewModel.isJoinButtonDisabled`. */
  @State isJoinDisabled: boolean = false;

  /** Swift: `@State private var showProfileView` — raises screen_profile as a sheet. */
  @State private showProfileSheet: boolean = false;

  /** True while svc_name's lookup, or the account-creation attempt, is in flight. */
  @State isLoading: boolean = false;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /**
   * Swift `createAction(name, password, profileName, profileImage)` -> `WelcomeVM.createAccount`:
   * the host runs the creation under its "Creating account" alert (profileImage is base64).
   */
  createAction: (name: string, password: string, profileName: string, profileImage: string) => void =
    (_name: string, _password: string, _profileName: string, _profileImage: string): void => {};

  /** Swift `let disposeBag = DisposeBag()` — the validation subscription. */
  private bag: DisposeBag = new DisposeBag();
  /** Swift `CreateAccountVM.username` — the VM's own copy, which its guard compares against. */
  private lastLookedUpUsername: string = '';

  aboutToAppear(): void {
    this.bindUsernameValidationStatus();
    this.raiseProfileSheetIfRequested();
  }

  /**
   * A cold deep link naming screen_profile resolves to WelcomeOnboardingPage plus the overlay
   * id, and Swift presents ProfileView OVER CreateAccountView (`createAccountCustomize` ->
   * `.sheet(isPresented: $showProfileView)`), so the host asks this overlay to raise the same
   * sheet the control raises. Consumed once: a second open must show the bare create form.
   */
  private raiseProfileSheetIfRequested(): void {
    const requested: boolean | undefined =
      AppStorage.get<boolean>('walkthroughProfileSheetRequested');
    if (requested !== true) {
      return;
    }
    AppStorage.setOrCreate<boolean>('walkthroughProfileSheetRequested', false);
    this.openProfileCustomization();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
    }
  }

  /** Swift `CreateAccountVM.bindUsernameValidationStatus()`. */
  private bindUsernameValidationStatus(): void {
    const nameService: NameService = ServiceRegistry.shared().nameService;
    this.bag.add(nameService.usernameValidationStatus.subscribe(
      (status: UsernameValidationStatus): void => {
        this.updateValidationState(status);
        this.updateJoinButtonAvailability();
      }));
  }

  /** Swift `CreateAccountVM.usernameUpdated(to:)` — the field's `.onChange(of: name)`. */
  private usernameUpdated(newUsername: string): void {
    if (this.lastLookedUpUsername === newUsername) {
      return;
    }
    this.lastLookedUpUsername = newUsername;
    if (newUsername.length === 0) {
      this.updateValidationState(UsernameValidationStatus.EMPTY);
      this.updateJoinButtonAvailability();
      return;
    }
    this.isLoading = true;
    // Swift passes empty strings for both: the new name is checked on the default name server,
    // never through whichever account happens to be current.
    ServiceRegistry.shared().nameService.lookupName('', '', newUsername);
  }

  /** Swift `CreateAccountVM.updateValidationState(with:)`. */
  private updateValidationState(status: UsernameValidationStatus): void {
    if (this.usernameField.length === 0) {
      this.isUsernameFree = false;
      this.isUsernameTaken = false;
      this.isLoading = false;
      this.errorLabel = '';
      return;
    }
    this.isUsernameFree = status === UsernameValidationStatus.VALID;
    this.isUsernameTaken = status === UsernameValidationStatus.ALREADY_TAKEN;
    this.isLoading = status === UsernameValidationStatus.LOOKING_UP;
    this.errorLabel = this.validationMessage(status);
  }

  /** Swift `UsernameValidationState.message` — the app's own strings, never a captured one. */
  private validationMessage(status: UsernameValidationStatus): string {
    let name: string = '';
    if (status === UsernameValidationStatus.LOOKING_UP) {
      name = 'create_account_looking_for_username_availability';
    } else if (status === UsernameValidationStatus.INVALID) {
      name = 'create_account_invalid_username';
    } else if (status === UsernameValidationStatus.ALREADY_TAKEN) {
      name = 'create_account_username_already_taken';
    } else if (status === UsernameValidationStatus.VALID) {
      name = 'create_account_username_valid';
    }
    if (name.length === 0) {
      return '';
    }
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      return context.resourceManager.getStringByNameSync(name);
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      return '';
    }
  }

  /**
   * Swift `UsernameValidationState.textColor`: `.available` -> jamiSuccess, `.invalid` /
   * `.unavailable` -> jamiFailure, `.lookingForAvailability` / `.unknown` -> `.clear`.
   * Both hexes are app constants the source hardcodes (Extensions/UIColor+Ring.swift).
   */
  private validationTextColor(): ResourceColor {
    if (this.isUsernameFree) {
      return VALIDATION_OK_COLOR;
    }
    if (this.isLoading) {
      return Color.Transparent;
    }
    return VALIDATION_FAIL_COLOR;
  }

  /** Swift `CreateAccountVM.updateJoinButtonAvailability()`. */
  private updateJoinButtonAvailability(): void {
    this.isJoinDisabled = this.usernameField.length > 0 && !this.isUsernameFree;
  }

  /** Swift `passwordValidated` — the Save button's own guard. */
  private passwordValidated(): boolean {
    return this.password.length > 0 && this.password === this.passwordConfirm;
  }

  /** Swift `passwordsDoNotMatch`. */
  private passwordsDoNotMatch(): boolean {
    return this.passwordConfirm.length > 0 && this.passwordConfirm !== this.password;
  }

  /** Swift: `dismissHandler.dismissView()` behind the cancel button. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** Swift: `encryptButton` — reveals the CustomAlert password section. */
  private toggleEncrypt(): void {
    // Swift `encryptButton`: `isTextFieldFocused = false` before showing the alert.
    this.isUsernameFocused = false;
    this.isEncryptExpanded = true;
  }

  /** Swift `actionButtons()` Save — keeps the password and closes the alert. */
  private saveEncryption(): void {
    this.isEncryptExpanded = false;
    this.isEncryptionEnabled = true;
  }

  /** Swift `actionButtons()` Cancel — closes the alert, dropping an unvalidated password. */
  private cancelEncryption(): void {
    this.isEncryptExpanded = false;
    if (!this.passwordValidated()) {
      this.password = '';
      this.passwordConfirm = '';
    }
  }

  /** Swift: `customizeButton` — `showProfileView = true` (plan edge -> screen_profile). */
  private openProfileCustomization(): void {
    this.showProfileSheet = true;
  }

  /** Swift `resetProfile()` — clears the picked avatar and profile name. */
  private resetProfile(): void {
    this.profileName = '';
    this.profileImage = '';
    this.profileCustomized();
  }

  /** Swift ProfileView's `saveProfile` closure, passed down from CreateAccountView. */
  private profileSaved(name: string, photo: string): void {
    // Do not reset the photo if it was taken previously.
    if (photo.length > 0) {
      this.profileImage = photo;
    }
    this.profileName = name;
    this.profileCustomized();
  }

  /** Swift `profileCustomized()`: `!profileName.isEmpty || profileImage != nil`. */
  private profileCustomized(): void {
    this.isProfileChosen = this.profileName.length > 0 || this.profileImage.length > 0;
  }

  /**
   * Swift `createButton`: `dismissHandler.dismissView()` then `createAction(...)`. The sheet
   * goes first and the welcome screen's "Creating account" alert covers everything until the
   * outcome, as on iOS. Keeping the sheet up with a live Create button for the whole creation
   * (key generation, registration, name registration) let a second tap - or Cancel and Join
   * again - add a second account, which then lost the name race and showed only its id (T-1620).
   */
  private join(): void {
    this.dismiss();
    this.createAction(this.usernameField, this.password, this.profileName, this.profileImage);
  }

  /**
   * A string-resource failure from `validationMessage`, in place under the buttons: the failure
   * glyph in `Color.jamiFailure` beside the message.
   */
  @Builder
  failureNotice() {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
        .fontSize(16)
        .fontColor([VALIDATION_FAIL_COLOR])
        .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
      Text(this.errorText)
        .fontSize($r('sys.float.Body_S'))
        .fontColor(VALIDATION_FAIL_COLOR)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: $r('sys.float.padding_level4') })
  }

  /** screen_profile (presentation: sheet, hostScreen: screen_create_account) content. */
  @Builder
  profileSheet() {
    CustomizeProfileSheet({
      isPresented: $showProfileSheet,
      initialName: this.profileName,
      initialImage: this.profileImage,
      onSave: (name: string, photo: string): void => {
        this.profileSaved(name, photo);
      }
    })
  }

  /** Swift `header` — cancel, the title, and the create button. */
  @Builder
  header() {
    // Swift `header`: `ZStack { HStack { cancel; Spacer; create }; Text(title).font(.headline) }
    // .padding()` — the title is a CENTRED layer, so it stays centred whatever the two bar
    // items measure.
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.create_account_new_account'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(600) // `.headline` is semibold
        .fontColor($r('app.color.label'))
        .id('createAccountTitle')
      Row() {
        // Swift: `Text(L10n.Global.cancel).foregroundColor(Color(UIColor.label))` — the plain
        // label colour, NOT the accent.
        Button($r('app.string.global_cancel'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.label'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .id('cancelCreatingAccount')
          .onClick(() => {
            this.dismiss();
          })
        Blank()
        // Swift: `.foregroundColor(isJoinButtonDisabled ? secondaryLabel : .jami)`.
        Button($r('app.string.global_create'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor(this.isJoinDisabled
            ? $r('app.color.secondary_label')
            : $r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .id('joinButton')
          .enabled(!this.isJoinDisabled)
          .onClick(() => {
            this.join();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
  }

  /** Swift `profileStatus` — shown only once a profile has been picked. */
  @Builder
  profileStatus() {
    // Swift `profileStatus`: `Text(header).font(.headline)` beside a pill outlined with
    // `RoundedRectangle(cornerRadius: 12).stroke(tertiaryLabel, lineWidth: 1)`, the whole row
    // `.padding(.bottom)`.
    Row() {
      Text($r('app.string.account_page_profile_header'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      // S6: the OUTLINED PILL the S4 tree flattened away. Swift puts the name and the xmark
      // in their own HStack and hangs the outline on THAT, not on the whole row — the
      // "Profile" header stays outside it:
      //   .padding(.leading).padding(.vertical, 10)
      //   .overlay(RoundedRectangle(cornerRadius: 12).inset(by: 1)
      //            .stroke(Color(UIColor.tertiaryLabel), lineWidth: 1))
      // Both the radius and the 1 pt stroke are hardcoded in the source, so they are copied
      // rather than tokenised.
      Row() {
        // Swift: `if let image = self.profileImage { Image … .frame(20, 20).clipShape(Circle()) }`.
        if (this.profileImage.length > 0) {
          AvatarSwiftUIView({
            avatarData: this.profileImage,
            displayText: this.profileName,
            isGroup: false,
            avatarSize: 20
          })
            .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
        }
        Text(this.profileName)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // Swift: `.frame(width: 10, height: 10)` `.foregroundColor(tertiaryLabel)`
        // `.padding(.horizontal)` — a hardcoded glyph size.
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(10)
          .fontColor([$r('sys.color.font_tertiary')])
          .margin({
            left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
          })
          .id('createAccountResetProfile')
          .onClick(() => {
            this.resetProfile();
          })
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)
      .margin({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
      .padding({ left: $r('sys.float.ohos_id_elements_margin_horizontal_l'), top: 10, bottom: 10 })
      .borderRadius(12)
      .border({ width: 1, color: $r('sys.color.font_tertiary') })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
  }

  /** Swift `encryptionStatus` — the checkmark + "encryption enabled" line. */
  @Builder
  encryptionStatus() {
    // Swift `encryptionStatus`: the glyph and the `.footnote` label are both
    // `Color.jamiSuccess`, the label `.padding(.horizontal, 5)`, the row `.padding(.bottom)`.
    Row() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
        .fontSize(16)
        .fontColor([VALIDATION_OK_COLOR])
      Text($r('app.string.create_account_encryption_enabled'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor(VALIDATION_OK_COLOR)
        .margin({
          left: $r('sys.float.ohos_id_elements_margin_horizontal_s'),
          right: $r('sys.float.ohos_id_elements_margin_horizontal_s')
        })
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })
  }

  /** Swift `footerView` — the live username-lookup message, bound to svc_name. */
  @Builder
  footerView() {
    Row() {
      // conditionalVariants[username_free]: Swift shows checkmark.circle.fill for a free name.
      if (this.isUsernameFree) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(16)
          .fontColor([VALIDATION_OK_COLOR])
          .margin({ right: $r('sys.float.ohos_id_elements_margin_horizontal_s') })
      }
      // conditionalVariants[username_taken]: a taken name always carries a message, and Swift
      // renders the labelled `createAccountErrorLabel` whenever the message is non-empty.
      if (this.isUsernameTaken || this.errorLabel.length > 0) {
        // Swift `.font(.footnote).foregroundColor(Color(validationState.textColor))`.
        Text(this.errorLabel)
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.validationTextColor())
          .textAlign(TextAlign.Center)
          .id('createAccountErrorLabel')
      } else {
        // Swift's invisible "valid name" placeholder: `Text("valid name")
        // .foregroundColor(.clear).font(.footnote)` — it keeps the row's height and carries
        // the screen-reader prompt, under the field rather than on it (T-1663). An empty Text
        // is zero-sized, so nothing could reach it; the prompt itself is the clear text here.
        Text($r('app.string.accessibility_create_account_verify_username_prompt'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor(Color.Transparent)
          .maxLines(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  /** Swift `buttons` — `HStack { Spacer(); encryptButton; customizeButton }`. */
  @Builder
  buttons() {
    // Both labels are `.foregroundColor(.jami)`; only the encrypt one carries `.padding()`.
    Row() {
      Blank()
      // Swift: `encryptionEnabled ? L10n.AccountPage.changePassword : L10n.CreateAccount.encrypt`.
      Button(this.isEncryptionEnabled ? $r('app.string.account_page_change_password') :
        $r('app.string.create_account_encrypt'))
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.jami'))
        .fontSize($r('sys.float.Body_L'))
        .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        .id('createAccountEncrypt')
        .onClick(() => {
          this.toggleEncrypt();
        })
      Button($r('app.string.create_account_customize'))
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.jami'))
        .fontSize($r('sys.float.Body_L'))
        .padding(0)
        .id('createAccountCustomize')
        .onClick(() => {
          this.openProfileCustomization();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** Swift `encryptView()` — the CustomAlert body: title, explanation, fields, actions. */
  @Builder
  encryptView() {
    // Swift `encryptView()`: `VStack(spacing: 20) { title.font(.headline);
    // explanation.font(.subheadline); passwordFieldsSection(); actionButtons() }`.
    Column({ space: 20 }) {
      Text($r('app.string.create_account_encrypt_title'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
      Text($r('app.string.create_account_encrypt_explanation'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('app.color.label'))
        .width('100%')

      WalkthroughPasswordView({
        text: $password,
        placeholder: $r('app.string.global_enter_password'),
        identifier: 'createAccountPassword'
      })
      WalkthroughPasswordView({
        text: $passwordConfirm,
        placeholder: $r('app.string.global_confirm_password'),
        identifier: 'createAccountPasswordConfirm'
      })
      if (this.passwordsDoNotMatch()) {
        // Swift: `.foregroundColor(.red).font(.footnote)`.
        Text($r('app.string.account_page_passwords_do_not_match'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor(Color.Red)
          .width('100%')
      }

      Row() {
        Button($r('app.string.global_cancel'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .id('createAccountEncryptCancel')
          .onClick(() => {
            this.cancelEncryption();
          })
        Blank()
        // Swift: `.disabled(!passwordValidated).opacity(passwordValidated ? 1 : 0.5)`.
        Button($r('app.string.global_save'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.jami'))
          .fontSize($r('sys.float.Body_L'))
          .padding(0)
          .opacity(this.passwordValidated() ? 1 : 0.5)
          .id('createAccountEncryptSave')
          .enabled(this.passwordValidated())
          .onClick(() => {
            this.saveEncryption();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        this.header()

        Scroll() {
          Column() {
            // Swift: `if profileCustomized() { profileStatus }`.
            if (this.isProfileChosen) {
              this.profileStatus()
            }
            // Swift: `if encryptionEnabled { encryptionStatus }`.
            if (this.isEncryptionEnabled) {
              this.encryptionStatus()
            }
            // Swift: `.multilineTextAlignment(.center).padding(.bottom)`.
            Text($r('app.string.create_account_name_explanation'))
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.label'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: $r('sys.float.ohos_id_elements_margin_horizontal_l') })

            // Swift `userNameView` — WalkthroughFocusableTextView(text: $name, ...).
            WalkthroughTextEditView({
              text: $usernameField,
              placeholder: $r('app.string.global_username'),
              identifier: 'usernameTextField',
              // Swift `isTextFieldFocused: $isTextFieldFocused`.
              isFocused: $isUsernameFocused,
              // Swift `.onChange(of: name) { viewModel.usernameUpdated(to: $0) }`.
              onTextChange: (value: string): void => {
                this.usernameUpdated(value);
              }
            })

            this.footerView()
            this.buttons()
            if (this.errorText.length > 0) {
              this.failureNotice()
            }
          }
          .width('100%')
          // Swift `ScrollView { … }.frame(maxWidth: 500).padding(.horizontal)`.
          .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
          .padding({
            left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
            right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
          })
        }
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      // `.formModal` leaves the top of the screen showing, so the sheet is a rounded-top
      // panel on `systemGroupedBackground`, not a full-bleed page.
      .height(SHEET_HEIGHT)
      .backgroundColor($r('sys.color.background_secondary'))
      .borderRadius({
        topLeft: $r('sys.float.ohos_id_corner_radius_default_m'),
        topRight: $r('sys.float.ohos_id_corner_radius_default_m')
      })
      .clip(true)
      // ProfileView carries its own Cancel/Save, so the system close is suppressed.
      .bindSheet($$this.showProfileSheet, this.profileSheet(), { showClose: false })

      // Swift: `if showEncryptView { encryptViewAlert() }` — an in-app alert layer, not a dialog.
      if (this.isEncryptExpanded) {
        // The @BuilderParam MUST be handed over as a lambda, not as the bare method reference:
        // a bare `this.encryptView` is re-bound to the CustomAlert instance when CustomAlert
        // calls it, so `$password` / `$passwordConfirm` resolve against CustomAlert (which owns
        // no such state) and the @Link constructor throws "source variable in parent/ancestor
        // @Component must be defined", killing the app the moment the alert opens.
        CustomAlert({
          content: (): void => {
            this.encryptView();
          }
        })
      }
    }
    .alignContent(Alignment.Bottom)
    .width('100%')
    .height('100%')
    .id('screen_create_account')
  }
}
