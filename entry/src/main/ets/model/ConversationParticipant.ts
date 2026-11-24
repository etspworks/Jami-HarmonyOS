/*
 * Ported from Ring/Ring/Models/ConversationModel.swift:105-147 (ConversationParticipant) and
 * Ring/CommonHelpers.swift:237-261 (ParticipantRole) - GPL-3.0, Savoir-faire Linux Inc.
 *
 * Participant data itself comes from the jami daemon (swarm member list); this module only
 * models and parses it.
 */

/** Swift `enum ParticipantRole: String`. Raw values are the daemon's own role strings. */
export enum ParticipantRole {
  ADMIN = 'admin',
  MEMBER = 'member',
  INVITED = 'invited',
  BANNED = 'banned',
  LEFT = 'left',
  UNKNOWN = 'unknown'
}

/** Swift `ParticipantRole(rawValue:)` - null when the daemon sent an unknown role string. */
export function parseParticipantRole(raw: string): ParticipantRole | null {
  switch (raw) {
    case 'admin': return ParticipantRole.ADMIN;
    case 'member': return ParticipantRole.MEMBER;
    case 'invited': return ParticipantRole.INVITED;
    case 'banned': return ParticipantRole.BANNED;
    case 'left': return ParticipantRole.LEFT;
    case 'unknown': return ParticipantRole.UNKNOWN;
    default: return null;
  }
}

/** Swift `ParticipantRole.isActive`. */
export function participantRoleIsActive(role: ParticipantRole): boolean {
  return role === ParticipantRole.ADMIN || role === ParticipantRole.MEMBER ||
    role === ParticipantRole.INVITED;
}

/**
 * Swift `ParticipantRole.stringValue` returned an L10n string; here it returns the name of the
 * string resource, which the UI resolves through `$r('app.string.<name>')`.
 */
export function participantRoleLabelResource(role: ParticipantRole): string {
  switch (role) {
    case ParticipantRole.ADMIN: return 'swarm_admin';
    case ParticipantRole.MEMBER: return 'swarm_member';
    case ParticipantRole.INVITED: return 'swarm_invited';
    case ParticipantRole.BANNED: return 'swarm_blocked';
    case ParticipantRole.LEFT: return 'swarm_left';
    default: return 'swarm_unknown';
  }
}

/** Keys of the daemon's member info map (`swarmMemberInfo`). */
const INFO_KEY_URI: string = 'uri';
const INFO_KEY_ROLE: string = 'role';
const INFO_KEY_LAST_DISPLAYED: string = 'lastDisplayed';

export class ConversationParticipant {
  jamiId: string = '';
  role: ParticipantRole = ParticipantRole.MEMBER;
  lastDisplayed: string = '';
  isLocal: boolean = false;

  /** Swift `init(jamiId:)` / `init(jamiId:isLocal:)`. */
  constructor(jamiId: string = '', isLocal: boolean = false) {
    this.jamiId = ConversationParticipant.stripUriPrefix(jamiId);
    this.isLocal = isLocal;
  }

  /** Swift `private static func stripUriPrefix(_:)`. */
  private static stripUriPrefix(uri: string): string {
    return uri
      .replace(new RegExp('ring:', 'g'), '')
      .replace(new RegExp('jami:', 'g'), '');
  }

  /** Swift `init(info:isLocal:)`. */
  static fromInfo(info: Map<string, string>, isLocal: boolean): ConversationParticipant {
    const participant: ConversationParticipant = new ConversationParticipant();
    participant.isLocal = isLocal;
    const uri: string | undefined = info.get(INFO_KEY_URI);
    if (uri !== undefined && uri.length > 0) {
      participant.jamiId = ConversationParticipant.stripUriPrefix(uri);
    }
    const role: string | undefined = info.get(INFO_KEY_ROLE);
    if (role !== undefined) {
      const parsed: ParticipantRole | null = parseParticipantRole(role);
      if (parsed !== null) {
        participant.role = parsed;
      }
    }
    const lastRead: string | undefined = info.get(INFO_KEY_LAST_DISPLAYED);
    if (lastRead !== undefined) {
      participant.lastDisplayed = lastRead;
    }
    return participant;
  }

  /** Swift `static func == (lhs:rhs:)` - identity is the jami id alone. */
  equals(other: ConversationParticipant): boolean {
    return this.jamiId === other.jamiId;
  }

  /** Swift `func hash(into:)` - the value to key a Set/Map by. */
  hash(): string {
    return this.jamiId;
  }
}
