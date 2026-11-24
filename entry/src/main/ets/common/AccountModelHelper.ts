/*
 * Ported from Ring/Ring/Account/AccountModelHelper.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * Reads an account's daemon detail maps. The Swift helper wrapped an AccountModel and called
 * `details.get(withConfigKeyModel:)`; here it takes the two maps directly, so the helper stays
 * pure and usable before an account model instance exists.
 *
 * `setCredentials` is the one member that still needs the model itself (it replaces the
 * account's credential list), so it takes the account as a parameter rather than through the
 * constructor - AccountsService/ContactsService already construct this helper from the two maps.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

import { AccountModel } from '../model/AccountModel';
import { AccountCredentialsModel } from '../model/AccountCredentialsModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AccountModelHelper';

const RING_ID_PREFIX: string = 'ring:';
const SIP_ID_PREFIX: string = 'sip:';

const ACCOUNT_TYPE_KEY: string = 'Account.type';
const ACCOUNT_ENABLE_KEY: string = 'Account.enable';
const ACCOUNT_USERNAME_KEY: string = 'Account.username';
const ACCOUNT_HOSTNAME_KEY: string = 'Account.hostname';
const ACCOUNT_LOCAL_PORT_KEY: string = 'Account.localPort';
const ACCOUNT_DEVICE_ID_KEY: string = 'Account.deviceID';
const ACCOUNT_REGISTRATION_STATUS_KEY: string = 'Account.registrationStatus';
const ACCOUNT_REGISTERED_NAME_KEY: string = 'Account.registeredName';
const ACCOUNT_MANAGER_URI_KEY: string = 'Account.managerUri';
const ARCHIVE_HAS_PASSWORD_KEY: string = 'Account.archiveHasPassword';

const ACCOUNT_TYPE_SIP: string = 'SIP';
const ACCOUNT_TYPE_RING: string = 'RING';

/** AccountState raw values the Swift `isInError()` tested against, verbatim. */
const ERROR_STATES: string[] = [
  'ERROR',
  'ERROR_AUTH',
  'ERROR_CONF_STUN',
  'ERROR_EXIST_STUN',
  'ERROR_GENERIC',
  'ERROR_HOST',
  'ERROR_NETWORK',
  'ERROR_NOT_ACCEPTABLE',
  'ERROR_SERVICE_UNAVAILABLE',
  'Request Timeout'
];

export class AccountModelHelper {
  private details: Map<string, string>;
  private volatileDetails: Map<string, string>;

  constructor(details: Map<string, string> | null, volatileDetails: Map<string, string> | null) {
    this.details = details === null ? new Map<string, string>() : details;
    this.volatileDetails = volatileDetails === null ? new Map<string, string>() : volatileDetails;
  }

  private detail(key: string): string {
    const value: string | undefined = this.details.get(key);
    return value === undefined ? '' : value;
  }

  private volatile(key: string): string {
    const value: string | undefined = this.volatileDetails.get(key);
    return value === undefined ? '' : value;
  }

  isAccountSip(): boolean {
    return this.detail(ACCOUNT_TYPE_KEY) === ACCOUNT_TYPE_SIP;
  }

  isAccountRing(): boolean {
    return this.detail(ACCOUNT_TYPE_KEY) === ACCOUNT_TYPE_RING;
  }

  isEnabled(): boolean {
    return this.detail(ACCOUNT_ENABLE_KEY) === 'true';
  }

  getRegistrationState(): string {
    return this.volatile(ACCOUNT_REGISTRATION_STATUS_KEY);
  }

  getCurrentDevice(): string {
    return this.volatile(ACCOUNT_DEVICE_ID_KEY);
  }

  getCurrentStringValue(property: string): string {
    return this.detail(property);
  }

  isInError(): boolean {
    return ERROR_STATES.indexOf(this.getRegistrationState()) >= 0;
  }

  /** `var ringId` - the username with the `ring:` prefix stripped. */
  get ringId(): string | null {
    const username: string | undefined = this.details.get(ACCOUNT_USERNAME_KEY);
    if (username === undefined) {
      return null;
    }
    return username.replace(new RegExp(RING_ID_PREFIX, 'g'), '');
  }

  /** The volatile `Account.registeredName` the account screens display. */
  get registeredName(): string {
    return this.volatile(ACCOUNT_REGISTERED_NAME_KEY);
  }

  /** A JAMS-managed account is one whose `Account.managerUri` is set. */
  get isJams(): boolean {
    return this.detail(ACCOUNT_MANAGER_URI_KEY).length > 0;
  }

  /** `var uri` - `sip:user@host:port` for a SIP account, `ring:<hash>` otherwise. */
  get uri(): string | null {
    if (this.isAccountSip()) {
      const name: string = this.detail(ACCOUNT_USERNAME_KEY);
      if (name.length === 0) {
        return null;
      }
      let uri: string = SIP_ID_PREFIX + name;
      const server: string = this.detail(ACCOUNT_HOSTNAME_KEY);
      if (server.length === 0) {
        return uri;
      }
      uri += '@' + server;
      const port: string = this.detail(ACCOUNT_LOCAL_PORT_KEY);
      if (port.length > 0) {
        uri += ':' + port;
      }
      return uri;
    }
    const ringId: string | null = this.ringId;
    if (ringId === null) {
      return null;
    }
    return RING_ID_PREFIX + ringId;
  }

  get hasPassword(): boolean {
    const value: string | undefined = this.details.get(ARCHIVE_HAS_PASSWORD_KEY);
    return (value === undefined ? 'false' : value) === 'true';
  }

  static uriFromRingId(ringId: string): string {
    return RING_ID_PREFIX + ringId;
  }

  /**
   * Swift `private let log = SwiftyBeaver.self`. SwiftyBeaver has no HarmonyOS package; the
   * platform logger takes its place, as everywhere else in this data layer.
   */
  static log(message: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /**
   * Swift `mutating func setCredentials(_ credentials: [[String: String]]?) -> AccountModel`.
   * Clears the account's credential list and rebuilds it from the daemon's raw credential
   * dictionaries; a dictionary missing a key is logged and skipped, exactly as the source did
   * with `CredentialsError.notEnoughData`. A null list just clears.
   *
   * The Swift helper owned the account (`self.account`); this one is built from the detail maps,
   * so the account arrives as a parameter and is returned unchanged in identity.
   */
  setCredentials(account: AccountModel, credentials: Map<string, string>[] | null): AccountModel {
    account.credentialDetails = [];
    if (credentials !== null) {
      for (const credential of credentials) {
        try {
          account.credentialDetails.push(AccountCredentialsModel.fromRawData(credential));
        } catch (error) {
          AccountModelHelper.log('Not enough data to create a credential: ' +
            (error as Error).message);
        }
      }
    }
    return account;
  }
}
