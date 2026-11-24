/*
 * Ported from Ring/Ring/Constants/Constants.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * Pure literals. The iOS app-group container paths (documentsPath/cachesPath) have no
 * HarmonyOS equivalent - a UIAbilityContext gives filesDir/cacheDir directly - so they are
 * not carried over.
 */
import { bundleManager } from '@kit.AbilityKit';

/** Avatar diameters in vp. Swift `Constants.AvatarSize` (CGFloat points). */
export enum AvatarSize {
  CONVERSATION_20 = 20,
  ACCOUNT_28 = 28,
  CONVERSATION_30 = 30,
  MEDIUM_40 = 40,
  MEDIUM_45 = 45,
  MEDIUM_50 = 50,
  DEFAULT_55 = 55,
  ACCOUNT_60 = 60,
  CONVERSATION_INFO_80 = 80,
  ACCOUNT_100 = 100,
  CONVERSATION_INFO_120 = 120,
  CALL_160 = 160
}

/** Swift `Constants.NotificationUserInfoKeys`. */
export enum NotificationUserInfoKey {
  CALL_ID = 'callID',
  NAME = 'name',
  MESSAGE_CONTENT = 'messageContent',
  PARTICIPANT_ID = 'participantID',
  ACCOUNT_ID = 'accountID',
  CONVERSATION_ID = 'conversationID',
  CALL_URI = 'callURI'
}

/** Swift `Constants.NotificationCategory`. */
export enum NotificationCategory {
  CALL = 'CALL_CATEGORY'
}

/** Swift `Constants.NotificationAction`. */
export enum NotificationAction {
  ACCEPT_VIDEO = 'GROUP_ACCEPT_VIDEO_ACTION',
  ACCEPT_AUDIO = 'GROUP_ACCEPT_AUDIO_ACTION'
}

/**
 * Swift `Constants.NotificationActionTitle.toString()` returned an L10n string; on HarmonyOS
 * the caller resolves the resource name through its own resourceManager.
 */
export enum NotificationActionTitleResource {
  ACCEPT_WITH_VIDEO = 'calls_accept_with_video',
  ACCEPT_WITH_AUDIO = 'calls_accept_with_audio'
}

function buildSwarmColors(): Map<string, string> {
  const colors: Map<string, string> = new Map<string, string>();
  colors.set('#E91E63', 'swarm_colors_vibrant_pink');
  colors.set('#9C27B0', 'swarm_colors_purple');
  colors.set('#673AB7', 'swarm_colors_violet');
  colors.set('#3F51B5', 'swarm_colors_indigo_blue');
  colors.set('#2196F3', 'swarm_colors_sky_blue');
  colors.set('#00BCD4', 'swarm_colors_cyan');
  colors.set('#009688', 'swarm_colors_teal');
  colors.set('#4CAF50', 'swarm_colors_green');
  colors.set('#8BC34A', 'swarm_colors_lime_green');
  colors.set('#9E9E9E', 'swarm_colors_medium_gray');
  colors.set('#CDDC39', 'swarm_colors_yellow_green');
  colors.set('#FFC107', 'swarm_colors_amber');
  colors.set('#FF5722', 'swarm_colors_bright_orange');
  colors.set('#795548', 'swarm_colors_brown');
  colors.set('#607D8B', 'swarm_colors_steel_blue');
  return colors;
}

function buildDialpadKeys(): string[][] {
  const keys: string[][] = [];
  keys.push(['1', '2', '3']);
  keys.push(['4', '5', '6']);
  keys.push(['7', '8', '9']);
  keys.push(['*', '0', '#']);
  return keys;
}

export class JamiConstants {
  /** Swift `Constants.versionName`. */
  static readonly VERSION_NAME: string = 'Euclid';
  static readonly APP_IDENTIFIER: string = 'com.savoirfairelinux.jami';

  /** Preference / shared-state identifiers. */
  static readonly SELECTED_ACCOUNT_ID: string = 'SELECTED_ACCOUNT_ID';
  static readonly NOTIFICATION_DATA: string = 'notificationData';
  static readonly UPDATED_CONVERSATIONS: string = 'updatedConversations';
  static readonly QUERIED_ACCOUNT_ID: string = 'queriedAccountId';
  static readonly NOTIFICATIONS_COUNT: string = 'notificationsCount';
  static readonly SHARE_EXTENSION_ACTIVE_ACCOUNTS: string = 'shareExtensionActiveAccounts';

