/*
 * Ported from Ring/Ring/Helpers/VCardUtils.swift:71-215 (class VCardUtils)
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * vCard encode/decode. PURE LOCAL LOGIC - nothing here reaches the jami daemon, so every
 * member works for real. `struct Profile`, `enum ProfileType` and `nonEmptyTrimmed()` live
 * in ../model/Profile (same source file, different owner); they are imported, never redeclared.
 *
 * Swift `Data` becomes `Uint8Array` (the typing ProfilesService/ProfileStore already call with).
 * `class func` becomes `static`. The file-reading members use `@ohos.file.fs` synchronously,
 * like ProfileStore: a `.ts` module cannot call `getContext()`, but these members are given an
 * absolute path by their caller, so no context is needed.
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

import { Profile, ProfileType, nonEmptyTrimmed } from '../model/Profile';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'VCardUtils';

/** Swift `enum VCardFields: String` (VCardUtils.swift:31-37). */
export enum VCardFields {
  BEGIN = 'BEGIN:VCARD',
  PHOTO_JPEG = 'PHOTO;ENCODING=BASE64;TYPE=JPEG:',
  END = 'END:VCARD',
  FULL_NAME = 'FN:',
  TELEPHONE = 'TEL;other:'
}

/**
 * The two name fields `getName(from vCard: CNContact?)` read. iOS' Contacts framework has no
 * HarmonyOS analogue and the source only ever touched these two properties, so the parameter
 * becomes the pair itself rather than a contact object.
 */
export interface VCardContactName {
  givenName: string;
  familyName: string;
}

const LINE_SEPARATOR: RegExp = new RegExp('\r\n|\r|\n');

function logError(what: string, error: BusinessError): void {
  hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s failed: %{public}s', what, error.message);
}

