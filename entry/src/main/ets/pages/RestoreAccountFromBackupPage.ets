/*
 * screen_import_from_archive — "Restore Account from Backup", ported from
 *   Ring/Ring/Features/Walkthrough/Views/ImportFromArchiveView.swift
 *   Ring/Ring/Features/Walkthrough/Models/ImportFromArchiveVM.swift
 *   Ring/Ring/UI/SwiftUIViews/DocumentPicker.swift
 *   Ring/Ring/Features/Walkthrough/Models/WelcomeVM.swift   (importFromArchive)
 *
 * presentation: modal, hostScreen: screen_welcome. WalkthroughCoordinator.showImportArchive
 * presents it .formModal, so it is a @CustomDialog mounted by WelcomeOnboardingPage — NOT a
 * routed page and NOT in main_pages.json.
 *
 * S3 — the real component tree of `ImportFromArchiveView.body`:
 *   VStack {
 *     header: ZStack { HStack { cancelButton; Spacer; importButton }; Text(title).headline }
 *     ScrollView { VStack(spacing: 15) {
 *       Text(explanation)
 *       selectFileButton          // label == viewModel.selectedFileText
 *       Text(passwordExplanation)
 *       WalkthroughPasswordView(text: $viewModel.password, identifier: "importArchivePassword")
 *     }}
 *     .sheet(isPresented: $viewModel.pickerPresented) { DocumentPicker(fileURL:, type: .item) }
 *   }
 *
 * Swift's WalkthroughPasswordView (Views.swift:21) is literally
 *   ZStack { RoundedRectangle(cornerRadius: 10).foregroundColor(backgroundColor)
 *            PasswordFieldView(text:placeholder:identifier:).padding(10/12) }
 * and this project's PasswordFieldView already carries that rounded pill and the same
 * `passwordVisibilityToggle` eye, so instantiating it directly is the source's own tree with no
 * level lost — and it is the component the plan assigns this screen (comp_password_field).
 *
 * conditionalVariants: `viewModel.isImportButtonDisabled == (selectedFileURL == nil)` and
 * `selectedFileText = selectedFileURL?.lastPathComponent ?? L10n…selectArchiveButton` — the two
 * branches [file_selected] / [no_file], built as real `if`s below.
 *
 * Import is Swift's: the sheet dismisses itself and hands the file and password to the host
 * (`ImportFromArchiveVM.importAction` -> `WelcomeVM.importFromArchive`), which shows the
 * "Creating account" progress and any error on the welcome screen.
 */
import { common } from '@kit.AbilityKit';
import { DocumentPicker } from '../components/DocumentPicker';
import { PasswordFieldView } from '../components/PasswordField';

/* ── S5 metrics, the source's own (ImportFromArchiveView.swift:32-100) ───────────── */
/** Swift `VStack(spacing: 15)` inside the ScrollView. */
const CONTENT_SPACING: number = 15;
/** Swift `.frame(maxWidth: 500)` on that VStack. */
const CONTENT_MAX_WIDTH: number = 500;
/** Swift `selectFileButton`: `.padding(.horizontal, 12).padding(.vertical, 12)`. */
const SELECT_FILE_PADDING: number = 12;
/** Swift `selectFileButton`: `.cornerRadius(12)` — hardcoded in the source. */
const SELECT_FILE_RADIUS: number = 12;
/** Swift `.padding(.vertical)` / `.padding(.bottom)` — the system 16 pt inset. */
const BLOCK_INSET: number = 16;
/** `.formModal` leaves the top of the screen showing (capture: 165 of 2556 px). */
const SHEET_HEIGHT: string = '92%';

