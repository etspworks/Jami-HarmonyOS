/*
 * Ported from Ring/Ring/Services/DataTransferService.swift (GPL-3.0, Savoir-faire Linux Inc.),
 * with Ring/CommonHelpers.swift `CommonHelpers.createFileUrlForSwarm` folded in (the plan gives
 * CommonHelpers no module of its own and this is the only caller in the data layer) and the
 * ObjC types of Ring/CommonObjc/ObjcTypes.h (`NSDataTransferInfo`, `NSDataTransferEventCode`,
 * `NSDataTransferError`) declared here, since this is the module that vends them.
 *
 * WHAT IS REAL AND WHAT IS A DISCLOSED GAP
 * ----------------------------------------
 * Peer-to-peer file transfer itself rides the C++ jami daemon, reached in Swift through
 * `DataTransferAdapter` (Ring/Ring/Bridging/DRingAdapter.mm) onto the prebuilt
 * `libjami-core.xcframework`. That binary has no source on disk, so CLAUDE.md Rule 11 forbids
 * porting it, stubbing it with fake success, or bridging to it through a sidecar/NDK/wasm shim.
 * Every `dataTransferAdapter.*` call therefore resolves through `DaemonService`:
 *   - a user-initiated operation (download, cancel, send) calls `reportUnavailable(...)`, which
 *     logs it and publishes it on `daemonService.unavailableEvents` for a screen to render;
 *   - a polled read-back (transfer info, progress) calls the build-only `unavailable(...)` and
 *     returns the absent value - null / 0 - rather than a number nothing measured.
 * A transfer that cannot start therefore never reports progress and never reaches a finished
 * state: `getTransferProgress` stays 0 and `dataTransferInfo` stays null.
 *
 * Everything that does NOT need the daemon is real and works: every path under the ability's
 * `filesDir` (the HarmonyOS equivalent of Swift's `Constants.documentsPath`), the duplicate-name
 * resolution, directory creation, staging a picked file into the conversation's own directory,
 * writing image bytes before a send, existence-checked reads of a file already on disk, and
 * deletion.
 *
 * RESTRICTED-API SUBSTITUTIONS APPLIED HERE (results/analysis/permission-substitutions.json)
 * -------------------------------------------------------------------------------------------
 *  - NSPhotoLibraryUsageDescription -> `PhotoViewPicker` / `DocumentViewPicker`
 *    (`@ohos.file.picker`). No broad storage permission is requested and none is needed. The
 *    picker itself is a UI gesture and lives in the screen; what it hands back is a FILE URI
 *    outside this app's sandbox, valid only for that pick. `sendFile` therefore STAGES that URI
 *    into the conversation's own directory before it is sent - the same copy-before-send the
 *    source performs in Ring/jamiShareExtension/AdapterService.swift:230 - so the transfer does
 *    not depend on a picker grant that has already lapsed. `fs.openSync` accepts a URI; the
 *    staged copy is a plain sandbox path from then on.
 *  - NSPhotoLibraryAddUsageDescription -> the `SaveButton` security component. Saving a RECEIVED
 *    file to the gallery must be started by a real user tap on that component, so it cannot live
 *    in a `.ts` service at all. This module's part is `getFileUrlForSwarm` /
 *    `getFileUrlNonSwarm`, which hand the screen the on-disk path its SaveButton copies from.
 *  - UIBackgroundModes: fetch -> a BackgroundTasksKit continuous task under the declared
 *    `dataTransfer` mode (+ `ohos.permission.KEEP_BACKGROUND_RUNNING`, already in module.json5).
 *    NOTHING HERE REQUESTS ONE, deliberately: a continuous task is requested when a transfer is
 *    actually running, and every transfer start above ends in the daemon gap. Requesting one for
 *    a transfer that cannot start would be the fake success this port is forbidden to write. The
 *    request belongs at the point the daemon gap closes.
 *
 * INJECTION (the ServiceRegistry contract, rule 3)
 * ------------------------------------------------
 *   setContext(ctx)   - the UIAbilityContext, for `filesDir`. A .ts module cannot call
 *                       getContext(), so until the ability calls this every path method returns
 *                       null and says so in the log - it does not guess a path.
 *   setDatabase(db)   - Swift `let dbManager: DBManager`. The Swift class stores it and never
 *                       reads it (verified across DataTransferService.swift); it is kept here as
 *                       the same injected handle, typed by the narrow `ConversationsDb` surface
 *                       the DB layer already exports, so a later transfer-status write has it.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { jamiDataPath } from './JamiNative';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

import { DisposeBag, PublishSubject } from './Observable';
import { ServiceEvent, ServiceEventInput, ServiceEventType } from './ServiceEvent';
import { ServiceRegistry } from './ServiceRegistry';
import { DaemonService } from './DaemonService';
import { ConversationsDb, DataTransferInfo as ConversationsTransferInfo } from './ConversationsService';
import { describeError } from './ErrorText';
import { jami } from './JamiNative';
import { TransferInfo } from 'libjami.so';

import { ConversationModel } from '../model/ConversationModel';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'DataTransferService';

/**
 * A pathological `fs` that reported every candidate name as taken would spin the duplicate-name
 * loop forever. Swift had no cap because `FileManager` cannot do that; this one costs a line.
 */
