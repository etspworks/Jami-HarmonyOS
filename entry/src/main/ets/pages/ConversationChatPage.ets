/*
 * screen_conversation — "Conversation (chat)", ported from
 *   Ring/Ring/Features/Conversations/Conversation/ConversationViewController.swift
 *   Ring/Ring/Features/Conversations/Conversation/ConversationViewModel.swift
 *   .../MessageSwiftUI/Views/ConversationContainerView.swift  (the nav bar + the sheets)
 *   .../MessageSwiftUI/Views/MessagesListView.swift           (the body -> comp_messages_list)
 *
 * ConversationContainerView.body:
 *   MessagesListView(model: viewModel.swiftUIModel)
 *     .navigationBarItems(leading: conversationTitleView, trailing: trailingButtons)
 *     .sheet(isPresented: $showPeerServices) { PeerSharingSheet(...) }
 *
 *   conversationTitleView = Button(viewModel.showContactInfo) {
 *       HStack { AvatarSwiftUIView(navBarAvatarProvider)
 *                VStack { if !name.isEmpty { Text(name) }
 *                         if !navUserName.isEmpty && navUserName != name { Text(navUserName) } } } }
 *     .accessibilityIdentifier("conversationTitle")
 *
 *   visibleTrailingButtons = guard !isBlocked else { [] }        // a blocked conversation has
 *       peerSharing if hasPeerSharing                            // NO trailing buttons at all
 *       audioCall   always
 *       videoCall   if !isAccountSip
 *
 * S3 — the component tree and the controls. The 24 controls carry the capture's own slugs
 * (batch brief), the message list is comp_messages_list over svc_conversations, and the
 * fourteen conditional branches are built as real `if`s: the capture reached this screen with
 * an EMPTY conversation, so every branch here is read from the source.
 *
 * COMPOSITION ROOT. Every component of screen_conversation is instantiated HERE: the call
 * banner, the compose panel and the reactions overlay are mounted around comp_messages_list in
 * the slots the source's ZStack gives them, and the message composition (row -> content ->
 * bubble -> player -> seek slider, plus the reply history and the collaborative-document
 * announcement) is declared as the builders below and handed down through @BuilderParam. The
 * nesting is the source's; only the place each instantiation is WRITTEN is the page.
 *
 * OVERLAY HOST. This page mounts every `present` edge out of screen_conversation:
 * screen_contact_picker + screen_peer_sharing as sheets (ArkUI binds ONE sheet per component,
 * so the peer sheet binds to its own trigger control), and screen_call, screen_collab_editor,
 * screen_location_sharing, screen_media_preview and screen_media_record as @CustomDialogs.
 */
import { router, LengthMetrics, KeyboardAvoidMode, window } from '@kit.ArkUI';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocationSharingService } from '../common/LocationSharingService';
// feat_notifications: a conversation the user has opened must not keep its unread notification.
import { notificationManager } from '@kit.NotificationKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { DataTransferInfo } from '../common/DataTransferService';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from '../common/ServiceEvent';
// feat_photo_picker: Swift `MessagePanelState.openGalery` / `.sendPhoto` raise UIImagePicker.
import picker from '@ohos.file.picker';
import { ArrayDataSource } from '../common/ArrayDataSource';
import { AccountCallTracker, ActiveCall } from '../model/ActiveCall';
import { AvatarSize } from '../common/JamiConstants';
import { AvatarSwiftUIView, GroupAvatarMember, GroupAvatarSelection } from '../components/AvatarSwiftui';
import { groupAvatarFor, groupMember, groupTitleFor } from '../components/ExpandableAvatar';
import { BackChevron } from '../components/BackButton';
import { CallBannerView, ReturnToCallBar } from '../components/CallBanner';
import { CollabDocMessageModel, CollabDocMessageView } from '../components/CollabDocMessage';
import { ContextMenuView, ContextualMenuItem } from '../components/ContextMenu';
import { MediaSeekSlider } from '../components/MediaSeekSlider';
import {
  formatFileSize, MessageBubbleView, MessageContentModel, TransferAction
} from '../components/MessageBubble';
import { MessagePanelModel, MessagePanelView } from '../components/MessagePanel';
import { MessageRowModel, MessageRowView } from '../components/MessageRow';
import { MessageRowsDataSource, MessagesListView } from '../components/MessagesList';
import { PlayerMode, PlayerModel, PlayerView } from '../components/PlayerView';
import { ReactionRowModel, ReactionsView } from '../components/ReactionsView';
import { ReplyHistory, ReplyTargetModel } from '../components/ReplyHistory';
import { MessageContainerModel, MessageContentView } from '../components/MessageContent';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { memberEventName } from '../common/ConversationDataSource';
import { ConversationsService, TypingStatus } from '../common/ConversationsService';
import { DaemonUnavailableError } from '../common/DaemonService';
// feat_voice_call: with no system call provider the app activates the audio route itself.
import { AudioService } from '../common/AudioService';
// feat_background: a call holds a BackgroundTasksKit `voip` continuous task for its lifetime.
import { CallService } from '../common/CallService';
// feat_file_transfer: Swift `MessagePanelState.sendFile` -> DataTransferService.sendFile.
import { DataTransferService } from '../common/DataTransferService';
// feat_collab_docs: Swift `MessagePanelState.newCollabDocument`.
import { CreatedDocument } from '../common/CollaborationService';
// feat_share_sheet: the context menu's share item, with the clipboard + toast fallback.
import { ShareActions } from '../common/ShareActions';
// feat_persistence_profiles: the account's own vCard, read back from the sandbox.
import { ProfileStore } from '../common/ProfileStore';
import { DisposeBag } from '../common/Observable';
import { describeError } from '../common/ErrorText';
import { AccountModel } from '../model/AccountModel';
import { AccountType } from '../model/AccountConfigModel';
import { ConversationModel, ConversationType } from '../model/ConversationModel';
import { DEFAULT_SWARM_COLOR_ARGB } from '../model/ConversationPreferences';
import { LookupNameResponse, LookupNameState } from '../common/NameService';
import { ConversationParticipant, ParticipantRole } from '../model/ConversationParticipant';
import {
  DataTransferStatus, durationFormatted, isCenteredMessageType, MessageModel, MessageStatus, MessageType,
  timeLabelString
} from '../model/MessageModel';
import { media } from '@kit.MediaKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { MessageAction } from '../model/MessageAction';
import { Profile } from '../model/Profile';
import { PickerItem } from '../components/ContactRow';
import { CallId, CallDirection, CallState } from '../model/CallState';
import { ConfigKey } from '../model/ConfigKeyModel';
import { ContactPickerSheet } from './ContactPickerPage';
import { PeerServicesSheet } from './PeerServicesPage';
import { PeerServicesResult } from '../common/PeerSharingService';
import { InCallScreenOverlay } from './InCallScreenPage';
import {
  COLLAB_EDITOR_ACCOUNT_KEY, COLLAB_EDITOR_CONVERSATION_KEY, COLLAB_EDITOR_DOCUMENT_KEY,
  CollaborativeDocumentEditorOverlay
} from './CollaborativeDocumentEditorPage';
import { CollabNewDocumentDialog } from './CollaborativeDocumentsPage';
import { LocationSharingView, startLocationSharing } from './LocationSharingPage';
import { MediaPreviewOverlay, stageMediaPreview } from './MediaPreviewPage';
import {
  MEDIA_RECORD_AUDIO_ONLY_KEY,
  MEDIA_RECORD_CONVERSATION_KEY,
  RecordAudioVideoMessageOverlay
} from './RecordAudioVideoMessagePage';
import { PhotoCaptureOverlay } from './PhotoCapturePage';

/* ── S5 metrics, the source's own (ConversationContainerView.swift, View+Helpers.swift) ── */
/** Swift `MessagesListVM.messageGroupingInterval` — 10 minutes. */
const MESSAGE_GROUPING_INTERVAL_MS: number = 10 * 60 * 1000;
/** Swift `MessageRowVM` `topSpace` / `bottomSpace` at a sequence's start / end. */
const SEQUENCE_SPACE: number = 2;
/** Swift `startProgressMonitor()`: `Timer.scheduledTimer(timeInterval: 0.5, ...)`. */
const PROGRESS_INTERVAL_MS: number = 500;
/** Swift `ConversationNavBarLayout.avatarSpacing = 8`. */
const NAV_AVATAR_GAP: number = 8;
/** Capture S0025: the nav band is `[0,53][393,97]` — 44vp. */
const NAV_BAR_HEIGHT: number = 44;
/** iPhone 4.20 (WDA): the 44pt chevron-only back item at x=0, the title item at x=50. */
const BACK_TITLE_GAP: number = 6;

/** Whether the file's extension is of the given uniform type. */
function conformsTo(path: string, type: uniformTypeDescriptor.UniformDataType): boolean {
  const dot: number = path.lastIndexOf('.');
  if (dot < 0) {
    return false;
  }
  try {
    const descriptor: uniformTypeDescriptor.TypeDescriptor | null = uniformTypeDescriptor
      .getTypeDescriptor(uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(
        path.substring(dot).toLowerCase()));
    return descriptor !== null && descriptor.belongsTo(type);
  } catch (error) {
    return false;
  }
}

/** Swift `String.isMediaExtension()`: a video or audio type, or ogg / webm. */
function isMediaFile(path: string): boolean {
  return /\.(ogg|webm)$/i.test(path) || conformsTo(path, uniformTypeDescriptor.UniformDataType.VIDEO) ||
    conformsTo(path, uniformTypeDescriptor.UniformDataType.AUDIO);
}

/** Swift `PlayerViewModel`'s `playerInfo`: what the file says, read once per message. */
class MediaInfo {
  hasVideo: boolean = false;
  durationText: string = '';
  /** The video's shown width / height (rotation applied); 0 for audio. */
  ratio: number = 0;
}

/** Swift `onFileOpened` (duration, video stream) — read from the file with AVMetadataExtractor. */
async function readMediaInfo(path: string): Promise<MediaInfo> {
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const extractor: media.AVMetadataExtractor = await media.createAVMetadataExtractor();
    try {
      extractor.fdSrc = { fd: file.fd };
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'media info: video=%{public}s audio=%{public}s ' +
        'duration=%{public}s size=%{public}sx%{public}s orientation=%{public}s', metadata.hasVideo,
        metadata.hasAudio, metadata.duration, metadata.videoWidth, metadata.videoHeight,
        metadata.videoOrientation);
      // An extractor that cannot parse the container (the daemon recorder's .webm, VP8 + Opus)
      // answers with no duration and no tracks: the file counts as unread and the extension's
      // guess stands, as Swift keeps the seeded `hasVideo` until the player reports the streams.
      // Taken at its word, it turned a video message into a 00:00 audio player (T-1041).
      if (!(Number(metadata.duration ?? '0') > 0)) {
        throw new Error('no duration in the metadata');
      }
      const info: MediaInfo = new MediaInfo();
      info.hasVideo = metadata.hasVideo === 'yes';
      info.durationText = durationFormatted(Number(metadata.duration ?? '0') / 1000);
      const width: number = Number(metadata.videoWidth ?? '0');
      const height: number = Number(metadata.videoHeight ?? '0');
      if (info.hasVideo && width > 0 && height > 0) {
        const turned: boolean = metadata.videoOrientation === '90' || metadata.videoOrientation === '270';
        info.ratio = turned ? height / width : width / height;
      }
      return info;
    } finally {
      await extractor.release();
    }
  } finally {
    fs.closeSync(file);
  }
}

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ConversationChatPage';

/**
 * comp_media_seek_slider in a message's player. The player's position pushes must reach the
 * slider: read from a plain row object in the page's builder they were never tracked (the
 * thumb sat at 0 while playing, T-1719), so the read goes through this @ObjectLink. A move
 * writes `position`, which PlayerView's @Watch turns into a seek (Swift `viewModel.seek(to:)`).
 */
@Component
struct MessagePlayerSeekSlider {
  @ObjectLink player: PlayerModel;

  build() {
    MediaSeekSlider({
      positionRatio: this.player.position,
      onSeekChange: (value: number): void => {
        this.player.position = value;
      }
    })
  }
}

/** Swift pushed the conversation itself; ArkUI router params carry its `key` instead. */
interface ConversationRouteParams {
  conversationKey?: string;
  /** Set when the deep link named an overlay this page HOSTS rather than the page itself. */
  overlayScreen?: string;
}

@Entry
@Component
struct ConversationChatPage {
  /* ── bound content ─────────────────────────────────────────────────────────────── */
  /**
   * bindingContract[message list] <- svc_conversations, paginated. Swift
   * `MessagesListVM.messagesModels` rendered by MessagesListView's flipped List + LazyForEach.
   */
  @State messageListFlippedListLazyForEachOverMessagesListVM: MessageRowsDataSource =
    new MessageRowsDataSource();
  /** bindingContract[title] <- ConversationModel.title (ConversationViewModel.name). */
  @State title: string = '';
  /** Swift `viewModel.navUserName` — the registered name under the title, when it differs. */
  @State navUserName: string = '';
  /** bindingContract[avatar] <- svc_profiles (viewModel.navBarAvatarProvider). */
  @State avatar: string = '';
  /** Swift `groupAvatarSnapshot` — the member composite in the nav bar for a swarm. */
  @State groupAvatar: GroupAvatarSelection = new GroupAvatarSelection();
  /** Swift `MessagePanelVM` — the compose panel's own state. */
  @State private panel: MessagePanelModel = new MessagePanelModel();
  /** Swift `@SwiftUI.State private var text` — the draft. */
  @State @Watch('onDraftChanged') messageText: string = '';
  /** bindingContract[reactions] <- MessageModel.react — the open overlay's rows. */
  @State reactions: ArrayDataSource<ReactionRowModel> =
    new ArrayDataSource<ReactionRowModel>([]);

  private localized(resource: Resource, ...args: string[]): string {
    try {
      return getContext(this).resourceManager.getStringSync(resource.id, ...args);
    } catch (error) {
      return '';
    }
  }

