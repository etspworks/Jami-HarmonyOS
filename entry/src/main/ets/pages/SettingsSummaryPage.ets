/*
 * screen_settings_summary — "Settings Summary", ported from
 *   Ring/Ring/Features/Settings/Me/SettingsSummaryView.swift
 *   Ring/Ring/Features/Settings/Me/UtilitiesViews.swift (SettingsRow)
 *
 * presentation: page. Pushed by AccountSummaryView's `NavigationLink -> SettingsSummaryView`.
 *
 * S2 wired the ten PUSH edges out of this screen. S3 builds the REAL component tree of
 * `SettingsSummaryView.body`, unstyled — a `List` of TWO sections, each with a header AND a
 * footer, every row a `NavigationLink { SettingsRow(iconName:title:) }` (comp_settings_row):
 *
 *   Section(header: accountSettings, footer: accountSettingsExplanation) {
 *     if model.account.type == .sip { Security }
 *     else                         { Chats; Call; Notifications; Name server }
 *     Connectivity and configurations          // both kinds
 *   }
 *   Section(header: appSettings, footer: appSettingsExplanation) {
 *     if model.account.type != .sip { File transfer; Location sharing; Video }
 *     Diagnostics                               // both kinds
 *   }
 *
 * THE SOURCE BRANCHES AND THE PLAN DOES NOT. `conditionalVariants` is empty for this screen
 * and the action contract marks all ten controls required at S0124 — which the source can
 * never render at once. The capture settles it: S0124 (a Jami account) shows NINE rows and no
 * Security. THE ONE INVARIANT says the source wins, so the `if` is built and Security stays in
 * the SIP branch. Reported to the orchestrator as an action-contract defect, not silenced.
 *
 * bindingContract is EMPTY by design: this screen is a pure navigation index, so every string
 * is a string resource. The one bound value is the branch selector itself — the account's type,
 * read from svc_accounts.
 *
 * The glyph per row is the SF Symbol the source names (`shield`, `message`, `phone`, `bell`,
 * `server.rack`, `link`, `folder`, `location`, `video`, `waveform.path.ecg`), resolved to a
 * sys.symbol VERIFIED in this SDK's own symbol table. Neither `server.rack` nor
 * `waveform.path.ecg` has an exact counterpart. `server.rack` takes the nearest glyph the
 * table actually carries, `externaldrive_3` (three stacked slots — the rack the capture
 * shows, where the single `externaldrive` read as a plain tray).
 *
 * `waveform.path.ecg` has NO unframed counterpart at all: every ECG path in the table is
 * enclosed (`waveform_path_ecg_square`, `_magnifyingglass`, `_circle`) or carries a heart,
 * and the smooth `waveform` has none of the trace. `waveform_path_ecg_square` is what the
 * row shipped with, and the judge read its frame as a different glyph on all six captured
 * states (I017). So the Diagnostics row carries the SOURCE symbol's own pixels instead,
 * bundled as `app.media.ic_waveform_path_ecg` (base + dark, tinted to the same secondary
 * the sibling SymbolGlyphs resolve to) and drawn by `pngRowLabel` — an Image cannot go
 * through SettingsRow, whose leading glyph is a SymbolGlyph, and SymbolGlyph takes system
 * symbols only.
 *
 * S5/S6 style this tree against S0124, S0127, S0128, S0137, S0138, S0149, S0151.
 */
import { router, LengthMetrics } from '@kit.ArkUI';
import { SettingsRow } from '../components/SettingsRow';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { BackChevron } from '../components/BackButton';

/** No account configured — the one failure this index can hit on its own. */
const ACCOUNT_UNAVAILABLE: string = 'no account';

/**
 * The page AccountSummaryView pushes this one from — iOS's back item carries THAT page's
 * title ("Account"), so the pop target and the label are the same screen.
 */
const ACCOUNT_SUMMARY_PAGE: string = 'pages/AccountSummarySettingsRootPage';
/** Capture: the gap between the chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/** iOS insets the back chevron from the bar's leading edge, as the sibling pages do (T-1634). */
const BACK_LEADING: number = 8;
/** SwiftUI's inline nav title is 17 pt SEMIBOLD; ArkUI spells semibold as the numeric 600. */
const TITLE_WEIGHT: number = 600;

