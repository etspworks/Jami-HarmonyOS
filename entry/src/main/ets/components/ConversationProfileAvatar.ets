/*
 * comp_conversation_profile_avatar — ported from
 * Ring/Ring/SwarmInfo/ProfileEditing/ConversationProfileEditorAvatar.swift
 * `struct ConversationProfileEditorAvatar` (line 21), branch for branch:
 *
 *   Button(action: showOptions) { avatar.overlay(alignment: .bottomTrailing) { badge } }
 *     .accessibilityLabel(L10n.ProfileEditor.changePicture)
 *     .accessibilityValue(model.avatar == nil ? noPicture : pictureSelected)
 *     .accessibilityIdentifier("conversation_profile_editor_avatar_pick")
 *
 *   avatar    : ZStack { model.avatar -> Image(uiImage:) ; else noPicture }
 *               .frame(120).clipShape(Circle())
 *   noPicture : secondarySystemFill + Circle().strokeBorder(separator)
 *               + person.2.fill (swarm) / person.fill
 *   badge     : camera.fill on a Color.jami circle, ringed in systemGroupedBackground
 *
 * The WHOLE control is the tap target (Swift's Button wraps avatar + badge), so `.onClick`
 * and the Rule-12 slug sit on the outermost container — never on the glyph inside it.
 *
 * `model.avatar` is a UIImage in Swift and the base64 the profile layer stores here, exactly
 * as comp_avatar_swiftui carries it; it is DATA from svc_profiles, never a bundled placeholder.
 *
 * S5 — STYLE. Every value is the SOURCE's own declaration: `Layout` (120/34/15/2/2/0.5),
 * `AvatarMetrics.borderWidth = 1` for the placeholder's `Circle().strokeBorder(separator)`,
 * `.font(.system(size:weight: .semibold))` for both glyphs, and `AvatarPickerButtonStyle`'s
 * pressed state (opacity 0.75 / scale 0.97 over 0.12s). The iOS semantic COLOURS map to the
 * HarmonyOS token whose role matches: secondarySystemFill -> comp_background_secondary,
 * .separator -> ohos_id_color_list_separator, .secondaryLabel -> secondary_label,
 * systemGroupedBackground (the badge's ring, so it reads as cut out of the form) ->
 * background_secondary, and `Color.jami` stays the app's own accent.
 */
import { LengthMetrics } from '@kit.ArkUI';
import { AvatarSize } from '../common/JamiConstants';
import { photoImageSource } from './ExpandableAvatar';

/** Swift `Layout.avatarSize = Constants.AvatarSize.conversationInfo120.points`. */
const AVATAR_SIZE: number = AvatarSize.CONVERSATION_INFO_120;
/** Swift `Layout.badgeSize`. */
const BADGE_SIZE: number = 34;
/**
 * Swift `Layout.badgeIconSize` is 15, but an HM symbol draws ~20% smaller than an SF Symbol at
 * the same size (the camera read 10.7 vp tall against the simulator's 13 pt), so this is a
 * calibration knob, as ACTION_GLYPH_SIZE is on the info page (review T-1180).
 */
const BADGE_ICON_SIZE: number = 18;
/** Swift `Layout.badgeRingWidth`. */
const BADGE_RING_WIDTH: number = 2;
/** Swift `Layout.badgeInset`. */
const BADGE_INSET: number = 2;
/** Swift `Layout.placeholderIconRatio`. */
const PLACEHOLDER_ICON_RATIO: number = 0.5;
/** Swift `AvatarMetrics.borderWidth` — the placeholder circle's hairline. */
const PLACEHOLDER_BORDER_WIDTH: number = 1;
/** SwiftUI `.semibold`; ArkUI spells it as the numeric 600. */
const GLYPH_WEIGHT: number = 600;
/** Swift `AvatarPickerButtonStyle` — `.opacity(0.75).scaleEffect(0.97)` while pressed. */
const PRESSED_OPACITY: number = 0.75;
const PRESSED_SCALE: number = 0.97;
/** Swift `.animation(.easeOut(duration: 0.12))`. */
const PRESS_ANIMATION_MS: number = 120;

@Component
export struct ConversationProfileEditorAvatar {
  /** Swift `model.avatar` — the editor's current picture. Empty means none. */
  @Prop avatarData: string = '';
  /** Swift `model.isSwarm` — picks person.2.fill over person.fill. */
  @Prop isSwarm: boolean = false;
  /** Swift `@Binding var showingOptions: Bool`. */
  @Link showingOptions: boolean;

