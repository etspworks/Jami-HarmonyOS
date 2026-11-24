/*
 * Ported from Ring/Ring/Storage/ProfileStore.swift:21-231 plus the path helpers it calls,
 * Ring/CommonHelpers.swift:82-232 (`ManagedProfileFolder`, `ProfilePathHelper`)
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The on-disk vCard store: every contact, invitation, JAMS-search and account profile the app
 * has ever seen is a `.vcf` file under the ability's files directory. NOTHING HERE IS A GAP -
 * this is local file IO and it works for real. The daemon only ever supplied the CONTENT of a
 * peer vCard; reading, writing and deleting them is entirely the app's own code.
 *
 * Swift's documents directory (`Constants.documentsPath`, an app-group container URL) becomes
 * the ability's `filesDir`. A `.ts` module cannot call `getContext()`, so the context is
 * INJECTED, once, at startup:
 *
 *     ProfileStore.setContext(this.context);   // EntryAbility.onCreate
 *
 * It is STATIC on purpose: `ProfilesService` constructs its own `ProfileStore()` (zero-argument,
 * per the registry contract) and deliberately exposes no pass-through, so an instance setter
 * could never be reached. WITHOUT THAT ONE CALL every read returns null and every write returns
 * false - profiles silently vanish - so it is logged loudly the first time it is needed.
 *
 * SYNCHRONOUS, like the Swift: `ProfilesService` calls straight through these methods inside its
 * resolution path. `@ohos.file.fs` has a full sync surface (`accessSync`/`readTextSync`/
 * `openSync`), so no signature had to become a Promise.
 *
 * NOT CARRIED OVER:
 *   `private static let writeLock = NSLock()` - it serialized writes across Swift's background
 *   queues. ArkTS runs one thread per ability and every method here is synchronous, so there is
 *   no concurrent writer to exclude and nothing for a lock to guard.
 *   Swift wrote with `.atomic` (write-to-temp-then-rename). `fs` has no atomic write option;
 *   these files are small single writes, and a torn vCard simply fails to parse and is
 *   re-fetched, which is the same outcome as a missing one.
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { jami, jamiDataPath } from './JamiNative';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

import { describeError } from './ErrorText';
import { UriType } from './JamiUri';
import { VCardUtils } from './VCardUtils';
import { Profile } from '../model/Profile';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ProfileStore';

/** Swift `enum ProfileSource` (ProfileStore.swift:21-35). */
export enum ProfileSource {
  CUSTOM = 'CUSTOM',
  CONTACT = 'CONTACT',
  JAMS_SEARCH = 'JAMS_SEARCH',
  INVITATION = 'INVITATION'
}

/** Swift `enum ManagedProfileSource: CaseIterable` (ProfileStore.swift:37-49). */
export enum ManagedProfileSource {
  CUSTOM = 'CUSTOM',
  JAMS_SEARCH = 'JAMS_SEARCH',
  INVITATION = 'INVITATION'
}

/**
 * Swift `enum ManagedProfileFolder: String, CaseIterable` (CommonHelpers.swift:82-88).
 * The raw values ARE the directory names on disk, so they are not renamed to SCREAMING_SNAKE.
 */
export enum ManagedProfileFolder {
  JAMS_SEARCH = 'jams-profiles',
  INVITATION = 'invitation-profiles',
  CUSTOM = 'custom-profiles'
}

/** Swift `ManagedProfileSource.allCases`, in declaration order. */
export const MANAGED_PROFILE_SOURCES: ManagedProfileSource[] = [
  ManagedProfileSource.CUSTOM,
  ManagedProfileSource.JAMS_SEARCH,
  ManagedProfileSource.INVITATION
];

/** Swift `ManagedProfileFolder.allCases`, in declaration order. */
export const MANAGED_PROFILE_FOLDERS: ManagedProfileFolder[] = [
  ManagedProfileFolder.JAMS_SEARCH,
  ManagedProfileFolder.INVITATION,
  ManagedProfileFolder.CUSTOM
];

