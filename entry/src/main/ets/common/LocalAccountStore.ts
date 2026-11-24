/*
 * Jami accounts created on the device without the jami daemon.
 *
 * What the daemon does at creation that can be done here for real: generate the RSA identity,
 * derive the Jami ID from it (opendht `PublicKey::getId()` = SHA-1 of the DER public key) and
 * register a username on the name server with the same signed request the daemon sends
 * (ArchiveAccountManager::registerName -> NameDirectory::registerName). Everything else an
 * account does (DHT, calls, messages) still needs the daemon.
 *
 * ponytail: keys are kept unencrypted in the app sandbox (filesDir) and the archive password is
 * ignored; encrypt with the password via cryptoFramework AES when local accounts outlive testing.
 * ponytail: RSA-2048, not the daemon's 4096 - 4096 generation blocks the UI for several seconds.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LocalAccountStore';
const STORE_FILE: string = 'local_accounts.json';
export const DEFAULT_NAME_SERVER: string = 'https://ns.jami.net';

export interface LocalAccount {
  accountId: string;
  jamiId: string;
  displayName: string;
  registeredName: string;
  /** Base64 DER: X.509 SubjectPublicKeyInfo / PKCS#8. */
  publicKey: string;
  privateKey: string;
  /** 40 hex chars, the name server's `owner` field. */
  owner: string;
}

/** Outcome of a name registration, by the daemon's NameDirectory status mapping. */
export enum LocalRegistration {
  SUCCESS = 'SUCCESS',
  INVALID_NAME = 'INVALID_NAME',
  ALREADY_TAKEN = 'ALREADY_TAKEN',
  ERROR = 'ERROR'
}

const base64: util.Base64Helper = new util.Base64Helper();

function toHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  }
  return out;
}

function randomHex(byteCount: number): string {
  const random: cryptoFramework.Random = cryptoFramework.createRandom();
  return toHex(random.generateRandomSync(byteCount).data);
}

/** opendht `PublicKey::toString()`: the PEM of the SubjectPublicKeyInfo. */
function publicKeyPem(der: Uint8Array): string {
  const b64: string = base64.encodeToStringSync(der);
  const lines: string[] = [];
  for (let i: number = 0; i < b64.length; i += 64) {
    lines.push(b64.substring(i, i + 64));
  }
  return '-----BEGIN PUBLIC KEY-----\n' + lines.join('\n') + '\n-----END PUBLIC KEY-----\n';
}

/** NameDirectory::registerName's HTTP status -> outcome. */
export function registrationForHttpCode(code: number): LocalRegistration {
  if (code >= 200 && code <= 299) {
    return LocalRegistration.SUCCESS;
  }
  if (code === 409 || code === 403) {
    return LocalRegistration.ALREADY_TAKEN;
  }
  if (code === 400) {
    return LocalRegistration.INVALID_NAME;
  }
  return LocalRegistration.ERROR;
}

export class LocalAccountStore {
  private filesDir: string = '';
  private accounts: LocalAccount[] = [];

  setFilesDir(path: string): void {
    this.filesDir = path;
    this.load();
  }

  ids(): string[] {
    return this.accounts.map((account: LocalAccount): string => account.accountId);
  }

  get(accountId: string): LocalAccount | null {
    for (const account of this.accounts) {
      if (account.accountId === accountId) {
        return account;
      }
    }
    return null;
  }

  /** The daemon's account detail map for a local account. */
  details(account: LocalAccount): Map<string, string> {
    const details: Map<string, string> = new Map<string, string>();
    details.set('Account.type', 'RING');
    details.set('Account.username', account.jamiId);
    details.set('Account.enable', 'true');
    details.set('Account.alias', account.displayName);
    details.set('Account.displayName', account.displayName);
    return details;
  }

  /** The daemon's volatile detail map: registered name and status. */
  volatileDetails(account: LocalAccount): Map<string, string> {
    const details: Map<string, string> = new Map<string, string>();
    details.set('Account.registeredName', account.registeredName);
    details.set('Account.registrationStatus', 'REGISTERED');
    return details;
  }