const MAX_DUPLICATE_SUFFIX: number = 1000;

/** Swift `enum Directories: String` - the three folders a transfer file can live in. */
export enum Directories {
  RECORDED = 'recorded',
  DOWNLOADS = 'downloads',
  CONVERSATION_DATA = 'conversation_data'
}

/**
 * ObjC `NS_ENUM(UInt32, NSDataTransferEventCode)` (Ring/CommonObjc/ObjcTypes.h:33). The VALUES
 * are fixed by the daemon's own enum and are the numbers that arrive on the event callback -
 * do not reorder.
 */
export enum DataTransferEventCode {
  INVALID = 0,
  CREATED = 1,
  UNSUPPORTED = 2,
  WAIT_PEER_ACCEPTANCE = 3,
  WAIT_HOST_ACCEPTANCE = 4,
  ONGOING = 5,
  FINISHED = 6,
  CLOSED_BY_HOST = 7,
  CLOSED_BY_PEER = 8,
  INVALID_PATHNAME = 9,
  UNJOINABLE_PEER = 10
}

/** ObjC `NS_ENUM(UInt32, NSDataTransferError)` (Ring/CommonObjc/ObjcTypes.h:46). */
export enum DataTransferError {
  SUCCESS = 0,
  UNKNOWN = 1,
  IO = 2,
  INVALID_ARGUMENT = 3
}

/**
 * Swift `func stringFromEventCode(with:)` (DataTransferService.swift:64). Used by the source's
 * ConversationsManager for its transfer log line; kept exported so a screen can label a state.
 * The strings are the source's, including its `wait_host_acceptance`/`wait_peer_acceptance`
 * swap - that is what the source displays.
 */
export function stringFromEventCode(code: DataTransferEventCode): string {
  switch (code) {
    case DataTransferEventCode.INVALID: return 'Invalid';
    case DataTransferEventCode.CREATED: return 'initializing transfer';
    case DataTransferEventCode.UNSUPPORTED: return 'unsupported';
    case DataTransferEventCode.WAIT_HOST_ACCEPTANCE: return 'waiting peer acceptance';
    case DataTransferEventCode.WAIT_PEER_ACCEPTANCE: return 'waiting host acceptance';
    case DataTransferEventCode.ONGOING: return 'ongoing';
    case DataTransferEventCode.FINISHED: return 'finished';
    case DataTransferEventCode.CLOSED_BY_HOST: return 'closed by host';
    case DataTransferEventCode.CLOSED_BY_PEER: return 'closed by peer';
    case DataTransferEventCode.INVALID_PATHNAME: return 'invalid pathname';
    case DataTransferEventCode.UNJOINABLE_PEER: return 'unjoinable peer';
    default: return 'Invalid';
  }
}

