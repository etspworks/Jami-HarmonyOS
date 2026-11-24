/*
 * Ported from Ring/Ring/Models/AccountConfigModel.swift:26-138 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The configuration of one account: the daemon's detail map, keyed by the ConfigKeys this
 * client knows. Every value is produced by the jami daemon; nothing here invents one.
 */

import hilog from '@ohos.hilog';
import { ConfigKey, ConfigKeyModel, configKeyFromRaw } from './ConfigKeyModel';

const LOG_DOMAIN: number = 0x0100;
const LOG_TAG: string = 'AccountConfigModel';

/** Swift `enum AccountType: String`. */
export enum AccountType {
  RING = 'RING',
  SIP = 'SIP'
}

/** Swift `AccountType(rawValue:)`. */
export function accountTypeFromRaw(raw: string): AccountType | null {
  if (raw === 'RING') {
    return AccountType.RING;
  }
  if (raw === 'SIP') {
    return AccountType.SIP;
  }
  return null;
}

export class AccountConfigModel {
  /**
   * Swift `private var configValues = [ConfigKeyModel: String]()`. ArkTS Maps key objects by
   * reference, so the raw ConfigKey string is the key and ConfigKeyModel stays the interface.
   */
  private configValues: Map<string, string> = new Map<string, string>();

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /** Swift `convenience init(withDetails:)`. */
  static withDetails(details: Map<string, string> | null): AccountConfigModel {
    const model: AccountConfigModel = new AccountConfigModel();
    if (details !== null) {
      model.update(details);
    }
    return model;
  }

  /** Swift `func getBool(forConfigKeyModel:)` - case-insensitive compare against "true". */
  getBool(configKeyModel: ConfigKeyModel): boolean {
    return this.get(configKeyModel).toLowerCase() === 'true';
  }

  /** Swift `func get(withConfigKeyModel:)` - empty string when the key is not set. */
  get(configKeyModel: ConfigKeyModel): string {
    const value: string | undefined = this.configValues.get(configKeyModel.hash());
    return value === undefined ? '' : value;
  }

  /** Convenience over `get` for callers holding a bare ConfigKey. */
  getValue(key: ConfigKey): string {
    return this.get(new ConfigKeyModel(key));
  }

  /** Swift `func set(withConfigKeyModel:withValue:)`. */
  set(configKeyModel: ConfigKeyModel, value: string): void {
    this.configValues.set(configKeyModel.hash(), value);
  }

  /** Swift `func update(withDetails:)` - keys unknown to this client are logged and dropped. */
  update(details: Map<string, string>): void {
    details.forEach((value: string, key: string): void => {
      const confKey: ConfigKey | null = configKeyFromRaw(key);
      if (confKey !== null) {
        this.configValues.set(String(confKey), value);
      } else {
        this.log('Unable to find key: ' + key);
      }
    });
  }

  /** Swift `extension AccountConfigModel { func toDetails() }`. */
  toDetails(): Map<string, string> {
    const details: Map<string, string> = new Map<string, string>();
    this.configValues.forEach((value: string, key: string): void => {
      details.set(key, value);
    });
    return details;
  }
}
