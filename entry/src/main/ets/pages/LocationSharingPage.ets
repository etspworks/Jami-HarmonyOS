/*
 * screen_location_sharing — "Location Sharing", ported from
 *   Ring/Ring/Features/Conversations/Conversation/MessageSwiftUI/Views/LocationSharingView.swift
 *   .../ViewModels/LocationSharingVM.swift, Ring/Ring/Services/LocationSharingService.swift
 *   .../MessageSwiftUI/Views/MapView.swift  -> comp_map_view
 *
 * hostScreen: screen_conversation. iOS lays the view over the message list, top-aligned,
 * while a share runs (MessagesListView `if model.shouldShowMap`), so it is a component the
 * conversation mounts — NOT a routed page and NOT in main_pages.json.
 *
 * NO CAPTURED STATE (the gallery declared this screen uncapturable): structure from source only.
 *
 * S3 — `LocationSharingView.body`:
 *   ZStack(alignment: isMapOpened ? .center : .bottom) {
 *     VStack { HStack { xmark "locationSharingClose"; Text("Location Sharing") }
 *                .frame(height: isMapOpened ? 60 : 0)      // the bar EXISTS only when opened
 *              ZStack(.bottom) { MapView(annotations:showZoomButton:)
 *                                createCopyrigtButton() } }  // "locationSharingMapCopyright"
 *       .onTapGesture { if !isMapOpened { open it } }
 *       .accessibilityIdentifier("location_sharing_map")
 *     if model.isAlreadySharingMyLocation() {
 *       if isMapOpened { remaining-time pill + "locationSharingStop" }
 *       else           { "locationSharingStopCompact" }
 *     }
 *   }
 *   .frame(width: isMapOpened ? screenWidth : 250, height: isMapOpened ? … : 150)
 *   .alert(isPresented: $showCopyrightAlert) { OpenStreetMap / Open in Safari }
 *
 * Two DIFFERENT stop controls, one per layout — that is the source's own split
 * (locationSharingStop vs locationSharingStopCompact), not one control styled two ways.
 *
 * DAEMON GAP: a position is published to the peer as a swarm message through the jami daemon,
 * so start/stop sharing report the ceiling instead of pretending to share.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resourceManager } from '@kit.LocalizationKit';
import { preferences } from '@kit.ArkData';
import { geoLocationManager } from '@kit.LocationKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { LocationSharingService, PeerLocationUpdate } from '../common/LocationSharingService';
import { DisposeBag } from '../common/Observable';
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';
import { LocationAnnotation, MapView } from '../components/MapView';
import { LengthMetrics } from '@kit.ArkUI';

/* ── S5 metrics, the source's own (LocationSharingView.swift:29-160) ─────────────── */
/** Swift `var viewCornerRadius: CGFloat = 15`. */
const VIEW_CORNER_RADIUS: number = 15;
/** Swift the opened title bar: a 20pt semibold white close over `darkGray`, title `.title3`. */
const TITLE_GLYPH_SIZE: number = 20;
const TITLE_EDGE_SPACER: number = 20;
/** Swift `.background(Color(UIColor.darkGray))` on the title bar and the copyright disc. */
const MAP_CHROME_GRAY: string = '#FF555555';
/** Swift `createCopyrigtButton()`: a 15pt glyph, padding 4, inside a 30pt disc, `.padding(5)`. */
const COPYRIGHT_GLYPH_SIZE: number = 15;
const COPYRIGHT_DISC_SIZE: number = 30;
const COPYRIGHT_INSET: number = 5;
/** Swift the pill controls: `.padding([.leading,.trailing], 15)`, radius 8 / 20. */
const PILL_H_PADDING: number = 15;
const PILL_V_PADDING_SMALL: number = 5;
const PILL_V_PADDING_LARGE: number = 15;
const PILL_RADIUS_SMALL: number = 8;
const PILL_RADIUS_LARGE: number = 20;
/** Swift `.background(Color.red)` on the stop controls — the iOS system red. */
const STOP_RED: string = '#FF3B30';
/** Swift `.background(Color.black)` behind the remaining-time chip. */
const TIME_CHIP_BLACK: string = '#FF000000';
/** The gap between the remaining-time chip and the stop button. */
const ALERT_GAP: number = 8;
/** sys.symbol.paperplane_fill turned to SF `paperplane.fill`'s up-right heading. */
const PAPERPLANE_SF_ANGLE: number = 45;

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LocationSharingPage';
/** Swift `createCopyrigtButton()`'s destination. */
const OSM_COPYRIGHT_URL: string = 'https://www.openstreetmap.org/copyright';

