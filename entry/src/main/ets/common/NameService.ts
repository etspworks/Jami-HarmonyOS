/*
 * Ported from Ring/Ring/Services/NameService.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * Jami's name service is NOT a REST endpoint. Every lookup, registration and directory search
 * goes through `NameRegistrationAdapter` (Ring/Ring/Bridging/NameRegistration/*.mm) into the
 * prebuilt C++ jami daemon, whose source is not on disk in this repository. There is therefore
 * nothing to port for the round-trip itself (Rule 11): it is a GAP, routed through
 * `DaemonService` like every other daemon-backed capability. `lookupName` goes to the daemon
 * like Swift does, and falls back to the name server's public HTTP API (what the daemon's
 * NameDirectory calls) only when the daemon is not running or refuses the request.
 *
 * What IS real and ported verbatim:
 *   - the 0.5s debounce and the cancel-previous-lookup bookkeeping (`delayedLookupNameCall`);
 *   - the empty-name short circuit (`.empty` before any request is made);
 *   - the response -> validation-status mapping in `registeredNameFound`;
 *   - the per-state logging and stream fan-out in `nameRegistrationEnded` / `userSearchEnded`;
 *   - the `registerNameObservable` composition over the registration event stream.
 *
 * A lookup that cannot reach the daemon resolves to the ERROR state the source already models
 * (`LookupNameState.ERROR` / `NameRegistrationState.ERROR`), delivered through the same
 * callbacks the adapter would have called. That is why a caller sees `INVALID` rather than a
 * spinner that never stops, and never sees a name that was not resolved.
 *
 * `REGISTERED_NAMES_KEY` (Swift `registeredNamesKey`, NameService.swift:25) is NOT written.
 * The derived contract marks it `status: "disabled"`, `reason: "no-reader-derived"`: the only
 * writer in the source is `nameRegistrationEnded` and no reader could be derived anywhere in
 * the app, so a stored value here would be inert. See the note on `nameRegistrationEnded`.
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DaemonService } from './DaemonService';
import { DisposeBag, PublishSubject } from './Observable';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';
import { DEFAULT_NAME_SERVER } from './LocalAccountStore';
import { jami } from './JamiNative';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'NameService';

/** The name server's accepted username syntax. */
const NAME_VALIDATOR: RegExp = /^[a-zA-Z0-9_-]{3,32}$/;

/** Maps an ns.jami.net `GET /name/<name>` status code the way the daemon's lookupName does. */
export function lookupStateForHttpCode(code: number): LookupNameState {
  if (code === 200) {
    return LookupNameState.FOUND;
  }
  if (code === 404) {
    return LookupNameState.NOT_FOUND;
  }
  if (code === 400 || code === 401) {
    return LookupNameState.INVALID_NAME;
  }
  return LookupNameState.ERROR;
}

/** Objective-C `LookupNameState` (LookupNameResponse.h) - the state of a name/address lookup. */
export enum LookupNameState {
  FOUND = 'FOUND',
  INVALID_NAME = 'INVALID_NAME',
  NOT_FOUND = 'NOT_FOUND',
  ERROR = 'ERROR'
}

/** Objective-C `NameRegistrationState` (NameRegistrationResponse.h). */
export enum NameRegistrationState {
  SUCCESS = 'SUCCESS',
  INVALID_NAME = 'INVALID_NAME',
  ALREADY_TAKEN = 'ALREADY_TAKEN',
  ERROR = 'ERROR'
}

/** Objective-C `UserSearchState` (UserSearchResponse.h) - the state of a JAMS directory search. */
export enum UserSearchState {
  FOUND = 'FOUND',
  INVALID_NAME = 'INVALID_NAME',
  NOT_FOUND = 'NOT_FOUND',
  ERROR = 'ERROR'
}

/** Swift `enum UsernameValidationStatus` (Ring/CommonHelpers.swift:264). */
export enum UsernameValidationStatus {
  EMPTY = 'EMPTY',
  LOOKING_UP = 'LOOKING_UP',
  INVALID = 'INVALID',
  ALREADY_TAKEN = 'ALREADY_TAKEN',
  VALID = 'VALID'
}

/**
 * Objective-C `LookupNameResponse`. The daemon's `RegisteredNameFound` signal, as the adapter
 * shaped it: `requestedName` is what was asked for, `name`/`address` what came back.
 */
export class LookupNameResponse {
  accountId: string;
  state: LookupNameState;
  address: string;
  name: string;
  requestedName: string;

  constructor(accountId: string, state: LookupNameState, address: string, name: string,
    requestedName: string) {
    this.accountId = accountId;
    this.state = state;
    this.address = address;
    this.name = name;
    this.requestedName = requestedName;
  }
}

