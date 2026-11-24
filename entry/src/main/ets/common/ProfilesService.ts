/*
 * Ported from Ring/Ring/Services/ProfilesService.swift:32-277 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The profile cache in front of ProfileStore: every screen that shows a contact's name or
 * avatar subscribes here, and every event that could change a stored vCard re-resolves the
 * matching subject.
 *
 * THE DAEMON GAP. Swift holds a `ProfilesAdapter` (Ring/Ring/Bridging) so the C++ jami daemon
 * can push a peer's vCard in over the DHT. That daemon is a prebuilt binary with no source on
 * disk and no HarmonyOS counterpart, so nothing will ever call `profileReceived` on this
 * build. The consequence is disclosed, not faked: a peer with no vCard ALREADY on disk
 * resolves to `Profile.empty()` - the source's own fallback - never to an invented alias or
 * avatar. `resolveProfile` records that per-item gap with the build-only
 * `DaemonService.unavailable(...)` rather than `reportUnavailable`, which would flood the
 * app-wide notice channel once per rendered row.
 *
 * Everything local works for real: reading and writing vCards under the ability's filesDir
 * (through ProfileStore), the in-memory profile subjects, and decoding the avatar bytes that
 * are already stored.
 *
 * FIELDS NOT CARRIED OVER, and why:
 *   `profilesAdapter`        - the daemon bridge above; there is none.
 *   `profilesLock`           - ArkTS runs one thread per ability, so the ThreadSafeDictionary
 *                              pair (`profiles`, `accountProfiles`) is a plain Map and the
 *                              NSLock guarding them has nothing to guard.
 *   `resolutionScheduler`    - the background queue Swift resolved profiles on. ProfileStore's
 *                              reads are synchronous file reads; there is no queue to hop to.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { BehaviorRelay, DisposeBag } from './Observable';
import { describeError } from './ErrorText';
import { JamiUri, UriType, profileTypeForUri } from './JamiUri';
import { JamiConstants } from './JamiConstants';
import { ServiceRegistry } from './ServiceRegistry';
import { ManagedProfileSource, ProfileSource, ProfileStore } from './ProfileStore';
import { VCardUtils } from './VCardUtils';
import { Profile, ProfileType } from '../model/Profile';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ProfilesService';

/** Swift `avatarsCache.totalCostLimit = 8 * 1024 * 1024`. */
const TOTAL_COST_LIMIT: number = 8 * 1024 * 1024;

/** The only avatar size Swift bothered to cache: `Constants.defaultAvatarSize * 2`. */
const CACHED_AVATAR_SIZE: number = JamiConstants.DEFAULT_AVATAR_SIZE * 2;

/** Swift `private struct ProfileKey: Hashable`. */
class ProfileKey {
  readonly accountId: string;
  readonly uri: string;

  constructor(accountId: string, uri: string) {
    this.accountId = accountId;
    this.uri = uri;
  }

  /** Swift got hashing for free; an ArkTS Map needs a primitive key. */
  get cacheKey(): string {
    return this.accountId + '\u0000' + this.uri;
  }
}

/** One entry of `avatarsCache`: Swift's NSCache `object` plus the `cost` it was stored with. */
class CachedAvatar {
  readonly object: image.PixelMap;
  readonly cost: number;

  constructor(object: image.PixelMap, cost: number) {
    this.object = object;
    this.cost = cost;
  }
}

export class ProfilesService {
  /**
   * Swift `private var profiles: ThreadSafeDictionary<ProfileKey, ReplaySubject<Profile>>`.
   * `ReplaySubject.create(bufferSize: 1)` becomes a `BehaviorRelay` seeded with
   * `Profile.empty()`: the one behavioural difference is that a brand-new subscriber sees the
   * empty profile immediately instead of nothing at all, which is what a row renders anyway
   * while the first resolution runs.
   */
  private profiles: Map<string, BehaviorRelay<Profile>> = new Map<string, BehaviorRelay<Profile>>();