/** Swift `mapWidth` / `mapHeight` — the compact panel's fixed size. */
const COMPACT_MAP_WIDTH: number = 250;
const COMPACT_MAP_HEIGHT: number = 150;
/** Swift `labelHeight` — the title bar exists only on the opened map. */
const OPENED_LABEL_HEIGHT: number = 60;
/** Swift `updateMapViewWithAnimation`: `withAnimation(.easeInOut(duration: 0.3))`. */
const MAP_ANIMATION_MS: number = 300;

/** Swift `requestWhenInUseAuthorization()`; approximate first, as the Location Kit requires. */
const LOCATION_PERMISSIONS: Permissions[] =
  ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'];
/** GeneralSettings.swift:26-27 keys, in the 'jami_shared' store LocationSharingSettingsPage writes. */
const PREFERENCES_STORE_NAME: string = 'jami_shared';
const LIMIT_LOCATION_SHARING_DURATION_KEY: string = 'LIMIT_LOCATION_SHARING_DURATION_KEY';
const LOCATION_SHARING_DURATION_KEY: string = 'LOCATION_SHARING_DURATION_KEY';
/** AppDelegate.swift:284-288 — an unset limit is on, an unset duration is 15 minutes. */
const SHIPPED_LIMIT_ENABLED: boolean = true;
const SHIPPED_DURATION_MINUTES: number = 15;
/** UIApplication.openSettingsURLString -> the system Settings page for this app. */
const SETTINGS_BUNDLE: string = 'com.huawei.hmos.settings';
const SETTINGS_ABILITY: string = 'com.huawei.hmos.settings.MainAbility';
const SETTINGS_APP_INFO_URI: string = 'application_info_entry';

/**
 * Swift `ConversationViewController.startLocationSharing()` — the attachment menu's
 * "Share my location": location permission first, then "already sharing", then the share for
 * the configured duration. Resolves true when a share with this peer is running, i.e. when the
 * conversation should show LocationSharingView.
 */
export async function startLocationSharing(ui: UIContext, accountId: string,
  peerUri: string): Promise<boolean> {
  const context: common.UIAbilityContext = ui.getHostContext() as common.UIAbilityContext;
  if (!(await checkLocationAuthorization(ui, context))) {
    return false;
  }
  const sharing: LocationSharingService = ServiceRegistry.shared().locationSharingService;
  sharing.setLocationPermissionGranted(true);
  // Swift `isNotAlreadySharingWithThisContact()` — the alert, and the running share stays shown.
  if (sharing.isAlreadySharingMyLocation(accountId, peerUri)) {
    ui.showAlertDialog({
      title: $r('app.string.alerts_alreadylocation_sharing'),
      message: '',
      autoCancel: true,
      confirm: { value: $r('app.string.global_ok'), action: (): void => {} }
    });
    return true;
  }
  sharing.startSharingLocation(accountId, peerUri, sharingDurationSeconds(context));
  return true;
}

/**
 * Swift `checkLocationAuthorization()`: notDetermined asks and does not share on that tap,
 * denied/restricted raises the Go to Settings alert. The request is a no-op once granted.
 */
async function checkLocationAuthorization(ui: UIContext,
  context: common.UIAbilityContext): Promise<boolean> {
  try {
    const result: PermissionRequestResult = await abilityAccessCtrl.createAtManager()
      .requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
    if (result.authResults.length > 0 && result.authResults[0] === 0) {
      return true;
    }
    // The prompt was shown and refused just now: Swift's notDetermined branch, nothing more.
    const shown: boolean[] | undefined = result.dialogShownResults;
    if (shown !== undefined && shown.length > 0 && shown[0]) {
      return false;
    }
  } catch (error) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'location permission request failed: %{public}s',
      describeError(error as BusinessError));
  }
  // Swift `showGoToSettingsAlert(title: L10n.Alerts.noLocationPermissionsTitle)`.
  ui.showAlertDialog({
    title: $r('app.string.alerts_no_location_permissions_title'),
    message: '',
    autoCancel: true,
    primaryButton: { value: $r('app.string.global_cancel'), action: (): void => {} },
    secondaryButton: {
      value: $r('app.string.actions_go_to_settings'),
      action: (): void => {
        openAppSettings(context);
      }
    }
  });
  return false;
}