  /** Swift `MessageContentVM`'s transfer half: where the file is, how big, how far along. */
  private applyTransfer(content: MessageContentModel, message: MessageModel): void {
    const conversation: ConversationModel | null = this.conversation;
    content.fileSize = message.totalSize;
    content.isImage = /\.(png|jpe?g|gif|webp|bmp|heic|heif)$/i.test(message.content);
    if (conversation === null) {
      return;
    }
    const info: DataTransferInfo | null = ServiceRegistry.shared().dataTransferService
      .dataTransferInfo(message.daemonId, conversation.accountId, conversation.id, true);
    // Swift draws the file on `.success` only. The daemon counts the bytes into "<path>.tmp" and
    // renames it after the sha3 check, so a full count alone named a file not there yet: the
    // image drew blank and no later key change redrew it until the chat was reopened (T-1597).
    const done: boolean = info !== null && info.totalSize > 0 && info.bytesProgress >= info.totalSize
      && fs.accessSync(info.path);
    content.filePath = done && info !== null ? info.path : '';
    if (info !== null && info.totalSize > 0) {
      content.fileSize = info.totalSize;
    }
    // A file already here is complete whatever the last event said.
    const status: DataTransferStatus = done ? DataTransferStatus.SUCCESS : message.transferStatus;
    // Swift `updateTransferActions()`.
    if (status === DataTransferStatus.CREATED || status === DataTransferStatus.AWAITING) {
      content.transferActions = message.incoming ? [TransferAction.ACCEPT, TransferAction.CANCEL]
        : [TransferAction.CANCEL];
    } else {
      content.transferActions = status === DataTransferStatus.ONGOING ? [TransferAction.CANCEL] : [];
    }
    // Swift `updateFileDescription()` with `DataTransferStatus.description`, English in 4.20.
    // Created/awaiting/error describe as '', and the iPhone draws no line for them (its size
    // lookup lands after the first description), so neither does this.
    const description: string = status === DataTransferStatus.ONGOING ? 'Transferring'
      : status === DataTransferStatus.SUCCESS ? 'Completed'
        : status === DataTransferStatus.CANCELED ? 'Canceled' : '';
    content.transferText = description.length === 0 ? ''
      : content.fileSize === 0 ? description : formatFileSize(content.fileSize) + ' - ' + description;
    // Swift `startProgressMonitor()`; `updateProgressMonitor` re-reads it every 0.5 s.
    content.showProgress = status === DataTransferStatus.ONGOING;
    content.fileProgress = info !== null && content.fileSize > 0
      ? Math.min(1, info.bytesProgress / content.fileSize) : 0;
    // Swift `TransferHelper.getPlayer`: a received or sent audio / video file plays in place.
    content.hasPlayer = content.filePath.length > 0 && isMediaFile(content.filePath);
    if (content.hasPlayer) {
      this.applyPlayer(content);
    }
  }

  /**
   * Swift `PlayerViewModel`: `hasVideo` seeded from the extension until the file is read, a
   * video starts muted (`audioMuted = true`) and audio-only plays unmuted; the duration shows
   * before the first play.
   */
  private applyPlayer(content: MessageContentModel): void {
    const player: PlayerModel = content.player;
    player.path = content.filePath;
    const info: MediaInfo | undefined = this.mediaInfo.get(content.message.id);
    if (info === undefined) {
      player.hasVideo = !conformsTo(content.filePath, uniformTypeDescriptor.UniformDataType.AUDIO);
      player.isMuted = player.hasVideo;
      this.readMediaInfo(content.message.id, content.filePath);
      return;
    }
    player.hasVideo = info.hasVideo;
    player.isMuted = info.hasVideo;
    player.durationText = info.durationText;
    // Swift sizes the bubble from the player's first frame. The AVPlayer reports it turned; the
    // extractor's size was not, so a portrait iPhone video sat in a 16:9 box (T-1601).
    content.playerRatio = this.videoRatios.get(content.message.id) ?? info.ratio;
  }

  /** Swift `updatePlayer(player:)`: the frame the player shows resizes the bubble once. */
  private videoRatioShown(messageId: string, ratio: number): void {
    if (ratio <= 0 || this.videoRatios.get(messageId) === ratio) {
      return;
    }
    this.videoRatios.set(messageId, ratio);
    const conversation: ConversationModel | null = this.conversation;
    if (conversation !== null) {
      this.publishMessages(conversation);
    }
  }