function encodeUtf8(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

export class VCardUtils {

  /** Swift `class func getName(from vCard: CNContact?) -> String`. */
  static getName(vCard: VCardContactName | null): string {
    if (vCard === null) {
      return '';
    }
    let name: string = '';
    if (vCard.givenName.length > 0) {
      name = vCard.givenName;
    }
    if (vCard.familyName.length > 0) {
      if (name.length > 0) {
        name += ' ';
      }
      name += vCard.familyName;
    }
    return name;
  }

  /**
   * Swift `class func dataWithImageAndUUID(from profile: Profile) throws -> Data?`.
   * The account's own vCard: name and phone always, photo when there is one. The Swift
   * `throws` was never exercised (building a string cannot fail), so this does not throw.
   */
  static dataWithImageAndUUID(profile: Profile): Uint8Array | null {
    const beginString: string = String(VCardFields.BEGIN) + '\n';
    const alias: string | null = profile.alias;
    const name: string = alias === null ? '' : alias.trim();
    const telephoneString: string = String(VCardFields.TELEPHONE) + profile.uri + '\n';
    const fullNameString: string = String(VCardFields.FULL_NAME) + name + '\n';
    const endString: string = String(VCardFields.END);

    let vCardString: string = beginString + fullNameString + telephoneString;

    const image: string | null = profile.photo;
    if (image === null) {
      return encodeUtf8(vCardString + endString);
    }
    vCardString += String(VCardFields.PHOTO_JPEG) + image + '\n' + endString;
    return encodeUtf8(vCardString);
  }

  /**
   * Swift `class func vCardData(for profile: Profile) -> Data?` - a peer's vCard: the name and
   * photo lines are emitted only when they actually carry a value.
   */
  static vCardData(profile: Profile): Uint8Array | null {
    const lines: string[] = [String(VCardFields.BEGIN)];
    const alias: string | null = nonEmptyTrimmed(profile.alias);
    if (alias !== null) {
      lines.push(String(VCardFields.FULL_NAME) + alias);
    }
    const photo: string | null = nonEmptyTrimmed(profile.photo);
    if (photo !== null) {
      lines.push(String(VCardFields.PHOTO_JPEG) + photo);
    }
    lines.push(String(VCardFields.TELEPHONE) + profile.uri);
    lines.push(String(VCardFields.END));
    return encodeUtf8(lines.join('\n'));
  }

  /**
   * Swift `class func parseProfile(from string: String) -> Profile?`. Every line is split at
   * its first colon; only PHOTO*, FN and TEL;other are kept. The profile type is decided by
   * the URI exactly as the source decided it (`profileUri.contains("ring")`).
   */
  static parseProfile(text: string): Profile | null {
    let alias: string | null = null;
    let avatar: string | null = null;
    let profileUri: string = '';

    const lines: string[] = text.split(LINE_SEPARATOR);
    for (const line of lines) {
      const colonIndex: number = line.indexOf(':');
      if (colonIndex < 0) {
        continue;
      }
      const key: string = line.substring(0, colonIndex);
      const value: string = line.substring(colonIndex + 1);
      if (key.startsWith('PHOTO')) {
        avatar = value;
      } else if (key === 'FN') {
        alias = value;
      } else if (key === 'TEL;other') {
        profileUri = value;
      }
    }

    const type: string =
      profileUri.indexOf('ring') >= 0 ? String(ProfileType.RING) : String(ProfileType.SIP);
    return new Profile(profileUri, alias, avatar, type);
  }

  /** Swift `class func parseDataToProfile(data: Data) -> Profile?`. */
  static parseDataToProfile(data: Uint8Array): Profile | null {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return VCardUtils.parseProfile(decoder.decodeToString(data));
    } catch (error) {
      logError('decode vCard payload', error as BusinessError);
      return null;
    }
  }

  /** Swift `class func parseToProfile(filePath: String) -> Profile?`. */
  static parseToProfile(filePath: string): Profile | null {
    const text: string | null = readText(filePath);
    return text === null ? null : VCardUtils.parseProfile(text);
  }

  /**
   * Swift `class func nameFromMergedProfile(basePath:customPath:) -> String?` - the custom
   * vCard's name wins whenever it is more than whitespace.
   */
  static nameFromMergedProfile(basePath: string | null, customPath: string | null): string | null {
    if (customPath !== null) {
      const name: string | null = VCardUtils.getNameFromVCard(customPath);
      if (name !== null && name.trim().length > 0) {
        return name;
      }
    }
    return basePath === null ? null : VCardUtils.getNameFromVCard(basePath);
  }

  /** Swift `class func parseMergedProfile(basePath:customPath:) -> Profile?`. */
  static parseMergedProfile(basePath: string | null, customPath: string | null): Profile | null {
    const base: Profile | null = basePath === null ? null : VCardUtils.parseToProfile(basePath);
    const custom: Profile | null =
      customPath === null ? null : VCardUtils.parseToProfile(customPath);
    return base === null ? custom : base.merging(custom);
  }

  /**
   * Swift `class func getNameFromVCard(filePath: String) -> String?` - the FN line only, without
   * parsing the rest of the card.
   *
   * ponytail: the source streamed the file 1 KB at a time to stop early on a big photo line;
   * this reads the whole vCard (tens of KB at worst) and scans it. Stream it if avatar payloads
   * ever grow enough to matter.
   */
  static getNameFromVCard(filePath: string): string | null {
    const text: string | null = readText(filePath);
    if (text === null) {
      return null;
    }
    const prefix: string = String(VCardFields.FULL_NAME);
    for (const line of text.split(LINE_SEPARATOR)) {
      if (line.startsWith(prefix)) {
        return line.substring(prefix.length);
      }
    }
    return null;
  }
}

/** Swift `try? String(contentsOfFile:encoding:.utf8)` - a missing/unreadable card is just null. */
function readText(filePath: string): string | null {
  try {
    return fs.readTextSync(filePath);
  } catch (error) {
    logError('read ' + filePath, error as BusinessError);
    return null;
  }
}
