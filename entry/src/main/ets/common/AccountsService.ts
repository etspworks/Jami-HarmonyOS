/*
 * Ported from Ring/Ring/Services/AccountsService.swift:65-1195 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The account domain: the account list, each account's daemon detail maps, its devices and
 * credentials, registration state, device linking, account creation and the per-account
 * configuration writes the settings screens make.
 *
 * THE DAEMON GAP. Every one of those operations went through `AccountAdapter`
 * (Ring/Ring/Bridging/AccountCreation/AccountAdapter.mm), a thin Objective-C++ shim over the
 * prebuilt C++ jami daemon (`xcframework/libjami-core.xcframework` + ~45 native frameworks).
 * That daemon has NO SOURCE ON DISK in this repository, so Rule 11 forbids porting it, faking
 * it, or bridging to it through a sidecar/NDK/wasm shim. The adapter field below therefore
 * resolves to `DaemonService`, and every daemon-backed call reports
 * `DaemonUnavailableError` - never a fabricated account, never a silent no-op. The method
 * exists, is typed, and says "not available", which is what lets a screen render the notice on
 * the right control.
 *
 * What IS ported for real, and works: the account list and its ordering, the current-account
 * rules, the local detail/credential/device models and every read over them, the whole
 * `ServiceEvent` stream and its consumers (`devicesObservable`,
 * `accountCreationStatusObservable`), every daemon->client callback (`registrationStateChanged`,
 * `knownDevicesChanged`, `accountDetailsChanged`, ...) and the local half of each configuration
 * write. Those callbacks simply never fire while the daemon is absent.
 *
 * Concurrency: Swift hopped to `DispatchQueue.global(qos: .background)` in `accountsChanged`,
 * `addDeviceStateChanged`, `deviceAuthStateChanged` and the push-notification setters, and
 * guarded `accountList` with an `NSLock`. ArkTS runs this service on one instance in one
 * thread, so the hops and the lock carry over as direct calls - there is no second writer.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { BehaviorRelay, DisposeBag, PublishSubject } from './Observable';
import { DaemonService } from './DaemonService';
import { ServiceRegistry } from './ServiceRegistry';
import { DBManager } from './DbManager';
import { AccountModelHelper } from './AccountModelHelper';
import { describeError } from './ErrorText';
import { jami, toMap, toRecord } from './JamiNative';
import { PreferenceManager } from './PreferenceManager';
import { ProfileStore } from './ProfileStore';

import {
  AccountModel,
  AccountState,
  accountStateFromRaw,
  accountStateIsError,
  boolToString
} from '../model/AccountModel';
import { AccountConfigModel, AccountType } from '../model/AccountConfigModel';
import { AccountCredentialsModel } from '../model/AccountCredentialsModel';
import { ConfigKey, ConfigKeyModel } from '../model/ConfigKeyModel';
import { DeviceModel } from '../model/DeviceModel';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'AccountsService';

/** SettingsCoordinator's exits after a removal: the smart list, onboarding, migration. */
const SMART_LIST_PAGE: string = 'pages/SmartListConversationsHomePage';
const WALKTHROUGH_PAGE: string = 'pages/WelcomeOnboardingPage';
const MIGRATION_PAGE: string = 'pages/AccountMigrationPage';

/** AccountMigrationPage's route param — Swift `needAccountMigration(accountId:)`. */
interface MigrationRouteParams {
  accountId: string;
  /** Swift `.replaceNavigationStack` (AppCoordinator.migrateAccount): the page has no Back. */
  replacesStack: boolean;
}


/** Swift `enum DeviceRevocationState: Int` - the code `deviceRevocationEnded` carries. */
export enum DeviceRevocationState {
  SUCCESS = 0,
  WRONG_PASSWORD = 1,
  UNKNOWN_DEVICE = 2
}

/** Swift `enum MigrationState: String`. */
export enum MigrationState {
  INVALID = 'INVALID',
  SUCCESS = 'SUCCESS',
  UNKOWN = 'UNKOWN'
}

/** Swift `enum AuthState: Int32` - the device-linking / account-import progress ladder. */
export enum AuthState {
  INITIALIZING = 0,
  TOKEN_AVAILABLE = 1,
  CONNECTING = 2,
  AUTHENTICATING = 3,
  IN_PROGRESS = 4,
  DONE = 5
}

/** Swift `AuthState(rawValue:)` - null for a code this client does not know. */
export function authStateFromRaw(raw: number): AuthState | null {
  if (raw === 0) {
    return AuthState.INITIALIZING;
  }
  if (raw === 1) {
    return AuthState.TOKEN_AVAILABLE;
  }
  if (raw === 2) {
    return AuthState.CONNECTING;
  }
  if (raw === 3) {
    return AuthState.AUTHENTICATING;
  }
  if (raw === 4) {
    return AuthState.IN_PROGRESS;
  }
  if (raw === 5) {
    return AuthState.DONE;
  }
  return null;
}

/** Swift `struct AuthResult` - one tick of a device-linking operation. */
export class AuthResult {
  readonly accountId: string;
  readonly operationId: number;
  readonly state: AuthState;
  readonly details: Map<string, string>;

  constructor(accountId: string, operationId: number, state: AuthState,
              details: Map<string, string>) {
    this.accountId = accountId;
    this.operationId = operationId;
    this.state = state;
    this.details = details;
  }
}

/**
 * Swift `enum AccountCreationError: Error`
 * (Ring/Ring/Features/Walkthrough/Models/CreateAccountVM.swift:144). Carried as the `message`
 * of a rejected promise so a screen can branch on it; the localized title/message the Swift
 * `LocalizedError` extension produced belong to the screen, not here.
 */
export enum AccountCreationError {
  GENERIC = 'AccountCreationError.generic',
  NETWORK = 'AccountCreationError.network',
  UNKNOWN = 'AccountCreationError.unknown',
  LINK_ERROR = 'AccountCreationError.linkError',
  WRONG_CREDENTIALS = 'AccountCreationError.wrongCredentials'
}

/** Swift `struct AccountCreationResult` - nested in AccountsService's creation extension. */
export class AccountCreationResult {
  accountId: string;
  /** Null while the account is still being created; a raw AccountState when it failed. */
  errorCode: string | null;

  constructor(accountId: string, errorCode: string | null = null) {
    this.accountId = accountId;
    this.errorCode = errorCode;
  }
}

/**
 * Swift `enum Directories` (Ring/Ring/Services/DataTransferService.swift:35) - only the two
 * folders `removeAccountById` deletes. DataTransferService owns the enum itself.
 */
const DIRECTORY_DOWNLOADS: string = 'downloads';
const DIRECTORY_RECORDED: string = 'recorded';

/** The string resource behind Swift `L10n.AccountPage.contactMeOnJamiContant(_:)`. */
const CONTACT_ME_RESOURCE: string = 'account_page_contact_me_on_jami_contant';
/** Upper bound on waiting for the username chosen at creation to be registered. */
const NAME_REGISTRATION_TIMEOUT_MS: number = 15000;
/** Upper bound on waiting for a new account's first creation status (JAMS sign-in included). */
const CREATION_STATUS_TIMEOUT_MS: number = 60000;

export class AccountsService {
  // MARK: - Private members

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /** Swift `let boothModeEnabled = "BOOTH_MODE_ENABLED"`. */
  readonly boothModeEnabled: string = 'BOOTH_MODE_ENABLED';

  /**
   * Swift `private let accountAdapter: AccountAdapter`, injected by the constructor. The
   * adapter is the C++ daemon bridge and has no source on disk (see the GAP note at the top),
   * so the field resolves to the honest daemon surface instead. Read through the registry on
   * every use, never cached in the constructor - the registry<->service cycle is only safe
   * while nothing executes during module evaluation.
   */
  private get accountAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /** Swift `private(set) var accountList: [AccountModel]`. */
  private accountListValue: AccountModel[] = [];

  get accountList(): AccountModel[] {
    return this.accountListValue;
  }

  private readonly disposeBag: DisposeBag = new DisposeBag();