  async create(displayName: string): Promise<LocalAccount> {
    const generator: cryptoFramework.AsyKeyGenerator =
      cryptoFramework.createAsyKeyGenerator('RSA2048|PRIMES_2');
    const keyPair: cryptoFramework.KeyPair = await generator.generateKeyPair();
    const publicDer: Uint8Array = keyPair.pubKey.getEncoded().data;
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA1');
    await md.update({ data: publicDer });
    const account: LocalAccount = {
      accountId: randomHex(8),
      jamiId: toHex((await md.digest()).data),
      displayName: displayName,
      registeredName: '',
      publicKey: base64.encodeToStringSync(publicDer),
      privateKey: base64.encodeToStringSync(keyPair.priKey.getEncoded().data),
      owner: randomHex(20)
    };
    this.accounts.push(account);
    this.save();
    return account;
  }

  remove(accountId: string): void {
    this.accounts = this.accounts.filter((account: LocalAccount): boolean => account.accountId !== accountId);
    this.save();
  }

  /** `POST <server>/name/<name>` with the daemon's body, signed RSA/SHA-512 over the name. */
  async registerName(accountId: string, name: string, nameserver: string): Promise<LocalRegistration> {
    const account: LocalAccount | null = this.get(accountId);
    if (account === null) {
      return LocalRegistration.ERROR;
    }
    const lowerName: string = name.toLowerCase();
    try {
      const converter: cryptoFramework.AsyKeyGenerator =
        cryptoFramework.createAsyKeyGenerator('RSA2048|PRIMES_2');
      const keyPair: cryptoFramework.KeyPair = await converter.convertKey(
        { data: base64.decodeSync(account.publicKey) }, { data: base64.decodeSync(account.privateKey) });
      const signer: cryptoFramework.Sign = cryptoFramework.createSign('RSA2048|PKCS1|SHA512');
      await signer.init(keyPair.priKey);
      const signature: cryptoFramework.DataBlob =
        await signer.sign({ data: new util.TextEncoder().encodeInto(lowerName) });
      const body: string = JSON.stringify({
        addr: account.jamiId,
        owner: account.owner,
        signature: base64.encodeToStringSync(signature.data),
        publickey: base64.encodeToStringSync(
          new util.TextEncoder().encodeInto(publicKeyPem(base64.decodeSync(account.publicKey))))
      });
      const server: string = (nameserver.length > 0 ? nameserver : DEFAULT_NAME_SERVER).replace(/\/+$/, '');
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(
          `${server}/name/${encodeURIComponent(lowerName)}`, {
            method: http.RequestMethod.POST,
            header: { 'Content-Type': 'application/json' },
            extraData: body,
            readTimeout: 15000,
            connectTimeout: 15000
          });
        const outcome: LocalRegistration = registrationForHttpCode(response.responseCode);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'registerName %{public}s -> %{public}d', lowerName,
          response.responseCode);
        if (outcome === LocalRegistration.SUCCESS) {
          account.registeredName = lowerName;
          this.save();
        }
        return outcome;
      } finally {
        request.destroy();
      }
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'registerName failed: %{public}s', (error as Error).message);
      return LocalRegistration.ERROR;
    }
  }

  private path(): string {
    return this.filesDir + '/' + STORE_FILE;
  }

  private load(): void {
    try {
      if (fileIo.accessSync(this.path())) {
        this.accounts = JSON.parse(fileIo.readTextSync(this.path())) as LocalAccount[];
      }
    } catch (error) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'load failed: %{public}s', (error as Error).message);
    }
  }

  private save(): void {
    if (this.filesDir.length === 0) {
      return;
    }
    const file: fileIo.File = fileIo.openSync(this.path(),
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, JSON.stringify(this.accounts));
    } finally {
      fileIo.closeSync(file);
    }
  }
}

export const localAccountStore: LocalAccountStore = new LocalAccountStore();
