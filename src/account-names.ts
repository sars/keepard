/**
 * How an account is named wherever the application lists one: the member,
 * the bank, the product, and the currency when the product does not say it —
 * "Rodion · Monobank · Iron", "Katya · Wise · EUR", "Rodion · Monobank · FOP
 * USD". One rule, so a picker on Assets, a card on Balances and a filter on
 * Transactions all call the same account the same thing.
 *
 * The owner's own label decides the product ("black", "Wise EUR", "LHV"); the
 * connector decides the bank where the label does not. Nothing here changes
 * which account a payment belongs to.
 */
export type AccountOwner = 'rodion' | 'katya';

/**
 * What each member is called on screen and in Telegram.
 *
 * An installation names its own people with MEMBER_1_NAME and MEMBER_2_NAME;
 * without them it shows Alex and Sam, so a fresh fork never carries anybody's
 * real name. The demo workspace always uses Alex and Sam, whatever its
 * environment says. Only the label changes: the owner recorded against every
 * payment is still `rodion` (member 1) or `katya` (member 2), because that
 * identity is what the ledger, the audit history and the bank connections are
 * keyed by, and nobody sees it.
 *
 * The object is shared and renamed in place, so every module that holds it,
 * the Telegram worker's included, reads the current names.
 */
const OWNER_NAMES: Record<AccountOwner, string> = {
  rodion: process.env.MEMBER_1_NAME?.trim() || 'Alex',
  katya: process.env.MEMBER_2_NAME?.trim() || 'Sam',
};
/** The live names, for modules that index them directly. */
export const memberNames: Readonly<Record<AccountOwner, string>> = OWNER_NAMES;
/** Rename the members for this process; demo mode calls this at startup. */
export function setOwnerNames(
  names: Partial<Record<AccountOwner, string>>,
): void {
  for (const [owner, name] of Object.entries(names))
    if (name) OWNER_NAMES[owner as AccountOwner] = name;
}
/** The names as they stand, for the payload the frontend reads them from. */
export function ownerNames(): Record<AccountOwner, string> {
  return { ...OWNER_NAMES };
}
/** Banks the household holds accounts with, by the word a label starts with. */
const BANKS = ['Monobank', 'Wise', 'Revolut', 'Swedbank', 'LHV', 'PrivatBank'];
const SOURCE_BANK: Record<string, string> = {
  monobank: 'Monobank',
  manual_cash: 'Cash',
};
/** Monobank's card names as the API states them, spelt for people. */
const PRODUCTS: Record<string, string> = {
  black: 'Black',
  white: 'White',
  iron: 'Iron',
  platinum: 'Platinum',
  yellow: 'Yellow',
  fop: 'FOP',
  eaid: 'eAid',
  diia: 'Diia',
  madeinukraine: 'Made in Ukraine',
  rebuilding: 'Rebuilding',
};

export interface AccountNameInput {
  owner: AccountOwner | string;
  source: string;
  label: string | null | undefined;
  /** The currency the account holds, when one is known; several stay unnamed. */
  currency?: string | null;
}

/** The parts of the name, for callers that lay them out separately. */
export function accountNameParts(input: AccountNameInput): {
  owner: string;
  bank: string | null;
  product: string | null;
} {
  const owner =
    OWNER_NAMES[input.owner as AccountOwner] ??
    input.owner.charAt(0).toUpperCase() + input.owner.slice(1);
  let label = (input.label ?? '').trim().replace(/\s+/g, ' ');
  let bank: string | null = SOURCE_BANK[input.source] ?? null;
  // A label the owner wrote may start with the bank: "Wise EUR", "LHV".
  const leading = [...(bank ? [bank] : []), ...BANKS].find((name) =>
    label.toLowerCase().startsWith(name.toLowerCase()),
  );
  if (leading) {
    bank = bank ?? leading;
    if (leading.toLowerCase() === bank.toLowerCase())
      label = label.slice(leading.length).trim();
  }
  let product: string | null = label
    ? (PRODUCTS[label.toLowerCase()] ?? label)
    : null;
  const currency = input.currency?.toUpperCase();
  if (currency && /^[A-Z]{3}$/.test(currency)) {
    if (!product) product = currency;
    else if (!product.toUpperCase().split(' ').includes(currency))
      product = `${product} ${currency}`;
  }
  return { owner, bank, product };
}

/** "Rodion · Monobank · Iron UAH"; parts that are unknown are simply left out. */
export function accountDisplayName(input: AccountNameInput): string {
  const { owner, bank, product } = accountNameParts(input);
  return [owner, bank, product].filter(Boolean).join(' · ');
}
