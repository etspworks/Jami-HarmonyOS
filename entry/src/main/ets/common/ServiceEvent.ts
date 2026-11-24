/*
 * Ported from Ring/Ring/Services/ServiceEvent.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The event every service publishes on its shared response stream: an event TYPE plus a
 * metadata bag keyed by ServiceEventInput.
 *
 * WHY THIS MODULE EXISTS SEPARATELY: eleven data-layer contract entries name
 * Ring/Ring/Services/ServiceEvent.swift as a source file and none of them OWNS it, so the
 * plan declares no module for it. ArkTS is nominally typed - if each service declared its
 * own ServiceEvent, their streams would not be interchangeable and nothing would compose.
 * The orchestrator created this one shared module between waves. Import it; never redeclare.
 *
 * Swift stored `[ServiceEventInput: Any]`. ArkTS bans `any`/`unknown` and has no runtime
 * generic cast, so the untyped bag becomes TYPED BUCKETS - one map per value shape the source
 * actually puts in. A miss returns null rather than throwing, which is Swift's `as? T`.
 */

import { Profile } from '../model/Profile';

/** Swift `enum ServiceEventType` - the event identifier. */
export enum ServiceEventType {
  ACCOUNT_ADDED = 'ACCOUNT_ADDED',
  ACCOUNTS_CHANGED = 'ACCOUNTS_CHANGED',
  REGISTRATION_STATE_CHANGED = 'REGISTRATION_STATE_CHANGED',
  PRESENCE_UPDATED = 'PRESENCE_UPDATED',
  KNOWN_DEVICES_CHANGED = 'KNOWN_DEVICES_CHANGED',
  EXPORT_ON_RING_ENDED = 'EXPORT_ON_RING_ENDED',
  CONTACT_ADDED = 'CONTACT_ADDED',
  CONTACT_REMOVED = 'CONTACT_REMOVED',
  CONTACT_REQUEST_RECEIVED = 'CONTACT_REQUEST_RECEIVED',
  CONTACT_REQUEST_DISCARDED = 'CONTACT_REQUEST_DISCARDED',
  CONTACT_REQUEST_SENT = 'CONTACT_REQUEST_SENT',
  CONTACT_REQUEST_ACCEPTED = 'CONTACT_REQUEST_ACCEPTED',
  CONTACT_REQUEST_REMOVED = 'CONTACT_REQUEST_REMOVED',
  ALL_CONTACTS_REMOVED = 'ALL_CONTACTS_REMOVED',
  NOTIFICATION_ENABLED = 'NOTIFICATION_ENABLED',
  CALL_ENDED = 'CALL_ENDED',
  CALLS_COMPLETED = 'CALLS_COMPLETED',
  DATA_TRANSFER_CREATED = 'DATA_TRANSFER_CREATED',
  DATA_TRANSFER_CHANGED = 'DATA_TRANSFER_CHANGED',
  DATA_TRANSFER_MESSAGE_UPDATED = 'DATA_TRANSFER_MESSAGE_UPDATED',
  DEVICE_REVOCATION_ENDED = 'DEVICE_REVOCATION_ENDED',
  NEW_INCOMING_MESSAGE = 'NEW_INCOMING_MESSAGE',
  NAME_REGISTRATION_ENDED = 'NAME_REGISTRATION_ENDED',
  CALL_PROVIDER_PREVIEW_PENDING_CALL = 'CALL_PROVIDER_PREVIEW_PENDING_CALL',
  NEW_OUTGOING_MESSAGE = 'NEW_OUTGOING_MESSAGE',
  MIGRATION_ENDED = 'MIGRATION_ENDED',
  LAST_DISPLAYED_MESSAGE_UPDATED = 'LAST_DISPLAYED_MESSAGE_UPDATED',
  PRESENSE_SUBSCRIBED = 'PRESENSE_SUBSCRIBED',
  SEND_LOCATION = 'SEND_LOCATION',
  STOP_LOCATION_SHARING = 'STOP_LOCATION_SHARING',
  APP_ENTER_BACKGROUND = 'APP_ENTER_BACKGROUND',
  APP_ENTER_FOREGROUND = 'APP_ENTER_FOREGROUND',
  CONVERSATION_PROFILE_UPDATED = 'CONVERSATION_PROFILE_UPDATED',
  CONVERSATION_PREFERENCES_UPDATED = 'CONVERSATION_PREFERENCES_UPDATED',
  CONVERSATION_MEMBER_EVENT = 'CONVERSATION_MEMBER_EVENT',
  CONVERSATION_REMOVED = 'CONVERSATION_REMOVED',
  REQUEST_ACCEPTED = 'REQUEST_ACCEPTED',
  ADD_DEVICE_STATE_CHANGED = 'ADD_DEVICE_STATE_CHANGED',
  DEVICE_AUTH_STATE_CHANGED = 'DEVICE_AUTH_STATE_CHANGED',
  CALL_STARTED = 'CALL_STARTED'
}

