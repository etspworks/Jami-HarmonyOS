/*
 * screen_backup_account — "Backup Account", ported from
 *   Ring/Ring/Features/Settings/Me/BackupAccount.swift
 *   Ring/Ring/Features/Settings/Me/BackupAccountModel.swift
 *   Ring/Ring/UI/SwiftUIViews/DocumentPicker.swift
 *
 * presentation: page. ManageAccountView reaches it with a NavigationLink, so it is an @Entry
 * page pushed from ManageAccountPage; Back is the platform affordance, composed here because an
 * @Entry router page draws no system chrome (controlInventory's `implicit: true /
 * affordance: back` entry, hence `.id('back')`).
 *
 * S3 — the real tree of `BackupAccount.body`:
 *   ScrollView { VStack { Text(explanation); contentBasedOnModelState(); Spacer } }
 *     .sheet(isPresented: $presentDocumentPicker) { DocumentPicker(fileURL: $filePath,
 *                                                                 type: .folder) }
 *
 *   contentBasedOnModelState() switches on BackupAccountModel.state:
 *     .loading        -> Text(creating) + ProgressView
 *     .error(msg)     -> Text(msg) in jamiFailure
 *     .success(msg)   -> "checkmark" glyph + Text(msg) in jamiSuccess
 *     .idle           -> mainContentView()
 *
 *   mainContentView() is itself a branch on `filePath != nil`:
 *     filePath == nil -> selectLocationButton()          "backup_account_choose_location"
 *     filePath != nil -> archiveNameSection()            "backup_account_archive_name"
 *                        if model.hasPassword() {
 *                          passwordFieldsSection()       "backup_account_password"
 *                        }
 *                        backupButton()                  "backup_account_export"
 *
 * FOLDER (T-1621). Where the device has a folder picker (FolderSelection, checked at run time),
 * "Open backup location" raises it in FOLDER mode as iOS does, and Backup copies the archive into
 * the picked folder. Otherwise, or when that folder cannot be written, the port keeps T-1605's
 * folder: the app's own Download/<app>, which the DOWNLOAD-mode save picker hands back with no
 * UI, shown in place of the button. Either way nothing is created before Backup (T-1605).
 *
 * conditionalVariants: [encrypted_account] `isEncryptedAccount` — `model.hasPassword()`, the
 * password section; [exported] `isExported` — the checkmark confirmation.
 *
 * bindingContract: `archive name` <- @State fileName, bound to what the user actually entered,
 * never a literal from the capture.
 *
 * DAEMON GAP (Rule 11). `exportToFileWithPassword` is jami-daemon work with no HarmonyOS
 * build. Export keeps its place, runs the source's own guards first (no folder / empty path),
 * builds the real destination path, calls the real service and SURFACES the gap through
 * `DaemonService.unavailableEvents` — the screen's own error state, which is exactly where the
 * source puts `.exportFailed`. It never returns silently and never fakes a success.
 */
// `focusControl` is a global ArkUI namespace (ets/component/common.d.ts) — not a @kit.ArkUI export.
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { describeError } from '../common/ErrorText';
import { PasswordFieldView } from '../components/PasswordField';
import { AccountModelHelper } from '../common/AccountModelHelper';
import { AccountsService } from '../common/AccountsService';
import { DaemonService, DaemonUnavailableError } from '../common/DaemonService';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { BackChevron } from '../components/BackButton';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'BackupAccount';