/* ── S5 metrics ───────────────────────────────────────────────────────────────────────────
 * A SwiftUI `List` with an INLINE nav title, i.e. iOS 15+ inset-grouped (mapping-tables.md
 * §7): a grey page, white content-sized cards inset from both edges, a grey UPPERCASE header
 * above each card and a grey sentence-case footer below it, and a separator between sibling
 * rows inset to the row's TEXT leading edge (past the glyph). None of it is spelled in the
 * Swift, so the values are the design tokens for those roles
 * (ios-to-harmonyos-design-tokens.md); only the bar height and the card radius are numbers.
 */
/** iOS inline navigation-bar / grouped-row height — a platform constant. */
const BAR_HEIGHT: number = 44;
/**
 * The separator inset of a row that leads with a glyph: the row's own padding
 * (padding_level10, 20) + the glyph SettingsRow pins at 18 + the gap (card_margin_start, 12).
 * Composed from the tokens, and it lands where the capture puts it — S0127's tree has every
 * row label at x=71 on a 393pt screen, 51 inside a card whose own edge is at x=20.
 */
const SEPARATOR_INSET: number = 50;
/** `List(.insetGrouped)`'s card corner, as the grouped-card token resolves it. */
const CARD_RADIUS: number = 12;
/** Swift `.frame(width: 18, height: 18)` on the row's leading glyph — the size SettingsRow pins. */
const ROW_GLYPH_SIZE: number = 18;
/** The least gap between a row's title and its chevron — SwiftUI HStack's default spacing. */
const CHEVRON_GAP: number = 8;

@Entry
@Component
struct SettingsSummaryPage {
  /** Swift `model.account.type == .sip` — the branch selector of BOTH sections. */
  @State private isSipAccount: boolean = false;
  /** True while svc_accounts is being read. */
  @State isLoading: boolean = false;
  /** Why the section branch could not be resolved; empty when there is nothing to report. */
  @State errorText: string = '';

  /** AppStorage['currentAccountId'], written by svc_accounts. */
  @StorageLink('currentAccountId') currentAccountId: string = '';

  /** Swift: the VM's subscriptions. */
  private bag: DisposeBag = new DisposeBag();

