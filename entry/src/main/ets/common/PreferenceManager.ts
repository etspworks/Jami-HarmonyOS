/*
 * Ported from Ring/Ring/Helpers/PreferencesManager.swift:23-111
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The donation-campaign schedule, and nothing else. Despite the name, the Swift
 * `PreferenceManager` is not the app's general settings store: it owns three `UserDefaults`
 * keys (campaign start date, end date, enabled flag) and the date arithmetic that decides
 * whether the donation banner shows. Every other stored setting in this app lives with its
 * reader - `ConversationsManager` owns the automatic-download keys, for example.
 *
 * NOT daemon-backed. `@ohos.data.preferences` is a real HarmonyOS capability, so all of this
 * works for real.
 *
 * FOUR THINGS DIFFER FROM SWIFT, ALL FORCED BY THE PLATFORM:
 *
 * 1. Context. `UserDefaults.standard` is ambient; a `Preferences` store needs a context, and a
 *    `.ts` module cannot call `getContext()` - so the ability calls the static
 *    `PreferenceManager.setContext(...)` once at startup (the `ProfileStore.setContext`
 *    precedent). The store NAME is `jami_shared`, the same one `ConversationsManager` opens, so
 *    the app has one settings store rather than one per module. Before the injection every read
 *    returns its Swift default and every write is dropped with a warning, which is what
 *    `UserDefaults` does for an unset key anyway.
 *
 * 2. Dates. `UserDefaults` stores a `Date`; `preferences` stores number/string/boolean, so a
 *    date is persisted as epoch MILLISECONDS and read back through `new Date(ms)`.
 *
 * 3. `DateFormatter(dateFormat: "dd.MM.yyyy")` has no HarmonyOS equivalent that parses a fixed
 *    non-locale pattern, so the pattern is applied by hand (`parseDate`). A
 *    locale-aware formatter would be wrong here: these are fixed campaign dates, not text the
 *    user reads.
 *
 * 4. `UserDefaults.register(defaults:)` installs a value only where the key is unset; there is
 *    no registration domain in `preferences`, so `registerDonationsDefaults` writes each
 *    default only when `hasSync` says the key is absent. The forced end-date update the Swift
 *    performs afterwards is kept verbatim.
 *
 * Every key written here is read here (`getStartDonationDate`, `getEndDonationDate`,
 * `isCampaignEnabled`), except the first-launch defaults (`registerFirstLaunchDefaults`), which
 * their settings screens and `ConversationsManager` read.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { describeError } from './ErrorText';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'PreferenceManager';

/** The one settings store; `ConversationsManager` opens the same name. */
const PREFERENCES_STORE_NAME: string = 'jami_shared';

/** Swift `struct DefaultsKeys` (PreferencesManager.swift:23) - the raw key strings. */
export enum DefaultsKeys {
  DONATION_START_DATE_KEY = 'DONATION_START_DATE_KEY',
  DONATION_END_DATE_KEY = 'DONATION_END_DATE_KEY',
  DONATION_CAMPAIGN_ENABLED = 'DONATION_COMPAIGN_ENABLED',
  /** Swift `Constants.selectedAccountID`. */
  SELECTED_ACCOUNT_ID = 'SELECTED_ACCOUNT_ID',
  /** Swift GeneralSettings.swift:23-27, the keys `registerFirstLaunchDefaults` seeds. */
  HARDWARE_ACCELERATION_KEY = 'HARDWARE_ACCELERATION_KEY',
  ACCEPT_TRANSFER_LIMIT_KEY = 'ACCEPT_TRANSFER_LIMIT_KEY',
  LIMIT_LOCATION_SHARING_DURATION_KEY = 'LIMIT_LOCATION_SHARING_DURATION_KEY',
  LOCATION_SHARING_DURATION_KEY = 'LOCATION_SHARING_DURATION_KEY'
}

/** Swift `struct DefaultValues` (PreferencesManager.swift:29) - the shipped campaign window. */
export enum DefaultValues {
  DONATION_START_DATE = '27.11.2023',
  DONATION_END_DATE = '01.04.2024'
}

/** Swift `dateFormatter.dateFormat = "dd.MM.yyyy"`. */
const DATE_FORMAT: string = 'dd.MM.yyyy';

/** Swift `Calendar.current.date(byAdding: .day, value: 7, to:)`. */
const TEMPORARY_DISABLE_DAYS: number = 7;
const MILLISECONDS_PER_DAY: number = 24 * 60 * 60 * 1000;

let settingsStore: preferences.Preferences | null = null;

/**
 * Swift `class PreferenceManager`. Every member is static, as in the source: this class holds
 * no instance state and is never constructed.
 */
export class PreferenceManager {
  /**
   * Swift `private static let dateFormatter: DateFormatter` - the pattern is the only part of
   * it that carries over (see header note 3). The Swift closure's local `formatter` variable
   * has no counterpart: it existed only to configure the object being returned.
   */
  static readonly dateFormatter: string = DATE_FORMAT;

