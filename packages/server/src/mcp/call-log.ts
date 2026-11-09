import { createHash } from 'node:crypto';

/**
 * The prod MCP's call log: one JSON line per call, which the platform's log collector keeps (preffect-home #73).
 * It never holds the token: arguments whose name looks secret, at any depth, and any value that holds the token
 * anywhere are masked, long values are cut
 * short, and the token presented shows only as a hash prefix, so two calls with one token can be matched up.
 * Template-owned: it names nothing game-specific.
 */

export const CALL_LOG_EVENT = 'mcp_call';
export const MASKED = '***';
/** An argument whose name contains any of these is masked, at any depth. */
export const SECRET_NAME_PATTERN = /token|secret|password|key|auth/i;
export const LONGEST_LOGGED_VALUE = 200;
export const TRUNCATION_MARK = '...';
export const TOKEN_HASH_LENGTH = 16;

/** ok and error are a tool's own answer; unauthorized and refused never reach a tool. */
export type CallOutcome = 'ok' | 'error' | 'unauthorized' | 'refused';

export interface CallLogLine {
  event: typeof CALL_LOG_EVENT;
  time: string;
  caller: string | null;
  method: string;
  tool: string | null;
  arguments: Record<string, unknown>;
  outcome: CallOutcome;
  token_sha256: string | null;
}

/** The facts about one call, before masking. */
export interface CallFacts {
  caller: string | undefined;
  method: string;
  tool: string | undefined;
  arguments: unknown;
  outcome: CallOutcome;
  presentedToken: string;
}

/** A prefix of the presented token's SHA-256, or null when none was presented. */
export function tokenHash(presented: string): string | null {
  if (presented === '') return null;
  return createHash('sha256').update(presented).digest('hex').slice(0, TOKEN_HASH_LENGTH);
}

function cutShort(text: string): string {
  return text.length <= LONGEST_LOGGED_VALUE ? text : `${text.slice(0, LONGEST_LOGGED_VALUE)}${TRUNCATION_MARK}`;
}

function maskValue(value: unknown, secret: string): unknown {
  if (Array.isArray(value)) return value.map((item) => maskValue(item, secret));
  if (value !== null && typeof value === 'object') return maskObject(value as Record<string, unknown>, secret);
  if (typeof value === 'string') return secret !== '' && value.includes(secret) ? MASKED : cutShort(value);
  return value;
}

function maskObject(object: Record<string, unknown>, secret: string): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(object).map(([name, value]) => [
      name,
      SECRET_NAME_PATTERN.test(name) ? MASKED : maskValue(value, secret),
    ]),
  );
}

/** A tool's arguments as they may be logged. Anything but an object logs as no arguments. */
export function maskArguments(args: unknown, secret: string): Record<string, unknown> {
  if (args === null || typeof args !== 'object' || Array.isArray(args)) return {};
  return maskObject(args as Record<string, unknown>, secret);
}

/** The line for one call. `secret` is the app's own token, masked wherever it shows up in the arguments. */
export function callLogLine(facts: CallFacts, secret: string, now: Date = new Date()): CallLogLine {
  return {
    event: CALL_LOG_EVENT,
    time: now.toISOString(),
    caller: facts.caller ?? null,
    method: facts.method,
    tool: facts.tool ?? null,
    arguments: maskArguments(facts.arguments, secret),
    outcome: facts.outcome,
    token_sha256: tokenHash(facts.presentedToken),
  };
}
