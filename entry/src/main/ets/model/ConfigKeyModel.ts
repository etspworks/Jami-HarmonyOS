/*
 * Ported from Ring/Ring/Models/ConfigKeyModel.swift:21-172 (GPL-3.0, Savoir-faire Linux Inc.).
 *
 * The daemon account-configuration keys and the key wrapper the account screens use.
 * Pure key table - every value behind a key comes from the jami daemon.
 */

/** Swift `enum ConfigKey: String` - the raw values are the daemon's own detail keys. */
export enum ConfigKey {
  MAILBOX = 'Account.mailbox',
  REGISTRATION_EXPIRE = 'Account.registrationExpire',
  CREDENTIAL_NUMBER = 'Credential.count',
  ACCOUNT_DTMF_TYPE = 'Account.dtmfType',
  RINGTONE_PATH = 'Account.ringtonePath',
  RINGTONE_ENABLED = 'Account.ringtoneEnabled',
  KEEP_ALIVE_ENABLED = 'Account.keepAliveEnabled',
  LOCAL_INTERFACE = 'Account.localInterface',
  ALLOW_IP_AUTO_REWRITE = 'Account.allowIPAutoRewrite',
  PUBLISHED_SAME_AS_LOCAL = 'Account.publishedSameAsLocal',
  LOCAL_PORT = 'Account.localPort',
  PUBLISHED_PORT = 'Account.publishedPort',
  PUBLISHED_ADDRESS = 'Account.publishedAddress',
  STUN_SERVER = 'STUN.server',
  STUN_ENABLE = 'STUN.enable',
  TURN_SERVER = 'TURN.server',
  TURN_ENABLE = 'TURN.enable',
  TURN_USERNAME = 'TURN.username',
  TURN_PASSWORD = 'TURN.password',
  TURN_REALM = 'TURN.realm',
  AUDIO_PORT_MIN = 'Account.audioPortMin',
  AUDIO_PORT_MAX = 'Account.audioPortMax',
  ACCOUNT_USER_AGENT = 'Account.useragent',
  ACCOUNT_UPNP_ENABLED = 'Account.upnpEnabled',
  ACCOUNT_ROUTE_SET = 'Account.routeset',
  ACCOUNT_AUTO_ANSWER = 'Account.autoAnswer',
  ACCOUNT_ALIAS = 'Account.alias',
  ACCOUNT_HOSTNAME = 'Account.hostname',
  ACCOUNT_USERNAME = 'Account.username',
  ACCOUNT_PASSWORD = 'Account.password',
  ACCOUNT_REALM = 'Account.realm',
  ACCOUNT_TYPE = 'Account.type',
  ACCOUNT_ENABLE = 'Account.enable',
  ACCOUNT_ACTIVE = 'Account.active',
  ACCOUNT_DEVICE_ID = 'Account.deviceID',
  VIDEO_ENABLED = 'Account.videoEnabled',
  VIDEO_PORT_MIN = 'Account.videoPortMin',
  VIDEO_PORT_MAX = 'Account.videoPortMax',
  PRESENCE_ENABLED = 'Account.presenceEnabled',
  ARCHIVE_PASSWORD = 'Account.archivePassword',
  ARCHIVE_PIN = 'Account.archivePIN',
  ARCHIVE_PATH = 'Account.archivePath',
  ARCHIVE_URL = 'Account.archiveURL',
  DISPLAY_NAME = 'Account.displayName',
  ETH_ACCOUNT = 'ETH.account',
  TLS_LISTENER_PORT = 'TLS.listenerPort',
  TLS_ENABLE = 'TLS.enable',
  TLS_CA_LIST_FILE = 'TLS.certificateListFile',
  TLS_PRIVATE_KEY_FILE = 'TLS.privateKeyFile',
  TLS_PASSWORD = 'TLS.password',
  TLS_METHOD = 'TLS.method',
  TLS_CIPHERS = 'TLS.ciphers',
  TLS_SERVER_NAME = 'TLS.serverName',
  TLS_VERIFY_SERVER = 'TLS.verifyServer',
  TLS_VERIFY_CLIENT = 'TLS.verifyClient',
  TLS_REQUIRE_CLIENT_CERTIFICATE = 'TLS.requireClientCertificate',
  TLS_NEGOCIATION_TIMEOUT_SEC = 'TLS.negotiationTimeoutSec',
  DISABLE_SECURE_DLG_CHECK = 'TLS.disableSecureDlgCheck',
  ACCOUNT_REGISTERED_NAME = 'Account.registeredName',
  ACCOUNT_REGISTRATION_STATUS = 'Account.registrationStatus',
  ACCOUNT_REGISTRATION_STATE_CODE = 'Account.registrationCode',
  ACCOUNT_REGISTRATION_STATE_DESC = 'Account.registrationDescription',
  SRTP_ENABLE = 'SRTP.enable',
  SRTP_KEY_EXCHANGE = 'SRTP.keyExchange',
  SRTP_ENCRYPTION_ALGO = 'SRTP.encryptionAlgorithm',
  SRTP_RTP_FALLBACK = 'SRTP.rtpFallback',
  RING_NS_ACCOUNT = 'RingNS.account',
  RING_NS_HOST = 'RingNS.host',
  DHT_PORT = 'DHT.port',
  DHT_PUBLIC_IN = 'DHT.PublicInCalls',
  ACCOUNT_ALLOW_CERT_FROM_HISTORY = 'Account.allowCertFromHistory',
  ACCOUNT_ALLOW_CERT_FROM_TRUSTED = 'Account.allowCertFromTrusted',
  ACCOUNT_ALLOW_CERT_FROM_CONTACT = 'Account.allowCertFromContact',
  ACCOUNT_HAS_CUSTOM_USER_AGENT = 'Account.hasCustomUserAgent',
  ACCOUNT_ACTIVE_CALL_LIMIT = 'Account.activeCallLimit',
  TLS_CERTIFICATE_FILE = 'TLS.certificateFile',
  RING_NS_URI = 'RingNS.uri',
  ACCOUNT_PRESENCE_SUBSCRIBE_SUPPORTED = 'Account.presenceSubscribeSupported',
  ACCOUNT_DEVICE_NAME = 'Account.deviceName',
  PROXY_ENABLED = 'Account.proxyEnabled',
  PROXY_LIST_ENABLED = 'Account.proxyListEnabled',
  PROXY_SERVER = 'Account.proxyServer',
  DHT_PROXY_LIST_URL = 'Account.dhtProxyListUrl',
  DEVICE_PUSH_TOKEN = 'Account.proxyPushToken',
  ARCHIVE_HAS_PASSWORD = 'Account.archiveHasPassword',
  DHT_PEER_DISCOVERY = 'Account.peerDiscovery',
  ACCOUNT_PEER_DISCOVERY = 'Account.accountDiscovery',
  ACCOUNT_PUBLISH = 'Account.accountPublish',
  MANAGER_URI = 'Account.managerUri',
  MANAGER_USERNAME = 'Account.managerUsername',
  TYPING_INDICATOR = 'Account.sendComposing',}

