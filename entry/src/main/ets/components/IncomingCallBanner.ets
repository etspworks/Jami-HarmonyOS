/*
 * The incoming-call banner (T-1628): what iOS 4.20's CallKit shows for a ringing call while Jami
 * is in the foreground. A dark pill across the top of whatever screen is up, with the caller's
 * avatar (CallKit's app badge on it), "Jami Audio" / "Jami Video", the caller's name, a red
 * decline and a blue accept. A tap on the pill opens the full call screen, as CallKit's expanded
 * UI. The Home page hosts it as a non-modal dialog, so it shows over every routed page and
 * leaves the page under it usable. Decline / accept are the call screen's own answer controls
 * (InCallScreenPage `answerControls`).
 */
import { ServiceRegistry } from '../common/ServiceRegistry';
import { DisposeBag } from '../common/Observable';
import { LookupNameResponse, LookupNameState } from '../common/NameService';
import { CallDirection, CallId, CallState } from '../model/CallState';
import { CallStatusKind } from '../model/CallStatus';
import { hasNegotiatedVideo } from '../model/MediaItem';
import { AvatarSwiftUIView } from './AvatarSwiftui';

/** AppStorage key, true while the banner is up: the return-to-call bars stay hidden under it. */
export const INCOMING_CALL_BANNER_UP: string = 'incomingCallBannerUp';

/* Measured on the iOS 4.20 capture (iPhone 11, pt). */
const PILL_MARGIN: number = 14;
const PILL_HEIGHT: number = 86;
const PILL_PADDING: number = 17;
const AVATAR_SIZE: number = 52;
const BADGE_SIZE: number = 16;
const BADGE_LOGO_SIZE: number = 12;
const TEXT_GAP: number = 11;
const BUTTON_SIZE: number = 50;
const BUTTON_GAP: number = 13;
const SUBTITLE_SIZE: number = 14;
const NAME_SIZE: number = 18;
const SUBTITLE_COLOR: string = '#8E8E8E';
/** iOS systemRed / systemBlue (dark), as on the capture. */
const DECLINE_COLOR: string = '#FF453A';
const ACCEPT_COLOR: string = '#0A84FF';

/** The first incoming call still ringing: the one CallKit, and the call screen, put in front. */
export function ringingIncomingCall(live: CallState[]): CallState | undefined {
  return live.find((call: CallState): boolean => call.direction === CallDirection.INCOMING &&
    (call.status.kind === CallStatusKind.INCOMING || call.status.kind === CallStatusKind.RINGING));
}

@CustomDialog
export struct IncomingCallBanner {
  /** Injected by the host's CustomDialogController. */
  controller?: CustomDialogController;
  /** Owned by the host; lowered when the banner closes itself. */
  @Link isPresented: boolean;
  /** Opens the full call screen in the banner's place (the host's presentCallScreen). */
  onExpand: () => void = (): void => {};

  @State private name: string = '';
  @State private photo: string = '';
  @State private isVideo: boolean = false;
  private callId: CallId | null = null;
  private peer: string = '';
  /** The registered name looked up for a peer with no profile name (the call screen's `peerNames`). */
  private lookedUpName: string = '';
  private bag: DisposeBag = new DisposeBag();

  aboutToAppear(): void {
    AppStorage.setOrCreate(INCOMING_CALL_BANNER_UP, true);
    const registry: ServiceRegistry = ServiceRegistry.shared();
    this.bag.add(registry.nameService.usernameLookupStatus.subscribe((response: LookupNameResponse): void => {
      if (response.state === LookupNameState.FOUND && response.name.length > 0 && response.address === this.peer) {
        this.lookedUpName = response.name;
        this.refresh();
      }
    }));
    this.bag.add(registry.callService.callsUpdated.subscribe((): void => {
      this.refresh();
    }));
    this.refresh();
  }

  aboutToDisappear(): void {
    this.bag.dispose();
    AppStorage.setOrCreate(INCOMING_CALL_BANNER_UP, false);
  }