  /** Swift `showOptions()` — `hideKeyboard(); showingOptions = true`. */
  private showOptions(): void {
    // Swift `hideKeyboard()` sends resignFirstResponder; ArkUI has the same idea as an
    // explicit blur on the focused node, which the page owns — the flag is what matters here.
    this.showingOptions = true;
  }

  /** Swift `private var noPicture`. */
  @Builder
  private noPicture() {
    Stack() {
      SymbolGlyph(this.isSwarm ? $r('sys.symbol.person_2_fill') : $r('sys.symbol.person_fill'))
        .fontSize(AVATAR_SIZE * PLACEHOLDER_ICON_RATIO)
        .fontWeight(GLYPH_WEIGHT)
        .fontColor([$r('app.color.secondary_label')])
    }
    .width(AVATAR_SIZE)
    .height(AVATAR_SIZE)
    .backgroundColor($r('sys.color.comp_background_secondary'))
    .borderRadius(AVATAR_SIZE / 2)
    // Swift `Circle().strokeBorder(Color(UIColor.separator), lineWidth: borderWidth)` — the
    // ring that keeps a grey placeholder off a grey form.
    .borderWidth(PLACEHOLDER_BORDER_WIDTH)
    .borderColor($r('sys.color.ohos_id_color_list_separator'))
  }

  /** Swift `private var badge` — camera.fill (icon-map: sys.symbol.camera_fill). */
  @Builder
  private badge() {
    Stack() {
      SymbolGlyph($r('sys.symbol.camera_fill'))
        .fontSize(BADGE_ICON_SIZE)
        .fontWeight(GLYPH_WEIGHT)
        .fontColor([Color.White])
    }
    .width(BADGE_SIZE)
    .height(BADGE_SIZE)
    .backgroundColor($r('app.color.jami'))
    .borderRadius(BADGE_SIZE / 2)
    .borderWidth(BADGE_RING_WIDTH)
    .borderColor($r('sys.color.background_secondary'))
    .margin({ end: LengthMetrics.vp(BADGE_INSET), bottom: LengthMetrics.vp(BADGE_INSET) })
  }

  /** Swift `configuration.isPressed == false`. */
  @Styles
  private restingAvatar() {
    .opacity(1)
      .scale({ x: 1, y: 1 })
  }

  /** Swift `.opacity(0.75).scaleEffect(0.97)`. */
  @Styles
  private pressedAvatar() {
    .opacity(PRESSED_OPACITY)
      .scale({ x: PRESSED_SCALE, y: PRESSED_SCALE })
  }

  build() {
    // Swift `avatar.overlay(alignment: .bottomTrailing) { badge }`, inside the Button.
    Stack({ alignContent: Alignment.BottomEnd }) {
      // Swift `if let image = model.avatar { Image } else { noPicture }`: `model.avatar` is a
      // DECODED UIImage, so a photo that does not decode is nil and shows noPicture. Here the
      // photo is a base64 string, and an ArkUI Image that cannot decode it draws nothing, which
      // left only the badge on screen (T-1707). The placeholder is always laid down and a
      // photo that does decode covers it. The vCard's bare base64 is read as a data URI.
      this.noPicture()
      if (this.avatarData.length > 0) {
        Image(photoImageSource(this.avatarData))
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .clip(true)
          .objectFit(ImageFit.Cover)
      }
      this.badge()
    }
    .width(AVATAR_SIZE)
    .height(AVATAR_SIZE)
    .id('conversation_profile_editor_avatar_pick')
    // Swift `AvatarPickerButtonStyle` — the whole control dips while it is held. @Styles
    // takes no parameters, which is why the two states are declared as members below.
    .stateStyles({ normal: this.restingAvatar, pressed: this.pressedAvatar })
    .animation({ duration: PRESS_ANIMATION_MS, curve: Curve.EaseOut })
    // Swift `.accessibilityLabel(L10n.ProfileEditor.changePicture)` — the control is a glyph
    // with no text of its own, so the inventory label is its only readable name.
    .accessibilityText($r('app.string.profile_editor_change_picture'))
    .accessibilityDescription($r('app.string.profile_editor_change_picture_hint'))
    .onClick(() => {
      this.showOptions();
    })
  }
}