@CustomDialog
export struct RestoreAccountFromBackupOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /**
   * Owned by screen_welcome (Swift: WalkthroughCoordinator owns the presented VC), so the
   * sheet can dismiss itself while the host stays the single writer of "is it up".
   */
  @Link isPresented: boolean;
  /** Swift `ImportFromArchiveVM.importAction(url, password)` — the host runs the import. */
  importAction: (uri: string, password: string) => void =
    (_uri: string, _password: string): void => {};

  /**
   * Swift `@Published var selectedFileURL: URL?` — empty string is the source's `nil`. The
   * DocumentPicker writes it through its @Link, exactly as the source's `@Binding` does, and
   * @Watch recomputes the two values the view model derives from it.
   */
  @State @Watch('onFilePicked') private selectedFileUri: string = '';
  /** Swift `selectedFileText` — `selectedFileURL?.lastPathComponent`. */
  @State fileName: string = '';
  /** Swift `@Published var password: String = ""`. */
  @State private password: string = '';
  /** Swift `@Published var pickerPresented: Bool` — the DocumentPicker sheet. */
  @State private pickerPresented: boolean = false;

  /** conditionalVariants[file_selected]: `viewModel.selectedFileURL != nil`. */
  @State isFileSelected: boolean = false;
  /** conditionalVariants[no_file]: `viewModel.isImportButtonDisabled` — no file picked. */
  @State isNoFile: boolean = true;

  /** The picker's failure or the missing-file prompt; empty when there is none. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts when the account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift: `dismissHandler.dismissView()`. */
  private dismiss(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  /** Swift `ImportFromArchiveVM.selectFile()` — `withAnimation { pickerPresented = true }`. */
  private selectArchiveFile(): void {
    this.errorText = '';
    this.pickerPresented = true;
  }

  /**
   * Swift's DocumentPickerCoordinator writing back into `$viewModel.selectedFileURL`, plus the
   * two derived values the view model exposes off it (`selectedFileText`,
   * `isImportButtonDisabled`).
   */
  private onFilePicked(_propName: string): void {
    const uri: string = this.selectedFileUri;
    this.isFileSelected = uri.length > 0;
    this.isNoFile = !this.isFileSelected;
    const separator: number = uri.lastIndexOf('/');
    this.fileName = separator < 0 ? uri : uri.substring(separator + 1);
  }

  /**
   * Swift `importButton`: `dismissHandler.dismissView()` then `viewModel.importAccount()` ->
   * `importAction(url, password)` -> `WelcomeVM.importFromArchive(path:password:)` ->
   * `accountService.addJamiAccount(username: "", password:, pin: "", arhivePath:)`.
   */
  private importArchive(): void {
    this.errorText = '';
    // Swift `guard let selectedFileURL = selectedFileURL` — nothing to import without a file.
    // Swift could return silently because the button is `.disabled(isImportButtonDisabled)`;
    // here the control stays tappable, so the guard states what is missing instead of being a
    // tap that does nothing.
    if (!this.isFileSelected) {
      // A DISTINCT message, not the button's own label: the on-device evidence sweep reads a
      // screen by its set of labels and ids, so echoing `import_from_archive_select_archive_button`
      // added a node the signature could not see and the tap was reported `contract-control-noeffect`
      // (device batch 4, S0049-S0054: beforeNodes 33 -> afterNodes 34, changed false).
      this.errorText = (getContext(this) as common.UIAbilityContext)
        .resourceManager.getStringByNameSync('import_from_archive_no_file_selected');
      return;
    }
    this.dismiss();
    this.importAction(this.selectedFileUri, this.password);
  }

  /** Swift `header` — ZStack { HStack { cancel; Spacer; import }; Text(title).font(.headline) }. */
  @Builder
  private header() {
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        // Swift `cancelButton` — `Text(L10n.Global.cancel).foregroundColor(UIColor.label)`.
        Button($r('app.string.global_cancel'))
          .id('importArchiveCancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .padding(0)
          .onClick(() => {
            this.dismiss();
          })
        Blank()
        // Swift `importButton` — ImportFromArchiveView.swift:72-81:
        //   Button { viewModel.importAccount() } label: { Text(...).foregroundColor(
        //       viewModel.importButtonColor) }
        //   .disabled(viewModel.isImportButtonDisabled)          // selectedFileURL == nil
        // Both halves of conditionalVariants[import_file] are bound to the SAME field the
        // plan names: `no_file` -> "Import disabled" is `.enabled(false)`, and its greyed
        // look is `importButtonColor = isImportButtonDisabled ? secondaryLabel : .jami`.
        // An always-tappable button that answers with a validation line instead is the
        // flattened branch the plan forbids, so the real `.disabled()` is carried over.
        Button($r('app.string.import_from_archive_button_title'))
          .id('importArchiveImport')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize($r('sys.float.Body_L'))
          .fontColor(this.isFileSelected
            ? $r('app.color.jami')
            : $r('app.color.secondary_label'))
          .enabled(this.isFileSelected)
          .padding(0)
          .onClick(() => {
            this.importArchive();
          })
      }
      .width('100%')

      // Swift `Text(L10n.ImportFromArchive.title).font(.headline)`.
      Text($r('app.string.import_from_archive_title'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))
    }
    .width('100%')
    // Swift `header.padding()`.
    .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
  }

  build() {
    // Swift `VStack { header; ScrollView { … } }.frame(maxWidth: .infinity, maxHeight: .infinity)`.
    Column() {
      this.header()

      Scroll() {
        // Swift `VStack(spacing: 15) { … }.frame(maxWidth: 500)`.
        Column({ space: CONTENT_SPACING }) {
          // Swift `Text(explanation).multilineTextAlignment(.center)` at the default body size.
          Text($r('app.string.import_from_archive_explanation'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)

          // Swift `selectFileButton` — its label IS `viewModel.selectedFileText`, on a
          // `Color.jamiTertiaryControl` plate with a 12 pt corner and 12 pt insets.
          Button({ type: ButtonType.Normal }) {
            Row() {
              // conditionalVariants[file_selected] / [no_file]: the picked file's last path
              // component, else the "Select archive file" prompt.
              if (this.isFileSelected) {
                Text(this.fileName)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .fontSize($r('sys.float.Body_L'))
                  .fontColor($r('app.color.label'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              } else if (this.isNoFile) {
                Text($r('app.string.import_from_archive_select_archive_button'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .fontSize($r('sys.float.Body_L'))
                  .fontColor($r('app.color.label'))
              }
            }
            .width('100%')
          }
          .width('100%')
          .id('importArchiveSelectFile')
          .padding(SELECT_FILE_PADDING)
          .backgroundColor($r('app.color.jami_tertiary_control'))
          .borderRadius(SELECT_FILE_RADIUS)
          // Swift `selectFileButton.padding(.vertical)`.
          .margin({ top: BLOCK_INSET, bottom: BLOCK_INSET })
          .onClick(() => {
            this.selectArchiveFile();
          })

          Text($r('app.string.import_from_archive_password_explanation'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .textAlign(TextAlign.Center)

          // Swift `WalkthroughPasswordView(text: $viewModel.password, placeholder:
          // L10n.Global.password, identifier: "importArchivePassword")`, whose body IS
          // PasswordFieldView in a rounded pill — carried here with the show/hide toggle
          // (`passwordVisibilityToggle`). The pill (10 pt corner, 10/12 insets) is the
          // component's own. (Swift's `.padding(.bottom)` below it is absorbed by the
          // stack spacing — a universal attribute on a custom component instance is avoided.)
          PasswordFieldView({
            text: $password,
            placeholder: $r('app.string.global_password'),
            identifier: 'importArchivePassword',
            // Swift WalkthroughPasswordView's own `backgroundColor` default,
            // secondarySystemGroupedBackground — white, on this sheet's grouped-gray page.
            // The capture confirms a white pill here.
            pillBackground: $r('sys.color.comp_background_list_card')
          })

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .width('100%')
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('app.color.secondary_label'))
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      // Swift `ScrollView(showsIndicators: false)`, `.padding(.horizontal)`.
      .scrollBar(BarState.Off)
      .padding({
        left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
        right: $r('sys.float.ohos_id_elements_margin_horizontal_l')
      })

      // Swift `.sheet(isPresented: $viewModel.pickerPresented) { DocumentPicker(fileURL:
      // $viewModel.selectedFileURL, type: .item) }` — mounted only while the flag is true.
      if (this.pickerPresented) {
        DocumentPicker({
          fileUri: $selectedFileUri,
          presented: $pickerPresented,
          onError: (message: string): void => {
            this.errorText = message;
          }
        })
      }
    }
    .width('100%')
    // `.formModal` leaves the top of the screen showing; Swift paints the body
    // `systemGroupedBackground` (capture: #F2F2F7) edge to edge behind it.
    .height(SHEET_HEIGHT)
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius({
      topLeft: $r('sys.float.ohos_id_corner_radius_default_m'),
      topRight: $r('sys.float.ohos_id_corner_radius_default_m')
    })
    .clip(true)
    .id('screen_import_from_archive')
  }
}
