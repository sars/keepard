import test from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { memoryDatabase, migrate } from '../src/database.js';
import { Repository } from '../src/repository.js';
import { web, type WebConfig } from '../src/web.js';
import { seedOwners } from '../src/auth.js';

// A demo at a public name asks for a sign-in like the real workspace; a demo
// without `demoLogin` keeps signing itself in. The account behind the door is
// seeded the way the household's own are.
test('a demo with demoLogin needs the seeded account; without it, it signs itself in', async () => {
  const db = memoryDatabase();
  await migrate(db);
  await seedOwners(db, [
    {
      owner: 'rodion',
      email: 'demo@example.test',
      password: 'synthetic-demo-password-1',
    },
  ]);
  const repo = new Repository(db);
  const start = async (config: WebConfig) => {
    const server = web(repo, config, () => {});
    await new Promise<void>((resolve) =>
      server.listen(0, '127.0.0.1', resolve),
    );
    // The host check reads the port off the config, as the other HTTP tests do.
    config.port = (server.address() as AddressInfo).port;
    return { server, base: `http://127.0.0.1:${config.port}` };
  };
  const login = (base: string, password: string) =>
    fetch(base + '/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        email: 'demo@example.test',
        password,
      }).toString(),
    });

  try {
    const guarded = await start({
      port: 0,
      mode: 'demo',
      release: 'test',
      demoLogin: true,
    });
    try {
      assert.equal((await fetch(guarded.base + '/health/live')).status, 200);
      assert.equal((await fetch(guarded.base + '/api/bootstrap')).status, 401);
      assert.equal((await fetch(guarded.base + '/api/accounts')).status, 401);
      // The refill page's status is answered before the session gate (404
      // here, with no reseed unit wired, rather than 401): a refill wipes the
      // sessions and the page keeps polling through it.
      assert.equal(
        (await fetch(guarded.base + '/showcase/reseed/status')).status,
        404,
      );
      assert.equal(
        (await login(guarded.base, 'not-the-password-at-all')).status,
        401,
      );
      const signedIn = await login(guarded.base, 'synthetic-demo-password-1');
      assert.equal(signedIn.status, 200);
      const cookie = signedIn.headers.get('set-cookie')!.split(';')[0]!;
      // Served over plain HTTP in this test, so the cookie is not marked Secure.
      assert.doesNotMatch(signedIn.headers.get('set-cookie')!, /;\s*Secure/i);
      const bootstrap = await fetch(guarded.base + '/api/bootstrap', {
        headers: { cookie },
      });
      assert.equal(bootstrap.status, 200);
      const identity = (await bootstrap.json()) as {
        mode: string;
        signedIn: boolean;
        actor: string;
      };
      assert.deepEqual(
        {
          mode: identity.mode,
          signedIn: identity.signedIn,
          actor: identity.actor,
        },
        { mode: 'demo', signedIn: true, actor: 'rodion' },
      );
    } finally {
      await new Promise((resolve) => guarded.server.close(resolve));
    }

    const open = await start({ port: 0, mode: 'demo', release: 'test' });
    try {
      const bootstrap = await fetch(open.base + '/api/bootstrap');
      assert.equal(bootstrap.status, 200);
      assert.equal(
        ((await bootstrap.json()) as { signedIn: boolean }).signedIn,
        false,
      );
      assert.equal(
        (await login(open.base, 'synthetic-demo-password-1')).status,
        404,
      );
    } finally {
      await new Promise((resolve) => open.server.close(resolve));
    }
  } finally {
    await db.close();
  }
});
