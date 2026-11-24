/*
 * screen_linked_devices — "Linked Devices", ported from
 *   Ring/Ring/Features/Settings/Me/LinkedDevicesView.swift
 *   Ring/Ring/Features/Settings/Me/LinkedDevicesVM.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (FocusableTextField)
 *
 * presentation: page. AccountSummaryView reaches it with a NavigationLink, so it is an @Entry
 * page pushed from AccountSummarySettingsRootPage. Back is the platform affordance
 * (controlInventory marks it implicit) — the device Back pops the router stack.
 *
 * S2 built the shell + the nav edges out of it:
 *   - push    screen_link_device -> pages/LinkANewDevicePage  ("Link new device")
 *   - present screen_revocation  -> RevokeDeviceOverlay, hostScreen = THIS screen: it is a
 *     LAYER of this page's Stack, not a routed page and not a system dialog — the source
 *     renders RevocationView inside its own ZStack behind `showRevocationAlert`.
 *
 * S3 builds the REAL component tree of `LinkedDevicesView.body`, unstyled:
 *
 *   ZStack {
 *     List {
 *       Section(header: thisDevice)   { ForEach(model.devices) { if device.isCurrent  { row } } }
 *       linkDeviceButton()
 *       if <any non-current device> {
 *         Section(header: otherDevices) { ForEach(model.devices) { if !device.isCurrent { row } } }
 *       }
 *     }
 *     if showRevocationAlert { RevocationView(...) }
 *   }
 *
 * and `createDeviceRow(device:)`:
 *
 *   HStack {
 *     VStack { if let name = device.deviceName {
 *                if editingDevice != device.deviceId { Text(name) } else { FocusableTextField } }
 *              Text(device.deviceId) }
 *     Spacer()
 *     if !device.isCurrent { Text(remove) } else { Text(editing ? save : edit) }
 *   }
 *
 * The rows are BOUND: `AccountsService.devicesObservable(account)` fills them (the Swift VM's
 * `subscribeDevices()`), never a literal array. The two sections are two ArrayDataSources over
 * the same relay, which is what the source's two filtered ForEach loops are.
 *
 * conditionalVariants, all four in the render body: [current_device] / [other_device] pick the
 * trailing control, [renaming] swaps the label for the field, [has_other_devices] omits the
 * whole second section. [revocation_open] is the `if (this.isRevocationOpen)` layer of the
 * Stack below, the second element of the source's ZStack.
 *
 * DAEMON GAP: the device list, the rename's remote half and the revocation are jami-daemon
 * work. The local rename really lands (`setAccountProperty` writes the detail map); the notice
 * states that it reaches nothing beyond this device, and no control is disabled for it.
 *
 * S5/S6 style this tree against results/traversal-source/.../S0111,S0112,S0242,S0246,S0247,S0249.
 */
import { router, LengthMetrics } from '@kit.ArkUI';
import { RevokeDeviceOverlay } from './RevokeDevicePage';
import { FocusableTextField } from '../components/FocusableTextField';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { DeviceModel } from '../model/DeviceModel';
import { AccountModel } from '../model/AccountModel';
import { ServiceRegistry } from '../common/ServiceRegistry';
// feat_device_linking lives in AccountsService — the devices stream, the rename write and the
// revocation all come from there, so this screen calls it by its own type.
import { AccountsService } from '../common/AccountsService';
import { DisposeBag } from '../common/Observable';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
import { DaemonUnavailableError } from '../common/DaemonService';
import { BackChevron } from '../components/BackButton';
import { COPY_SHARE_MENU } from './AccountSummarySettingsRootPage';

/* ── S5 metrics ───────────────────────────────────────────────────────────────────────────
 * The source is a SwiftUI `List` inside a NavigationView with an INLINE title, i.e. iOS 15+
 * inset-grouped (mapping-tables.md §7): a grey page, white content-sized cards inset from
 * both edges, an uppercase grey section header indented to the card's content edge. None of
 * that is spelled in the Swift, so every value below is the design TOKEN for the iOS
 * semantic role (ios-to-harmonyos-design-tokens.md) rather than a number read off the PNG.
 * The literals are exactly the four the source hardcodes, plus the iOS bar height.
 */
