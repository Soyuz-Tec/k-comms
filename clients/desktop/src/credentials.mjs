import { mkdir, lstat, readFile, writeFile, rename, rm, chmod } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { MAX_CREDENTIAL_BYTES, secureStorageAvailable, validateReplacement, validateCredential, credentialIdentity } from './policy.mjs';

export class CredentialVault {
  constructor({ storage, platform, directory, origin, onIdentityChanged = () => {}, filesystem = { mkdir, lstat, readFile, writeFile, rename, rm, chmod } }) {
    this.fs = filesystem;
    this.storage = storage; this.platform = platform; this.directory = directory; this.origin = origin; this.onIdentityChanged = onIdentityChanged;
    this.state = { generation: 0, kind: null, value: null }; this.queue = Promise.resolve();
    this.filename = path.join(directory, 'credentials.v1.enc');
  }
  available() { return secureStorageAvailable(this.storage, this.platform); }
  snapshot() { return structuredClone(this.state); }
  requireEncryption() { if (!this.available()) throw new Error('OS credential storage unavailable'); }
  async load() {
    this.requireEncryption();
    await this.fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
    const info = await this.fs.lstat(this.directory);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Invalid credential directory');
    if (this.platform !== 'win32') await this.fs.chmod(this.directory, 0o700);
    try {
      const file = await this.fs.lstat(this.filename);
      if (!file.isFile() || file.isSymbolicLink() || file.size > MAX_CREDENTIAL_BYTES + 4096 || (this.platform !== 'win32' && (file.mode & 0o077) !== 0)) throw new Error('Unsafe credential file');
      const plaintext = this.storage.decryptString(await this.fs.readFile(this.filename));
      if (Buffer.byteLength(plaintext) > MAX_CREDENTIAL_BYTES) throw new Error('Credential file exceeds bound');
      const saved = JSON.parse(plaintext);
      if (saved.version !== 1 || saved.origin !== this.origin || !['member', 'guest'].includes(saved.kind)) throw new Error('Credential origin does not match');
      this.state = { generation: 0, kind: saved.kind, value: validateCredential(saved.value, saved.kind) };
    } catch (error) {
      this.state = { generation: 0, kind: null, value: null };
      if (error.code !== 'ENOENT') await this.fs.rm(this.filename, { force: true });
    }
    return this.snapshot();
  }
  replace(raw) {
    const next = validateReplacement(raw);
    if (next.kind !== null) this.requireEncryption();
    if (next.generation <= this.state.generation) throw new Error('Stale credential generation');
    const identityChanged = credentialIdentity(next) !== credentialIdentity(this.state);
    // Accept generations synchronously, so a late older write cannot revive
    // logout or change the current media identity while filesystem work waits.
    this.state = next;
    if (identityChanged || next.kind === null) this.onIdentityChanged();
    const operation = this.queue.catch(() => {}).then(async () => {
      if (this.state.generation !== next.generation) return;
      if (next.kind === null) { await this.fs.rm(this.filename, { force: true }); return; }
      this.requireEncryption();
      const sealed = this.storage.encryptString(JSON.stringify({ version: 1, origin: this.origin, kind: next.kind, value: next.value }));
      const temporary = path.join(this.directory, '.credential-' + randomUUID());
      try {
        await this.fs.writeFile(temporary, sealed, { flag: 'wx', mode: 0o600 });
        if (this.state.generation === next.generation) await this.fs.rename(temporary, this.filename);
      } finally { await this.fs.rm(temporary, { force: true }); }
    }).catch(async () => {
      // Storage failure is final for this generation; no plaintext fallback.
      if (this.state.generation === next.generation) { this.state = { generation: next.generation, kind: null, value: null }; this.onIdentityChanged(); await this.fs.rm(this.filename, { force: true }); }
      throw new Error('Encrypted credential update failed');
    });
    this.queue = operation;
    return operation.then(() => ({ generation: this.state.generation }));
  }
}
