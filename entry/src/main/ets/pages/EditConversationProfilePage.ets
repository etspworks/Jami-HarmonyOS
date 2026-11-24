/*
 * screen_conversation_profile_editor — "Edit Conversation Profile", ported from
 *   Ring/Ring/SwarmInfo/ProfileEditing/ConversationProfileEditorView.swift
 *   Ring/Ring/SwarmInfo/ProfileEditing/ConversationProfileEditorVM.swift
 *   Ring/Ring/SwarmInfo/ProfileEditing/ConversationProfileEditorAvatar.swift
 *
 * presentation: modal, hostScreen: screen_swarm_info. `ConversationsCoordinator
 * .presentConversationProfileEditor` presents it with `.present`, so it is a @CustomDialog
 * mounted by SwarmConversationInfoPage — NOT a routed page and NOT in main_pages.json.
 *
 * S3 — the REAL component tree of `ConversationProfileEditorView.body`, unstyled:
 *
 *   NavigationView { Form {
 *     Section { ConversationProfileEditorAvatar(model:showingOptions:) }
 *     Section(header: name, footer: nameFooter) { TextField(namePlaceholder, $model.name) }
 *     if model.isSwarm { Section(header: description) { descriptionEditor } }
 *     if model.canResetContactProfile { Section { Button(resetOriginal) } }
 *   } .toolbar { Cancel ; Save.disabled(!model.hasChanges) } }
 *   .confirmationDialog($showingAvatarOptions) { takePhoto ; uploadPhoto
 *                                                ; if canRemoveAvatar { remove | reset }
 *                                                ; cancel }
 *   .sheet(item: $imagePickerType) { ImagePicker(...) }
 *   .alert(discardTitle, isPresented: $showingDiscardConfirmation) { cancel ; discard }
 *   .alert(saveError, isPresented: $model.saveFailed) {}
 *
 * The confirmationDialog and both alerts are rendered as IN-TREE Stack layers (the project's
 * CustomAlert idiom, as on ManageAccountPage) rather than promptAction menus: a system menu
 * contributes no addressable node, and every one of these controls carries a Rule-12 slug the
 * drivers must be able to find.
 *
 * conditionalVariants, each an ArkUI `if` on the field the plan names:
 *   avatar_dialog_open  -> isAvatarDialogOpen   has_picture         -> hasPicture
 *   has_original_picture-> hasOriginalPicture   has_original_profile-> hasOriginalProfile
 *   swarm               -> isSwarm              discard_alert       -> isDiscardAlert
 *   save_failed         -> isSaveFailed
 *
 * bindingContract: name <- ConversationModel.title, description <- ConversationModel.description,
 * avatar <- svc_profiles. All three are read off the services in `load()`; nothing on this
 * screen is a literal transcribed from a capture.
 *
 * Camera / photo-library capture (feat_camera_avatar, feat_photo_picker) goes through
 * comp_image_picker, which wraps @ohos.file.picker / @kit.CameraKit — both SYSTEM pickers, so
 * neither needs a permission on the self-signed allowlist.
 *
 * S4 — the plan's `@Link isPresented` is the editor's own dismissal flag. It lives on
 * `EditConversationProfileContent`, which holds every piece of the VM; the exported
 * `@CustomDialog EditConversationProfileOverlay` is a thin shell that owns the flag and
 * closes its injected controller when the content lowers it. That split is what lets BOTH
 * hosts (SwarmConversationInfoPage and ContactInfoPage) keep mounting the overlay with no
 * arguments — a @Link on the exported struct itself would need a binding at every builder
 * call site, and one of those files belongs to another screen. `conversationKey` stays an
 * optional member for the same reason: a host that passes none gets nothing loaded.
 */
import { LengthMetrics, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CustomAlert } from '../components/CustomAlert';
import { ConversationProfileEditorAvatar } from '../components/ConversationProfileAvatar';
import { ImagePicker, PhotoSheetType } from '../components/ImagePicker';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DaemonUnavailableError } from '../common/DaemonService';
import { DisposeBag } from '../common/Observable';
import { JamiUri, UriType } from '../common/JamiUri';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import {
  ConversationAttributes,
  ConversationModel
} from '../model/ConversationModel';
import { ConversationParticipant } from '../model/ConversationParticipant';
import { Profile } from '../model/Profile';

/** The AppStorage key the host writes before it opens this overlay. */
export const EDIT_CONVERSATION_KEY: string = 'editConversationKey';

/** Swift `@ScaledMetric private var descriptionMinHeight: CGFloat = 88`. */
const DESCRIPTION_MIN_HEIGHT: number = 88;
/** Swift `Layout.textEditorTopInset`. */
const TEXT_EDITOR_TOP_INSET: number = 8;
/** Swift `VStack(spacing:)` of the in-app alerts, matching the project's CustomAlert rows. */
const ALERT_STACK_GAP: number = 20;
/** `Form` section spacing. */
const FORM_SECTION_GAP: number = 16;