/** Objective-C `NameRegistrationResponse` - the daemon's `NameRegistrationEnded` signal. */
export class NameRegistrationResponse {
  accountId: string;
  state: NameRegistrationState;
  address: string;
  name: string;

  constructor(accountId: string, state: NameRegistrationState, address: string, name: string) {
    this.accountId = accountId;
    this.state = state;
    this.address = address;
    this.name = name;
  }
}

/**
 * Objective-C `UserSearchResponse` - the daemon's `UserSearchEnded` signal. Swift read
 * `results as? [[String: String]]`, so the untyped `NSArray` becomes an array of string maps.
 */
export class UserSearchResponse {
  accountId: string;
  state: UserSearchState;
  query: string;
  results: Array<Map<string, string>>;

  constructor(accountId: string, state: UserSearchState, query: string,
    results: Array<Map<string, string>>) {
    this.accountId = accountId;
    this.state = state;
    this.query = query;
    this.results = results;
  }
}

export class NameService {
  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /**
   * Swift `private var delayedLookupNameCall: DispatchWorkItem?` - the pending debounced lookup,
   * cancelled by the next keystroke. A `setTimeout` handle here; `clearTimeout` is the cancel.
   */
  private delayedLookupNameCall: number | null = null;

  /** Swift `private let lookupNameCallDelay = 0.5` (seconds). Milliseconds here. */
  private readonly lookupNameCallDelay: number = 500;

  /** Swift `var usernameValidationStatus = PublishSubject<UsernameValidationStatus>()`. */
  readonly usernameValidationStatus: PublishSubject<UsernameValidationStatus> =
    new PublishSubject<UsernameValidationStatus>();

  /** Swift `private let registrationStatus = PublishSubject<ServiceEvent>()`. */
  private readonly registrationStatus: PublishSubject<ServiceEvent> =
    new PublishSubject<ServiceEvent>();

  /**
   * Swift `var sharedRegistrationStatus: Observable<ServiceEvent>` - `registrationStatus.share()`.
   * A ported PublishSubject is already multicast, so the shared stream IS the stream.
   */
  readonly sharedRegistrationStatus: PublishSubject<ServiceEvent>;

  /** Swift `var usernameLookupStatus = PublishSubject<LookupNameResponse>()`. */
  readonly usernameLookupStatus: PublishSubject<LookupNameResponse> =
    new PublishSubject<LookupNameResponse>();

  /** Registered names that lookups resolved, by address, for peers who are not contacts (T-0884). */
  private readonly resolvedNames: Map<string, string> = new Map<string, string>();

  /** The registered name a lookup found for `address`, if any. */
  cachedName(address: string): string | undefined {
    return this.resolvedNames.get(address);
  }

  /** Swift `private let userSearchResponseStream = PublishSubject<UserSearchResponse>()`. */
  private readonly userSearchResponseStream: PublishSubject<UserSearchResponse> =
    new PublishSubject<UserSearchResponse>();

  /** Swift `let userSearchResponseShared: Observable<UserSearchResponse>` - the shared stream. */
  readonly userSearchResponseShared: PublishSubject<UserSearchResponse>;

  constructor() {
    this.sharedRegistrationStatus = this.registrationStatus;
    this.userSearchResponseShared = this.userSearchResponseStream;
  }

  /**
   * Swift `private let nameRegistrationAdapter: NameRegistrationAdapter` - the Objective-C++
   * daemon bridge, a constructor argument. It has no HarmonyOS counterpart, so every call that
   * went through it goes through the daemon gap instead.
   */
  private get nameRegistrationAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /**
   * Swift `NameRegistrationAdapter.delegate = self` in `init` - this service IS the adapter's
   * delegate. There is no adapter to register with, so the three delegate methods
   * (`registeredNameFound`, `nameRegistrationEnded`, `userSearchEnded`) are simply public: this
   * module calls them itself with the ERROR responses the gap produces, and they are the entry
   * point a real daemon binding would call.
   */
  get delegate(): NameService {
    return this;
  }