/** Swift `ManagedProfileFolder.contactProfileFallbacks` (CommonHelpers.swift:87). */
export const CONTACT_PROFILE_FALLBACKS: ManagedProfileFolder[] = [
  ManagedProfileFolder.JAMS_SEARCH,
  ManagedProfileFolder.INVITATION
];

/** Swift `ProfileSource.managedFolder` - `.contact` has no managed folder of its own. */
function managedFolder(source: ProfileSource): ManagedProfileFolder | null {
  if (source === ProfileSource.CUSTOM) {
    return ManagedProfileFolder.CUSTOM;
  }
  if (source === ProfileSource.JAMS_SEARCH) {
    return ManagedProfileFolder.JAMS_SEARCH;
  }
  if (source === ProfileSource.INVITATION) {
    return ManagedProfileFolder.INVITATION;
  }
  return null;
}

/** Swift `ManagedProfileSource.profileSource`. */
function profileSource(source: ManagedProfileSource): ProfileSource {
  if (source === ManagedProfileSource.JAMS_SEARCH) {
    return ProfileSource.JAMS_SEARCH;
  }
  if (source === ManagedProfileSource.INVITATION) {
    return ProfileSource.INVITATION;
  }
  return ProfileSource.CUSTOM;
}

/** Swift `FileManager.default.fileExists(atPath:)` - a throw is answered false, as Foundation does. */
function fileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (error) {
    return false;
  }
}

function logError(what: string, error: BusinessError): void {
  hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s: %{public}s', what, describeError(error));
}

/** Swift `Data(string.utf8).base64EncodedString()` - the vCard file name is a base64 URI. */
function base64(value: string): string {
  const bytes: Uint8Array = new util.TextEncoder().encodeInto(value);
  return new util.Base64Helper().encodeToStringSync(bytes);
}

/** Swift `ProfilePathHelper.jamiHash(from:)` (CommonHelpers.swift:91-99). */
export function jamiHash(uri: string): string {
  return uri
    .replace(new RegExp('<', 'g'), '')
    .replace(new RegExp('>', 'g'), '')
    .replace(new RegExp('@ring\\.dht', 'g'), '')
    .replace(new RegExp('ring:', 'g'), '')
    .replace(new RegExp('jami:', 'g'), '')
    .trim();
}

/** Swift `ProfilePathHelper.profileURICandidates(for:)` (CommonHelpers.swift:101-106). */
export function profileURICandidates(contactId: string): string[] {
  const hash: string = jamiHash(contactId);
  if (hash.length === 0) {
    return [];
  }
  return ['jami:' + hash, 'ring:' + hash];
}

/** Swift `ProfilePathHelper.contactsPath(accountId:documents:createIfNotExists:)`. */
function contactsPath(accountId: string, documents: string, createIfNotExists: boolean): string | null {
  const profilesFolder: string = documents + '/' + accountId + '/profiles/';
  if (fileExists(profilesFolder)) {
    return profilesFolder;
  }
  if (!createIfNotExists) {
    return null;
  }
  try {
    fs.mkdirSync(profilesFolder, true);
  } catch (error) {
    logError('contactsPath ' + profilesFolder, error as BusinessError);
    return null;
  }
  return fileExists(profilesFolder) ? profilesFolder : null;
}

/** Swift `ProfilePathHelper.legacyContactProfilePath(accountId:profileURI:documents:)`. */
function legacyContactProfilePath(accountId: string, profileURI: string, documents: string): string | null {
  const profilesFolder: string | null = contactsPath(accountId, documents, false);
  if (profilesFolder === null) {
    return null;
  }
  return profilesFolder + base64(profileURI) + '.vcf';
}

/** Swift `ProfilePathHelper.contactProfilePath(accountId:contactId:documents:createIfNotExists:)`. */
function contactProfilePath(accountId: string, contactId: string, documents: string,
                            createIfNotExists: boolean): string | null {
  const hash: string = jamiHash(contactId);
  if (hash.length === 0) {
    return null;
  }
  const profilesFolder: string | null = contactsPath(accountId, documents, createIfNotExists);
  if (profilesFolder === null) {
    return null;
  }
  return profilesFolder + base64(hash) + '.vcf';
}