  /**
   * In-process event names. iOS posted these as Darwin notifications between the app and its
   * extensions; HarmonyOS has no extension processes here, so they are plain emitter ids.
   */
  static readonly EVENT_NOTIFICATION_RECEIVED: string = 'com.savoirfairelinux.notificationExtension.receivedNotification';
  static readonly EVENT_APP_IS_ACTIVE: string = 'com.savoirfairelinux.jami.appActive';
  static readonly EVENT_SHARE_EXTENSION_IS_ACTIVE: string = 'com.savoirfairelinux.shareExtension.isActive';
  static readonly EVENT_SHARE_EXTENSION_RESPONSE: string = 'com.savoirfairelinux.shareExtension.response';
  static readonly EVENT_NOTIFICATION_EXTENSION_IS_ACTIVE: string = 'com.savoirfairelinux.notificationExtension.isActive';
  static readonly EVENT_NOTIFICATION_EXTENSION_RESPONSE: string = 'com.savoirfairelinux.notificationExtension.accountActive';

  static readonly MAX_PROFILE_IMAGE_SIZE: number = 512;
  static readonly DEFAULT_AVATAR_SIZE: number = AvatarSize.DEFAULT_55;

  /** Swarm colour hex -> the string resource name holding its display name. */
  static readonly SWARM_COLORS: Map<string, string> = buildSwarmColors();

  /** The in-call dialpad grid (Ring/Ring/Calls/Views/CallScreenView.swift `InCallDialpadView`). */
  static readonly DIALPAD_KEYS: string[][] = buildDialpadKeys();

  /** About-screen credits, verbatim from Constants.swift. */
  static readonly CONTRIBUTORS_DEVELOPERS: string = 'Abhishek Ojha\nAdrien Béraud\nAlassane Yattara\nAlbert Babí\nAlexander Lussier-Cullen\nAlexandr Sergheev\nAlexandre Eberhardt\nAlexandre Lision\nAlexandre Savard\nAlexandre Viau\nAline Bonnet\nAline Gondim Santos\nAlireza Toghiani\nAmin Bandali\nAmirHossein Naghshzan\nAmna Snene\nAndreas Hatziiliou\nAndreas Traczyk\nAnthony Léonard\nBrando Tovar\nCapucine Berthet\nCharles-Francis Damedey\nChristophe Villemer\nCyrille Béraud\nDorina Mosku\nEden Abitbol\nÉdric Milaret\nÉloi Bail\nEmma Falkiewitz\nEmmanuel Lepage-Vallée\nEmmanuel Milou\nEric Bjarstal\nFadi Shehadeh\nFélix Boucher\nFranck Laurent\nFrançois-Simon Fauteux-Chapleau\nFrédéric Guimont\nGuillaume Heller\nGuillaume Roguez\nHadrien De Sousa\nHugo Lefeuvre\nHussein Abdallah\nIlyas Erdogan\nIo Daza-Dillon\nJérôme Lamy\nJulien Grossholtz\nJulien Robert\nKateryna Kostiuk\nKessler DuPont-Teevin\nLanius-collaris\nLarbi Gharib\nLéo Banno-Cloutier\nLéopold Chappuis\nLiam Courdoson\nLoïc Siret\nLouis Maillard\nMathéo Joseph\nMaxim Cournoyer\nMichel Schmit\nMingrui Zhang\nMohamed Amine Younes Bouacida\nMohamed Chibani\nNghia Dam\nNicolas Jäger\nNicolas Reynaud\nNicolas Vengeon\nOlivier Gregoire\nOlivier Soldano\nPage Magnier-Slimani\nPatrick Keroulas\nPavan Koushik Nellore\nPeymane Marandi\nPhilippe Gorley\nPierre Duchemin\nPierre Lespagnol\nPierre Nicolas\nRaphaël Brulé\nRawaha El Houssayni\nRayan Osseiran\nRomain Bertozzi\nSaher Azer\nSamuel Kayode\nSébastien Blin\nSeva Ivanov\nSilbino Gonçalves Matado\nSimon Désaulniers\nSimon Zeni\nStepan Salenikovich\nThibault Wittemberg\nThomas Ballasi\nTrevor Tabah\nVitalii Nikitchyn\nVsevolod Ivanov\nXavier Jouslin de Noray\nYang Wang\nZélie Leydert\nZiwei Wang';
  static readonly CONTRIBUTORS_MEDIA: string = 'Charlotte Hoffmann\nMarianne Forget';
  static readonly CONTRIBUTORS_COMMUNITY_MANAGEMENT: string = 'Dorina Mosku\nCabrel Tambue\nLoïc Bogino';
  static readonly SPECIAL_THANKS: string = 'Anna\nElys\nVeroJeanLuc';

  /**
   * Swift `Constants.fullVersion` - "<version>(<build>)". iOS derived the build number from the
   * Info.plist creation date; HarmonyOS carries a real versionCode, which is used instead.
   */
  static async fullVersion(): Promise<string> {
    const info: bundleManager.BundleInfo =
      await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return `${info.versionName}(${info.versionCode})`;
  }
}
