/*
 * Ported from Ring/Ring/Models/ContactModel.swift:22-70 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One contact of an account, as the daemon's contact list describes it. `added` defaults to
 * "now" only when the daemon sent no timestamp, exactly as the Swift model did.
 */

import { JamiUri, UriType } from '../common/JamiUri';
import { stringToBool } from './CallDetails';

export class ContactModel {
  hash: string = '';
  conversationId: string = '';
  userName: string | null = null;
  uriString: string | null = null;
  confirmed: boolean = false;
  added: Date = new Date();
  banned: boolean = false;
  type: UriType = UriType.RING;

  /** Swift `init(withUri contactUri: JamiURI)`. */
  static fromUri(contactUri: JamiUri): ContactModel {
    const contact: ContactModel = new ContactModel();
    contact.uriString = contactUri.uriString;
    contact.type = contactUri.schema;
    const hash: string | null = contactUri.hash;
    contact.hash = hash === null ? '' : hash;
    return contact;
  }

  /** Swift `init(withDictionary dictionary:)` - jami contacts only. */
  static fromDictionary(dictionary: Map<string, string>): ContactModel {
    const contact: ContactModel = new ContactModel();

    const hash: string | undefined = dictionary.get('id');
    if (hash !== undefined) {
      contact.hash = hash;
      const uriString: string | null = JamiUri.fromInfoHash(UriType.RING, hash).uriString;
      if (uriString !== null) {
        contact.uriString = uriString;
      }
    }

    const confirmed: string | undefined = dictionary.get('confirmed');
    if (confirmed !== undefined) {
      const parsed: boolean | null = stringToBool(confirmed);
      contact.confirmed = parsed === null ? false : parsed;
    }

    const added: string | undefined = dictionary.get('added');
    if (added !== undefined) {
      const seconds: number = Number.parseFloat(added);
      if (!Number.isNaN(seconds)) {
        contact.added = new Date(seconds * 1000);
      }
    }

    const banned: string | undefined = dictionary.get('banned');
    if (banned !== undefined) {
      const isBanned: boolean | null = stringToBool(banned);
      if (isBanned !== null) {
        contact.banned = isBanned;
      }
    }

    const conversationId: string | undefined = dictionary.get('conversationId');
    if (conversationId !== undefined) {
      contact.conversationId = conversationId;
    }

    return contact;
  }

  /** Swift `var addedDate` - the moment the contact was added, in epoch seconds. */
  get addedDate(): number {
    return Math.floor(this.added.getTime() / 1000);
  }

  /** Swift `static func == (lhs:rhs:)` - the URI alone is the identity. */
  equals(other: ContactModel): boolean {
    return this.uriString === other.uriString;
  }
}
