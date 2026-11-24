/*
 * Ported from Ring/Ring/Helpers/SharedActionsPresenter.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * The iOS activity-sheet presenter becomes @kit.ShareKit systemShare. The pasteboard + toast fallback is
 * mandatory: a self-signed build can hit a device with no share panel, and the control must
 * never silently no-op (results/analysis/permission-substitutions.json, feat_share_sheet).
 * The About alert the Swift class also owned is UI and belongs to the About screen; the version
 * string it printed is JamiConstants.fullVersion().
 */
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { common, Want } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { describeError } from './ErrorText';

export enum ShareOutcome {
  SHARED = 'SHARED',
  COPIED_TO_CLIPBOARD = 'COPIED_TO_CLIPBOARD',
  FAILED = 'FAILED'
}

export class ShareActions {
  /** `SharedActionsPresenter.openDonationLink()` */
  static readonly DONATION_URL: string = 'https://jami.net/donate/';

  /**
   * The system share panel's action (`ohos.want.action.sendData`), which EntryAbility's skill in
   * module.json5 declares: it is what makes Jami a share target, the HarmonyOS counterpart of
   * the iOS jamiShareExtension's NSExtension activation rule.
   */
  private static readonly SEND_DATA_ACTION: string = 'ohos.want.action.sendData';
  /** What the share panel handed in, until ShareExtensionPage takes it. */
  private static incoming: Promise<systemShare.SharedRecord[]> | null = null;

  /**
   * EntryAbility: true when `want` came from the system share panel. Its records are read
   * (`systemShare.getSharedData`) and held for ShareExtensionPage, the iOS
   * `extensionContext.inputItems`.
   */
  static receiveSharedWant(want: Want): boolean {
    if (want.action !== ShareActions.SEND_DATA_ACTION) {
      return false;
    }
    ShareActions.incoming = systemShare.getSharedData(want)
      .then((data: systemShare.SharedData): systemShare.SharedRecord[] => data.getRecords())
      .catch((error: BusinessError): systemShare.SharedRecord[] => {
        console.error(`ShareActions.receiveSharedWant failed: ${describeError(error)}`);
        return [];
      });
    return true;
  }

  /**
   * ShareExtensionPage: the shared records, once. null when the page was not opened by the
   * share panel (nothing was shared in).
   */
  static takeSharedRecords(): Promise<systemShare.SharedRecord[]> | null {
    const records: Promise<systemShare.SharedRecord[]> | null = ShareActions.incoming;
    ShareActions.incoming = null;
    return records;
  }

  /**
   * `SharedActionsPresenter.shareAccountInfo(onViewController:sourceView:content:)`.
   * Falls back to the clipboard + a toast when the system share panel is unavailable, so the
   * caller always gets a visible result. Returns what actually happened.
   */
  static async share(context: common.UIAbilityContext, content: string,
                     title: string): Promise<ShareOutcome> {
    // The panel rejects a record with no payload (BusinessError 401, "Parameter error"), and an
    // empty string is exactly what the caller holds while the account list is a daemon gap. Not
    // an error - the user is told the feature has no data instead of the log carrying a failure.
    // A whitespace-only payload is as empty as '' here: `accountInfoToShare` joins its lines with
    // '\n', so a one-empty-line array arrives as '\n' and the panel rejects it the same way.
    if (content.trim().length === 0) {
      console.warn(`ShareActions.share skipped: no content to share (title "${title}")`);
      ShareActions.announce(context, 'daemon_not_available');
      return ShareOutcome.FAILED;
    }
    const record: systemShare.SharedRecord = {
      // The share panel's text scenario is `general.text`; `general.plain-text` is the clipboard
      // subtype and is not the id the panel matches target apps on.
      utd: uniformTypeDescriptor.UniformDataType.TEXT,
      content: content,
      title: title
    };
    const controller: systemShare.ShareController =
      new systemShare.ShareController(new systemShare.SharedData(record));
    const options: systemShare.ShareControllerOptions = {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DETAIL
    };
    try {
      await controller.show(context, options);
      return ShareOutcome.SHARED;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`ShareActions.share failed: ${describeError(err)}`);
      const copied: boolean = await ShareActions.copyToClipboard(context, content);
      return copied ? ShareOutcome.COPIED_TO_CLIPBOARD : ShareOutcome.FAILED;
    }
  }

  /**
   * Swift `MediaPreviewModel.share()` -> `ShareSheet(activityItems: [url])`: the local file
   * itself, typed from its extension (general.jpeg, general.mpeg-4, ...). A failure rejects
   * so the caller can say so; a file path on the clipboard would be no fallback.
   */
  static async shareFile(context: common.UIAbilityContext, filePath: string): Promise<void> {
    const dot: number = filePath.lastIndexOf('.');
    const record: systemShare.SharedRecord = {
      utd: dot < 0 ? uniformTypeDescriptor.UniformDataType.FILE
        : uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(filePath.substring(dot).toLowerCase()),
      uri: fileUri.getUriFromPath(filePath)
    };
    const controller: systemShare.ShareController =
      new systemShare.ShareController(new systemShare.SharedData(record));
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DETAIL
    });
  }

  /**
   * The share fallback, also the plain "copy" action of the account/swarm screens.
   * `toastResourceName` is the string resource announced to the user.
   */
  static async copyToClipboard(context: common.UIAbilityContext, content: string,
                               toastResourceName: string = 'global_copy'): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createPlainTextData(content);
      await pasteboard.getSystemPasteboard().setData(data);
      ShareActions.announce(context, toastResourceName);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`ShareActions.copyToClipboard failed: ${describeError(err)}`);
      return false;
    }
  }

  /** The one toast of this module: `resourceName` is the string announced to the user. */
  private static announce(context: common.UIAbilityContext, resourceName: string): void {
    try {
      const toast: promptAction.ShowToastOptions = {
        message: context.resourceManager.getStringByNameSync(resourceName),
        duration: 2000
      };
      promptAction.showToast(toast);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`ShareActions.announce failed: ${describeError(err)}`);
    }
  }

  /** `SharedActionsPresenter.openDonationLink()` - UIApplication.open -> UIAbilityContext.openLink. */
  static async openDonationLink(context: common.UIAbilityContext): Promise<boolean> {
    return ShareActions.openLink(context, ShareActions.DONATION_URL);
  }

  /**
   * `UIApplication.open(_:)`.
   *
   * NOT `UIAbilityContext.openLink`: that resolves App Linking only - a domain VERIFIED against
   * this bundle - so every plain `https:` and `mailto:` URL this app opens failed with
   * "No matching ability is found. (code 16000019)". The implicit want below is what a browser
   * and a mail client actually declare in their own `skills`, and it is how a third-party link
   * is opened on HarmonyOS.
   *
   * Returns true when the user got a result: the link opened, OR nothing handles it and the URL
   * went to the clipboard with a toast. False only when neither worked - the caller may then
   * disclose the URL itself, which is the last resort rather than the normal path.
   */
  static async openLink(context: common.UIAbilityContext, url: string): Promise<boolean> {
    const want: Want = {
      // `wantConstant.Action.ACTION_VIEW_DATA` (@ohos.ability.wantConstant:200) - the literal
      // rather than the import, because that module is the deprecated namespace and the current
      // `@ohos.app.ability.wantConstant` the Kit re-exports does not declare this action.
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      await context.startAbility(want);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      // Never silent: a device with no browser or no mail client is the expected case here
      // (16000019 / 16000010), not a defect to swallow.
      console.error(`ShareActions.openLink failed: ${describeError(err)}`);
      return ShareActions.copyToClipboard(context, url);
    }
  }
}
