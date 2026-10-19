import test from 'node:test';
import assert from 'node:assert/strict';
import { memberSetting } from '../src/member-settings.js';

test('a member setting is read from MEMBER_n_*, and the household’s original names still work', () => {
  assert.equal(
    memberSetting('rodion', 'EMAIL', { MEMBER_1_EMAIL: 'a@example.com' }),
    'a@example.com',
  );
  assert.equal(
    memberSetting('katya', 'TELEGRAM_USER_ID', {
      MEMBER_2_TELEGRAM_USER_ID: '42',
    }),
    '42',
  );
  // A server configured before the names were made configurable keeps working.
  assert.equal(
    memberSetting('rodion', 'PASSWORD', { RODION_PASSWORD: 'x'.repeat(20) }),
    'x'.repeat(20),
  );
  assert.equal(
    memberSetting('katya', 'TELEGRAM_USER_ID', { TELEGRAM_KATYA_USER_ID: '7' }),
    '7',
  );
  // The new name wins when both are set; an empty value counts as unset.
  assert.equal(
    memberSetting('katya', 'EMAIL', {
      MEMBER_2_EMAIL: 'new@example.com',
      KATYA_EMAIL: 'old@example.com',
    }),
    'new@example.com',
  );
  assert.equal(
    memberSetting('rodion', 'EMAIL', { MEMBER_1_EMAIL: '', RODION_EMAIL: '' }),
    undefined,
  );
  // Member 1 never reads member 2's settings.
  assert.equal(
    memberSetting('rodion', 'EMAIL', { MEMBER_2_EMAIL: 'b@example.com' }),
    undefined,
  );
});