/*
 * S5 — STYLE ONLY. Every number below is either declared by the SOURCE or read as a FRAME
 * (never a colour) off the capture S0301, whose tree is in points on a 393x852 screen:
 *   NavigationBar [0,69]-[393,125]        -> a 56 pt bar, its items 28 pt tall at x 15/377
 *   avatar cell   [20,160]-[373,280]      -> the form's rows are inset 20, the avatar is 120
 *   "Name" header [20,297]-[373,336]      -> 39 pt, and the render up-cases it
 *   field cell    [20,336]-[373,380]      -> a 44 pt row
 *   footer cell   [20,380]-[373,430]
 * COLOUR and TYPE come from the iOS semantic ROLE, mapped to the HarmonyOS token whose role
 * matches (ios-to-harmonyos-design-tokens.md), never sampled from the PNG:
 *   systemGroupedBackground -> sys.color.background_secondary   (the form's grey page)
 *   secondarySystemGrouped  -> sys.color.comp_background_list_card (the white row)
 *   .label/.secondaryLabel  -> label / secondary_label
 *   .footnote section header-> Body_S ; inline nav title .headline -> Body_L semibold
 *   `.accentColor(.jami)`   -> app.color.jami for the bar items (the source's own accent)
 * The confirmationDialog and the two alerts are presented by UIKit OUTSIDE that accentColor,
 * so their actions keep the system tint (sys.color.font_emphasize) and the destructive one
 * sys.color.warning — exactly as EditProfilePage's ported action sheet does.
 * Nothing structural moves: the controls, bindings, branches and presentation are S1-S4's.
 */
/** The capture's nav band, 69..125. */
const NAV_BAR_HEIGHT: number = 56;
/** `.navigationBarTitleDisplayMode(.inline)` is 17 pt SEMIBOLD; ArkUI spells semibold as 600. */
const TITLE_WEIGHT: number = 600;
/** The form's first section starts 35 pt below the bar (125 -> 160 in the capture). */
const FORM_TOP_INSET: number = 35;
/** A grouped list row, 336..380 in the capture. */
const ROW_MIN_HEIGHT: number = 44;
/** iOS indents a grouped header/footer past its card; the capture puts both at x 40 (20+20). */
const HEADER_INDENT: number = 20;
/** iOS's grouped inset: rows at x 20 and their text at 20 inside (the system margin here is 16). */
const GROUPED_INSET: number = 20;
/** UIKit's action-sheet / alert row. */
const ALERT_ROW_HEIGHT: number = 57;
/**
 * The action sheet's insets and dim, as EditProfilePage's photo sheet: this dialog's window is
 * full-screen, so the sheet clears the navigation indicator the way iOS clears the home bar.
 */
const SHEET_INSET: number = 8;
const SHEET_BOTTOM_INSET: number = 34;
const SHEET_BACKDROP: string = '#33000000';

/**
 * Swift `ConversationProfileEditorVM` — ported into the struct rather than an @Observed class
 * because every @Published field of it is a render input, which in ArkUI V1 is @State.
 */
@Component
struct EditConversationProfileContent {
  /**
   * The plan's `isPresented`, owned by the host and lowered by every dismissal path of this
   * editor (Cancel with no edits, Discard, a completed Save). The shell below watches it.
   */
  @Link isPresented: boolean;
  /**
   * `<accountId>|<conversationId or first participant>` — the same key ContactInfoPage and
   * SmartListConversationsHomePage pass around, since a router/dialog param carries data and
   * not the ConversationModel object Swift's coordinator handed over.
   *
   * It arrives through AppStorage because a @CustomDialog's builder arguments are fixed when
   * the CONTROLLER is built, and a host builds its controller before it knows which
   * conversation the user will edit. The host writes the key immediately before `open()`.
   */
  @StorageProp('editConversationKey') conversationKey: string = '';

  /** bindingContract: name field <- ConversationModel.title (Swift `model.name`). */
  @State nameField: string = '';
  /** bindingContract: description <- ConversationModel.description. */
  @State description: string = '';
  /** bindingContract: avatar <- svc_profiles (base64, as the profile layer stores it). */
  @State avatar: string = '';

  /** conditionalVariants[avatar_dialog_open]: Swift `showingAvatarOptions == true`. */
  @State isAvatarDialogOpen: boolean = false;
  /** conditionalVariants[has_picture]: the swarm branch of `model.canRemoveAvatar`. */
  @State hasPicture: boolean = false;
  /** conditionalVariants[has_original_picture]: the contact branch of `canRemoveAvatar`. */
  @State hasOriginalPicture: boolean = false;
  /** conditionalVariants[has_original_profile]: Swift `model.canResetContactProfile`. */
  @State hasOriginalProfile: boolean = false;
  /** conditionalVariants[swarm]: Swift `model.isSwarm` — `!conversation.isCoredialog()`. */
  @State isSwarm: boolean = false;
  /** conditionalVariants[discard_alert]: Swift `showingDiscardConfirmation == true`. */
  @State isDiscardAlert: boolean = false;
  /** conditionalVariants[save_failed]: Swift `model.saveFailed == true`. */
  @State isSaveFailed: boolean = false;