  /** Swift `private let responseStream = PublishSubject<ServiceEvent>()`. */
  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /**
   * Swift `let dbManager: DBManager`, a constructor argument. The registry constructor takes
   * no arguments and does not vend DBManager, so it arrives through `setDbManager` at startup.
   */
  private dbManager: DBManager | null = null;

  /** Swift `let needMigrateCurrentAccount = PublishSubject<String>()`. */
  readonly needMigrateCurrentAccount: PublishSubject<string> = new PublishSubject<string>();

  readonly currentAccountChanged: PublishSubject<AccountModel | null> =
    new PublishSubject<AccountModel | null>();
  readonly currentWillChange: PublishSubject<AccountModel | null> =
    new PublishSubject<AccountModel | null>();
  readonly authStateSubject: PublishSubject<AuthResult> = new PublishSubject<AuthResult>();

  /**
   * Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`.
   * A PublishSubject is already multicast here, so the shared stream IS the response stream;
   * external observers subscribe to this one, the service publishes to `responseStream`.
   */
  readonly sharedResponseStream: PublishSubject<ServiceEvent>;

  /**
   * Swift read this from `UserDefaults.standard.bool(forKey: boothModeEnabled)`. This module's
   * contract declares no settings key, and the only writer (`setBoothMode`) is gated behind
   * `passwordIsValid`, which is daemon-backed - so the flag can never become true while the
   * daemon is absent and persisting it would store a value nothing can set.
   * ponytail: in-memory; move to PreferenceManager (svc_preferences) when booth mode can be set.
   */
  private boothModeValue: boolean = false;

  /** Injected by the ability: needed for `accountInfoToShare`'s localized title. */
  private appResources: resourceManager.ResourceManager | null = null;

  /** Injected by the ability: `context.filesDir`, for `removeAccountById`'s folder cleanup. */
  private filesDir: string = '';

  constructor() {
    this.sharedResponseStream = this.responseStream;
  }

  /** Call once from the ability's `onCreate`: `setDbManager(<the DBManager instance>)`. */
  setDbManager(manager: DBManager): void {
    this.dbManager = manager;
  }

  /** Call once from the ability's `onCreate`: `setResources(this.context.resourceManager)`. */
  setResources(manager: resourceManager.ResourceManager): void {
    this.appResources = manager;
  }

  /** Call once from the ability's `onCreate`: `setFilesDir(this.context.filesDir)`. */
  setFilesDir(path: string): void {
    this.filesDir = path;
  }

  // MARK: - Public members

  /** Swift `var accounts: [AccountModel]`. */
  get accounts(): AccountModel[] {
    return this.accountListValue;
  }

  set accounts(newValue: AccountModel[]) {
    this.accountListValue = newValue;
  }

  /**
   * Swift `var currentAccount: AccountModel?`. The getter is simply the first account; the
   * setter moves the account to the head of the list, which is what makes it current.
   */
  get currentAccount(): AccountModel | null {
    return this.accountListValue.length > 0 ? this.accountListValue[0] : null;
  }

  set currentAccount(newValue: AccountModel | null) {
    const existingCurrent: AccountModel | null = this.currentAccount;
    const sameAccount: boolean = existingCurrent !== null && newValue !== null &&
      existingCurrent.equals(newValue);
    if (!sameAccount) {
      this.currentWillChange.onNext(existingCurrent);
    }
    if (newValue === null) {
      return;
    }
    const newAccount: AccountModel = newValue;
    let listed: AccountModel | null = null;
    let index: number = -1;
    for (let i: number = 0; i < this.accountListValue.length; i++) {
      if (this.accountListValue[i].equals(newAccount)) {
        listed = this.accountListValue[i];
        index = i;
        break;
      }
    }
    if (listed !== null) {
      if (index !== 0) {
        this.accountListValue.splice(index, 1);
        this.accountListValue.unshift(listed);
      }
      this.currentAccountChanged.onNext(listed);
    } else {
      this.accountListValue.push(newAccount);
      // Verbatim from Swift: the local `currentAccount` shadows the property here and is nil
      // in this branch, so the Swift setter publishes nil. Kept as-is rather than "corrected",
      // because the branch only runs for an account the daemon never listed.
      this.currentAccountChanged.onNext(null);
    }
  }

  /**
   * Swift `var accountInfoToShare: [String]?` - the "contact me on Jami" line the account
   * screen shares. The Swift fallback that read a cached registered name out of
   * `UserDefaults[registeredNamesKey]` is NameService's store (svc_name) and this module's
   * contract declares no settings key, so it is not read here; `registeredName` and `jamiId`
   * cover the same value for a loaded account.
   */
  get accountInfoToShare(): string[] | null {
    const account: AccountModel | null = this.currentAccount;
    if (account === null) {
      return null;
    }
    const info: string[] = [];
    let nameToContact: string = '';
    if (account.type === AccountType.SIP) {
      const accountDetails: AccountConfigModel | null = account.details;
      if (accountDetails === null || account.credentialDetails.length === 0) {
        return null;
      }
      if (this.helperFor(account).isAccountRing()) {
        return null;
      }
      const credentials: AccountCredentialsModel = account.credentialDetails[0];
      const username: string = credentials.username;
      const server: string = accountDetails.get(new ConfigKeyModel(ConfigKey.ACCOUNT_HOSTNAME));
      if (username.length === 0 || server.length === 0) {
        return null;
      }
      nameToContact = username + '@' + server;
    }
    if (account.registeredName.length > 0) {
      nameToContact = account.registeredName;
    }
    if (nameToContact.length === 0) {
      nameToContact = account.jamiId;
    }
    info.push(this.contactMeTitle(nameToContact));
    return info;
  }

  // MARK: - Account list

  /**
   * Swift `private func loadAccountsFromDaemon()`. The daemon owns the account list, so with
   * it absent the list comes back empty and the selection restore has nothing to restore.
   */
  private loadAccountsFromDaemon(): void {
    const selectedAccount: AccountModel | null = this.currentAccount;
    this.accountListValue = [];
    const accountIds: string[] | null = this.getAccountsId();
    if (accountIds !== null) {
      for (const accountId of accountIds) {
        this.accountListValue.push(new AccountModel(accountId));
      }
    }
    this.reloadAccounts();
    if (selectedAccount !== null) {
      for (let i: number = 0; i < this.accountListValue.length; i++) {
        if (this.accountListValue[i].equals(selectedAccount)) {
          const account: AccountModel = this.accountListValue[i];
          this.accountListValue.splice(i, 1);
          this.accountListValue.unshift(account);
          break;
        }
      }
    }
  }

  /** Swift `func getAccountsId() -> [String]?` - `accountAdapter.getAccountList()`. GAP. */
  getAccountsId(): string[] | null {
    return jami.getAccountList();
  }

  /** Swift `func addDevice(accountId:token:) -> UInt32` - `accountAdapter.addDevice`. GAP. */
  addDevice(accountId: string, token: string): number {
    return jami.addDevice(accountId, token);
  }

  /**
   * Swift `func initialAccountsLoading() -> Completable`. Completes either way: this runs at
   * app bootstrap, and rejecting would take the launch down instead of leaving the app running
   * with the daemon-backed screens showing their notice.
   */
  async initialAccountsLoading(): Promise<void> {
    this.loadAccountsFromDaemon();
    // Swift AppDelegate `prepareAccounts()` on this completion: no account yet = first launch.
    if (!this.hasAccounts()) {
      PreferenceManager.registerFirstLaunchDefaults();
    }
  }

  /** Swift `func hasAccounts() -> Bool`. */
  hasAccounts(): boolean {
    return this.accountListValue.length > 0;
  }

  /** Swift `private func reloadAccounts()`. */
  private reloadAccounts(): void {
    for (const account of this.accountListValue) {
      this.updateAccountDetails(account);
    }
  }

  /** Swift `func updateCurrentAccount(account:)`. */
  updateCurrentAccount(account: AccountModel): void {
    const current: AccountModel | null = this.currentAccount;
    if (current === null || !current.equals(account)) {
      this.currentAccount = account;
    }
  }