  /* ── lifecycle ────────────────────────────────────────────────────────────────────────── */
  aboutToAppear(): void {
    this.readAccount();
    this.bag.add(ServiceRegistry.shared().accountService.currentAccountChanged.subscribe(
      (account: AccountModel | null): void => {
        this.applyAccount(account);
      }));
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
  /** Swift `AccountSummaryVM.account` — here the account id in AppStorage. */
  private readAccount(): void {
    this.isLoading = true;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    let account: AccountModel | null = null;
    if (this.currentAccountId.length > 0) {
      account = registry.accountService.getAccount(this.currentAccountId);
    }
    if (account === null) {
      account = registry.accountService.currentAccount;
    }
    this.applyAccount(account);
  }

  /** Swift `model.account.type == .sip`. */
  private applyAccount(account: AccountModel | null): void {
    this.isSipAccount = account !== null && account.type === AccountType.SIP;
    // No account means the branch above fell back to the Jami sections by default, which is
    // worth saying rather than silently showing a set that was never resolved.
    this.errorText = account === null ? ACCOUNT_UNAVAILABLE : '';
    this.isLoading = false;
  }

  /* ── handlers — every controlInventory entry, wired to its Swift effect ───────────────── */
  /**
   * iOS's leading back item for a page pushed by a NavigationLink — the same pop the device
   * Back key performs, and controlInventory's `implicit: true / affordance: back` entry. A cold
   * deep link can land here as the only entry in the stack, where `back()` would pop the last
   * page and exit the app, so go to the parent coordinator root instead (the same shape
   * AccountSummarySettingsRootPage.dismiss() uses).
   */
  private goBack(): void {
    if (router.getLength() === '1') {
      router.replaceUrl({ url: ACCOUNT_SUMMARY_PAGE }).catch((error: Error): void => {
        console.error('SettingsSummaryPage: replaceUrl ' + ACCOUNT_SUMMARY_PAGE + ' failed: '
          + error.message);
      });
      return;
    }
    router.back();
  }

  /** Swift `NavigationLink -> SecuritySettingsView` (SIP accounts only). */
  private openSecuritySettings(): void {
    router.pushUrl({ url: 'pages/SecuritySettingsPage' });
  }

  /** Swift `NavigationLink -> ChatSettingsView`. */
  private openChatSettings(): void {
    router.pushUrl({ url: 'pages/ChatSettingsPage' });
  }

  /** Swift `NavigationLink -> CallSettingsView`. */
  private openCallSettings(): void {
    router.pushUrl({ url: 'pages/CallSettingsPage' });
  }

  /** Swift `NavigationLink -> NotificationsSettingsView`. */
  private openNotificationSettings(): void {
    router.pushUrl({ url: 'pages/NotificationSettingsPage' });
  }

  /** Swift `NavigationLink -> NameServerView`. */
  private openNameServer(): void {
    router.pushUrl({ url: 'pages/NameServerSettingsPage' });
  }

  /** Swift `NavigationLink -> ConnectivitySettingsView`. */
  private openConnectivitySettings(): void {
    router.pushUrl({ url: 'pages/ConnectivityAndConfigurationsPage' });
  }

  /** Swift `NavigationLink -> FileTransferSettingsView`. */
  private openFileTransferSettings(): void {
    router.pushUrl({ url: 'pages/FileTransferSettingsPage' });
  }

  /** Swift `NavigationLink -> LocationSharingSettingsView`. */
  private openLocationSharingSettings(): void {
    router.pushUrl({ url: 'pages/LocationSharingSettingsPage' });
  }

  /** Swift `NavigationLink -> VideoSettingsView`. */
  private openVideoSettings(): void {
    router.pushUrl({ url: 'pages/VideoSettingsPage' });
  }

  /** Swift `NavigationLink -> LogUI`. */
  private openDiagnosticsLog(): void {
    router.pushUrl({ url: 'pages/DiagnosticsLogPage' });
  }

  /* ── render ───────────────────────────────────────────────────────────────────────────── */
  /** Swift `Section(header:)` / `Section(footer:)` — plain text around the card. */
  @Builder
  sectionHeaderText(value: Resource) {
    // iOS grouped section header: an UPPERCASED grey caption indented to the card's content
    // edge. The uppercasing is the platform's, so the resource keeps the app's own casing.
    Text(value)
      .width('100%')
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .textCase(TextCase.UpperCase)
      .padding({
        start: LengthMetrics.resource($r('sys.float.padding_level10')),
        end: LengthMetrics.resource($r('sys.float.padding_level10')),
        top: LengthMetrics.resource($r('sys.float.padding_level8')),
        bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
      })
  }

  /** Swift `Section(footer:)` — the same grey caption, sentence case, under the card. */
  @Builder
  sectionFooterText(value: Resource) {
    Text(value)
      .width('100%')
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('app.color.secondary_label'))
      .padding({
        start: LengthMetrics.resource($r('sys.float.padding_level10')),
        end: LengthMetrics.resource($r('sys.float.padding_level10')),
        top: LengthMetrics.resource($r('sys.float.padding_level4'))
      })
  }