  /** The ringing call's caller and media; the banner goes once no call rings. */
  private refresh(): void {
    const registry: ServiceRegistry = ServiceRegistry.shared();
    const live: CallState[] = registry.callService.stateMirror.liveCalls;
    const call: CallState | undefined = ringingIncomingCall(live);
    if (call === undefined) {
      // Still live, no longer ringing: answered from the notification or the lock screen, and
      // CallKit then shows the app's call screen. Declined or ended: the banner just goes.
      const shown: CallId | null = this.callId;
      if (shown !== null && live.some((other: CallState): boolean => other.id.equals(shown))) {
        this.onExpand();
      } else {
        this.close();
      }
      return;
    }
    // The call screen's `applyCall`: negotiated video makes it a video call, answered with the camera.
    this.isVideo = !call.isAudioOnly || hasNegotiatedVideo(call.media);
    const shown: CallId | null = this.callId;
    if (shown === null || !shown.equals(call.id)) {
      this.callId = call.id;
      this.peer = call.peerHash;
      this.lookedUpName = '';
      const registered: string | null = call.registeredName;
      if (call.displayName.length === 0 && (registered === null || registered.length === 0)) {
        registry.nameService.lookupAddress(call.accountId, '', call.peerHash);
      }
      // The call screen routes the audio once per call from the moment it rings; so does this.
      registry.audioService.callKitActivated(this.isVideo, call.direction);
    }
    const best: string = call.bestName;
    this.name = best === call.peerHash && this.lookedUpName.length > 0 ? this.lookedUpName : best;
    const photo: string | null = registry.profileService.getProfile(call.peerHash, call.accountId).value.photo;
    this.photo = photo === null ? '' : photo;
  }

  private close(): void {
    this.isPresented = false;
    const dialog: CustomDialogController | undefined = this.controller;
    if (dialog !== undefined) {
      dialog.close();
    }
  }

  private decline(): void {
    const id: CallId | null = this.callId;
    if (id !== null) {
      ServiceRegistry.shared().callService.refuse(id);
    }
    this.close();
  }

  private accept(): void {
    const id: CallId | null = this.callId;
    if (id !== null) {
      ServiceRegistry.shared().callService.accept(id, this.isVideo);
    }
    this.onExpand();
  }

  @Builder
  private roundButton(id: string, icon: Resource, color: string, label: Resource, action: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([Color.White])
    }
    .id(id)
    .width(BUTTON_SIZE)
    .height(BUTTON_SIZE)
    .borderRadius(BUTTON_SIZE / 2)
    .backgroundColor(color)
    .accessibilityText(label)
    .onClick(action)
  }

  build() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          AvatarSwiftUIView({
            avatarData: this.photo,
            displayText: this.name,
            isGroup: false,
            avatarSize: AVATAR_SIZE
          })
          // CallKit's `iconTemplateImageData` (the Jami logo) on the caller's face.
          Stack() {
            Image($r('app.media.jami_icon'))
              .width(BADGE_LOGO_SIZE)
              .height(BADGE_LOGO_SIZE)
              .objectFit(ImageFit.Contain)
          }
          .width(BADGE_SIZE)
          .height(BADGE_SIZE)
          .borderRadius(4)
          .backgroundColor(Color.Black)
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)

        Column() {
          // CallKit writes "<app name> Audio" / "<app name> Video" itself (CallsHelper
          // providerConfiguration + CallKitService.configure(hasVideo:)).
          Text(this.isVideo ? $r('app.string.call_banner_jami_video') : $r('app.string.call_banner_jami_audio'))
            .fontSize(SUBTITLE_SIZE)
            .fontColor(SUBTITLE_COLOR)
            .maxLines(1)
          Text(this.name)
            .fontSize(NAME_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: TEXT_GAP, right: TEXT_GAP })

        Row({ space: BUTTON_GAP }) {
          this.roundButton('incoming_banner_decline', $r('sys.symbol.xmark'), DECLINE_COLOR,
            $r('app.string.call_decline'), (): void => {
              this.decline();
            })
          this.roundButton('incoming_banner_accept', $r('sys.symbol.checkmark'), ACCEPT_COLOR,
            $r('app.string.call_answer'), (): void => {
              this.accept();
            })
        }
      }
      .width('100%')
      .height(PILL_HEIGHT)
      .padding({ left: PILL_PADDING, right: PILL_PADDING })
      .borderRadius(PILL_HEIGHT / 2)
      .backgroundColor(Color.Black)
      // CallKit: a tap on the banner (not on its buttons) opens the full call screen.
      .onClick(() => {
        this.onExpand();
      })
    }
    .width('100%')
    .padding({ left: PILL_MARGIN, right: PILL_MARGIN, top: PILL_MARGIN })
    .id('incoming_call_banner')
  }
}
