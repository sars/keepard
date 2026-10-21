import { ConnectorError, type Requester } from './types.js';
import { setTimeout as sleep } from 'node:timers/promises';

/**
 * Told about every request once it has settled, for the attempt record.
 *
 * It receives the path as asked; the recorder reduces it to a shape before
 * storing it, because these paths address a consent session and a provider
 * account id. Anything this reports is diagnostic only and must never change
 * what the requester returns — an observer that throws is ignored.
 */
export type RequestObserver = (event: {
  path: string;
  status?: number;
  ms: number;
  /** Bytes the bank answered with; absent when it never answered. */
  size?: number;
  code?: string;
  retryAfterMs?: number;
  /** The bank's own code for a refusal, when it gave one; see `refusalReason`. */
  reason?: string;
}) => void;

/** How much of a refusal's body is read while looking for its code. */
const REASON_BODY_BYTES = 4096;

/**
 * Reduces an `error` field from a refusal to something safe to keep: a code
 * such as `EXPIRED_SESSION` or `ASPSP_ERROR`, never a sentence.
 *
 * Only a string survives, upper-cased and cut to forty characters, and only
 * when nothing but letters, digits and underscores remain — a value holding a
 * space, a dash or a quote is free text as far as this is concerned and is
 * dropped whole rather than stripped, since a stripped sentence is still the
 * sentence. `message` and `detail` are never read at all.
 */
export function sanitizeReason(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const reason = value.toUpperCase().slice(0, 40);
  return /^[A-Z0-9_]+$/.test(reason) ? reason : undefined;
}

/**
 * The code a bank gave for refusing a request, from the first few kilobytes
 * of its body, which is then cancelled.
 *
 * Enable Banking answers a refusal with `{"error": "EXPIRED_SESSION",
 * "message": "Session is expired"}`, and the status alone — a 401 — cannot
 * tell an expired session from a revoked one. Only the `error` field is
 * looked at, through `sanitizeReason`; a body that is not JSON, is empty, is
 * longer than the bound, or cannot be read gives nothing. Never throws.
 */
async function refusalReason(
  body: ReadableStream<Uint8Array> | null,
): Promise<string | undefined> {
  if (!body) return undefined;
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (size <= REASON_BODY_BYTES) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      chunks.push(value);
    }
  } catch {
    return undefined;
  } finally {
    await reader.cancel().catch(() => undefined);
  }
  if (size === 0 || size > REASON_BODY_BYTES) return undefined;
  try {
    const parsed = JSON.parse(
      Buffer.concat(chunks).toString('utf8'),
    ) as unknown;
    return sanitizeReason((parsed as { error?: unknown } | null)?.error);
  } catch {
    return undefined;
  }
}

export function requester(
  origin: 'https://api.monobank.ua' | 'https://api.enablebanking.com',
  intervalMs = 0,
  fetcher: typeof fetch = fetch,
  observe?: RequestObserver,
): Requester {
  let lastStart = 0;
  let queue: Promise<unknown> = Promise.resolve();
  const report: RequestObserver = (event) => {
    if (!observe) return;
    try {
      observe(event);
    } catch {
      // A failed note about a request is not a failed request.
    }
  };
  return (path, headers) => {
    const request = queue.then(async () => {
      if (!path.startsWith('/') || path.startsWith('//'))
        throw new ConnectorError('schema');
      const url = new URL(path, origin);
      if (url.origin !== origin) throw new ConnectorError('schema');
      const wait = intervalMs - (Date.now() - lastStart);
      if (wait > 0) await sleep(wait);
      lastStart = Date.now();
      const began = lastStart;
      try {
        const response = await fetcher(url, {
          method: 'GET',
          headers,
          redirect: 'error',
          signal: AbortSignal.timeout(20000),
        });
        if (!response.ok) {
          const retry = response.headers.get('retry-after');
          // Read for its code and then dropped: the code is the one thing in
          // a refusal worth keeping, and nothing else from the body is kept.
          const reason = await refusalReason(response.body);
          const refused = (error: ConnectorError) => {
            report({
              path,
              status: response.status,
              ms: Date.now() - began,
              code: error.code,
              ...(error.retryAfterMs === undefined
                ? {}
                : { retryAfterMs: error.retryAfterMs }),
              ...(reason === undefined ? {} : { reason }),
            });
            return error;
          };
          if (response.status === 401 || response.status === 403)
            throw refused(new ConnectorError('auth'));
          if (response.status === 429) {
            const millis = retry
              ? /^\d+$/.test(retry)
                ? Number(retry) * 1000
                : Date.parse(retry) - Date.now()
              : 60000;
            throw refused(
              new ConnectorError(
                'rate_limit',
                Math.min(
                  Math.max(Number.isFinite(millis) ? millis : 60000, 1000),
                  86400000,
                ),
              ),
            );
          }
          if (response.status >= 500)
            throw refused(new ConnectorError('transient'));
          throw refused(new ConnectorError('schema'));
        }
        const reader = response.body?.getReader();
        if (!reader) throw new ConnectorError('schema');
        let size = 0;
        const chunks: Uint8Array[] = [];
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > 4 * 1024 * 1024) {
            await reader.cancel();
            throw new ConnectorError('incomplete');
          }
          chunks.push(value);
        }
        // A request that worked is reported too. Only the refusals were, at
        // first, which made a healthy run look as though it had asked the bank
        // for nothing at all — and "what did it request" is most of what the
        // run screen is for. The size is the response's length in bytes, which
        // says whether a bank answered thinly without saying what it answered.
        report({ path, status: response.status, ms: Date.now() - began, size });
        return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
      } catch (error) {
        if (error instanceof ConnectorError) throw error;
        // Everything else is a connection that never produced a response: a
        // timeout, a refused socket, a body that stopped early. It has no
        // status, and it is the failure most worth seeing on the run screen
        // because nothing else records it anywhere.
        const code = error instanceof SyntaxError ? 'schema' : 'transient';
        report({ path, ms: Date.now() - began, code });
        throw new ConnectorError(code);
      }
    });
    queue = request.catch(() => undefined);
    return request;
  };
}