/** Swift `enum ServiceEventInput` - the keys of the event's metadata bag. */
export enum ServiceEventInput {
  ID = 'ID',
  STATE = 'STATE',
  REGISTRATION_STATE = 'REGISTRATION_STATE',
  URI = 'URI',
  PRESENCE_STATUS = 'PRESENCE_STATUS',
  MESSAGE_STATUS = 'MESSAGE_STATUS',
  MESSAGE_ID = 'MESSAGE_ID',
  PIN = 'PIN',
  ACCOUNT_ID = 'ACCOUNT_ID',
  DATE = 'DATE',
  CALL_TYPE = 'CALL_TYPE',
  CALL_TIME = 'CALL_TIME',
  CALL_STATE = 'CALL_STATE',
  MEDIA_TYPE = 'MEDIA_TYPE',
  MEDIA_STATE = 'MEDIA_STATE',
  TRANSFER_ID = 'TRANSFER_ID',
  CONVERSATION_ID = 'CONVERSATION_ID',
  LOCAL_PHOTO_ID = 'LOCAL_PHOTO_ID',
  PROXY_ADDRESS = 'PROXY_ADDRESS',
  DEVICE_ID = 'DEVICE_ID',
  CONTENT = 'CONTENT',
  PEER_URI = 'PEER_URI',
  ACCOUNT_URI = 'ACCOUNT_URI',
  NAME = 'NAME',
  CALL_UUID = 'CALL_UUID',
  CALL_ID = 'CALL_ID',
  MUTED = 'MUTED',
  OLD_DISPLAYED_MESSAGE = 'OLD_DISPLAYED_MESSAGE',
  NEW_DISPLAYED_MESSAGE = 'NEW_DISPLAYED_MESSAGE',
  CONVERSATION_TYPE = 'CONVERSATION_TYPE',
  PROFILE = 'PROFILE',
  /**
   * NOT in the Swift enum. Swift packs `(content, shouldTryToSave)` into `.content` as a
   * tuple, which has no typed ArkTS equivalent, so the flag gets its own input key.
   */
  SHOULD_TRY_TO_SAVE = 'SHOULD_TRY_TO_SAVE'
}

/**
 * Swift `struct ServiceEvent`. Carries the information a service returns, as a stream event.
 *
 * Swift stored `[ServiceEventInput: Any]`. ArkTS bans `any`/`unknown` and has no runtime
 * generic cast, so the untyped bag becomes TYPED BUCKETS: one map per value shape the source
 * actually puts in. Two read styles are provided on purpose, because the services were written
 * against both and they must share one nominal type:
 *   - `addEventInput` / `getEventInput` - the string-only pair (the overwhelming majority of
 *     inputs are strings; this is the shape `AccountsService` and `ConversationsService` use).
 *   - `addString`/`addNumber`/`addBoolean`/`addMap`/`addProfile` with matching `getX`
 *     accessors - the typed shape `ConversationsManager` uses.
 * A read of an unset key, or of a key stored under a different shape, returns null, which is
 * Swift's `as? T`.
 *
 * Swift's struct was a value type copied on every assignment; this is a class, so a consumer
 * retaining an event past the emit must `copy()` it.
 */
export class ServiceEvent {
  /** Swift `internal private(set) var eventType` - identifies the event type. */
  private type: ServiceEventType;

  private strings: Map<string, string> = new Map<string, string>();
  private numbers: Map<string, number> = new Map<string, number>();
  private booleans: Map<string, boolean> = new Map<string, boolean>();
  private maps: Map<string, Map<string, string>> = new Map<string, Map<string, string>>();
  private profiles: Map<string, Profile> = new Map<string, Profile>();

  /** Swift `init(withEventType:)`. */
  constructor(eventType: ServiceEventType) {
    this.type = eventType;
  }

  get eventType(): ServiceEventType {
    return this.type;
  }

  /** Swift `mutating func addEventInput(_:value:)`, string form. */
  addEventInput(input: ServiceEventInput, value: string): void {
    this.strings.set(input as string, value);
  }

  /** Swift `func getEventInput<T>(_:) -> T?`, string form. Null when unset. */
  getEventInput(input: ServiceEventInput): string | null {
    const value: string | undefined = this.strings.get(input as string);
    return value === undefined ? null : value;
  }

  /** True when the event carries this key under any shape. */
  hasEventInput(input: ServiceEventInput): boolean {
    const key: string = input as string;
    return this.strings.has(key) || this.numbers.has(key) || this.booleans.has(key) ||
      this.maps.has(key) || this.profiles.has(key);
  }

  addString(input: ServiceEventInput, value: string): void {
    this.strings.set(input as string, value);
  }

  getString(input: ServiceEventInput): string | null {
    const value: string | undefined = this.strings.get(input as string);
    return value === undefined ? null : value;
  }

  addNumber(input: ServiceEventInput, value: number): void {
    this.numbers.set(input as string, value);
  }

  getNumber(input: ServiceEventInput): number | null {
    const value: number | undefined = this.numbers.get(input as string);
    return value === undefined ? null : value;
  }

  addBoolean(input: ServiceEventInput, value: boolean): void {
    this.booleans.set(input as string, value);
  }

  getBoolean(input: ServiceEventInput): boolean | null {
    const value: boolean | undefined = this.booleans.get(input as string);
    return value === undefined ? null : value;
  }

  addMap(input: ServiceEventInput, value: Map<string, string>): void {
    this.maps.set(input as string, value);
  }

  getMap(input: ServiceEventInput): Map<string, string> | null {
    const value: Map<string, string> | undefined = this.maps.get(input as string);
    return value === undefined ? null : value;
  }

  addProfile(input: ServiceEventInput, value: Profile): void {
    this.profiles.set(input as string, value);
  }

  getProfile(input: ServiceEventInput): Profile | null {
    const value: Profile | undefined = this.profiles.get(input as string);
    return value === undefined ? null : value;
  }

  /** A detached copy, for a consumer retaining the event past the emit (Swift got this free). */
  copy(): ServiceEvent {
    const clone: ServiceEvent = new ServiceEvent(this.type);
    this.strings.forEach((value: string, key: string) => { clone.strings.set(key, value); });
    this.numbers.forEach((value: number, key: string) => { clone.numbers.set(key, value); });
    this.booleans.forEach((value: boolean, key: string) => { clone.booleans.set(key, value); });
    this.maps.forEach((value: Map<string, string>, key: string) => { clone.maps.set(key, value); });
    this.profiles.forEach((value: Profile, key: string) => { clone.profiles.set(key, value); });
    return clone;
  }
}