  /** Swift `private let log = SwiftyBeaver.self` - SwiftyBeaver maps to hilog. */
  private log(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  /** Drops every subscription this service took out. */
  dispose(): void {
    try {
      this.cancelDelayedLookup();
    } finally {
      this.disposeBag.dispose();
    }
  }

  private cancelDelayedLookup(): void {
    const pending: number | null = this.delayedLookupNameCall;
    if (pending !== null) {
      clearTimeout(pending);
      this.delayedLookupNameCall = null;
    }
  }

  /**
   * Swift `func lookupName(withAccount:nameserver:name:)` - a debounced username lookup.
   *
   * The empty-name short circuit, the cancel of the previous request and the 0.5s delay are the
   * real behaviour and are ported as-is. Swift substituted `TestEnvironment.shared.nameServerURI`
   * for an empty nameserver; that value comes from a process environment variable set by the
   * XCUITest host, which has no HarmonyOS counterpart; an empty nameserver means the daemon's
   * default, ns.jami.net.
   *
   * The request goes to the daemon (`libjami::lookupName`, answered by RegisteredNameFound);
   * `queryNameServer` makes the same public HTTP call when the daemon cannot take it.
   */
  lookupName(account: string, nameserver: string, name: string): void {
    // Cancel previous lookups...
    this.cancelDelayedLookup();
    this.pendingLookupName = name;

    if (name.length === 0) {
      this.usernameValidationStatus.onNext(UsernameValidationStatus.EMPTY);
      return;
    }
    this.usernameValidationStatus.onNext(UsernameValidationStatus.LOOKING_UP);

    // Fire a delayed lookup...
    this.delayedLookupNameCall = setTimeout(() => {
      this.delayedLookupNameCall = null;
      if (!this.nameRegistrationAdapter.daemonStarted || !jami.lookupName(account, nameserver, name)) {
        this.queryNameServer(account, nameserver, name);
      }
    }, this.lookupNameCallDelay);
  }

  /**
   * The name the last `lookupName` asked for. Only its answer drives `usernameValidationStatus`:
   * RegisteredNameFound also answers every `lookupAddress` and older keystrokes.
   */
  private pendingLookupName: string = '';

  /**
   * The daemon's `NameDirectory::lookupName`: syntax check against NAME_VALIDATOR, then
   * `GET <server>/name/<lowercased name>` (200 taken, 404 free).
   */
  private queryNameServer(account: string, nameserver: string, name: string): void {
    const deliver = (state: LookupNameState, address: string): void => {
      this.registeredNameFound(new LookupNameResponse(account, state, address, name, name));
    };
    if (!NAME_VALIDATOR.test(name)) {
      deliver(LookupNameState.INVALID_NAME, '');
      return;
    }
    const server: string = (nameserver.length > 0 ? nameserver : DEFAULT_NAME_SERVER).replace(/\/+$/, '');
    const request: http.HttpRequest = http.createHttp();
    request.request(`${server}/name/${encodeURIComponent(name.toLowerCase())}`,
      { method: http.RequestMethod.GET, readTimeout: 10000, connectTimeout: 10000 })
      .then((response: http.HttpResponse): void => {
        let address: string = '';
        if (response.responseCode === 200 && typeof response.result === 'string') {
          try {
            // ns.jami.net answers `{"name", "addr", "publickey", "signature"}`.
            address = (JSON.parse(response.result) as Record<string, string>)['addr'] ?? '';
          } catch (e) {
            address = '';
          }
        }
        deliver(lookupStateForHttpCode(response.responseCode), address);
      })
      .catch((error: Error): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'name lookup failed: %{public}s', error.message);
        deliver(LookupNameState.ERROR, '');
      })
      .finally((): void => request.destroy());
  }

  /**
   * Swift `func lookupAddress(withAccount:nameserver:address:)` - resolve the registered name of
   * a jami hash. Swift hopped to a background queue; the gap has no work to do off the main
   * thread, and the response is delivered asynchronously either way.
   *
   * Build-only gap (`unavailable`, not `reportUnavailable`): this runs once per participant, per
   * contact row and per call peer, and would flood the notice channel.
   */
  lookupAddress(account: string, nameserver: string, address: string): void {
    // The answer arrives as the daemon's RegisteredNameFound signal.
    jami.lookupAddress(account, nameserver, address);
  }

  /**
   * Swift `func registerName(withAccount:password:name:)` - register the username on the
   * blockchain. USER-INITIATED gap; the failure is delivered through `nameRegistrationEnded`, so
   * `registerNameObservable` and `AccountsViewModel` both see the outcome they subscribe for.
   */
  registerName(account: string, password: string, name: string): void {
    // The outcome arrives as the daemon's NameRegistrationEnded signal.
    jami.registerName(account, name, password.length > 0 ? 'password' : '', password);
  }

  /**
   * Swift `func registerNameObservable(accountId:password:name:) -> Observable<Bool>`.
   *
   * Swift combined the fire-and-forget adapter call with the filtered `nameRegistrationEnded`
   * event and mapped `.success` to true. The ported plumbing has no `combineLatest`, so the
   * subscription IS the composition: subscribe to the registration stream first, filter on the
   * account and the event type, then fire the request. The returned subject emits exactly one
   * boolean and then unsubscribes itself, which is what `.take(1)` did downstream.
   */
  registerNameObservable(accountId: string, password: string, name: string): PublishSubject<boolean> {
    const result: PublishSubject<boolean> = new PublishSubject<boolean>();
    let unsubscribe: (() => void) | null = null;
    let settled: boolean = false;
    unsubscribe = this.sharedRegistrationStatus.subscribe((event: ServiceEvent): void => {
      if (settled || event.eventType !== ServiceEventType.NAME_REGISTRATION_ENDED ||
        event.getEventInput(ServiceEventInput.ACCOUNT_ID) !== accountId) {
        return;
      }
      settled = true;
      const state: string | null = event.getEventInput(ServiceEventInput.STATE);
      result.onNext(state === NameRegistrationState.SUCCESS as string);
      if (unsubscribe !== null) {
        unsubscribe();
      }
    });
    this.disposeBag.add(unsubscribe);
    this.registerName(accountId, password, name);
    return result;
  }

  /**
   * Swift `func searchUser(withAccount:query:)` - the JAMS directory search. USER-INITIATED gap;
   * resolved as an ERROR search response so the search UI leaves its loading state.
   */
  searchUser(account: string, query: string): void {
    // The account's JAMS directory answers with UserSearchEnded.
    if (!jami.searchUser(account, query)) {
      setTimeout(() => {
        this.userSearchEnded(new UserSearchResponse(account, UserSearchState.ERROR, query,
          new Array<Map<string, string>>()));
      }, 0);
    }
  }

  // MARK: NameRegistrationAdapterDelegate

  /**
   * Swift `internal func registeredNameFound(with response: LookupNameResponse)` - ported
   * verbatim, including the mapping a name-registration screen depends on: a name the daemon
   * cannot find is one the user may take. The validation status is only for the name being
   * typed (`pendingLookupName`); every response still reaches `usernameLookupStatus`.
   */
  registeredNameFound(response: LookupNameResponse): void {
    if (response.requestedName !== this.pendingLookupName) {
      // An address lookup or an older keystroke: not the name being validated.
    } else if (response.state === LookupNameState.NOT_FOUND) {
      this.usernameValidationStatus.onNext(UsernameValidationStatus.VALID);
    } else if (response.state === LookupNameState.FOUND) {
      this.usernameValidationStatus.onNext(UsernameValidationStatus.ALREADY_TAKEN);
    } else if (response.state === LookupNameState.INVALID_NAME ||
      response.state === LookupNameState.ERROR) {
      this.usernameValidationStatus.onNext(UsernameValidationStatus.INVALID);
    } else {
      hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'Lookup name error');
    }

    if (response.state === LookupNameState.FOUND && response.address.length > 0 &&
      response.name.length > 0) {
      this.resolvedNames.set(response.address, response.name);
    }
    this.usernameLookupStatus.onNext(response);
  }

  /**
   * Swift `internal func nameRegistrationEnded(with response: NameRegistrationResponse)`.
   *
   * THE ONE DELIBERATE OMISSION. Swift's success branch merged `response.name` into
   * `UserDefaults[registeredNamesKey]` (NameService.swift:158-163). The derived module contract
   * marks that key `disabled` / `no-reader-derived`: this method is its only writer and no reader
   * exists anywhere in the app (`AccountsService.accountInfoToShare` dropped its fallback read
   * for the same reason). A `@ohos.data.preferences` write with no consumer is inert state, so
   * the key is not written. The registered name itself is not lost - it reaches every consumer
   * through the event published below, which is what the app actually subscribes to.
   */
  nameRegistrationEnded(response: NameRegistrationResponse): void {
    if (response.state === NameRegistrationState.SUCCESS) {
      this.log(`Registered name: ${response.name.length === 0 ? 'no name' : response.name}`);
    } else {
      this.log(`Name Registration failed. State = ${response.state as string}`);
    }
    const event: ServiceEvent = new ServiceEvent(ServiceEventType.NAME_REGISTRATION_ENDED);
    event.addEventInput(ServiceEventInput.STATE, response.state as string);
    event.addEventInput(ServiceEventInput.ACCOUNT_ID, response.accountId);
    event.addEventInput(ServiceEventInput.NAME, response.name);
    this.registrationStatus.onNext(event);
  }

  /**
   * Swift `internal func userSearchEnded(with response: UserSearchResponse)` - every state is
   * forwarded to the stream; only the log level differs, exactly as in the source.
   */
  userSearchEnded(response: UserSearchResponse): void {
    switch (response.state) {
      case UserSearchState.FOUND:
        this.userSearchResponseStream.onNext(response);
        break;
      case UserSearchState.INVALID_NAME:
        this.userSearchResponseStream.onNext(response);
        hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'User search invalid name');
        break;
      case UserSearchState.NOT_FOUND:
        this.userSearchResponseStream.onNext(response);
        hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', 'User search not found');
        break;
      case UserSearchState.ERROR:
        this.userSearchResponseStream.onNext(response);
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'User search error');
        break;
      default:
        hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', 'User search unknown default');
        break;
    }
  }
}
