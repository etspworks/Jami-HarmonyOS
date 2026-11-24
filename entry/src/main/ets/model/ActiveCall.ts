/*
 * Ported from Ring/Ring/Models/Calls/ActiveCall.swift:19-122 (GPL-3.0, Savoir-faire Linux Inc.):
 * `RemoteCallIdentity`, `ActiveCall` (the struct at :30 plus its failable `init?(_ raw:)`
 * extension at :47) and `AccountCallTracker`.
 *
 * An active ("rendez-vous") call announced in a swarm conversation. The `rdv:` string is the
 * daemon's own encoding; this module only builds it and takes it apart.
 */

/**
 * Swift `struct RemoteCallIdentity: Hashable` - identifies a call across accounts. Excludes
 * `accountId` and `isFromLocalDevice`, which differ per tracker.
 */
export class RemoteCallIdentity {
  readonly conversationId: string;
  readonly id: string;
  readonly uri: string;
  readonly device: string;

  constructor(conversationId: string, id: string, uri: string, device: string) {
    this.conversationId = conversationId;
    this.id = id;
    this.uri = uri;
    this.device = device;
  }

  /** Swift `Hashable` - the value a Map/Set keys this identity by. */
  hash(): string {
    return this.conversationId + ' ' + this.id + ' ' + this.uri + ' ' + this.device;
  }

  equals(other: RemoteCallIdentity): boolean {
    return this.hash() === other.hash();
  }
}

export class ActiveCall {
  readonly id: string;
  readonly uri: string;
  readonly device: string;
  readonly conversationId: string;
  readonly accountId: string;
  readonly isFromLocalDevice: boolean;

  constructor(id: string, uri: string, device: string, conversationId: string,
              accountId: string, isFromLocalDevice: boolean) {
    this.id = id;
    this.uri = uri;
    this.device = device;
    this.conversationId = conversationId;
    this.accountId = accountId;
    this.isFromLocalDevice = isFromLocalDevice;
  }

  /** Swift `var remoteIdentity`. */
  get remoteIdentity(): RemoteCallIdentity {
    return new RemoteCallIdentity(this.conversationId, this.id, this.uri, this.device);
  }

  /** Swift `func constructURI()`. */
  constructURI(): string {
    return 'rdv:' + this.conversationId + '/' + this.uri + '/' + this.device + '/' + this.id;
  }

  /** Swift `init?(_ raw: String)` - null unless the `rdv:` string has exactly four components. */
  static fromRaw(raw: string): ActiveCall | null {
    const components: string[] = raw.replace(new RegExp('rdv:', 'g'), '').split('/');
    if (components.length !== 4) {
      return null;
    }
    return new ActiveCall(components[3], components[1], components[2], components[0], '', false);
  }

  /** Swift synthesized `Hashable` - every stored property takes part. */
  hash(): string {
    return this.conversationId + ' ' + this.id + ' ' + this.uri + ' '
      + this.device + ' ' + this.accountId + ' '
      + (this.isFromLocalDevice ? '1' : '0');
  }

  equals(other: ActiveCall): boolean {
    return this.hash() === other.hash();
  }
}

/**
 * Swift `struct AccountCallTracker`. Swift's `Set<ActiveCall>` becomes a Map keyed by
 * `ActiveCall.hash()`, because ArkTS Sets key objects by reference.
 */
export class AccountCallTracker {
  private calls: Map<string, ActiveCall[]> = new Map<string, ActiveCall[]>();
  private ignored: Map<string, Map<string, ActiveCall>> =
    new Map<string, Map<string, ActiveCall>>();
  private accepted: Map<string, Map<string, ActiveCall>> =
    new Map<string, Map<string, ActiveCall>>();

  /** Swift `var allConversationIds`. */
  get allConversationIds(): string[] {
    const ids: string[] = [];
    this.calls.forEach((value: ActiveCall[], key: string): void => {
      ids.push(key);
    });
    return ids;
  }

