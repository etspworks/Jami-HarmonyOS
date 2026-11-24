/*
 * comp_account_selection_sheet — ported from
 *   Ring/jamiShareExtension/ShareView.swift `struct AccountSelectionSheet` (line 676)
 *   + `struct AccountSelectionRowView` (line 714)
 *   Ring/jamiShareExtension/AccountViewModel.swift (the row's name and avatar)
 *
 *   NavigationView { List {
 *       Section(header: Text(L10n.ShareExtension.selectAccountTitle)) {
 *           ForEach(accounts) { account in
 *               AccountSelectionRowView(account:isSelected:) { selectedAccountId = account.id
 *                                                              isPresented = false }
 *                   .accessibilityIdentifier("share_account_itemroot") } } }
 *       .toolbar { ToolbarItem(.cancellationAction) { Button(L10n.Global.close) {
 *           isPresented = false } .accessibilityIdentifier("share_account_picker_close") } } }
 *
 *   AccountSelectionRowView = HStack(spacing: 12) {
 *       AccountAvatarView(account:size: 45) ; Text(account.name) ; Spacer()
 *       if isSelected { Image(systemName: "checkmark.circle.fill") } }
 *       .contentShape(Rectangle()).onTapGesture { onTap() }
 *
 * The row is instantiated once per account, so it carries the source's SHARED `…itemroot`
 * slug (Rule 12's list-row exception) and the whole row is the tap target, as `contentShape`
 * + `onTapGesture` make it.
 *
 * `checkmark.circle.fill` is an exact icon-map match.
 */
import { ArrayDataSource } from '../common/ArrayDataSource';
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { AccountModel } from '../model/AccountModel';
import { Profile } from '../model/Profile';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';

/** Swift `HStack(spacing: 12)`. */
const ROW_GAP: number = 12;
/** Swift `AccountAvatarView(account: account, size: 45)`. */
const ROW_AVATAR: number = 45;
/** Swift `.frame(width: 20, height: 20)` on the selection check. */
const CHECK_SIZE: number = 20;

/* ── S5 (NO CAPTURE — the source's own, plus the iOS defaults a grouped List inherits) ──
 * `List` + `Section(header:)` in a NavigationView, so iOS draws the grouped chrome for free
 * (mapping-tables.md §7): a grey page, a white content card, a grey caption header indented
 * to the card's content edge. The sheet's accent is the extension's AccentColor,
 * `app.color.jami_button_primary`.
 */
/** iOS inline navigation-bar height, and a grouped row's minimum. */
const NAV_BAR_HEIGHT: number = 44;
/** The standard screen side margin. */
const PAGE_INSET: number = 16;
/** `List(.insetGrouped)` — the white card's corner, and the iOS hairline. */
const CARD_RADIUS: number = 10;
const HAIRLINE: number = 0.5;

@Component
export struct AccountSelectionSheet {
  /** Swift `let accounts: [AccountViewModel]` <- svc_accounts `viewModel.accountList`. */
  @Prop accounts: AccountModel[] = [];
  /** Swift `@Binding var selectedAccountId: String?`. */
  @Link selectedAccountId: string;
  /** Swift `@Binding var isPresented: Bool`. */
  @Link isPresented: boolean;

