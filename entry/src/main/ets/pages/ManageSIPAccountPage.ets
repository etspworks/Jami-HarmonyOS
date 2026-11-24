/*
 * screen_manage_sip_account — "Manage SIP Account", ported from
 *   Ring/Ring/Features/Settings/Me/ManageSipAccountView.swift
 *   Ring/Ring/Features/Settings/Me/SipAccountDetailModel.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (FieldRowView / EditableFieldView)
 *
 * presentation: page. AccountSummaryView reaches it with a NavigationLink for an account of
 * type .sip, so it is an @Entry page pushed from AccountSummarySettingsRootPage. An @Entry
 * router page draws no system chrome, so iOS's inline bar and its leading "< Account" back item
 * are composed here, as the sibling ManageAccountPage does (T-0516).
 *
 * NO CAPTURED STATE: the gallery declared this screen uncapturable (the seeded account is a
 * local Jami account), so its structure comes from the source only.
 *
 * S3 — `ManageSipAccountView.body`:
 *   Form {
 *     Section(header: Text(L10n.AccountPage.accountIdentity)) {
 *       NavigationLink(EditableFieldView($model.username))  { FieldRowView(username) }
 *       NavigationLink(EditableFieldView($model.server))    { FieldRowView(sipServer) }
 *       NavigationLink(EditPasswordView($model.password))   { FieldRowView(password.masked) }
 *       NavigationLink(EditableFieldView($model.proxy))     { FieldRowView(proxyServer) }
 *       NavigationLink(EditableFieldView($model.port))      { FieldRowView(port) }
 *     }
 *     Section { Button(L10n.Global.removeAccount).alert(isPresented: $showRemovalAlert) }
 *   }
 *
 * Each row is a NavigationLink around FieldRowView: label, the CURRENT value off svc_accounts
 * in secondary grey (wrapping, never truncated — the 4.20 iPhone wraps a long server onto a
 * second line), and the disclosure chevron iOS draws for a NavigationLink, with a grouped
 * separator inset to the label between sibling rows (T-0516).
 *
 * comp_editable_field (EditableFieldView) is the source's own single-field editor. iOS PUSHES
 * it from each NavigationLink as a screen of its own ("< Back   Edit Server", the field focused
 * with the keyboard up). Here it is that screen drawn as a full-page layer over this one, with
 * its own bar, so no route is needed; the device Back key and the bar's back item both close it,
 * and closing it fires the component's `onDisappearAction` -> `updateSipSettings()` write-back
 * exactly as the Swift `.onDisappear` does. The Password row pushes screen_edit_password, as the
 * source does.
 */
import { router } from '@kit.ArkUI';
// `focusControl` is a global ArkUI namespace (components/FocusableTextField.ets).
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { describeError } from '../common/ErrorText';
import { AccountModel } from '../model/AccountModel';
import { AccountConfigModel } from '../model/AccountConfigModel';
import { AccountCredentialsModel } from '../model/AccountCredentialsModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { EditableFieldView } from '../components/EditableField';
import { LengthMetrics } from '@kit.ArkUI';
import { BackChevron } from '../components/BackButton';

/* ── S5 tokens — the source is an iOS inset-grouped `Form`, so it is composed explicitly,
 * with the same metrics as the sibling pages/ManageAccountPage.ets ── */
/** iOS grouped-row minimum height, and the inline navigation bar's. */
const GROUPED_ROW_MIN_HEIGHT: number = 44;
/** The grouped separator's inset — the row's own leading padding (padding_level10). */
const SEPARATOR_INSET: number = 20;
/** iOS's gap between two grouped sections. */
const GROUPED_SECTION_GAP: number = 35;
/** SwiftUI HStack's default spacing, between a row's label and its value. */
const ROW_LABEL_GAP: number = 8;
/** The disclosure chevron iOS draws for a NavigationLink. */
const CHEVRON_SIZE: number = 14;
/** The gap between the leading back item's chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/**
 * Swift FocusableTextField.updateUIView: "Wait untill view shows" — becomeFirstResponder after
 * 0.5 s, which is what raises the keyboard on the pushed editor.
 */