  /** CALL ONCE at startup: `PreferenceManager.setContext(this.context)` in `EntryAbility.onCreate`. */
  static setContext(context: common.UIAbilityContext): void {
    try {
      const options: preferences.Options = { name: PREFERENCES_STORE_NAME };
      settingsStore = preferences.getPreferencesSync(context, options);
    } catch (error) {
      settingsStore = null;
      hilog.error(LOG_DOMAIN, LOG_TAG, 'settings store unavailable: %{public}s',
        describeError(error as BusinessError));
    }
  }

  /**
   * Swift `static func registerDonationsDefaults()`. Installs the shipped campaign window for
   * any key that has none, then forces the end date - "the end date could be set in the
   * previous application run".
   */
  static registerDonationsDefaults(): void {
    const defaultStartDate: Date | null = PreferenceManager.parseDate(DefaultValues.DONATION_START_DATE);
    const defaultEndDate: Date | null = PreferenceManager.parseDate(DefaultValues.DONATION_END_DATE);
    if (defaultStartDate === null || defaultEndDate === null) {
      return;
    }
    PreferenceManager.registerDefaultNumber(DefaultsKeys.DONATION_START_DATE_KEY,
      defaultStartDate.getTime());
    PreferenceManager.registerDefaultNumber(DefaultsKeys.DONATION_END_DATE_KEY,
      defaultEndDate.getTime());
    PreferenceManager.registerDefaultBoolean(DefaultsKeys.DONATION_CAMPAIGN_ENABLED, true);
    /*
     * Force update as the end date could be set in the previous application run.
     */
    PreferenceManager.updateEndDonationsDate(defaultEndDate);
  }

  /**
   * Swift AppDelegate `prepareAccounts()` (4.20): once the accounts are loaded and there is none,
   * the first-launch value of each of these settings, written only where it is unset (T-1628).
   * Swift also called `videoService.setHardwareAccelerated(withState: true)`; VideoService
   * already holds true in memory.
   */
  static registerFirstLaunchDefaults(): void {
    PreferenceManager.registerDefaultNumber(DefaultsKeys.ACCEPT_TRANSFER_LIMIT_KEY, 20);
    PreferenceManager.registerDefaultBoolean(DefaultsKeys.HARDWARE_ACCELERATION_KEY, true);
    PreferenceManager.registerDefaultBoolean(DefaultsKeys.LIMIT_LOCATION_SHARING_DURATION_KEY, true);
    PreferenceManager.registerDefaultNumber(DefaultsKeys.LOCATION_SHARING_DURATION_KEY, 15);
  }

