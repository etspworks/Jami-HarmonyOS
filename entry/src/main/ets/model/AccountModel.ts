/*
 * Ported from Ring/Ring/Models/AccountModel.swift:26-246 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One account, as the jami daemon describes it. `details`/`volatileDetails` are the daemon's
 * two detail maps; the derived fields below are re-read from them on every update, exactly as
 * the Swift `willSet` observers did.
 *
 * The Swift model guarded each map with a DispatchQueue (`detailsQueue`,
 * `volatileDetailsQueue`, `syncQueue`). ArkTS has no shared-memory concurrency here - the
 * model lives on the single ArkTS instance that owns it - so the queues carry over as plain
 * accessors and the backing fields keep their Swift names.
 */

import { AccountConfigModel, AccountType, accountTypeFromRaw } from './AccountConfigModel';
import { AccountCredentialsModel } from './AccountCredentialsModel';
import { ConfigKey, ConfigKeyModel } from './ConfigKeyModel';
import { DeviceModel } from './DeviceModel';

/** Swift `enum AccountModelError: Error { case unexpectedError }`. */
export const ACCOUNT_MODEL_ERROR_UNEXPECTED: string = 'AccountModelError.unexpectedError';

/** Swift `enum AccountState: String` (Ring/CommonHelpers.swift:318). */
export enum AccountState {
  REGISTERED = 'REGISTERED',
  READY = 'READY',
  UNREGISTERED = 'UNREGISTERED',
  TRYING = 'TRYING',
  ERROR = 'ERROR',
  ERROR_GENERIC = 'ERROR_GENERIC',
  ERROR_AUTH = 'ERROR_AUTH',
  ERROR_NETWORK = 'ERROR_NETWORK',
  ERROR_HOST = 'ERROR_HOST',
  ERROR_CONF_STUN = 'ERROR_CONF_STUN',
  ERROR_EXIST_STUN = 'ERROR_EXIST_STUN',
  ERROR_SERVICE_UNAVAILABLE = 'ERROR_SERVICE_UNAVAILABLE',
  ERROR_NOT_ACCEPTABLE = 'ERROR_NOT_ACCEPTABLE',
  ERROR_REQUEST_TIMEOUT = 'Request Timeout',
  ERROR_NEED_MIGRATION = 'ERROR_NEED_MIGRATION',
  INITIALIZING = 'INITIALIZING'
}

const ACCOUNT_STATE_ERRORS: AccountState[] = [
  AccountState.ERROR,
  AccountState.ERROR_GENERIC,
  AccountState.ERROR_AUTH,
  AccountState.ERROR_HOST,
  AccountState.ERROR_CONF_STUN,
  AccountState.ERROR_EXIST_STUN,
  AccountState.ERROR_SERVICE_UNAVAILABLE,
  AccountState.ERROR_NOT_ACCEPTABLE,
  AccountState.ERROR_REQUEST_TIMEOUT,
  AccountState.ERROR_NEED_MIGRATION,
  AccountState.ERROR_NETWORK
];

function buildRawToAccountState(): Map<string, AccountState> {
  const map: Map<string, AccountState> = new Map<string, AccountState>();
  for (const state of [
    AccountState.REGISTERED, AccountState.READY, AccountState.UNREGISTERED, AccountState.TRYING,
    AccountState.ERROR, AccountState.ERROR_GENERIC, AccountState.ERROR_AUTH,
    AccountState.ERROR_NETWORK, AccountState.ERROR_HOST, AccountState.ERROR_CONF_STUN,
    AccountState.ERROR_EXIST_STUN, AccountState.ERROR_SERVICE_UNAVAILABLE,
    AccountState.ERROR_NOT_ACCEPTABLE, AccountState.ERROR_REQUEST_TIMEOUT,
    AccountState.ERROR_NEED_MIGRATION, AccountState.INITIALIZING
  ]) {
    map.set(String(state), state);
  }
  return map;
}

const RAW_TO_ACCOUNT_STATE: Map<string, AccountState> = buildRawToAccountState();

/** Swift `AccountState(rawValue:)`. */
export function accountStateFromRaw(raw: string): AccountState | null {
  const state: AccountState | undefined = RAW_TO_ACCOUNT_STATE.get(raw);
  return state === undefined ? null : state;
}

/** Swift `AccountState.isError()`. */
export function accountStateIsError(state: AccountState): boolean {
  return ACCOUNT_STATE_ERRORS.indexOf(state) >= 0;
}

/**
 * Swift `NSString.boolValue` (used by `String.boolValue`): true for a leading "y"/"Y"/"t"/"T"
 * or a non-zero leading integer, false otherwise.
 */
export function nsBoolValue(value: string): boolean {
  const match: RegExpExecArray | null = new RegExp('^\\s*([+-]?)([0-9]+|[yYtT])').exec(value);
  if (match === null) {
    return false;
  }
  const token: string = match[2];
  if (token === 'y' || token === 'Y' || token === 't' || token === 'T') {
    return true;
  }
  return Number.parseInt(token, 10) !== 0;
}

/** Swift `extension Bool { func toString() }`. */
export function boolToString(value: boolean): string {
  return value ? 'true' : 'false';
}

export class AccountModel {
  id: string = '';
  credentialDetails: AccountCredentialsModel[] = [];
  devices: DeviceModel[] = [];
  username: string = '';
  type: AccountType = AccountType.RING;
  isJams: boolean = false;
  enabled: boolean = true;

  /** Swift `var protectedDetails` / `var protectedVolatileDetails`. */
  protectedDetails: AccountConfigModel | null = null;
  protectedVolatileDetails: AccountConfigModel | null = null;

