/*
 * screen_blocked_contacts — "Blocked Contacts", ported from
 *   Ring/Ring/Features/Settings/Me/BlockedContactsView.swift
 *   Ring/Ring/Features/Settings/Me/BlockedContactsVM.swift
 *
 * presentation: page. ManageAccountView reaches it with a NavigationLink, so it is an @Entry
 * page pushed from ManageAccountPage; Back is the platform affordance, composed here because
 * an @Entry router page draws no system chrome (controlInventory's `implicit: true /
 * affordance: back` entry, hence `.id('back')`).
 *
 * S3 — the real tree of `BlockedContactsView.body`:
 *   List(model.blockedContacts) { contactViewModel in BlockedContactRowView(model:) }
 *     .navigationTitle(L10n.AccountPage.blockedContacts)
 *     .navigationBarTitleDisplayMode(.inline)
 *
 * bindingContract: the row set is `BlockedContactsVM.loadBannedContacts()` — the LIVE
 * `contactService.contacts` relay filtered to `contact.banned` — rendered through
 * `LazyForEach` over an `ArrayDataSource`. It starts EMPTY and is filled by svc_contacts;
 * there is no literal array anywhere here. On this platform the relay really is empty (no
 * daemon, so no contacts are loaded), and the empty state is the honest render of that.
 *
 * conditionalVariants: [empty] `isEmpty` — no blocked contacts, which is the captured state;
 * [has_rows] `hasRows` — one BlockedContactRowView per blocked contact. Two exclusive
 * branches, never both (an empty state rendered beside bound content is a defect).
 *
 * Unblock calls `ContactsService.unbanContact`, which reaches libjami and re-emits the
 * contacts relay, so the row leaves the list at once.
 */
import { router } from '@kit.ArkUI';
import { BlockedContactRowView } from '../components/BlockedContactRow';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { ContactsService } from '../common/ContactsService';
import { PresenceService } from '../common/PresenceService';
import { DisposeBag } from '../common/Observable';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AccountModel } from '../model/AccountModel';
import { ContactModel } from '../model/ContactModel';
import { BackChevron } from '../components/BackButton';

/** The composed inline navigation bar's own row. */
const BAR_HEIGHT: number = 44;
/** SwiftUI `List`'s own row inset. */
const ROW_INSET: number = 16;
/** ManageAccountView is what pushed this page — the coordinator root a cold deep link lacks. */
const MANAGE_ACCOUNT_PAGE: string = 'pages/ManageAccountPage';

/* ── S5 metrics (capture S0238, S0239, S0269, S0271) ──────────────────────────────────────
 * A pushed page: the inline bar with iOS's own navy back item over a PLAIN system background —
 * the capture is white edge to edge, not the grouped grey a `List` usually sits on, so the page
 * takes background_primary. Everything else is the semantic role for its part.
 */
/** The gap between the back chevron and its label. */
const BACK_GLYPH_GAP: number = 6;
/**
 * The clearance UINavigationBar needs between the back item and the centred title before it
 * swaps the origin's title for "Back" — EditPasswordFieldPage's BACK_FIT_MARGIN (T-1611).
 */
const BACK_FIT_MARGIN: number = 16;

@Entry
@Component
struct BlockedContactsPage {
  /**
   * bindingContract[blocked contact list] / [rows]: svc_contacts <- `BlockedContactsVM
   * .blockedContacts`. Starts empty and is filled by the service, never seeded with literals.
   */
  @State blockedContactList: ContactModel[] = [];
  /** conditionalVariants[empty]: Swift `model.blockedContacts.isEmpty`. */
  @State isEmpty: boolean = true;
  /** conditionalVariants[has_rows]: one BlockedContactRowView per blocked contact. */
  @State hasRows: boolean = false;
  /** True while svc_contacts is in flight. */
  @State isLoading: boolean = false;
  /** AppStorage['currentAccountId'] — svc_contacts is scoped to it. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /** The bar, its title and its back item, measured for the back label's fit (T-1630). */
  @State private barWidth: number = 0;
  @State private titleWidth: number = 0;
  /** The back item's width while it still shows the origin's title, kept once "Back" replaces it. */
  @State private fullBackWidth: number = 0;