/** Swift `ProfilePathHelper.profileFolderPath(accountId:folder:documents:)`. */
function profileFolderPath(accountId: string, folder: ManagedProfileFolder, documents: string): string {
  return documents + '/' + accountId + '/' + (folder as string);
}

/** Swift `ProfilePathHelper.profilePath(accountId:contactId:folder:documents:createIfNotExists:)`. */
function profilePath(accountId: string, contactId: string, folder: ManagedProfileFolder,
                     documents: string, createIfNotExists: boolean): string | null {
  const hash: string = jamiHash(contactId);
  if (hash.length === 0) {
    return null;
  }
  const folderPath: string = profileFolderPath(accountId, folder, documents);
  if (!fileExists(folderPath)) {
    if (!createIfNotExists) {
      return null;
    }
    try {
      fs.mkdirSync(folderPath, true);
    } catch (error) {
      logError('profilePath ' + folderPath, error as BusinessError);
      return null;
    }
  }
  return folderPath + '/' + base64(hash) + '.vcf';
}

/** Swift `ProfilePathHelper.accountProfilePath(accountId:documents:)`. */
function accountProfilePath(accountId: string, documents: string): string {
  return documents + '/' + accountId + '/profile.vcf';
}

/**
 * The account vCard libjami's updateProfile actually writes, profiles/<base64(uri)>.vcf; it then
 * links profile.vcf to it, and the HarmonyOS sandbox refuses both the hard and the soft link
 * ("Permission denied"), so profile.vcf is missing (T-0529, T-1599).
 */
function writtenAccountProfilePath(accountId: string, documents: string): string | null {
  const ownUri: string = jami.getAccountDetails(accountId)['Account.username'] ?? '';
  return contactProfilePath(accountId, ownUri, documents, false);
}

/** Swift `VCardUtils.parseToProfile(filePath:)` - read the file, then parse the text. */
function parseProfileAtPath(path: string): Profile | null {
  try {
    return VCardUtils.parseProfile(fs.readTextSync(path));
  } catch (error) {
    logError('read ' + path, error as BusinessError);
    return null;
  }
}

/** Swift `try data.write(to:options:.atomic)`, reported as a boolean like its callers want. */
function writeBytes(path: string, data: Uint8Array): boolean {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    fs.writeSync(file.fd, data.buffer as ArrayBuffer);
    return true;
  } catch (error) {
    logError('write ' + path, error as BusinessError);
    return false;
  } finally {
    if (file !== null) {
      fs.closeSync(file);
    }
  }
}

/** Swift `try? FileManager.default.removeItem(atPath:)` - a missing file is the normal case. */
function removeItem(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (error) {
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'remove %{public}s: %{public}s', path,
      describeError(error as BusinessError));
  }
}

export class ProfileStore {
  /**
   * The ability context, for `filesDir` (Swift's `Constants.documentsPath`). STATIC because
   * `ProfilesService` builds its own zero-argument `ProfileStore` - see the header.
   */
  private static context: common.UIAbilityContext | null = null;

  /** CALL ONCE at startup: `ProfileStore.setContext(this.context)` in `EntryAbility.onCreate`. */
  static setContext(context: common.UIAbilityContext): void {
    ProfileStore.context = context;
  }