  /** LazyForEach's source (CLAUDE.md rule 7) — the accounts the page handed over. */
  private rows: ArrayDataSource<AccountModel> = new ArrayDataSource<AccountModel>([]);
  /** Each account's own profile name and photo, by account id ('' = none). */
  private aliases: Map<string, string> = new Map<string, string>();
  private photos: Map<string, string> = new Map<string, string>();
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    this.rows.reload(this.accounts);
    // Swift `AccountViewModel.fetchAccountDetails`: follow each account's own profile. The relay
    // starts empty and fills ~100 ms later, so a single read at build time kept the username.
    for (const account of this.accounts) {
      this.bag.add(ServiceRegistry.shared().profileService.getAccountProfile(account.id)
        .subscribe((profile: Profile): void => {
          this.aliases.set(account.id, profile.alias === null ? '' : profile.alias);
          this.photos.set(account.id, profile.photo === null ? '' : profile.photo);
          // The row key carries the name and photo, so the reload rebuilds the changed row.
          this.rows.reload(this.accounts.slice());
        }));
    }
  }

  aboutToDisappear(): void {
    this.bag.dispose();
  }

  /**
   * Swift `AdapterService.resolveLocalAccountName(from:)` — the account's profile name, else the
   * registered name, else the Jami id.
   */
  private accountName(account: AccountModel): string {
    const alias: string = this.aliases.get(account.id) ?? '';
    return alias.length > 0 ? alias
      : account.registeredName.length > 0 ? account.registeredName : account.jamiId;
  }

  /** Swift `AccountAvatarView(account:)` — the account's profile photo, '' for the monogram. */
  private accountAvatar(account: AccountModel): string {
    return this.photos.get(account.id) ?? '';
  }

  /** Swift the row's `onTap` — selects the sending account and closes the sheet. */
  private select(account: AccountModel): void {
    this.selectedAccountId = account.id;
    this.isPresented = false;
  }

  /** Swift `AccountSelectionRowView(account:isSelected:onTap:)`. */
  @Builder
  private accountRow(account: AccountModel) {
    Row({ space: ROW_GAP }) {
      // Swift `AccountAvatarView(account:size: 45)`: photo, else the monogram on
      // `avatarBackgroundColor(for: name)` (T-1191: was a grey disc).
      AvatarSwiftUIView({
        avatarData: this.accountAvatar(account),
        displayText: this.accountName(account),
        avatarSize: ROW_AVATAR
      })

      Text(this.accountName(account))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // Swift `.truncationMode(.middle)`: an id-named account keeps both ends.
        .ellipsisMode(EllipsisMode.CENTER)
        .layoutWeight(1)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))

      Blank()

      // Swift `if isSelected { Image(systemName: "checkmark.circle.fill") }`.
      if (account.id === this.selectedAccountId) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(CHECK_SIZE)
          // The sheet's `.accentColor` — the extension's AccentColor.
          .fontColor([$r('app.color.jami_button_primary')])
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .padding({
      start: LengthMetrics.vp(PAGE_INSET),
      end: LengthMetrics.vp(PAGE_INSET),
      top: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s')),
      bottom: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
    })
    // The WHOLE row is Swift's tap target (`contentShape(Rectangle()).onTapGesture`).
    .id('share_account_itemroot')
    .accessibilityText($r('app.string.share_extension_accessibility_select_account'))
    .onClick(() => {
      this.select(account);
    })
  }

  build() {
    Column() {
      // Swift the cancellationAction toolbar item.
      Row() {
        Button($r('app.string.global_close'))
          .id('share_account_picker_close')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami_button_primary'))
          .constraintSize({ minHeight: NAV_BAR_HEIGHT })
          .onClick(() => {
            this.isPresented = false;
          })

        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: NAV_BAR_HEIGHT })
      .padding({ start: LengthMetrics.vp(PAGE_INSET), end: LengthMetrics.vp(PAGE_INSET) })
      .backgroundColor($r('sys.color.background_primary'))
      .border({ width: { bottom: HAIRLINE }, color: { bottom: $r('sys.color.comp_divider') } })

      // Swift `Section(header: Text(L10n.ShareExtension.selectAccountTitle))` — the grouped
      // header, grey caption, indented to the card's content edge.
      Text($r('app.string.share_extension_select_account_title'))
        .width('100%')
        // insetGrouped section headers are uppercased ('SELECT ACCOUNT' on iOS).
        .textCase(TextCase.UpperCase)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .padding({
          start: LengthMetrics.vp(PAGE_INSET * 2),
          end: LengthMetrics.vp(PAGE_INSET),
          top: LengthMetrics.resource($r('sys.float.margin_level2')),
          bottom: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
        })

      List() {
        LazyForEach(this.rows, (account: AccountModel) => {
          ListItem() {
            this.accountRow(account)
          }
        }, (account: AccountModel) =>
          `${account.id}|${this.accountName(account)}|${this.accountAvatar(account).length}`)
      }
      // No explicit width: the horizontal margin below reduces the List's own constraint,
      // while a width('100%') PLUS a margin overflows the Column in ArkUI. No height either:
      // the inset-grouped card ends after its last row, and only shrinks (then scrolls) when
      // the accounts outgrow the sheet.
      .flexShrink(1)
      // `List(.insetGrouped)` — a white content card inset from both page edges.
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius(CARD_RADIUS)
      .clip(true)
      .margin({ start: LengthMetrics.vp(PAGE_INSET), end: LengthMetrics.vp(PAGE_INSET) })
      .divider({
        strokeWidth: HAIRLINE,
        color: $r('sys.color.comp_divider'),
        startMargin: PAGE_INSET + ROW_AVATAR + ROW_GAP
      })
    }
    .width('100%')
    .height('100%')
    // The grey page iOS paints behind a grouped List.
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