  /** Swift `mutating func setCalls(for:to:)` - an empty list clears both side tables. */
  setCalls(conversationId: string, newCalls: ActiveCall[]): void {
    this.calls.set(conversationId, newCalls);
    if (newCalls.length === 0) {
      this.ignored.set(conversationId, new Map<string, ActiveCall>());
      this.accepted.set(conversationId, new Map<string, ActiveCall>());
    }
  }

  /** Swift `mutating func ignoreCall(_:)`. */
  ignoreCall(call: ActiveCall): void {
    AccountCallTracker.bucket(this.ignored, call.conversationId).set(call.hash(), call);
  }

  /** Swift `mutating func acceptCall(_:)`. */
  acceptCall(call: ActiveCall): void {
    AccountCallTracker.bucket(this.accepted, call.conversationId).set(call.hash(), call);
  }

  /** Swift `mutating func removeAcceptedCall(_:)`. */
  removeAcceptedCall(call: ActiveCall): void {
    const bucket: Map<string, ActiveCall> | undefined = this.accepted.get(call.conversationId);
    if (bucket !== undefined) {
      bucket.delete(call.hash());
    }
  }

  /** Swift `func calls(for:)`. */
  callsFor(conversationId: string): ActiveCall[] {
    const found: ActiveCall[] | undefined = this.calls.get(conversationId);
    return found === undefined ? [] : found;
  }

  /** Swift `func ignoredCalls(for:)`. */
  ignoredCalls(conversationId: string): ActiveCall[] {
    return AccountCallTracker.values(this.ignored.get(conversationId));
  }

  /** Swift `func acceptedCalls(for:)`. */
  acceptedCalls(conversationId: string): ActiveCall[] {
    return AccountCallTracker.values(this.accepted.get(conversationId));
  }

  /** Swift `func notAcceptedCalls(for:)`. */
  notAcceptedCalls(conversationId: string): ActiveCall[] {
    const accepted: Map<string, ActiveCall> | undefined = this.accepted.get(conversationId);
    return this.callsFor(conversationId).filter((call: ActiveCall): boolean => {
      return accepted === undefined || !accepted.has(call.hash());
    });
  }

  /** Swift `func notIgnoredCalls(for:)`. */
  notIgnoredCalls(conversationId: string): ActiveCall[] {
    const ignored: Map<string, ActiveCall> | undefined = this.ignored.get(conversationId);
    return this.callsFor(conversationId).filter((call: ActiveCall): boolean => {
      return ignored === undefined || !ignored.has(call.hash());
    });
  }

  /** Swift `func incomingNotAcceptedCalls(for:)`. */
  incomingNotAcceptedCalls(conversationId: string): ActiveCall[] {
    return this.notAcceptedCalls(conversationId).filter((call: ActiveCall): boolean => {
      return !call.isFromLocalDevice;
    });
  }

  /** Swift `func incomingNotAcceptedNotIgnoredCalls()`. */
  incomingNotAcceptedNotIgnoredCalls(): ActiveCall[] {
    const result: ActiveCall[] = [];
    for (const conversationId of this.allConversationIds) {
      const accepted: Map<string, ActiveCall> | undefined = this.accepted.get(conversationId);
      for (const call of this.notIgnoredCalls(conversationId)) {
        if (!call.isFromLocalDevice && (accepted === undefined || !accepted.has(call.hash()))) {
          result.push(call);
        }
      }
    }
    return result;
  }

  private static bucket(table: Map<string, Map<string, ActiveCall>>,
                        conversationId: string): Map<string, ActiveCall> {
    let bucket: Map<string, ActiveCall> | undefined = table.get(conversationId);
    if (bucket === undefined) {
      bucket = new Map<string, ActiveCall>();
      table.set(conversationId, bucket);
    }
    return bucket;
  }

  private static values(bucket: Map<string, ActiveCall> | undefined): ActiveCall[] {
    if (bucket === undefined) {
      return [];
    }
    const result: ActiveCall[] = [];
    bucket.forEach((call: ActiveCall): void => {
      result.push(call);
    });
    return result;
  }
}