  /** Swift `Constants.documentsPath`. Null until `setContext` has run. */
  private static documentsPath(): string | null {
    const context: common.UIAbilityContext | null = ProfileStore.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'no context: profiles cannot be read or written (call ProfileStore.setContext at startup)');
      return null;
    }
    // Swift's documents path is libjami's data directory (see JamiNative.startJami).
    return jamiDataPath(context.filesDir);
  }

  /**
   * Swift `func profile(uri:accountId:source:) -> Profile?`. The emptiness rule is the source's:
   * a CUSTOM profile is returned even when empty (the user may have deliberately cleared it),
   * every other source must actually say something.
   */
  profile(uri: string, accountId: string, source: ProfileSource): Profile | null {
    const path: string | null = this.path(uri, accountId, source, false);
    if (path === null || !fileExists(path)) {
      return null;
    }
    const profile: Profile | null = parseProfileAtPath(path);
    if (profile === null) {
      return null;
    }
    if (source === ProfileSource.CUSTOM) {
      return profile;
    }
    return profile.isEmpty ? null : profile;
  }

  /** Swift `func hasProfile(uri:accountId:) -> Bool` - contact or custom, either counts. */
  hasProfile(uri: string, accountId: string): boolean {
    const sources: ProfileSource[] = [ProfileSource.CONTACT, ProfileSource.CUSTOM];
    for (const source of sources) {
      const path: string | null = this.path(uri, accountId, source, false);
      if (path !== null && fileExists(path)) {
        return true;
      }
    }
    return false;
  }

  /** Swift `@discardableResult func save(_:accountId:source:) -> Bool`. */
  save(profile: Profile, accountId: string, source: ManagedProfileSource): boolean {
    if (profile.isEmpty) {
      return false;
    }
    const path: string | null = this.path(profile.uri, accountId, profileSource(source), true);
    if (path === null) {
      return false;
    }
    const data: Uint8Array | null = VCardUtils.vCardData(profile);
    if (data === null) {
      return false;
    }
    return writeBytes(path, data);
  }

  /** Swift `func remove(uri:accountId:source:)`. */
  remove(uri: string, accountId: string, source: ManagedProfileSource): void {
    const path: string | null = this.path(uri, accountId, profileSource(source), false);
    if (path === null) {
      return;
    }
    removeItem(path);
  }

  /**
   * Swift `func removeManagedProfiles(uri:accountId:)` - everything the app stored about this
   * peer: the three managed folders, the legacy contact vCards, and the SIP peer profile.
   */
  removeManagedProfiles(uri: string, accountId: string): void {
    for (const source of MANAGED_PROFILE_SOURCES) {
      this.remove(uri, accountId, source);
    }
    this.removeLegacyContactProfiles(uri, accountId);
    this.removeSipPeerProfile(uri, accountId);
  }

  /** Swift `@discardableResult func saveSipPeerProfile(_:accountId:) -> Bool`. */
  saveSipPeerProfile(profile: Profile, accountId: string): boolean {
    if (profile.isEmpty) {
      return false;
    }
    const path: string | null = this.sipPeerProfilePath(profile.uri, accountId, true);
    if (path === null) {
      return false;
    }
    const data: Uint8Array | null = VCardUtils.vCardData(profile);
    if (data === null) {
      return false;
    }
    return writeBytes(path, data);
  }

  /** Swift `func removeSipPeerProfile(uri:accountId:)`. */
  removeSipPeerProfile(uri: string, accountId: string): void {
    const path: string | null = this.sipPeerProfilePath(uri, accountId, false);
    if (path === null) {
      return;
    }
    removeItem(path);
  }

  /** Swift `func removeAllManagedProfiles(accountId:)` - drops the whole folder per source. */
  removeAllManagedProfiles(accountId: string): void {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return;
    }
    for (const folder of MANAGED_PROFILE_FOLDERS) {
      const path: string = profileFolderPath(accountId, folder, documents);
      try {
        fs.rmdirSync(path);
      } catch (error) {
        // Swift used `try?` - a folder that was never created is the normal case.
        hilog.debug(LOG_DOMAIN, LOG_TAG, 'removeAllManagedProfiles %{public}s: %{public}s', path,
          describeError(error as BusinessError));
      }
    }
  }

  /**
   * Swift `func legacyContactProfile(uri:accountId:) -> Profile?` - vCards written by older
   * versions of the app, named after the full `jami:`/`ring:` URI rather than the hash.
   */
  legacyContactProfile(uri: string, accountId: string): Profile | null {
    for (const path of this.legacyContactProfilePaths(uri, accountId)) {
      if (fileExists(path)) {
        return parseProfileAtPath(path);
      }
    }
    return null;
  }

  /** Swift `func removeLegacyContactProfiles(uri:accountId:)`. */
  removeLegacyContactProfiles(uri: string, accountId: string): void {
    for (const path of this.legacyContactProfilePaths(uri, accountId)) {
      removeItem(path);
    }
  }

  /** Swift `func accountProfile(accountId:) -> Profile?` - the user's own vCard. */
  accountProfile(accountId: string): Profile | null {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return null;
    }
    const path: string = accountProfilePath(accountId, documents);
    if (fileExists(path)) {
      return parseProfileAtPath(path);
    }
    // profile.vcf missing: read the file libjami really wrote instead (T-0529).
    const written: string | null = writtenAccountProfilePath(accountId, documents);
    return written !== null && fileExists(written) ? parseProfileAtPath(written) : null;
  }

  /**
   * Copies the written account vCard to <accountId>/profile.vcf when that file is missing (no
   * Swift counterpart: iOS's link never fails). profile.vcf is the file libjami re-reads every
   * time it sends the vCard to a peer device (JamiAccount::sendProfile), so without it the name
   * and picture never reach contacts (T-1599). libjami deletes profile.vcf before every re-link,
   * so this runs after each updateProfile as well as at account load. The real fix is a copy
   * fallback in the daemon's createFileLink.
   */
  restoreAccountProfileFile(accountId: string): void {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return;
    }
    const path: string = accountProfilePath(accountId, documents);
    if (fileExists(path)) {
      return;
    }
    const written: string | null = writtenAccountProfilePath(accountId, documents);
    if (written === null || !fileExists(written)) {
      return;
    }
    try {
      fs.copyFileSync(written, path);
    } catch (error) {
      logError('restoreAccountProfileFile ' + accountId, error as BusinessError);
    }
  }

  /**
   * Swift `@discardableResult func saveAccountProfile(_:accountId:) -> Bool`. The account vCard
   * carries the UUID + resized picture (`dataWithImageAndUUID`), unlike a peer's.
   */
  saveAccountProfile(profile: Profile, accountId: string): boolean {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return false;
    }
    const data: Uint8Array | null = VCardUtils.dataWithImageAndUUID(profile);
    if (data === null) {
      return false;
    }
    const path: string = accountProfilePath(accountId, documents);
    const folder: string = documents + '/' + accountId;
    // Swift `createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories:)`.
    // Guarded: libjami already owns this folder, and `mkdirSync` throws 13900015 (File exists)
    // on one that is there, where Foundation's call succeeds.
    if (!fileExists(folder)) {
      try {
        fs.mkdirSync(folder, true);
      } catch (error) {
        logError('saveAccountProfile mkdir ' + accountId, error as BusinessError);
        return false;
      }
    }
    if (!writeBytes(path, data)) {
      return false;
    }
    return fileExists(path);
  }

  /** Swift `private func path(uri:accountId:source:createIfNotExists:) -> String?`. */
  private path(uri: string, accountId: string, source: ProfileSource,
               createIfNotExists: boolean): string | null {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return null;
    }
    const folder: ManagedProfileFolder | null = managedFolder(source);
    if (folder === null) {
      return contactProfilePath(accountId, uri, documents, false);
    }
    return profilePath(accountId, uri, folder, documents, createIfNotExists);
  }

  /**
   * Swift `private func sipPeerProfilePath(uri:accountId:createIfNotExists:) -> String?`.
   * Only a `sip:` URI has one; anything else answers null.
   */
  private sipPeerProfilePath(uri: string, accountId: string,
                             createIfNotExists: boolean): string | null {
    if (!uri.startsWith((UriType.SIP as string) + ':')) {
      return null;
    }
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return null;
    }
    return contactProfilePath(accountId, uri, documents, createIfNotExists);
  }

  /** Swift `private func legacyContactProfilePaths(uri:accountId:) -> [String]`. */
  private legacyContactProfilePaths(uri: string, accountId: string): string[] {
    const documents: string | null = ProfileStore.documentsPath();
    if (documents === null) {
      return [];
    }
    const paths: string[] = [];
    for (const candidate of profileURICandidates(uri)) {
      const path: string | null = legacyContactProfilePath(accountId, candidate, documents);
      if (path !== null) {
        paths.push(path);
      }
    }
    return paths;
  }
}