/** Swift `isLocationSharingDurationLimited ? locationSharingDuration * 60 : nil` (0 = nil). */
function sharingDurationSeconds(context: common.UIAbilityContext): number {
  try {
    const options: preferences.Options = { name: PREFERENCES_STORE_NAME };
    const store: preferences.Preferences = preferences.getPreferencesSync(context, options);
    const limited: boolean =
      store.getSync(LIMIT_LOCATION_SHARING_DURATION_KEY, SHIPPED_LIMIT_ENABLED) as boolean;
    const minutes: number =
      store.getSync(LOCATION_SHARING_DURATION_KEY, SHIPPED_DURATION_MINUTES) as number;
    return limited ? minutes * 60 : 0;
  } catch (error) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'duration setting unreadable: %{public}s',
      describeError(error as BusinessError));
    return SHIPPED_DURATION_MINUTES * 60;
  }
}

/** Swift `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString))`. */
function openAppSettings(context: common.UIAbilityContext): void {
  const want: Want = {
    bundleName: SETTINGS_BUNDLE,
    abilityName: SETTINGS_ABILITY,
    uri: SETTINGS_APP_INFO_URI,
    parameters: { pushParams: context.abilityInfo.bundleName }
  };
  try {
    context.startAbility(want).catch((error: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings open failed: %{public}s', describeError(error));
    });
  } catch (error) {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'settings open failed: %{public}s',
      describeError(error as BusinessError));
  }
}

/** LocationSharingInstanceDictionary's key rule: the same contact with or without its scheme. */
function bareUri(uri: string): string {
  return uri.replace('ring:', '').replace('jami:', '');
}

/** Swift `LocationSharingAnnotation(coordinate:avatar:)`; a null coordinate is no pin. */
function pinAt(key: string, latitude: number | null, longitude: number | null): LocationAnnotation | null {
  if (latitude === null || longitude === null) {
    return null;
  }
  const pin: LocationAnnotation = new LocationAnnotation();
  pin.peerUri = key;
  pin.latitude = latitude;
  pin.longitude = longitude;
  return pin;
}

/**
 * Swift `struct LocationSharingView: View`, which MessagesListView lays over the messages
 * (`if model.shouldShowMap { LocationSharingView(model:) }`, top-aligned) while the
 * conversation stays usable around it. A plain component, so the conversation can host it the
 * same way.
 */
@Component
export struct LocationSharingView {
  /** The host's flag. */
  @Link isPresented: boolean;
  /** Swift `conversation.accountId` / `getParticipants().first?.jamiId`. */
  accountId: string = '';
  peerUri: string = '';

  /** Swift `model.coordinates` — the contact's position, then mine. */
  @State annotations: LocationAnnotation[] = [];
  /** Swift `model.getMyLocationSharingRemainedTimeText()`. */
  @State private remainingTimeText: string = '';
  /** Swift `locationSharingiewModel.isMapOpened`; false is the 250x150 compact map. */
  @State isMapOpened: boolean = false;
  /** Swift `model.isAlreadySharingMyLocation()`. */
  @State isSharingActive: boolean = false;

  private bag: DisposeBag = new DisposeBag();
  /** Swift `myContactsLocation` / `myCoordinate`. */
  private contactPin: LocationAnnotation | null = null;
  private myPin: LocationAnnotation | null = null;

  /** Swift `MessagesListVM.subscribeLocationEvents()`. */
  aboutToAppear(): void {
    const sharing: LocationSharingService = ServiceRegistry.shared().locationSharingService;
    this.bag.add(sharing.peerUriAndLocationReceived.subscribe((update: PeerLocationUpdate): void => {
      const peer: string | null = update.peerUri;
      if (peer !== null && bareUri(peer) === bareUri(this.peerUri)) {
        this.contactPin = pinAt(peer, update.latitude, update.longitude);
        this.refresh();
      }
    }));
    this.bag.add(sharing.currentLocation.subscribe((location: geoLocationManager.Location | null): void => {
      this.myPin = location === null ? null : pinAt(this.accountId, location.latitude, location.longitude);
      this.refresh();
    }));
  }

  aboutToDisappear(): void {
    this.bag.dispose();
  }

  /** Swift `updateCoordinatesList()`, plus the share state the view reads on each update. */
  private refresh(): void {
    const sharing: LocationSharingService = ServiceRegistry.shared().locationSharingService;
    this.isSharingActive = sharing.isAlreadySharingMyLocation(this.accountId, this.peerUri);
    this.remainingTimeText = this.remainingText(
      sharing.getMyLocationSharingRemainedTime(this.accountId, this.peerUri));
    const pins: LocationAnnotation[] = [];
    if (this.contactPin !== null) {
      pins.push(this.contactPin);
    }
    if (this.myPin !== null) {
      pins.push(this.myPin);
    }
    this.annotations = pins;
    // Swift `shouldShowMap = isAlreadySharingLocation() && ...`: once neither side shares any
    // more (Stop, expiry, the contact's Stop), the map leaves the conversation.
    if (!this.isSharingActive && !sharing.isAlreadySharing(this.accountId, this.peerUri)) {
      this.isPresented = false;
    }
  }

