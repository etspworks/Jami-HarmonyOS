/*
 * Ported from Ring/Ring/Models/AccountCredentialsModel.swift:21-86 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The SIP credentials of an account, as the daemon's credential list carries them.
 */

import { ConfigKey } from './ConfigKeyModel';

/** Swift `enum CredentialsError: Error { case notEnoughData }`. */
export const CREDENTIALS_ERROR_NOT_ENOUGH_DATA: string = 'CredentialsError.notEnoughData';

export class AccountCredentialsModel {
  username: string = '';
  password: string = '';
  accountRealm: string = '';

  /** Swift `convenience init(withUsername:password:accountRealm:)`. */
  constructor(username: string = '', password: string = '', accountRealm: string = '') {
    this.username = username;
    this.password = password;
    this.accountRealm = accountRealm;
  }

  /**
   * Swift `convenience init(withRawaData:) throws` - throws when any of the three daemon
   * credential keys is absent.
   */
  static fromRawData(raw: Map<string, string>): AccountCredentialsModel {
    const username: string | undefined = raw.get(String(ConfigKey.ACCOUNT_USERNAME));
    const password: string | undefined = raw.get(String(ConfigKey.ACCOUNT_PASSWORD));
    const accountRealm: string | undefined = raw.get(String(ConfigKey.ACCOUNT_REALM));
    if (username === undefined || password === undefined || accountRealm === undefined) {
      throw new Error(CREDENTIALS_ERROR_NOT_ENOUGH_DATA);
    }
    return new AccountCredentialsModel(username, password, accountRealm);
  }

  /** Swift `func toDictionary() -> [String: String]`. */
  toDictionary(): Map<string, string> {
    const dictionary: Map<string, string> = new Map<string, string>();
    dictionary.set(String(ConfigKey.ACCOUNT_USERNAME), this.username);
    dictionary.set(String(ConfigKey.ACCOUNT_PASSWORD), this.password);
    dictionary.set(String(ConfigKey.ACCOUNT_REALM), this.accountRealm);
    return dictionary;
  }
}
