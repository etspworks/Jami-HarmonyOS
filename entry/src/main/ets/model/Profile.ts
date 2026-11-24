/*
 * Ported from Ring/Ring/Helpers/VCardUtils.swift:43-69 (struct Profile, enum ProfileType) and
 * its private `Optional<String>.nonEmptyTrimmed()` extension at lines 217-225
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * A contact/account profile as it is carried in a vCard: display name plus an avatar.
 * Pure data - nothing here reaches the jami daemon or the file system. Parsing a vCard into
 * a Profile is VCardUtils' job (../common/VCardUtils).
 *
 * `photo` is the base64 payload of the vCard PHOTO line, kept as the string it arrives as.
 * The Swift code decoded it to `Data` only at the point it built a UIImage; on HarmonyOS the
 * UI decodes it the same way, so the model stays textual and lossless.
 */

/** Swift `enum ProfileType: String`. Raw values are the daemon's own profile-type strings. */
export enum ProfileType {
  RING = 'RING',
  SIP = 'SIP'
}

/**
 * Swift `private extension Optional where Wrapped == String { func nonEmptyTrimmed() }`.
 * Exported because both Profile and VCardUtils use it to decide whether a vCard field
 * actually carries a value.
 */
export function nonEmptyTrimmed(value: string | null | undefined): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  const trimmed: string = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

export class Profile {
  uri: string = '';
  alias: string | null = null;
  /** Base64-encoded avatar, exactly as the vCard PHOTO line carried it. */
  photo: string | null = null;
  /** A `ProfileType` raw value; the Swift struct typed this as a plain String too. */
  type: string = '';

  constructor(uri: string = '', alias: string | null = null, photo: string | null = null,
              type: string = '') {
    this.uri = uri;
    this.alias = alias;
    this.photo = photo;
    this.type = type;
  }

  /** Swift `static var empty: Profile`. */
  static empty(): Profile {
    return new Profile('', null, null, '');
  }

  /** Swift `var isEmpty: Bool` - a profile with neither a name nor a photo says nothing. */
  get isEmpty(): boolean {
    return nonEmptyTrimmed(this.alias) === null && nonEmptyTrimmed(this.photo) === null;
  }

  /**
   * Swift `func merging(preferring preferred: Profile?) -> Profile`.
   * `uri` and `type` always stay this profile's own; only name and photo can be overridden.
   */
  merging(preferred: Profile | null): Profile {
    if (preferred === null) {
      return this;
    }
    const alias: string | null = nonEmptyTrimmed(preferred.alias);
    const photo: string | null = nonEmptyTrimmed(preferred.photo);
    return new Profile(this.uri, alias === null ? this.alias : alias,
      photo === null ? this.photo : photo, this.type);
  }
}
