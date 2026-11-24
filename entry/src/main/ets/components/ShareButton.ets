/*
 * comp_share_button — ported from Ring/Ring/Features/Settings/Me/UtilitiesViews.swift
 * `struct ShareButtonView<ButtonContent>` (line 35).
 *
 * The source has two bodies behind one API — a SwiftUI share link on iOS 16+, and below it a
 * Button that raises the platform's own share-sheet controller. Both share the same string
 * and wrap the SAME caller-supplied label, so on HarmonyOS the version branch disappears and
 * what is left is: a tappable label that hands `infoToShare` to the system share panel
 * (@kit.ShareKit systemShare, with the clipboard + toast fallback already in
 * common/ShareActions.ts). Neither source-platform API has a HarmonyOS counterpart and
 * neither is transcribed here.
 *
 * The source puts `.accessibilityIdentifier("shareButton")` on the button and lets the CALLER add
 * its own on top (AccountSummaryView: "account_summary_invite_friends"). ArkUI cannot stack
 * two ids on one node, so the caller's slug is passed in and the source default is kept for
 * callers that do not.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShareActions } from '../common/ShareActions';
import { describeError } from '../common/ErrorText';

@Component
export struct ShareButtonView {
  /** Swift `let infoToShare: String`. */
  infoToShare: string = '';
  /** Swift `.accessibilityIdentifier("shareButton")`, overridden per call site. */
  identifier: string = 'shareButton';
  /** The string resource announced as the share-panel title (`L10n.Global.share` by default). */
  titleResourceName: string = 'global_share';
  /** False when the label is already a full button (Swift's default `commonButtonStyle` one). */
  rowInsets: boolean = true;
  /** Swift `@ViewBuilder content: () -> ButtonContent` — the caller's own label. */
  @BuilderParam content: () => void;

  /** The source's share action — the same string, handed to the platform share panel. */
  private share(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ShareActions.share(context, this.infoToShare,
      context.resourceManager.getStringByNameSync(this.titleResourceName))
      .catch((error: BusinessError) => {
        console.error(`ShareButtonView.share failed: ${describeError(error)}`);
      });
  }

  build() {
    // S5 — style only: the source's `ShareLink`/`Button` is plain chrome (no tint, no
    // background of its own), so the whole visual identity of the row comes from the caller's
    // label. The wrapper contributes only the grouped-row padding the caller's Form cell gave
    // it, so a caller can drop the label straight into an inset-grouped card.
    Column() {
      this.content()
    }
    .width('100%')
    .padding(this.rowInsets ? {
      left: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      right: $r('sys.float.ohos_id_elements_margin_horizontal_l'),
      top: $r('sys.float.padding_level6'),
      bottom: $r('sys.float.padding_level6')
    } : 0)
    .id(this.identifier)
    .onClick(() => {
      this.share();
    })
  }
}
