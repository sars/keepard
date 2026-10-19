import type { Owner } from './domain.js';

/**
 * The two members' own settings, read from the environment.
 *
 * An installation sets MEMBER_1_* for the first member and MEMBER_2_* for the
 * second. The household this was built for set RODION_* and KATYA_* (and
 * TELEGRAM_RODION_USER_ID, TELEGRAM_KATYA_USER_ID) before the names were
 * made configurable, and those still work, so a running server needs no edit.
 * The new name wins when both are set.
 *
 * Member 1 is the ledger's `rodion` and member 2 its `katya`; see
 * account-names.ts for why those keys stay.
 */
export type MemberSetting = 'EMAIL' | 'PASSWORD' | 'TELEGRAM_USER_ID';

const MEMBER_NUMBER: Record<Owner, 1 | 2> = { rodion: 1, katya: 2 };

const LEGACY: Record<Owner, Record<MemberSetting, string>> = {
  rodion: {
    EMAIL: 'RODION_EMAIL',
    PASSWORD: 'RODION_PASSWORD',
    TELEGRAM_USER_ID: 'TELEGRAM_RODION_USER_ID',
  },
  katya: {
    EMAIL: 'KATYA_EMAIL',
    PASSWORD: 'KATYA_PASSWORD',
    TELEGRAM_USER_ID: 'TELEGRAM_KATYA_USER_ID',
  },
};

export function memberSetting(
  owner: Owner,
  setting: MemberSetting,
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const current = env[`MEMBER_${MEMBER_NUMBER[owner]}_${setting}`];
  if (current) return current;
  return env[LEGACY[owner][setting]] || undefined;
}