  private _status: AccountState = AccountState.UNREGISTERED;
  private _registeredName: string = '';
  private _proxy: string = '';

  /** Swift `convenience init(withAccountId:)`. */
  constructor(accountId: string = '') {
    this.id = accountId;
  }

  /** Swift `convenience init(withAccountId:details:volatileDetails:credentials:devices:)`. */
  static withDetails(accountId: string, details: AccountConfigModel,
                     volatileDetails: AccountConfigModel,
                     credentials: AccountCredentialsModel[],
                     devices: DeviceModel[]): AccountModel {
    const account: AccountModel = new AccountModel(accountId);
    account.details = details;
    account.volatileDetails = volatileDetails;
    account.credentialDetails = credentials;
    account.devices = devices;
    return account;
  }

  /** Swift `var details` - the setter runs `protectedDetails`'s `willSet` observer. */
  get details(): AccountConfigModel | null {
    return this.protectedDetails;
  }

  set details(newValue: AccountConfigModel | null) {
    if (newValue !== null) {
      this.updateFromDetails(newValue);
    }
    this.protectedDetails = newValue;
  }

  /** Swift `var volatileDetails`. */
  get volatileDetails(): AccountConfigModel | null {
    return this.protectedVolatileDetails;
  }

  set volatileDetails(newValue: AccountConfigModel | null) {
    if (newValue !== null) {
      this.updateFromVolatileDetails(newValue);
    }
    this.protectedVolatileDetails = newValue;
  }

  /** Swift `var status` (guarded by `syncQueue`). */
  get status(): AccountState {
    return this._status;
  }

  set status(newValue: AccountState) {
    this._status = newValue;
  }

  /** Swift `var registeredName`. */
  get registeredName(): string {
    return this._registeredName;
  }

  set registeredName(newValue: string) {
    this._registeredName = newValue;
  }

  /** Swift `var proxy`. */
  get proxy(): string {
    return this._proxy;
  }

  set proxy(newValue: string) {
    this._proxy = newValue;
  }

  /** Swift `var jamiId: String`. */
  get jamiId(): string {
    return this.username.replace(new RegExp('ring:', 'g'), '');
  }

  /** Swift `var managerConfModel` - the key that decides whether the account is JAMS-managed. */
  get managerConfModel(): ConfigKeyModel {
    return new ConfigKeyModel(ConfigKey.MANAGER_URI);
  }

  /** Swift `var accountType` - the raw `Account.type` this account reports. */
  get accountType(): string {
    const details: AccountConfigModel | null = this.protectedDetails;
    return details === null ? '' : details.getValue(ConfigKey.ACCOUNT_TYPE);
  }

  /** Swift `static func == (lhs:rhs:)` - the account id alone is the identity. */
  equals(other: AccountModel): boolean {
    return this.id === other.id;
  }

  /** Swift `func updateDetails(dictionary:)`. */
  updateDetails(dictionary: Map<string, string>): void {
    const newDetails: AccountConfigModel = AccountConfigModel.withDetails(dictionary);
    this.updateFromDetails(newDetails);
    const details: AccountConfigModel | null = this.protectedDetails;
    if (details !== null) {
      details.update(dictionary);
    }
  }

  /** Swift `func updateVolatileDetails(dictionary:)`. */
  updateVolatileDetails(dictionary: Map<string, string>): void {
    const newDetails: AccountConfigModel = AccountConfigModel.withDetails(dictionary);
    this.updateFromVolatileDetails(newDetails);
    const details: AccountConfigModel | null = this.protectedVolatileDetails;
    if (details !== null) {
      details.update(dictionary);
    }
  }

  /** Swift `private func updateFromDetails(details:)`. */
  private updateFromDetails(details: AccountConfigModel): void {
    const username: string = details.getValue(ConfigKey.ACCOUNT_USERNAME);
    if (username.length > 0) {
      this.username = username;
    }
    const accountType: AccountType | null = accountTypeFromRaw(details.getValue(ConfigKey.ACCOUNT_TYPE));
    if (accountType !== null) {
      this.type = accountType;
    }
    // An AccountDetailsChanged echo can be partial: keys with a write still queued are dropped
    // (T-1625), and a missing key read as "" turned the account off until relaunch (T-1626).
    // username and type above already skip an empty value.
    const present: Map<string, string> = details.toDetails();
    const enable: string | undefined = present.get(String(ConfigKey.ACCOUNT_ENABLE));
    if (enable !== undefined) {
      this.enabled = nsBoolValue(enable);
    }
    const managerUri: string | undefined = present.get(this.managerConfModel.hash());
    if (managerUri !== undefined) {
      this.isJams = managerUri.length > 0;
    }
  }

  /** Swift `private func updateFromVolatileDetails(details:)`. */
  private updateFromVolatileDetails(details: AccountConfigModel): void {
    const registeredName: string = details.getValue(ConfigKey.ACCOUNT_REGISTERED_NAME);
    if (registeredName.length > 0) {
      this.registeredName = registeredName;
    }
    const status: AccountState | null =
      accountStateFromRaw(details.getValue(ConfigKey.ACCOUNT_REGISTRATION_STATUS));
    if (status !== null) {
      this.status = status;
    }
    this.proxy = details.getValue(ConfigKey.PROXY_SERVER);
  }

  /** Swift `func setEnable(enable:)` - writes `Account.enable` back into the detail map. */
  setEnable(enable: boolean): void {
    const property: ConfigKeyModel = new ConfigKeyModel(ConfigKey.ACCOUNT_ENABLE);
    const accountDetails: AccountConfigModel | null = this.details;
    if (accountDetails !== null) {
      accountDetails.set(property, boolToString(enable));
    }
    this.details = accountDetails;
  }
}