const EDITOR_FOCUS_DELAY_MS: number = 500;
/** The editor layer slides in from the trailing edge, as a pushed screen does. */
const EDITOR_TRANSITION_MS: number = 250;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back". The 4.20 iPhone (390 pt) drops "< Manage account" beside
 * "Edit Port" with 2 pt clear and keeps "< Account" beside "Manage account" with 35 pt clear; the
 * port's narrower font leaves Edit Port 9.5 vp clear on the review device, so it sits above that
 * (T-1611). ponytail: one margin calibrated off the iPhone; tune here if a locale disagrees.
 */
const BACK_FIT_MARGIN: number = 16;
/** The page AccountSummaryView pushes this one from — iOS's back item carries its title. */
const ACCOUNT_SUMMARY_PAGE: string = 'pages/AccountSummarySettingsRootPage';
/** Swift `Color.jamiFailure` (UIColor+Ring.swift), the remove label's colour. */
const DESTRUCTIVE_RED: string = '#F00000';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ManageSIPAccountPage';

/** Swift `SipAccountDetailModel`'s editable fields, as the row identities. */
enum SipField {
  NONE = '',
  USERNAME = 'username',
  SERVER = 'server',
  PROXY = 'proxy',
  PORT = 'port'
}

@Entry
@Component
struct ManageSIPAccountPage {
  /**
   * bindingContract[field values] <- svc_accounts. Swift `SipAccountDetailModel` reads the
   * account's OWN detail map and writes it back; the five @State strings below are the
   * editable views onto it, exactly as the source's @Published fields are.
   */
  @State fieldValues: AccountConfigModel | null = null;
  /** bindingContract[field values] <- svc_accounts (AccountConfigModel SIP credentials). */
  @State username: string = '';
  @State server: string = '';
  @State password: string = '';
  @State proxy: string = '';
  @State port: string = '';
  /** The field whose EditableFieldView screen is open; NONE when none is. */
  @State editingField: SipField = SipField.NONE;
  /** Swift `$model.<field>` — the binding the open editor types into. */
  @State editValue: string = '';
  /** The field the open editor writes back to; kept past close for `onDisappearAction`. */
  private editedField: SipField = SipField.NONE;
  /** True while svc_accounts is in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** Written by svc_accounts when the current account changes. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /**
   * The SIP account this page was opened for. Every read and write stays on it, so a switch of
   * the current account while the page or its editor is open cannot pour the new account's
   * details into this one on the next onPageShow (T-1632).
   */
  private pageAccountId: string = '';
  /** The editor bar, its title and its back item, measured for the back label's fit (T-1611). */
  @State private editorBarWidth: number = 0;
  @State private editorTitleWidth: number = 0;
  /** The back item's width while it still reads "Manage account", kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;

  aboutToAppear(): void {
    this.pageAccountId = this.currentAccountId;
  }

  /**
   * Swift `SipAccountDetailModel.init` — every field is read off the account's own maps. Re-read
   * on every show: EditPasswordView is a pushed page that writes the credentials itself.
   */
  onPageShow(): void {
    this.isLoading = true;
    try {
      const account: AccountModel | null = this.account();
      if (account === null) {
        return;
      }
      const details: AccountConfigModel | null = account.details;
      if (details === null) {
        // Swift `guard let details = account.details ... else { return }`.
        return;
      }
      this.fieldValues = details;
      const credentials: AccountCredentialsModel | undefined = account.credentialDetails[0];
      if (credentials !== undefined) {
        this.username = credentials.username;
        this.password = credentials.password;
      } else {
        // No credentials came back from the daemon; it mirrors the SIP username in the detail
        // map, so the row still shows it.
        this.username = details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_USERNAME));
      }
      this.server = details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_HOSTNAME));
      this.port = details.get(new ConfigKeyModel(ConfigKey.LOCAL_PORT));
      this.proxy = details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_ROUTE_SET));
      this.errorText = '';
    } catch (error) {
      this.errorText = describeError(error as BusinessError);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load failed: %{public}s', this.errorText);
    } finally {
      this.isLoading = false;
    }
  }

  private account(): AccountModel | null {
    return ServiceRegistry.shared().accountService.getAccount(this.pageAccountId);
  }

  /** Swift `model.password.maskedPassword` — the row never shows the password itself. */
  private maskedPassword(): string {
    let masked: string = '';
    for (let index: number = 0; index < this.password.length; index++) {
      masked = masked + '•';
    }
    return masked;
  }

  /**
   * Swift `NavigationLink -> EditPasswordView($model.password, onDisappearAction:
   * updateSipSettings)`: the page's SIP mode edits the credential's password and writes it with
   * `setAccountCrdentials`.
   */
  private openEditPassword(): void {
    router.pushUrl({
      url: 'pages/EditPasswordFieldPage',
      params: { configKey: String(ConfigKey.ACCOUNT_PASSWORD), accountId: this.pageAccountId }
    }).catch((error: Error): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'pushUrl failed: %{public}s', error.message);
    });
  }

  /** Swift: the four `NavigationLink(destination: EditableFieldView(value: $model.<field>))`. */
  private editField(field: SipField): void {
    this.editValue = this.fieldValue(field);
    this.editedField = field;
    this.editingField = field;
    setTimeout((): void => {
      focusControl.requestFocus('editable_field_value');
    },
      EDITOR_FOCUS_DELAY_MS);
  }

  /** The editor's back item / the device Back key: pop the editor, which saves. */
  private closeEditor(): void {
    this.editingField = SipField.NONE;
  }

  /** The device Back key pops the editor first, then this page. */
  onBackPress(): boolean {
    if (this.editingField === SipField.NONE) {
      return false;
    }
    this.closeEditor();
    return true;
  }

  /** EditableFieldView's `onDisappearAction`: the binding lands, then `updateSipSettings()`. */
  private commitEdit(): void {
    switch (this.editedField) {
      case SipField.USERNAME:
        this.username = this.editValue;
        break;
      case SipField.SERVER:
        this.server = this.editValue;
        break;
      case SipField.PROXY:
        this.proxy = this.editValue;
        break;
      case SipField.PORT:
        this.port = this.editValue;
        break;
      default:
        return;
    }
    this.editedField = SipField.NONE;
    this.updateSipSettings();
  }

  private fieldValue(field: SipField): string {
    switch (field) {
      case SipField.USERNAME:
        return this.username;
      case SipField.SERVER:
        return this.server;
      case SipField.PROXY:
        return this.proxy;
      default:
        return this.port;
    }
  }

  /**
   * Swift `SipAccountDetailModel.updateSipSettings()`, verbatim in shape: nothing to do when
   * nothing changed; the credentials go back through `setAccountCrdentials` and the detail map
   * through `setAccountDetails`, both against svc_accounts.
   */
  private updateSipSettings(): void {
    const account: AccountModel | null = this.account();
    const details: AccountConfigModel | null = this.fieldValues;
    if (account === null || details === null) {
      return;
    }
    // Swift also guards on `credentialDetails.first`, which would drop every edit when the
    // daemon returns no credentials; the detail map is written without them instead.
    const credentials: AccountCredentialsModel | undefined = account.credentialDetails[0];
    const storedUsername: string = credentials !== undefined ? credentials.username
      : details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_USERNAME));
    const storedPassword: string = credentials !== undefined ? credentials.password : this.password;
    const storedServer: string = details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_HOSTNAME));
    const storedPort: string = details.get(new ConfigKeyModel(ConfigKey.LOCAL_PORT));
    const storedProxy: string = details.get(new ConfigKeyModel(ConfigKey.ACCOUNT_ROUTE_SET));
    if (storedUsername === this.username && storedPassword === this.password &&
      storedServer === this.server && storedPort === this.port &&
      storedProxy === this.proxy) {
      return;
    }
    const accounts = ServiceRegistry.shared().accountService;
    if (credentials !== undefined &&
      (storedUsername !== this.username || storedPassword !== this.password)) {
      credentials.username = this.username;
      credentials.password = this.password;
      account.credentialDetails = [credentials];
      const payload: Array<Map<string, string>> = [credentials.toDictionary()];
      accounts.setAccountCrdentials(account.id, payload);
    }
    if (storedServer !== this.server || storedPort !== this.port ||
      storedUsername !== this.username || storedProxy !== this.proxy) {
      details.set(new ConfigKeyModel(ConfigKey.ACCOUNT_HOSTNAME), this.server);
      details.set(new ConfigKeyModel(ConfigKey.LOCAL_PORT), this.port);
      details.set(new ConfigKeyModel(ConfigKey.ACCOUNT_USERNAME), this.username);
      details.set(new ConfigKeyModel(ConfigKey.ACCOUNT_ROUTE_SET), this.proxy);
      account.details = details;
      accounts.setAccountDetails(account.id, details);
    }
  }

  /**
   * Swift `.alert(isPresented: $showRemovalAlert) { Alert(title: removeAccount, message:
   * removeAccountMessage, primaryButton: .destructive(remove), secondaryButton: .cancel()) }` —
   * the SYSTEM alert, which iOS centres over the dimmed page with Cancel left and the red
   * Remove right (4.20 iPhone). ArkUI's own alert is that control; Center overrides its
   * bottom-anchored phone default.
   */
  private confirmRemoveAccount(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.global_remove_account'),
      message: $r('app.string.account_page_remove_account_message'),
      alignment: DialogAlignment.Center,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.global_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.global_remove'),
        fontColor: $r('sys.color.warning'),
        action: (): void => {
          this.removeAccount();
        }
      }
    });
  }

  /**
   * Swift `removeAccount()` — AccountSummaryVM.removeAccount(statePublisher:): remove, make the
   * next account current and leave settings for the smart list (T-1613).
   */
  private removeAccount(): void {
    const account: AccountModel | null = this.account();
    if (account === null) {
      return;
    }
    ServiceRegistry.shared().accountService.removeAccountAndLeaveSettings(account.id);
  }

  /**
   * iOS's leading back item — the same pop the device Back key performs. A cold deep link can
   * land here as the only entry in the stack, where `back()` would exit the app, so go to the
   * pusher instead (ManageAccountPage.goBack()'s shape).
   */
  private goBack(): void {
    if (router.getLength() === '1') {
      router.replaceUrl({ url: ACCOUNT_SUMMARY_PAGE }).catch((error: Error): void => {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl failed: %{public}s', error.message);
      });
      return;
    }
    router.back();
  }

  /** Swift `.navigationTitle(L10n.AccountPage.manageAccount)`, inline, plus "< Account". */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Text($r('app.string.account_page_manage_account'))
        .width('100%')
        .height(GROUPED_ROW_MIN_HEIGHT)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .textAlign(TextAlign.Center)

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text($r('app.string.account_page_account_header'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
      .padding({ start: LengthMetrics.vp(ROW_LABEL_GAP) })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
  }

  /**
   * Swift `NavigationLink { FieldRowView(label:value:) }`: `HStack { Text(label); Spacer();
   * Text(value).secondaryLabel }` plus the chevron. The value shrinks and WRAPS (multi-line
   * SwiftUI Text, leading-aligned) instead of truncating; the label never shrinks.
   * `value` is a getter read inside the builder: a by-value string is evaluated once, at the
   * first build, before onPageShow loads the account, so the rows would stay empty.
   */
  @Builder
  private fieldRow(label: ResourceStr, value: () => string, slug: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .flexShrink(0)
      Blank()
      Text(value())
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.secondary_label'))
        .textAlign(TextAlign.Start)
        .flexShrink(1)
        .margin({ left: ROW_LABEL_GAP, right: ROW_LABEL_GAP })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(CHEVRON_SIZE)
        .fontColor([$r('sys.color.font_tertiary')])
        .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
    .padding({
      left: $r('sys.float.padding_level10'),
      right: $r('sys.float.padding_level10'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4')
    })
    .id(slug)
    // The whole row is the tap target, exactly as the NavigationLink is.
    .onClick(() => {
      onTap();
    })
  }

  /** iOS draws a grouped row separator itself, inset to the row's text leading edge. */
  @Builder
  private rowSeparator() {
    Divider()
      .strokeWidth(0.5)
      .color($r('sys.color.comp_divider'))
      .margin({ left: SEPARATOR_INSET })
  }

  private fieldLabel(field: SipField): Resource {
    switch (field) {
      case SipField.USERNAME:
        return $r('app.string.global_username');
      case SipField.SERVER:
        return $r('app.string.account_sip_server');
      case SipField.PROXY:
        return $r('app.string.account_proxy_server');
      default:
        return $r('app.string.account_port');
    }
  }

  /**
   * UINavigationBar swaps the origin's title for the generic "Back" when it would not fit left
   * of the centred title — T-1601's rule. The 4.20 iPhone shows "< Back" on all four editors.
   */
  private isBackShortened(): boolean {
    return this.fullBackWidth > 0 &&
      this.fullBackWidth + BACK_FIT_MARGIN > (this.editorBarWidth - this.editorTitleWidth) / 2;
  }

  /**
   * EditableFieldView's `.navigationTitle(L10n.Global.edit + " \(title)")`, inline, and iOS's
   * back item, labelled with this page's title ("Manage account") when that fits beside the
   * centred title, else "Back" (T-1611).
   */
  @Builder
  private editorNavigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        Text() {
          Span($r('app.string.global_edit'))
          Span(' ')
          Span(this.fieldLabel(this.editingField))
        }
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.label'))
        .onAreaChange((_old: Area, area: Area) => {
          this.editorTitleWidth = Number(area.width);
        })
      }
      .width('100%')
      .height(GROUPED_ROW_MIN_HEIGHT)
      .justifyContent(FlexAlign.Center)

      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
          : $r('app.string.account_page_manage_account'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
      }
      .id('editable_field_back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
      .padding({ start: LengthMetrics.vp(ROW_LABEL_GAP) })
      .onAreaChange((_old: Area, area: Area) => {
        if (!this.isBackShortened()) {
          this.fullBackWidth = Number(area.width);
        }
      })
      .onClick(() => {
        this.closeEditor();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.editorBarWidth = Number(area.width);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.navigationBar()

        Scroll() {
          Column() {
            // Swift `Section(header: Text(L10n.AccountPage.accountIdentity))` — iOS upper-cases a
            // grouped section header and indents it to the rows' text edge.
            Text($r('app.string.account_page_account_identity'))
              .width('100%')
              .textCase(TextCase.UpperCase)
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('app.color.secondary_label'))
              .padding({
                left: $r('sys.float.padding_level10'),
                right: $r('sys.float.padding_level10'),
                top: $r('sys.float.padding_level8'),
                bottom: $r('sys.float.padding_level3')
              })

            Column() {
              this.fieldRow($r('app.string.global_username'), () => this.username,
                'manage_sip_account_username', () => {
                  this.editField(SipField.USERNAME);
                })
              this.rowSeparator()
              this.fieldRow($r('app.string.account_sip_server'), () => this.server,
                'manage_sip_account_sip_server', () => {
                  this.editField(SipField.SERVER);
                })
              this.rowSeparator()
              // Swift: the password row pushes EditPasswordView, not an EditableFieldView.
              this.fieldRow($r('app.string.global_password'), () => this.maskedPassword(),
                'manage_sip_account_password', () => {
                  this.openEditPassword();
                })
              this.rowSeparator()
              this.fieldRow($r('app.string.account_proxy_server'), () => this.proxy,
                'manage_sip_account_proxy_server', () => {
                  this.editField(SipField.PROXY);
                })
              this.rowSeparator()
              this.fieldRow($r('app.string.account_port'), () => this.port,
                'manage_sip_account_port', () => {
                  this.editField(SipField.PORT);
                })
            }
            .width('100%')
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            .clip(true)

            // Swift: the second Section — the remove button alone, `Color.jamiFailure`, centred.
            Text($r('app.string.global_remove_account'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize($r('sys.float.Body_L'))
              .fontColor(DESTRUCTIVE_RED)
              .constraintSize({ minHeight: GROUPED_ROW_MIN_HEIGHT })
              .backgroundColor($r('sys.color.comp_background_list_card'))
              .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
              .margin({ top: GROUPED_SECTION_GAP })
              .id('manage_sip_account_remove_account')
              .onClick(() => {
                this.confirmRemoveAccount();
              })
          }
          .width('100%')
          .padding({
            left: $r('sys.float.padding_level10'),
            right: $r('sys.float.padding_level10')
          })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .width('100%')
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('app.color.secondary_label'))
            .textAlign(TextAlign.Center)
            .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.comp_background_gray'))

      // Swift `EditableFieldView` — the screen each NavigationLink pushes, as a page layer.
      if (this.editingField !== SipField.NONE) {
        Column() {
          this.editorNavigationBar()
          EditableFieldView({
            value: $editValue,
            title: this.fieldLabel(this.editingField),
            placeholder: this.fieldLabel(this.editingField),
            onDisappearAction: (): void => {
              this.commitEdit();
            }
          })
            .margin({ top: GROUPED_SECTION_GAP })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('sys.color.comp_background_gray'))
        .transition(TransitionEffect.move(TransitionEdge.END)
          .animation({ duration: EDITOR_TRANSITION_MS }))
        .id('screen_editable_field')
      }
    }
    .width('100%')
    .height('100%')
    .id('screen_manage_sip_account')
  }
}