/** iOS inline navigation-bar height — a platform constant, not an app value. */
const BAR_HEIGHT: number = 44;
/** The coordinator root this page is pushed from — where its leading back item returns to. */
const ACCOUNT_SUMMARY_PAGE: string = 'pages/AccountSummarySettingsRootPage';
/** iOS's gap between the back chevron and the origin page's title. */
const BACK_GLYPH_GAP: number = 6;
/** Swift `.cornerRadius(10)` on the link-device button's plate. */
const LINK_BUTTON_RADIUS: number = 10;
/** Swift `.padding(.horizontal, 10)` on the link-device button's label. */
const LINK_BUTTON_H_PADDING: number = 10;
/** Swift `.padding(.vertical, 12)` on the link-device button's label. */
const LINK_BUTTON_V_PADDING: number = 12;
/** Swift `VStack(alignment: .leading, spacing: 8)` — the name/id gap inside a row. */
const ROW_STACK_GAP: number = 8;
/**
 * S6, measured off the capture's own accessibility tree (S0242 `base.ui.json`, 393pt wide):
 * the grouped section gap iOS puts between the device card (bottom 212) and the link-device
 * row (top 247). The source spells no spacing at all — this is UIKit's grouped-list metric,
 * so it is a platform constant rather than a token (no `sys.float` expresses it).
 */
const GROUPED_SECTION_GAP: number = 35;

/**
 * LazyForEach row key. knownDevicesChanged renames a DeviceModel in place and `reload` reuses
 * every row whose key is unchanged, so a key of the id alone would keep the old name on screen
 * after Save; the name is part of the key so a rename rebuilds its row.
 */
function deviceRowKey(device: DeviceModel): string {
  return device.deviceId + '/' + (device.deviceName ?? '');
}

/** `List(.insetGrouped)`: a white, content-sized card inset from both page edges. */
@Styles function groupedCard() {
  .width('100%')
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .clip(true)
}

@Entry
@Component
struct LinkedDevicesPage {
  /* ── bound data ───────────────────────────────────────────────────────────────────────── */
  /** Swift `LinkedDevicesVM.devices` — every device the account knows, from svc_accounts. */
  @State linkedDeviceList: DeviceModel[] = [];
  /**
   * bindingContract[device rows] -> svc_accounts (Swift `model.devices`): the rows of the
   * second section, every device that is NOT this one. `hasOtherDevices` is read off it.
   */
  @State deviceRows: DeviceModel[] = [];
  /** Swift `ForEach(model.devices) { if device.isCurrent }` — the "This device" section. */
  private currentDeviceSource: ArrayDataSource<DeviceModel> =
    new ArrayDataSource<DeviceModel>([]);
  /** Swift `ForEach(model.devices) { if !device.isCurrent }` — the "Other devices" section. */
  private otherDeviceSource: ArrayDataSource<DeviceModel> = new ArrayDataSource<DeviceModel>([]);

  /** bindingContract[name] -> DeviceModel.deviceName, mirrored for this device. */
  @State name: string = '';
  /**
   * bindingContract[id] -> DeviceModel.deviceId, mirrored for this device.
   *
   * PLAN DEFECT, reported: the plan names this state var with the bare word i-d, which is an
   * inherited CustomComponent attribute setter (SDK `CommonAttribute` declares it as a
   * method, and BaseCustomComponent extends it) — a state field of that name is the ArkTS
   * error "not assignable to the same property in base type", and static_guard's
   * `reserved-attr` blocks it at every phase. It is carried under a non-colliding name; the
   * S4 gate's `statevar-missing` for it cannot be cleared by any legal edit to this page.
   */
  @State deviceIdValue: string = '';

