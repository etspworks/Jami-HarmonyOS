/*
 * comp_blocked_contact_row — ported from
 *   Ring/Ring/Features/Settings/Me/BlockedContactsView.swift `struct BlockedContactRowView`
 *   Ring/Ring/Features/Settings/Me/BlockedContactsVM.swift  `class BlockedContactsRowVM`
 *
 *   HStack {
 *     AvatarSwiftUIView(source: model)
 *     Spacer().frame(width: 15)
 *     VStack(alignment: .leading) {
 *       if !model.profileName.isEmpty    { Text(model.profileName) }
 *       if !model.registeredName.isEmpty { Text(model.registeredName) }
 *       else                             { Text(model.id).font(.footnote) }
 *     }
 *     Spacer().frame(width: 15)
 *     Spacer()
 *     Button { model.unblock() } label: { Text(unblockContact).foregroundColor(.jami) }
 *       .accessibilityIdentifier("blocked_contacts_unblock")
 *   }
 *
 * The row VM's own work is reproduced here, where the source put it: `getProfile()` subscribes
 * to `profileService.getProfile(uri:accountId:)` for the alias and the avatar, and
 * `getRegisteredName()` takes `contact.userName` when it has one and otherwise asks
 * `nameService.lookupAddress`. Neither the name nor the avatar is ever a literal.
 *
 * `unblock()` is the CALLER's action: the source's row VM reaches ContactsService and
 * PresenceService, and the page owns both of those here, so the row raises the intent and the
 * page performs it (and discloses the daemon gap, which is a screen-level notice).
 */
import { AvatarSwiftUIView } from './AvatarSwiftui';
import { AvatarSize } from '../common/JamiConstants';
import { DisposeBag } from '../common/Observable';
import { LookupNameResponse, NameService } from '../common/NameService';
import { ProfilesService } from '../common/ProfilesService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ContactModel } from '../model/ContactModel';
import { Profile } from '../model/Profile';
import { COPY_SHARE_MENU } from '../pages/AccountSummarySettingsRootPage';

/** Swift `super.init(... size: Constants.AvatarSize.default55)`. */
const ROW_AVATAR_SIZE: number = AvatarSize.DEFAULT_55;
/** Swift `Spacer().frame(width: 15)` — twice, either side of the name column. */
const ROW_GAP: number = 15;
/* ── S5: a SwiftUI List row — the avatar, the name lines at the body/footnote roles, and the
 * unblock action as a bare tinted label. The row height is the avatar plus the List's own
 * vertical inset. */
const ROW_PADDING_V: number = 8;

@Component
export struct BlockedContactRowView {
  /** Swift `let contact: ContactModel` — the banned contact this row stands for. */
  contact: ContactModel = new ContactModel();
  /** Swift `let account: AccountModel` — only its id is needed by the lookups below. */
  accountId: string = '';
  /** Swift `model.unblock()` — raised to the page, which owns the two services it needs. */
  onUnblock: (contact: ContactModel) => void = (contact: ContactModel): void => {
    console.debug('BlockedContactRowView: no onUnblock supplied for ' + contact.hash);
  };

  /** bindingContract[avatar]: svc_profiles <- AvatarSwiftUIView. Base64, as the vCard carries it. */
  @State avatar: string = '';
  /** Swift `@Published var profileName` — `profile.alias`. */
  @State profileName: string = '';
  /** bindingContract[name]: ContactModel.userName <- the contact's best name. */
  @State name: string = '';

  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.getProfile(registry.profileService);
    this.getRegisteredName(registry.nameService);
  }

  aboutToDisappear(): void {
    // ArkTS rule 8 — the row's subscriptions go with it.
    this.bag.dispose();
  }

  /** Swift `getProfile()` — the alias and the avatar, from svc_profiles. */
  private getProfile(profiles: ProfilesService): void {
    const uri: string | null = this.contact.uriString;
    if (uri === null || uri.length === 0) {
      return;
    }
    this.bag.add(profiles.getProfile(uri, this.accountId)
      .subscribe((profile: Profile): void => {
        const photo: string | null = profile.photo;
        if (photo !== null && photo.length > 0) {
          this.avatar = photo;
        }
        const alias: string | null = profile.alias;
        if (alias !== null && alias.length > 0) {
          this.profileName = alias;
        }
      }));
  }

  /**
   * Swift `getRegisteredName()` — `contact.userName` when it is set, otherwise the name
   * service's lookup of `contact.hash`.
   */
  private getRegisteredName(names: NameService): void {
    const userName: string | null = this.contact.userName;
    if (userName !== null && userName.length > 0) {
      this.name = userName;
      return;
    }
    this.bag.add(names.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
      if (response.requestedName !== this.contact.hash) {
        return;
      }
      const resolved: string | null = response.name;
      if (resolved !== null && resolved.length > 0) {
        this.name = resolved;
        this.contact.userName = resolved;
      }
    }));
    names.lookupAddress(this.accountId, '', this.contact.hash);
  }

  build() {
    // Swift `HStack { avatar; gap; names; gap; Spacer; unblock }`.
    Row() {
      AvatarSwiftUIView({
        avatarData: this.avatar,
        displayText: this.profileName.length > 0 ? this.profileName : this.name,
        isGroup: false,
        avatarSize: ROW_AVATAR_SIZE
      })

      // Swift `VStack(alignment: .leading) { … }` between the two 15pt spacers.
      Column() {
        // Swift `if !model.profileName.isEmpty { Text(model.profileName) }`.
        if (this.profileName.length > 0) {
          Text(this.profileName)
            .maxLines(1)
            // Swift `.lineLimit(1).truncationMode(.middle)` — one line, truncated, never
            // scrolled; ArkUI has no middle ellipsis, so the tail one stands in.
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.label'))
            // Swift `.textSelection(.enabled)` on each line: long press offers Copy | Share.
            .copyOption(CopyOptions.LocalDevice)
            .editMenuOptions(COPY_SHARE_MENU)
        }
        // Swift `if !model.registeredName.isEmpty { Text(registeredName) } else { Text(id) }`.
        if (this.name.length > 0) {
          Text(this.name)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // Swift `.font(model.profileName.isEmpty ? .footnote : .body)` — this line is the
            // row's only name when there is no profile name, and the smaller second line when
            // there is.
            .fontSize(this.profileName.length > 0
              ? $r('sys.float.Body_L')
              : $r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .editMenuOptions(COPY_SHARE_MENU)
        } else {
          // Swift `Text(model.id).font(.footnote)` — the id line is the smaller role.
          Text(this.contact.hash)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .editMenuOptions(COPY_SHARE_MENU)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: ROW_GAP, right: ROW_GAP })

      // Swift the unblock Button — the source's own identifier, on the tappable node itself.
      Button($r('app.string.account_page_unblock_contact'))
        .id('blocked_contacts_unblock')
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        // Swift `Text(unblockContact).foregroundColor(.jami)` — a bare tinted label.
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
        .padding(0)
        .onClick(() => {
          this.onUnblock(this.contact);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: ROW_PADDING_V, bottom: ROW_PADDING_V })
    // Rule 12's list-row exception: one shared id ending in `itemroot`, so the driver can
    // resolve a row by index instead of by a name that repeats.
    .id('blocked_contacts_itemroot')
  }
}