  /** True while svc_conversations / svc_profiles are in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** The disclosed daemon gap, raised by this screen's own save path. */
  @State showDaemonNotice: boolean = false;

  /** Swift `@SwiftUI.State private var imagePickerType: PhotoSheetType?` — nil = closed. */
  @State private isPickerOpen: boolean = false;
  @State private pickerSource: PhotoSheetType = PhotoSheetType.GALLERY;
  /**
   * Swift `@SwiftUI.State private var selectedImage: UIImage?` plus its
   * `.onChange(of: selectedImage)` handler — @Watch is ArkUI's onChange.
   */
  @State @Watch('applyPickedImage') private selectedImage: string = '';
  /** Swift `model.hasChanges`, recomputed on every edit so Save's guard is reactive. */
  @State private hasChanges: boolean = false;

  // --- Swift VM members that are not render inputs -------------------------------------
  private conversation: ConversationModel | null = null;
  /** Swift `private var initialName`. */
  private initialName: string = '';
  /** Swift `private var initialDescription`. */
  private initialDescription: string = '';
  /** Swift `private let initialCustomPhoto: String?`. */
  private initialCustomPhoto: string | null = null;
  /** Swift `private let baseContactName: String?`. */
  private baseContactName: string | null = null;
  /** Swift `private let baseContactAvatar: UIImage?` (base64 here). */
  private baseContactAvatar: string = '';
  /** Swift `@Published private var avatarWasChanged`. */
  private avatarWasChanged: boolean = false;
  /** Swift `@Published private var useOriginalContactAvatar`. */
  private useOriginalContactAvatar: boolean = false;
  /** Swift `private var contactURI: String?`. */
  private contactURI: string | null = null;
  /** Swift `private let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();

  /**
   * The system status bar the DIALOG WINDOW draws under. A @CustomDialog gets a full-screen
   * window, unlike a router page, so without this the nav bar below is painted in the top
   * 137 px behind the status bar: Cancel sits on the clock, Save on the battery, and uitest
   * drops both from the dump because their bounds lie entirely inside the occluded strip —
   * which is what read as `contract-control-inert`. Swift's `NavigationView` bar is inset by
   * the same amount (the capture puts it at [0,53][393,97] under a 53 pt status bar).
   */
  @State private topInset: number = 0;

