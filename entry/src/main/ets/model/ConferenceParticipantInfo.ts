/*
 * Ported from Ring/Ring/Models/Calls/ConferenceParticipantInfo.swift:21-94, with the
 * `ConfInfoKey` table from Ring/Ring/Models/Calls/LibJamiCallConstants.swift
 * (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * One entry of libjami's `OnConferenceInfosUpdated` participant list. Every value is the
 * daemon's; an absent key stays empty/false/0.
 */

import { SinkId } from './SinkId';
import { filterOutHost, libJamiBool } from './CallDetails';

/** Swift `enum ConfInfoKey: String` - a case with no raw value uses its own name. */
export enum ConfInfoKey {
  URI = 'uri',
  DEVICE = 'device',
  SINK_ID = 'sinkId',
  ACTIVE = 'active',
  FRAME_X = 'x',
  FRAME_Y = 'y',
  FRAME_WIDTH = 'w',
  FRAME_HEIGHT = 'h',
  VIDEO_MUTED = 'videoMuted',
  AUDIO_LOCAL_MUTED = 'audioLocalMuted',
  AUDIO_MODERATOR_MUTED = 'audioModeratorMuted',
  IS_MODERATOR = 'isModerator',
  HAND_RAISED = 'handRaised',
  VOICE_ACTIVITY = 'voiceActivity',
  RECORDING = 'recording'
}

/** Swift `CGRect` - the participant's tile inside the conference frame. */
export interface ParticipantFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export class ConferenceParticipantInfo {
  uri: string = '';
  device: string = '';
  sinkId: SinkId = new SinkId('');
  isActive: boolean = false;
  frame: ParticipantFrame = { x: 0, y: 0, width: 0, height: 0 };
  isVideoMuted: boolean = false;
  isAudioLocallyMuted: boolean = false;
  isAudioModeratorMuted: boolean = false;
  isModerator: boolean = false;
  isHandRaised: boolean = false;
  hasVoiceActivity: boolean = false;
  isRecording: boolean = false;

  /** Swift `var id: String` - the sink id when libjami gave one, else uri|device. */
  get id(): string {
    return this.sinkId.raw.length === 0
      ? ConferenceParticipantInfo.id(this.uri, this.device)
      : this.sinkId.raw;
  }

  /** Swift `static func id(uri:device:)`. */
  static id(uri: string, device: string): string {
    return uri + '|' + device;
  }

  /**
   * Swift `static func latestPerStream(_:)`. Libjami may report an audio-only placeholder and
   * its replacement camera entry in one update; both describe one rendered stream when their
   * sink ids match, so the later entry replaces the earlier while the stream keeps its slot.
   */
  static latestPerStream(participants: ConferenceParticipantInfo[]): ConferenceParticipantInfo[] {
    const result: ConferenceParticipantInfo[] = [];
    const indexById: Map<string, number> = new Map<string, number>();
    for (const participant of participants) {
      const index: number | undefined = indexById.get(participant.id);
      if (index === undefined) {
        indexById.set(participant.id, result.length);
        result.push(participant);
      } else {
        result[index] = participant;
      }
    }
    return result;
  }

  /** Swift `func isLocalDevice(localJamiId:localDeviceId:isHostedLocally:)`. */
  isLocalDevice(localJamiId: string, localDeviceId: string, isHostedLocally: boolean): boolean {
    if (this.uri.length === 0) {
      return isHostedLocally;
    }
    return localJamiId.length > 0 && filterOutHost(this.uri) === localJamiId
      && (localDeviceId.length === 0 || this.device.length === 0 || this.device === localDeviceId);
  }

  /** Swift `func resolvedUri(localJamiId:peerUri:isHostedLocally:)`. */
  resolvedUri(localJamiId: string, peerUri: string, isHostedLocally: boolean): string {
    if (this.uri.length > 0) {
      return this.uri;
    }
    return isHostedLocally ? localJamiId : peerUri;
  }

  /** Swift `init?(_ dict: [String: String])` - null when libjami sent no `uri` key at all. */
  static fromDict(dict: Map<string, string>): ConferenceParticipantInfo | null {
    const uri: string | undefined = dict.get(String(ConfInfoKey.URI));
    if (uri === undefined) {
      return null;
    }
    const info: ConferenceParticipantInfo = new ConferenceParticipantInfo();
    info.uri = uri;
    info.device = ConferenceParticipantInfo.value(dict, ConfInfoKey.DEVICE);
    info.sinkId = new SinkId(ConferenceParticipantInfo.value(dict, ConfInfoKey.SINK_ID));
    info.isActive = ConferenceParticipantInfo.flag(dict, ConfInfoKey.ACTIVE);
    info.frame = {
      x: ConferenceParticipantInfo.dimension(dict, ConfInfoKey.FRAME_X),
      y: ConferenceParticipantInfo.dimension(dict, ConfInfoKey.FRAME_Y),
      width: ConferenceParticipantInfo.dimension(dict, ConfInfoKey.FRAME_WIDTH),
      height: ConferenceParticipantInfo.dimension(dict, ConfInfoKey.FRAME_HEIGHT)
    };
    info.isVideoMuted = ConferenceParticipantInfo.flag(dict, ConfInfoKey.VIDEO_MUTED);
    info.isAudioLocallyMuted = ConferenceParticipantInfo.flag(dict, ConfInfoKey.AUDIO_LOCAL_MUTED);
    info.isAudioModeratorMuted =
      ConferenceParticipantInfo.flag(dict, ConfInfoKey.AUDIO_MODERATOR_MUTED);
    info.isModerator = ConferenceParticipantInfo.flag(dict, ConfInfoKey.IS_MODERATOR);
    info.isHandRaised = ConferenceParticipantInfo.flag(dict, ConfInfoKey.HAND_RAISED);
    info.hasVoiceActivity = ConferenceParticipantInfo.flag(dict, ConfInfoKey.VOICE_ACTIVITY);
    info.isRecording = ConferenceParticipantInfo.flag(dict, ConfInfoKey.RECORDING);
    return info;
  }

  /** Swift's local `func value(_:)`, defaulted to "". */
  private static value(dict: Map<string, string>, key: ConfInfoKey): string {
    const raw: string | undefined = dict.get(String(key));
    return raw === undefined ? '' : raw;
  }

  /** Swift's local `func flag(_:)`. */
  private static flag(dict: Map<string, string>, key: ConfInfoKey): boolean {
    const parsed: boolean | null = libJamiBool(dict.get(String(key)));
    return parsed === null ? false : parsed;
  }

  /** Swift's local `func dimension(_:)`. */
  private static dimension(dict: Map<string, string>, key: ConfInfoKey): number {
    const raw: string | undefined = dict.get(String(key));
    if (raw === undefined) {
      return 0;
    }
    const parsed: number = Number.parseFloat(raw);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /** Swift `Hashable` - the rendered-stream identity. */
  equals(other: ConferenceParticipantInfo): boolean {
    return this.id === other.id;
  }

  hash(): string {
    return this.id;
  }
}
