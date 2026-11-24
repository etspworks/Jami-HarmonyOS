/*
 * Ported from Ring/Ring/Services/PresenceService.swift:25-115 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Who of the account's contacts is online. Two halves, and only one of them can work here:
 *
 *   LOCAL (real) - the per-contact `BehaviorRelay<PresenceStatus>` every row binds to, the
 *   subscribe/unsubscribe bookkeeping, and the `PRESENSE_SUBSCRIBED` event on the shared
 *   response stream. `newBuddyNotification` stays PUBLIC and fully implemented, so the moment
 *   anything can push a buddy status in, presence lights up with no further change here.
 *
 *   DAEMON (a gap) - `PresenceAdapter` (Ring/Ring/Bridging/PresenceAdapter.mm) is an
 *   Objective-C++ shim over the PREBUILT jami daemon, which carries the actual DHT presence
 *   subscription. Its source is not on disk, so per Rule 11 there is nothing to port and a
 *   stub that fabricated a status would be worse than the gap: it would light contacts up green
 *   who are not reachable. The consequence is the SOURCE'S OWN DEFAULT - a buddy nobody has
 *   reported on stays OFFLINE.
 *
 * The gap is recorded with the build-only `DaemonService.unavailable(...)`, not
 * `reportUnavailable(...)`: subscription runs once per contact on every account load, so
 * publishing it would flood the app-wide notice channel with hundreds of identical notices for
 * something the user never asked for. That is the precedent `ContactsService`/`ProfilesService`
 * set for per-contact paths.
 *
 * NOT CARRIED OVER:
 *   `presenceQueue` (DispatchQueue) - it existed solely to serialize access to
 *   `contactPresence` across background queues. ArkTS runs one thread per ability, so the map
 *   has no concurrent writer; every `presenceQueue.async`/`.sync` body became a direct call,
 *   which also makes `getSubscriptionsForContact` genuinely synchronous as its callers expect.
 *   `PresenceAdapter.delegate = self` - there is no bridge to register with.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { jami } from './JamiNative';

import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { DaemonService } from './DaemonService';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';
import { ContactModel } from '../model/ContactModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'PresenceService';

/**
 * Swift `enum PresenceStatus: Int` (PresenceService.swift:25-29). The raw values are the
 * daemon's own status codes and `newBuddyNotification` maps straight from them, so the numbers
 * are part of the contract, not an implementation detail.
 */
export enum PresenceStatus {
  OFFLINE = 0,
  AVAILABLE = 1,
  CONNECTED = 2
}

/** Swift `PresenceStatus(rawValue: status)` - an unknown code is dropped, never guessed. */
export function presenceStatusFromRaw(status: number): PresenceStatus | null {
  // The literals are the enum's own raw values, spelled out because ArkTS compares a `number`
  // against a numeric enum member only through a cast, which reads worse than this does.
  if (status === 0) {
    return PresenceStatus.OFFLINE;
  }
  if (status === 1) {
    return PresenceStatus.AVAILABLE;
  }
  if (status === 2) {
    return PresenceStatus.CONNECTED;
  }
  return null;
}

export class PresenceService {
  /** Swift `private var contactPresence: [String: BehaviorRelay<PresenceStatus>]`. */
  private readonly contactPresence: Map<string, BehaviorRelay<PresenceStatus>> =
    new Map<string, BehaviorRelay<PresenceStatus>>();

  /** "<accountId>/<jamiId>" for every buddy this app asked libjami to track. */
  private readonly subscribed: Set<string> = new Set<string>();

  /** Swift `private let responseStream = PublishSubject<ServiceEvent>()`. */
  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /**
   * Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`.
   * A PublishSubject is already multicast, so the shared stream IS the response stream.
   */
  readonly sharedResponseStream: PublishSubject<ServiceEvent>;

  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /** Zero-argument, per the ServiceRegistry contract; nothing is read from the registry here. */
  constructor() {
    this.sharedResponseStream = this.responseStream;
  }

  /** Drops every subscription this service took out. */
  dispose(): void {
    this.disposeBag.dispose();
  }

  /**
   * Swift `private let presenceAdapter: PresenceAdapter` - the daemon bridge. It has no
   * HarmonyOS counterpart, so the one call that went through it goes through here.
   */
  private get presenceAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /**
   * Swift `func getSubscriptionsForContact(contactId:) -> BehaviorRelay<PresenceStatus>?`.
   * Null means "never subscribed"; a relay that exists but reads OFFLINE means "subscribed,
   * nobody has reported this buddy online" - which, with no daemon, is every buddy.
   */
  getSubscriptionsForContact(contactId: string): BehaviorRelay<PresenceStatus> | null {
    const relay: BehaviorRelay<PresenceStatus> | undefined = this.contactPresence.get(contactId);
    return relay === undefined ? null : relay;
  }