  /**
   * Swift `VideoPipeline.applyStoredAccelerationPreference()`: the Video settings switch, on when
   * it was never set (T-1593).
   */
  static isHardwareAccelerationEnabled(): boolean {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      return true;
    }
    try {
      return store.getSync(DefaultsKeys.HARDWARE_ACCELERATION_KEY, true) as boolean;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read %{public}s failed: %{public}s',
        DefaultsKeys.HARDWARE_ACCELERATION_KEY as string, describeError(error as BusinessError));
      return true;
    }
  }

  /** Swift `static func updateEndDonationsDate(date:)`. */
  static updateEndDonationsDate(date: Date): void {
    PreferenceManager.store(DefaultsKeys.DONATION_END_DATE_KEY, date.getTime());
  }

  /** Swift `static func setStartDonationDate(_:)` - an unparseable string writes nothing. */
  static setStartDonationDate(dateString: string): void {
    const date: Date | null = PreferenceManager.parseDate(dateString);
    if (date === null) {
      return;
    }
    PreferenceManager.store(DefaultsKeys.DONATION_START_DATE_KEY, date.getTime());
  }

  /** Swift `static func getStartDonationDate() -> Date?`. */
  static getStartDonationDate(): Date | null {
    return PreferenceManager.readDate(DefaultsKeys.DONATION_START_DATE_KEY);
  }

  /** Swift `static func getEndDonationDate() -> Date?`. */
  static getEndDonationDate(): Date | null {
    return PreferenceManager.readDate(DefaultsKeys.DONATION_END_DATE_KEY);
  }

  /** Swift `sharedDefaults.set(accountId, forKey: Constants.selectedAccountID)`. */
  static setSelectedAccountId(accountId: string): void {
    PreferenceManager.store(DefaultsKeys.SELECTED_ACCOUNT_ID, accountId);
  }

  /** Swift `sharedDefaults.string(forKey: Constants.selectedAccountID)`; empty when unset. */
  static getSelectedAccountId(): string {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      return '';
    }
    try {
      return store.getSync(DefaultsKeys.SELECTED_ACCOUNT_ID, '') as string;
    } catch (error) {
      return '';
    }
  }

  /** Swift `static func setCampaignEnabled(_:)`. */
  static setCampaignEnabled(isEnabled: boolean): void {
    PreferenceManager.store(DefaultsKeys.DONATION_CAMPAIGN_ENABLED, isEnabled);
  }

  /** Swift `static func isCampaignEnabled() -> Bool` - `UserDefaults.bool` is false when unset. */
  static isCampaignEnabled(): boolean {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      return false;
    }
    try {
      return store.getSync(DefaultsKeys.DONATION_CAMPAIGN_ENABLED, false) as boolean;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read %{public}s failed: %{public}s',
        DefaultsKeys.DONATION_CAMPAIGN_ENABLED as string, describeError(error as BusinessError));
      return false;
    }
  }

  /**
   * Swift `static func isReachEndOfDonationCampaign() -> Bool`. No stored end date means the
   * campaign is over, which is what keeps the banner hidden on a fresh install that never ran
   * `registerDonationsDefaults`.
   */
  static isReachEndOfDonationCampaign(): boolean {
    const currentDate: Date = new Date();
    const endDate: Date | null = PreferenceManager.getEndDonationDate();
    if (endDate !== null) {
      return currentDate.getTime() > endDate.getTime();
    }
    return true;
  }

  /** Swift `static func temporarilyDisableDonationCampaign()` - pushes the start date 7 days out. */
  static temporarilyDisableDonationCampaign(): void {
    const currentDate: Date = new Date();
    const date7DaysAhead: Date =
      new Date(currentDate.getTime() + TEMPORARY_DISABLE_DAYS * MILLISECONDS_PER_DAY);
    PreferenceManager.store(DefaultsKeys.DONATION_START_DATE_KEY, date7DaysAhead.getTime());
  }

  /** Swift `static func isDateWithinCampaignPeriod() -> Bool`. */
  static isDateWithinCampaignPeriod(): boolean {
    const currentDate: Date = new Date();
    const startDate: Date | null = PreferenceManager.getStartDonationDate();
    const endDate: Date | null = PreferenceManager.getEndDonationDate();
    if (startDate !== null && endDate !== null) {
      const now: number = currentDate.getTime();
      return now >= startDate.getTime() && now < endDate.getTime();
    }
    return false;
  }

  // MARK: - Private

  /** Swift `dateFormatter.date(from:)` for the fixed `dd.MM.yyyy` pattern. */
  private static parseDate(text: string): Date | null {
    // The pattern is fixed; `dateFormatter` is `dd.MM.yyyy`, so the separator is '.' and the
    // field order is day, month, year.
    const parts: string[] = text.split('.');
    if (parts.length !== 3) {
      return null;
    }
    const day: number = Number.parseInt(parts[0], 10);
    const month: number = Number.parseInt(parts[1], 10);
    const year: number = Number.parseInt(parts[2], 10);
    if (Number.isNaN(day) || Number.isNaN(month) || Number.isNaN(year)) {
      return null;
    }
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    const date: Date = new Date(year, month - 1, day);
    // `new Date(2023, 1, 31)` rolls into March; Swift's formatter refuses such a date.
    if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) {
      return null;
    }
    return date;
  }

  /** Swift `UserDefaults.object(forKey:) as? Date`. */
  private static readDate(key: DefaultsKeys): Date | null {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      return null;
    }
    try {
      if (!store.hasSync(key)) {
        return null;
      }
      const stored: number = store.getSync(key, 0) as number;
      return stored === 0 ? null : new Date(stored);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read %{public}s failed: %{public}s', key as string,
        describeError(error as BusinessError));
      return null;
    }
  }

  /** Swift `UserDefaults.set(_:forKey:)`. */
  private static store(key: DefaultsKeys, value: preferences.ValueType): void {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG,
        'no settings store; %{public}s dropped (call setContext at startup)', key as string);
      return;
    }
    try {
      store.putSync(key, value);
      // flushSync, not flush(): a fire-and-forget promise loses the write when the page/ability
      // is torn down before it settles. The outer catch reports a synchronous failure.
      store.flushSync();
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write %{public}s failed: %{public}s', key as string,
        describeError(error as BusinessError));
    }
  }

  /** The `register(defaults:)` half: install only where the key has no value yet. */
  private static registerDefaultNumber(key: DefaultsKeys, value: number): void {
    if (PreferenceManager.hasValue(key)) {
      return;
    }
    PreferenceManager.store(key, value);
  }

  private static registerDefaultBoolean(key: DefaultsKeys, value: boolean): void {
    if (PreferenceManager.hasValue(key)) {
      return;
    }
    PreferenceManager.store(key, value);
  }

  private static hasValue(key: DefaultsKeys): boolean {
    const store: preferences.Preferences | null = settingsStore;
    if (store === null) {
      // Nothing can be stored either, so "already set" is the answer that drops the write.
      return true;
    }
    try {
      return store.hasSync(key);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'hasSync %{public}s failed: %{public}s', key as string,
        describeError(error as BusinessError));
      return true;
    }
  }
}