  /**
   * Swift `getMyLocationSharingRemainedTimeText()`: "0 minutes", "15 minutes", "1 hour",
   * "2 hours, 5 minutes" (MessagesListVM.swift:1277).
   */
  private remainingText(remainingTime: number): string {
    const resources: resourceManager.ResourceManager =
      (this.getUIContext().getHostContext() as common.UIAbilityContext).resourceManager;
    const hours: number = Math.floor(remainingTime / 60);
    const minutes: number = remainingTime % 60;
    const minuteText: string = resources.getStringSync(minutes === 1
      ? $r('app.string.duration_picker_minute').id : $r('app.string.duration_picker_minutes').id, minutes);
    if (hours === 0) {
      return minuteText;
    }
    const hourText: string = resources.getStringSync(hours === 1
      ? $r('app.string.duration_picker_hour').id : $r('app.string.duration_picker_hours').id, hours);
    return minutes === 0 ? hourText : hourText + ', ' + minuteText;
  }

  /** Swift `updateMapViewWithAnimation(isMapOpened:)` — the map grows and shrinks over 0.3 s. */
  private updateMapViewWithAnimation(opened: boolean): void {
    this.getUIContext().animateTo({ duration: MAP_ANIMATION_MS, curve: Curve.EaseInOut }, () => {
      this.isMapOpened = opened;
    });
  }

  /** Swift the stop buttons: `model.stopSendingLocation()` then `updateMapViewWithAnimation(false)`. */
  private stopSharing(): void {
    ServiceRegistry.shared().locationSharingService.stopSharingLocation(this.accountId, this.peerUri);
    this.updateMapViewWithAnimation(false);
    this.refresh();
  }

  /** Swift `.alert(isPresented: $showCopyrightAlert)` -> https://www.openstreetmap.org/copyright. */
  private showCopyright(): void {
    this.getUIContext().showAlertDialog({
      message: $r('app.string.alerts_open_street_map_copyright'),
      autoCancel: true,
      primaryButton: { value: $r('app.string.global_cancel'), action: (): void => {} },
      secondaryButton: {
        value: $r('app.string.global_ok'),
        action: (): void => {
          this.openCopyright();
        }
      }
    });
  }