  /** conditionalVariants[current_device]: `device.isCurrent` — the row's rename control. */
  @State isCurrentDevice: boolean = false;
  /** conditionalVariants[other_device]: `!device.isCurrent` — the row's Remove control. */
  @State isOtherDevice: boolean = false;
  /** conditionalVariants[renaming]: `editingDevice == device.deviceId` — field, not label. */
  @State isRenaming: boolean = false;
  /** conditionalVariants[has_other_devices]: `!model.devices.filter { !$0.isCurrent }.isEmpty`. */
  @State hasOtherDevices: boolean = false;
  /** Swift: `@State private var showRevocationAlert` (conditionalVariants[revocation_open]). */
  @State isRevocationOpen: boolean = false;
  /** Swift `@State var editingDevice: String = ""` — the deviceId being renamed, "" when none. */
  @State private editingDevice: string = '';
  /** Swift `@State private var deviceName: String = ""` — the name typed while renaming. */
  @State private deviceName: string = '';
  /** Swift `@State private var isFocused: Bool` — FocusableTextField's first-responder binding. */
  @State private isFocused: boolean = false;
  /** Swift `@State private var deviceToRevoke: DeviceModel?`. */
  @State private deviceToRevoke: string = '';
  /** True while svc_accounts is being read. */
  @State isLoading: boolean = false;
  /** The daemon gap this screen's own actions hit, stated in place rather than as a toast. */
  @State private showDaemonNotice: boolean = false;
  /** The gap's own message, rendered under the notice; empty when nothing has failed. */
  @State errorText: string = '';

  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift `let disposeBag = DisposeBag()` — the devices subscription. */
  private bag: DisposeBag = new DisposeBag();

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    this.subscribeDevices();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription is released whatever happens on the way out.
    try {
      this.bag.dispose();
    } finally {
      this.isLoading = false;
    }
  }

  /* ── data layer ───────────────────────────────────────────────────────────────────────── */
  /** Swift `LinkedDevicesVM.accountService` — svc_accounts, where feat_device_linking lives. */
  private accounts(): AccountsService {
    return ServiceRegistry.shared().accountService;
  }

  /** Swift `AccountSummaryVM` hands the VM its account; here it is the id in AppStorage. */
  private currentAccount(): AccountModel | null {
    const service: AccountsService = this.accounts();
    if (this.currentAccountId.length > 0) {
      const byId: AccountModel | null = service.getAccount(this.currentAccountId);
      if (byId !== null) {
        return byId;
      }
    }
    return service.currentAccount;
  }

  /** Swift `LinkedDevicesVM.subscribeDevices()` — devicesObservable replays and re-emits. */
  private subscribeDevices(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account === null) {
      return;
    }
    this.isLoading = true;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(this.accounts().devicesObservable(account)
      .subscribe((devices: DeviceModel[]): void => {
        this.applyDevices(devices);
      }));
    // Swift `handleDeviceRevocationEvent`: `self.devices = self.account.devices`. A revocation
    // drops the device from account.devices without a knownDevicesChanged of its own.
    this.bag.add(this.accounts().sharedResponseStream.subscribe((event: ServiceEvent): void => {
      if (event.eventType === ServiceEventType.DEVICE_REVOCATION_ENDED &&
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) === account.id) {
        this.applyDevices(account.devices);
      }
    }));
    // The gaps THIS screen's own controls raise: the rename's remote half and the revocation.
    this.bag.add(registry.daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'account.setDetails' || error.feature === 'account.revokeDevice') {
          this.showDaemonNotice = true;
          this.errorText = error.message;
        }
      }));
  }

  /** Swift: the `@Published var devices` assignment, split into the source's two filters. */
  private applyDevices(devices: DeviceModel[]): void {
    this.linkedDeviceList = devices;
    const current: DeviceModel[] = [];
    const others: DeviceModel[] = [];
    for (const device of devices) {
      if (device.isCurrent) {
        current.push(device);
      } else {
        others.push(device);
      }
    }
    this.currentDeviceSource.reload(current);
    this.otherDeviceSource.reload(others);
    this.deviceRows = others;
    this.hasOtherDevices = this.deviceRows.length > 0;
    // The row-kind selectors the plan names, mirrored from the set the list now renders.
    this.isCurrentDevice = current.length > 0;
    this.isOtherDevice = this.hasOtherDevices;
    // bindingContract[name] / [id] — this device's own bound fields.
    const thisDevice: DeviceModel | undefined = current.length > 0 ? current[0] : undefined;
    this.name = thisDevice !== undefined && thisDevice.deviceName !== undefined
      ? thisDevice.deviceName : '';
    this.deviceIdValue = thisDevice !== undefined ? thisDevice.deviceId : '';
    this.isLoading = false;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * iOS's leading back item for a page pushed by a NavigationLink — the same pop the device
   * Back key performs. A cold deep link can land here as the only entry in the stack, where
   * `back()` would pop the last page and exit the app, so go to the parent coordinator root
   * instead (the same shape ManageAccountPage/SettingsSummaryPage use).
   */
  private goBack(): void {
    if (router.getLength() === '1') {
      router.replaceUrl({ url: ACCOUNT_SUMMARY_PAGE }).catch((error: Error): void => {
        console.error('LinkedDevicesPage: replaceUrl ' + ACCOUNT_SUMMARY_PAGE + ' failed: '
          + error.message);
      });
      return;
    }
    router.back();
  }

  /** Swift `linkDeviceButton`'s action — `model.linkDevice()` activates the NavigationLink. */
  private openLinkDevice(): void {
    router.pushUrl({ url: 'pages/LinkANewDevicePage' });
  }

  /**
   * Swift: the Remove text's onTapGesture — `deviceToRevoke = device; showRevocationAlert = true`,
   * which renders RevocationView over the list (plan edge -> screen_revocation, kind: present).
   */
  private showRevocation(deviceId: string): void {
    this.deviceToRevoke = deviceId;
    this.isRevocationOpen = true;
  }

  /**
   * Swift `.onChange(of: showRevocationAlert)`: on dismissal the pending device is dropped.
   * Back is the overlay's dismiss affordance (the implicit control the plan already lists),
   * so no control is added here.
   */
  private dismissRevocation(): void {
    this.isRevocationOpen = false;
    this.deviceToRevoke = '';
  }

  /** Back closes the revocation layer first, exactly as it closes an iOS alert. */
  onBackPress(): boolean {
    if (this.isRevocationOpen) {
      this.dismissRevocation();
      return true;
    }
    return false;
  }

  /** Swift `handleButtonAction(device:)` — saveDeviceName() when editing, else enterEditMode(). */
  private toggleRename(device: DeviceModel): void {
    if (this.editingDevice === device.deviceId) {
      this.saveDeviceName();
    } else {
      this.enterEditMode(device);
    }
  }

  /** Swift `enterEditMode(device:)`. */
  private enterEditMode(device: DeviceModel): void {
    const name: string | undefined = device.deviceName;
    if (name !== undefined) {
      this.deviceName = name;
    }
    // Raised by the field's onAppear (deviceRow), not here: FocusableTextField requests focus
    // in aboutToAppear, before its TextInput exists, so raising it now never focuses it.
    this.isFocused = false;
    this.editingDevice = device.deviceId;
    this.isRenaming = true;
  }

  /** Swift `saveDeviceName()` — `model.editDeviceName(name:)` -> AccountsService.setDeviceName. */
  private saveDeviceName(): void {
    const account: AccountModel | null = this.currentAccount();
    if (account !== null) {
      // Cleared first: the daemon half reports the gap synchronously, so the subscription
      // above sets it again on the way back out if the daemon is still missing.
      this.showDaemonNotice = false;
      this.errorText = '';
      this.accounts().setDeviceName(account.id, this.deviceName);
    }
    this.isFocused = false;
    this.editingDevice = '';
    this.isRenaming = false;
  }

  /* ── render ───────────────────────────────────────────────────────────────────────────── */
  /** Swift `Section(header: Text(...))`. */
  @Builder
  sectionHeader(title: Resource) {
    // iOS grouped section header: an UPPERCASED grey caption indented to the card's content
    // edge. The uppercasing is the platform's, not the string's — the resource keeps the
    // app's own casing and `textCase` applies the grouped-list convention.
    Text(title)
      .width('100%')
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .textCase(TextCase.UpperCase)
      // S6: capture S0242 puts the header's text at x=40 on a 393pt screen — 20 inside the
      // card, whose own edge is 20 inside the page. padding_level10 is that 20vp.
      .padding({
        start: LengthMetrics.resource($r('sys.float.padding_level10')),
        end: LengthMetrics.resource($r('sys.float.padding_level10')),
        top: LengthMetrics.resource($r('sys.float.padding_level8')),
        bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
      })
  }

  /**
   * Swift `createDeviceRow(device:)`. The two device-kind selectors are passed in, so each
   * `if` below reads the name the plan's conditionalVariants bind: [current_device]
   * `device.isCurrent`, [other_device] `!device.isCurrent`. [renaming] is read off
   * `this.editingDevice` in place: a by-value @Builder argument is evaluated once, so a
   * renaming flag passed in never flips the row to the field and Save.
   */
  @Builder
  deviceRow(device: DeviceModel, isCurrentDevice: boolean, isOtherDevice: boolean) {
    Row() {
      // Swift `VStack(alignment: .leading, spacing: 8)`.
      Column({ space: ROW_STACK_GAP }) {
        // Swift `if let name = device.deviceName { ... }` — a nameless device shows only its id.
        if (device.deviceName !== undefined) {
          // conditionalVariants[renaming]: `editingDevice != device.deviceId`.
          if (this.editingDevice !== device.deviceId) {
            // Swift: a plain `Text`, so the grouped row's default `.body` on `.label`.
            Text(device.deviceName)
              .fontSize($r('sys.float.Body_L'))
              .fontColor($r('app.color.label'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .copyOption(CopyOptions.LocalDevice)
              .editMenuOptions(COPY_SHARE_MENU)
          } else {
            Row() {
              FocusableTextField({
                text: $deviceName,
                isFirstResponder: $isFocused,
                identifier: 'linked_devices_device_name'
              })
            }
            .width('100%')
            // Swift updateUIView's becomeFirstResponder once the field is on screen: the
            // binding's @Watch now focuses a TextInput that exists (caret + keyboard).
            .onAppear(() => {
              this.isFocused = true;
            })
          }
        }
        // Swift `Text(device.deviceId).font(.footnote).foregroundColor(.secondaryLabel)`. A plain
        // Text, so VoiceOver reads the full id: the screen reader must reach it too (T-1631).
        Text(device.deviceId)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .copyOption(CopyOptions.LocalDevice)
          .editMenuOptions(COPY_SHARE_MENU)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // Swift `Spacer()` then the trailing control, one per device kind.
      Blank()
      if (isOtherDevice) {
        // conditionalVariants[other_device] — the Remove tap opens RevocationView.
        // Swift `.foregroundColor(.jami)` over an otherwise default `.body` Text.
        Text($r('app.string.global_remove'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .margin({ start: LengthMetrics.resource($r('sys.float.ohos_id_card_margin_start')) })
          .id('linked_devices_remove')
          .onClick(() => {
            this.showRevocation(device.deviceId);
          })
      } else if (isCurrentDevice) {
        // conditionalVariants[current_device] — Edit, then Save while renaming.
        Text(this.editingDevice === device.deviceId
          ? $r('app.string.global_save')
          : $r('app.string.global_edit'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .margin({ start: LengthMetrics.resource($r('sys.float.ohos_id_card_margin_start')) })
          .id('linked_devices_edit_name')
          .onClick(() => {
            this.toggleRename(device);
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // S6, measured on S0242: the card is [20,136][373,212] and its name/id block is
    // [40,152]..[308,196] — 20 in from the card on both sides, 16 above the name and 16
    // below the id. 16 + 20 + 8 + 16 + 16 is exactly the card's 76pt height.
    .padding({
      start: LengthMetrics.resource($r('sys.float.padding_level10')),
      end: LengthMetrics.resource($r('sys.float.padding_level10')),
      top: LengthMetrics.resource($r('sys.float.padding_level8')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level8'))
    })
  }

  /**
   * Swift `linkDeviceButton()` — the one place this screen spells its own style:
   *   Text(...).foregroundColor(.label).padding(.horizontal, 10).padding(.vertical, 12)
   *            .frame(maxWidth: .infinity).background(.jamiTertiaryControl).cornerRadius(10)
   * plus `.listRowBackground(.clear)` / `.listRowSeparator(.hidden)` / zero row insets, which
   * is why it sits on the grey page rather than on a white card.
   */
  @Builder
  linkDeviceButton() {
    Button($r('app.string.link_device_title'))
      .type(ButtonType.Normal)
      .id('linked_devices_link_device')
      .width('100%')
      .fontSize($r('sys.float.Body_L'))
      .fontColor($r('app.color.label'))
      .backgroundColor($r('app.color.jami_tertiary_control'))
      .borderRadius(LINK_BUTTON_RADIUS)
      .padding({
        left: LINK_BUTTON_H_PADDING,
        right: LINK_BUTTON_H_PADDING,
        top: LINK_BUTTON_V_PADDING,
        bottom: LINK_BUTTON_V_PADDING
      })
      .margin({ top: GROUPED_SECTION_GAP })
      .onClick(() => {
        this.openLinkDevice();
      })
  }

  /**
   * THE DAEMON GAP, in place under the controls that hit it. Never a toast (gone before it is
   * read) and never `.enabled(false)` — the rename's LOCAL half really happened.
   */
  @Builder
  daemonGapNotice() {
    // The source has no failure UI at all, so the FORM is the platform's own inline notice,
    // on the grey page above the list — never a panel that replaces the screen
    // (android-ui-fidelity.md §7).
    Column({ space: ROW_STACK_GAP }) {
      Text($r('app.string.daemon_not_available'))
        .width('100%')
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      start: LengthMetrics.resource($r('sys.float.padding_level10')),
      end: LengthMetrics.resource($r('sys.float.padding_level10')),
      top: LengthMetrics.resource($r('sys.float.padding_level4')),
      bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
    })
  }

  build() {
    // Swift `ZStack { List { ... }; if showRevocationAlert { RevocationView(...) } }`.
    Stack() {
      Column() {
        // Swift `.navigationTitle(...).navigationBarTitleDisplayMode(.inline)` — iOS centres
        // an inline title in the bar's own optical row (mapping-tables.md §7) and draws the
        // leading back item itself, labelled with the ORIGIN page's title ("Account"). An
        // @Entry router page draws no system chrome, so that item is composed here; it is
        // controlInventory's `implicit: true / affordance: back` entry, hence `.id('back')`.
        Stack({ alignContent: Alignment.Start }) {
          Text($r('app.string.account_page_linked_devices'))
            .width('100%')
            .height(BAR_HEIGHT)
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
          .constraintSize({ minHeight: BAR_HEIGHT })
          .onClick(() => {
            this.goBack();
          })
        }
        .width('100%')
        .constraintSize({ minHeight: BAR_HEIGHT })

        if (this.showDaemonNotice) {
          this.daemonGapNotice()
        }

        List() {
          // Swift `Section(header: Text(L10n.AccountPage.thisDevice))`. The inset-grouped
          // header sits on the grey page ABOVE the card, so it is an item of its own: as the
          // group's header it would be drawn inside the card's white fill.
          ListItem() {
            this.sectionHeader($r('app.string.account_page_this_device'))
          }
          ListItemGroup() {
            LazyForEach(this.currentDeviceSource, (device: DeviceModel) => {
              ListItem() {
                this.deviceRow(device, device.isCurrent, !device.isCurrent)
              }
              .id('linked_devices_this_device_itemroot')
            }, (device: DeviceModel) => deviceRowKey(device))
          }
          .groupedCard()

          // Rule 12: the capture's LinkedDevicesView base tree records the Link-new-device
          // CELL as a clickable with no identifier and no text of its own, so the harness
          // named it `tap_2` and the replay has nothing else to address it by (S0245). The
          // ArkUI counterpart of that cell is this ListItem; the Button inside it fills it,
          // so a tap here reaches the same handler the named button already carries.
          ListItem() {
            this.linkDeviceButton()
          }
          .id('tap_2')

          // conditionalVariants[has_other_devices]: the whole section is omitted when the
          // account has no other device — not merely empty.
          if (this.hasOtherDevices) {
            // Outside the card, as above. With the header's own top padding this margin is the
            // grouped section gap the link-device button also sits under.
            ListItem() {
              this.sectionHeader($r('app.string.account_page_other_devices'))
            }
            .margin({ top: $r('sys.float.padding_level8') })
            ListItemGroup() {
              LazyForEach(this.otherDeviceSource, (device: DeviceModel) => {
                ListItem() {
                  this.deviceRow(device, device.isCurrent, !device.isCurrent)
                }
                .id('linked_devices_other_device_itemroot')
              }, (device: DeviceModel) => deviceRowKey(device))
            }
            // The grouped list's own separator between rows, inset to the text's leading edge.
            .divider({
              strokeWidth: 0.5,
              color: $r('sys.color.comp_divider'),
              startMargin: $r('sys.float.padding_level10')
            })
            .groupedCard()
          }
        }
        .width('100%')
        .layoutWeight(1)
        // `List(.insetGrouped)`: the grey page the white cards sit on, with the 16 side inset
        // that makes them content-sized rather than edge-to-edge.
        .backgroundColor($r('sys.color.background_secondary'))
        .contentStartOffset(0)
        .padding({
          start: LengthMetrics.resource($r('sys.float.padding_level10')),
          end: LengthMetrics.resource($r('sys.float.padding_level10'))
        })
        // S6: the capture's tree carries a "Vertical scroll bar, 1 page" element, i.e. iOS's
        // indicator, which shows while scrolling and fades out. Auto is that behaviour.
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))

      // conditionalVariants[revocation_open] — Swift `if showRevocationAlert {
      // RevocationView(model:showRevocationAlert:deviceToRevoke:) }`: the alert is a layer of
      // this page's own tree, over the list, not a system dialog.
      if (this.isRevocationOpen) {
        // Rendered in place, so the overlay has no CustomDialogController to close: its
        // dismissing buttons report back through onDismiss, exactly as the Swift binding does.
        RevokeDeviceOverlay({
          isPresented: $isRevocationOpen,
          deviceId: this.deviceToRevoke,
          onDismiss: () => {
            this.isRevocationOpen = false;
            this.deviceToRevoke = '';
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_linked_devices')
  }
}