/** Swift `let archiveName = fileName + ".jac"` (BackupAccountModel.swift:86). */
const ARCHIVE_SUFFIX: string = '.jac';
/** libjami's scratch file next to the archive; renamed over it once complete (T-0596). */
const TEMP_SUFFIX: string = '.tmp';
/** The archive name when the field is left empty (Swift would write a hidden ".jac"). */
const DEFAULT_ARCHIVE_NAME: string = 'jami_backup';
/** Where the user finds the folder in Files: its path from here on. */
const DOWNLOAD_DIR: string = 'Download';
/** A picked folder's path down to the user's root in Files ("Download/…", "Documents/…"). */
const USER_ROOT: string = '/currentUser/';
/** The syscap of `DocumentSelectMode.FOLDER`. */
const FOLDER_SELECTION: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';
/** hilog tag of the F4 device checks (T-1621). */
const F4_TAG: string = 'JamiF4';
/** Swift `private let cornerRadius: CGFloat = 12`. */
const FIELD_RADIUS: number = 12;
/** Swift `private let horizontalPadding: CGFloat = 10` / `verticalPadding: CGFloat = 12`. */
const FIELD_PADDING_H: number = 10;
const FIELD_PADDING_V: number = 12;
/** Swift's bare `.padding(.horizontal)`. */
const PAGE_INSET: number = 16;
/** SwiftUI's default VStack spacing between the explanation and the state content. */
const VSTACK_SPACING: number = 8;
/** Swift `backupButton().padding(.vertical, 25)`. */
const BUTTON_GAP: number = 25;
/** Swift `Image(systemName: "checkmark") … .frame(height: 40)`. */
const SUCCESS_GLYPH_SIZE: number = 40;
/** Swift `loadingView()` — `VStack(spacing: 20)`. */
const LOADING_SPACING: number = 20;
/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/** ManageAccountView is what pushed this page — the coordinator root a cold deep link lacks. */
const MANAGE_ACCOUNT_PAGE: string = 'pages/ManageAccountPage';

/* ── S5 metrics (capture S0234, S0235, S0256, S0259) ──────────────────────────────────────
 * A pushed page on the plain (NOT grouped) system background: the inline bar with iOS's own
 * navy back item, the explanation as a left-aligned body paragraph at the page inset, and ONE
 * filled full-width action on jamiTertiaryControl. Sizes and colours are the semantic roles,
 * except the two state colours the source spells itself.
 */
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/** iOS filled action-button height inside a form body. */
const BUTTON_HEIGHT: number = 44;
/** Swift `Color.jamiSuccess` — UIColor+Ring.swift:98, `0x00b20b`. */
const JAMI_SUCCESS: string = '#00B20B';
/** Swift `Color.jamiFailure` — UIColor+Ring.swift:99, `0xf00000`. */
const JAMI_FAILURE: string = '#F00000';

@Entry
@Component
struct BackupAccountPage {
  /** bindingContract[archive name]: archiveFileName <- Swift `@State private var fileName`. */
  @State archiveName: string = '';
  /** Swift's `DocumentPicker(type: .folder)` exists here: the device has the folder picker. */
  @State canPickFolder: boolean = canIUse(FOLDER_SELECTION);
  /** Swift `filePath` when it was picked: the folder's URI, empty until then. */
  @State folderUri: string = '';
  /** Why the archive went to Download/<app> rather than where the user asked; empty otherwise. */
  @State fallbackNotice: ResourceStr = '';
  /** The folder picker is up: one gesture raises it once. */
  private picking: boolean = false;
  /**
   * Swift `@State private var filePath: URL?`, as a path: the app's Download/<app> folder
   * (resolveFolder), empty until the picker has handed it back.
   */
  private folderPath: string = '';
  /** That folder as shown on the screen, "Download/<app>". */
  @State location: string = '';
  /** The written archive as shown with the confirmation, "Download/<app>/<name>.jac". */
  @State savedPath: string = '';
  /** Swift `@State private var password` — filled only when the account is encrypted. */
  @State private password: string = '';

  /** conditionalVariants[encrypted_account]: Swift `model.hasPassword()`. */
  @State isEncryptedAccount: boolean = false;
  /** conditionalVariants[exported]: Swift `state == .success(message)`. */
  @State isExported: boolean = false;
  /** Swift `state == .loading` — true while svc_accounts is in flight. */
  @State isLoading: boolean = false;
  /** Swift `state == .error(message)` — describeError()/the model's own displayMessage. */
  @State errorText: string = '';
  /** Swift `.success(message)` — `L10n.BackupAccount.exportSuccess`. */
  @State private successText: ResourceStr = '';