  /** LazyForEach's source, reloaded from the relay (CLAUDE.md rule 7). */
  private rows: ArrayDataSource<ContactModel> = new ArrayDataSource<ContactModel>([]);
  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    this.loadBannedContacts(ServiceRegistry.shared().contactsService);
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the subscription goes whatever happens on the way out.
    this.bag.dispose();
  }

  /**
   * Swift `loadBannedContacts()` — `contactService.contacts.startWith(contacts.value)`, mapped
   * to the banned ones. The relay is the app's live contact set; `startWith` is the current
   * value applied before the subscription, which is what the first two lines do.
   */
  private loadBannedContacts(contacts: ContactsService): void {
    this.isLoading = true;
    this.applyContacts(contacts.contacts.value);
    this.bag.add(contacts.contacts.subscribe((values: ContactModel[]): void => {
      this.applyContacts(values);
    }));
    this.isLoading = false;
  }

  /** Swift's `compactMap { guard contact.banned else { return nil } }`. */
  private applyContacts(values: ContactModel[]): void {
    const banned: ContactModel[] = values.filter((contact: ContactModel) => contact.banned);
    this.blockedContactList = banned;
    this.rows.reload(banned);
    this.hasRows = banned.length > 0;
    this.isEmpty = !this.hasRows;
  }

  /**
   * Swift `BlockedContactsRowVM.unblock()` — `contactsService.unbanContact(contact:account:)`
   * then `presenceService.subscribeBuddy(...)`. Both live on this page, which owns the
   * services; the row raises the intent.
   */
  private unblock(contact: ContactModel): void {
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(this.currentAccountId);
    if (account === null) {
      return;
    }
    const contacts: ContactsService = ServiceRegistry.shared().contactsService;
    const presence: PresenceService = ServiceRegistry.shared().presenceService;
    // The service re-emits its relay, so applyContacts drops the row at once.
    contacts.unbanContact(contact, account);
    presence.subscribeBuddy(account.id, contact.hash, true);
  }

  /** The platform back affordance of a pushed page. */
  private goBack(): void {
    // A cold deep link can land here as the only entry on the stack, where `back()` would pop
    // the last page and drop the app; go to the pusher instead.
    if (router.getLength() === '1') {
      router.replaceUrl({ url: MANAGE_ACCOUNT_PAGE }).catch((error: Error): void => {
        console.error('BlockedContactsPage: replaceUrl ' + MANAGE_ACCOUNT_PAGE + ' failed: '
          + error.message);
      });
      return;
    }
    router.back();
  }

  /**
   * UINavigationBar swaps the origin's title for the generic "Back" when it would not fit left
   * of the centred title — T-1601's rule (T-1611).
   */
  private isBackShortened(): boolean {
    return this.fullBackWidth > 0 &&
      this.fullBackWidth + BACK_FIT_MARGIN > (this.barWidth - this.titleWidth) / 2;
  }

  /**
   * Swift `.navigationTitle(L10n.AccountPage.blockedContacts)
   * .navigationBarTitleDisplayMode(.inline)` plus iOS's own leading back item, labelled with
   * the ORIGIN page's title ("Manage account") when it fits, else "Back" (T-1630).
   */
  @Builder
  private navigationBar() {
    Stack({ alignContent: Alignment.Start }) {
      // `.navigationBarTitleDisplayMode(.inline)` — centred and semibold.
      Row() {
        Text($r('app.string.account_page_blocked_contacts'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.label'))
          .flexShrink(1)
          .onAreaChange((_old: Area, area: Area) => {
            this.titleWidth = Number(area.width);
          })
      }
      .width('100%')
      .height(BAR_HEIGHT)
      .justifyContent(FlexAlign.Center)

      // iOS's leading back item: the chevron and the origin page's title, both in the app tint.
      // VoiceOver reads the origin's title even when "Back" is shown.
      Row({ space: BACK_GLYPH_GAP }) {
        BackChevron()
        Text(this.isBackShortened() ? $r('app.string.actions_back_action')
          : $r('app.string.account_page_manage_account'))
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('app.color.jami'))
          .maxLines(1)
      }
      .id('back')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: BAR_HEIGHT })
      .accessibilityGroup(true)
      .accessibilityText($r('app.string.account_page_manage_account'))
      .onAreaChange((_old: Area, area: Area) => {
        if (!this.isBackShortened()) {
          this.fullBackWidth = Number(area.width);
        }
      })
      .onClick(() => {
        this.goBack();
      })
    }
    .width('100%')
    .constraintSize({ minHeight: BAR_HEIGHT })
    .onAreaChange((_old: Area, area: Area) => {
      this.barWidth = Number(area.width);
    })
  }

  build() {
    Column() {
      this.navigationBar()

      if (this.isLoading) {
        LoadingProgress()
          .id('blockedContactsLoading')
          .width(BAR_HEIGHT)
          .height(BAR_HEIGHT)
          .color($r('sys.color.font_secondary'))
      }

      // conditionalVariants[has_rows] / [empty] — exclusive branches of Swift's `List(...)`,
      // which draws nothing at all when the collection is empty.
      if (this.hasRows) {
        List() {
          LazyForEach(this.rows, (contact: ContactModel) => {
            ListItem() {
              BlockedContactRowView({
                contact: contact,
                accountId: this.currentAccountId,
                onUnblock: (picked: ContactModel): void => {
                  this.unblock(picked);
                }
              })
            }
          }, (contact: ContactModel) => contact.hash)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('sys.color.background_primary'))
        .divider({
          strokeWidth: 0.5,
          color: $r('sys.color.comp_divider'),
          startMargin: ROW_INSET
        })
        .padding({ left: ROW_INSET, right: ROW_INSET })
      } else if (this.isEmpty) {
        // The source's List renders an empty body; the screen keeps its chrome and says
        // nothing more, which is what the capture shows on an account that has blocked nobody.
        Column()
          .id('blockedContactsEmpty')
          .width('100%')
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    // The capture is white edge to edge, so the page is on the plain system background.
    .backgroundColor($r('sys.color.background_primary'))
    .id('screen_blocked_contacts')
  }
}
