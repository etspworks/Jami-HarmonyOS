/*
 * Ported from Ring/Ring/Coordinators/InjectionBag.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Swift builds every service in AppDelegate and passes the bag down through the coordinators.
 * ArkTS has no such single entry point that every page reaches, so the bag becomes one lazy
 * singleton: `ServiceRegistry.shared()`. Each service is built on first access and kept.
 *
 * THE CONTRACT EVERY SERVICE IN `common/` OBEYS:
 *   1. a zero-argument constructor - the registry passes nothing;
 *   2. dependencies are read from `ServiceRegistry.shared()` INSIDE methods, never in the
 *      constructor or at module top level. The import cycle (registry -> service -> registry)
 *      is only safe while nothing runs during module evaluation;
 *   3. anything the OS must hand in (a UIAbilityContext, a ResourceManager) is injected by a
 *      `setX(...)` the ability calls once at startup - a .ts module cannot call `getContext()`.
 *
 * `callKitService` is deliberately NOT vended: a self-signed HarmonyOS build cannot register a
 * system call provider, so `CallUiService` (an in-app incoming-call page + NotificationKit) is
 * the disclosed substitution (`svc_call_ui`). It is not vended here either: add it only if a
 * later batch needs registry-wide access to it.
 */
import { AccountsService } from './AccountsService';
import { AudioService } from './AudioService';
import { CallService } from './CallService';
import { CallsManager } from './CallsManager';
import { CollaborationService } from './CollaborationService';
import { ContactsService } from './ContactsService';
import { ConversationsService } from './ConversationsService';
import { DaemonService } from './DaemonService';
import { DataTransferService } from './DataTransferService';
import { LocationSharingService } from './LocationSharingService';
import { NameService } from './NameService';
import { NetworkService } from './NetworkService';
import { PeerSharingService } from './PeerSharingService';
import { PresenceService } from './PresenceService';
import { ProfilesService } from './ProfilesService';
import { RequestsService } from './RequestsService';
import { SystemService } from './SystemService';
import { VideoService } from './VideoService';

export class ServiceRegistry {
  private static instance: ServiceRegistry | null = null;

  /** The one bag. Built on first use; never built during module evaluation (see the cycle note). */
  static shared(): ServiceRegistry {
    let registry: ServiceRegistry | null = ServiceRegistry.instance;
    if (registry === null) {
      registry = new ServiceRegistry();
      ServiceRegistry.instance = registry;
    }
    return registry;
  }

  private daemon: DaemonService | null = null;
  private accounts: AccountsService | null = null;
  private name: NameService | null = null;
  private conversations: ConversationsService | null = null;
  private contacts: ContactsService | null = null;
  private presence: PresenceService | null = null;
  private network: NetworkService | null = null;
  private calls: CallService | null = null;
  private video: VideoService | null = null;
  private audio: AudioService | null = null;
  private dataTransfer: DataTransferService | null = null;
  private profiles: ProfilesService | null = null;
  private locationSharing: LocationSharingService | null = null;
  private requests: RequestsService | null = null;
  private system: SystemService | null = null;
  private peerSharing: PeerSharingService | null = null;
  private collaboration: CollaborationService | null = null;

  /**
   * Swift `weak var callsManager: CallsManager?` - assigned by AppDelegate once the call
   * domains are wired, not built by the bag. Stays nullable here for the same reason, so a
   * caller must handle "calls are not wired yet".
   */
  callsManager: CallsManager | null = null;

  get daemonService(): DaemonService {
    let service: DaemonService | null = this.daemon;
    if (service === null) {
      service = new DaemonService();
      this.daemon = service;
    }
    return service;
  }

  get accountService(): AccountsService {
    let service: AccountsService | null = this.accounts;
    if (service === null) {
      service = new AccountsService();
      this.accounts = service;
    }
    return service;
  }

  get nameService(): NameService {
    let service: NameService | null = this.name;
    if (service === null) {
      service = new NameService();
      this.name = service;
    }
    return service;
  }

  get conversationsService(): ConversationsService {
    let service: ConversationsService | null = this.conversations;
    if (service === null) {
      service = new ConversationsService();
      this.conversations = service;
    }
    return service;
  }

  get contactsService(): ContactsService {
    let service: ContactsService | null = this.contacts;
    if (service === null) {
      service = new ContactsService();
      this.contacts = service;
    }
    return service;
  }

  get presenceService(): PresenceService {
    let service: PresenceService | null = this.presence;
    if (service === null) {
      service = new PresenceService();
      this.presence = service;
    }
    return service;
  }

  get networkService(): NetworkService {
    let service: NetworkService | null = this.network;
    if (service === null) {
      service = new NetworkService();
      this.network = service;
    }
    return service;
  }

  get callService(): CallService {
    let service: CallService | null = this.calls;
    if (service === null) {
      service = new CallService();
      this.calls = service;
    }
    return service;
  }

  get videoService(): VideoService {
    let service: VideoService | null = this.video;
    if (service === null) {
      service = new VideoService();
      this.video = service;
    }
    return service;
  }

  get audioService(): AudioService {
    let service: AudioService | null = this.audio;
    if (service === null) {
      service = new AudioService();
      this.audio = service;
    }
    return service;
  }

  get dataTransferService(): DataTransferService {
    let service: DataTransferService | null = this.dataTransfer;
    if (service === null) {
      service = new DataTransferService();
      this.dataTransfer = service;
    }
    return service;
  }

  get profileService(): ProfilesService {
    let service: ProfilesService | null = this.profiles;
    if (service === null) {
      service = new ProfilesService();
      this.profiles = service;
    }
    return service;
  }

  get locationSharingService(): LocationSharingService {
    let service: LocationSharingService | null = this.locationSharing;
    if (service === null) {
      service = new LocationSharingService();
      this.locationSharing = service;
    }
    return service;
  }

  get requestsService(): RequestsService {
    let service: RequestsService | null = this.requests;
    if (service === null) {
      service = new RequestsService();
      this.requests = service;
    }
    return service;
  }

  get systemService(): SystemService {
    let service: SystemService | null = this.system;
    if (service === null) {
      service = new SystemService();
      this.system = service;
    }
    return service;
  }

  get peerSharingService(): PeerSharingService {
    let service: PeerSharingService | null = this.peerSharing;
    if (service === null) {
      service = new PeerSharingService();
      this.peerSharing = service;
    }
    return service;
  }

  get collaborationService(): CollaborationService {
    let service: CollaborationService | null = this.collaboration;
    if (service === null) {
      service = new CollaborationService();
      this.collaboration = service;
    }
    return service;
  }
}