  /**
   * Swift `func subscribeBuddies(withAccount:withContacts:subscribe:)` - banned contacts skipped.
   * One "JamiF5" line per batch: how many libjami calls it made and how many the account now holds.
   */
  subscribeBuddies(accountId: string, contacts: ContactModel[], subscribe: boolean): void {
    const before: number = this.subscribed.size;
    for (const contact of contacts) {
      if (contact.banned) {
        continue;
      }
      this.subscribeBuddy(accountId, contact.hash, subscribe);
    }
    const prefix: string = accountId + '/';
    const held: number =
      Array.from(this.subscribed).filter((key: string): boolean => key.startsWith(prefix)).length;
    hilog.info(LOG_DOMAIN, 'JamiF5',
      'presence %{public}s account=%{public}s contacts=%{public}d calls=%{public}d held=%{public}d',
      subscribe ? 'subscribe' : 'unsubscribe', accountId, contacts.length,
      Math.abs(this.subscribed.size - before), held);
  }

  /**
   * Swift `func subscribeBuddy(withAccountId:withJamiId:withFlag:)`.
   *
   * Swift skipped the libjami call when a presence entry existed. Here a NewBuddyNotification
   * (a conversation tracking its members) can create that entry first, so the guard reads the
   * app's own subscriptions instead: libjami counts track/untrack per buddy (presence_manager.cpp
   * trackBuddy/untrackBuddy), so each one is made exactly once. The relay is kept on unsubscribe
   * (reset to OFFLINE) so the rows bound to it follow the next subscription.
   */
  subscribeBuddy(accountId: string, jamiId: string, flag: boolean): void {
    const key: string = accountId + '/' + jamiId;
    if (flag === this.subscribed.has(key)) {
      // already in that state
      return;
    }

    // The DHT presence subscription; libjami answers with NewBuddyNotification.
    jami.subscribeBuddy(accountId, jamiId, flag);

    if (!flag) {
      this.subscribed.delete(key);
      this.getSubscriptionsForContact(jamiId)?.accept(PresenceStatus.OFFLINE);
      return;
    }
    this.subscribed.add(key);

    const existing: BehaviorRelay<PresenceStatus> | undefined = this.contactPresence.get(jamiId);
    if (existing !== undefined) {
      existing.accept(PresenceStatus.OFFLINE);
      return;
    }

    this.contactPresence.set(jamiId, new BehaviorRelay<PresenceStatus>(PresenceStatus.OFFLINE));
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.PRESENSE_SUBSCRIBED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.URI, jamiId);
    this.responseStream.onNext(event);
  }

  /**
   * The contact's relay, made OFFLINE when nothing has reported on it yet, so a row drawn before
   * the subscription or the first notification still follows them (Swift ConversationRowVM
   * `subscribePresence(contactId:)`).
   */
  presenceFor(jamiId: string): BehaviorRelay<PresenceStatus> {
    let relay: BehaviorRelay<PresenceStatus> | undefined = this.contactPresence.get(jamiId);
    if (relay === undefined) {
      relay = new BehaviorRelay<PresenceStatus>(PresenceStatus.OFFLINE);
      this.contactPresence.set(jamiId, relay);
    }
    return relay;
  }

  /**
   * Swift `PresenceAdapterDelegate.newBuddyNotification(withAccountId:withJamiId:withStatus:
   * withLineStatus:)` - the daemon pushing a buddy's status in (JamiNative 'NewBuddyNotification').
   */
  newBuddyNotification(accountId: string, jamiId: string, status: number,
                       lineStatus: string): void {
    const presenceStatus: PresenceStatus | null = presenceStatusFromRaw(status);
    hilog.info(LOG_DOMAIN, 'JamiF5',
      'presence notification account=%{public}s uri=%{public}s status=%{public}d', accountId, jamiId, status);
    if (presenceStatus === null) {
      this.log('newBuddyNotification: unknown status ' + status + ' for ' + jamiId +
        ' (line status "' + lineStatus + '"); left as it was');
      return;
    }
    this.presenceFor(jamiId).accept(presenceStatus);
  }
}