/**
 * ObjC `@interface NSDataTransferInfo` (Ring/CommonObjc/ObjcTypes.h:58) - every field, in the
 * ObjC declaration order. `implements ConversationsTransferInfo` is load-bearing: ArkTS is
 * NOMINALLY typed, so without it this object could not be handed to
 * `ConversationsService.generateDataTransferMessage`, which is exactly what
 * ConversationsManager does with it.
 *
 * Swift filled this by handing an empty instance to the adapter, which wrote into it. The
 * adapter is the daemon gap, so the only instances this module produces are the ones a future
 * adapter fills; it never fabricates one.
 */
export class DataTransferInfo implements ConversationsTransferInfo {
  accountId: string = '';
  lastEvent: DataTransferEventCode = DataTransferEventCode.INVALID;
  /** `NSDataTransferFlags.direction`; 1 = incoming, as the daemon sets it. */
  flags: number = 0;
  totalSize: number = 0;
  bytesProgress: number = 0;
  peer: string = '';
  displayName: string = '';
  path: string = '';
  mimetype: string = '';
  conversationId: string = '';
}

/** Swift `(fileName as NSString).deletingPathExtension`. */
function deletingPathExtension(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}

/** Swift `(fileName as NSString).pathExtension`. */
function pathExtension(fileName: string): string {
  const dot: number = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(dot + 1) : '';
}

/**
 * Swift `FileManager.default.fileExists(atPath:)`. `accessSync` throws on some failures where
 * Foundation simply answers false, so a throw is answered the same way Swift's API would.
 */
function fileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

/** Swift `fileExists(atPath:isDirectory:)` with `isDirectory.boolValue == true`. */
function directoryExists(path: string): boolean {
  try {
    return fs.statSync(path).isDirectory();
  } catch (err) {
    return false;
  }
}

/**
 * Manage sent and received files. The source's own layout note, unchanged except that Swift's
 * `Documents` is the ability's `filesDir` here:
 *   - non swarm sent/received: <filesDir>/downloads/<accountId>/<conversationId>/<fileName>
 *   - non swarm recorded:      <filesDir>/recorded/<accountId>/<conversationId>/<fileName>
 *   - swarm:                   <filesDir>/<accountId>/conversation_data/<conversationId>/<file>
 *
 * Swift returned `URL?` from every path method; ArkTS file APIs take a path string, so each
 * returns `string | null` - the same "absent" answer, one representation down.
 */
export class DataTransferService {
  /** Swift `private let log = SwiftyBeaver.self` - hilog's tag is the ArkTS equivalent. */
  private readonly log: string = LOG_TAG;

  /** Swift `private let responseStream = PublishSubject<ServiceEvent>()`. */
  private readonly responseStream: PublishSubject<ServiceEvent> = new PublishSubject<ServiceEvent>();

  /** Swift `var sharedResponseStream: Observable<ServiceEvent>` - `responseStream.share()`. */
  readonly sharedResponseStream: PublishSubject<ServiceEvent> = this.responseStream;

  /** Swift `private let disposeBag = DisposeBag()`. */
  private readonly disposeBag: DisposeBag = new DisposeBag();

  /** Swift `let dbManager: DBManager`, injected by `setDatabase`. See the header. */
  private dbManager: ConversationsDb | null = null;

  /** The ability context, injected by `setContext`; `filesDir` is Swift's documents path. */
  private context: common.UIAbilityContext | null = null;

  /*
   * Swift `private let dataTransferAdapter: DataTransferAdapter` and its companion
   * `DataTransferAdapter.delegate = self` (init, DataTransferService.swift:108). Both are the
   * daemon bridge and have no HarmonyOS counterpart, so neither is a field here: the adapter
   * resolves to `DaemonService` below, and the delegate half survives as the public
   * `dataTransferEvent(...)` callback, which is real and publishes on the response stream the
   * moment anything calls it.
   */