  /**
   * The leading glyph + title of a row carrying a BUNDLED glyph — the source SF Symbol's own
   * pixels, for the symbol this SDK's table has no unframed counterpart for. Same box, gap,
   * tint and label style SettingsRow gives a SymbolGlyph, so the row reads identically to its
   * siblings (Swift `Image(systemName:).resizable().aspectRatio(contentMode: .fit)
   * .frame(width: 18, height: 18).foregroundColor(.secondary).padding(.trailing, 5)`); the
   * secondary tint is baked into the asset (base + dark), because fillColor is SVG-only.
   */
  @Builder
  pngRowLabel(png: Resource, title: Resource) {
    Row() {
      Image(png)
        .width(ROW_GLYPH_SIZE)
        .height(ROW_GLYPH_SIZE)
        .objectFit(ImageFit.Contain)
        .margin({ right: $r('sys.float.ohos_id_card_margin_start') })
      // Wraps like SettingsRow's title (T-0624, T-0933).
      Text(title)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * Swift `NavigationLink(destination:) { SettingsRow(iconName:title:) }` — the whole row is
   * the tap target (the link is), and the chevron is what iOS draws for a NavigationLink with
   * no line of Swift (mapping-tables.md §7).
   */
  @Builder
  linkRow(glyph: Resource, title: Resource, slug: string, isFirst: boolean, isLast: boolean,
    onTap: () => void, glyphPng: Resource | null) {
    // The card is composed row by row, because the header and footer of an iOS section sit
    // OUTSIDE the card: only the rows carry the white fill, and the outer corners are rounded
    // on the first and last row of the section.
    Column() {
      Row() {
        // The label takes only what the chevron and its gap leave, so a long title
        // ("Connectivity and configurations" on the folded width) wraps instead of running
        // into the chevron (T-0624).
        Row() {
          // A row whose SF Symbol the symbol table has no unframed counterpart for passes its
          // glyph as a bundled media resource instead; SettingsRow draws a SymbolGlyph.
          if (glyphPng !== null) {
            this.pngRowLabel(glyphPng, title)
          } else {
            SettingsRow({ icon: glyph, title: title })
          }
        }
        .layoutWeight(1)
        // The chevron iOS draws for a NavigationLink with no line of Swift.
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.font_tertiary')])
          .margin({ left: CHEVRON_GAP })
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .padding({
        left: $r('sys.float.padding_level10'),
        right: $r('sys.float.padding_level10'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4')
      })
      // iOS draws the grouped separator itself, inset to the row's text leading edge, and
      // omits it under the last row of a section — which is the transparent case here.
      Divider()
        .strokeWidth(0.5)
        .color(isLast ? Color.Transparent : $r('sys.color.comp_divider'))
        .margin({ left: SEPARATOR_INSET })
    }
    .width('100%')
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius({
      topLeft: isFirst ? CARD_RADIUS : 0,
      topRight: isFirst ? CARD_RADIUS : 0,
      bottomLeft: isLast ? CARD_RADIUS : 0,
      bottomRight: isLast ? CARD_RADIUS : 0
    })
    .id(slug)
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Column() {
      // Swift `.navigationTitle(L10n.AccountPage.settingsHeader)` with the inline display
      // mode — iOS centres it in the bar's own optical row (mapping-tables.md §7) and draws the
      // leading back item itself, labelled with the ORIGIN page's title ("Account"). An @Entry
      // router page draws no system chrome, so that item is composed here.
      Stack({ alignContent: Alignment.Start }) {
        Text($r('app.string.account_page_settings_header'))
          .width('100%')
          .height(BAR_HEIGHT)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(TITLE_WEIGHT)
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
        // Padding, not margin, so the tap target still reaches the screen edge.
        .padding({ start: LengthMetrics.vp(BACK_LEADING) })
        .onClick(() => {
          this.goBack();
        })
      }
      .width('100%')
      .constraintSize({ minHeight: BAR_HEIGHT })

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .padding({
            start: LengthMetrics.resource($r('sys.float.padding_level10')),
            end: LengthMetrics.resource($r('sys.float.padding_level10')),
            bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
          })
      }

      List() {
        // Swift `Section(header: accountSettings, footer: accountSettingsExplanation)`.
        ListItemGroup({
          header: this.sectionHeaderText($r('app.string.global_account_settings')),
          footer: this.sectionFooterText($r('app.string.account_page_account_settings_explanation'))
        }) {
            // Swift `if model.account.type == .sip { … } else { … }` — the SIP account gets
            // Security alone; every other account gets the four Jami rows. The card's rounded
            // corners follow the branch: whichever row is FIRST in the section carries the top
            // corners, and Connectivity always carries the bottom ones.
            if (this.isSipAccount) {
              ListItem() {
                this.linkRow($r('sys.symbol.checkmark_shield'),
                  $r('app.string.account_page_security'),
                  'settings_summary_security', true, false,
                  () => {
                    this.openSecuritySettings();
                  }, null)
              }
            } else {
              ListItem() {
                this.linkRow($r('sys.symbol.message'), $r('app.string.account_page_chats'),
                  'settings_summary_chats', true, false, () => {
                    this.openChatSettings();
                  },
                  null)
              }
              ListItem() {
                this.linkRow($r('sys.symbol.phone'), $r('app.string.global_call'),
                  'settings_summary_call', false, false, () => {
                    this.openCallSettings();
                  },
                  null)
              }
              ListItem() {
                this.linkRow($r('sys.symbol.bell'),
                  $r('app.string.account_page_notifications_header'),
                  'settings_summary_notifications_header', false, false,
                  () => {
                    this.openNotificationSettings();
                  }, null)
              }
              ListItem() {
                this.linkRow($r('sys.symbol.externaldrive_3'),
                  $r('app.string.account_page_name_server'),
                  'settings_summary_name_server', false, false, () => {
                    this.openNameServer();
                  },
                  null)
              }
            }
            // Outside the branch in the source too — both account kinds get it, and it is the
            // section's last row either way.
            ListItem() {
              this.linkRow($r('sys.symbol.link'),
                $r('app.string.account_page_connectivity_and_configuration'),
                'settings_summary_connectivity_and_configuration', false, true,
                () => {
                  this.openConnectivitySettings();
                }, null)
            }
          }

        // Swift `Section(header: appSettings, footer: appSettingsExplanation)`.
        ListItemGroup({
          header: this.sectionHeaderText($r('app.string.account_page_app_settings')),
          footer: this.sectionFooterText($r('app.string.account_page_app_settings_explanation'))
        }) {
            // Swift `if model.account.type != .sip { … }`. On a SIP account Diagnostics is the
            // section's ONLY row, so it carries both the top and the bottom corners — which is
            // what the two guards below read.
            if (!this.isSipAccount) {
              ListItem() {
                this.linkRow($r('sys.symbol.folder'),
                  $r('app.string.general_settings_file_transfer'),
                  'settings_summary_file_transfer', true, false,
                  () => {
                    this.openFileTransferSettings();
                  }, null)
              }
              ListItem() {
                this.linkRow($r('sys.symbol.location_up'),
                  $r('app.string.general_settings_location_sharing'),
                  'settings_summary_location_sharing', false, false,
                  () => {
                    this.openLocationSharingSettings();
                  }, null)
              }
              ListItem() {
                this.linkRow($r('sys.symbol.video'), $r('app.string.global_video'),
                  'settings_summary_video', false, false, () => {
                    this.openVideoSettings();
                  },
                  null)
              }
            }
            ListItem() {
              // The source's `waveform.path.ecg` — the bare open zigzag, bundled, because no
              // unframed ECG path exists in the symbol table (see the header note).
              this.linkRow($r('app.media.ic_waveform_path_ecg'), $r('app.string.log_view_title'),
                'settings_summary_log_ui', this.isSipAccount, true,
                () => {
                  this.openDiagnosticsLog();
                }, $r('app.media.ic_waveform_path_ecg'))
            }
          }
      }
      .width('100%')
      .layoutWeight(1)
      // `List(.insetGrouped)`: the grey page the white cards sit on, with the 16 side inset
      // that makes them content-sized rather than edge to edge.
      .backgroundColor($r('sys.color.background_secondary'))
      .contentStartOffset(0)
      .padding({
        start: LengthMetrics.resource($r('sys.float.padding_level10')),
        end: LengthMetrics.resource($r('sys.float.padding_level10'))
      })
      // S6: the capture's tree carries iOS's own "Vertical scroll bar, 1 page" indicator —
      // shown while scrolling, faded out at rest. Auto is that behaviour.
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_settings_summary')
  }
}