  /** Swift `func getAccount(fromAccountId id:) -> AccountModel?`. */
  getAccount(id: string): AccountModel | null {
    for (const account of this.accountListValue) {
      if (id === account.id) {
        return account;
      }
    }
    return null;
  }

  /** Swift `func setAccountList(_:)`. */
  setAccountList(accounts: AccountModel[]): void {
    this.accountListValue = accounts;
  }

  /** Swift `func hasValidAccount() -> Bool`. Verbatim, first-match-wins semantics included. */
  hasValidAccount(): boolean {
    for (const account of this.accountListValue) {
      if (account.status !== AccountState.ERROR_NEED_MIGRATION) {
        return true;
      }
    }
    return false;
  }

  /** Swift `func needAccountMigration(accountId:) -> Bool`. */
  needAccountMigration(accountId: string): boolean {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return false;
    }
    return account.status === AccountState.ERROR_NEED_MIGRATION;
  }

  // MARK: - Daemon detail reads and writes

  /**
   * Swift `func getAccountDetails(fromAccountId id:) -> AccountConfigModel`. The daemon owns
   * these details, so an empty config model comes back. GAP.
   */
  getAccountDetails(id: string): AccountConfigModel {
    return AccountConfigModel.withDetails(toMap(jami.getAccountDetails(id)));
  }

  /**
   * Swift `func setAccountDetails(forAccountId:withDetails:)`. GAP. The daemon write
   * re-registers a SIP account and resolves its host, up to a second per failed lookup on the
   * phone, so the binding runs it on its own worker, in call order (T-1625). Callers update the
   * local detail map first, so nothing waits; the promise settles once the daemon has the write,
   * for a caller that must read it back.
   */
  setAccountDetails(id: string, newDetails: AccountConfigModel): Promise<void> {
    const details: Map<string, string> = newDetails.toDetails();
    const keys: string[] = [];
    details.forEach((value: string, key: string): void => {
      keys.push(key);
    });
    return this.trackQueuedWrite(id, keys, jami.setAccountDetails(id, toRecord(details)), 'setAccountDetails');
  }

  /**
   * Counts `keys` of account `id` in `queuedDetailWrites` until `write`, already queued on the
   * binding's worker, settles, and logs a rejected write (T-1625 review, T-1627).
   */
  private trackQueuedWrite(id: string, keys: string[], write: Promise<void>, label: string): Promise<void> {
    keys.forEach((key: string): void => {
      this.queuedDetailWrites.set(id + '/' + key, (this.queuedDetailWrites.get(id + '/' + key) ?? 0) + 1);
    });
    return write
      .catch((error: BusinessError): void => this.log(label + ': ' + describeError(error)))
      .then((): void => keys.forEach((key: string): void => {
        const left: number = (this.queuedDetailWrites.get(id + '/' + key) ?? 1) - 1;
        if (left > 0) {
          this.queuedDetailWrites.set(id + '/' + key, left);
        } else {
          this.queuedDetailWrites.delete(id + '/' + key);
        }
      }));
  }

  /**
   * `accountId/detailKey` -> daemon writes of that key still queued on the binding's worker
   * (T-1625 review). Each write's AccountDetailsChanged echo lands after it has run, so in a burst
   * of taps the echo of an older write carries a value the user has since changed again.
   */
  private readonly queuedDetailWrites: Map<string, number> = new Map<string, number>();

  /**
   * Swift `func setAccountCrdentials(forAccountId:crdentials:)` (Swift's own spelling). GAP.
   * Re-registers like `setAccountDetails`, so it goes through the same worker queue (T-1625).
   */
  setAccountCrdentials(id: string, crdentials: Array<Map<string, string>>): Promise<void> {
    return jami.setCredentials(id, crdentials.map((entry: Map<string, string>) => toRecord(entry)))
      .catch((error: BusinessError): void => this.log('setAccountCrdentials: ' + describeError(error)));
  }

  /** Swift `func getVolatileAccountDetails(fromAccountId id:) -> AccountConfigModel`. GAP. */
  getVolatileAccountDetails(id: string): AccountConfigModel {
    return AccountConfigModel.withDetails(toMap(jami.getVolatileAccountDetails(id)));
  }

  /**
   * Swift `func getAccountCredentials(fromAccountId id:) throws -> [AccountCredentialsModel]`:
   * the daemon's credential maps (SIP only; a Jami account has none), each built with
   * `AccountCredentialsModel(withRawaData:)`, which throws on a map missing one of its keys.
   */
  getAccountCredentials(id: string): AccountCredentialsModel[] {
    return jami.getCredentials(id).map((raw: Record<string, string>): AccountCredentialsModel =>
      AccountCredentialsModel.fromRawData(toMap(raw)));
  }

  /** Swift `func getKnownRingDevices(fromAccountId id:) -> [DeviceModel]`. */
  getKnownRingDevices(id: string): DeviceModel[] {
    const devices: DeviceModel[] = [];
    const knownRingDevices: Map<string, string> | null = this.fetchKnownRingDevices(id);
    if (knownRingDevices === null) {
      return devices;
    }
    const accountDetails: AccountConfigModel = this.getVolatileAccountDetails(id);
    const currentDeviceId: string = accountDetails.get(new ConfigKeyModel(ConfigKey.ACCOUNT_DEVICE_ID));
    knownRingDevices.forEach((deviceName: string, deviceId: string): void => {
      devices.push(new DeviceModel(deviceId, deviceName, deviceId === currentDeviceId));
    });
    return devices;
  }

  /**
   * `accountAdapter.getKnownRingDevices(_:)` - the daemon half of `getKnownRingDevices`. Every
   * `updateAccountDetails` rebuilds `account.devices` from it, so an empty answer here would
   * wipe the list `knownDevicesChanged` filled.
   */
  private fetchKnownRingDevices(id: string): Map<string, string> | null {
    return toMap(jami.getKnownRingDevices(id));
  }

  /** Swift `func revokeDevice(for:withPassword:deviceId:)`. GAP. */
  revokeDevice(account: string, password: string, deviceId: string): void {
    jami.revokeDevice(account, deviceId, 'password', password);
  }

  /** Swift `func updateProfile(accountId:displayName:avatar:fileType:) async` — not a gap. */
  async updateProfile(accountId: string, displayName: string, avatar: string,
                      fileType: string): Promise<void> {
    // libjami writes the account's vCard synchronously, emits ProfileReceived for the account,
    // and sends the vCard to the peers. On HarmonyOS its profile.vcf link fails, so that send
    // finds no file; the copy below lets the next connection to each peer device send it (T-1599).
    jami.updateProfile(accountId, displayName, avatar, fileType, 1);
    new ProfileStore().restoreAccountProfileFile(accountId);
  }

  /**
   * Swift `private func getInitialAccountDetails(accountType:) throws -> [String: String]`.
   * The template itself is `accountAdapter.getAccountTemplate`, so the three overrides below
   * are kept but never reached. GAP.
   */
  private getInitialAccountDetails(accountType: string): Map<string, string> {
    const accountDetails: Map<string, string> | null = this.fetchAccountTemplate(accountType);
    if (accountDetails === null) {
      throw this.accountAdapter.reportUnavailable('account.template');
    }
    accountDetails.set(String(ConfigKey.ACCOUNT_DTMF_TYPE), 'oversip');
    accountDetails.set(String(ConfigKey.ACCOUNT_TYPE), accountType);
    accountDetails.set(String(ConfigKey.RINGTONE_ENABLED), 'false');
    return accountDetails;
  }

  /** `accountAdapter.getAccountTemplate(_:)`. GAP. */
  private fetchAccountTemplate(accountType: string): Map<string, string> | null {
    return toMap(jami.getAccountTemplate(accountType));
  }

  /** Swift `private func getJamiInitialAccountDetails() throws -> [String: String]`. */
  private getJamiInitialAccountDetails(): Map<string, string> {
    const defaultDetails: Map<string, string> = this.getInitialAccountDetails(String(AccountType.RING));
    defaultDetails.set(String(ConfigKey.DHT_PUBLIC_IN), 'false');
    return defaultDetails;
  }

  // MARK: - Account removal

  /** Swift `func removeAccount(_ row: Int)`. GAP on the daemon half. */
  removeAccount(row: number): void {
    if (row < this.accountListValue.length) {
      jami.removeAccount(this.accountListValue[row].id);
    }
  }

  /**
   * Swift `func removeAccount(id: String)` - the second `removeAccount` overload. ArkTS has no
   * overloading, so the id form is renamed. The local halves (database + downloads/recordings
   * folders) do run; the daemon half reports unavailable.
   */
  removeAccountById(id: string): void {
    const account: AccountModel | null = this.getAccount(id);
    if (account === null) {
      return;
    }
    const shouldRemoveFolder: boolean = this.helperFor(account).isAccountSip();
    const manager: DBManager | null = this.dbManager;
    if (manager !== null) {
      manager.removeDBForAccount(id, shouldRemoveFolder);
    } else {
      this.log('removeAccountById: no DBManager injected; database left in place');
    }
    jami.removeAccount(id);
    if (this.getAccount(id) === null) {
      this.removeAccountFolder(DIRECTORY_DOWNLOADS, id);
      this.removeAccountFolder(DIRECTORY_RECORDED, id);
    }
  }

  /**
   * Swift `AccountSummaryVM.removeAccount(statePublisher:)`, shared by ManageAccountView and
   * ManageSipAccountView: `removeAccount(id:)`, then `determinePostRemovalState()` — the first
   * remaining account that needs no migration becomes current and the selected one — and
   * SettingsCoordinator acting on the state: `.accountRemoved` dismisses the whole settings
   * stack onto the smart list, `.needToOnboard` and `.needAccountMigration` leave for the
   * walkthrough / migration (T-1613, T-1616).
   */
  removeAccountAndLeaveSettings(id: string): void {
    this.removeAccountById(id);
    const remaining: AccountModel[] = this.accountListValue.filter(
      (candidate: AccountModel): boolean => candidate.id !== id);
    if (remaining.length === 0) {
      PreferenceManager.setSelectedAccountId('');
      AccountsService.replaceStack(WALKTHROUGH_PAGE, undefined);
      return;
    }
    const next: AccountModel | undefined = remaining.find(
      (candidate: AccountModel): boolean => !this.needAccountMigration(candidate.id));
    if (next === undefined) {
      PreferenceManager.setSelectedAccountId('');
      const params: MigrationRouteParams = { accountId: remaining[0].id, replacesStack: true };
      AccountsService.replaceStack(MIGRATION_PAGE, params);
      return;
    }
    // Publishes currentAccountChanged unless the daemon's accountsChanged already did: the home
    // header and its conversations follow, and the removed account is no longer shown.
    this.updateCurrentAccount(next);
    PreferenceManager.setSelectedAccountId(next.id);
    if (router.getStateByUrl(SMART_LIST_PAGE).length === 0) {
      // A cold deep link into settings has no smart list beneath it to dismiss onto.
      AccountsService.replaceStack(SMART_LIST_PAGE, undefined);
      return;
    }
    router.back({ url: SMART_LIST_PAGE });
  }

  /** The stack swap SettingsCoordinator's parent performs for onboarding / migration. */
  private static replaceStack(url: string, params: Object | undefined): void {
    router.clear();
    router.replaceUrl({ url: url, params: params }).catch((error: BusinessError): void => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'replaceUrl %{public}s failed: %{public}s', url,
        describeError(error));
    });
  }

  /**
   * Swift `try? FileManager.default.removeItem(atPath:)` on the account's downloads and
   * recordings folders. The iOS app-group documents directory becomes the ability's filesDir.
   */
  private removeAccountFolder(directory: string, accountId: string): void {
    if (this.filesDir.length === 0) {
      this.log('removeAccountFolder: no filesDir injected; ' + directory + ' left in place');
      return;
    }
    const path: string = this.filesDir + '/' + directory + '/' + accountId;
    try {
      fileIo.rmdirSync(path);
    } catch (error) {
      // Swift used `try?` here - a missing folder is the normal case, not a failure.
      const err: BusinessError = error as BusinessError;
      this.log('removeAccountFolder ' + path + ': ' + describeError(err));
    }
  }

  /**
   * Swift `func removeAccountAndWaitForCompletion(id:) -> Observable<Bool>`. It waited for the
   * daemon's `accountsChanged` signal before reporting success; that signal can never arrive,
   * so the promise rejects with the gap rather than waiting forever on it. GAP.
   */
  async removeAccountAndWaitForCompletion(id: string): Promise<boolean> {
    const initialAccountCount: number = this.accountListValue.length;
    // Swift combined the removal with the next `accountsChanged` signal.
    return new Promise<boolean>((resolve: (removed: boolean) => void): void => {
      const unsubscribe: () => void = this.responseStream.subscribe((event: ServiceEvent): void => {
        if (event.eventType === ServiceEventType.ACCOUNTS_CHANGED) {
          unsubscribe();
          resolve(this.accountListValue.length < initialAccountCount);
        }
      });
      jami.removeAccount(id);
    });
  }

  /** Swift `func exportToFileWithPassword(accountId:destinationPath:password:) -> Bool`. GAP. */
  exportToFileWithPassword(accountId: string, destinationPath: string, password: string): boolean {
    return jami.exportToFile(accountId, destinationPath, password.length > 0 ? 'password' : '', password);
  }

  /**
   * Swift `func migrateAccount(account:password:) -> Observable<Bool>`. Both halves are
   * daemon-backed - writing the archive password is `setAccountDetails`, and the result is the
   * daemon's `migrationEnded` signal - so this reports the gap instead of timing out after the
   * Swift 30 seconds. `migrationEnded` below still publishes the event if one ever arrives. GAP.
   */
  async migrateAccount(accountId: string, password: string): Promise<boolean> {
    throw this.accountAdapter.reportUnavailable('account.migrate');
  }

  // MARK: - AccountAdapterDelegate (daemon -> client callbacks)

  /** Swift `func accountDetailsChanged(accountId:details:)`. */
  accountDetailsChanged(accountId: string, details: Map<string, string>): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    // A key with a write still queued already holds that newer value locally. Applying the stale
    // echo reverted it, and the redundant-write guards then dropped the user's last tap (T-1625).
    const settled: Map<string, string> = new Map<string, string>();
    details.forEach((value: string, key: string): void => {
      if (!this.queuedDetailWrites.has(accountId + '/' + key)) {
        settled.set(key, value);
      }
    });
    account.updateDetails(settled);
  }

  /** Swift `func accountVoaltileDetailsChanged(accountId:details:)` (Swift's own spelling). */
  accountVoaltileDetailsChanged(accountId: string, details: Map<string, string>): void {
    // T-1442: libjami emits this right after every RegistrationStateChanged (Account::
    // setRegistrationState, one lambda), carrying that change's code and reason; only a SIP
    // account reports Account.registrationCode. Logged before the lookup, so a change that lands
    // before the account list loads still shows. active=false: released by setAccountsActive(false).
    const code: string | undefined = details.get(String(ConfigKey.ACCOUNT_REGISTRATION_STATE_CODE));
    if (code !== undefined) {
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'SIP registration %{public}s: state=%{public}s code=%{public}s detail=%{public}s active=%{public}s',
        accountId, details.get(String(ConfigKey.ACCOUNT_REGISTRATION_STATUS)) ?? '', code,
        details.get(String(ConfigKey.ACCOUNT_REGISTRATION_STATE_DESC)) ?? '',
        details.get(String(ConfigKey.ACCOUNT_ACTIVE)) ?? '');
    }
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    account.updateVolatileDetails(details);
  }

  /** Swift `func accountsChanged()` - the background hop is a direct call here. */
  accountsChanged(): void {
    this.handleAccountsChanged();
  }

  /** Swift `func handleAccountsChanged()`. */
  handleAccountsChanged(): void {
    this.log('Accounts changed.');
    const currentAccounts: string[] = this.accountListValue.map((account: AccountModel): string => {
      return account.id;
    });
    const newAccounts: string[] | null = this.getAccountsId();
    if (newAccounts === null) {
      this.updateAccountList(currentAccounts, []);
      this.notifyAccountsChanged();
      return;
    }
    const removedAccounts: string[] = currentAccounts.filter((id: string): boolean => {
      return newAccounts.indexOf(id) < 0;
    });
    const addedAccounts: string[] = newAccounts.filter((id: string): boolean => {
      return currentAccounts.indexOf(id) < 0;
    });
    const previous: AccountModel | null = this.currentAccount;
    this.updateAccountList(removedAccounts, addedAccounts);
    // The current account is the list's head, so removing it silently made the next account
    // current; Swift left that to the removing view model. Announce it, or the smart list shows
    // the new account over the removed one's conversations until a restart (T-1613).
    const current: AccountModel | null = this.currentAccount;
    if (previous !== null && current !== null && removedAccounts.indexOf(previous.id) >= 0) {
      this.currentAccountChanged.onNext(current);
    }
    this.notifyAccountsChanged();
  }

  /**
   * Swift `private func updateAccountList(removedAccounts:addedAccounts:)`. Swift took
   * `accountListLock` (an `NSLock`) around this body; ArkTS runs the service on one thread,
   * so there is no second writer to lock out and the lock is not carried over.
   */
  private updateAccountList(removedAccounts: string[], addedAccounts: string[]): void {
    const newAccounts: AccountModel[] = this.createAndFetchNewAccounts(addedAccounts);
    this.accountListValue = this.accountListValue.filter((account: AccountModel): boolean => {
      return removedAccounts.indexOf(account.id) < 0;
    });
    for (const newAccount of newAccounts) {
      let known: boolean = false;
      for (const account of this.accountListValue) {
        if (account.id === newAccount.id) {
          known = true;
          break;
        }
      }
      if (!known) {
        this.accountListValue.push(newAccount);
      }
    }
  }

  /** Swift `private func createAndFetchNewAccounts(from:) -> [AccountModel]`. */
  private createAndFetchNewAccounts(addedAccounts: string[]): AccountModel[] {
    return addedAccounts.map((accountId: string): AccountModel => {
      const newAccount: AccountModel = new AccountModel(accountId);
      this.updateAccountDetails(newAccount);
      return newAccount;
    });
  }

  /** Swift `private func notifyAccountsChanged()`. */
  private notifyAccountsChanged(): void {
    this.responseStream.onNext(new ServiceEvent(ServiceEventType.ACCOUNTS_CHANGED));
  }

  /** Swift `private func updateAccountDetails(account:)`. */
  private updateAccountDetails(account: AccountModel): void {
    // Account load: restore a profile.vcf libjami failed to link (see updateProfile, T-1599).
    new ProfileStore().restoreAccountProfileFile(account.id);
    account.details = this.getAccountDetails(account.id);
    account.volatileDetails = this.getVolatileAccountDetails(account.id);
    account.devices = this.getKnownRingDevices(account.id);
    try {
      const credentialDetails: AccountCredentialsModel[] = this.getAccountCredentials(account.id);
      account.credentialDetails = [];
      for (const credentials of credentialDetails) {
        account.credentialDetails.push(credentials);
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.log('updateAccountDetails: ' + describeError(err));
    }
  }

  /**
   * Swift `private func buildAccountFromDaemon(accountId id:) throws -> AccountModel`, in the
   * "private daemon wrappers" extension. Rethrows whatever the credential read throws.
   */
  private buildAccountFromDaemon(id: string): AccountModel {
    const accountModel: AccountModel = new AccountModel(id);
    accountModel.details = this.getAccountDetails(id);
    accountModel.volatileDetails = this.getVolatileAccountDetails(id);
    accountModel.devices = this.getKnownRingDevices(id);
    const credentialDetails: AccountCredentialsModel[] = this.getAccountCredentials(id);
    accountModel.credentialDetails = [];
    for (const credentials of credentialDetails) {
      accountModel.credentialDetails.push(credentials);
    }
    return accountModel;
  }

  /** Swift `func migrationEnded(for:status:)`. */
  migrationEnded(account: string, status: string): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.MIGRATION_ENDED);
    event.addEventInput(ServiceEventInput.STATE, status);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, account);
    this.responseStream.onNext(event);
  }

  /**
   * Swift `func registrationStateChanged(for:state:)` - also the place a freshly generated
   * account is detected (INITIALIZING -> anything else) and where the current account's need
   * for migration is raised.
   */
  registrationStateChanged(accountId: string, state: string): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account !== null) {
      const newState: AccountState | null = accountStateFromRaw(state);
      if (newState !== null) {
        if (account.status === AccountState.INITIALIZING && newState !== AccountState.INITIALIZING) {
          this.updateAccountDetails(account);
          if (!accountStateIsError(newState)) {
            const addedEvent: ServiceEvent = new ServiceEvent(ServiceEventType.ACCOUNT_ADDED);
            addedEvent.addEventInput(ServiceEventInput.ACCOUNT_ID, account.id);
            this.responseStream.onNext(addedEvent);
          }
        }
      }
    }
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.REGISTRATION_STATE_CHANGED);
    event.addEventInput(ServiceEventInput.REGISTRATION_STATE, state);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);

    const current: AccountModel | null = this.currentAccount;
    const newState: AccountState | null = accountStateFromRaw(state);
    if (current !== null && newState === AccountState.ERROR_NEED_MIGRATION &&
      accountId === current.id) {
      this.needMigrateCurrentAccount.onNext(current.id);
    }
  }

  /** Swift `private func handleAuthStateChange(accountId:opId:state:details:)`. */
  private handleAuthStateChange(accountId: string, opId: number, state: number,
                                details: Map<string, string>): void {
    const authState: AuthState | null = authStateFromRaw(state);
    if (authState === null) {
      return;
    }
    this.authStateSubject.onNext(new AuthResult(accountId, opId, authState, details));
  }

  /** Swift `func addDeviceStateChanged(accountId:opId:state:details:)`. */
  addDeviceStateChanged(accountId: string, opId: number, state: number,
                        details: Map<string, string>): void {
    this.handleAuthStateChange(accountId, opId, state, details);
  }

  /** Swift `func deviceAuthStateChanged(accountId:state:details:)`. */
  deviceAuthStateChanged(accountId: string, state: number, details: Map<string, string>): void {
    this.handleAuthStateChange(accountId, 0, state, details);
  }

  // MARK: - Push notifications

  /**
   * Swift `func setPushNotificationToken(token:)`. The Swift comment block explaining why the
   * account details are NOT pushed back to the daemon here is behaviour, not decoration: doing
   * so triggers a full unregister/reload/register on every launch and loses in-flight DHT
   * operations. Keep it that way if this is ever wired to a real daemon. GAP.
   */
  setPushNotificationToken(token: string): void {
    if (token.length === 0) {
      this.accountAdapter.reportUnavailable('account.setPushToken');
      return;
    }
    // Swift `pushNotificationConfig` - the dictionary handed to
    // `accountAdapter.setPushNotificationConfig(_:)`.
    const pushConfig: Map<string, string> = new Map<string, string>();
    pushConfig.set('token', token);
    pushConfig.set('platform', 'harmonyos');
    this.log('push config built with ' + String(pushConfig.size) + ' keys');
    this.accountAdapter.reportUnavailable('account.setPushConfig');
  }

  /** Swift `func setPushNotificationTopic(topic:)`. GAP. */
  setPushNotificationTopic(topic: string): void {
    this.accountAdapter.reportUnavailable('account.setPushTopic');
  }

  /**
   * Swift `func pushNotificationReceived(data: [String: Any])` - it stringified every value
   * before forwarding, so the parameter is `Map<string, string>` here rather than `any`. GAP.
   */
  pushNotificationReceived(data: Map<string, string>): void {
    const notificationData: Map<string, string> = new Map<string, string>();
    data.forEach((value: string, key: string): void => {
      notificationData.set(key, value);
    });
    this.log('pushNotificationReceived: ' + String(notificationData.size) + ' keys');
    this.accountAdapter.reportUnavailable('account.pushNotification');
  }

  /** Swift `func setAccountsActive(active:)`. GAP. */
  setAccountsActive(active: boolean): void {
    for (const accountId of jami.getAccountList()) {
      this.setAccountActive(active, accountId);
    }
  }

  /**
   * Swift `func setAccountActive(active:accountId:)`. GAP. It (un)registers the account, so it
   * runs on the binding's worker, in order with the account writes (T-1627).
   */
  setAccountActive(active: boolean, accountId: string): void {
    this.trackQueuedWrite(accountId, [], jami.setAccountActive(accountId, active), 'setAccountActive');
  }

  /** Swift `func provideAccountAuthentication(accountId:password:)`. GAP. */
  provideAccountAuthentication(accountId: string, password: string): void {
    jami.provideAccountAuthentication(accountId, password, password.length > 0 ? 'password' : '');
  }

  /**
   * Swift `func createTemporaryAccount() async throws -> String`. The details map is built for
   * real; `accountAdapter.addAccount` is the daemon. The Swift `TestEnvironment.nameServerURI`
   * override is a UI-test hook with no HarmonyOS equivalent and is not carried over. GAP.
   */
  async createTemporaryAccount(): Promise<string> {
    const details: Map<string, string> = this.getJamiInitialAccountDetails();
    details.set(String(ConfigKey.PROXY_ENABLED), 'true');
    details.set(String(ConfigKey.ARCHIVE_URL), 'jami-auth');
    const accountId: string = jami.addAccount(toRecord(details));
    if (accountId.length === 0) {
      throw new Error('addAccount failed');
    }
    return accountId;
  }

  // MARK: - Configuration settings

  /** Swift `func changePassword(forAccount:password:newPassword:) -> Bool`. GAP. */
  changePassword(accountId: string, password: string, newPassword: string): boolean {
    return jami.changeAccountPassword(accountId, password, newPassword);
  }

  /** Swift `func setDeviceName(accountId:deviceName:)`. */
  setDeviceName(accountId: string, deviceName: string): void {
    this.setAccountProperty(new ConfigKeyModel(ConfigKey.ACCOUNT_DEVICE_NAME), deviceName, accountId);
  }

  /** Swift `func hasAccountWithProxyEnabled() -> Bool`. */
  hasAccountWithProxyEnabled(): boolean {
    for (const account of this.accounts) {
      const accountDetails: AccountConfigModel = this.getAccountDetails(account.id);
      if (accountDetails.get(new ConfigKeyModel(ConfigKey.PROXY_ENABLED)) === 'true') {
        return true;
      }
    }
    return false;
  }

  /** Swift `func boothMode() -> Bool` - see the `boothModeValue` note. */
  boothMode(): boolean {
    return this.boothModeValue;
  }

  /**
   * Swift `func setBoothMode(forAccount:enable:password:) -> Bool`. The password check is
   * `accountAdapter.passwordIsValid`, so the flag can never actually be flipped here. GAP.
   */
  setBoothMode(accountId: string, enable: boolean, password: string): boolean {
    if (this.boothModeValue === enable) {
      return true;
    }
    if (!jami.isPasswordValid(accountId, password)) {
      return false;
    }
    this.boothModeValue = enable;
    return true;
  }

  /** Swift `func enableSRTP(enable:accountId:)`. */
  enableSRTP(enable: boolean, accountId: string): void {
    const newValue: string = enable ? 'sdes' : '';
    this.setAccountProperty(new ConfigKeyModel(ConfigKey.SRTP_KEY_EXCHANGE), newValue, accountId);
  }

  /**
   * Swift `func enableAccount(accountId:enable:)`. The daemon sends no update for the enable
   * status, which is why the local configuration is written here before the daemon call.
   * sendRegister (un)registers the account, so it runs on the binding's worker after any write
   * queued before it, and counts as a queued Account.enable write: the echo of such an earlier
   * write carries the old value (T-1627).
   */
  enableAccount(accountId: string, enable: boolean): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    account.setEnable(enable);
    this.trackQueuedWrite(accountId, [String(ConfigKey.ACCOUNT_ENABLE)], jami.sendRegister(accountId, enable),
      'sendRegister');
  }

  /** Swift `func setStunSettings(accountId:server:)`. */
  setStunSettings(accountId: string, server: string): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    const details: AccountConfigModel | null = account.details;
    if (details === null) {
      return;
    }
    const property: ConfigKeyModel = new ConfigKeyModel(ConfigKey.STUN_SERVER);
    if (details.get(property) === server) {
      return;
    }
    details.set(property, server);
    const changed: Map<string, string> = new Map<string, string>();
    changed.set(String(ConfigKey.STUN_SERVER), server);
    this.setAccountDetails(accountId, AccountConfigModel.withDetails(changed));
  }

  /** Swift `func setTurnSettings(accountId:server:username:password:realm:)`. */
  setTurnSettings(accountId: string, server: string, username: string, password: string,
                  realm: string): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    const details: AccountConfigModel | null = account.details;
    if (details === null) {
      return;
    }
    // Swift iterated a `[ConfigKey: String]` literal; the keys are written out here because
    // ArkTS cannot turn a raw detail-map key back into a ConfigKey without a cast.
    const turnKeys: ConfigKey[] = [
      ConfigKey.TURN_SERVER, ConfigKey.TURN_USERNAME, ConfigKey.TURN_PASSWORD, ConfigKey.TURN_REALM
    ];
    const turnValues: string[] = [server, username, password, realm];

    const detailsToUpdate: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i < turnKeys.length; i++) {
      details.set(new ConfigKeyModel(turnKeys[i]), turnValues[i]);
      detailsToUpdate.set(String(turnKeys[i]), turnValues[i]);
    }
    this.setAccountDetails(accountId, AccountConfigModel.withDetails(detailsToUpdate));
  }

  /** Swift `func switchAccountPropertyTo(state:accountId:property:)`. */
  switchAccountPropertyTo(state: boolean, accountId: string, property: ConfigKeyModel): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    const accountDetails: AccountConfigModel | null = account.details;
    if (accountDetails === null) {
      return;
    }
    if (accountDetails.get(property) === boolToString(state)) {
      return;
    }
    this.setAccountProperty(property, boolToString(state), accountId);
  }

  /**
   * Swift `func setAccountProperty(property:value:accountId:)` - the local detail map is the
   * half that really updates, so the settings rows react even with the daemon absent.
   */
  setAccountProperty(property: ConfigKeyModel, value: string, accountId: string): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    const accountDetails: AccountConfigModel | null = account.details;
    if (accountDetails === null) {
      return;
    }
    if (accountDetails.get(property) === value) {
      return;
    }
    accountDetails.set(property, value);
    account.details = accountDetails;
    const detailsToUpdate: Map<string, string> = new Map<string, string>();
    detailsToUpdate.set(String(property.key), value);
    this.setAccountDetails(accountId, AccountConfigModel.withDetails(detailsToUpdate));
  }

  // MARK: - Devices management

  /** Swift `func knownDevicesChanged(for:devices:)`. */
  knownDevicesChanged(accountId: string, devices: Map<string, string>): void {
    this.log('[account]: ' + accountId + ' - knownDevicesChanged, devices count: ' +
      String(devices.size));
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    this.updateAccountDevices(account, devices);
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.KNOWN_DEVICES_CHANGED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(event);
  }

  /** Swift `private func updateAccountDevices(account:devices:)`. */
  private updateAccountDevices(account: AccountModel, devices: Map<string, string>): void {
    this.removeOldDevices(account.devices, devices);
    const currentDeviceId: string = this.helperFor(account).getCurrentDevice();
    this.addOrUpdateDevices(account.devices, devices, currentDeviceId);
  }

  /**
   * Swift `private func removeOldDevices(currentDevices: inout [DeviceModel], devices:)`.
   * Swift's `inout` is an in-place mutation here: ArkTS arrays are references, so the array is
   * spliced rather than reassigned - reassigning would leave `account.devices` untouched.
   */
  private removeOldDevices(currentDevices: DeviceModel[], devices: Map<string, string>): void {
    for (let i: number = currentDevices.length - 1; i >= 0; i--) {
      if (!devices.has(currentDevices[i].deviceId)) {
        currentDevices.splice(i, 1);
      }
    }
  }

  /** Swift `private func addOrUpdateDevices(currentDevices: inout:devices:currentDeviceId:)`. */
  private addOrUpdateDevices(currentDevices: DeviceModel[], devices: Map<string, string>,
                             currentDeviceId: string): void {
    devices.forEach((deviceName: string, deviceId: string): void => {
      let existingDevice: DeviceModel | null = null;
      for (const device of currentDevices) {
        if (device.deviceId === deviceId) {
          existingDevice = device;
          break;
        }
      }
      if (existingDevice !== null) {
        if (existingDevice.deviceName !== deviceName) {
          existingDevice.deviceName = deviceName;
        }
      } else {
        currentDevices.push(new DeviceModel(deviceId, deviceName, deviceId === currentDeviceId));
      }
    });
  }

  /**
   * Swift `func exportOnRing(withPassword password:) -> Completable` - "link a new device", the
   * daemon's `exportOnRing`. It answered through `exportOnRingEnded` below. GAP.
   */
  async exportOnRing(password: string): Promise<void> {
    throw this.accountAdapter.reportUnavailable('account.exportOnRing');
  }

  /** Swift `func exportOnRingEnded(for:state:pin:)`. */
  exportOnRingEnded(account: string, state: number, pin: string): void {
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.EXPORT_ON_RING_ENDED);
    event.addEventInput(ServiceEventInput.ID, account);
    event.addEventInput(ServiceEventInput.STATE, String(state));
    event.addEventInput(ServiceEventInput.PIN, pin);
    this.responseStream.onNext(event);
  }

  /** Swift `func deviceRevocationEnded(for:state:deviceId:)`. */
  deviceRevocationEnded(accountId: string, state: number, deviceId: string): void {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account === null) {
      return;
    }
    for (let i: number = account.devices.length - 1; i >= 0; i--) {
      if (account.devices[i].deviceId === deviceId) {
        account.devices.splice(i, 1);
      }
    }
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.DEVICE_REVOCATION_ENDED);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    event.addEventInput(ServiceEventInput.STATE, String(state));
    event.addEventInput(ServiceEventInput.DEVICE_ID, deviceId);
    this.responseStream.onNext(event);
  }

  /**
   * Swift `func devicesObservable(account:) -> Observable<[DeviceModel]>` -
   * `Observable.just(account.devices).concat(<every knownDevicesChanged for this account>)`.
   * A BehaviorRelay is exactly that shape: it replays the current list on subscribe and emits
   * the list again on every device change.
   */
  devicesObservable(account: AccountModel): BehaviorRelay<DeviceModel[]> {
    const relay: BehaviorRelay<DeviceModel[]> = new BehaviorRelay<DeviceModel[]>(account.devices);
    const dispose: () => void = this.sharedResponseStream.subscribe((event: ServiceEvent): void => {
      if (event.eventType === ServiceEventType.KNOWN_DEVICES_CHANGED &&
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) === account.id) {
        relay.accept(account.devices);
      }
    });
    this.disposeBag.add(dispose);
    return relay;
  }

  /** Swift `func confirmAddDevice(accountId:operationId:)`. GAP. */
  confirmAddDevice(accountId: string, operationId: number): void {
    jami.confirmAddDevice(accountId, operationId);
  }

  /** Swift `func cancelAddDevice(accountId:operationId:)`. GAP. */
  cancelAddDevice(accountId: string, operationId: number): void {
    jami.cancelAddDevice(accountId, operationId);
  }

  // MARK: - Account creation

  /**
   * Swift `func addJamiAccount(username:password:pin:arhivePath:profileName:)` (Swift's own
   * spelling of `arhivePath`) - creates or links a Jami account. The creation itself is the
   * daemon's `addAccount`, so the returned promise rejects with the gap. GAP.
   */
  async addJamiAccount(username: string | null, password: string, pin: string, arhivePath: string,
                       profileName: string): Promise<string> {
    return this.handleAccountCreation(false,
      this.createJamiAccount(username, password, pin, arhivePath, profileName),
      username === null ? '' : username, password);
  }

  /** Swift `func connectToAccountManager(username:password:serverUri:)` - the JAMS flow. GAP. */
  async connectToAccountManager(username: string, password: string,
                                serverUri: string): Promise<string> {
    return this.handleAccountCreation(true,
      this.createJamsAccount(username, password, serverUri));
  }

  /**
   * Swift `func addSipAccount(userName:password:sipServer:) -> Bool`: add the account, create its
   * database (with its folder), make it current, remember it as selected. The daemon's
   * AccountsChanged signal arrives later on the JS thread, so the list is reloaded here first,
   * or `getAccount` would not find the new id yet. Async because the database is.
   */
  async addSipAccount(userName: string, password: string, sipServer: string): Promise<boolean> {
    try {
      const accountDetails: Map<string, string> =
        this.getInitialAccountDetails(String(AccountType.SIP));
      accountDetails.set(String(ConfigKey.ACCOUNT_USERNAME), userName);
      accountDetails.set(String(ConfigKey.ACCOUNT_HOSTNAME), sipServer);
      accountDetails.set(String(ConfigKey.ACCOUNT_PASSWORD), password);
      const accountId: string = jami.addAccount(toRecord(accountDetails));
      if (accountId.length === 0) {
        return false;
      }
      this.handleAccountsChanged();
      const manager: DBManager | null = this.dbManager;
      if (manager === null || !(await manager.createDatabaseForAccount(accountId, true))) {
        return false;
      }
      const account: AccountModel | null = this.getAccount(accountId);
      if (account === null) {
        return false;
      }
      this.currentAccount = account;
      PreferenceManager.setSelectedAccountId(accountId);
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      this.log('addSipAccount: ' + describeError(err));
      return false;
    }
  }

  /**
   * Swift `private func handleAccountCreation(isJams:createAccount:) -> Observable<String>`.
   * It combined the creation call with the first matching creation-status event, then ran
   * `completeCreation`. The wait is kept in full so it works the moment creation can succeed.
   */
  private async handleAccountCreation(isJams: boolean, createAccount: Promise<string>,
                                      username: string = '', password: string = ''): Promise<string> {
    const accountId: string = await createAccount;
    const creationStatus: AccountCreationResult = await this.firstCreationStatus(accountId);
    if (creationStatus.errorCode === null && username.length > 0) {
      await this.registerCreatedName(accountId, password, username);
    }
    const error: Error | null = await this.completeCreation(accountId, isJams, creationStatus.errorCode);
    if (error !== null) {
      throw error;
    }
    return accountId;
  }

  /**
   * The username chosen in the New account sheet. The daemon only gets to the name server once
   * the account has left INITIALIZING - after the creation status above - so making the account
   * current straight away published it with just its jami id, and the header never re-reads it.
   * Register the name (the daemon refuses a duplicate of its own in-flight request, whose outcome
   * still arrives as NameRegistrationEnded), wait for the outcome, bounded, then re-read the
   * details so the registered name is on the model before the account becomes current.
   */
  private async registerCreatedName(accountId: string, password: string, name: string): Promise<void> {
    await new Promise<void>((resolve: () => void): void => {
      const timer: number = setTimeout(resolve, NAME_REGISTRATION_TIMEOUT_MS);
      ServiceRegistry.shared().nameService.registerNameObservable(accountId, password, name)
        .subscribe((registered: boolean): void => {
          clearTimeout(timer);
          if (!registered) {
            this.log('registerCreatedName: registration of ' + name + ' failed');
          }
          resolve();
        });
    });
    const account: AccountModel | null = this.getAccount(accountId);
    if (account !== null) {
      this.updateAccountDetails(account);
    }
  }

  /**
   * The `take(1)` half of `handleAccountCreation`: the first status for this account id.
   * Bounded: ACCOUNT_ADDED only fires when the model saw the account in INITIALIZING, and a
   * JAMS server that never answers sends nothing, so an unbounded wait left Sign in / Create
   * spinning with no outcome (TC-ONBOARD-184). On timeout the daemon's current status decides.
   */
  private firstCreationStatus(accountId: string): Promise<AccountCreationResult> {
    return new Promise<AccountCreationResult>((resolve: (value: AccountCreationResult) => void): void => {
      const statuses: PublishSubject<AccountCreationResult> = this.accountCreationStatusObservable();
      let dispose: (() => void) | null = null;
      const finish = (result: AccountCreationResult): void => {
        clearTimeout(timer);
        if (dispose !== null) {
          dispose();
        }
        resolve(result);
      };
      const timer: number = setTimeout((): void => {
        finish(this.creationStatusAfterTimeout(accountId));
      }, CREATION_STATUS_TIMEOUT_MS);
      dispose = statuses.subscribe((result: AccountCreationResult): void => {
        if (result.accountId !== accountId) {
          return;
        }
        finish(result);
      });
    });
  }

  /**
   * No creation status arrived in time: re-read the account. Registered (or at least past
   * INITIALIZING without an error) counts as created - the status event was missed. Anything
   * else is a failed creation; the half-made account is removed, as the daemon does with its
   * own failures, and the caller gets a network error to show.
   */
  private creationStatusAfterTimeout(accountId: string): AccountCreationResult {
    const account: AccountModel | null = this.getAccount(accountId);
    if (account !== null) {
      this.updateAccountDetails(account);
      if (account.status !== AccountState.INITIALIZING && !accountStateIsError(account.status)) {
        return new AccountCreationResult(accountId);
      }
    }
    this.log('account creation timed out: ' + accountId);
    jami.removeAccount(accountId);
    return new AccountCreationResult(accountId, AccountState.ERROR_NETWORK);
  }

  /**
   * Swift `private func completeCreation(accountId:isJams:errorCode:) -> Error?`. Creates the
   * account database, then makes the new account current. The Swift app-group
   * `selectedAccountID` write is PreferenceManager's key.
   */
  private async completeCreation(accountId: string, isJams: boolean,
                                 errorCode: string | null): Promise<Error | null> {
    if (errorCode !== null) {
      const status: AccountState | null = accountStateFromRaw(errorCode);
      if (status !== null) {
        if (status === AccountState.ERROR_NETWORK) {
          return new Error(AccountCreationError.NETWORK);
        }
        return new Error(isJams ? AccountCreationError.WRONG_CREDENTIALS
          : AccountCreationError.UNKNOWN);
      }
    }
    const manager: DBManager | null = this.dbManager;
    if (manager === null) {
      this.log('completeCreation: no DBManager injected');
      return new Error(AccountCreationError.UNKNOWN);
    }
    try {
      const created: boolean = await manager.createDatabaseForAccount(accountId, false);
      if (!created) {
        return new Error(AccountCreationError.UNKNOWN);
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      return new Error(describeError(err));
    }
    const account: AccountModel | null = this.getAccount(accountId);
    if (account !== null) {
      this.currentAccount = account;
    }
    PreferenceManager.setSelectedAccountId(accountId);
    return null;
  }

  /**
   * Swift `private func createJamiAccount(username:password:pin:arhivePath:profileName:)`.
   * The details map is built exactly as Swift built it - every optional key is only set when
   * non-empty, which is what decides create-vs-link on the daemon side. `addAccount` is the
   * daemon. The `TestEnvironment.nameServerURI` override is a UI-test hook, not carried over.
   */
  private async createJamiAccount(username: string | null, password: string, pin: string,
                                  arhivePath: string, profileName: string): Promise<string> {
    const details: Map<string, string> = this.getJamiInitialAccountDetails();
    if (username !== null) {
      details.set(String(ConfigKey.ACCOUNT_REGISTERED_NAME), username);
    }
    if (password.length > 0) {
      details.set(String(ConfigKey.ARCHIVE_PASSWORD), password);
    }
    if (pin.length > 0) {
      details.set(String(ConfigKey.ARCHIVE_PIN), pin);
    }
    if (arhivePath.length > 0) {
      details.set(String(ConfigKey.ARCHIVE_PATH), arhivePath);
    }
    if (profileName.length > 0) {
      details.set(String(ConfigKey.DISPLAY_NAME), profileName);
    }
    // iOS enables the DHT proxy because it pairs it with push notifications. HarmonyOS has no
    // push wiring here, and a proxy without push misses incoming requests, so join the DHT directly.
    details.set(String(ConfigKey.PROXY_ENABLED), 'false');
    const accountId: string = jami.addAccount(toRecord(details));
    if (accountId.length === 0) {
      throw new Error('addAccount failed');
    }
    return accountId;
  }

  /** Swift `private func createJamsAccount(username:password:serverUri:)`. GAP. */
  private async createJamsAccount(username: string, password: string,
                                  serverUri: string): Promise<string> {
    const details: Map<string, string> = this.getJamiInitialAccountDetails();
    details.set(String(ConfigKey.MANAGER_USERNAME), username);
    details.set(String(ConfigKey.ARCHIVE_PASSWORD), password);
    details.set(String(ConfigKey.PROXY_ENABLED), 'true');
    details.set(String(ConfigKey.MANAGER_URI), serverUri);
    const accountId: string = jami.addAccount(toRecord(details));
    if (accountId.length === 0) {
      throw new Error('addAccount failed');
    }
    return accountId;
  }

  /**
   * Swift `func accountCreationStatusObservable() -> Observable<AccountCreationResult>` - the
   * `accountAdded` / `registrationStateChanged` slice of the response stream, mapped to the
   * creation result. Pure stream logic; it works whenever those events arrive.
   */
  accountCreationStatusObservable(): PublishSubject<AccountCreationResult> {
    const results: PublishSubject<AccountCreationResult> = new PublishSubject<AccountCreationResult>();
    const dispose: () => void = this.sharedResponseStream.subscribe((event: ServiceEvent): void => {
      if (event.eventType !== ServiceEventType.ACCOUNT_ADDED &&
        event.eventType !== ServiceEventType.REGISTRATION_STATE_CHANGED) {
        return;
      }
      const accountId: string | null = event.getEventInput(ServiceEventInput.ACCOUNT_ID);
      if (accountId === null || accountId.length === 0) {
        return;
      }
      if (event.eventType === ServiceEventType.ACCOUNT_ADDED) {
        results.onNext(new AccountCreationResult(accountId));
        return;
      }
      const stateStr: string | null = event.getEventInput(ServiceEventInput.REGISTRATION_STATE);
      if (stateStr === null) {
        return;
      }
      const state: AccountState | null = accountStateFromRaw(stateStr);
      if (state === null) {
        return;
      }
      if (accountStateIsError(state)) {
        results.onNext(new AccountCreationResult(accountId, stateStr));
      }
    });
    this.disposeBag.add(dispose);
    return results;
  }

  // MARK: - Helpers

  /**
   * Swift `AccountModelHelper(withAccount: account)`. The ported helper reads the two raw
   * daemon maps rather than an AccountModel, so it is built from the account's config models.
   */
  private helperFor(account: AccountModel): AccountModelHelper {
    const details: AccountConfigModel | null = account.details;
    const volatileDetails: AccountConfigModel | null = account.volatileDetails;
    return new AccountModelHelper(details === null ? null : details.toDetails(),
      volatileDetails === null ? null : volatileDetails.toDetails());
  }

  /** Swift `L10n.AccountPage.contactMeOnJamiContant(nameToContact)`. */
  private contactMeTitle(nameToContact: string): string {
    const resources: resourceManager.ResourceManager | null = this.appResources;
    if (resources === null) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'no ResourceManager set; share text unformatted');
      return nameToContact;
    }
    return resources.getStringByNameSync(CONTACT_ME_RESOURCE, nameToContact);
  }

  /** Releases every stream subscription this service opened. */
  dispose(): void {
    this.disposeBag.dispose();
  }
}
