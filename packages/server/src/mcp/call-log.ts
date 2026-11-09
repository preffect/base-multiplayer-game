import { createHash } from 'node:crypto';

/**
 * The prod MCP's call log: one JSON line per call, which the platform's log collector keeps (preffect-home #73).
 * It never holds the token: arguments whose name looks secret, at any depth, and any value that holds the token
 * anywhere are masked. Every string is cut short, and depth, keys and items are capped, so no call writes a huge line.
 * Only a refused call carries a hash prefix of the token it presented, to tell callers apart: an accepted one
 * presented the app's own. Building a line can't fail, so no call goes unlogged.
 * Template-owned: it names nothing game-specific.
 */

export const CALL_LOG_EVENT = 'mcp_call';
export const MASKED = '***';
/** An argument whose name contains any of these is masked, at any depth. */
export const SECRET_NAME_PATTERN = /token|secret|password|key|auth/i;
export const LONGEST_LOGGED_VALUE = 200;
export const TRUNCATION_MARK = '...';
export const TOKEN_HASH_LENGTH = 16;
/** Nesting below this many levels logs as DEEPER_MARK. */
export const DEEPEST_LOGGED_LEVEL = 8;
export const DEEPER_MARK = '[deeper]';
/** Keys per object and items per array; the rest log as one count. */
export const MOST_LOGGED_ENTRIES = 50;
export const MORE_KEY = '[more]';

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

export function cutShort(text: string): string {
  return text.length <= LONGEST_LOGGED_VALUE ? text : `${text.slice(0, LONGEST_LOGGED_VALUE)}${TRUNCATION_MARK}`;
}

function moreCount(total: number): string {
  return `${total - MOST_LOGGED_ENTRIES} more`;
}

function maskValue(value: unknown, secret: string, depth: number): unknown {
  if (value !== null && typeof value === 'object' && depth >= DEEPEST_LOGGED_LEVEL) return DEEPER_MARK;
  if (Array.isArray(value)) {
    const items = value.slice(0, MOST_LOGGED_ENTRIES).map((item) => maskValue(item, secret, depth + 1));
    return value.length > MOST_LOGGED_ENTRIES ? [...items, moreCount(value.length)] : items;
  }
  if (value !== null && typeof value === 'object') return maskObject(value as Record<string, unknown>, secret, depth);
  if (typeof value === 'string') return secret !== '' && value.includes(secret) ? MASKED : cutShort(value);
  return value;
}

function maskObject(object: Record<string, unknown>, secret: string, depth: number): Record<string, unknown> {
  const entries = Object.entries(object);
  const masked: Record<string, unknown> = Object.fromEntries(
    entries
      .slice(0, MOST_LOGGED_ENTRIES)
      .map(([name, value]) => [
        cutShort(name),
        SECRET_NAME_PATTERN.test(name) ? MASKED : maskValue(value, secret, depth + 1),
      ]),
  );
  if (entries.length > MOST_LOGGED_ENTRIES) masked[MORE_KEY] = moreCount(entries.length);
  return masked;
}

/** A tool's arguments as they may be logged. Anything but an object logs as no arguments. */
export function maskArguments(args: unknown, secret: string): Record<string, unknown> {
  if (args === null || typeof args !== 'object' || Array.isArray(args)) return {};
  return maskObject(args as Record<string, unknown>, secret, 0);
}

/** The line for one call. `secret` is the app's own token, masked wherever it shows up in the arguments. */
export function callLogLine(facts: CallFacts, secret: string, now: Date = new Date()): CallLogLine {
  return {
    event: CALL_LOG_EVENT,
    time: now.toISOString(),
    caller: facts.caller ?? null,
    method: cutShort(facts.method),
    tool: facts.tool === undefined ? null : cutShort(facts.tool),
    arguments: maskArguments(facts.arguments, secret),
    outcome: facts.outcome,
    token_sha256: facts.outcome === 'unauthorized' ? tokenHash(facts.presentedToken) : null,
  };
}

/** callLogLine, or, if building it fails, the call without its arguments: a call is never left unlogged. */
export function safeCallLogLine(facts: CallFacts, secret: string, now: Date = new Date()): CallLogLine {
  try {
    return callLogLine(facts, secret, now);
  } catch {
    return {
      event: CALL_LOG_EVENT,
      time: now.toISOString(),
      caller: null,
      method: typeof facts.method === 'string' ? cutShort(facts.method) : '',
      tool: typeof facts.tool === 'string' ? cutShort(facts.tool) : null,
      arguments: {},
      outcome: facts.outcome,
      token_sha256: null,
    };
  }
}