  /** Swift `var accountProfiles: ThreadSafeDictionary<String, ReplaySubject<Profile>>`. */
  accountProfiles: Map<string, BehaviorRelay<Profile>> = new Map<string, BehaviorRelay<Profile>>();

  /** Swift `private let avatarsCache = NSCache<NSString, UIImage>()`. */
  private avatarsCache: Map<string, CachedAvatar> = new Map<string, CachedAvatar>();
  private avatarsCacheCost: number = 0;

  /** Swift `private let profileStore: ProfileStore` (defaulted in the initializer). */
  private store: ProfileStore | null = null;

  /** Swift `let disposeBag = DisposeBag()`. */
  readonly disposeBag: DisposeBag = new DisposeBag();

  private get profileStore(): ProfileStore {
    let store: ProfileStore | null = this.store;
    if (store === null) {
      store = new ProfileStore();
      this.store = store;
    }
    return store;
  }

  // MARK: - URI helpers

  /**
   * Swift `static func profileUriString(for uri: JamiURI) -> String?`.
   * A SIP peer is filed under its bare hash, with host and port dropped, so the same peer
   * reached through two proxies lands on one profile.
   */
  static profileUriString(uri: JamiUri): string | null {
    if (uri.schema !== UriType.SIP) {
      return uri.uriString;
    }
    const peerHash: string | null = uri.hash;
    if (peerHash === null) {
      return null;
    }
    return JamiUri.fromInfoHash(UriType.SIP, peerHash).uriString;
  }

  /** Swift `private func normalizedURI(_ uri: String) -> String`. */
  private normalizedURI(uri: string): string {
    const parsed: string | null = JamiUri.parse(uri).uriString;
    return parsed === null ? uri : parsed;
  }

  // MARK: - Inbound events

