import { randomUUID } from 'node:crypto';
import { lstat, open, rename, unlink } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import type { Executor } from './database.js';
import type { Owner } from './domain.js';
import { describeConnection } from './import-status.js';
import { parseInstance, RETRY_REQUEST_SUFFIX } from './schedule.js';

/**
 * "Retry import" on Bank connections, the dashboard's half.
 *
 * A bank import that fails for a reason the scheduler cannot classify latches
 * its connection: `<instance>.blocked` in the scheduler's state directory, and
 * every later timer run answers `blocked` without touching the bank until a
 * person removes the file. That directory is mounted into the worker alone, by
 * design — the web process must never be able to make a bank call happen —
 * and until this existed the only remedy was deleting the latch over SSH
 * (Revolut, 20 October 2026, after a single HTTP 400 the bank never repeated).
 *
 * So the dashboard asks the way a renewed approval does: it leaves a file in
 * the consent directory, the one directory both containers share, and the
 * scheduler compares that file's time with the latch on its next run, lifts
 * the latch when the request is the newer, and makes exactly one attempt. The
 * request is consumed either way; a run that fails again latches afresh, so
 * the button is one attempt per press, never a loop. The import itself still
 * runs only where the timer runs it, and only with its own gates.
 *
 * Who may press it: the member whose connection it is, or the administrator.
 * When: only while `bank_sync_runs.retry_reason` says `blocked`, which is the
 * scheduler's own announcement of the latch. Every press is an audit event.
 */
export type ImportRetryCode =
  | 'invalid_connection'
  | 'not_your_connection'
  | 'not_stopped'
  | 'retry_directory_unsafe';

export class ImportRetryError extends Error {
  constructor(readonly code: ImportRetryCode) {
    super(code);
  }
}

export type ImportRetryState = {
  connection: string;
  /** The scheduler has latched this connection for a person. */
  importStopped: boolean;
  /** A request is waiting for the next timer run. */
  retryQueued: boolean;
};

/** `enablebanking:rodion:revolut` is the timer instance `enablebanking-rodion-revolut`. */
export function connectionInstance(connection: string): string {
  const described = describeConnection(connection);
  if (described.unrecognised || !described.owner)
    throw new ImportRetryError('invalid_connection');
  const instance =
    described.provider === 'monobank'
      ? `monobank-${described.owner}`
      : `enablebanking-${described.owner}-${described.bank}`;
  try {
    parseInstance(instance);
  } catch {
    throw new ImportRetryError('invalid_connection');
  }
  return instance;
}

export class ImportRetryRequests {
  constructor(
    private readonly db: Executor,
    private readonly directory: string,
  ) {
    if (!isAbsolute(directory)) throw new Error('retry_directory_relative');
  }

  private marker(connection: string): string {
    return join(
      this.directory,
      `${connectionInstance(connection)}${RETRY_REQUEST_SUFFIX}`,
    );
  }

  /** What the screen shows for each of a member's connections. */
  async status(connections: string[]): Promise<ImportRetryState[]> {
    const stopped = new Set(
      (
        await this.db.query(
          "SELECT connection FROM bank_sync_runs WHERE retry_reason='blocked'",
        )
      ).rows.map((row) => String(row.connection)),
    );
    return Promise.all(
      connections.map(async (connection) => ({
        connection,
        importStopped: stopped.has(connection),
        retryQueued: await this.queued(connection),
      })),
    );
  }

  private async queued(connection: string): Promise<boolean> {
    try {
      return (await lstat(this.marker(connection))).isFile();
    } catch {
      return false;
    }
  }

  /**
   * Leaves the request for the scheduler and records who made it. A request
   * repeated while one is waiting refreshes its time, which is what the owner
   * means by pressing again after another failure has latched the bank anew.
   */
  async request(actor: Owner, connection: string, admin = false) {
    const described = describeConnection(connection);
    const marker = this.marker(connection);
    if (described.owner !== actor && !admin)
      throw new ImportRetryError('not_your_connection');
    const run = await this.db.query(
      'SELECT retry_reason FROM bank_sync_runs WHERE connection=$1',
      [connection],
    );
    if (run.rows[0]?.retry_reason !== 'blocked')
      throw new ImportRetryError('not_stopped');
    const directory = await lstat(this.directory);
    if (
      !directory.isDirectory() ||
      directory.isSymbolicLink() ||
      (directory.mode & 0o022) !== 0 ||
      (process.getuid !== undefined && directory.uid !== process.getuid())
    )
      throw new ImportRetryError('retry_directory_unsafe');
    // Written whole and renamed into place, private to this user, so the
    // scheduler never reads a half-written file and nobody else reads it at all.
    const temporary = `${marker}.${randomUUID()}.tmp`;
    const file = await open(temporary, 'wx', 0o600);
    try {
      await file.writeFile(`${actor}\n`);
      await file.sync();
    } finally {
      await file.close();
    }
    try {
      await rename(temporary, marker);
    } catch (error) {
      await unlink(temporary).catch(() => undefined);
      throw error;
    }
    try {
      await this.db.query(
        `INSERT INTO audit_events(id,transaction_id,actor,event,before_value,after_value,reason)
         VALUES($1,NULL,$2,'import_retry_requested',NULL,$3,$4)`,
        [
          randomUUID(),
          actor,
          JSON.stringify({
            connection,
            instance: connectionInstance(connection),
            onBehalfOf: described.owner,
          }),
          'Asked for one more import attempt from Bank connections; the scheduler tries once at its next run',
        ],
      );
    } catch (error) {
      // A request nobody recorded must not stand: the audit is part of the act.
      await unlink(marker).catch(() => undefined);
      throw error;
    }
  }
}