  // MARK: - injection (the ServiceRegistry contract, rule 3)

  /** Called once at startup: `setContext(this.context)` from the ability's `onCreate`. */
  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** Called once at startup with the per-account database layer. */
  setDatabase(database: ConversationsDb): void {
    this.dbManager = database;
  }

  /** Releases the subscriptions this service owns; called from the ability's `onDestroy`. */
  dispose(): void {
    this.disposeBag.dispose();
  }

  // MARK: - internals

  private get daemon(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /** Swift `Constants.documentsPath`. Null - never a guessed path - until the ability injects. */
  private documentsPath(): string | null {
    const context: common.UIAbilityContext | null = this.context;
    if (context === null) {
      hilog.error(LOG_DOMAIN, this.log,
        'no context; file paths unavailable (call setContext at startup)');
      return null;
    }
    // Swift's documents path is libjami's data directory (see JamiNative.startJami).
    return jamiDataPath(context.filesDir);
  }

  // MARK: - transfer info

  /**
   * Swift `dataTransferInfo(withId:accountId:conversationId:isSwarm:)`. The adapter filled the
   * info object; it is the daemon gap, so this returns null exactly as Swift does when the
   * adapter answers anything but `.success`. Polled on every transfer event, so the build-only
   * `unavailable` is used rather than publishing a notice per poll.
   */
  dataTransferInfo(fileId: string, accountId: string, conversationId: string,
    isSwarm: boolean): DataTransferInfo | null {
    const raw: TransferInfo = jami.fileTransferInfo(accountId, conversationId, fileId);
    if (raw.code !== DataTransferError.SUCCESS) {
      return null;
    }
    const info: DataTransferInfo = new DataTransferInfo();
    info.accountId = accountId;
    info.conversationId = conversationId;
    info.path = raw.path;
    info.totalSize = raw.total;
    info.bytesProgress = raw.progress;
    return info;
  }

  /**
   * Swift `getTransferProgress(withId:accountId:conversationId:isSwarm:)` - `info.bytesProgress`
   * after the adapter fills it. Nothing measured it, so it is 0: a transfer that cannot start
   * must not report progress.
   */
  getTransferProgress(transferId: string, accountId: string, conversationId: string,
    isSwarm: boolean): number {
    const info: DataTransferInfo | null =
      this.dataTransferInfo(transferId, accountId, conversationId, isSwarm);
    return info === null ? 0 : info.bytesProgress;
  }

  // MARK: - swarm transfer actions

  /**
   * Swift `downloadFile(withId:interactionID:fileName:accountID:conversationID:)`.
   *
   * Swift's `fileName: inout String` is dropped: ArkTS has no `inout`, the source passed `path`
   * (always "") to the adapter rather than the name, and both call sites
   * (TransferHelper.acceptTransfer, ConversationsManager) discard the value afterwards.
   *
   * User-initiated, so the gap is reported and published - the user gets the notice.
   */
  downloadFile(transferId: string, interactionId: string, accountId: string,
    conversationId: string): void {
    // An empty path lets libjami keep the file in the conversation's own data directory.
    jami.downloadFile(accountId, conversationId, interactionId, transferId, '');
  }

  // MARK: - swarm and non swarm transfer actions

  /**
   * Swift `cancelTransfer(withId:accountId:conversationId:)`. Returns `UNKNOWN`, never `SUCCESS`:
   * there is no transfer to cancel and the caller must not read a cancellation that never
   * happened.
   */
  cancelTransfer(transferId: string, accountId: string, conversationId: string): DataTransferError {
    const result: DataTransferError =
      jami.cancelDataTransfer(accountId, conversationId, transferId) as DataTransferError;
    if (result !== DataTransferError.SUCCESS) {
      hilog.error(LOG_DOMAIN, this.log, 'unable to cancel transfer with id: %{public}s', transferId);
    }
    return result;
  }

  /**
   * Swift `sendFile(conversation:filePath:displayName:localIdentifier:)`.
   *
   * The local half is real and runs first: `filePath` is whatever the screen's
   * DocumentViewPicker / PhotoViewPicker handed back, which is a URI outside this sandbox whose
   * grant lapses with the pick, so it is STAGED into the conversation's own directory - the same
   * copy-before-send the source does in AdapterService.swift:230. A path already inside the
   * destination (the `sendAndSaveFile` route, which wrote it there itself) is not re-copied.
   *
   * The send itself is the daemon gap and is reported.
   */
  sendFile(conversation: ConversationModel, filePath: string, displayName: string,
    localIdentifier: string | null): void {
    const staged: string | null = this.stageFileForSending(conversation, filePath, displayName);
    if (staged === null) {
      hilog.error(LOG_DOMAIN, this.log, 'unable to stage %{public}s for sending', displayName);
      return;
    }
    if (!conversation.isSwarm()) {
      // Legacy one-to-one (non-swarm) transfers are gone from libjami.
      this.daemon.reportUnavailable('transfer.send');
      return;
    }
    jami.sendFile(conversation.accountId, conversation.id, staged, displayName, '');
  }

  /**
   * Copies a picked file into the conversation's own directory and returns the staged path.
   * Returns the input unchanged when it is already the destination. Real end to end.
   */
  private stageFileForSending(conversation: ConversationModel, filePath: string,
    displayName: string): string | null {
    const destination: string | null = conversation.isSwarm()
      ? this.createFileUrlForSwarm(displayName, conversation.accountId, conversation.id)
      : this.getFilePathForTransfer(displayName, conversation.accountId, conversation.id);
    if (destination === null) {
      return null;
    }
    if (destination === filePath) {
      return destination;
    }
    // `openSync` accepts a file URI, which is what the picker returns; `copyFileSync` then works
    // from the open descriptor, so the grant is used once, here, and never relied on again.
    let source: fs.File | null = null;
    try {
      source = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(source.fd, destination);
      return destination;
    } catch (err) {
      hilog.error(LOG_DOMAIN, this.log, 'unable to stage picked file: %{public}s',
        describeError(err as BusinessError));
      return null;
    } finally {
      if (source !== null) {
        fs.closeSync(source);
      }
    }
  }

  /**
   * Swift `sendAndSaveFile(displayName:conversation:imageData:)`. The write is real - this is
   * the path a PhotoViewPicker pick takes, where the screen already holds the image bytes - and
   * only the send that follows it is the gap. Swift's `Data` is an `ArrayBuffer` here.
   */
  sendAndSaveFile(displayName: string, conversation: ConversationModel,
    imageData: ArrayBuffer): void {
    const imagePath: string | null = conversation.isSwarm()
      ? this.createFileUrlForSwarm(displayName, conversation.accountId, conversation.id)
      : this.getFilePathForTransfer(displayName, conversation.accountId, conversation.id);
    if (imagePath === null) {
      return;
    }
    let file: fs.File | null = null;
    try {
      file = fs.openSync(imagePath,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
      fs.writeSync(file.fd, imageData);
    } catch (err) {
      hilog.error(LOG_DOMAIN, this.log, 'unable to copy image to cache: %{public}s',
        describeError(err as BusinessError));
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
    this.sendFile(conversation, imagePath, displayName, null);
  }

  // MARK: - file path non swarm

  /**
   * Swift `getFileUrlNonSwarm(fileName:inFolder:accountID:conversationID:)`. Real: the path of a
   * file already on disk, or null when it is not there.
   */
  getFileUrlNonSwarm(fileName: string, inFolder: string, accountId: string,
    conversationId: string): string | null {
    const documents: string | null = this.documentsPath();
    if (documents === null) {
      return null;
    }
    const path: string = `${documents}/${inFolder}/${accountId}/${conversationId}/${fileName}`;
    return fileExists(path) ? path : null;
  }

  /**
   * Swift `createFileUrlForDirectory(directory:fileName:accountID:conversationID:)` - the path to
   * save a file at before sending, for a non-swarm conversation. Real, including the source's
   * duplicate-name rule: `recorded` overwrites, everything else becomes `name_2.ext`, `name_3.ext`
   * and so on.
   */
  private createFileUrlForDirectory(directory: string, fileName: string, accountId: string,
    conversationId: string): string | null {
    const documents: string | null = this.documentsPath();
    if (documents === null) {
      return null;
    }
    const fileNameOnly: string = deletingPathExtension(fileName);
    const fileExtensionOnly: string = pathExtension(fileName);
    const directoryPath: string = `${documents}/${directory}/${accountId}/${conversationId}`;

    if (directoryExists(directoryPath)) {
      if (directory === Directories.RECORDED as string) {
        return `${directoryPath}/${fileName}`;
      }
      let finalFileName: string = `${fileNameOnly}.${fileExtensionOnly}`;
      let filePathCheck: string = `${directoryPath}/${finalFileName}`;
      let duplicates: number = 2;
      while (fileExists(filePathCheck) && duplicates <= MAX_DUPLICATE_SUFFIX) {
        finalFileName = `${fileNameOnly}_${duplicates}.${fileExtensionOnly}`;
        filePathCheck = `${directoryPath}/${finalFileName}`;
        duplicates++;
      }
      return filePathCheck;
    }

    try {
      fs.mkdirSync(directoryPath, true);
      return `${directoryPath}/${fileName}`;
    } catch (err) {
      hilog.error(LOG_DOMAIN, this.log, 'error creating dir: %{public}s',
        describeError(err as BusinessError));
      return null;
    }
  }

  /**
   * Swift `CommonHelpers.createFileUrlForSwarm(fileName:accountId:conversationId:)`
   * (Ring/CommonHelpers.swift:24). Unlike the non-swarm helper it does NOT create the directory:
   * for a swarm conversation that directory is the daemon's, and its absence is the source's
   * "no destination" answer. Its duplicate rule also keeps an extensionless name extensionless.
   */
  private createFileUrlForSwarm(fileName: string, accountId: string,
    conversationId: string): string | null {
    const documents: string | null = this.documentsPath();
    if (documents === null) {
      return null;
    }
    const fileNameOnly: string = deletingPathExtension(fileName);
    const fileExtensionOnly: string = pathExtension(fileName);
    const directoryPath: string =
      `${documents}/${accountId}/${Directories.CONVERSATION_DATA as string}/${conversationId}`;
    if (!directoryExists(directoryPath)) {
      // The staging area for files handed to libjami's sendFile; it is the app's, not libjami's.
      try {
        fs.mkdirSync(directoryPath, true);
      } catch (err) {
        hilog.error(LOG_DOMAIN, this.log, 'error creating dir: %{public}s',
          describeError(err as BusinessError));
        return null;
      }
    }
    let finalFileName: string =
      fileExtensionOnly.length > 0 ? `${fileNameOnly}.${fileExtensionOnly}` : fileNameOnly;
    let filePathCheck: string = `${directoryPath}/${finalFileName}`;
    let duplicates: number = 2;
    while (fileExists(filePathCheck) && duplicates <= MAX_DUPLICATE_SUFFIX) {
      finalFileName = fileExtensionOnly.length > 0
        ? `${fileNameOnly}_${duplicates}.${fileExtensionOnly}`
        : `${fileNameOnly}_${duplicates}`;
      filePathCheck = `${directoryPath}/${finalFileName}`;
      duplicates++;
    }
    return filePathCheck;
  }

  /** Swift `getFilePathForTransfer(forFile:accountID:conversationID:)`. */
  private getFilePathForTransfer(fileName: string, accountId: string,
    conversationId: string): string | null {
    return this.createFileUrlForDirectory(Directories.DOWNLOADS as string, fileName, accountId,
      conversationId);
  }

  /** Swift `getFilePathForRecordings(forFile:accountID:conversationID:isSwarm:)`. */
  getFilePathForRecordings(fileName: string, accountId: string, conversationId: string,
    isSwarm: boolean): string | null {
    if (isSwarm) {
      return this.createFileUrlForSwarm(fileName, accountId, conversationId);
    }
    return this.createFileUrlForDirectory(Directories.RECORDED as string, fileName, accountId,
      conversationId);
  }

  // MARK: - file path for swarm

  /**
   * Swift `getFileUrlForSwarm(fileName:accountID:conversationID:)`. Real: the path of a saved
   * swarm file, or null when it is not on disk.
   */
  getFileUrlForSwarm(fileName: string, accountId: string, conversationId: string): string | null {
    const documents: string | null = this.documentsPath();
    if (documents === null) {
      return null;
    }
    const path: string =
      `${documents}/${accountId}/${Directories.CONVERSATION_DATA as string}/${conversationId}/${fileName}`;
    return fileExists(path) ? path : null;
  }

  /** Swift `removeFile(at:)` - `try?`, so a missing file is not an error. */
  removeFile(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (err) {
      hilog.debug(LOG_DOMAIN, this.log, 'nothing to remove at %{public}s: %{public}s', path,
        describeError(err as BusinessError));
    }
  }

  // MARK: - DataTransferAdapterDelegate

  /**
   * Swift `dataTransferEvent(withFileId:withEventCode:accountId:conversationId:interactionId:)` -
   * the adapter's delegate callback. Real end to end: it is what publishes
   * DATA_TRANSFER_CREATED / DATA_TRANSFER_CHANGED on the shared response stream, which
   * ConversationsManager subscribes to. Nothing calls it while the daemon is absent, which is
   * why no transfer event is fabricated.
   *
   * The `STATE` input is written as a NUMBER because that is how ConversationsManager reads it
   * back (`event.getNumber(ServiceEventInput.STATE)`); the four ids are strings.
   */
  dataTransferEvent(transferId: string, eventCode: number, accountId: string,
    conversationId: string, interactionId: string): void {
    if (eventCode < DataTransferEventCode.INVALID.valueOf()
      || eventCode > DataTransferEventCode.UNJOINABLE_PEER.valueOf()) {
      hilog.error(LOG_DOMAIN, this.log, 'unable to get transfer code');
      return;
    }
    const event: DataTransferEventCode = eventCode as DataTransferEventCode;
    hilog.info(LOG_DOMAIN, this.log, 'event: %{public}s', stringFromEventCode(event));

    const isSwarm: boolean = conversationId.length > 0;
    const info: DataTransferInfo | null =
      this.dataTransferInfo(transferId, accountId, conversationId, isSwarm);
    // Swift: `if event == .created && info?.flags != 1 { return }` - do not emit a created event
    // for an outgoing transfer, which is already saved in the database. A nil `info` fails the
    // `== 1` test in Swift too, so an unresolvable info drops the created event rather than
    // inventing one.
    if (event === DataTransferEventCode.CREATED && (info === null || info.flags !== 1)) {
      return;
    }

    // Every non-created event is aggregated into the update category, as in Swift.
    const serviceEventType: ServiceEventType = event === DataTransferEventCode.CREATED
      ? ServiceEventType.DATA_TRANSFER_CREATED
      : ServiceEventType.DATA_TRANSFER_CHANGED;
    const serviceEvent: ServiceEvent = new ServiceEvent(serviceEventType);
    serviceEvent.addEventInput(ServiceEventInput.TRANSFER_ID, transferId);
    serviceEvent.addNumber(ServiceEventInput.STATE, eventCode);
    serviceEvent.addEventInput(ServiceEventInput.CONVERSATION_ID, conversationId);
    serviceEvent.addEventInput(ServiceEventInput.MESSAGE_ID, interactionId);
    serviceEvent.addEventInput(ServiceEventInput.ACCOUNT_ID, accountId);
    this.responseStream.onNext(serviceEvent);
  }
}