  private openCopyright(): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareActions.openLink(context, OSM_COPYRIGHT_URL).catch((error: Object): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'copyright page failed: %{public}s',
        describeError(error as BusinessError));
    });
  }

  build() {
    // Swift `shouldShowMap = isAlreadySharingLocation() && !coordinates.isEmpty`.
    if (this.annotations.length > 0) {
      Stack({ alignContent: this.isMapOpened ? Alignment.Center : Alignment.Bottom }) {
        Column() {
          // Swift: the title bar's height is 0 until the map is opened — it exists only there.
          if (this.isMapOpened) {
            // Swift: a `darkGray` bar with the top corners rounded, a 20pt semibold white
            // close 20pt in, then the `.title3` semibold white title.
            Row({ space: TITLE_EDGE_SPACER }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .id('locationSharingClose')
                .accessibilityText($r('app.string.accessibility_close'))
                .fontSize(TITLE_GLYPH_SIZE)
                .fontWeight(FontWeight.Medium)
                .fontColor([Color.White])
                // Swift `updateMapViewWithAnimation(isMapOpened: false)` — back to the compact map.
                .onClick(() => {
                  this.updateMapViewWithAnimation(false);
                })
              Text($r('app.string.location_sharing_title'))
                .fontSize($r('sys.float.Title_S'))
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Blank()
            }
            .width('100%')
            .height(OPENED_LABEL_HEIGHT)
            .alignItems(VerticalAlign.Center)
            .padding({
              start: LengthMetrics.vp(TITLE_EDGE_SPACER),
              end: LengthMetrics.vp(TITLE_EDGE_SPACER)
            })
            .backgroundColor(MAP_CHROME_GRAY)
            .borderRadius({
              topLeft: VIEW_CORNER_RADIUS,
              topRight: VIEW_CORNER_RADIUS
            })
          }

          Stack({ alignContent: Alignment.BottomEnd }) {
            MapView({ annotations: this.annotations, showZoomButton: this.isMapOpened })

            // Swift `.onTapGesture { if !isMapOpened { open it } }`. The map surface takes its
            // own touches, so the compact map gets a tap layer of its own.
            if (!this.isMapOpened) {
              Column()
                .id('location_sharing_map')
                .width('100%')
                .height('100%')
                .onClick(() => {
                  this.updateMapViewWithAnimation(true);
                })
            }

            // Swift `createCopyrigtButton()` — the OSM tiles' attribution, a licence requirement.
            SymbolGlyph($r('sys.symbol.info_circle'))
              .id('locationSharingMapCopyright')
              .accessibilityText($r('app.string.alerts_open_street_map_copyright'))
              .fontSize(COPYRIGHT_GLYPH_SIZE)
              .fontColor([Color.White])
              .width(COPYRIGHT_DISC_SIZE)
              .height(COPYRIGHT_DISC_SIZE)
              .backgroundColor(MAP_CHROME_GRAY)
              .borderRadius(COPYRIGHT_DISC_SIZE / 2)
              .clip(true)
              .margin(COPYRIGHT_INSET)
              .onClick(() => {
                this.showCopyright();
              })
          }
          .layoutWeight(1)
          .width('100%')
          // Swift `.cornerRadius(isMapOpened ? 0 : viewCornerRadius)` on the map.
          .borderRadius(this.isMapOpened ? 0 : VIEW_CORNER_RADIUS)
          .clip(true)
        }
        .width('100%')
        .height('100%')

        // Swift `if model.isAlreadySharingMyLocation()` — two different stop controls, one per
        // layout, exactly as the source splits them.
        if (this.isSharingActive) {
          if (this.isMapOpened) {
            Column({ space: ALERT_GAP }) {
              Blank()
              // Swift: the remaining-time chip — `.caption` semibold white on black, radius 8.
              Text(this.remainingTimeText)
                .fontSize($r('sys.float.Body_S'))
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .padding({
                  left: PILL_H_PADDING,
                  right: PILL_H_PADDING,
                  top: PILL_V_PADDING_SMALL,
                  bottom: PILL_V_PADDING_SMALL
                })
                .backgroundColor(TIME_CHIP_BLACK)
                .borderRadius(PILL_RADIUS_SMALL)
              // Swift: the stop button — a red radius-20 pill with black content.
              Row({ space: ALERT_GAP }) {
                SymbolGlyph($r('sys.symbol.paperplane_fill'))
                  .fontSize(COPYRIGHT_GLYPH_SIZE)
                  .fontColor([Color.Black])
                  // The HarmonyOS paperplane points straight up; SF `paperplane.fill` points up-right.
                  .rotate({ angle: PAPERPLANE_SF_ANGLE })
                Text($r('app.string.actions_stop_location_sharing'))
                  .fontSize($r('sys.float.Body_L'))
                  .fontColor(Color.Black)
              }
              .id('locationSharingStop')
              .alignItems(VerticalAlign.Center)
              .padding({
                left: PILL_H_PADDING,
                right: PILL_H_PADDING,
                top: PILL_V_PADDING_LARGE,
                bottom: PILL_V_PADDING_LARGE
              })
              .backgroundColor(STOP_RED)
              .borderRadius(PILL_RADIUS_LARGE)
              .margin({ bottom: ALERT_GAP + 2 })
              .onClick(() => {
                this.stopSharing();
              })
            }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
            .hitTestBehavior(HitTestMode.Transparent)
          } else {
            Column() {
              Blank()
              // Swift: the compact stop chip — `.caption` semibold white on red, radius 8,
              // inside `.padding(.all, 10)`.
              Text($r('app.string.actions_stop_location_sharing'))
                .id('locationSharingStopCompact')
                .fontSize($r('sys.float.Body_S'))
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .padding({
                  left: PILL_H_PADDING,
                  right: PILL_H_PADDING,
                  top: PILL_V_PADDING_SMALL,
                  bottom: PILL_V_PADDING_SMALL
                })
                .backgroundColor(STOP_RED)
                .borderRadius(PILL_RADIUS_SMALL)
                .margin(COPYRIGHT_INSET * 2)
                .onClick(() => {
                  this.stopSharing();
                })
            }
            .width('100%')
            .height('100%')
            .alignItems(HorizontalAlign.Center)
            .hitTestBehavior(HitTestMode.Transparent)
          }
        }
      }
      // Swift `.frame(width: mapWidth, height: mapHeight)`.
      .width(this.isMapOpened ? '100%' : COMPACT_MAP_WIDTH)
      .height(this.isMapOpened ? '100%' : COMPACT_MAP_HEIGHT)
      .id('screen_location_sharing')
    }
  }
}