  private readMediaInfo(messageId: string, path: string): void {
    if (this.mediaInfoPending.has(messageId)) {
      return;
    }
    this.mediaInfoPending.add(messageId);
    readMediaInfo(path)
      .then((info: MediaInfo): void => {
        this.mediaInfo.set(messageId, info);
        const conversation: ConversationModel | null = this.conversation;
        if (conversation !== null) {
          this.publishMessages(conversation);
        }
      })
      .catch((error: Object): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'media info unreadable: %{public}s',
          describeError(error as BusinessError));
      });
  }

  /** Swift `TransferState.accept` / `.cancel` -> TransferHelper.acceptTransfer / cancelTransfer. */
  private transferAction(container: MessageContainerModel, action: TransferAction): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const message: MessageModel = container.content.message;
    const transfers: DataTransferService = ServiceRegistry.shared().dataTransferService;
    if (action === TransferAction.ACCEPT) {
      transfers.downloadFile(message.daemonId, message.id, conversation.accountId, conversation.id);
    } else {
      transfers.cancelTransfer(message.daemonId, conversation.accountId, conversation.id);
    }
  }

  /**
   * Swift `startProgressMonitor()` / `stopProgressMonitor()`: while an incoming transfer is
   * ongoing its progress is re-read every 0.5 s (Swift's per-bubble Timer).
   */
  private updateProgressMonitor(conversation: ConversationModel, rows: MessageRowModel[]): void {
    const ongoing: boolean = rows.some((row: MessageRowModel) =>
      row.container.content.showProgress && row.container.content.message.incoming);
    if (ongoing && this.progressTimer < 0) {
      // ponytail: re-publishes the whole list per tick; a per-bubble poll if long chats lag.
      const timer: number = setInterval((): void => {
        if (this.conversation === conversation) {
          this.publishMessages(conversation);
        }
      }, PROGRESS_INTERVAL_MS);
      this.progressTimer = timer;
      this.conversationBag.add((): void => {
        clearInterval(timer);
        this.progressTimer = -1;
      });
    } else if (!ongoing && this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /** Swift `textMenuItems()` / `fileTransferMenuItems()`. */
  private menuItemsFor(content: MessageContentModel): string[] {
    if (content.messageDeleted) {
      return [];
    }
    const incoming: boolean = content.message.incoming;
    if (content.type === MessageType.TEXT) {
      if (incoming) {
        return [ContextualMenuItem.REPLY, ContextualMenuItem.COPY, ContextualMenuItem.FORWARD];
      }
      return [ContextualMenuItem.REPLY, ContextualMenuItem.EDIT, ContextualMenuItem.COPY,
      ContextualMenuItem.FORWARD, ContextualMenuItem.DELETE_MESSAGE];
    }
    if (content.type === MessageType.FILE_TRANSFER) {
      // Swift: Save and Preview need the file on this device (`url != nil`); an audio file
      // (`player?.hasVideo.value == false`) has nothing to preview.
      const items: string[] = content.filePath.length === 0
        ? [ContextualMenuItem.REPLY, ContextualMenuItem.FORWARD, ContextualMenuItem.SHARE]
        : content.hasPlayer && !content.player.hasVideo
          ? [ContextualMenuItem.REPLY, ContextualMenuItem.SAVE, ContextualMenuItem.FORWARD,
          ContextualMenuItem.SHARE]
          : [ContextualMenuItem.REPLY, ContextualMenuItem.SAVE, ContextualMenuItem.FORWARD,
          ContextualMenuItem.PREVIEW, ContextualMenuItem.SHARE];
      if (!incoming) {
        items.push(ContextualMenuItem.DELETE_MESSAGE);
      }
      return items;
    }
    return [];
  }

  /**
   * Opens a file that is on this device. One that is not is fetched with Accept, as on iOS
   * (DefaultTransferView answers no tap).
   */
  private openFile(container: MessageContainerModel): void {
    const conversation: ConversationModel | null = this.conversation;
    const content: MessageContentModel = container.content;
    if (conversation === null || content.filePath.length === 0) {
      return;
    }
    // Swift `presentMediaPreview()`: an image or a video opens the in-app preview; any other
    // file goes to the system viewer (Swift `ContextMenu.openDocument`).
    if (this.openMediaPreview(container)) {
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: fileUri.getUriFromPath(content.filePath),
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    this.hostContext().startAbility(want)
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `delete()` — an edition with an empty body, which every member renders as deleted. */
  private deleteContextMessage(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    ServiceRegistry.shared().conversationsService.editSwarmMessage(conversation.id,
      conversation.accountId, '', this.contextMenuMessage.id);
  }

  /** Swift `callBannerViewModel.activeCalls` <- svc_calls. */
  @State activeCalls: ActiveCall[] = [];
  /** Swift `model.typingIndicatorText`. */
  @State private typingIndicatorText: string = '';
  /** Swift `model.syncMessage`. */
  @State private syncMessage: string = '';
  /** Swift `model.contextMenuModel` — the message the context menu was raised over. */
  @State private contextMenuMessage: MessageContainerModel = new MessageContainerModel();
  /**
   * Swift `MessagePanelVM.messageToReply?.message.id` — the parent the next send threads onto.
   * Its own field: the swipe never raises the context menu, so `contextMenuMessage` is not it.
   */
  private replyMessageId: string = '';
  /** Swift `MessagePanelVM.messageToEdit?.message.id` — fixed when Edit is picked. */
  private editMessageId: string = '';
  /** Swift `model.contextMenuModel.menuItems`. */
  @State private contextMenuItems: ContextualMenuItem[] = [];
  /** Swift `cxModel.isOurMsg`. */
  @State private contextMenuOurMessage: boolean = false;

  /* ── conditionalVariants ───────────────────────────────────────────────────────── */
  /** [actions_expanded]: the media action row is expanded. */
  @State isActionsExpanded: boolean = false;
  /** [replying_or_editing]: MessagePanelVM.isEdit / reply target set. */
  @State isReplyingOrEditing: boolean = false;
  /** [temporary_conversation]: the conversation is not yet accepted. */
  @State isTemporaryConversation: boolean = false;
  /** [ended]: EndedConversationView. */
  @State isEnded: boolean = false;
  /** [syncing]: SyncingConversationView. */
  @State isSyncing: boolean = false;
  /** [blocked]: BlockView + unblock button. */
  @State isBlocked: boolean = false;
  /**
   * Swift `ConversationViewModel.hasPeerSharing` — the peer-services button, only once a
   * one-to-one peer answers the services query with at least one exposed service.
   */
  @State hasPeerSharing: boolean = false;
  /** [swarm]: group conversation — the title routes to SwarmInfoView. */
  @State isSwarm: boolean = false;
  /**
   * Swift `MessagesListVM`: `messagePanel.canWriteDocuments = conversation.isSwarm()`
   * (MessagesListVM.swift:226) — the gate on the collaborative-document media action.
   * It starts TRUE because the jami daemon is the disclosed Rule-11 gap: with no daemon no
   * conversation ever resolves, and the source's own default for a swarm conversation (which
   * is what every captured state of this screen is) is the honest reading of "not yet known".
   * The moment a real conversation lands, `isSwarm()` is what decides it.
   */
  @State private canWriteDocuments: boolean = true;
  /** [active_call_banner]: CallBannerViewModel.activeCalls non-empty. */
  @State isActiveCallBanner: boolean = false;
  /** [context_menu_open]: contextMenuPresentingState != .none. */
  @State isContextMenuOpen: boolean = false;
  /** Swift `keyboardHeight > 0` (Publishers.keyboardHeight). */
  private keyboardUp: boolean = false;
  /** Swift `keyboardWasActiveBeforeMenu`: the long press took the keyboard down. */
  private keyboardWasActiveBeforeMenu: boolean = false;
  /** [reactions_open]: the reactions overlay is shown. */
  @State isReactionsOpen: boolean = false;
  /** [scrolled_up]: the list is scrolled away from the bottom. */
  @State @Watch('onScrolledUpChanged') isScrolledUp: boolean = false;
  /** Swift `MessagesListVM.numberOfNewMessages`. */
  @State private newMessagesCount: number = 0;
  /** Swift `MessagesListVM.swarmColor` <- `conversation.preferences.getColor()`. */
  @State private swarmColor: number = DEFAULT_SWARM_COLOR_ARGB;
  /** Swift `lastMessageBeforeScroll` — the newest message when the list left the bottom. */
  private lastMessageBeforeScroll: string = '';
  /** [typing]: TypingIndicatorView shown for a typing peer. */
  @State isTyping: boolean = false;
  /** [empty]: no messages loaded — the captured state. */
  @State isEmpty: boolean = true;
  /** Swift `viewModel.isAccountSip` — a SIP account offers no video call. */
  @State private isAccountSip: boolean = false;
  /** True while svc_conversations is in flight. */
  @State isLoading: boolean = true;
  /** describeError() output from util_error_text; empty when there is no failure. */
  @State errorText: string = '';
  /** AppStorage['currentAccountId'], written by svc_accounts on an account switch. */
  @StorageLink('currentAccountId') currentAccountId: string = '';
  /**
   * The disclosed daemon gap raised by THIS screen's own controls. Rendered as a visible
   * overlay layer so a daemon-backed control is never a silent no-op; the next action clears it.
   */
  @State showDaemonNotice: boolean = false;

  /** Swift `let disposeBag = DisposeBag()`. */
  private bag: DisposeBag = new DisposeBag();
  /** The open conversation's own streams; replaced whenever another conversation is applied. */
  private conversationBag: DisposeBag = new DisposeBag();
  /** The running `updateProgressMonitor` interval, -1 when none. */
  private progressTimer: number = -1;
  /** Each media message's file info, by message id, and the reads still running. */
  private mediaInfo: Map<string, MediaInfo> = new Map<string, MediaInfo>();
  private mediaInfoPending: Set<string> = new Set<string>();
  /** Each video message's width / height as its AVPlayer shows it (rotation applied). */
  private videoRatios: Map<string, number> = new Map<string, number>();
  /** Swift `MessagesListVM.currentlyTypingUsers`, kept as jami ids and named when shown. */
  private typers: Set<string> = new Set<string>();
  /** Swift `MessagesListVM.avatars`: the message authors whose profile this page follows. */
  private trackedAuthors: Set<string> = new Set<string>();

  /** A deep link's overlay is presented once per arrival, not on every `onPageShow`. */
  private deepLinkOverlayOpened: boolean = false;
  /** Between `onPageShow` and `onPageHide`: a message that arrives while hidden stays unread. */
  private pageVisible: boolean = false;
  /** Swift `var conversation: ConversationModel!`, resolved from the route param. */
  private conversation: ConversationModel | null = null;

  /* ── overlays ──────────────────────────────────────────────────────────────────── */
  /** screen_call — presentation: modal; the overlay's own presentation flag. */
  @State private showCallScreen: boolean = false;
  /** screen_contact_picker — presentation: sheet, hostScreen: screen_conversation. */
  @State private showContactPicker: boolean = false;
  /**
   * Swift `ContactPickerViewModel.type`, decided by the CALLER: the in-call "add participant"
   * raises `.forCall`, the Forward item `.forConversation`.
   */
  @State private contactPickerForConversation: boolean = false;
  /** screen_peer_sharing — presentation: sheet, hostScreen: screen_conversation. */
  @State private showPeerServices: boolean = false;

  /** screen_call — presentation: modal, hostScreen: screen_conversation. */
  private callDialog: CustomDialogController = new CustomDialogController({
    builder: InCallScreenOverlay({
      isPresented: $showCallScreen,
      onAddParticipant: (): void => {
        this.openContactPicker(false);
      }
    }),
    autoCancel: false,
    // Back closes the call screen; the call goes on (the return bar brings it back).
    cancel: (): void => {
      this.showCallScreen = false;
    },
    // T-1731: Back with an in-call sheet open closes only the sheet, as iOS.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK && InCallScreenOverlay.closeOpenPanel()) {
        return;
      }
      this.showCallScreen = false;
      action.dismiss();
    },
    customStyle: true,
    // The Add participant search sits flush on the keyboard, not 16vp above it (T-1470).
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });

  /** screen_collab_editor — presentation: modal, hostScreen: screen_conversation. */
  /** screen_location_sharing's own presentation flag, plus the peer it was opened for. */
  @State private showLocationSharing: boolean = false;
  @State private locationAccountId: string = '';
  @State private locationPeerUri: string = '';
  /** Swift `PeerSharingViewModel(accountId:peerId:)` — the peer screen_peer_sharing queries. */
  @State private peerServicesAccountId: string = '';
  @State private peerServicesPeerId: string = '';

  /** screen_collab_editor's own presentation flag, plus the document it was opened for. */
  @State private showCollabEditor: boolean = false;
  @State private collabAccountId: string = '';
  @State private collabConversationId: string = '';
  @State private collabDocumentId: string = '';

  private collabEditorDialog: CustomDialogController = new CustomDialogController({
    builder: CollaborativeDocumentEditorOverlay({
      isPresented: $showCollabEditor,
      accountId: this.collabAccountId,
      conversationId: this.collabConversationId,
      documentId: this.collabDocumentId
    }),
    autoCancel: true,
    // T-1602: Back with a prompt, the menu or the keyboard up closes only that.
    onWillDismiss: (action: DismissDialogAction): void => {
      if (action.reason === DismissReason.PRESS_BACK
        && CollaborativeDocumentEditorOverlay.closeOpenLayer()) {
        return;
      }
      this.showCollabEditor = false;
      action.dismiss();
    },
    customStyle: true,
    // Swift presents the editor full screen: the default inset dialog box put its top bar
    // under the status bar (Close clipped to 2px, untappable), so it gets the whole window
    // and pads itself by the system avoid area, as mediaPreviewDialog does.
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    // The format bar sits ON the keyboard, as iOS's: the default 16 vp distance showed a strip
    // of the chat between the two (same as CollaborativeDocumentsPage, T-1330).
    keyboardAvoidDistance: LengthMetrics.vp(0)
  });

  /** Swift `promptNewCollabDocument()` — the "New document" alert. */
  private collabNameDialog: CustomDialogController = new CustomDialogController({
    builder: CollabNewDocumentDialog({
      onCreate: (name: string): void => {
        this.createCollabDocument(name);
      }
    }),
    autoCancel: false,
    // Centred on phones too (the default is bottom there), as iOS's alert-style prompt.
    alignment: DialogAlignment.Center,
    customStyle: true,
    // UIAlertController focuses its first text field on present: cursor in, keyboard up (T-1318).
    onDidAppear: (): void => {
      focusControl.requestFocus('collab_name_prompt_field');
    }
  });

  /**
   * screen_media_preview's presentation flag. This page owns it; the overlay holds it by
   * @Link and lowers it as it dismisses, so a Close/drag dismissal inside the preview is
   * visible here without reading the controller.
   */
  @State private isMediaPreviewPresented: boolean = false;

  /** screen_media_preview — presentation: modal, hostScreen: screen_conversation. */
  private mediaPreviewDialog: CustomDialogController = new CustomDialogController({
    builder: MediaPreviewOverlay({
      isPresented: $isMediaPreviewPresented,
      // Swift `model.forwardCallback` — the preview picks the rooms, the conversation sends.
      onForwardSelected: (ids: string[]): void => {
        this.forwardMessage(ids);
      },
      // Swift `MediaPreviewActionsDelegate.deleteMessage()` — a daemon commit, reported.
      onDelete: (): void => {
        this.deleteContextMessage();
      },
      // Jami 4.21 MediaPreviewConversationActions: Reply quotes the message in this page's
      // composer (the viewer has closed), React sends / withdraws a reaction on it (T-1624).
      onReply: (): void => {
        this.replyTo(this.contextMenuMessage);
        focusControl.requestFocus('messagePanelTextField');
      },
      onReact: (emoji: string): void => {
        this.pickEmoji(emoji);
      },
      onRevokeReaction: (reactionId: string): void => {
        this.revokeReaction(reactionId);
      }
    }),
    autoCancel: true,
    customStyle: true,
    // S5: Swift `MediaPreviewView ... .ignoresSafeArea()` — the preview covers the whole
    // window, so the dialog box is given the full window rather than the default inset one.
    width: '100%',
    height: '100%',
    cornerRadius: 0,
    // A tap outside closes the dialog without running dismiss(), so the flag is lowered here
    // too — otherwise the host would believe the preview is still up.
    cancel: (): void => {
      this.isMediaPreviewPresented = false;
    }
  });

  /**
   * screen_media_record's `.overCurrentContext` presentation flag. This page owns it; the
   * overlay holds it by @Link and lowers it as it dismisses, so a Cancel/Send inside the
   * recorder is visible here without reading the controller.
   */
  @State private isMediaRecordPresented: boolean = false;

  /** screen_media_record — presentation: modal, hostScreen: screen_conversation. */
  private mediaRecordDialog: CustomDialogController = new CustomDialogController({
    builder: RecordAudioVideoMessageOverlay({ isPresented: $isMediaRecordPresented }),
    autoCancel: true,
    customStyle: true
  });

  /** Swift `takePicture()`'s camera picker, presented `.overFullScreen` (T-0755). */
  private photoCaptureDialog: CustomDialogController = new CustomDialogController({
    builder: PhotoCaptureOverlay({
      onUsePhoto: (path: string): void => {
        this.sendPickedFile(path);
      }
    }),
    autoCancel: false,
    customStyle: true,
    width: '100%',
    height: '100%',
    cornerRadius: 0
  });

  /* ── lifecycle ─────────────────────────────────────────────────────────────────── */
  /**
   * Swift `ConversationViewController.viewWillAppear` + `ConversationViewModel.conversation`'s
   * didSet: resolve the conversation, publish every bound value, then mark it read.
   */
  aboutToAppear(): void {
    // S6 — capture S0027 is the keyboard state: the nav bar stays put, the message list
    // SHRINKS to `[0,97][393,459]` and the compose panel rides on top of the keyboard.
    // ArkUI's default avoidance is OFFSET, which slides the whole page up and takes the nav
    // bar with it; RESIZE is the behaviour the source shows.
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      const onKeyboard = (height: number): void => {
        this.keyboardUp = height > 0;
      };
      win.on('keyboardHeightChange', onKeyboard);
      this.bag.add((): void => {
        win.off('keyboardHeightChange', onKeyboard);
      });
    }).catch((error: BusinessError): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'keyboard height unavailable: %{public}d', error.code);
    });
    const raw: Object | undefined = router.getParams();
    const key: string = raw === undefined
      ? '' : ((raw as ConversationRouteParams).conversationKey ?? '');
    this.applyConversation(this.resolveConversation(key));
    this.subscribeDaemonGaps();
    // svc_db populates `conversations` from the per-account relationalStore at startup, so the
    // history can land AFTER this page opened — re-publish when it does rather than showing an
    // empty conversation the store already has messages for.
    this.bag.add(ServiceRegistry.shared().conversationsService.conversations.subscribe(
      (conversations: ConversationModel[]): void => {
        const current: ConversationModel | null = this.conversation;
        if (current === null) {
          if (conversations.length > 0) {
            this.applyConversation(conversations[0]);
          }
          return;
        }
        if (current.id.length === 0) {
          // A temporary conversation becomes the swarm the daemon created for that peer.
          const peer: ConversationParticipant[] = current.getParticipants();
          const ready: ConversationModel | undefined = conversations.find((candidate: ConversationModel) =>
            candidate.id.length > 0 && candidate.accountId === current.accountId &&
            candidate.isCoredialog() && peer.length > 0 &&
            candidate.getParticipants().some((p: ConversationParticipant) => p.jamiId === peer[0].jamiId));
          if (ready !== undefined) {
            this.applyConversation(ready);
            return;
          }
        }
        this.publishMessages(current);
      }));
    // Swift `CallBannerViewModel.setupCallSubscription()`: the banner follows activeCalls, so a
    // call that starts or ends while this chat is open shows or hides it live (T-1576).
    this.bag.add(ServiceRegistry.shared().callService.activeCalls.subscribe((): void => {
      const current: ConversationModel | null = this.conversation;
      if (current !== null) {
        this.refreshActiveCalls(current,
          ServiceRegistry.shared().accountService.getAccount(current.accountId));
      }
    }));
  }

  /**
   * A deep link is delivered once per arrival; `onPageShow` also fires on every return, so
   * the overlay is opened once. Swift: `ConversationsCoordinator` presenting the sheet on top
   * of the conversation it belongs to (screen_contact_picker's hostScreen).
   */
  onPageShow(): void {
    this.pageVisible = true;
    // Swift `viewDidAppear` -> `setMessagesAsRead()`: what arrived while hidden is read now (T-1631).
    this.markAsReadIfOpen('shown');
    // Swift `ConversationState.openCollabDocument` reaches the CONVERSATION coordinator, which
    // is what presents CollabEditorViewController. screen_collab_documents (hosted by the
    // swarm-info screen) publishes the document and returns here, so the request is picked up
    // on arrival — every time, not only on a deep link.
    const pendingDocument: string = AppStorage.get<string>('pendingCollabDocumentId') ?? '';
    if (pendingDocument.length > 0) {
      AppStorage.setOrCreate<string>('pendingCollabDocumentId', '');
      this.openCollabDocument(pendingDocument);
      return;
    }
    if (this.deepLinkOverlayOpened) {
      return;
    }
    const raw: Object | undefined = router.getParams();
    if (raw === undefined || raw === null) {
      return;
    }
    const overlay: string = (raw as ConversationRouteParams).overlayScreen ?? '';
    if (overlay.length === 0) {
      return;
    }
    this.deepLinkOverlayOpened = true;
    if (overlay === 'screen_contact_picker') {
      this.openContactPicker(true);
    } else if (overlay === 'screen_media_record') {
      // A deep link carries no audioOnly flag; the captured MediaRecordView states are the
      // video recorder, which is the `Record video` control's own form.
      this.openMediaRecord(false);
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'deep link named an overlay this page does not host: %{public}s', overlay);
    }
  }

  /** Swift `viewWillDisappear` -> `setMessagesAsRead()`: leaving the chat reads it (T-1631). */
  onPageHide(): void {
    this.markAsReadIfOpen('hidden');
    this.pageVisible = false;
  }

  aboutToDisappear(): void {
    this.bag.dispose();
    this.conversationBag.dispose();
  }

  /** `ConversationViewModel.key` is `<accountId>|<conversationId or first participant>`. */
  private resolveConversation(key: string): ConversationModel | null {
    const conversations: ConversationModel[] =
      ServiceRegistry.shared().conversationsService.conversations.value;
    const separator: number = key.indexOf('|');
    if (separator < 0) {
      // Deep-linked with no key (the replay's cold start): the account's first conversation
      // is what the smart list would have opened, and null leaves the empty branch showing.
      return conversations.length > 0 ? conversations[0] : null;
    }
    const accountId: string = key.substring(0, separator);
    const identity: string = key.substring(separator + 1);
    for (const conversation of conversations) {
      if (conversation.accountId !== accountId) {
        continue;
      }
      if (conversation.id === identity || conversation.hash === identity) {
        return conversation;
      }
      // A peer's jami id names that peer's one-to-one (a temporary, non-swarm or QR-scanned
      // row), never a group whose first member is that peer (T-1603).
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (conversation.isCoredialog() && participants.length > 0 && participants[0].jamiId === identity) {
        return conversation;
      }
    }
    // Swift `JamiSearchViewModel.temporaryConversation`: a search result that is not a
    // conversation yet opens as a one-to-one with that peer, offering the invitation.
    if (/^[0-9a-f]{40}$/.test(identity)) {
      return ConversationModel.withParticipantUri(identity, accountId, ConversationType.ONE_TO_ONE);
    }
    // Swift `createTemporarySipConversation` / `showSipConversation(withNumber:)`: on a SIP
    // account any number opens as a SIP conversation; it had no fallback, so the chat opened
    // empty (T-0892).
    const account: AccountModel | null = ServiceRegistry.shared().accountService.getAccount(accountId);
    if (account !== null && account.type === AccountType.SIP && identity.length > 0) {
      return ConversationModel.withParticipantUriAndHash(identity, accountId, identity, ConversationType.SIP);
    }
    return null;
  }

  /** Swift `MessagePanelVM`: `L10n.Conversation.messagePlaceholder + " " + name`. */
  private updatePlaceholder(): void {
    const prefix: string = this.getUIContext().getHostContext()?.resourceManager
      .getStringByNameSync('conversation_message_placeholder') ?? 'Write to';
    this.panel.placeholder = this.title.length > 0 ? `${prefix} ${this.title}` : prefix;
  }

  /** Swift `MessagesListVM`'s published values, all off the services the plan assigns here. */
  private applyConversation(conversation: ConversationModel | null): void {
    this.conversation = conversation;
    this.conversationBag.dispose();
    this.hasPeerSharing = false;
    this.trackedAuthors.clear();
    this.typers.clear();
    this.typingIndicatorText = '';
    this.isTyping = false;
    if (conversation !== null) {
      // Swift `MessagesListVM.subscribeToTypingStatus()`: this conversation's typers, by id.
      this.conversationBag.add(ServiceRegistry.shared().conversationsService.typingStatusStream
        .subscribe((status: TypingStatus): void => {
          if (status.conversationId !== conversation.id || this.conversation !== conversation) {
            return;
          }
          if (status.status === 1) {
            this.typers.add(status.from);
          } else {
            this.typers.delete(status.from);
          }
          this.updateTypingIndicator(conversation);
        }));
      // Swift `MessagesListVM.subscribeForNewMessages`: received, sent and history-loaded
      // messages all arrive on `newMessages`.
      this.conversationBag.add(conversation.newMessages.subscribe((): void => {
        if (this.conversation === conversation) {
          this.publishMessages(conversation);
          // Swift `ConversationViewModel.messageDisplayed()`: a newest message that is incoming
          // is read once shown; while the page is hidden it waits for `onPageShow` (T-1631).
          const newest: MessageModel | undefined = conversation.messages[0];
          if (newest !== undefined && newest.incoming) {
            if (this.pageVisible) {
              this.markAsReadIfOpen('incoming shown');
            } else {
              hilog.info(LOG_DOMAIN, 'JamiF5', 'chat %{public}s: incoming %{public}s while hidden, stays unread',
                conversation.id, newest.id);
            }
          }
        }
      }));
      // Swift `subscribeReplyTarget()`: a reply's parent loaded from the daemon fills its quote.
      this.conversationBag.add(ServiceRegistry.shared().conversationsService.replyTargets
        .subscribe((): void => {
          if (this.conversation === conversation) {
            this.publishMessages(conversation);
          }
        }));
      // Editions, deletions and reactions, and transfer progress, redraw the rows too.
      this.conversationBag.add(conversation.reactionsUpdated.subscribe((): void => {
        if (this.conversation === conversation) {
          this.publishMessages(conversation);
        }
      }));
      this.conversationBag.add(conversation.messageUpdatedEvents.subscribe((): void => {
        if (this.conversation === conversation) {
          this.publishMessages(conversation);
        }
      }));
      this.conversationBag.add(ServiceRegistry.shared().conversationsService.sharedResponseStream
        .subscribe((event: ServiceEvent): void => {
          if (event.eventType === ServiceEventType.DATA_TRANSFER_MESSAGE_UPDATED
            && this.conversation === conversation) {
            this.publishMessages(conversation);
          }
          // Swift `subscribeSwarmPreferences()` -> `updateColorPreference()`.
          if (event.eventType === ServiceEventType.CONVERSATION_PREFERENCES_UPDATED &&
            event.getEventInput(ServiceEventInput.CONVERSATION_ID) === conversation.id &&
            this.conversation === conversation) {
            this.swarmColor = conversation.preferences.getColor();
            // Swift `swarmColorUpdated(color:)` re-tints every sent bubble.
            this.publishMessages(conversation);
          }
          // Swift `SwarmInfo` follows the conversation's info and members: a group opened
          // right after Create gets its title, members and ended state only after this push.
          if ((event.eventType === ServiceEventType.CONVERSATION_PROFILE_UPDATED ||
            event.eventType === ServiceEventType.CONVERSATION_MEMBER_EVENT) &&
            event.getEventInput(ServiceEventInput.CONVERSATION_ID) === conversation.id &&
            this.conversation === conversation) {
            this.publishMessages(conversation);
          }
        }));
      // conversationReady re-reads the daemon's info and members into this same model.
      this.conversationBag.add(ServiceRegistry.shared().conversationsService.conversationReadyEvents
        .subscribe((id: string): void => {
          if (id === conversation.id && id.length > 0 && this.conversation === conversation) {
            this.publishMessages(conversation);
          }
        }));
    }
    if (conversation === null) {
      this.isLoading = false;
      this.isEmpty = true;
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.getAccount(conversation.accountId);
    this.isSwarm = !conversation.isCoredialog();
    // Swift sets `isTemporary` only for a swarm/JAMS search result; a SIP number chats at once.
    this.isTemporaryConversation = conversation.id.length === 0 && conversation.isSwarm();
    this.isSyncing = conversation.synchronizing.value;
    this.isAccountSip = account !== null && account.type === AccountType.SIP;
    this.title = conversation.title.length > 0 ? conversation.title : conversation.hash;
    this.canWriteDocuments = conversation.isSwarm();
    this.swarmColor = conversation.preferences.getColor();

    const participants: ConversationParticipant[] = conversation.getParticipants();
    const peerJamiId: string = participants.length > 0 ? participants[0].jamiId : '';
    // A search result's temporary conversation carries the jami id as its hash, so the title
    // is that id until the lookup answers (T-1604).
    if ((this.title.length === 0 || this.title === peerJamiId) && conversation.isCoredialog() &&
      peerJamiId.length > 0) {
      // Swift `bestName`: profile name, else registered name, else the jami id.
      this.title = peerJamiId;
      this.conversationBag.add(registry.nameService.usernameLookupStatus.subscribe(
        (response: LookupNameResponse): void => {
          if (response.address === peerJamiId && response.state === LookupNameState.FOUND &&
            response.name.length > 0) {
            // Swift `subscribeUserServiceLookupStatus` feeds `userName`, i.e. the title until an
            // alias wins and `navUserName` under it, so both follow the lookup live (T-1614).
            this.navUserName = response.name;
            if (this.title === peerJamiId) {
              this.title = response.name;
              this.updatePlaceholder();
            }
          }
        }));
      registry.nameService.lookupAddress(conversation.accountId, '', peerJamiId);
    }
    this.refreshSwarmTitle(conversation);
    this.updatePlaceholder();
    if (peerJamiId.length > 0) {
      // Swift `userName.accept(participant jamiId)` while no registered name is known: a peer
      // with an alias but no name shows the Jami ID under the title (T-1615).
      if (conversation.isCoredialog() && this.navUserName.length === 0) {
        this.navUserName = peerJamiId;
      }
      // Swift MessagesListVM.isBlocked <- ConversationRowVM.isConversationForBlockedContact():
      // isDialog() first, so a 3+ member group with a banned member keeps its panel (T-1568).
      // ConversationDataSource re-runs `updateBlockedStatus()` on a ban or unban, so the banner,
      // the panel and the nav bar's call buttons follow the contacts relay live (T-0812/T-0817).
      this.conversationBag.add(registry.contactsService.contacts.subscribe((): void => {
        const peer = registry.contactsService.contact(peerJamiId);
        this.isBlocked = conversation.isDialog() && peer !== null && peer.banned;
        // Swift `navUserName` <- `userName` <- `contact.userName`: re-read on every emission, so
        // a contact added, or its name lookup landing, while the chat is open shows the line
        // under the title live, as the title itself does (T-1614).
        if (conversation.isCoredialog() && peer !== null && peer.userName !== null &&
          peer.userName.length > 0) {
          this.navUserName = peer.userName;
        }
      }));
      // Swift `setupPeerSharingAvailability()`: a one-to-one, unblocked conversation asks the
      // peer for its services; the button follows the cached and the fresh answer (T-1609).
      if (conversation.isCoredialog() && !this.isBlocked) {
        const applyPeerServices = (result: PeerServicesResult | null): void => {
          if (result !== null && this.conversation === conversation) {
            this.hasPeerSharing = result.hasExposedServices;
          }
        };
        this.conversationBag.add(registry.peerSharingService
          .observePeerServices(conversation.accountId, peerJamiId).subscribe(applyPeerServices));
        registry.peerSharingService.queryPeerServices(conversation.accountId, peerJamiId)
          .then(applyPeerServices);
      }
      // A swarm's nav avatar is its own picture or the member composite, never the first
      // member's photo.
      if (account !== null && conversation.isCoredialog()) {
        this.trackPeerProfile(peerJamiId, account.id);
      }
      // Swift MessagesListVM.subscribeLocationEvents() runs at init: a share already running in
      // this conversation (mine or the contact's) shows the map when the chat opens, and the
      // contact's first position shows it while the chat is open (T-0858).
      const locationPeer: string =
        conversation.getParticipants().length > 0 ? conversation.getParticipants()[0].jamiId : '';
      const locationSharing: LocationSharingService = registry.locationSharingService;
      const showMapIfSharing = (): void => {
        if (locationPeer.length === 0 || this.showLocationSharing || this.conversation !== conversation) {
          return;
        }
        if (locationSharing.isAlreadySharingMyLocation(conversation.accountId, locationPeer) ||
          locationSharing.isAlreadySharing(conversation.accountId, locationPeer)) {
          this.locationAccountId = conversation.accountId;
          this.locationPeerUri = locationPeer;
          this.showLocationSharing = true;
        }
      };
      showMapIfSharing();
      this.conversationBag.add(locationSharing.peerUriAndLocationReceived
        .subscribe((): void => {
          showMapIfSharing();
        }));
    }
    this.publishMessages(conversation);
    this.refreshActiveCalls(conversation, account);
    this.loadAccountAvatar(account);
    this.markAsRead(conversation, account, 'opened');
    this.clearNotifications(conversation);
    this.isLoading = false;
  }

  /** Swift `profileService.getProfile(uri:accountId:)` -> the nav bar avatar. */
  private trackPeerProfile(peerJamiId: string, accountId: string): void {
    this.bag.add(ServiceRegistry.shared().profileService.getProfile(peerJamiId, accountId)
      .subscribe((profile: Profile): void => {
        this.avatar = profile.photo === null ? '' : profile.photo;
        const alias: string | null = profile.alias;
        // Swift `bestName`: the profile alias wins over the registered name and the id (T-1572).
        if (alias !== null && alias.trim().length > 0 && this.title !== alias.trim()) {
          this.title = alias.trim();
          this.updatePlaceholder();
        }
      }));
  }

  /**
   * Swift `MessagesListVM.currentAccountAvatar` / `accountProfileName` — the account's own
   * vCard, read back from the sandbox (feat_persistence_profiles) rather than kept in memory.
   */
  private loadAccountAvatar(account: AccountModel | null): void {
    if (account === null) {
      return;
    }
    const profile: Profile | null = new ProfileStore().accountProfile(account.id);
    if (profile !== null && profile.photo !== null) {
      this.panel.accountAvatar = profile.photo;
    }
  }

  /**
   * Swift `SwarmInfo.finalTitle` + `participantsString` + `groupAvatarSnapshot`: a swarm is
   * named by its title, else after its members; the member list is the subtitle; a swarm
   * without a picture shows the member composite. The profile and members can land after the
   * page opened (a just-created group), so this runs again whenever the conversation
   * republishes.
   */
  private refreshSwarmTitle(conversation: ConversationModel): void {
    this.groupAvatar = groupAvatarFor(conversation);
    if (conversation.isCoredialog()) {
      return;
    }
    this.avatar = conversation.avatar;
    // Swift `ParticipantInfo.apply(profile)` / `lookupName`: every member's vCard and name feed
    // the subtitle and the composite, so a late one redraws the header (T-0884).
    conversation.getParticipants().forEach((participant: ConversationParticipant): void => {
      this.trackAuthor(participant.jamiId, conversation);
    });
    const members: string = groupTitleFor(conversation, this.localized($r('app.string.conversation_yourself')));
    this.navUserName = members;
    const title: string = conversation.title.trim().length > 0 ? conversation.title.trim() : members;
    if (title.length > 0 && title !== this.title) {
      this.title = title;
      this.updatePlaceholder();
    }
  }

  /** Swift `SwarmInfo.isConversationEnded(_:)`; only a swarm has a SwarmInfo. */
  private isConversationEnded(conversation: ConversationModel): boolean {
    if (!conversation.isSwarm() || conversation.id.length === 0 ||
      conversation.getAllParticipants().length === 0) {
      return false;
    }
    if (conversation.getParticipants().some((participant: ConversationParticipant) =>
      participant.role !== ParticipantRole.BANNED && participant.role !== ParticipantRole.LEFT)) {
      return false;
    }
    const local: ConversationParticipant | null = conversation.getLocalParticipants();
    if (conversation.isCoredialog()) {
      return local === null || local.role === ParticipantRole.LEFT;
    }
    return local === null || local.role !== ParticipantRole.ADMIN;
  }

  /** Swift `MessagesListVM.messagesModels` — one row per loaded message. */
  private publishMessages(conversation: ConversationModel): void {
    this.refreshSwarmTitle(conversation);
    const rows: MessageRowModel[] = [];
    const messages: MessageModel[] = conversation.messages;
    for (const message of messages) {
      rows.push(this.buildRow(message));
    }
    this.applySequencing(conversation, messages, rows);
    this.applyReadIndicators(conversation, messages, rows);
    this.messageListFlippedListLazyForEachOverMessagesListVM.reload(rows);
    this.updateProgressMonitor(conversation, rows);
    // Swift `updateNumberOfNewMessages()`: how many messages now sit above the last one seen,
    // your own sends included, as iOS 4.20 counts them (T-1655).
    const lastSeen: number = this.lastMessageBeforeScroll.length === 0 ? -1
      : messages.findIndex((message: MessageModel) => message.id === this.lastMessageBeforeScroll);
    if (lastSeen >= 0) {
      this.newMessagesCount = lastSeen;
    }
    this.isEmpty = rows.length === 0;
    this.isEnded = this.isConversationEnded(conversation);
  }

  /**
   * Swift `MessagesListVM.updateLastDisplayed` / `updateLastRead` / `updateLastDelivered` over the
   * newest-first list (T-0821/T-0822). Each other member's read marker starts at its
   * `lastDisplayed` and moves to any newer outgoing message that member has displayed; its
   * avatar sits under that message (`readIds`), so an unread newest message has none. The sent
   * check goes on the newest delivered message only while it is newer than every read marker,
   * and a message still sending carries the outline circle (`isSending()`).
   */
  private applyReadIndicators(conversation: ConversationModel, messages: MessageModel[],
    rows: MessageRowModel[]): void {
    const readIndices: number[] = [];
    for (const participant of conversation.getParticipants()) {
      let lastRead: number = participant.lastDisplayed.length === 0 ? -1
        : messages.findIndex((message: MessageModel) => message.id === participant.lastDisplayed);
      for (let index = 0; index < messages.length && (lastRead < 0 || index < lastRead); index++) {
        if (!messages[index].incoming &&
          messages[index].statusForParticipantValue(participant.jamiId) === MessageStatus.DISPLAYED) {
          lastRead = index;
          break;
        }
      }
      if (lastRead >= 0) {
        readIndices.push(lastRead);
        rows[lastRead].readAvatars.push(groupMember(participant, conversation.accountId));
        this.trackAuthor(participant.jamiId, conversation);
      }
    }
    const delivered: number = messages.findIndex((message: MessageModel) => message.isDelivered());
    if (delivered >= 0 && readIndices.every((read: number) => delivered < read)) {
      rows[delivered].showReceiveIndicator = true;
    }
    for (let index = 0; index < messages.length; index++) {
      rows[index].showSentIndicator = messages[index].isSending();
    }
  }

  /** Swift `createMessageRowView(for:)`'s model half. */
  private buildRow(message: MessageModel): MessageRowModel {
    const row: MessageRowModel = new MessageRowModel();
    row.container.id = message.id;
    row.container.content.message = message;
    row.container.content.type = message.type;
    row.container.content.content = message.content;
    row.container.content.messageDeleted = message.isMessageDeleted();
    row.container.content.messageEdited = message.isMessageEdited();
    row.container.content.editIndicator = this.localized($r('app.string.conversation_edited'));
    row.container.content.swarmColor = this.swarmColor;
    if (row.container.content.messageDeleted) {
      // Swift `L10n.Conversation.deletedMessage(username)`; for our own message
      // `MessagesListVM.getName` gives the account's name with the " (You)" suffix.
      row.container.content.messageDeletedText =
        this.localized($r('app.string.conversation_deleted_message'))
          .replace('%s', message.incoming ? this.title : this.ownName());
    }
    if (message.type === MessageType.FILE_TRANSFER) {
      this.applyTransfer(row.container.content, message);
    }
    // Swift `CollabDocMessageVM.init`: the commit's name, removed once the announcement was
    // edited (retired), and the unread registry's current answer.
    if (message.type === MessageType.COLLAB_DOCUMENT && this.conversation !== null) {
      const document: CollabDocMessageModel = new CollabDocMessageModel();
      document.documentId = message.collabDocumentId;
      document.conversationId = this.conversation.id;
      document.name = message.collabDocumentName.length > 0
        ? message.collabDocumentName : this.localized($r('app.string.collab_untitled'));
      document.removed = message.isMessageDeleted();
      ServiceRegistry.shared().collaborationService.isWaitingToBeRead(this.conversation.accountId,
        this.conversation.id, message.collabDocumentId,
        (waiting: boolean): void => {
          document.waitingToBeRead = waiting;
        })();
      row.collabDocument = document;
      // Swift `MessageType.isCentered` includes .collabDocument; MessageRow draws the
      // announcement only for a centred row, so without this it rendered as an empty row.
      row.centeredMessage = true;
    }
    // Swift `ContactMessageView`: "Conversation created" and the member lines are drawn
    // across the conversation; as bubbles they had no content branch and rendered empty.
    if (message.type === MessageType.INITIAL || message.type === MessageType.CONTACT) {
      row.centeredMessage = true;
      const memberId: string = message.uri.length > 0 ? message.uri : message.authorId;
      // Swift `ContactMessageVM.username` <- `MessagesListVM.getName` (memberEventName): a
      // contact's alias, else the registered name, else the Jami ID; a non-contact's vCard name
      // is not used (T-1625). The avatar is the member's own picture.
      const member: GroupAvatarMember = this.conversation === null
        ? new GroupAvatarMember() : groupMember(new ConversationParticipant(memberId), this.conversation.accountId);
      const name: string = this.conversation === null
        ? memberId : memberEventName(memberId, this.conversation.accountId);
      row.username = name;
      row.contactMessageText = message.type === MessageType.INITIAL
        ? message.content : (message.getContactInteractionString(name) ?? message.content);
      // Swift `ContactMessageVM.needAvatar`: an incoming member line shows that member's avatar.
      if (message.type === MessageType.CONTACT && message.incoming && this.conversation !== null) {
        row.shouldDisplayAvatar = true;
        row.avatar = member.photo;
        this.trackAuthor(memberId, this.conversation);
      }
      return row;
    }
    row.container.content.menuItems = this.menuItemsFor(row.container.content);
    row.container.canReply = row.container.content.menuItems.includes(ContextualMenuItem.REPLY);
    // Swift `ReactionsContainerModel.displayValue`: each emoji with its own count when above 1,
    // joined by two spaces ("👍2  👎"), T-1676. First-seen order; Swift's Dictionary has none.
    const emojiCounts: Map<string, number> = new Map<string, number>();
    const rowsByAuthor: Map<string, ReactionRowModel> = new Map<string, ReactionRowModel>();
    const conversation: ConversationModel | null = this.conversation;
    const localJamiId: string = conversation === null ? '' : this.localJamiId(conversation);
    message.reactions.forEach((reaction: MessageAction): void => {
      emojiCounts.set(reaction.content, (emojiCounts.get(reaction.content) ?? 0) + 1);
      let reactionRow: ReactionRowModel | undefined = rowsByAuthor.get(reaction.author);
      if (reactionRow === undefined) {
        reactionRow = new ReactionRowModel();
        reactionRow.jamiId = reaction.author;
        reactionRow.username = reaction.author;
        // Swift `ReactionsRowViewModel.requestName` -> `MessagesListVM.getName`: the member's
        // name and avatar; our own row is the account's, named "<name> (You)".
        if (conversation !== null) {
          const isLocal: boolean = reaction.author === localJamiId;
          const member: GroupAvatarMember = isLocal
            ? groupMember(new ConversationParticipant(reaction.author, true), conversation.accountId)
            : groupMember(new ConversationParticipant(reaction.author), conversation.accountId);
          reactionRow.username = isLocal ? this.ownName() : member.name;
          reactionRow.avatar = member.photo;
          if (!isLocal) {
            this.trackAuthor(reaction.author, conversation);
          }
        }
        rowsByAuthor.set(reaction.author, reactionRow);
      }
      // Swift `ReactionsRowViewModel.toString()`: the author's emojis joined by a space.
      reactionRow.emojis += (reactionRow.emojis.length > 0 ? ' ' : '') + reaction.content;
    });
    const chips: string[] = [];
    emojiCounts.forEach((count: number, emoji: string): void => {
      chips.push(count > 1 ? emoji + String(count) : emoji);
    });
    row.container.reactionsDisplay = chips.join('  ');
    row.container.reactions = Array.from(rowsByAuthor.values());
    row.container.hasReactions = message.reactions.size > 0;
    // Swift `MessagesListVM.receiveReply`: a reply quotes its parent over the bubble.
    if (message.isReply()) {
      row.container.replyTarget = this.replyTargetFor(message);
    }
    row.incoming = message.incoming;
    row.username = message.authorId;
    return row;
  }

  /** The local account's Jami ID for this conversation, '' when the account is gone. */
  private localJamiId(conversation: ConversationModel): string {
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(conversation.accountId);
    return account === null ? '' : account.jamiId;
  }

  /**
   * Swift `MessagesListVM.getName` for our own id: the account's best name (profile alias,
   * registered name, Jami ID) `.withYourselfSuffix()`, "ios-mainaccount (You)".
   */
  private ownName(): string {
    const yourself: string = this.localized($r('app.string.conversation_yourself'));
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return yourself;
    }
    const name: string = groupMember(new ConversationParticipant(this.localJamiId(conversation), true),
      conversation.accountId).name;
    return name.length > 0 ? `${name} (${yourself})` : yourself;
  }

  /**
   * Swift `MessagesListVM.computeSequencing` as the reference build (Jami 4.20) runs it.
   * `conversation.messages` is NEWEST first (new messages are prepended, older pages appended,
   * as Swift `messagesModels`), so the previous (older) message is index + 1: the time is shown over the first message and over any message 10 minutes
   * or more after the previous one, and either starts a new sequence. In a swarm with more than
   * one other member an incoming message that starts a sequence carries its AUTHOR's avatar
   * and name above the bubble (`shouldDisplayContactInfo` -> `shouldDisplayAavatar` and
   * `MessageStackVM.shouldDisplayName`, T-1608); a 1:1 never shows either.
   */
  private applySequencing(conversation: ConversationModel, messages: MessageModel[],
    rows: MessageRowModel[]): void {
    const showsContactInfo: boolean = conversation.getParticipants().length > 1;
    for (let index = 0; index < messages.length; index++) {
      const current: MessageModel = messages[index];
      const previous: MessageModel | null = index + 1 < messages.length ? messages[index + 1] : null;
      const row: MessageRowModel = rows[index];
      row.shouldShowTimeString = previous === null ||
        current.receivedDate.getTime() - previous.receivedDate.getTime() >= MESSAGE_GROUPING_INTERVAL_MS;
      if (row.shouldShowTimeString) {
        row.timeString = timeLabelString(current.receivedDate);
      }
      // Swift `getMessageSequencing(forIndex:)` -> `topSpace` / `bottomSpace`: the oldest row is
      // a single message, the newest ends its sequence, the rest look at both neighbours (the
      // newer one's time header was set one turn earlier).
      const next: MessageModel | null = index > 0 ? messages[index - 1] : null;
      const startsRun: boolean = previous === null || row.shouldShowTimeString ||
        this.breaksSequence(previous, current);
      row.topSpace = startsRun ? SEQUENCE_SPACE : 0;
      row.bottomSpace = next === null || previous === null || rows[index - 1].shouldShowTimeString ||
        this.breaksSequence(next, current) ? SEQUENCE_SPACE : 0;
      if (row.centeredMessage || !row.incoming || !showsContactInfo) {
        continue;
      }
      row.groupConversation = true;
      // Swift `firstOfSequence || singleMessage`, never on a reply.
      if (startsRun && !current.isReply()) {
        const authorId: string = current.uri.length > 0 ? current.uri : current.authorId;
        const author: GroupAvatarMember = groupMember(new ConversationParticipant(authorId), conversation.accountId);
        row.shouldDisplayAvatar = true;
        row.shouldDisplayName = true;
        row.avatar = author.photo;
        row.username = author.name;
        this.trackAuthor(authorId, conversation);
      }
    }
  }

  /** Swift `MessagesListVM.isBreakingSequence` (the emoji-only clause has no port model). */
  private breaksSequence(previous: MessageModel, current: MessageModel): boolean {
    return previous.uri !== current.uri || previous.authorId !== current.authorId ||
      isCenteredMessageType(previous.type) || isCenteredMessageType(current.type) ||
      previous.isReply() || current.isReply() ||
      previous.reactions.size > 0 || current.reactions.size > 0;
  }

  /** Swift `getInformationForContact(id:)`: a late vCard redraws the author's rows. */
  private trackAuthor(authorId: string, conversation: ConversationModel): void {
    if (this.trackedAuthors.has(authorId)) {
      return;
    }
    this.trackedAuthors.add(authorId);
    const registry: ServiceRegistry = ServiceRegistry.shared();
    let primed: boolean = false;
    this.conversationBag.add(registry.profileService
      .getProfile(authorId, conversation.accountId)
      .subscribe((): void => {
        if (primed && this.conversation === conversation) {
          this.publishMessages(conversation);
        }
      }));
    primed = true;
    // Swift `nameLookup(id:)`: a member who is not a contact has no registered name here, so
    // it is looked up and the rows redraw with it (T-0895..T-0900).
    if (registry.contactsService.contact(authorId) === null) {
      this.conversationBag.add(registry.nameService.usernameLookupStatus.subscribe(
        (response: LookupNameResponse): void => {
          if (response.address === authorId && response.state === LookupNameState.FOUND &&
            response.name.length > 0 && this.conversation === conversation) {
            this.publishMessages(conversation);
          }
        }));
      registry.nameService.lookupAddress(conversation.accountId, '', authorId);
    }
  }

  /** Swift `callBannerViewModel.activeCalls` <- svc_calls. */
  private refreshActiveCalls(conversation: ConversationModel, account: AccountModel | null): void {
    if (account === null || conversation.id.length === 0) {
      this.activeCalls = [];
      this.isActiveCallBanner = false;
      return;
    }
    // Swift: `accountTrackers[accountId]?.incomingNotAcceptedCalls(for: conversation.id) ?? []`.
    const tracker: AccountCallTracker | undefined =
      ServiceRegistry.shared().callService.activeCalls.value.get(account.id);
    this.activeCalls = tracker === undefined ? [] : tracker.incomingNotAcceptedCalls(conversation.id);
    this.isActiveCallBanner = this.activeCalls.length > 0;
  }

  /** Swift `ConversationViewModel.setMessagesAsRead()` — the SQLite write path (svc_db). */
  private markAsRead(conversation: ConversationModel, account: AccountModel | null, reason: string): void {
    if (account === null) {
      return;
    }
    hilog.info(LOG_DOMAIN, 'JamiF5', 'chat %{public}s marked read (%{public}s), newest %{public}s',
      conversation.id, reason, conversation.messages.length > 0 ? conversation.messages[0].id : '-');
    ServiceRegistry.shared().conversationsService
      .setMessagesAsRead(conversation, account.id, account.jamiId)
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift's AppDelegate dropped a conversation's delivered notifications once it was opened
   * (`removeAllDeliveredNotifications` on becoming active); scoped here to the conversation the
   * user actually opened, which is its group.
   */
  private clearNotifications(conversation: ConversationModel): void {
    const group: string = conversation.id.length > 0 ? conversation.id : conversation.hash;
    if (group.length === 0) {
      return;
    }
    notificationManager.cancelGroup(group).catch((error: Object): void => {
      hilog.debug(LOG_DOMAIN, LOG_TAG, 'no notification group to cancel: %{public}s',
        describeError(error as BusinessError));
    });
  }

  /** The daemon gaps raised by THIS screen's own controls become its visible notice. */
  private subscribeDaemonGaps(): void {
    this.bag.add(ServiceRegistry.shared().daemonService.unavailableEvents.subscribe(
      (error: DaemonUnavailableError): void => {
        if (error.feature.startsWith('conversation.') || error.feature.startsWith('call.') ||
          error.feature.startsWith('transfer.') || error.feature.startsWith('collab.') ||
          error.feature.startsWith('location.') || error.feature.startsWith('contact.') ||
          error.feature.startsWith('request.')) {
          this.showDaemonNotice = true;
        }
      }));
  }

  private hostContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** One place decides whether a failure is the disclosed gap or a real error. */
  private reportFailure(error: Object): void {
    if (error instanceof DaemonUnavailableError) {
      this.showDaemonNotice = true;
      return;
    }
    this.errorText = describeError(error as BusinessError);
    hilog.error(LOG_DOMAIN, LOG_TAG, 'conversation action failed: %{public}s', this.errorText);
  }

  /* ── effects ───────────────────────────────────────────────────────────────────── */
  /**
   * Swift `viewModel.startAudioCall` / `startCall` -> ConversationState.startCall, which the
   * coordinator turns into a placed call plus the in-call screen. A banner tap joins THAT
   * call (Swift `joinActiveCall(call:withVideo:)` places `call.constructURI()`).
   */
  private openCallScreen(audioOnly: boolean = true, joinUri: string = ''): void {
    this.showDaemonNotice = false;
    this.errorText = '';
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const calls: CallService = ServiceRegistry.shared().callService;
    const uri: string | null = joinUri.length > 0 ? joinUri : calls.outgoingCallURI(conversation);
    if (uri === null) {
      return;
    }
    calls.placeCall(conversation.accountId, uri, audioOnly || this.isAccountSip)
      .then((): void => {
        // Swift: CallKit activated the audio session; with no system provider the app does it.
        const audio: AudioService = ServiceRegistry.shared().audioService;
        audio.callKitActivated(!audioOnly && !this.isAccountSip, CallDirection.OUTGOING);
        this.showCallScreen = true;
        this.callDialog.open();
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift: the collaborative-document announcement row opens THAT document, never a new one. */
  private openCollabDocument(documentId: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    this.collabAccountId = conversation.accountId;
    this.collabConversationId = conversation.id;
    this.collabDocumentId = documentId;
    // The controller's builder arguments were fixed when it was built: the ids travel here.
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_ACCOUNT_KEY, conversation.accountId);
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_CONVERSATION_KEY, conversation.id);
    AppStorage.setOrCreate<string>(COLLAB_EDITOR_DOCUMENT_KEY, documentId);
    this.showCollabEditor = true;
    this.collabEditorDialog.open();
  }

  /**
   * Swift `MessagePanelState.newCollabDocument` -> `promptNewCollabDocument()`
   * (ConversationViewController.swift:255): the name alert first; Create creates.
   */
  private openCollabEditor(): void {
    this.showDaemonNotice = false;
    this.collabNameDialog.open();
  }

  /**
   * Swift `ConversationViewModel.createCollabDocument(named:failed:)`: create, then open the
   * editor on it (`ConversationState.openCollabDocument`); a refusal is `collab.createError`.
   */
  private createCollabDocument(name: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || conversation.id.length === 0) {
      return;
    }
    ServiceRegistry.shared().collaborationService
      .createDocument(conversation.accountId, conversation.id, name)
      .then((created: CreatedDocument): void => {
        this.openCollabDocument(created.id);
      })
      .catch((): void => {
        this.errorText = this.localized($r('app.string.collab_create_error'));
      });
  }

  /**
   * Swift `MessagePanelState.openGalery` -> `selectItemsFromPhotoLibrary()`: PHPicker with
   * `selectionLimit = 0` (no limit), which is what gives the sheet its Add button, and every
   * picked item is sent (`results.forEach`). A single-select HarmonyOS picker returns on the
   * first tap and has no complete button, so this one is multi-select (500 is its ceiling)
   * with the button reading Add. Its Cancel is the system close (X); no option relabels it.
   */
  private pickPhoto(): void {
    this.showDaemonNotice = false;
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.maxSelectNumber = 500;
    options.completeButtonText = photoAccessHelper.CompleteButtonText.TEXT_ADD;
    new photoAccessHelper.PhotoViewPicker().select(options)
      .then((result: photoAccessHelper.PhotoSelectResult): void => {
        for (const uri of result.photoUris) {
          this.sendPickedFile(uri);
        }
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift `MessagePanelState.sendPhoto` -> `takePicture()`: UIImagePickerController's camera on
   * the rear lens, the shot sent like any picked file. In-app (PhotoCapturePage), because the
   * system cameraPicker's review cannot read Retake / Use Photo (T-0755). Cancel sends nothing.
   */
  private takePhoto(): void {
    this.showDaemonNotice = false;
    this.photoCaptureDialog.open();
  }

  /** Swift `MessagePanelState.sendFile` — the document picker, then the same transfer path. */
  private pickFile(): void {
    this.showDaemonNotice = false;
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    new picker.DocumentViewPicker().select(options)
      .then((uris: string[]): void => {
        if (uris.length > 0) {
          this.sendPickedFile(uris[0]);
        }
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `ConversationViewModel.sendFile(filePath:displayName:conversationModel:)`. */
  private sendPickedFile(uri: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const separator: number = uri.lastIndexOf('/');
    const displayName: string = separator < 0 ? uri : uri.substring(separator + 1);
    const transfers: DataTransferService = ServiceRegistry.shared().dataTransferService;
    // Stages the file into the conversation's own directory for real, then reports the
    // peer-transfer gap — which the subscription above turns into this screen's notice.
    transfers.sendFile(conversation, uri, displayName, null);
  }

  /** Swift `openURL(url)` on a message bubble whose body is a full URL. */
  private openUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    ShareActions.openLink(this.hostContext(), url)
      .then((opened: boolean): void => {
        if (!opened) {
          this.errorText = url;
        }
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift `ConversationViewController.saveFile(url:)`: an image goes to the photo library
   * (`saveGIFOrImage`), any other file to Files (`saveFileToDocuments`). Each system dialog
   * grants one write to the URI it returns, and the file is copied into it; an empty list is
   * the user cancelling.
   */
  private saveContextFile(): void {
    const content: MessageContentModel = this.contextMenuMessage.content;
    if (content.filePath.length === 0) {
      return;
    }
    const context: common.UIAbilityContext = this.hostContext();
    const extension: string = content.filePath.substring(content.filePath.lastIndexOf('.') + 1);
    try {
      const target: Promise<string[]> = content.isImage
        ? photoAccessHelper.getPhotoAccessHelper(context).showAssetsCreationDialog(
          [fileUri.getUriFromPath(content.filePath)],
          [{ fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE }])
        : new picker.DocumentViewPicker(context).save({ newFileNames: [content.content] });
      target.then((uris: string[]): void => {
        if (uris.length === 0) {
          return;
        }
        // Closed on every path, as MediaPreviewPage.save(): a failed open or copy throws into
        // the catch below without leaking a descriptor.
        const source: fs.File = fs.openSync(content.filePath, fs.OpenMode.READ_ONLY);
        try {
          const destination: fs.File = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY);
          try {
            fs.copyFileSync(source.fd, destination.fd);
          } finally {
            fs.closeSync(destination);
          }
        } finally {
          fs.closeSync(source);
        }
      }).catch((error: Object): void => {
        this.reportFailure(error);
      });
    } catch (error) {
      this.reportFailure(error as Object);
    }
  }

  /** Swift `actionHandler.shareMessage` — the context menu's share item (feat_share_sheet). */
  private shareContextMessage(): void {
    const body: string = this.contextMenuMessage.content.content;
    if (body.length === 0) {
      return;
    }
    ShareActions.share(this.hostContext(), body, this.title)
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift `MessagePanelState.shareLocation` -> ConversationViewController.startLocationSharing():
   * permission, "already sharing", then the share; the map shows while one runs.
   */
  private openLocationSharing(): void {
    this.showDaemonNotice = false;
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || conversation.getParticipants().length === 0) {
      return;
    }
    this.locationAccountId = conversation.accountId;
    this.locationPeerUri = conversation.getParticipants()[0].jamiId;
    startLocationSharing(this.getUIContext(), this.locationAccountId, this.locationPeerUri)
      .then((sharing: boolean): void => {
        if (sharing) {
          this.showLocationSharing = true;
        }
      });
  }

  /**
   * Swift `actionHandler.presentMediaPreview(...)` — false when the file is not an image or a
   * video on this device. The controller's builder arguments are fixed when it is built, so
   * stageMediaPreview hands the item over through AppStorage.
   */
  openMediaPreview(container: MessageContainerModel): boolean {
    const content: MessageContentModel = container.content;
    // Swift `isVideo = player?.hasVideo.value == true`: the file's tracks, not its extension,
    // so an .mp4 with no video track is a document (T-1697).
    if (content.hasPlayer && !content.player.hasVideo) {
      return false;
    }
    // Jami 4.21 `makePreviewModel`: the sender over the date (ours "Name (You)"), and the
    // message the viewer replies / reacts to. Swift `allowDelete = !message.isIncoming`.
    const message: MessageModel = content.message;
    const conversation: ConversationModel | null = this.conversation;
    const sender: string = !message.incoming ? this.ownName()
      : conversation === null ? this.title
        : this.memberName(message.uri.length > 0 ? message.uri : message.authorId, conversation);
    if (!stageMediaPreview(content.filePath, !message.incoming, container, sender)) {
      return false;
    }
    // The preview's Forward, Delete, Reply and reactions act on this message (forwardMessage,
    // deleteContextMessage, replyTo, pickEmoji, revokeReaction), whichever way it was opened.
    this.contextMenuMessage = container;
    this.isMediaPreviewPresented = true;
    this.mediaPreviewDialog.open();
    return true;
  }

  /**
   * Swift `model.recordAudio()` / `recordVideo()` -> `ConversationState.recordFile` ->
   * `ConversationNavigation.openRecordFile(conversation:audioOnly:)`. The two entry points
   * differ ONLY in `audioOnly`, which swaps the camera preview for the waveform and hides the
   * camera switch — so the flag has to reach screen_media_record.
   *
   * A @CustomDialog's builder arguments are fixed when the CONTROLLER is built, and this page
   * builds one controller for both entry points, so the two inputs the overlay needs travel
   * through AppStorage instead (screen_media_record reads them as @StorageProp).
   */
  private openMediaRecord(audioOnly: boolean): void {
    AppStorage.setOrCreate<boolean>(MEDIA_RECORD_AUDIO_ONLY_KEY, audioOnly);
    AppStorage.setOrCreate<string>(MEDIA_RECORD_CONVERSATION_KEY, this.conversationKey());
    this.isMediaRecordPresented = true;
    this.mediaRecordDialog.open();
  }

  /**
   * `<accountId>|<conversationId or first participant>` — the key shape every conversation
   * handoff in this app uses (ConversationDataSource.key), since a router or dialog parameter
   * carries data and not the ConversationModel itself.
   */
  private conversationKey(): string {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return '';
    }
    if (conversation.id.length > 0) {
      return `${conversation.accountId}|${conversation.id}`;
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    const first: string = participants.length > 0 ? participants[0].jamiId : '';
    return `${conversation.accountId}|${first}`;
  }

  /** Swift `peerServicesButton` -> makePeerSharingViewModel() then the sheet. */
  private openPeerServices(): void {
    // Swift `PeerSharingViewModel(accountId:peerId:…)` — the sheet needs the peer it queries,
    // which is the one-to-one conversation's single participant.
    const conversation: ConversationModel | null = this.conversation;
    if (conversation !== null) {
      const participants: ConversationParticipant[] = conversation.getParticipants();
      if (participants.length > 0) {
        this.peerServicesAccountId = conversation.accountId;
        this.peerServicesPeerId = participants[0].jamiId;
      }
    }
    this.showPeerServices = true;
  }

  /** Swift: the `Forward` context-menu item raises the contact picker as a .pageSheet. */
  openContactPicker(forConversation: boolean): void {
    this.contactPickerForConversation = forConversation;
    this.showContactPicker = true;
  }

  /**
   * Swift `contactSelectedCB` when the picker was raised from the call: the chosen contact is
   * added to the ongoing call. With no call up (and, on this platform, no daemon to place one)
   * the disclosed notice is what the user sees.
   */
  private addCallParticipant(item: PickerItem): void {
    const calls: CallService = ServiceRegistry.shared().callService;
    // The call screen raised the picker: the picked contact joins the call that is up.
    const live: CallState[] = calls.stateMirror.liveCalls;
    if (live.length > 0) {
      const account: AccountModel | null =
        ServiceRegistry.shared().accountService.getAccount(live[0].accountId);
      if (account !== null) {
        const deviceId: string = account.details === null ? ''
          : account.details.getValue(ConfigKey.ACCOUNT_DEVICE_ID);
        calls.addParticipant(item.id, live[0].id, account.jamiId, deviceId);
        this.showCallScreen = true;
        this.callDialog.open();
      }
      return;
    }
    if (this.activeCalls.length === 0) {
      return;
    }
    const call: ActiveCall = this.activeCalls[0];
    ServiceRegistry.shared().callService
      .addParticipant(item.id, new CallId(call.id), call.uri, call.device);
  }

  /** Swift `conversationSelectedCB` — the picked conversations receive the forwarded message. */
  private forwardMessage(conversationIds: string[]): void {
    const content: MessageContentModel = this.contextMenuMessage.content;
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const service: ConversationsService = registry.conversationsService;
    // Swift `shareMessage(message:with:)`: a file goes as the file itself (`sendFile`), named by
    // the first line of its content; text goes as text (T-0962).
    const fileName: string = content.message.content.split('\n')[0];
    for (const conversationId of conversationIds) {
      if (content.type !== MessageType.FILE_TRANSFER) {
        service.sendSwarmMessage(conversationId, this.currentAccountId, content.content, '');
        continue;
      }
      const target: ConversationModel | null =
        service.getConversationForId(conversationId, this.currentAccountId) ?? this.conversation;
      if (target !== null && content.filePath.length > 0) {
        registry.dataTransferService.sendFile(target, content.filePath, fileName, null);
      }
    }
  }

  /**
   * Swift `ConversationViewModel.showContactInfo` — the title control pushes the contact page
   * for a non-swarm conversation and the swarm info page for any swarm. Swift tests
   * `conversation.isSwarm()`, which is true for a one-to-one swarm too: the physical iPhone
   * opens the swarm info (Settings / Documents, Remove / Block contact) for a 1:1.
   * Swift returns for a temporary (search) conversation, and a swarm has no SwarmInfo until it
   * has an id (`shouldCreateSwarmInfo`): the "Send Invitation" state's title does nothing
   * (T-1588). A SIP conversation has no id either and still opens its contact page.
   */
  private openConversationInfo(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    if (this.isSwarm || conversation.isSwarm()) {
      if (conversation.id.length === 0) {
        return;
      }
      router.pushUrl({
        url: 'pages/SwarmConversationInfoPage',
        params: { conversationKey: this.conversationKey() }
      });
      return;
    }
    router.pushUrl({
      url: 'pages/ContactInfoPage',
      params: { conversationKey: this.conversationKey() }
    });
  }

  /**
   * Swift `MessagesListVM.loadMore()` — nothing to do while a load is in flight or once the
   * oldest loaded message has no parent, then a paged read from svc_conversations.
   */
  private loadMore(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null || this.isLoading) {
      return;
    }
    const messages: MessageModel[] = conversation.messages;
    if (messages.length === 0) {
      return;
    }
    // Swift `messagesModels.last`: the list is newest first, so the oldest loaded message is
    // the last one. Paging from the first re-read the newest page and never saw the root
    // commit ("Conversation created") as the end of the history (T-0894).
    const oldest: MessageModel = messages[messages.length - 1];
    if (oldest.parentId.length === 0 && oldest.parents.length === 0) {
      // Swift `allLoaded()`.
      return;
    }
    this.isLoading = true;
    ServiceRegistry.shared().conversationsService
      .loadConversationMessages(conversation.id, conversation.accountId, oldest.id);
    this.publishMessages(conversation);
    this.isLoading = false;
  }

  /** Swift `atTheBottom`'s didSet: note the newest message on leaving, reset the count back. */
  private onScrolledUpChanged(): void {
    const messages: MessageModel[] = this.conversation === null ? [] : this.conversation.messages;
    this.lastMessageBeforeScroll = this.isScrolledUp && messages.length > 0 ? messages[0].id : '';
    if (!this.isScrolledUp) {
      this.newMessagesCount = 0;
    }
  }

  /** Swift `MessagesListVM.scrollToTheBottom()` — the newest message becomes the scroll target. */
  private scrollToBottom(): void {
    this.isScrolledUp = false;
    // Swift marked the conversation read once the bottom was reached.
    this.markAsReadIfOpen('scrolled to bottom');
  }

  /** `markAsRead` for the conversation this page has open, if it has one yet. */
  private markAsReadIfOpen(reason: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation !== null) {
      this.markAsRead(conversation,
        ServiceRegistry.shared().accountService.getAccount(conversation.accountId), reason);
    }
  }

  /**
   * Swift `MessagesListVM.sendRequest()` — the temporary conversation's contact invitation,
   * carrying the account's own vCard payload, then the peer's presence subscription.
   * Swift's `temporaryPeerProfile` only comes from a JAMS directory search row, which this
   * port has no path to, so the peer profile stays null exactly as it does for a Jami search.
   */
  private sendInvitation(): void {
    this.showDaemonNotice = false;
    this.errorText = '';
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    let jamiId: string = '';
    if (participants.length > 0) {
      jamiId = participants[0].jamiId;
    } else if (conversation.isOnlyLocalParticipant()) {
      const local: ConversationParticipant | null = conversation.getLocalParticipants();
      jamiId = local === null ? '' : local.jamiId;
    }
    if (jamiId.length === 0) {
      return;
    }
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const payload: Uint8Array | null = registry.profileService.accountVCardPayload(conversation.accountId);
    registry.requestsService
      .sendContactRequest(jamiId, conversation.accountId, payload, null)
      .then((): void => {
        if (conversation.isCoredialog()) {
          registry.presenceService.subscribeBuddy(conversation.accountId, jamiId, true);
        }
        this.isTemporaryConversation = false;
      })
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /** Swift `MessagesListVM.unblock()` -> ContactsService.unbanContact. */
  private unblock(): void {
    this.showDaemonNotice = false;
    this.errorText = '';
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const participants: ConversationParticipant[] = conversation.getParticipants();
    const account: AccountModel | null =
      ServiceRegistry.shared().accountService.getAccount(conversation.accountId);
    if (participants.length === 0 || account === null) {
      return;
    }
    const contact = ServiceRegistry.shared().contactsService.contact(participants[0].jamiId);
    if (contact === null) {
      return;
    }
    ServiceRegistry.shared().contactsService.unbanContact(contact, account);
    ServiceRegistry.shared().presenceService.subscribeBuddy(account.id, contact.hash, true);
    this.isBlocked = false;
  }

  /**
   * Swift `onLongPress` on a message — raises the context menu over it. Swift
   * `receivedLongPress()` answers nothing for a message with no menu items, so the guard is
   * the source's.
   */
  private openContextMenuFor(container: MessageContainerModel): void {
    if (container.content.menuItems.length === 0) {
      return;
    }
    this.contextMenuMessage = container;
    this.contextMenuOurMessage = !container.content.message.incoming;
    this.contextMenuItems = container.content.menuItems as ContextualMenuItem[];
    this.isContextMenuOpen = true;
    // Swift `if keyboardHeight > 0 { ... resignFirstResponder }` — the keyboard drops.
    this.keyboardWasActiveBeforeMenu = this.keyboardUp;
    this.getUIContext().getFocusController().clearFocus();
  }

  /** Swift `showReactionsView(reactionsModel)`. */
  private openReactionsFor(container: MessageContainerModel): void {
    this.reactions = new ArrayDataSource<ReactionRowModel>(container.reactions);
    this.isReactionsOpen = true;
  }

  /**
   * Swift `MessagesListVM.configureReply(message:)`, from the swipe and from the menu's Reply:
   * this message becomes the reply's parent, quoted under "In reply to <author>".
   */
  private replyTo(container: MessageContainerModel): void {
    const message: MessageModel = container.content.message;
    const conversation: ConversationModel | null = this.conversation;
    this.replyMessageId = container.id;
    this.panel.isEdit = false;
    this.panel.replyContent = container.content.content;
    // Swift `updateUsernameForReply`: our own message is "You", else the author's best name.
    if (!message.incoming) {
      this.panel.inReplyTo = this.localized($r('app.string.conversation_yourself'));
    } else if (conversation === null) {
      this.panel.inReplyTo = this.title;
    } else {
      this.panel.inReplyTo =
        this.memberName(message.uri.length > 0 ? message.uri : message.authorId, conversation);
    }
    this.isReplyingOrEditing = true;
  }

  /**
   * Swift `receiveReply` + `MessageReplyTargetVM.getInReplyMessage`: the parent from the loaded
   * messages or the reply-target registry, else asked of the daemon (`replyTargets` redraws the
   * row when it lands). Ours reads "In reply to Me/<author>", theirs "<author> replied to Me/<author>".
   */
  private replyTargetFor(message: MessageModel): ReplyTargetModel | null {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return null;
    }
    const service: ConversationsService = ServiceRegistry.shared().conversationsService;
    const parent: MessageModel | undefined =
      conversation.messages.find((item: MessageModel) => item.id === message.reply) ??
      service.replyTargets.value.find((item: MessageModel) => item.id === message.reply);
    if (parent === undefined) {
      service.loadTargetReply(conversation.id, conversation.accountId, message.reply);
      return null;
    }
    const me: string = this.localized($r('app.string.account_me'));
    const parentName: string = parent.incoming ? this.memberName(parent.authorId, conversation) : me;
    const target: ReplyTargetModel = new ReplyTargetModel();
    target.inReplyTo = message.incoming
      ? this.localized($r('app.string.conversation_replied_to'),
        this.memberName(message.authorId, conversation), parentName)
      : this.localized($r('app.string.conversation_in_reply_to')) + ' ' + parentName;
    target.content = parent.content;
    target.type = parent.type;
    target.incoming = message.incoming;
    return target;
  }

  /**
   * Swift `MessagesListVM.scrollToTargetReply(messageId:)`: scroll to the quoted message, or
   * load back to it first; the list scrolls once it is in.
   */
  private scrollToReplyTarget(messageId: string): void {
    const conversation: ConversationModel | null = this.conversation;
    if (this.messageListFlippedListLazyForEachOverMessagesListVM.scrollTo(messageId) ||
      conversation === null || conversation.messages.length === 0) {
      return;
    }
    ServiceRegistry.shared().conversationsService.loadMessagesUntil(messageId, conversation.id,
      conversation.accountId, conversation.messages[conversation.messages.length - 1].id);
  }

  /** Swift `names[jamiId]`: a one-to-one's peer is the title, a group member its best name. */
  private memberName(jamiId: string, conversation: ConversationModel): string {
    if (conversation.isCoredialog()) {
      return this.title;
    }
    // A reply's author starts no sequence, so it is followed here: a group's "In reply to" /
    // "replied to" names a non-contact by its looked-up name, as the bubbles do (T-0881).
    this.trackAuthor(jamiId, conversation);
    return groupMember(new ConversationParticipant(jamiId), conversation.accountId).name;
  }

  /** Swift `MessagesListVM.updateTypingIndicatorText()`. */
  private updateTypingIndicator(conversation: ConversationModel): void {
    const names: string[] = Array.from(this.typers)
      .map((jamiId: string): string => this.memberName(jamiId, conversation));
    let text: string = '';
    if (names.length === 1) {
      text = this.localized($r('app.string.conversation_typing_indicator_one_user'), names[0]);
    } else if (names.length === 2) {
      text = this.localized($r('app.string.conversation_typing_indicator_two_users'), names[0], names[1]);
    } else if (names.length === 3) {
      text = this.localized($r('app.string.conversation_typing_indicator_other_users'), names[0], names[1], '1');
    } else if (names.length > 3) {
      text = this.localized($r('app.string.conversation_typing_indicator_others_users'), names[0], names[1],
        String(names.length - 2));
    }
    this.typingIndicatorText = text;
    this.isTyping = text.length > 0;
  }

  /** Swift `animateDismiss(state: .willDismissWithoutAction)`. */
  private closeContextMenu(): void {
    this.dismissContextMenu(true);
  }

  /**
   * Swift `contextMenuPresentingStateChanged`: closing without an action, or with Copy, Delete
   * message or a reaction (`.willDismissWithAction`), gives back the keyboard the long press
   * took; any other item (`.willDismissWithTextEditingAction`) does not (T-1600).
   */
  private dismissContextMenu(restoreKeyboard: boolean): void {
    this.isContextMenuOpen = false;
    if (restoreKeyboard && this.keyboardWasActiveBeforeMenu) {
      focusControl.requestFocus('messagePanelTextField');
    }
    this.keyboardWasActiveBeforeMenu = false;
  }

  /** Swift `model.contentVM?.contextMenuSelect(item:)` — one effect per item (S4). */
  private selectContextMenuItem(item: ContextualMenuItem): void {
    this.dismissContextMenu(item === ContextualMenuItem.COPY ||
      item === ContextualMenuItem.DELETE_MESSAGE);
    if (item === ContextualMenuItem.FORWARD) {
      this.openContactPicker(true);
      return;
    }
    if (item === ContextualMenuItem.PREVIEW) {
      // Swift `presentMediaPreview()`: an image or a video opens the in-app preview, any
      // other file `ContextMenu.openDocument` — the system viewer, as a tap does (openFile).
      this.openFile(this.contextMenuMessage);
      return;
    }
    if (item === ContextualMenuItem.SHARE) {
      this.shareContextMessage();
      return;
    }
    if (item === ContextualMenuItem.SAVE) {
      this.saveContextFile();
      return;
    }
    if (item === ContextualMenuItem.COPY) {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        this.contextMenuMessage.content.content);
      pasteboard.getSystemPasteboard().setData(data)
        .catch((error: Object): void => {
          this.reportFailure(error);
        });
      return;
    }
    if (item === ContextualMenuItem.DELETE_MESSAGE || item === ContextualMenuItem.DELETE_FILE) {
      this.deleteContextMessage();
      return;
    }
    if (item === ContextualMenuItem.EDIT) {
      this.editMessageId = this.contextMenuMessage.id;
      this.panel.isEdit = true;
      this.panel.replyContent = this.contextMenuMessage.content.content;
      this.messageText = this.contextMenuMessage.content.content;
      this.isReplyingOrEditing = true;
      return;
    }
    if (item === ContextualMenuItem.REPLY) {
      this.replyTo(this.contextMenuMessage);
    }
  }

  /** Swift `cxModel.handleUpdatedReaction()` — the picked emoji is sent as a reaction (S4). */
  private pickEmoji(emoji: string): void {
    this.dismissContextMenu(true);
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    ServiceRegistry.shared().conversationsService.sendEmojiReactionMessage(conversation.id,
      conversation.accountId, emoji, this.contextMenuMessage.id);
  }

  /**
   * Swift `MessagesListVM.subscribeContextMenu()` revoke: `editSwarmMessage(message: "",
   * parentId: reactionId)` withdraws our reaction; the daemon's ReactionRemoved redraws the row.
   */
  private revokeReaction(reactionId: string): void {
    this.dismissContextMenu(true);
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    ServiceRegistry.shared().conversationsService.editSwarmMessage(conversation.id,
      conversation.accountId, '', reactionId);
  }

  /**
   * Swift `MessagePanelVM.sendMessage(text:)` + `ConversationViewModel.sendMessage(withContent:)`:
   * an empty draft sends the default emoji, the text is trimmed, an edit edits instead of
   * sending, and a swarm goes through sendSwarmMessage while a one-to-one goes through the
   * non-swarm path (or the in-call channel when a call with that peer is up).
   * Swift `editMessage(text:)` has no default emoji: an empty edit is dropped. A trimmed-empty
   * body sends nothing, and the view's `cleanState()` still clears the draft and the top view.
   */
  private sendMessage(text: string): void {
    this.showDaemonNotice = false;
    this.errorText = '';
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const body: string =
      (text.length === 0 && !this.panel.isEdit ? this.panel.defaultEmoji : text).trim();
    if (body.length > 0) {
      const service: ConversationsService = ServiceRegistry.shared().conversationsService;
      if (this.panel.isEdit) {
        // Swift `editMessage(text:)` — the edited message is the parent of the edition.
        service.editSwarmMessage(conversation.id, conversation.accountId, body,
          this.editMessageId);
      } else if (!conversation.isSwarm()) {
        // Swift `if !conversation.isSwarm()`: a SIP or legacy conversation carries its database
        // row id, so the id alone sent it down the swarm path (T-0892).
        this.sendNonSwarm(conversation, body);
      } else if (conversation.id.length > 0) {
        service.sendSwarmMessage(conversation.id, conversation.accountId, body,
          this.isReplyingOrEditing ? this.replyMessageId : '');
      }
    }
    this.messageText = '';
    this.panel.replyContent = '';
    this.panel.isEdit = false;
    this.replyMessageId = '';
    this.editMessageId = '';
    this.isReplyingOrEditing = false;
  }

  /** Swift's non-swarm branch of `sendMessage(withContent:)`. */
  private sendNonSwarm(conversation: ConversationModel, body: string): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const account: AccountModel | null = registry.accountService.getAccount(conversation.accountId);
    const participants: ConversationParticipant[] = conversation.getParticipants();
    if (account === null || participants.length === 0) {
      return;
    }
    const peerJamiId: string = participants[0].jamiId;
    const calls: CallService = registry.callService;
    const ongoing: CallId | null = calls.call(peerJamiId, conversation.accountId);
    if (ongoing !== null) {
      // Swift: in a call the message rides the call channel, not the DHT.
      registry.conversationsService.sendInCallMessage(ongoing.raw, body, account);
      return;
    }
    registry.conversationsService.sendNonSwarmMessage(body, account, peerJamiId)
      .catch((error: Object): void => {
        this.reportFailure(error);
      });
  }

  /**
   * Swift `.onChange(of: text) { model.handleTyping(message: text) }` -> `setIsComposingMsg`:
   * every draft change lands here (typed, prefilled by Edit, cleared by a send or a Close). The
   * daemon takes the `swarm:<id>` URI and ignores anything else. Like iOS 4.20, the peer is
   * told on EVERY change, not only when the draft turns empty or non-empty: libjami's
   * receiver drops an indicator 12 s after it appeared, and the next keystroke brings it back.
   */
  private onDraftChanged(): void {
    const conversation: ConversationModel | null = this.conversation;
    if (conversation === null) {
      return;
    }
    const uri: string | null = conversation.getConversationURI();
    if (uri === null) {
      return;
    }
    ServiceRegistry.shared().conversationsService
      .setIsComposingMsg(uri, conversation.accountId, this.messageText.length > 0);
  }

  /**
   * Swift `closeAction` on the top view: `cancelReply()`, or for an edit `cancelEdit()` plus
   * `text = ""` (MessagePanelView.swift:107-110). Left in edit mode, the next send would
   * silently edit the old message.
   */
  private closeTopView(): void {
    if (this.panel.isEdit) {
      this.panel.isEdit = false;
      this.messageText = '';
    }
    this.replyMessageId = '';
    this.editMessageId = '';
    this.isReplyingOrEditing = false;
  }

  /* ── the message composition ───────────────────────────────────────────────────── */
  /** comp_media_seek_slider — Swift `seekSlider(autoHide:)` inside the player's controls. */
  @Builder
  private mediaSeekSlider(player: PlayerModel) {
    MessagePlayerSeekSlider({ player: player })
  }

  /** comp_player_view — Swift `MediaView(message:..., withPlayerControls: true)`. */
  @Builder
  private mediaPlayer(container: MessageContainerModel) {
    PlayerView({
      model: container.content.player,
      // Swift: an item with no video track gets the audio-message control set.
      sizeMode: container.content.player.hasVideo
        ? PlayerMode.VIDEO_MESSAGE
        : PlayerMode.AUDIO_MESSAGE,
      withControls: true,
      seekBuilder: (): void => {
        this.mediaSeekSlider(container.content.player)
      },
      onVideoTap: (): void => {
        this.openMediaPreview(container);
      },
      onVideoLongPress: (): void => {
        this.openContextMenuFor(container);
      },
      onVideoRatio: (ratio: number): void => {
        this.videoRatioShown(container.content.message.id, ratio);
      }
    })
      .height('100%')
  }

  /** comp_message_bubble — Swift `MessageBubbleView` / `MessageBubbleWithEditionWrapper`. */
  @Builder
  private messageBubble(container: MessageContainerModel) {
    MessageBubbleView({
      model: container.content,
      playerBuilder: (): void => {
        this.mediaPlayer(container)
      },
      onLongPress: (): void => {
        this.openContextMenuFor(container);
      },
      onOpenFile: (): void => {
        this.openFile(container);
      },
      onTransferAction: (action: TransferAction): void => {
        this.transferAction(container, action);
      },
      // Swift `openURL(url)` — a full-URL bubble opens the link in the system browser.
      onOpenUrl: (url: string): void => {
        this.openUrl(url);
      }
    })
  }

  /** comp_reply_history — Swift `renderReplyHistory()`, only for a message that replies. */
  @Builder
  private replyHistory(container: MessageContainerModel) {
    if (container.replyTarget !== null) {
      ReplyHistory({
        target: container.replyTarget,
        onScrollToTarget: (): void => {
          this.scrollToReplyTarget(container.content.message.reply);
        }
      })
    }
  }

  /** comp_message_content — Swift `MessageContentView`. */
  @Builder
  private messageContent(container: MessageContainerModel) {
    MessageContentView({
      model: container,
      bubbleBuilder: (): void => {
        this.messageBubble(container)
      },
      replyBuilder: (): void => {
        this.replyHistory(container)
      },
      onShowReactions: (): void => {
        this.openReactionsFor(container);
      },
      onReply: (): void => {
        this.replyTo(container);
      }
    })
  }

  /** comp_collab_doc_message — Swift the collaborative-document announcement row. */
  @Builder
  private collabDocMessage(model: MessageRowModel) {
    if (model.collabDocument !== null) {
      CollabDocMessageView({
        model: model.collabDocument,
        onOpen: (documentId: string): void => {
          this.openCollabDocument(documentId);
        }
      })
    }
  }

  /** comp_message_row — Swift `createMessageRowView(for:)`, one per list item. */
  @Builder
  private messageRow(model: MessageRowModel) {
    MessageRowView({
      model: model,
      contentBuilder: (): void => {
        this.messageContent(model.container)
      },
      collabDocBuilder: (): void => {
        this.collabDocMessage(model)
      }
    })
  }

  /** comp_call_banner — Swift `if callBannerViewModel.isVisible { CallBannerView }`. */
  @Builder
  private callBanner() {
    CallBannerView({
      activeCalls: this.activeCalls,
      onAcceptVideo: (call: ActiveCall): void => {
        this.openCallScreen(false, call.constructURI());
      },
      onAcceptAudio: (call: ActiveCall): void => {
        this.openCallScreen(true, call.constructURI());
      }
    })
  }

  /** comp_reactions_view — Swift the reactions overlay, dismissed by a tap anywhere on it. */
  @Builder
  private reactionsOverlay() {
    Column() {
      ReactionsView({ rows: this.reactions })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // Swift 4.20 MessagesListView: the card floats over the undimmed conversation (no scrim);
    // a tap anywhere dismisses it.
    .id('reactions_dismiss')
    .onClick(() => {
      this.isReactionsOpen = false;
    })
  }

  /** comp_message_panel — Swift `if !model.isBlocked { MessagePanelView(...) }`. */
  @Builder
  private messagePanel() {
    MessagePanelView({
      model: this.panel,
      text: $messageText,
      isActionsExpanded: $isActionsExpanded,
      isReplyingOrEditing: $isReplyingOrEditing,
      canWriteDocuments: this.canWriteDocuments,
      onSend: (text: string): void => {
        this.sendMessage(text);
      },
      onCloseTopView: (): void => {
        this.closeTopView();
      },
      onRecordAudio: (): void => {
        this.openMediaRecord(true);
      },
      onRecordVideo: (): void => {
        this.openMediaRecord(false);
      },
      onShareLocation: (): void => {
        this.openLocationSharing();
      },
      onSendFile: (): void => {
        this.pickFile();
      },
      onOpenGallery: (): void => {
        this.pickPhoto();
      },
      onSendPhoto: (): void => {
        this.takePhoto();
      },
      onNewCollabDocument: (): void => {
        this.openCollabEditor();
      }
    })
  }

  /* ── overlay builders ──────────────────────────────────────────────────────────── */
  @Builder
  contactPickerSheet() {
    ContactPickerSheet({
      isPresented: $showContactPicker,
      pickerForConversation: this.contactPickerForConversation,
      onContactSelected: (item: PickerItem): void => {
        this.addCallParticipant(item);
      },
      onConversationsSelected: (ids: string[]): void => {
        this.forwardMessage(ids);
      }
    })
  }

  @Builder
  peerServicesSheet() {
    PeerServicesSheet({
      isPresented: $showPeerServices,
      accountId: this.peerServicesAccountId,
      peerId: this.peerServicesPeerId
    })
  }

  /** Swift `conversationTitleView` — avatar + name + registered name, one control. */
  @Builder
  private conversationTitle() {
    // S5 — capture S0025: a 30vp avatar 8vp before the bold accent name; the registered-name
    // line below it in `.footnote`, also accent.
    Row({ space: NAV_AVATAR_GAP }) {
      AvatarSwiftUIView({
        avatarData: this.avatar,
        displayText: this.title,
        isGroup: this.isSwarm,
        avatarSize: AvatarSize.CONVERSATION_30,
        groupAvatar: this.groupAvatar
      })
      Column() {
        if (this.title.length > 0) {
          Text(this.title)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // Swift `.bold().foregroundColor(.jami)`.
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.jami'))
        }
        // Swift `navUserName` when it differs from the name: a 1:1's registered name (else its
        // Jami ID), a swarm's member list (`SwarmInfo.participantsString`).
        if (this.navUserName.length > 0 && this.navUserName !== this.title) {
          Text(this.navUserName)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // Swift `.font(.footnote).foregroundColor(.jami)`.
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('app.color.jami'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .id('conversationTitle')
    .alignItems(VerticalAlign.Center)
    // Takes the space left between Back and the call buttons; a long name truncates instead
    // of pushing the buttons off screen.
    .layoutWeight(1)
    .onClick(() => {
      this.openConversationInfo();
    })
  }

  /** Swift `trailingButtons` — nothing at all while the conversation is blocked. */
  @Builder
  private trailingButtons() {
    // Swift `HStack(spacing: 0)`, each glyph `navBarIconStyle()`: 20vp in `.jami` inside a
    // 44vp tap target — capture S0025 has them at `[273,49][325,101]` and `[325,49][377,101]`.
    Row() {
      if (!this.isBlocked) {
        // Swift `if buttons.contains(.peerSharing)` — the peer exposes at least one service.
        if (this.hasPeerSharing) {
          SymbolGlyph($r('sys.symbol.network_acceleration'))
            .id('conversationPeerServices')
            .accessibilityText($r('app.string.peer_services_title'))
            .fontSize($r('app.float.nav_bar_icon_glyph_size'))
            .fontColor([$r('app.color.jami')])
            .width($r('app.float.tap_target_size'))
            .height($r('app.float.tap_target_size'))
            .onClick(() => {
              this.openPeerServices();
            })
            // One component binds one sheet, so the peer-services sheet mounts on its trigger.
            // S5: Swift `.sheet(isPresented:)` presents at the full detent on iPhone, so the
            // peer-services sheet takes SheetSize.LARGE rather than ArkUI's MEDIUM default.
            .bindSheet($$this.showPeerServices, this.peerServicesSheet(),
              { detents: [SheetSize.LARGE], showClose: false })
        }

        SymbolGlyph($r('sys.symbol.phone'))
          .id('conversationAudioCall')
          // Swift `L10n.Accessibility.conversationStartVoiceCall(viewModel.name)` (T-0813).
          .accessibilityText(this.localized($r('app.string.accessibility_conversation_start_voice_call'))
            .replace('%s', this.title))
          .fontSize($r('app.float.nav_bar_icon_glyph_size'))
          .fontColor([$r('app.color.jami')])
          .width($r('app.float.tap_target_size'))
          .height($r('app.float.tap_target_size'))
          .onClick(() => {
            this.openCallScreen(true);
          })

        // Swift `if !viewModel.isAccountSip { videoCallButton }`.
        if (!this.isAccountSip) {
          SymbolGlyph($r('sys.symbol.video'))
            .id('conversationVideoCall')
            // Swift `L10n.Accessibility.conversationStartVideoCall(viewModel.name)` (T-0818).
            .accessibilityText(this.localized($r('app.string.accessibility_conversation_start_video_call'))
              .replace('%s', this.title))
            .fontSize($r('app.float.nav_bar_icon_glyph_size'))
            .fontColor([$r('app.color.jami')])
            .width($r('app.float.tap_target_size'))
            .height($r('app.float.tap_target_size'))
            .onClick(() => {
              this.openCallScreen(false);
            })
        }
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack() {
      this.conversationScreen()

      // Swift: ContextMenuSnapshotWindowCoordinator raises ContextMenuView in its own window
      // over the whole screen, nav bar and compose panel included.
      if (this.isContextMenuOpen) {
        ContextMenuView({
          message: this.contextMenuMessage,
          items: this.contextMenuItems,
          isOurMessage: this.contextMenuOurMessage,
          // Swift `tappableMessageBody()` — the same comp_message_content, redrawn.
          snapshotBuilder: (): void => {
            this.messageContent(this.contextMenuMessage)
          },
          onSelect: (item: ContextualMenuItem): void => {
            this.selectContextMenuItem(item);
          },
          onPickEmoji: (emoji: string): void => {
            this.pickEmoji(emoji);
          },
          onRevokeReaction: (reactionId: string): void => {
            this.revokeReaction(reactionId);
          },
          onDismiss: (): void => {
            this.closeContextMenu();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** The conversation itself: nav bar, message list with its overlays, compose panel. */
  @Builder
  private conversationScreen() {
    Column() {
      // Swift `.navigationBarItems(leading: conversationTitleView, trailing: trailingButtons)`.
      Row() {
        // The system back item, which an @Entry router page has to compose. iPhone 4.20 shows
        // the chevron alone in a 44pt item labelled "Back" (T-1609).
        Row() {
          BackChevron()
        }
        .id('back')
        .width($r('app.float.tap_target_size'))
        .alignItems(VerticalAlign.Center)
        .constraintSize({ minHeight: NAV_BAR_HEIGHT })
        .padding({
          start: LengthMetrics.resource($r('sys.float.ohos_id_elements_margin_horizontal_s'))
        })
        .margin({ end: LengthMetrics.vp(BACK_TITLE_GAP) })
        // Icon-only, so the label the visible text used to give is set explicitly.
        .accessibilityText($r('app.string.actions_back_action'))
        .onClick(() => {
          router.back();
        })

        this.conversationTitle()
        this.trailingButtons()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .constraintSize({ minHeight: NAV_BAR_HEIGHT })
      .backgroundColor($r('sys.color.background_primary'))

      Stack({ alignContent: Alignment.Top }) {
        MessagesListView({
          messages: this.messageListFlippedListLazyForEachOverMessagesListVM,
          typingIndicatorText: this.typingIndicatorText,
          // Swift `displayNameForTemporary` is the conversation's `name`, the same as the title.
          temporaryPeerName: this.title,
          temporaryPeerAvatar: this.avatar,
          syncMessage: this.syncMessage,
          // comp_message_row and everything under it, declared by this page.
          rowBuilder: (model: MessageRowModel): void => {
            this.messageRow(model)
          },
          isEmpty: $isEmpty,
          isTyping: $isTyping,
          isScrolledUp: $isScrolledUp,
          newMessagesCount: this.newMessagesCount,
          swarmColor: this.swarmColor,
          isTemporaryConversation: $isTemporaryConversation,
          isEnded: $isEnded,
          isSyncing: $isSyncing,
          isBlocked: $isBlocked,
          onLoadMore: (): void => {
            this.loadMore();
          },
          onScrollToBottom: (): void => {
            this.scrollToBottom();
          },
          onSendInvitation: (): void => {
            this.sendInvitation();
          },
          onUnblock: (): void => {
            this.unblock();
          }
        })

        // Swift MessagesListView `if model.shouldShowMap { LocationSharingView(model:) }` —
        // over the messages, top-aligned; the conversation stays usable around it.
        if (this.showLocationSharing) {
          LocationSharingView({
            isPresented: $showLocationSharing,
            accountId: this.locationAccountId,
            peerUri: this.locationPeerUri
          })
        }

        // Swift `if callBannerViewModel.isVisible { CallBannerView }` — over the content.
        if (this.isActiveCallBanner) {
          this.callBanner()
        }
        // T-1594: Back closed the call screen while the call goes on; this bar brings it back.
        if (!this.showCallScreen) {
          ReturnToCallBar({
            onReturn: (): void => {
              this.showCallScreen = true;
              this.callDialog.open();
            }
          })
            .margin({ top: 8 })
        }

        // Swift `if showReactionsView, let reactions { ReactionsView(...) }`.
        if (this.isReactionsOpen) {
          this.reactionsOverlay()
        }

        // The disclosed daemon gap raised by this screen's own controls, as a visible overlay
        // layer: a daemon-backed control must never look like a no-op. Carries no interactive
        // node of its own and lets touches through; the next action clears it.
        if (this.showDaemonNotice) {
          Column() {
            Blank()
            Text($r('app.string.daemon_not_available'))
              .width('100%')
              .id('conversation_daemon_notice')
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_on_primary'))
              .textAlign(TextAlign.Center)
              .padding($r('sys.float.ohos_id_card_margin_start'))
              .backgroundColor($r('app.color.jami'))
              .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          }
          .width('100%')
          .height('100%')
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
          .hitTestBehavior(HitTestMode.Transparent)
        }

      }
      .layoutWeight(1)
      .width('100%')

      // Swift `if !model.isBlocked { MessagePanelView(...) }` — a blocked conversation has no
      // compose panel at all, and TemporaryConversationView's opaque background covers it.
      if (!this.isBlocked && !this.isTemporaryConversation) {
        this.messagePanel()
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('app.color.secondary_label'))
          .textAlign(TextAlign.Center)
          .padding($r('sys.float.ohos_id_elements_margin_horizontal_l'))
      }
    }
    .width('100%')
    .height('100%')
    // Capture S0025: `systemBackground` — a plain white conversation.
    .backgroundColor($r('sys.color.background_primary'))
    // The source sheet carries its own Cancel, so the system close is suppressed.
    .bindSheet($$this.showContactPicker, this.contactPickerSheet(), { showClose: false })
    .id('screen_conversation')
  }
}