  /** AppStorage['currentAccountId'] — svc_accounts' current account. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** The daemon-gap subscription. */
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    this.refreshHasPassword();
    this.observeDaemonGap(ServiceRegistry.shared().daemonService);
    hilog.info(LOG_DOMAIN, F4_TAG, 'backup: FolderSelection=%{public}s', String(this.canPickFolder));
    if (!this.canPickFolder) {
      this.showDownloadFolder();
    }
  }

  /** Only to show the folder; a failure is said again, on the screen, by Backup. */
  private showDownloadFolder(): void {
    this.resolveFolder().catch((error: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'download folder failed: %{public}s', describeError(error));
    });
  }

  /**
   * Swift `selectLocationButton()` -> `DocumentPicker(fileURL: $filePath, type: .folder)`. A
   * cancelled picker leaves the screen as it was; a picker that fails falls back to Download.
   */
  private chooseLocation(): void {
    if (this.picking) {
      return;
    }
    this.picking = true;
    this.errorText = '';
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    if (canIUse(FOLDER_SELECTION)) {
      options.selectMode = picker.DocumentSelectMode.FOLDER;
    }
    new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext).select(options)
      .then((uris: string[]): void => {
        hilog.info(LOG_DOMAIN, F4_TAG, 'backup: folder picked %{public}s',
          uris.length > 0 ? uris[0] : '(cancelled)');
        if (uris.length > 0) {
          this.folderUri = uris[0].endsWith('/') ? uris[0].slice(0, -1) : uris[0];
          const path: string = new fileUri.FileUri(this.folderUri).path;
          const at: number = path.indexOf(USER_ROOT);
          this.location = at < 0 ? path : path.substring(at + USER_ROOT.length);
        }
      })
      .catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, F4_TAG, 'backup: folder picker failed, using Download: %{public}s',
          describeError(error));
        this.canPickFolder = false;
        this.fallbackNotice = describeError(error);
        this.showDownloadFolder();
      })
      .finally((): void => {
        this.picking = false;
      });
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription goes whatever happens on the way out.
    this.bag.dispose();
  }

  /**
   * The disclosed gap: `account.exportToFile` reports on the daemon's app-wide channel, and
   * the notice lands in the screen's OWN error state — where the source puts `.exportFailed`.
   */
  private observeDaemonGap(daemon: DaemonService): void {
    this.bag.add(daemon.unavailableEvents.subscribe((_error: DaemonUnavailableError): void => {
      this.isLoading = false;
      this.isExported = false;
      this.errorText = this.resolve('daemon_not_available');
    }));
  }

  /** Swift `BackupAccountModel.hasPassword()` — `AccountModelHelper(withAccount:).hasPassword`. */
  private refreshHasPassword(): void {
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(this.currentAccountId);
    if (account === null) {
      this.isEncryptedAccount = false;
      return;
    }
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    const helper: AccountModelHelper = new AccountModelHelper(
      details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
    this.isEncryptedAccount = helper.hasPassword;
  }

  /**
   * Swift `TextField(...)` becoming first responder when its row is tapped: the caption and
   * the field are one control, so a tap on either puts the caret in the field.
   */
  private focusArchiveName(): void {
    focusControl.requestFocus('backup_account_archive_name');
  }

  /**
   * Swift's `filePath`, which the port does not ask for (see the header): the save picker's
   * DOWNLOAD mode shows no UI and hands back the app's Download/<app> folder, the one public
   * folder the app may write by path. Nothing is created in it here.
   */
  private async resolveFolder(): Promise<string> {
    if (this.folderPath.length === 0) {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const uris: string[] =
        await new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext).save(options);
      if (uris.length > 0) {
        const path: string = new fileUri.FileUri(uris[0]).path;
        this.folderPath = path.endsWith('/') ? path.slice(0, -1) : path;
        const at: number = this.folderPath.indexOf(DOWNLOAD_DIR);
        this.location = at < 0 ? this.folderPath : this.folderPath.substring(at);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'backup folder %{public}s', this.folderPath);
      }
    }
    return this.folderPath;
  }

  // ── handlers — every controlInventory entry, wired to its Swift effect ─────────────────
  /**
   * Swift `backupButton()` — `model.exportToFile(filePath:fileName:password:)`, whose own
   * guards run BEFORE the daemon call: `.invalidFilePath` when there is no folder, then the
   * archive name, then the export itself.
   */
  private exportArchive(): void {
    this.errorText = '';
    this.isExported = false;
    if (this.folderUri.length > 0 && this.currentAccountId.length > 0 &&
      this.writeIntoPickedFolder(this.currentAccountId)) {
      return;
    }
    this.resolveFolder()
      .then((folder: string): void => {
        // Swift `guard let filePath = filePath, !filePath.absoluteURL.path.isEmpty else
        // { handleError(.invalidFilePath) }`.
        if (folder.length === 0) {
          this.errorText = this.resolve('backup_account_error_wrong_location');
          return;
        }
        const accountId: string = this.currentAccountId;
        if (accountId.length === 0) {
          // No account selected: there is nothing to export, and Swift's own nearest error is
          // the access failure. Said, never swallowed.
          this.errorText = this.resolve('backup_account_error_access_denied');
          hilog.error(LOG_DOMAIN, LOG_TAG, 'export with no current account');
          return;
        }
        this.writeArchive(accountId, folder);
      })
      .catch((error: BusinessError): void => {
        this.errorText = describeError(error);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'download folder failed: %{public}s', this.errorText);
      });
  }

  /**
   * Swift `let archiveName = fileName + ".jac"; let finalUrl =
   * filePath.appendingPathComponent(archiveName)`, with Swift's success and `.exportFailed` states.
   */
  private writeArchive(accountId: string, folder: string): void {
    const name: string = this.archiveFileName();
    this.isLoading = true;
    try {
      // Daemon-backed: it reports on `DaemonService.unavailableEvents`, which
      // `observeDaemonGap` renders into `errorText`.
      // feat_account_archive lives in AccountsService — named here rather than reached
      // anonymously through the registry, so this screen's own wiring carries the evidence.
      const accounts: AccountsService = ServiceRegistry.shared().accountService;
      if (!this.exportReplacing(accounts, accountId, folder + '/' + name)) {
        // Swift `handleError(.exportFailed)`. The gap subscription may already have written a
        // more specific notice; this is the source's own text when it has not.
        if (this.errorText.length === 0) {
          this.errorText = this.resolve('backup_account_error_failed');
        }
        return;
      }
      // Swift `handleSuccess()` -> `.success(L10n.BackupAccount.exportSuccess)`, and where it went.
      this.successText = $r('app.string.backup_account_export_success');
      this.savedPath = this.location + '/' + name;
      this.isExported = true;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Swift overwrites an archive of the same name. libjami's `copy_file(overwrite_existing)` cannot
   * do that in the public Download folder (the existing file belongs to the file manager, not to
   * the app), so libjami writes a NEW file next to it, which then replaces the old archive: the
   * user's previous backup stays untouched until a complete new one exists (T-0596).
   */
  private exportReplacing(accounts: AccountsService, accountId: string, destination: string): boolean {
    const temp: string = destination + TEMP_SUFFIX;
    // A stale scratch file from an interrupted export would hit the same overwrite failure.
    BackupAccountPage.removeIfPresent(temp);
    try {
      if (!accounts.exportToFileWithPassword(accountId, temp, this.password)) {
        return false;
      }
      fileIo.renameSync(temp, destination);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'archive written to %{public}s', destination);
      return true;
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replacing %{public}s failed: %{public}s', destination,
        describeError(error as BusinessError));
      return false;
    } finally {
      // Gone already after a successful rename; on every failure path it must not linger.
      BackupAccountPage.removeIfPresent(temp);
    }
  }

  private archiveFileName(): string {
    return (this.archiveName.length > 0 ? this.archiveName : DEFAULT_ARCHIVE_NAME) + ARCHIVE_SUFFIX;
  }

  /**
   * Swift `filePath.appendingPathComponent(name)` in the PICKED folder. libjami writes a path and
   * the folder is reachable only through its URI, so the archive is built in the cache and its
   * bytes copied into <folder>/<name>: nothing is created there unless the export worked. True
   * when this settled the Backup (written, or the export itself failed); false when the folder
   * could not be written, and the caller then falls back to Download/<app>, saying so.
   */
  private writeIntoPickedFolder(accountId: string): boolean {
    const name: string = this.archiveFileName();
    const scratch: string = getContext(this).cacheDir + '/' + name;
    // A picked folder grants its path, not a creatable URI: fileIo.openSync(<folder uri>/<name>,
    // CREATE) fails 'No such file or directory' on the BRA-AL00 (T-1621 review), the path works.
    const target: string = new fileUri.FileUri(this.folderUri).path + '/' + name;
    BackupAccountPage.removeIfPresent(scratch);
    this.isLoading = true;
    let created: boolean = false;
    try {
      if (!ServiceRegistry.shared().accountService.exportToFileWithPassword(accountId, scratch, this.password)) {
        if (this.errorText.length === 0) {
          this.errorText = this.resolve('backup_account_error_failed');
        }
        return true;
      }
      const file: fileIo.File = fileIo.openSync(target,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      created = true;
      try {
        fileIo.copyFileSync(scratch, file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(LOG_DOMAIN, F4_TAG, 'backup: archive written to %{public}s', target);
      this.successText = $r('app.string.backup_account_export_success');
      this.savedPath = this.location + '/' + name;
      this.isExported = true;
      return true;
    } catch (error) {
      hilog.error(LOG_DOMAIN, F4_TAG, 'backup: writing %{public}s failed, using Download: %{public}s',
        target, describeError(error as BusinessError));
      if (created) {
        // ponytail: best effort; outside its sandbox the app may not be allowed to unlink (T-1605).
        BackupAccountPage.removeIfPresent(target);
      }
      this.fallbackNotice = $r('app.string.backup_account_error_access_denied');
      return false;
    } finally {
      BackupAccountPage.removeIfPresent(scratch);
      this.isLoading = false;
    }
  }

  private static removeIfPresent(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'removing %{public}s failed: %{public}s', path,
        describeError(error as BusinessError));
    }
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: MANAGE_ACCOUNT_PAGE }).catch((error: Error): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s',
          MANAGE_ACCOUNT_PAGE, error.message);
      });
      return;
    }
    router.back();
  }

  /** A localized string resolved to plain text, for the one inline failure slot. */
  private resolve(name: string): string {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringByNameSync(name);
  }

  // ── builders ──────────────────────────────────────────────────────────────────────────
  /**
   * Swift `.navigationTitle(L10n.BackupAccount.title).navigationBarTitleDisplayMode(.inline)`
   * with iOS's own leading back item. Its label would be the origin page's title ("Manage
   * account"), but that does not fit beside "Backup account", so UINavigationBar falls back to
   * "Back" — what the iPhone shows (TC-ACCOUNT-246).
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // `.navigationBarTitleDisplayMode(.inline)` — centred and semibold.
      Text($r('app.string.backup_account_title'))
        .width('100%')
        .height(BAR_HEIGHT)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.label'))

      // iOS's leading back item: the chevron and the origin page's title, both in the app tint.
      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text($r('app.string.actions_back_action'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
  }

  /** Swift `archiveNameSection()` — the label over the styled TextField. */
  @Builder
  private archiveNameSection() {
    // "Archive name" is the contracted control: the caption and its field, as one tappable
    // container. Rule 12 keeps the SOURCE slug on the field itself.
    Column() {
      Column() {
        Text($r('app.string.backup_account_archive_name'))
          .width('100%')
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
        TextInput({
          placeholder: $r('app.string.backup_account_archive_name_placeholder'),
          text: $$this.archiveName
        })
          .id('backup_account_archive_name')
          .enableKeyboardOnFocus(true)
          // Swift `.disableAutocorrection(true).autocapitalization(.none)`.
          .enableAutoFill(false)
          .width('100%')
          .padding({
            top: FIELD_PADDING_V,
            bottom: FIELD_PADDING_V,
            left: FIELD_PADDING_H,
            right: FIELD_PADDING_H
          })
          .borderRadius(FIELD_RADIUS)
          // Swift `.background(Color.jamiFormBackground)` — the app's own form fill.
          .backgroundColor($r('app.color.jami_form_background'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .placeholderColor($r('app.color.placeholder_text'))
          .placeholderFont({ size: $r('sys.float.Body_L') })
          .margin({ top: $r('sys.float.padding_level4') })
          .onChange((value: string) => {
            this.archiveName = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .id('archive-name')
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.focusArchiveName();
    })
  }

  /**
   * Swift `passwordFieldsSection()` — the request label over `PasswordFieldView(text:
   * $password, placeholder: L10n.Global.enterPassword, identifier: "backup_account_password")`.
   */
  @Builder
  private passwordFieldsSection() {
    Column() {
      Text($r('app.string.backup_account_password_request'))
        .width('100%')
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
      PasswordFieldView({
        text: $password,
        placeholder: $r('app.string.global_enter_password'),
        identifier: 'backup_account_password'
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: PAGE_INSET })
  }

  /**
   * The folder the archive goes to (picked, or Download/<app> where there is no folder picker),
   * so the user knows where to find it in Files.
   */
  @Builder
  private locationRow() {
    Row({ space: BACK_GLYPH_GAP }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor([$r('app.color.label')])
      Text(this.location)
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
    }
    .id('backup_account_location')
    .width('100%')
    .padding({
      top: FIELD_PADDING_V,
      bottom: FIELD_PADDING_V,
      left: FIELD_PADDING_H,
      right: FIELD_PADDING_H
    })
    .borderRadius(FIELD_RADIUS)
    .backgroundColor($r('app.color.jami_form_background'))
    .margin({ bottom: PAGE_INSET })
  }

  /** Why the archive goes to Download/<app> instead of the picked folder (T-1621). */
  @Builder
  private fallbackNoticeText() {
    Text(this.fallbackNotice)
      .id('backupAccountFallbackNotice')
      .width('100%')
      .fontSize($r('sys.float.Body_M'))
      .fontColor(JAMI_FAILURE)
      .margin({ bottom: PAGE_INSET })
  }

  /**
   * Swift `mainContentView()`: `filePath == nil` -> `selectLocationButton()`, else the form. With
   * no folder picker the folder is the app's own, so there is nothing to pick first.
   */
  @Builder
  private mainContentView() {
    if (this.canPickFolder && this.folderUri.length === 0) {
      // Swift `selectLocationButton().padding(.vertical, 5)`, `.commonButtonStyle()`.
      Button($r('app.string.backup_account_document_picker_button'))
        .id('backup_account_choose_location')
        .type(ButtonType.Normal)
        .width('100%')
        .height(BUTTON_HEIGHT)
        .borderRadius(FIELD_RADIUS)
        .backgroundColor($r('app.color.jami_tertiary_control'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .margin({ top: 5, bottom: 5 })
        .onClick(() => {
          this.chooseLocation();
        })
    } else {
      Column() {
        if (this.location.length > 0) {
          this.locationRow()
        }
        if (this.fallbackNotice !== '') {
          this.fallbackNoticeText()
        }

        this.archiveNameSection()

        // conditionalVariants[encrypted_account]: `if model.hasPassword()`.
        if (this.isEncryptedAccount) {
          this.passwordFieldsSection()
        }

        // Swift `backupButton().padding(.vertical, 25)`.
        // Swift `.commonButtonStyle()` — filled on jamiTertiaryControl, label in the ordinary
        // text colour, which is what the capture's "Open backup location" twin shows.
        Button($r('app.string.backup_account_backup_button'))
          .id('backup_account_export')
          .type(ButtonType.Normal)
          .width('100%')
          .height(BUTTON_HEIGHT)
          .borderRadius(FIELD_RADIUS)
          .backgroundColor($r('app.color.jami_tertiary_control'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.label'))
          .margin({ top: BUTTON_GAP, bottom: BUTTON_GAP })
          .onClick(() => {
            this.exportArchive();
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** Swift `successView(_:)` — `Image(systemName: "checkmark")` over the message. */
  @Builder
  private successView() {
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(SUCCESS_GLYPH_SIZE)
        // Swift `.foregroundColor(Color.jamiSuccess)` on both the glyph and the message.
        .fontColor([JAMI_SUCCESS])
      Text(this.successText)
        .id('backupAccountSuccess')
        .textAlign(TextAlign.Center)
        // Swift `.font(.title)` on the confirmation message — the title role, not body.
        .fontSize($r('sys.float.Title_S'))
        .fontColor(JAMI_SUCCESS)
        .margin({ top: $r('sys.float.padding_level4') })
      // Where the archive went (T-1605), and why when it is not the picked folder (T-1621).
      Text(this.savedPath)
        .id('backupAccountSavedPath')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .margin({ top: $r('sys.float.padding_level4') })
      if (this.fallbackNotice !== '') {
        Text(this.fallbackNotice)
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_M'))
          .fontColor(JAMI_FAILURE)
          .margin({ top: $r('sys.float.padding_level4') })
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      this.navigationBar()

      // Swift `ScrollView { VStack { Text(explanation); contentBasedOnModelState(); Spacer } }`.
      Scroll() {
        Column({ space: VSTACK_SPACING }) {
          Text($r('app.string.backup_account_explanation'))
            .width('100%')
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            .margin({ top: PAGE_INSET, bottom: PAGE_INSET })

          // Swift `contentBasedOnModelState()` — the four-way switch on `model.state`.
          if (this.isLoading) {
            // Swift `loadingView()` — Text(creating) + ProgressView.
            Column({ space: LOADING_SPACING }) {
              Text($r('app.string.backup_account_creating'))
                .textAlign(TextAlign.Center)
                // Swift `.font(.headline)` — body size at the semibold weight.
                .fontSize($r('sys.float.Body_L'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.label'))
              LoadingProgress()
                .width(SUCCESS_GLYPH_SIZE)
                .height(SUCCESS_GLYPH_SIZE)
                .color($r('sys.color.font_secondary'))
            }
            .id('backupAccountLoading')
            .width('100%')
          } else if (this.errorText.length > 0) {
            // Swift `errorView(_:)` — the message in jamiFailure.
            // Swift `errorView(_:)` puts the message in jamiFailure.
            Text(this.errorText)
              .id('backupAccountError')
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_L'))
              .fontColor(JAMI_FAILURE)
          } else if (this.isExported) {
            // conditionalVariants[exported].
            this.successView()
          } else {
            this.mainContentView()
          }

          Blank()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: PAGE_INSET, right: PAGE_INSET })
      }
      .width('100%')
      .layoutWeight(1)
      // A Scroll centres content shorter than itself; SwiftUI's ScrollView starts it at the top.
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    // Swift `.background(Color(UIColor.systemBackground))`.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_backup_account')
  }
}
