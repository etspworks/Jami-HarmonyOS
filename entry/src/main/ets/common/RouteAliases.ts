/**
 * Deep-link target resolution for the replay/verification harness.
 *
 * GENERATED (Stage 0, deterministic) from results/plan/migration-plan.json,
 * results/plan/plan-skeleton.json and results/traversal-source/graph.json.
 * `aa start ... --ps targetPage <Name>` passes the SOURCE page identity
 * (an iOS view-controller / SwiftUI view class name), a plan screen id, or a
 * generated route name. Each maps to the routable page that renders it; an
 * overlay (modal/sheet/popup) folds to its host page and reports the overlay
 * screen id so the host can present it.
 */

const ROUTE_ALIASES: Map<string, string> = new Map<string, string>();
const OVERLAY_ALIASES: Map<string, string> = new Map<string, string>();

ROUTE_ALIASES.set('AboutButton', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('AboutJamiNavPage', 'pages/AboutJamiNavPage');
ROUTE_ALIASES.set('AboutSwiftUIView', 'pages/WelcomeOnboardingPage');
// Modal hosted by screen_welcome (WalkthroughCoordinator presents it .formModal), so a
// captured state whose page slug is AboutSwiftUIView needs that modal OPEN on arrival.
// Without this row the deep link resolved to the bare host page and the overlay never opened.
OVERLAY_ALIASES.set('AboutSwiftUIView', 'screen_about_jami');
// S0002..S0007 carry this slug and the plan assigns every one of them to screen_about_jami,
// the modal AboutSwiftUIView hosted by the walkthrough page. screen_about (AboutJamiNavPage)
// owns no captured state at all, so routing this slug there sent half of screen_about_jami's
// deep links to a page the gate does not expect (device batch 4: deep-link-wrong-page,
// 'screen_about' where 'screen_welcome' + the modal was expected). AboutJamiNavPage stays
// reachable by its own screen id row below.
ROUTE_ALIASES.set('AboutViewController', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('AboutViewController', 'screen_about_jami');
ROUTE_ALIASES.set('AccessibleCustomColorPicker', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('AccountAvatarView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('AccountLists', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('AccountLists', 'screen_account_lists');
ROUTE_ALIASES.set('AccountMigrationPage', 'pages/AccountMigrationPage');
ROUTE_ALIASES.set('AccountMigrationView', 'pages/AccountMigrationPage');
ROUTE_ALIASES.set('AccountNavigationButton', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('AccountRowView', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('AccountRowView', 'screen_account_lists');
ROUTE_ALIASES.set('AccountSelectionRowView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('AccountSelectionSheet', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('AccountSelectionView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('AccountStatusIndicator', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('AccountStatusIndicator', 'screen_account_lists');
ROUTE_ALIASES.set('AccountSummarySettingsRootPage', 'pages/AccountSummarySettingsRootPage');
ROUTE_ALIASES.set('AccountSummaryView', 'pages/AccountSummarySettingsRootPage');
ROUTE_ALIASES.set('ActiveCallsView', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('ActiveCallsView', 'screen_active_calls');
ROUTE_ALIASES.set('AudioWaveformView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('AudioWaveformView', 'screen_media_record');
ROUTE_ALIASES.set('AvatarSwiftUIView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('AvatarView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('AvatarWithPresence', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('AvatarWithPresence', 'screen_contact_picker');
ROUTE_ALIASES.set('BackupAccount', 'pages/BackupAccountPage');
ROUTE_ALIASES.set('BackupAccountPage', 'pages/BackupAccountPage');
ROUTE_ALIASES.set('BlockView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('BlockedContactRowView', 'pages/BlockedContactsPage');
ROUTE_ALIASES.set('BlockedContactsPage', 'pages/BlockedContactsPage');
ROUTE_ALIASES.set('BlockedContactsView', 'pages/BlockedContactsPage');
ROUTE_ALIASES.set('ButtonsView', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('CallAvatarView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CallAvatarView', 'screen_call');
ROUTE_ALIASES.set('CallBannerView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('CallControlIcon', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CallControlIcon', 'screen_call');
ROUTE_ALIASES.set('CallControlsView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CallControlsView', 'screen_call');
ROUTE_ALIASES.set('CallHeaderView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CallHeaderView', 'screen_call');
ROUTE_ALIASES.set('CallRowView', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('CallRowView', 'screen_active_calls');
ROUTE_ALIASES.set('CallSettingsPage', 'pages/CallSettingsPage');
ROUTE_ALIASES.set('CallSettingsView', 'pages/CallSettingsPage');
ROUTE_ALIASES.set('CallTopActionsView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CallTopActionsView', 'screen_call');
ROUTE_ALIASES.set('ChatSettingsPage', 'pages/ChatSettingsPage');
ROUTE_ALIASES.set('ChatSettingsView', 'pages/ChatSettingsPage');
ROUTE_ALIASES.set('CircleView', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('CollabDocMessageView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('CollabEditorViewController', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CollabEditorViewController', 'screen_collab_editor');
ROUTE_ALIASES.set('CollabHistoryPanel', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('CollabHistoryPanel', 'screen_collab_editor');
ROUTE_ALIASES.set('CollabUnreadIndicator', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ConferenceParticipantsView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ConferenceParticipantsView', 'screen_call');
ROUTE_ALIASES.set('ConnectivityAndConfigurationsPage', 'pages/ConnectivityAndConfigurationsPage');
ROUTE_ALIASES.set('ConnectivitySettingsView', 'pages/ConnectivityAndConfigurationsPage');
ROUTE_ALIASES.set('ContactInfoPage', 'pages/ContactInfoPage');
ROUTE_ALIASES.set('ContactMessageView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ContactPickerConversationRow', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ContactPickerConversationRow', 'screen_contact_picker');
ROUTE_ALIASES.set('ContactPickerView', 'pages/ConversationChatPage');
// Sheet hosted by screen_conversation (the plan's navIn for screen_contact_picker lists
// screen_conversation first and screen_correctness expects that host's page marker on
// S0093). Without the OVERLAY row the deep link resolved to a bare host page and the
// picker never opened - the same defect the batch-2 overlay rows fixed.
OVERLAY_ALIASES.set('ContactPickerView', 'screen_contact_picker');
ROUTE_ALIASES.set('ContactRowView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ContactRowView', 'screen_contact_picker');
ROUTE_ALIASES.set('ContactViewController', 'pages/ContactInfoPage');
ROUTE_ALIASES.set('ContextMenuView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ControlButton', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ControlButton', 'screen_call');
ROUTE_ALIASES.set('ConversationAvatarView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ConversationChatPage', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ConversationContainerView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ConversationProfileEditorAvatar', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('ConversationProfileEditorAvatar', 'screen_conversation_profile_editor');
ROUTE_ALIASES.set('ConversationProfileEditorView', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('ConversationProfileEditorView', 'screen_conversation_profile_editor');
ROUTE_ALIASES.set('ConversationScrollView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ConversationSection', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ConversationSelectableRow', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ConversationViewController', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('CreateAccountView', 'pages/WelcomeOnboardingPage');
// screen_create_account is a modal hosted by screen_welcome, and every captured state whose page
// slug is CreateAccountView (S0041/S0043/S0044, plus screen_welcome's S0045/S0046 and
// screen_profile's S0042) needs that modal OPEN on arrival. Without this row the deep link
// resolved to the bare host page and the overlay never opened.
OVERLAY_ALIASES.set('CreateAccountView', 'screen_create_account');
ROUTE_ALIASES.set('CreateSwarmHostPage', 'pages/CreateSwarmHostPage');
ROUTE_ALIASES.set('CreateSwarmParticipantsPage', 'pages/CreateSwarmParticipantsPage');
ROUTE_ALIASES.set('CurrentAccountButton', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('DefaultTransferView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('DiagnosticsLogPage', 'pages/DiagnosticsLogPage');
ROUTE_ALIASES.set('DialpadKeyButton', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('DialpadKeyButton', 'screen_dialpad');
ROUTE_ALIASES.set('DialpadView', 'pages/SmartListConversationsHomePage');
// Modal hosted by screen_smart_list. DialpadKeyButton already carried this row; the page
// slug itself did not, so a deep link to S0095 opened the host with no dialpad on it and
// every dialpad control read as absent.
OVERLAY_ALIASES.set('DialpadView', 'screen_dialpad');
ROUTE_ALIASES.set('EditExpirationtime', 'pages/EditRegistrationExpiryPage');
ROUTE_ALIASES.set('EditImageIcon', 'pages/CreateSwarmParticipantsPage');
OVERLAY_ALIASES.set('EditImageIcon', 'screen_swarm_profile');
ROUTE_ALIASES.set('EditMessagePanel', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('EditPasswordFieldPage', 'pages/EditPasswordFieldPage');
ROUTE_ALIASES.set('EditPasswordView', 'pages/EditPasswordFieldPage');
ROUTE_ALIASES.set('EditProfileView', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('EditProfileView', 'screen_edit_profile');
ROUTE_ALIASES.set('EditRegistrationExpiryPage', 'pages/EditRegistrationExpiryPage');
ROUTE_ALIASES.set('EmojiBarItemView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('EmojiBarView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('EmptyStateView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('EncryptAccount', 'pages/EncryptChangeAccountPasswordPage');
ROUTE_ALIASES.set('EncryptChangeAccountPasswordPage', 'pages/EncryptChangeAccountPasswordPage');
ROUTE_ALIASES.set('EndedConversationView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ExpandableAvatar', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('FileTransferSettingsPage', 'pages/FileTransferSettingsPage');
ROUTE_ALIASES.set('FileTransferSettingsView', 'pages/FileTransferSettingsPage');
ROUTE_ALIASES.set('ForwardContactPicker', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ForwardContactPicker', 'screen_media_preview');
ROUTE_ALIASES.set('HeaderView', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('HorizontalView', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('ImageOrGifView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ImportFromArchiveView', 'pages/WelcomeOnboardingPage');
// Modal hosted by screen_welcome (WalkthroughCoordinator presents it .formModal), so a
// captured state whose page slug is ImportFromArchiveView needs that modal OPEN on arrival.
// Without this row the deep link resolved to the bare host page and the overlay never opened.
OVERLAY_ALIASES.set('ImportFromArchiveView', 'screen_import_from_archive');
ROUTE_ALIASES.set('Indicator', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('InitialLoadingPage', 'pages/InitialLoadingPage');
ROUTE_ALIASES.set('InitialLoadingViewController', 'pages/InitialLoadingPage');
ROUTE_ALIASES.set('InviteParticipantsSheet', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('InviteParticipantsSheet', 'screen_invite_participants');
ROUTE_ALIASES.set('JamsConnectView', 'pages/WelcomeOnboardingPage');
// Modal hosted by screen_welcome (WalkthroughCoordinator presents it .formModal), so a
// captured state whose page slug is JamsConnectView needs that modal OPEN on arrival.
// Without this row the deep link resolved to the bare host page and the overlay never opened.
OVERLAY_ALIASES.set('JamsConnectView', 'screen_jams_connect');
ROUTE_ALIASES.set('LazyView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('LinkANewDevicePage', 'pages/LinkANewDevicePage');
ROUTE_ALIASES.set('LinkDeviceView', 'pages/LinkANewDevicePage');
ROUTE_ALIASES.set('LinkThisDeviceToAnAccountPage', 'pages/LinkThisDeviceToAnAccountPage');
// S0047's captured page slug. LinkThisDeviceToAnAccountPage is a routed @Entry page, not an
// overlay on the walkthrough host: this row named the host, so the deep link stopped on
// WelcomeOnboardingPage (device batch 4: deep-link-wrong-page). The page is already an
// ONBOARDING_FLOW_PAGES member, so rootFor() still seeds the walkthrough beneath it.
ROUTE_ALIASES.set('LinkToAccountView', 'pages/LinkThisDeviceToAnAccountPage');
ROUTE_ALIASES.set('LinkedDevicesPage', 'pages/LinkedDevicesPage');
ROUTE_ALIASES.set('LinkedDevicesView', 'pages/LinkedDevicesPage');
ROUTE_ALIASES.set('LocationSharingSettingsPage', 'pages/LocationSharingSettingsPage');
ROUTE_ALIASES.set('LocationSharingSettingsView', 'pages/LocationSharingSettingsPage');
ROUTE_ALIASES.set('LocationSharingView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('LocationSharingView', 'screen_location_sharing');
ROUTE_ALIASES.set('LogUI', 'pages/DiagnosticsLogPage');
ROUTE_ALIASES.set('ManageAccountPage', 'pages/ManageAccountPage');
ROUTE_ALIASES.set('ManageAccountView', 'pages/ManageAccountPage');
ROUTE_ALIASES.set('ManageSIPAccountPage', 'pages/ManageSIPAccountPage');
ROUTE_ALIASES.set('ManageSipAccountView', 'pages/ManageSIPAccountPage');
ROUTE_ALIASES.set('MediaPreviewBottomBar', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewBottomBar', 'screen_media_preview');
ROUTE_ALIASES.set('MediaPreviewContentView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewContentView', 'screen_media_preview');
ROUTE_ALIASES.set('MediaPreviewOverlayControls', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewOverlayControls', 'screen_media_preview');
ROUTE_ALIASES.set('MediaPreviewSheetContent', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewSheetContent', 'screen_media_preview');
ROUTE_ALIASES.set('MediaPreviewTopBar', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewTopBar', 'screen_media_preview');
ROUTE_ALIASES.set('MediaPreviewView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaPreviewView', 'screen_media_preview');
ROUTE_ALIASES.set('MediaRecordView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('MediaRecordView', 'screen_media_record');
ROUTE_ALIASES.set('MediaView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MemberItem', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('MemberList', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('MessageBubbleTextRenderer', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageBubbleView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageBubbleWithEditionWrapper', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageContent', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageContentView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessagePanelImageButton', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessagePanelView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageRowView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageStackView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessageTopBaseView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessagesList', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('MessagesListView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('NameRegistrationView', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('NameRegistrationView', 'screen_name_registration');
ROUTE_ALIASES.set('NameServerSettingsPage', 'pages/NameServerSettingsPage');
ROUTE_ALIASES.set('NameServerView', 'pages/NameServerSettingsPage');
ROUTE_ALIASES.set('NoConversationsView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('NoSearchResultsView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('NotificationSettingsPage', 'pages/NotificationSettingsPage');
ROUTE_ALIASES.set('NotificationsSettingsView', 'pages/NotificationSettingsPage');
ROUTE_ALIASES.set('ParticipantCanvas', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ParticipantCanvas', 'screen_call');
ROUTE_ALIASES.set('ParticipantRowView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ParticipantRowView', 'screen_call');
ROUTE_ALIASES.set('ParticipantTileUIView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('ParticipantTileUIView', 'screen_call');
ROUTE_ALIASES.set('PeerServiceBrowser', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('PeerServiceBrowser', 'screen_peer_sharing');
ROUTE_ALIASES.set('PeerSharingSheet', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('PeerSharingSheet', 'screen_peer_sharing');
ROUTE_ALIASES.set('PendingParticipantRowView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('PendingParticipantRowView', 'screen_call');
ROUTE_ALIASES.set('PiPSourceLayerView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('PiPSourceLayerView', 'screen_call');
ROUTE_ALIASES.set('PlayerSwiftUI', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('PortraitView', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('ProfileView', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('ProfileView', 'screen_profile');
ROUTE_ALIASES.set('QRCodePresenter', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('QRCodePresenter', 'screen_qr_code_presenter');
ROUTE_ALIASES.set('ReactionRowView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ReactionsView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('RecordButtonLabel', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('RecordButtonLabel', 'screen_media_record');
ROUTE_ALIASES.set('RecordingIndicator', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('RecordingIndicator', 'screen_call');
ROUTE_ALIASES.set('RendererLayerView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('RendererLayerView', 'screen_call');
ROUTE_ALIASES.set('ReplyHistory', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('ReplyViewInMessagePanel', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('RequestsIndicatorView', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('RequestsIndicatorView', 'screen_requests');
ROUTE_ALIASES.set('RequestsRowView', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('RequestsRowView', 'screen_requests');
ROUTE_ALIASES.set('RequestsView', 'pages/SmartListConversationsHomePage');
// The captured page slug of S0085/S0087. RequestsIndicatorView and RequestsRowView already
// carried the OVERLAY row; the view's own slug did not, so the deep link opened the bare
// smart list and the requests sheet never opened (device batch 4: 8 contract-control-absent).
OVERLAY_ALIASES.set('RequestsView', 'screen_requests');
ROUTE_ALIASES.set('RevocationView', 'pages/LinkedDevicesPage');
OVERLAY_ALIASES.set('RevocationView', 'screen_revocation');
ROUTE_ALIASES.set('RosterAvatar', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('RosterAvatar', 'screen_call');
ROUTE_ALIASES.set('RosterControlIcon', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('RosterControlIcon', 'screen_call');
ROUTE_ALIASES.set('SIPConfigurationView', 'pages/WelcomeOnboardingPage');
// Modal hosted by screen_welcome (WalkthroughCoordinator presents it .formModal), so a
// captured state whose page slug is SIPConfigurationView needs that modal OPEN on arrival.
// Without this row the deep link resolved to the bare host page and the overlay never opened.
OVERLAY_ALIASES.set('SIPConfigurationView', 'screen_sip_configuration');
ROUTE_ALIASES.set('SavedToast', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('SavedToast', 'screen_media_preview');
ROUTE_ALIASES.set('ScanViewController', 'pages/SmartListConversationsHomePage');
// S0008's captured page slug. Without the OVERLAY row the deep link resolved to the bare
// host page and the scanner dialog never opened (device batch 4: scan_close reported absent).
OVERLAY_ALIASES.set('ScanViewController', 'screen_scan_qr');
ROUTE_ALIASES.set('SearchBarWrapperController', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('SearchableConversationsView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('SecuritySettingsPage', 'pages/SecuritySettingsPage');
ROUTE_ALIASES.set('SecuritySettingsView', 'pages/SecuritySettingsPage');
ROUTE_ALIASES.set('SettingsSummaryPage', 'pages/SettingsSummaryPage');
ROUTE_ALIASES.set('SettingsSummaryView', 'pages/SettingsSummaryPage');
ROUTE_ALIASES.set('SettingsView', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('ShareButtonBackground', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ShareExtensionPage', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ShareView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('ShareViewController', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('SmartListContentView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('SmartListConversationsHomePage', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('SmartListSearchResultsPage', 'pages/SmartListSearchResultsPage');
ROUTE_ALIASES.set('SmartListSearchResultsView', 'pages/SmartListSearchResultsPage');
ROUTE_ALIASES.set('SmartListView', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('SwarmConversationInfoPage', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('SwarmCreationUI', 'pages/CreateSwarmParticipantsPage');
// S0010's captured page slug. CreateSwarmHostPage is a routed @Entry page, not an overlay,
// so this must name the page itself; pointing it at the host left the deep link on the smart
// list (device batch 4: deep-link-wrong-page, 'screen_smart_list' where screen_swarm_creation
// was expected). rootFor() seeds the smart list beneath it, so Back still pops to the root.
ROUTE_ALIASES.set('SwarmCreationViewController', 'pages/CreateSwarmHostPage');
ROUTE_ALIASES.set('SwarmInfoView', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('SwarmProfile', 'pages/CreateSwarmParticipantsPage');
OVERLAY_ALIASES.set('SwarmProfile', 'screen_swarm_profile');
ROUTE_ALIASES.set('SyncingConversationView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('TemporaryConversationView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('TitleView', 'pages/ContactInfoPage');
ROUTE_ALIASES.set('TypingIndicatorView', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('UnifiedAvatarView', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('VideoPreviewLayer', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('VideoPreviewLayer', 'screen_media_record');
ROUTE_ALIASES.set('VideoSettingsPage', 'pages/VideoSettingsPage');
ROUTE_ALIASES.set('VideoSettingsView', 'pages/VideoSettingsPage');
ROUTE_ALIASES.set('VideoSurfaceView', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('VideoSurfaceView', 'screen_call');
ROUTE_ALIASES.set('WaveformBar', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('WaveformBar', 'screen_media_record');
ROUTE_ALIASES.set('WelcomeOnboardingPage', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('WelcomeView', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('pages/AboutJamiNavPage', 'pages/AboutJamiNavPage');
ROUTE_ALIASES.set('pages/AccountMigrationPage', 'pages/AccountMigrationPage');
ROUTE_ALIASES.set('pages/AccountSummarySettingsRootPage', 'pages/AccountSummarySettingsRootPage');
ROUTE_ALIASES.set('pages/BackupAccountPage', 'pages/BackupAccountPage');
ROUTE_ALIASES.set('pages/BlockedContactsPage', 'pages/BlockedContactsPage');
ROUTE_ALIASES.set('pages/CallSettingsPage', 'pages/CallSettingsPage');
ROUTE_ALIASES.set('pages/ChatSettingsPage', 'pages/ChatSettingsPage');
ROUTE_ALIASES.set('pages/ConnectivityAndConfigurationsPage', 'pages/ConnectivityAndConfigurationsPage');
ROUTE_ALIASES.set('pages/ContactInfoPage', 'pages/ContactInfoPage');
ROUTE_ALIASES.set('pages/ConversationChatPage', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('pages/CreateSwarmHostPage', 'pages/CreateSwarmHostPage');
ROUTE_ALIASES.set('pages/CreateSwarmParticipantsPage', 'pages/CreateSwarmParticipantsPage');
ROUTE_ALIASES.set('pages/DiagnosticsLogPage', 'pages/DiagnosticsLogPage');
ROUTE_ALIASES.set('pages/EditPasswordFieldPage', 'pages/EditPasswordFieldPage');
ROUTE_ALIASES.set('pages/EditRegistrationExpiryPage', 'pages/EditRegistrationExpiryPage');
ROUTE_ALIASES.set('pages/EncryptChangeAccountPasswordPage', 'pages/EncryptChangeAccountPasswordPage');
ROUTE_ALIASES.set('pages/FileTransferSettingsPage', 'pages/FileTransferSettingsPage');
ROUTE_ALIASES.set('pages/InitialLoadingPage', 'pages/InitialLoadingPage');
ROUTE_ALIASES.set('pages/LinkANewDevicePage', 'pages/LinkANewDevicePage');
ROUTE_ALIASES.set('pages/LinkThisDeviceToAnAccountPage', 'pages/LinkThisDeviceToAnAccountPage');
ROUTE_ALIASES.set('pages/LinkedDevicesPage', 'pages/LinkedDevicesPage');
ROUTE_ALIASES.set('pages/LocationSharingSettingsPage', 'pages/LocationSharingSettingsPage');
ROUTE_ALIASES.set('pages/ManageAccountPage', 'pages/ManageAccountPage');
ROUTE_ALIASES.set('pages/ManageSIPAccountPage', 'pages/ManageSIPAccountPage');
ROUTE_ALIASES.set('pages/NameServerSettingsPage', 'pages/NameServerSettingsPage');
ROUTE_ALIASES.set('pages/NotificationSettingsPage', 'pages/NotificationSettingsPage');
ROUTE_ALIASES.set('pages/SecuritySettingsPage', 'pages/SecuritySettingsPage');
ROUTE_ALIASES.set('pages/SettingsSummaryPage', 'pages/SettingsSummaryPage');
ROUTE_ALIASES.set('pages/ShareExtensionPage', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('pages/SmartListConversationsHomePage', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('pages/SmartListSearchResultsPage', 'pages/SmartListSearchResultsPage');
ROUTE_ALIASES.set('pages/SwarmConversationInfoPage', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('pages/VideoSettingsPage', 'pages/VideoSettingsPage');
ROUTE_ALIASES.set('pages/WelcomeOnboardingPage', 'pages/WelcomeOnboardingPage');
ROUTE_ALIASES.set('screen_about', 'pages/AboutJamiNavPage');
ROUTE_ALIASES.set('screen_about_jami', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_about_jami', 'screen_about_jami');
ROUTE_ALIASES.set('screen_account_lists', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('screen_account_lists', 'screen_account_lists');
ROUTE_ALIASES.set('screen_account_migration', 'pages/AccountMigrationPage');
ROUTE_ALIASES.set('screen_account_summary', 'pages/AccountSummarySettingsRootPage');
ROUTE_ALIASES.set('screen_active_calls', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('screen_active_calls', 'screen_active_calls');
ROUTE_ALIASES.set('screen_backup_account', 'pages/BackupAccountPage');
ROUTE_ALIASES.set('screen_blocked_contacts', 'pages/BlockedContactsPage');
ROUTE_ALIASES.set('screen_call', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_call', 'screen_call');
ROUTE_ALIASES.set('screen_call_settings', 'pages/CallSettingsPage');
ROUTE_ALIASES.set('screen_chat_settings', 'pages/ChatSettingsPage');
ROUTE_ALIASES.set('screen_collab_documents', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('screen_collab_documents', 'screen_collab_documents');
ROUTE_ALIASES.set('screen_collab_editor', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_collab_editor', 'screen_collab_editor');
ROUTE_ALIASES.set('screen_connectivity_settings', 'pages/ConnectivityAndConfigurationsPage');
ROUTE_ALIASES.set('screen_contact', 'pages/ContactInfoPage');
ROUTE_ALIASES.set('screen_contact_picker', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_contact_picker', 'screen_contact_picker');
ROUTE_ALIASES.set('screen_conversation', 'pages/ConversationChatPage');
ROUTE_ALIASES.set('screen_conversation_profile_editor', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('screen_conversation_profile_editor', 'screen_conversation_profile_editor');
ROUTE_ALIASES.set('screen_create_account', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_create_account', 'screen_create_account');
ROUTE_ALIASES.set('screen_dialpad', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('screen_dialpad', 'screen_dialpad');
ROUTE_ALIASES.set('screen_edit_expiration_time', 'pages/EditRegistrationExpiryPage');
ROUTE_ALIASES.set('screen_edit_password', 'pages/EditPasswordFieldPage');
ROUTE_ALIASES.set('screen_edit_profile', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('screen_edit_profile', 'screen_edit_profile');
ROUTE_ALIASES.set('screen_encrypt_account', 'pages/EncryptChangeAccountPasswordPage');
ROUTE_ALIASES.set('screen_file_transfer_settings', 'pages/FileTransferSettingsPage');
ROUTE_ALIASES.set('screen_import_from_archive', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_import_from_archive', 'screen_import_from_archive');
ROUTE_ALIASES.set('screen_in_call_dialpad', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_in_call_dialpad', 'screen_in_call_dialpad');
ROUTE_ALIASES.set('screen_initial_loading', 'pages/InitialLoadingPage');
ROUTE_ALIASES.set('screen_invite_participants', 'pages/SwarmConversationInfoPage');
OVERLAY_ALIASES.set('screen_invite_participants', 'screen_invite_participants');
ROUTE_ALIASES.set('screen_jams_connect', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_jams_connect', 'screen_jams_connect');
ROUTE_ALIASES.set('screen_link_device', 'pages/LinkANewDevicePage');
ROUTE_ALIASES.set('screen_link_to_account', 'pages/LinkThisDeviceToAnAccountPage');
ROUTE_ALIASES.set('screen_linked_devices', 'pages/LinkedDevicesPage');
ROUTE_ALIASES.set('screen_location_sharing', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_location_sharing', 'screen_location_sharing');
ROUTE_ALIASES.set('screen_location_sharing_settings', 'pages/LocationSharingSettingsPage');
ROUTE_ALIASES.set('screen_log', 'pages/DiagnosticsLogPage');
ROUTE_ALIASES.set('screen_manage_account', 'pages/ManageAccountPage');
ROUTE_ALIASES.set('screen_manage_sip_account', 'pages/ManageSIPAccountPage');
ROUTE_ALIASES.set('screen_media_preview', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_media_preview', 'screen_media_preview');
ROUTE_ALIASES.set('screen_media_record', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_media_record', 'screen_media_record');
ROUTE_ALIASES.set('screen_name_registration', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('screen_name_registration', 'screen_name_registration');
ROUTE_ALIASES.set('screen_name_server', 'pages/NameServerSettingsPage');
ROUTE_ALIASES.set('screen_notifications_settings', 'pages/NotificationSettingsPage');
ROUTE_ALIASES.set('screen_peer_sharing', 'pages/ConversationChatPage');
OVERLAY_ALIASES.set('screen_peer_sharing', 'screen_peer_sharing');
ROUTE_ALIASES.set('screen_profile', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_profile', 'screen_profile');
ROUTE_ALIASES.set('screen_qr_code_presenter', 'pages/AccountSummarySettingsRootPage');
OVERLAY_ALIASES.set('screen_qr_code_presenter', 'screen_qr_code_presenter');
ROUTE_ALIASES.set('screen_requests', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('screen_requests', 'screen_requests');
ROUTE_ALIASES.set('screen_revocation', 'pages/LinkedDevicesPage');
OVERLAY_ALIASES.set('screen_revocation', 'screen_revocation');
ROUTE_ALIASES.set('screen_scan_qr', 'pages/SmartListConversationsHomePage');
OVERLAY_ALIASES.set('screen_scan_qr', 'screen_scan_qr');
ROUTE_ALIASES.set('screen_security_settings', 'pages/SecuritySettingsPage');
ROUTE_ALIASES.set('screen_settings_summary', 'pages/SettingsSummaryPage');
ROUTE_ALIASES.set('screen_share_extension', 'pages/ShareExtensionPage');
ROUTE_ALIASES.set('screen_sip_configuration', 'pages/WelcomeOnboardingPage');
OVERLAY_ALIASES.set('screen_sip_configuration', 'screen_sip_configuration');
ROUTE_ALIASES.set('screen_smart_list', 'pages/SmartListConversationsHomePage');
ROUTE_ALIASES.set('screen_smart_list_search', 'pages/SmartListSearchResultsPage');
ROUTE_ALIASES.set('screen_swarm_creation', 'pages/CreateSwarmHostPage');
ROUTE_ALIASES.set('screen_swarm_creation_ui', 'pages/CreateSwarmParticipantsPage');
ROUTE_ALIASES.set('screen_swarm_info', 'pages/SwarmConversationInfoPage');
ROUTE_ALIASES.set('screen_swarm_profile', 'pages/CreateSwarmParticipantsPage');
OVERLAY_ALIASES.set('screen_swarm_profile', 'screen_swarm_profile');
ROUTE_ALIASES.set('screen_video_settings', 'pages/VideoSettingsPage');
ROUTE_ALIASES.set('screen_welcome', 'pages/WelcomeOnboardingPage');

/*
 * ---------------------------------------------------------------------------
 * Coordinator roots.
 *
 * The source routes through UINavigationControllers, so every screen below a coordinator root
 * has that root under it in the stack: one pop out of any settings sub-page lands on
 * AccountSummaryView (SettingsCoordinator's root - S0150/S0155/S0240/S0248/S0254/S0293), one pop
 * out of any main-flow screen lands on SmartListView (S0023/S0033/S0106/S0125), and one pop out
 * of a walkthrough sub-page lands on WelcomeView (S0048/S0068).
 *
 * The settings members below are the pages AccountSummaryView / SettingsSummaryView reach; each
 * is a route this file actually registers.
 * ---------------------------------------------------------------------------
 */

const SETTINGS_FLOW_PAGES: Set<string> = new Set<string>();
SETTINGS_FLOW_PAGES.add('pages/SettingsSummaryPage');
SETTINGS_FLOW_PAGES.add('pages/ChatSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/CallSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/NotificationSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/NameServerSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/ConnectivityAndConfigurationsPage');
SETTINGS_FLOW_PAGES.add('pages/FileTransferSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/LocationSharingSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/VideoSettingsPage');
SETTINGS_FLOW_PAGES.add('pages/SecuritySettingsPage');
SETTINGS_FLOW_PAGES.add('pages/DiagnosticsLogPage');
SETTINGS_FLOW_PAGES.add('pages/ManageAccountPage');
SETTINGS_FLOW_PAGES.add('pages/ManageSIPAccountPage');
SETTINGS_FLOW_PAGES.add('pages/LinkedDevicesPage');
SETTINGS_FLOW_PAGES.add('pages/BackupAccountPage');
SETTINGS_FLOW_PAGES.add('pages/EncryptChangeAccountPasswordPage');
SETTINGS_FLOW_PAGES.add('pages/BlockedContactsPage');
SETTINGS_FLOW_PAGES.add('pages/EditPasswordFieldPage');
SETTINGS_FLOW_PAGES.add('pages/EditRegistrationExpiryPage');
SETTINGS_FLOW_PAGES.add('pages/LinkANewDevicePage');

const ONBOARDING_FLOW_PAGES: Set<string> = new Set<string>();
ONBOARDING_FLOW_PAGES.add('pages/LinkThisDeviceToAnAccountPage');
ONBOARDING_FLOW_PAGES.add('pages/AboutJamiNavPage');

/**
 * True for a page url that sits UNDER AccountSummaryView in the source settings stack, so a
 * deep link to it must be seeded with 'pages/AccountSummarySettingsRootPage' beneath it.
 * EditProfile / QRCode / RegisterAUsername are overlays ON that root, so they resolve to the
 * root url itself and are deliberately not members; RevokeDevice folds into LinkedDevices;
 * AddASIPAccount / ConnectToAJAMSServer resolve to the onboarding page, not a settings page.
 */
export function isSettingsFlowPage(url: string): boolean {
  return SETTINGS_FLOW_PAGES.has(url);
}

/** True for a walkthrough sub-page whose single pop lands on WelcomeView (S0048, S0068). */
export function isOnboardingFlowPage(url: string): boolean {
  return ONBOARDING_FLOW_PAGES.has(url);
}

function normalize(name: string): string[] {
  const out: string[] = [];
  const raw: string = name.trim();
  if (raw.length === 0) {
    return out;
  }
  const base: string = raw.split('/')[0];
  out.push(raw);
  out.push(base);
  const underscore: number = base.indexOf('_');
  if (underscore > 0 && !base.startsWith('screen_')) {
    out.push(base.substring(underscore + 1));
  }
  out.push(base + 'Page');
  return out;
}

/** The page url to route to for a `targetPage` value, or '' when unknown. */
export function resolveTargetPage(name: string): string {
  const candidates: string[] = normalize(name);
  for (const c of candidates) {
    const hit: string | undefined = ROUTE_ALIASES.get(c);
    if (hit !== undefined) {
      return hit;
    }
  }
  return '';
}

/** The overlay screen id a `targetPage` value names, or '' when it is a page. */
export function resolveTargetOverlay(name: string): string {
  const candidates: string[] = normalize(name);
  for (const c of candidates) {
    const hit: string | undefined = OVERLAY_ALIASES.get(c);
    if (hit !== undefined) {
      return hit;
    }
  }
  return '';
}

/*
 * ---------------------------------------------------------------------------
 * Cold-start deep-link handoff.
 *
 * ONE component decides the initial route: `InitialLoadingPage`. `EntryAbility` cannot -
 * on a cold start the app must first finish bootstrap, and a router call raced against the
 * loading page's own redirect left the app on whichever of the two lost. So the ability only
 * RECORDS the target here and the loading page consumes it when its bootstrap completes.
 *
 * Once the loading page has handed over (`takePendingTarget`), the router is live and no
 * bootstrap is pending, so `onNewWant` routes immediately instead of recording.
 * ---------------------------------------------------------------------------
 */

let pendingTarget: string = '';
let initialRouteDone: boolean = false;

/** `onCreate`: a fresh launch. Records the launch's `targetPage` ('' when it carried none). */
export function beginInitialRoute(target: string): void {
  pendingTarget = target;
  initialRouteDone = false;
}

/** `onNewWant` while the loading page still owns the route. */
export function setPendingTarget(target: string): void {
  pendingTarget = target;
}

/** The loading page taking ownership of the initial route. Clears the target, hands over. */
export function takePendingTarget(): string {
  const target: string = pendingTarget;
  pendingTarget = '';
  initialRouteDone = true;
  return target;
}

/** True once the loading page has routed: from here on a deep link is routed immediately. */
export function isInitialRouteDone(): boolean {
  return initialRouteDone;
}