/** Every ConfigKey member, in declaration order. Needed because ArkTS has no enum reflection. */
export const ALL_CONFIG_KEYS: ConfigKey[] = [
  ConfigKey.MAILBOX,
  ConfigKey.REGISTRATION_EXPIRE,
  ConfigKey.CREDENTIAL_NUMBER,
  ConfigKey.ACCOUNT_DTMF_TYPE,
  ConfigKey.RINGTONE_PATH,
  ConfigKey.RINGTONE_ENABLED,
  ConfigKey.KEEP_ALIVE_ENABLED,
  ConfigKey.LOCAL_INTERFACE,
  ConfigKey.ALLOW_IP_AUTO_REWRITE,
  ConfigKey.PUBLISHED_SAME_AS_LOCAL,
  ConfigKey.LOCAL_PORT,
  ConfigKey.PUBLISHED_PORT,
  ConfigKey.PUBLISHED_ADDRESS,
  ConfigKey.STUN_SERVER,
  ConfigKey.STUN_ENABLE,
  ConfigKey.TURN_SERVER,
  ConfigKey.TURN_ENABLE,
  ConfigKey.TURN_USERNAME,
  ConfigKey.TURN_PASSWORD,
  ConfigKey.TURN_REALM,
  ConfigKey.AUDIO_PORT_MIN,
  ConfigKey.AUDIO_PORT_MAX,
  ConfigKey.ACCOUNT_USER_AGENT,
  ConfigKey.ACCOUNT_UPNP_ENABLED,
  ConfigKey.ACCOUNT_ROUTE_SET,
  ConfigKey.ACCOUNT_AUTO_ANSWER,
  ConfigKey.ACCOUNT_ALIAS,
  ConfigKey.ACCOUNT_HOSTNAME,
  ConfigKey.ACCOUNT_USERNAME,
  ConfigKey.ACCOUNT_PASSWORD,
  ConfigKey.ACCOUNT_REALM,
  ConfigKey.ACCOUNT_TYPE,
  ConfigKey.ACCOUNT_ENABLE,
  ConfigKey.ACCOUNT_ACTIVE,
  ConfigKey.ACCOUNT_DEVICE_ID,
  ConfigKey.VIDEO_ENABLED,
  ConfigKey.VIDEO_PORT_MIN,
  ConfigKey.VIDEO_PORT_MAX,
  ConfigKey.PRESENCE_ENABLED,
  ConfigKey.ARCHIVE_PASSWORD,
  ConfigKey.ARCHIVE_PIN,
  ConfigKey.ARCHIVE_PATH,
  ConfigKey.ARCHIVE_URL,
  ConfigKey.DISPLAY_NAME,
  ConfigKey.ETH_ACCOUNT,
  ConfigKey.TLS_LISTENER_PORT,
  ConfigKey.TLS_ENABLE,
  ConfigKey.TLS_CA_LIST_FILE,
  ConfigKey.TLS_PRIVATE_KEY_FILE,
  ConfigKey.TLS_PASSWORD,
  ConfigKey.TLS_METHOD,
  ConfigKey.TLS_CIPHERS,
  ConfigKey.TLS_SERVER_NAME,
  ConfigKey.TLS_VERIFY_SERVER,
  ConfigKey.TLS_VERIFY_CLIENT,
  ConfigKey.TLS_REQUIRE_CLIENT_CERTIFICATE,
  ConfigKey.TLS_NEGOCIATION_TIMEOUT_SEC,
  ConfigKey.DISABLE_SECURE_DLG_CHECK,
  ConfigKey.ACCOUNT_REGISTERED_NAME,
  ConfigKey.ACCOUNT_REGISTRATION_STATUS,
  ConfigKey.ACCOUNT_REGISTRATION_STATE_CODE,
  ConfigKey.ACCOUNT_REGISTRATION_STATE_DESC,
  ConfigKey.SRTP_ENABLE,
  ConfigKey.SRTP_KEY_EXCHANGE,
  ConfigKey.SRTP_ENCRYPTION_ALGO,
  ConfigKey.SRTP_RTP_FALLBACK,
  ConfigKey.RING_NS_ACCOUNT,
  ConfigKey.RING_NS_HOST,
  ConfigKey.DHT_PORT,
  ConfigKey.DHT_PUBLIC_IN,
  ConfigKey.ACCOUNT_ALLOW_CERT_FROM_HISTORY,
  ConfigKey.ACCOUNT_ALLOW_CERT_FROM_TRUSTED,
  ConfigKey.ACCOUNT_ALLOW_CERT_FROM_CONTACT,
  ConfigKey.ACCOUNT_HAS_CUSTOM_USER_AGENT,
  ConfigKey.ACCOUNT_ACTIVE_CALL_LIMIT,
  ConfigKey.TLS_CERTIFICATE_FILE,
  ConfigKey.RING_NS_URI,
  ConfigKey.ACCOUNT_PRESENCE_SUBSCRIBE_SUPPORTED,
  ConfigKey.ACCOUNT_DEVICE_NAME,
  ConfigKey.PROXY_ENABLED,
  ConfigKey.PROXY_LIST_ENABLED,
  ConfigKey.PROXY_SERVER,
  ConfigKey.DHT_PROXY_LIST_URL,
  ConfigKey.DEVICE_PUSH_TOKEN,
  ConfigKey.ARCHIVE_HAS_PASSWORD,
  ConfigKey.DHT_PEER_DISCOVERY,
  ConfigKey.ACCOUNT_PEER_DISCOVERY,
  ConfigKey.ACCOUNT_PUBLISH,
  ConfigKey.MANAGER_URI,
  ConfigKey.MANAGER_USERNAME,
  ConfigKey.TYPING_INDICATOR,];

