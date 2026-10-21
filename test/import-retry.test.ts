import assert from 'node:assert/strict';
import test from 'node:test';
import { lstat, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { memoryDatabase, migrate } from '../src/database.js';
import {
  connectionInstance,
  ImportRetryError,
  ImportRetryRequests,
} from '../src/import-retry.js';

async function stoppedRevolut() {
  const db = memoryDatabase();
  await migrate(db);
  await db.query(
    `INSERT INTO bank_sync_runs(connection,state,retry_reason)
     VALUES('enablebanking:rodion:revolut','failed','blocked'),
           ('enablebanking:katya:swedbank','failed','blocked'),
           ('monobank:rodion','succeeded',NULL)`,
  );
  return db;
}

test('a connection key names its timer instance, and nothing else does', () => {
  assert.equal(
    connectionInstance('enablebanking:rodion:revolut'),
    'enablebanking-rodion-revolut',
  );
  assert.equal(connectionInstance('monobank:katya'), 'monobank-katya');
  for (const bad of ['', 'monobank', 'enablebanking:rodion', 'x:rodion:y'])
    assert.throws(
      () => connectionInstance(bad),
      (e: unknown) =>
        e instanceof ImportRetryError && e.code === 'invalid_connection',
      bad,
    );
});

test('the member asks for one more attempt: a private marker and an audit event', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pf-import-retry-'));
  const db = await stoppedRevolut();
  const retry = new ImportRetryRequests(db, directory);
  try {
    assert.deepEqual(
      await retry.status(['enablebanking:rodion:revolut', 'monobank:rodion']),
      [
        {
          connection: 'enablebanking:rodion:revolut',
          importStopped: true,
          retryQueued: false,
        },
        {
          connection: 'monobank:rodion',
          importStopped: false,
          retryQueued: false,
        },
      ],
    );
    await retry.request('rodion', 'enablebanking:rodion:revolut');
    const marker = join(
      directory,
      'enablebanking-rodion-revolut.retry-requested',
    );
    const info = await lstat(marker);
    assert.ok(info.isFile());
    assert.equal(info.mode & 0o777, 0o600);
    assert.equal(await readFile(marker, 'utf8'), 'rodion\n');
    // Nothing half-written is left beside it.
    assert.deepEqual(await readdir(directory), [
      'enablebanking-rodion-revolut.retry-requested',
    ]);
    assert.deepEqual(await retry.status(['enablebanking:rodion:revolut']), [
      {
        connection: 'enablebanking:rodion:revolut',
        importStopped: true,
        retryQueued: true,
      },
    ]);
    const audit = (
      await db.query(
        "SELECT actor,transaction_id,after_value,reason FROM audit_events WHERE event='import_retry_requested'",
      )
    ).rows;
    assert.equal(audit.length, 1);
    assert.equal(audit[0]!.actor, 'rodion');
    assert.equal(audit[0]!.transaction_id, null);
    assert.deepEqual(audit[0]!.after_value, {
      connection: 'enablebanking:rodion:revolut',
      instance: 'enablebanking-rodion-revolut',
      onBehalfOf: 'rodion',
    });
    assert.match(String(audit[0]!.reason), /one more import attempt/);

    // Pressing again refreshes the request, so a latch written since is
    // older than it once more.
    await new Promise((done) => setTimeout(done, 20));
    await retry.request('rodion', 'enablebanking:rodion:revolut');
    assert.ok((await lstat(marker)).mtimeMs > info.mtimeMs);
  } finally {
    await db.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("only the connection's member or the administrator may ask, and only while it is stopped", async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pf-import-retry-who-'));
  const db = await stoppedRevolut();
  const retry = new ImportRetryRequests(db, directory);
  const code = (expected: string) => (e: unknown) =>
    e instanceof ImportRetryError && e.code === expected;
  try {
    await assert.rejects(
      retry.request('katya', 'enablebanking:rodion:revolut'),
      code('not_your_connection'),
    );
    await assert.rejects(
      retry.request('rodion', 'monobank:rodion'),
      code('not_stopped'),
    );
    await assert.rejects(
      retry.request('rodion', 'enablebanking:rodion:wise'),
      code('not_stopped'),
    );
    await assert.rejects(
      retry.request('rodion', 'nonsense'),
      code('invalid_connection'),
    );
    assert.deepEqual(await readdir(directory), []);
    assert.equal(
      (await db.query('SELECT count(*)::int AS n FROM audit_events')).rows[0]!
        .n,
      0,
    );
    // The administrator may answer for the other member; the audit says both.
    await retry.request('rodion', 'enablebanking:katya:swedbank', true);
    assert.deepEqual(await readdir(directory), [
      'enablebanking-katya-swedbank.retry-requested',
    ]);
    const audit = (
      await db.query(
        "SELECT actor,after_value FROM audit_events WHERE event='import_retry_requested'",
      )
    ).rows;
    assert.equal(audit[0]!.actor, 'rodion');
    assert.equal(
      (audit[0]!.after_value as { onBehalfOf: string }).onBehalfOf,
      'katya',
    );
  } finally {
    await db.close();
    await rm(directory, { recursive: true, force: true });
  }
});
