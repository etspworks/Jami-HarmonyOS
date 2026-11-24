/*
 * Ported from Ring/Ring/Models/DeviceModel.swift:21-41 - GPL-3.0, Savoir-faire Linux Inc.
 *
 * A device linked to an account. Every value comes from the jami daemon's device list
 * (AccountsService maps it); this module only models it.
 */

export class DeviceModel {
  deviceId: string = '';
  /** Swift `var deviceName: String?` - the daemon may send a device with no name. */
  deviceName: string | undefined = undefined;
  isCurrent: boolean = false;

  /** Swift `convenience init(withDeviceId:deviceName:isCurrent:)`. */
  constructor(deviceId: string = '', deviceName: string | undefined = undefined,
              isCurrent: boolean = false) {
    this.deviceId = deviceId;
    this.deviceName = deviceName;
    this.isCurrent = isCurrent;
  }

  /** Swift `static func == (lhs:rhs:)` - identity is the device id alone. */
  equals(other: DeviceModel): boolean {
    return this.deviceId === other.deviceId;
  }

  /** Swift `func hash(into:)` - the value to key a Set/Map by. */
  hash(): string {
    return this.deviceId;
  }
}