  aboutToAppear(): void {
    this.resolveTopInset();
    // The gap THIS overlay's own Save raises — the swarm half is a daemon write.
    this.bag.add(ServiceRegistry.shared().daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature === 'conversation.updateInfos') {
          this.showDaemonNotice = true;
          this.errorText = error.message;
        }
      }));
    this.load();
  }

  aboutToDisappear(): void {
    // ArkTS rule 8: the subscription goes whatever happened above.
    this.bag.dispose();
  }

  /** The window's own top avoid area — never a hardcoded status-bar height. */
  private resolveTopInset(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topInset = px2vp(area.topRect.height);
    }).catch((error: BusinessError): void => {
      // No avoid area readable — say so and keep the bar where it is rather than guessing.
      hilog.warn(0x0001, 'EditConversationProfile',
        'top avoid area unavailable: %{public}d', error.code);
    });
  }

  /**
   * Swift `init(conversation:injectionBag:)`, in its own order: the group branch reads the
   * daemon's conversation info; the one-to-one branch merges the peer's own profile with the
   * user's custom override.
   */
  private load(): void {
    const conversation: ConversationModel | null =
      EditConversationProfileContent.resolveConversation(this.conversationKey);
    this.conversation = conversation;
    if (conversation === null) {
      this.isLoading = false;
      this.refreshDerived();
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    // Swift `let isGroup = !conversation.isCoredialog(); isSwarm = isGroup`.
    this.isSwarm = !conversation.isCoredialog();
    if (this.isSwarm) {
      const info: Map<string, string> = registry.conversationsService
        .getConversationInfo(conversation.id, conversation.accountId);
      // Swift read the daemon map; with the daemon gap it comes back empty, so the model the
      // service already carries is what the screen shows — still data, never a literal.
      const title: string | undefined = info.get(ConversationAttributes.TITLE);
      const about: string | undefined = info.get(ConversationAttributes.DESCRIPTION);
      const picture: string | undefined = info.get(ConversationAttributes.AVATAR);
      this.nameField = title === undefined ? conversation.title : title;
      this.description = about === undefined ? conversation.description : about;
      this.avatar = picture === undefined ? conversation.avatar : picture;
      this.initialCustomPhoto = null;
      this.baseContactName = null;
      this.baseContactAvatar = '';
    } else {
      // Swift `description = ""` — a one-to-one profile has no description field at all.
      this.description = '';
      const uri: string | null = this.resolveContactUri(conversation);
      this.contactURI = uri;
      const base: Profile | null = uri === null
        ? null : registry.profileService.getOriginalProfile(uri, conversation.accountId);
      const custom: Profile | null = uri === null
        ? null : registry.profileService.getCustomProfile(uri, conversation.accountId);
      // Swift `base?.merging(preferring: custom) ?? custom`.
      let merged: Profile | null = base === null ? custom : base.merging(custom);
      const alias: string | null = merged === null ? null : merged.alias;
      const photo: string | null = merged === null ? null : merged.photo;
      this.nameField = alias === null ? '' : alias;
      this.avatar = photo === null ? '' : photo;
      this.initialCustomPhoto = custom === null ? null : custom.photo;
      this.baseContactName = base === null ? null : base.alias;
      const basePhoto: string | null = base === null ? null : base.photo;
      this.baseContactAvatar = basePhoto === null ? '' : basePhoto;
    }
    // Swift `initialName = name; initialDescription = description`.
    this.initialName = this.nameField;
    this.initialDescription = this.description;
    this.isLoading = false;
    this.refreshDerived();
  }

  /**
   * Swift `private static func contactURI(for:injectionBag:)` — the first participant's
   * jamiId under the account's own schema.
   */
  private resolveContactUri(conversation: ConversationModel): string | null {
    const participants: ConversationParticipant[] = conversation.getParticipants();
    if (participants.length === 0) {
      return null;
    }
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(conversation.accountId);
    if (account === null) {
      return null;
    }
    const schema: UriType = account.type === AccountType.SIP ? UriType.SIP : UriType.RING;
    return JamiUri.fromInfoHash(schema, participants[0].jamiId).uriString;
  }

  /** The same key split ContactInfoPage uses — one shape for every conversation handoff. */
  private static resolveConversation(key: string): ConversationModel | null {
    const separator: number = key.indexOf('|');
    if (key.length === 0 || separator < 0) {
      return null;
    }
    const accountId: string = key.substring(0, separator);
    const identity: string = key.substring(separator + 1);
    const conversations: ConversationModel[] =
      ServiceRegistry.shared().conversationsService.conversations.value;
    for (const conversation of conversations) {
      if (conversation.accountId !== accountId) {
        continue;
      }
      if (conversation.id === identity || conversation.hash === identity) {
        return conversation;
      }
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (participants.length > 0 && participants[0].jamiId === identity) {
        return conversation;
      }
    }
    return null;
  }

  /** Swift `private func normalized(_:)`. */
  private normalized(value: string): string {
    return value.trim();
  }

  /** Swift `private var hasCustomContactPicture`. */
  private hasCustomContactPicture(): boolean {
    return !this.useOriginalContactAvatar &&
      (this.initialCustomPhoto !== null || this.avatarWasChanged);
  }

  /**
   * Swift's four computed properties (`hasChanges`, `canResetContactProfile`,
   * `canRemoveAvatar` split into its two branches) recomputed in one place, because ArkUI
   * re-renders off @State and not off a getter.
   */
  private refreshDerived(): void {
    this.hasChanges =
      this.normalized(this.nameField) !== this.normalized(this.initialName) ||
      this.normalized(this.description) !== this.normalized(this.initialDescription) ||
      this.avatarWasChanged;
    // Swift `canResetContactProfile`: not a swarm, and either the name or the picture is the
    // user's own edit rather than the contact's.
    const baseName: string = this.baseContactName === null ? '' : this.baseContactName;
    this.hasOriginalProfile = !this.isSwarm &&
      (this.normalized(this.nameField) !== this.normalized(baseName) ||
        this.hasCustomContactPicture());
    // Swift `canRemoveAvatar`, by branch: the swarm one offers "Remove picture", the contact
    // one "Use original picture", so the plan carries them as two variants.
    this.hasPicture = this.isSwarm && this.avatar.length > 0;
    this.hasOriginalPicture = !this.isSwarm && this.hasCustomContactPicture();
  }

  /** Swift `.onChange(of: selectedImage)` — `model.avatar = image; model.avatarDidChange()`. */
  private applyPickedImage(): void {
    if (this.selectedImage.length === 0) {
      return;
    }
    this.avatar = this.selectedImage;
    // Swift `avatarDidChange()`.
    this.avatarWasChanged = true;
    this.useOriginalContactAvatar = false;
    this.selectedImage = '';
    this.refreshDerived();
  }

  /** Swift `private func takePhoto()` — `imagePickerType = .picture`. */
  private takePhoto(): void {
    this.isAvatarDialogOpen = false;
    this.pickerSource = PhotoSheetType.PICTURE;
    this.isPickerOpen = true;
  }

  /** Swift `private func choosePhoto()` — `imagePickerType = .gallery`. */
  private choosePhoto(): void {
    this.isAvatarDialogOpen = false;
    this.pickerSource = PhotoSheetType.GALLERY;
    this.isPickerOpen = true;
  }

  /** Swift `model.removeAvatar()`. */
  private removeAvatar(): void {
    this.isAvatarDialogOpen = false;
    this.avatarWasChanged = true;
    if (this.isSwarm) {
      this.avatar = '';
    } else {
      this.useOriginalContactAvatar = true;
      this.avatar = this.baseContactAvatar;
    }
    this.refreshDerived();
  }

  /** Swift `model.resetContactProfile()`. */
  private resetContactProfile(): void {
    if (this.isSwarm) {
      return;
    }
    this.nameField = this.baseContactName === null ? '' : this.baseContactName;
    this.useOriginalContactAvatar = true;
    this.avatarWasChanged = true;
    this.avatar = this.baseContactAvatar;
    this.refreshDerived();
  }

  /** Swift `private func cancel()`. */
  private cancel(): void {
    if (this.hasChanges) {
      this.isDiscardAlert = true;
    } else {
      this.dismiss();
    }
  }

  /** Swift `model.dismiss()` -> `dismissHandler.dismissView()`. */
  private dismiss(): void {
    // An overlay is not a stack entry, so lowering this never pops the host page — the
    // shell closes the dialog controller and the host page stays exactly where it was.
    this.isPresented = false;
  }

  /** Swift `model.save()`. */
  private save(): void {
    this.isSaveFailed = false;
    this.errorText = '';
    this.showDaemonNotice = false;
    if (this.isSwarm) {
      this.saveSwarm();
    } else {
      this.saveContact();
    }
  }

  /** Swift `private func saveSwarm()`. */
  private saveSwarm(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      this.isSaveFailed = true;
      return;
    }
    const service: ServiceRegistry = ServiceRegistry.shared();
    const info: Map<string, string> =
      service.conversationsService.getConversationInfo(conversation.id, conversation.accountId);
    info.set(ConversationAttributes.TITLE, this.normalized(this.nameField));
    info.set(ConversationAttributes.DESCRIPTION, this.normalized(this.description));
    if (this.avatarWasChanged) {
      // Swift converted the UIImage here; the picker already handed back the encoded bytes.
      info.set(ConversationAttributes.AVATAR, this.avatar);
    }
    service.conversationsService
      .updateConversationInfos(conversation.accountId, conversation.id, info);
    // Swift updated the model through the daemon's `conversationProfileUpdated` signal; with
    // the gap the local model is what the info screen reads back, so it is updated here.
    conversation.updateInfo(info);
    if (!service.daemonService.daemonStarted) {
      // The remote half of the save did NOT happen. The overlay stays open with the notice
      // the subscription above raised, instead of closing on a save that never left.
      this.showDaemonNotice = true;
      return;
    }
    this.dismiss();
  }

  /** Swift `private func saveContact()`. */
  private saveContact(): void {
    const conversation: ConversationModel | null = this.conversation;
    const uri: string | null = this.contactURI;
    if (conversation === null || uri === null) {
      // Swift `guard let contactURI else { saveFailed = true; return }`.
      this.isSaveFailed = true;
      return;
    }
    const trimmedName: string = this.normalized(this.nameField);
    const originalName: string =
      this.normalized(this.baseContactName === null ? '' : this.baseContactName);
    const customAlias: string | null =
      trimmedName.length === 0 || trimmedName === originalName ? null : trimmedName;
    let customPhoto: string | null = this.initialCustomPhoto;
    if (this.avatarWasChanged) {
      customPhoto = this.useOriginalContactAvatar
        ? null : (this.avatar.length === 0 ? null : this.avatar);
      if (!this.useOriginalContactAvatar && customPhoto === null) {
        // Swift `guard let image = avatar?.fixOrientation() ... else { saveFailed = true }`.
        this.isSaveFailed = true;
        return;
      }
    }
    const saved: boolean = ServiceRegistry.shared().profileService
      .updateCustomProfile(uri, conversation.accountId, customAlias, customPhoto);
    if (!saved) {
      this.isSaveFailed = true;
      return;
    }
    this.dismiss();
  }

  /** Swift `Section { HStack { Spacer; ConversationProfileEditorAvatar; Spacer } }`. */
  @Builder
  private avatarSection() {
    Row() {
      Blank()
      // The capture recorded this ONE control under both of its slugs: its
      // accessibilityIdentifier (`conversation_profile_editor_avatar_pick`, carried by the
      // component itself) and its accessibilityLabel slug (`change_picture`, sid S0305). An
      // element takes a single `.id()`, so the label slug goes on a content-sized wrapper
      // around it: a tap at its centre lands on the component inside, which owns the handler.
      Stack() {
        ConversationProfileEditorAvatar({
          avatarData: this.avatar,
          isSwarm: this.isSwarm,
          showingOptions: $isAvatarDialogOpen
        })
      }
      .id('change_picture')
      Blank()
    }
    .width('100%')
  }

  /** Swift `Section(header: name, footer: nameFooter) { TextField(...) }`. */
  @Builder
  private nameSection() {
    Column() {
      // The grouped section header: `.footnote`, secondaryLabel, UP-CASED by the platform —
      // the capture renders "NAME" from the same `L10n.ProfileEditor.name` string, so the
      // case is a text TRANSFORM here, never a second string.
      Text($r('app.string.profile_editor_name'))
        .width('100%')
        .textCase(TextCase.UpperCase)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .padding({
          start: LengthMetrics.vp(HEADER_INDENT),
          bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
        })
      TextInput({
        // Swift `model.namePlaceholder` — group vs contact.
        placeholder: this.isSwarm
          ? $r('app.string.profile_editor_group_name_placeholder')
          : $r('app.string.profile_editor_contact_name_placeholder'),
        text: this.nameField
      })
        .id('conversation_profile_editor_name')
        .width('100%')
        // The white inset-grouped row: 44 pt as a FLOOR, so the row still grows with the
        // system font size rather than clipping its own text.
        .constraintSize({ minHeight: ROW_MIN_HEIGHT })
        .padding({
          start: LengthMetrics.vp(GROUPED_INSET),
          end: LengthMetrics.vp(GROUPED_INSET)
        })
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .placeholderFont({ size: $r('sys.float.Body_L') })
        .caretColor($r('app.color.jami'))
        .onChange((value: string) => {
          this.nameField = value;
          this.refreshDerived();
        })
      // Swift `@ViewBuilder private var nameFooter` — shown only for a one-to-one contact.
      if (!this.isSwarm) {
        Text($r('app.string.profile_editor_local_changes_footer'))
          .width('100%')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('app.color.secondary_label'))
          .padding({
            start: LengthMetrics.vp(HEADER_INDENT),
            end: LengthMetrics.vp(HEADER_INDENT),
            top: LengthMetrics.resource($r('sys.float.padding_level4'))
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * Swift `private var descriptionEditor` — a TextEditor with a hand-drawn placeholder,
   * because SwiftUI's TextEditor has none. ArkUI's TextArea does, so the placeholder is the
   * component's own; Swift's insets are kept so the text sits where it did.
   */
  @Builder
  private descriptionSection() {
    Column() {
      Text($r('app.string.profile_editor_description'))
        .width('100%')
        .textCase(TextCase.UpperCase)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('app.color.secondary_label'))
        .padding({
          start: LengthMetrics.vp(HEADER_INDENT),
          bottom: LengthMetrics.resource($r('sys.float.padding_level4'))
        })
      TextArea({
        placeholder: $r('app.string.profile_editor_description_placeholder'),
        text: this.description
      })
        .id('conversation_profile_editor_description')
        .width('100%')
        .constraintSize({ minHeight: DESCRIPTION_MIN_HEIGHT })
        // Swift's own top inset, and the grouped row's side inset so the editor's first
        // character lands in the same column as the name field's.
        .padding({
          start: LengthMetrics.vp(GROUPED_INSET),
          end: LengthMetrics.vp(GROUPED_INSET),
          top: LengthMetrics.vp(TEXT_EDITOR_TOP_INSET),
          bottom: LengthMetrics.vp(TEXT_EDITOR_TOP_INSET)
        })
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.label'))
        .placeholderColor($r('app.color.placeholder_text'))
        .placeholderFont({ size: $r('sys.float.Body_L') })
        .caretColor($r('app.color.jami'))
        .onChange((value: string) => {
          this.description = value;
          this.refreshDerived();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Swift `if model.canResetContactProfile { Section { Button(resetOriginal) } }`. */
  @Builder
  private resetSection() {
    Row() {
      Blank()
      // Swift `Text(L10n.ProfileEditor.resetOriginal).foregroundColor(Color.jami)` — inside
      // the NavigationView, so this one DOES take the app accent, unlike the alert actions.
      Text($r('app.string.profile_editor_reset_original'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('app.color.jami'))
      Blank()
    }
    .width('100%')
    .constraintSize({ minHeight: ROW_MIN_HEIGHT })
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
    .id('conversation_profile_editor_reset_original')
    .accessibilityDescription($r('app.string.profile_editor_reset_original_hint'))
    .onClick(() => {
      this.resetContactProfile();
    })
  }

  /** Swift `.toolbar { cancellationAction ; confirmationAction }`. */
  @Builder
  private profileToolbar() {
    // The inline nav title is CENTRED on the screen, not between the two items — with a
    // short "Cancel" and a short "Save" a Row would put it off centre. The capture has it
    // at x 148..244 on a 393 pt screen, i.e. dead centre, so the title is its own layer.
    Stack({ alignContent: Alignment.Center }) {
      Row() {
        // Same control, same slug: the id and the handler sit on the container that wraps the
        // label so the on-device drivers read a clickable node, which is the shape the app's
        // other bar items (`back`) already use. A bare Text reports its own text bounds only.
        Row() {
          Text($r('app.string.global_cancel'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('app.color.jami'))
        }
        .alignItems(VerticalAlign.Center)
        .id('conversation_profile_editor_cancel')
        .onClick(() => {
          this.cancel();
        })
        Blank()
        Row() {
          Text($r('app.string.global_save'))
            .fontSize($r('sys.float.Body_L'))
            // A disabled bar item greys out on iOS; ArkUI's `.enabled(false)` does not restyle
            // a Text, so the disabled colour is spelled out. Style only — the guard is S4's.
            // iOS greys it to tertiaryLabel, rgba(60,60,67,0.3) (188,188,193 on the sheet):
            // secondary_label (0.6 alpha) at half opacity is that in both themes.
            .fontColor(this.hasChanges ? $r('app.color.jami') : $r('app.color.secondary_label'))
            .opacity(this.hasChanges ? 1 : 0.5)
            // A `.confirmationAction` bar item is semibold on iOS, enabled or not (review T-1178).
            .fontWeight(TITLE_WEIGHT)
        }
        .alignItems(VerticalAlign.Center)
        .id('conversation_profile_editor_save')
        // Swift `.disabled(!model.hasChanges)` — the source's real guard, not an invented one.
        .enabled(this.hasChanges)
        .onClick(() => {
          this.save();
        })
      }
      .width('100%')

      // Swift `.navigationTitle(model.navigationTitle)` in the bar's centre.
      Text(this.isSwarm
        ? $r('app.string.profile_editor_edit_group')
        : $r('app.string.profile_editor_edit_contact'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // The title is the LATER Stack child, so it is the topmost hit target over the bar
        // below it. It is a label, never a control: let the two bar items receive the touch.
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    // A floor, not a fix: the bar grows with the system font size instead of clipping.
    .constraintSize({ minHeight: NAV_BAR_HEIGHT })
    .padding({
      start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l')),
      end: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_l'))
    })
  }

  /**
   * Swift `.confirmationDialog("", isPresented: $showingAvatarOptions, titleVisibility: .hidden)`.
   * Rendered in tree so each option is an addressable node; the options themselves are the
   * source's, guarded by the same two branches of `model.canRemoveAvatar`. On iPhone it is an
   * action sheet: pinned to the bottom, the actions in one card and Cancel in its own, and a
   * tap on the dimmed screen dismisses it like Cancel (T-1691, T-1692).
   */
  @Builder
  private avatarOptions() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SHEET_BACKDROP)
        .accessibilityLevel('no')
        .onClick(() => {
          this.isAvatarDialogOpen = false;
        })

      Column({ space: SHEET_INSET }) {
        this.avatarActions()
        Text($r('app.string.global_cancel'))
          .id('conversation_profile_editor_dialog_cancel')
          .width('100%')
          .constraintSize({ minHeight: ALERT_ROW_HEIGHT })
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(TITLE_WEIGHT)
          .fontColor($r('sys.color.font_emphasize'))
          .backgroundColor($r('sys.color.background_primary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
          .onClick(() => {
            this.isAvatarDialogOpen = false;
          })
      }
      .width('100%')
      .padding({
        start: LengthMetrics.vp(SHEET_INSET),
        end: LengthMetrics.vp(SHEET_INSET),
        bottom: LengthMetrics.vp(SHEET_BOTTOM_INSET)
      })
    }
    .width('100%')
    .height('100%')
  }

  /** The action sheet's first card: every action but Cancel. */
  @Builder
  private avatarActions() {
    Column() {
      // UIKit's action-sheet rows: full-bleed 57 pt, centred, on the system tint (this
      // dialog is presented OUTSIDE the NavigationView's `.accentColor(.jami)`), hairline
      // separated.
      Text($r('app.string.alerts_profile_take_photo'))
        .id('conversation_profile_editor_profile_take_photo')
        .width('100%')
        .constraintSize({ minHeight: ALERT_ROW_HEIGHT })
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_emphasize'))
        .onClick(() => {
          this.takePhoto();
        })
      Divider()
        .color($r('sys.color.comp_divider'))
      Text($r('app.string.alerts_profile_upload_photo'))
        .id('conversation_profile_editor_profile_upload_photo')
        .width('100%')
        .constraintSize({ minHeight: ALERT_ROW_HEIGHT })
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_emphasize'))
        .onClick(() => {
          this.choosePhoto();
        })
      // conditionalVariants[has_picture] — the swarm branch of canRemoveAvatar.
      if (this.hasPicture) {
        Divider()
          .color($r('sys.color.comp_divider'))
        // Swift `role: .destructive` — red, the only one of the five that is.
        Text($r('app.string.profile_editor_remove_picture'))
          .id('conversation_profile_editor_remove_picture')
          .width('100%')
          .constraintSize({ minHeight: ALERT_ROW_HEIGHT })
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.warning'))
          .onClick(() => {
            this.removeAvatar();
          })
      }
      // conditionalVariants[has_original_picture] — the contact branch of canRemoveAvatar.
      if (this.hasOriginalPicture) {
        Divider()
          .color($r('sys.color.comp_divider'))
        Text($r('app.string.profile_editor_reset_picture'))
          .id('conversation_profile_editor_reset_picture')
          .width('100%')
          .constraintSize({ minHeight: ALERT_ROW_HEIGHT })
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.font_emphasize'))
          .onClick(() => {
            this.removeAvatar();
          })
      }
    }
    .width('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .borderRadius($r('sys.float.ohos_id_corner_radius_dialog'))
    .clip(true)
  }

  /** Swift `.alert(discardTitle, isPresented: $showingDiscardConfirmation)`. */
  @Builder
  private discardAlert() {
    Column({ space: ALERT_STACK_GAP }) {
      // UIKit's alert: headline 17 pt semibold centred, message 13 pt secondary centred,
      // then the two actions side by side — `role: .cancel` bold, `.destructive` red regular.
      Text($r('app.string.profile_editor_discard_title'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
      Text($r('app.string.profile_editor_discard_message'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
      Row() {
        // Rule: the alert headline and this control must not share a string, or the matcher
        // ties — Cancel here carries its own slug and its own handler.
        Text($r('app.string.global_cancel'))
          .id('conversation_profile_editor_discard_cancel')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(TITLE_WEIGHT)
          .fontColor($r('sys.color.font_emphasize'))
          .onClick(() => {
            this.isDiscardAlert = false;
          })
        Blank()
        // Swift `role: .destructive`.
        Text($r('app.string.profile_editor_discard'))
          .id('conversation_profile_editor_discard')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontSize($r('sys.float.Body_L'))
          .fontColor($r('sys.color.warning'))
          .onClick(() => {
            this.isDiscardAlert = false;
            this.dismiss();
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  /** Swift `.alert(L10n.ProfileEditor.saveError, isPresented: $model.saveFailed) {}`. */
  @Builder
  private saveErrorAlert() {
    Column({ space: ALERT_STACK_GAP }) {
      Text($r('app.string.profile_editor_save_error'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(TITLE_WEIGHT)
        .fontColor($r('app.color.label'))
      Text($r('app.string.global_ok'))
        .id('conversation_profile_editor_save_error_ok')
        .width('100%')
        .textAlign(TextAlign.Center)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_emphasize'))
        .onClick(() => {
          this.isSaveFailed = false;
        })
    }
    .width('100%')
  }

  build() {
    // Swift `NavigationView { Form { ... } }` plus the four presentation modifiers hung off
    // it, each of which is a layer over the form rather than a sibling of it.
    Stack() {
      Column() {
        this.profileToolbar()

        Scroll() {
          Column({ space: FORM_SECTION_GAP }) {
            this.avatarSection()
            this.nameSection()
            // conditionalVariants[swarm] — the description section is group-only.
            if (this.isSwarm) {
              this.descriptionSection()
            }
            // conditionalVariants[has_original_profile].
            if (this.hasOriginalProfile) {
              this.resetSection()
            }
            if (this.showDaemonNotice) {
              // The disclosed gap: a message about the save, laid out as a grouped row so it
              // reads as part of the form rather than as an alert over it.
              Text($r('app.string.daemon_not_available'))
                .width('100%')
                .id('conversation_profile_editor_daemon_notice')
                .fontSize($r('sys.float.Body_M'))
                .fontColor($r('app.color.secondary_label'))
                .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
                .backgroundColor($r('sys.color.comp_background_list_card'))
                .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            }
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .width('100%')
                .fontSize($r('sys.float.Body_M'))
                .fontColor($r('sys.color.warning'))
                .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
                .backgroundColor($r('sys.color.comp_background_list_card'))
                .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            }
          }
          .width('100%')
          // The form's own inset: rows at x 20..373 in the capture, which is the grouped
          // page margin, and the first section 35 pt below the bar.
          .padding({
            start: LengthMetrics.vp(GROUPED_INSET),
            end: LengthMetrics.vp(GROUPED_INSET),
            top: LengthMetrics.vp(FORM_TOP_INSET),
            bottom: LengthMetrics.resource($r('sys.float.margin_level2'))
          })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      // The dialog window is full-screen; the form starts below the status bar, as the source's
      // NavigationView does. Without it the nav bar is painted behind the system clock. The
      // layers below are not inset: their dim covers the status bar, as on iPhone.
      .padding({ top: this.topInset })

      // comp_image_picker contributes no view of its own; it launches the system picker as it
      // mounts and lowers isPickerOpen on both outcomes (Swift's `showingType = nil`).
      if (this.isPickerOpen) {
        ImagePicker({
          sourceType: this.pickerSource,
          image: $selectedImage,
          isPresented: $isPickerOpen
        })
      }

      // conditionalVariants[avatar_dialog_open].
      if (this.isAvatarDialogOpen) {
        this.avatarOptions()
      }
      // conditionalVariants[discard_alert].
      if (this.isDiscardAlert) {
        CustomAlert() {
          this.discardAlert()
        }
      }
      // conditionalVariants[save_failed].
      if (this.isSaveFailed) {
        CustomAlert() {
          this.saveErrorAlert()
        }
      }
    }
    .width('100%')
    .height('100%')
    // iOS `systemGroupedBackground` — the grey the whole form sits on, bar included.
    .backgroundColor($r('sys.color.background_secondary'))
    .id('screen_conversation_profile_editor')
  }
}

/**
 * The presented shell. `@CustomDialog` injects `controller`, so a host mounts it with no
 * arguments exactly as before; the content's `isPresented` is bound to this struct's own
 * state and the @Watch turns a lowered flag into the controller close.
 */
@CustomDialog
export struct EditConversationProfileOverlay {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /** True for as long as the editor is on screen; the content lowers it to dismiss. */
  @State @Watch('onPresentedChanged') private presented: boolean = true;

  aboutToAppear(): void {
    // A controller can be re-opened; the flag has to come back up with it or the second
    // open would close itself the moment the content mounted.
    this.presented = true;
  }

  private onPresentedChanged(): void {
    if (this.presented) {
      return;
    }
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  build() {
    EditConversationProfileContent({ isPresented: $presented })
  }
}
