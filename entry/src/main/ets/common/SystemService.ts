/*
 * Ported from Ring/Ring/Services/SystemService.swift:24-53 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The daemon log monitor behind Settings -> "Enable log" / the log viewer.
 *
 *   LOCAL (real, fully working) - the monitoring flag, the accumulated log buffer, the
 *   per-line relay every log screen binds to, and the two guards around them (`messageReceived`
 *   drops a line while monitoring is off; `clearLog` only clears while off, or when forced).
 *
 *   DAEMON (a gap) - turning the log on. Swift's `systemAdapter.triggerLog(_:)`
 *   (Ring/Ring/Bridging/SystemAdapter.h:31) forwards into the prebuilt jami daemon, whose
 *   source is not on disk, so per Rule 11 there is nothing to port: the flag still toggles -
 *   that half is the app's own state - and the daemon half resolves through `DaemonService`
 *   to an explicit "not available on this platform" notice. No fabricated log lines.
 *
 * `SystemAdapter.delegate = self` has no counterpart: with no daemon there is no push channel.
 * `messageReceived` stays PUBLIC so a bridge - or a test - can drive it the moment one exists.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BehaviorRelay } from './Observable';
import { ServiceRegistry } from './ServiceRegistry';
import { jami } from './JamiNative';
import { DaemonService } from './DaemonService';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SystemService';

export class SystemService {
  /** Swift `var newMessage = BehaviorRelay(value: "")` - the latest log line, for the viewer. */
  readonly newMessage: BehaviorRelay<string> = new BehaviorRelay<string>('');

  /** Swift `var currentLog = ""` - everything received since monitoring started. */
  currentLog: string = '';

  /** Swift `var isMonitoring = BehaviorRelay(value: false)` - what the toggle binds to. */
  readonly isMonitoring: BehaviorRelay<boolean> = new BehaviorRelay<boolean>(false);

  /**
   * Swift `private let systemAdapter: SystemAdapter` - the Objective-C++ bridge into the jami
   * daemon. No counterpart here (see the header), so the field becomes the gap surface.
   * Read from the registry inside a body, never in the constructor.
   */
  private get systemAdapter(): DaemonService {
    return ServiceRegistry.shared().daemonService;
  }

  /**
   * Swift `triggerLog()` - flips the flag, then tells the daemon. The flip is the app's own
   * state and runs for real; the daemon half is the gap, reported (not thrown) because the
   * caller is a toggle with nothing to unwind.
   */
  triggerLog(): void {
    this.isMonitoring.accept(!this.isMonitoring.value);
    // libjami streams its log lines back through MessageSend while monitoring.
    jami.monitor(this.isMonitoring.value);
  }

  /** Swift `clearLog(force:)` - clears only while monitoring is off, unless forced. */
  clearLog(force: boolean = false): void {
    if (!this.isMonitoring.value || force) {
      this.currentLog = '';
      this.newMessage.accept('');
    }
  }

  /**
   * Swift `@objc func messageReceived(message:)` - the `SystemAdapterDelegate` callback. Pure
   * local bookkeeping, ported literally; nothing calls it today (no daemon push channel).
   */
  messageReceived(message: string): void {
    if (!this.isMonitoring.value) {
      return;
    }
    this.currentLog += '\n' + message;
    this.newMessage.accept(message);
    hilog.debug(LOG_DOMAIN, LOG_TAG, 'log line received');
  }
}
