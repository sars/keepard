// Asks for a refill of the showcase, the way the refill page does.
//
// Run every night by `private-finances-showcase-nightly.timer`, inside the
// `showcase-reseed` service. It only leaves a request file; the `.path` unit
// that watches for the page's requests sees it and runs the same refill, so a
// nightly refill is exactly a refill somebody asked for, status file included.
// The public demo is written to by visitors, and this puts it back each night.
//
// The demo is rebuilt in the shape it was last built in, or the defaults when
// it has never been refilled. A refill already under way is left alone.
import {
  readReseedStatus,
  writeReseedRequest,
} from '../dist/src/showcase-control.js';
import { clampShowcase } from '../dist/src/showcase.js';

const directory =
  process.env.SHOWCASE_CONTROL_DIR ?? '/var/lib/private-finances-showcase';

const status = await readReseedStatus(directory);
if (status && ['queued', 'seeding', 'starting'].includes(status.state)) {
  console.log(`a refill is already ${status.state}; nothing to do`);
  process.exit(0);
}
const last = status?.shape;
const shape = {
  density: clampShowcase('density', last?.density),
  months: Math.round(clampShowcase('months', last?.months)),
  refunds: Math.round(clampShowcase('refunds', last?.refunds)),
  receipts: Math.round(clampShowcase('receipts', last?.receipts)),
};
await writeReseedRequest(directory, shape);
console.log(`refill requested: ${JSON.stringify(shape)}`);
