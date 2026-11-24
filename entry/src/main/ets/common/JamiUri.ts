/*
 * Ported from Ring/Ring/Helpers/JamiURI.swift (GPL-3.0, Savoir-faire Linux Inc.).
 * Pure parsing/formatting of jami: / ring: / sip: URIs - no daemon access.
 */

export enum UriType {
  JAMI = 'jami',
  RING = 'ring',
  SIP = 'sip',
  UNRECOGNIZED = ''
}

const URI_PATTERN: RegExp = new RegExp('^\\s*(\\w+:)?(?:([\\w.]+)@)?([\\d\\w.\\-]+)?(?::(\\d+))?\\s*$', 'i');
const HEX_ID_PATTERN: RegExp = new RegExp('^[0-9a-fA-F]{40}$', 'i');

function group(match: RegExpExecArray, index: number): string {
  const value: string | undefined = match[index];
  return value === undefined ? '' : value;
}

export function uriTypeFromScheme(scheme: string | null): UriType {
  if (scheme === null) {
    return UriType.UNRECOGNIZED;
  }
  const normalized: string = scheme.toLowerCase().replace(new RegExp(':', 'g'), '');
  if (normalized === 'jami') {
    return UriType.JAMI;
  }
  if (normalized === 'ring') {
    return UriType.RING;
  }
  if (normalized === 'sip') {
    return UriType.SIP;
  }
  return UriType.UNRECOGNIZED;
}

export function isJamiUriType(type: UriType): boolean {
  return type === UriType.JAMI || type === UriType.RING;
}

export class JamiUri {
  schema: UriType = UriType.UNRECOGNIZED;
  userInfo: string = '';
  hostname: string = '';
  port: string = '';

  /** `init(schema:)` - an empty URI of a known schema. */
  static withSchema(schema: UriType): JamiUri {
    const uri: JamiUri = new JamiUri();
    uri.schema = schema;
    return uri;
  }

  /**
   * `init(schema:infoHash:account:)` - parses `infoHash` and re-labels it with `schema`.
   * The Swift initializer read the SIP fallbacks off `account.details`; the account model lives
   * behind the daemon bridge, so the caller passes the two values it already holds.
   */
  static fromInfoHash(schema: UriType, infoHash: string, fallbackHostname: string = '',
                      fallbackPort: string = ''): JamiUri {
    const parsed: JamiUri = JamiUri.parse(infoHash);
    const uri: JamiUri = new JamiUri();
    uri.schema = schema;
    uri.userInfo = parsed.userInfo;
    uri.hostname = parsed.hostname;
    uri.port = parsed.port;
    if (schema === UriType.SIP) {
      if (uri.hostname.length === 0) {
        uri.hostname = fallbackHostname;
      }
      if (uri.port.length === 0) {
        uri.port = fallbackPort;
      }
    }
    return uri;
  }

  /** `init(from:)` */
  static parse(uriString: string): JamiUri {
    const normalizedUri: string = uriString
      .replace(new RegExp('<', 'g'), '')
      .replace(new RegExp('>', 'g'), '')
      .replace(new RegExp('@ring\\.dht', 'g'), '')
      .trim();

    const uri: JamiUri = new JamiUri();
    const match: RegExpExecArray | null = URI_PATTERN.exec(normalizedUri);
    if (match === null) {
      uri.schema = UriType.UNRECOGNIZED;
      uri.userInfo = normalizedUri;
      return uri;
    }

    const scheme: string = group(match, 1);
    uri.schema = uriTypeFromScheme(scheme.length === 0 ? null : scheme);
    uri.userInfo = group(match, 2);
    uri.hostname = group(match, 3);
    uri.port = group(match, 4);

    const bareHost: boolean = uri.userInfo.length === 0 && uri.hostname.length > 0;
    if (bareHost && (isJamiUriType(uri.schema) || uri.schema === UriType.UNRECOGNIZED)) {
      uri.userInfo = uri.hostname;
      uri.hostname = '';
    }
    return uri;
  }

  get isHexId(): boolean {
    return HEX_ID_PATTERN.test(this.userInfo);
  }

  get isJami(): boolean {
    return isJamiUriType(this.schema) || (this.schema === UriType.UNRECOGNIZED && this.isHexId);
  }

  get hash(): string | null {
    return this.userInfo.length === 0 ? null : this.userInfo;
  }

  get uriString(): string | null {
    if (this.userInfo.length === 0) {
      return null;
    }
    if (isJamiUriType(this.schema) || (this.schema === UriType.UNRECOGNIZED && this.isHexId)) {
      return 'jami:' + this.userInfo;
    }
    if (this.schema === UriType.SIP) {
      let result: string = 'sip:' + this.userInfo;
      if (this.hostname.length > 0) {
        result += '@' + this.hostname;
        if (this.port.length > 0) {
          result += ':' + this.port;
        }
      }
      return result;
    }
    return null;
  }
}

/** `extension ProfileType { init(uri:) }` - a jami URI is a RING profile, anything else SIP. */
export function profileTypeForUri(uri: string): string {
  return JamiUri.parse(uri).isJami ? 'RING' : 'SIP';
}
