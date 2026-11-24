/*
 * Ported from Ring/Ring/Models/Calls/CallDetails.swift:21-57, with the `CallDetailKey` table
 * and the libjami string helpers from Ring/Ring/Models/Calls/LibJamiCallConstants.swift and
 * Ring/Ring/Extensions/String+Helpers.swift (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The parsed form of one `getCallDetails` map. Every value comes from the jami daemon; an
 * absent key stays empty/false/null rather than being filled with a plausible default.
 */

import { LibJamiCallState, libJamiCallStateFromRaw } from './CallStatus';

/** Swift `enum CallDetailKey: String` - the keys of the `getCallDetails` dictionary. */
export enum CallDetailKey {
  CALL_TYPE = 'CALL_TYPE',
  PEER_NUMBER = 'PEER_NUMBER',
  REGISTERED_NAME = 'REGISTERED_NAME',
  DISPLAY_NAME = 'DISPLAY_NAME',
  CALL_STATE = 'CALL_STATE',
  CONF_ID = 'CONF_ID',
  TIMESTAMP_START = 'TIMESTAMP_START',
  TO_USERNAME = 'TO_USERNAME',
  ACCOUNT_ID = 'ACCOUNTID',
  PEER_HOLD = 'PEER_HOLD',
  AUDIO_MUTED = 'AUDIO_MUTED',
  VIDEO_MUTED = 'VIDEO_MUTED',
  VIDEO_SOURCE = 'VIDEO_SOURCE',
  AUDIO_ONLY = 'AUDIO_ONLY',
  AUDIO_CODEC = 'AUDIO_CODEC',
  VIDEO_CODEC = 'VIDEO_CODEC'
}

/**
 * Swift `extension Bool { init?(libJamiString:) }` - parses libjami's boolean encodings.
 * Null for anything else, so a caller can tell "absent" from "false".
 */
export function libJamiBool(value: string | undefined): boolean | null {
  if (value === undefined) {
    return null;
  }
  const lowered: string = value.toLowerCase();
  if (lowered === 'true' || lowered === '1' || lowered === 'yes') {
    return true;
  }
  if (lowered === 'false' || lowered === '0' || lowered === 'no') {
    return false;
  }
  return null;
}

/** Swift `extension Bool { var libJamiString }`. */
export function boolToLibJamiString(value: boolean): string {
  return value ? 'true' : 'false';
}

/** Swift `extension String { func filterOutHost() }`. */
export function filterOutHost(value: string): string {
  return value.replace(new RegExp('@ring\\.dht', 'g'), '');
}

/** Swift `extension String { func toBool() -> Bool? }`. */
export function stringToBool(value: string): boolean | null {
  return libJamiBool(value);
}

export class CallDetails {
  peerNumber: string = '';
  registeredName: string = '';
  displayName: string = '';
  /** Null when libjami sent no `CALL_STATE`, or one this client does not know. */
  state: LibJamiCallState | null = null;
  /** Swift: null when the call is not part of a conference (libjami sends ""). */
  conferenceId: string | null = null;
  startedAt: Date | null = null;
  accountId: string = '';
  peerHold: boolean = false;
  audioMuted: boolean = false;
  videoMuted: boolean = false;
  isAudioOnly: boolean = false;
  audioCodec: string = '';
  videoCodec: string = '';

  /** Swift `var confId` - the conference id as libjami sent it, empty when standalone. */
  get confId(): string {
    return this.conferenceId === null ? '' : this.conferenceId;
  }

  /** Swift `init(_ dict: [String: String])`. */
  static fromDict(dict: Map<string, string>): CallDetails {
    const details: CallDetails = new CallDetails();
    details.peerNumber = CallDetails.value(dict, CallDetailKey.PEER_NUMBER);
    details.registeredName = CallDetails.value(dict, CallDetailKey.REGISTERED_NAME);
    details.displayName = CallDetails.value(dict, CallDetailKey.DISPLAY_NAME);

    const rawState: string | undefined = dict.get(String(CallDetailKey.CALL_STATE));
    details.state = rawState === undefined ? null : libJamiCallStateFromRaw(rawState);

    const confId: string = CallDetails.value(dict, CallDetailKey.CONF_ID);
    details.conferenceId = confId.length === 0 ? null : confId;

    const rawStart: string | undefined = dict.get(String(CallDetailKey.TIMESTAMP_START));
    if (rawStart !== undefined) {
      const seconds: number = Number.parseFloat(rawStart);
      if (!Number.isNaN(seconds) && seconds > 0) {
        details.startedAt = new Date(seconds * 1000);
      }
    }

    details.accountId = CallDetails.value(dict, CallDetailKey.ACCOUNT_ID);
    details.peerHold = CallDetails.flag(dict, CallDetailKey.PEER_HOLD);
    details.audioMuted = CallDetails.flag(dict, CallDetailKey.AUDIO_MUTED);
    details.videoMuted = CallDetails.flag(dict, CallDetailKey.VIDEO_MUTED);
    details.isAudioOnly = CallDetails.flag(dict, CallDetailKey.AUDIO_ONLY);
    details.audioCodec = CallDetails.value(dict, CallDetailKey.AUDIO_CODEC);
    details.videoCodec = CallDetails.value(dict, CallDetailKey.VIDEO_CODEC);
    return details;
  }

  /** Swift's local `func value(_ key: CallDetailKey) -> String?`, defaulted to "". */
  private static value(dict: Map<string, string>, key: CallDetailKey): string {
    const raw: string | undefined = dict.get(String(key));
    return raw === undefined ? '' : raw;
  }

  /** Swift `Bool(libJamiString: value(key)) ?? false`. */
  private static flag(dict: Map<string, string>, key: CallDetailKey): boolean {
    const parsed: boolean | null = libJamiBool(dict.get(String(key)));
    return parsed === null ? false : parsed;
  }
}