function buildRawToKey(): Map<string, ConfigKey> {
  const map: Map<string, ConfigKey> = new Map<string, ConfigKey>();
  for (const key of ALL_CONFIG_KEYS) {
    map.set(String(key), key);
  }
  return map;
}

const RAW_TO_KEY: Map<string, ConfigKey> = buildRawToKey();

/** Swift `ConfigKey(rawValue:)` - null for a key this client does not know. */
export function configKeyFromRaw(raw: string): ConfigKey | null {
  const key: ConfigKey | undefined = RAW_TO_KEY.get(raw);
  return key === undefined ? null : key;
}

/**
 * Swift `ConfigKeyModel.twoStates` - the keys the settings screens render as a switch.
 * Declared once; the Swift source carried a copy on every instance.
 */
export const TWO_STATE_CONFIG_KEYS: ConfigKey[] = [
  ConfigKey.ACCOUNT_ENABLE,
  ConfigKey.VIDEO_ENABLED,
  ConfigKey.RINGTONE_ENABLED,
  ConfigKey.KEEP_ALIVE_ENABLED,
  ConfigKey.ALLOW_IP_AUTO_REWRITE,
  ConfigKey.PUBLISHED_SAME_AS_LOCAL,
  ConfigKey.STUN_ENABLE,
  ConfigKey.TURN_ENABLE,
  ConfigKey.ACCOUNT_AUTO_ANSWER,
  ConfigKey.ACCOUNT_UPNP_ENABLED
];

/** Swift `struct ConfigKeyModel: Hashable`. */
export class ConfigKeyModel {
  readonly key: ConfigKey;

  /** Swift `init(withKey:)`. */
  constructor(key: ConfigKey) {
    this.key = key;
  }

  /** Swift `let twoStates: [ConfigKey]`. */
  get twoStates(): ConfigKey[] {
    return TWO_STATE_CONFIG_KEYS;
  }

  /** Swift `func isTwoState() -> Bool`. */
  isTwoState(): boolean {
    return TWO_STATE_CONFIG_KEYS.indexOf(this.key) >= 0;
  }

  /** Swift `var twoState` accessor shorthand used by the settings rows. */
  get twoState(): boolean {
    return this.isTwoState();
  }

  /** Swift `static func == (lhs:rhs:)` - the key alone is the identity. */
  equals(other: ConfigKeyModel): boolean {
    return this.key === other.key;
  }

  /**
   * Swift `func hash(into:)`. ArkTS Map/Set key on reference identity for objects, so the
   * raw key string is what callers key a collection by.
   */
  hash(): string {
    return String(this.key);
  }
}