  /**
   * Swift `func profileReceived(contact:withAccountId:path:)` - the ProfilesAdapter delegate
   * callback. `path` is the file the daemon wrote and is unused here exactly as in the source:
   * the profile is re-read through ProfileStore's own lookup order. With no daemon this is
   * never called from the bridge; it stays public because it is the contract's entry point and
   * ConversationsManager forwards to it.
   */
  profileReceived(uri: string, accountId: string, path: string): void {
    const uriString: string | null = JamiUri.fromInfoHash(UriType.RING, uri).uriString;
    if (uriString === null) {
      return;
    }
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'profile received for %{public}s (path len %{public}d)',
      uriString, path.length);
    this.removePeerProfiles(uriString, accountId);
    this.triggerProfileSignal(uriString, accountId);
  }

  /** Swift `func sipPeerNameReceived(_:uri:accountId:)`. */
  sipPeerNameReceived(alias: string, uri: string, accountId: string): void {
    const normalized: string = this.normalizedURI(uri);
    const profile: Profile = new Profile(normalized, alias, null, ProfileType.SIP);
    if (!this.profileStore.saveSipPeerProfile(profile, accountId)) {
      return;
    }
    this.triggerProfileSignal(normalized, accountId);
  }

  /** Swift `func invitationAccepted(_:accountId:)`. */
  invitationAccepted(profile: Profile, accountId: string): void {
    this.profileStore.save(profile, accountId, ManagedProfileSource.INVITATION);
    this.triggerProfileSignal(profile.uri, accountId);
  }

  /**
   * Swift `func invitationSent(_:accountId:)`. Swift took a struct copy before rewriting
   * `uri`; a Profile is a reference here, so the copy is explicit - the caller's object must
   * not change under it.
   */
  invitationSent(profile: Profile, accountId: string): void {
    const normalized: Profile = new Profile(this.normalizedURI(profile.uri), profile.alias,
      profile.photo, profile.type);
    if (normalized.isEmpty) {
      return;
    }
    if (!this.profileStore.save(normalized, accountId, ManagedProfileSource.JAMS_SEARCH)) {
      return;
    }
    this.triggerProfileSignal(normalized.uri, accountId);
  }

  /** Swift `func peerDiscarded(uri:accountId:)`. */
  peerDiscarded(uri: string, accountId: string): void {
    this.removePeerProfiles(uri, accountId);
    this.triggerProfileSignal(uri, accountId);
  }

  /** Swift `func conversationDeleted(uri:accountId:)`. */
  conversationDeleted(uri: string, accountId: string): void {
    const normalized: string = this.normalizedURI(uri);
    this.profileStore.removeManagedProfiles(normalized, accountId);
    this.triggerProfileSignal(normalized, accountId);
  }

  /** Swift `func accountContactsCleared(accountId:)`. */
  accountContactsCleared(accountId: string): void {
    this.profileStore.removeAllManagedProfiles(accountId);
  }

  /** Swift `private func removePeerProfiles(uri:accountId:)`. */
  private removePeerProfiles(uri: string, accountId: string): void {
    const normalized: string = this.normalizedURI(uri);
    this.profileStore.remove(normalized, accountId, ManagedProfileSource.JAMS_SEARCH);
    this.profileStore.remove(normalized, accountId, ManagedProfileSource.INVITATION);
  }

  // MARK: - Contact profiles

  /**
   * Swift `func getProfile(uri:accountId:) -> Observable<Profile>`.
   * The 0.1s hop Swift used to leave the subject returned before the first value arrives is a
   * `setTimeout` here, for the same reason: a subscriber attached on the same turn must not
   * miss the first resolution.
   */
  getProfile(uri: string, accountId: string): BehaviorRelay<Profile> {
    const normalized: string = this.normalizedURI(uri);
    const key: ProfileKey = new ProfileKey(accountId, normalized);
    let subject: BehaviorRelay<Profile> | undefined = this.profiles.get(key.cacheKey);
    if (subject === undefined) {
      subject = new BehaviorRelay<Profile>(Profile.empty());
      this.profiles.set(key.cacheKey, subject);
      setTimeout(() => {
        this.triggerProfileSignal(normalized, accountId);
      }, 100);
    }
    return subject;
  }

  /** Swift `func hasStoredProfile(uri:accountId:) -> Bool`. */
  hasStoredProfile(uri: string, accountId: string): boolean {
    return this.profileStore.hasProfile(this.normalizedURI(uri), accountId);
  }

  /** Swift `private func triggerProfileSignal(uri:accountId:)`. */
  private triggerProfileSignal(uri: string, accountId: string): void {
    const key: ProfileKey = new ProfileKey(accountId, this.normalizedURI(uri));
    const subject: BehaviorRelay<Profile> | undefined = this.profiles.get(key.cacheKey);
    if (subject === undefined) {
      return;
    }
    subject.accept(this.resolveProfile(key));
  }

  /** Swift `private func resolveProfile(for:) -> Profile`. */
  private resolveProfile(key: ProfileKey): Profile {
    const stored: Profile | null = this.resolveStoredProfile(key);
    if (stored !== null) {
      return stored;
    }
    // No vCard from this peer yet: libjami sends one with ProfileReceived when it arrives.
    return Profile.empty();
  }

  /**
   * Swift `private func resolveStoredProfile(for:) -> Profile?`. The lookup order IS the
   * behaviour: a peer-supplied profile is the base, and the user's own custom edits win over
   * every field it set.
   */
  private resolveStoredProfile(key: ProfileKey): Profile | null {
    const customProfile: Profile | null =
      this.profileStore.profile(key.uri, key.accountId, ProfileSource.CUSTOM);

    let peerProfile: Profile | null =
      this.profileStore.profile(key.uri, key.accountId, ProfileSource.CONTACT);
    if (peerProfile === null) {
      peerProfile = this.profileStore.legacyContactProfile(key.uri, key.accountId);
    }
    if (peerProfile === null) {
      peerProfile = this.profileStore.profile(key.uri, key.accountId, ProfileSource.JAMS_SEARCH);
    }
    if (peerProfile === null) {
      peerProfile = this.invitationProfile(key);
    }
    return peerProfile === null ? customProfile : peerProfile.merging(customProfile);
  }

  /** Swift `private func invitationProfile(for:) -> Profile?`. */
  private invitationProfile(key: ProfileKey): Profile | null {
    return this.profileStore.profile(key.uri, key.accountId, ProfileSource.INVITATION);
  }

  /** Swift `func getOriginalProfile(uri:accountId:) -> Profile?` - the peer's own, unedited. */
  getOriginalProfile(uri: string, accountId: string): Profile | null {
    const normalized: string = this.normalizedURI(uri);
    const contact: Profile | null =
      this.profileStore.profile(normalized, accountId, ProfileSource.CONTACT);
    return contact === null
      ? this.profileStore.legacyContactProfile(normalized, accountId)
      : contact;
  }

  /** Swift `func getCustomProfile(uri:accountId:) -> Profile?` - only the user's own edits. */
  getCustomProfile(uri: string, accountId: string): Profile | null {
    return this.profileStore.profile(this.normalizedURI(uri), accountId, ProfileSource.CUSTOM);
  }

  /**
   * Swift `@discardableResult func updateCustomProfile(uri:accountId:alias:photo:) -> Bool`.
   * Clearing both fields deletes the override rather than storing an empty one, so the peer's
   * own profile becomes visible again.
   */
  updateCustomProfile(uri: string, accountId: string, alias: string | null,
                      photo: string | null): boolean {
    const normalized: string = this.normalizedURI(uri);
    const profile: Profile =
      new Profile(normalized, alias, photo, profileTypeForUri(normalized));
    let saved: boolean;
    if (profile.isEmpty) {
      this.profileStore.remove(normalized, accountId, ManagedProfileSource.CUSTOM);
      saved = true;
    } else {
      saved = this.profileStore.save(profile, accountId, ManagedProfileSource.CUSTOM);
    }
    if (saved) {
      this.triggerProfileSignal(normalized, accountId);
    }
    return saved;
  }

  // MARK: - Account profile (Swift `extension ProfilesService`)

  /** Swift `func getAccountProfile(accountId:) -> Observable<Profile>`. */
  getAccountProfile(accountId: string): BehaviorRelay<Profile> {
    let subject: BehaviorRelay<Profile> | undefined = this.accountProfiles.get(accountId);
    if (subject === undefined) {
      subject = new BehaviorRelay<Profile>(Profile.empty());
      this.accountProfiles.set(accountId, subject);
      setTimeout(() => {
        this.triggerAccountProfileSignal(accountId);
      }, 100);
    }
    return subject;
  }

  /** Swift `private func triggerAccountProfileSignal(accountId:)`. */
  private triggerAccountProfileSignal(accountId: string): void {
    const subject: BehaviorRelay<Profile> | undefined = this.accountProfiles.get(accountId);
    if (subject === undefined) {
      return;
    }
    const stored: Profile | null = this.profileStore.accountProfile(accountId);
    subject.accept(stored === null ? Profile.empty() : stored);
  }

  /**
   * Swift `func accountVCardPayload(accountId:) -> Data?` - the account's own vCard, as sent
   * with an outgoing trust request. Null when the user never set a name or a picture.
   *
   * Building the payload is local and real; DELIVERING it is the daemon gap, and belongs to
   * whichever call site sends the trust request.
   */
  accountVCardPayload(accountId: string): Uint8Array | null {
    const profile: Profile | null = this.profileStore.accountProfile(accountId);
    if (profile === null || profile.isEmpty) {
      return null;
    }
    return VCardUtils.dataWithImageAndUUID(profile);
  }

  /** Swift `func accountProfileUpdated(accountId:)`. */
  accountProfileUpdated(accountId: string): void {
    this.triggerAccountProfileSignal(accountId);
  }

  /** Swift `func updateAccountProfile(accountId:alias:photo:accountURI:)`. */
  updateAccountProfile(accountId: string, alias: string | null, photo: string | null,
                       accountURI: string): void {
    const profile: Profile =
      new Profile(accountURI, alias, photo, profileTypeForUri(accountURI));
    if (this.profileStore.saveAccountProfile(profile, accountId)) {
      this.triggerAccountProfileSignal(accountId);
    }
  }

  // MARK: - Avatar cache

  /**
   * Swift `func key(for data: Data, size: CGFloat) -> String` - SHA256 of the bytes plus the
   * requested size, so two contacts sharing one picture share one decode.
   */
  key(data: Uint8Array, size: number): string {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const input: cryptoFramework.DataBlob = { data: data };
    md.updateSync(input);
    const digest: cryptoFramework.DataBlob = md.digestSync();
    let hex: string = '';
    for (let i: number = 0; i < digest.data.length; i++) {
      hex += digest.data[i].toString(16).padStart(2, '0');
    }
    return hex + '|' + Math.trunc(size).toString();
  }

  /** Swift `subscript(_ key: String) -> UIImage?` (getter). */
  private cachedAvatar(key: string): image.PixelMap | null {
    const entry: CachedAvatar | undefined = this.avatarsCache.get(key);
    return entry === undefined ? null : entry.object;
  }

  /**
   * Swift `subscript(_ key: String) -> UIImage?` (setter). NSCache evicted by cost on its own;
   * this does it explicitly against the same `totalCostLimit`.
   *
   * ponytail: insertion-order (FIFO) eviction, not LRU - switch if the hit rate ever matters.
   * Evicted PixelMaps are dropped, never released: the UI may still be rendering one, and
   * releasing it out from under a live Image() would blank an avatar that is on screen.
   */
  private cacheAvatar(key: string, value: image.PixelMap | null): void {
    const existing: CachedAvatar | undefined = this.avatarsCache.get(key);
    if (existing !== undefined) {
      this.avatarsCacheCost -= existing.cost;
      this.avatarsCache.delete(key);
    }
    if (value === null) {
      return;
    }
    const cost: number = value.getPixelBytesNumber();
    this.avatarsCache.set(key, new CachedAvatar(value, cost));
    this.avatarsCacheCost += cost;

    while (this.avatarsCacheCost > TOTAL_COST_LIMIT && this.avatarsCache.size > 1) {
      const oldest: string | undefined = this.avatarsCache.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      const evicted: CachedAvatar | undefined = this.avatarsCache.get(oldest);
      if (evicted !== undefined) {
        this.avatarsCacheCost -= evicted.cost;
      }
      this.avatarsCache.delete(oldest);
    }
  }

  /**
   * Swift `func getAvatarFor(_ data: Data, size: CGFloat) -> UIImage?`, via
   * `Data.convertToImage(size:)` (Ring/Ring/Extensions/Data+Helpers.swift:35-41).
   *
   * Async where Swift was synchronous, because the only way to release an ImageSource on
   * HarmonyOS is `release(): Promise<void>` and rule 8 says it is released in `finally`.
   * Swift scaled by `UIScreen.main.scale` inside the decode; a .ts module cannot reach the
   * display, so `size` is taken as the pixel size the caller already wants.
   */
  async getAvatarFor(data: Uint8Array, size: number): Promise<image.PixelMap | null> {
    const cacheKey: string = this.key(data, size);
    const cached: image.PixelMap | null = this.cachedAvatar(cacheKey);
    if (cached !== null) {
      return cached;
    }

    const buffer: ArrayBuffer = new ArrayBuffer(data.length);
    new Uint8Array(buffer).set(data);

    let source: image.ImageSource | null = null;
    let decoded: image.PixelMap | null = null;
    try {
      source = image.createImageSource(buffer);
      const side: number = Math.max(1, Math.round(size));
      const options: image.DecodingOptions = { desiredSize: { width: side, height: side } };
      decoded = source.createPixelMapSync(options);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'avatar decode failed: %{public}s',
        describeError(err as BusinessError));
      decoded = null;
    } finally {
      if (source !== null) {
        await source.release();
      }
    }

    if (decoded !== null && size === CACHED_AVATAR_SIZE) {
      this.cacheAvatar(cacheKey, decoded);
    }
    return decoded;
  }
}
