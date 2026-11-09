import { describe, expect, it } from 'vitest';
import {
  CALL_LOG_EVENT,
  DEEPER_MARK,
  DEEPEST_LOGGED_LEVEL,
  LONGEST_LOGGED_VALUE,
  MASKED,
  MORE_KEY,
  MOST_LOGGED_ENTRIES,
  TOKEN_HASH_LENGTH,
  TRUNCATION_MARK,
  callLogLine,
  maskArguments,
  safeCallLogLine,
  tokenHash,
  type CallFacts,
} from './call-log.js';

const TOKEN = 'the-apps-own-token';
const FIXED_TIME = new Date('2026-11-09T08:00:00.000Z');

describe('maskArguments', () => {
  it.each(['token', 'apiToken', 'client_secret', 'password', 'api_key', 'KEY', 'authorization', 'Auth'])(
    'masks an argument named %s',
    (name) => {
      expect(maskArguments({ [name]: 'value', other: 'kept' }, TOKEN)).toEqual({ [name]: MASKED, other: 'kept' });
    },
  );

  it('masks at any depth, in objects and arrays', () => {
    const args = { outer: { password: 'x', list: [{ secret: 'y', name: 'kept' }] } };
    expect(maskArguments(args, TOKEN)).toEqual({
      outer: { password: MASKED, list: [{ secret: MASKED, name: 'kept' }] },
    });
  });

  it("masks any value that holds the app's token anywhere, whatever its name", () => {
    expect(
      maskArguments({ note: TOKEN, list: [TOKEN], header: `Bearer ${TOKEN}`, deep: { a: [`x${TOKEN}y`] } }, TOKEN),
    ).toEqual({
      note: MASKED,
      list: [MASKED],
      header: MASKED,
      deep: { a: [MASKED] },
    });
  });

  it('cuts a long value short', () => {
    const long = 'a'.repeat(LONGEST_LOGGED_VALUE + 1);
    expect(maskArguments({ text: long }, TOKEN)).toEqual({
      text: `${'a'.repeat(LONGEST_LOGGED_VALUE)}${TRUNCATION_MARK}`,
    });
    expect(maskArguments({ text: 'a'.repeat(LONGEST_LOGGED_VALUE) }, TOKEN)).toEqual({
      text: 'a'.repeat(LONGEST_LOGGED_VALUE),
    });
  });

  it('keeps numbers, booleans and null as they are', () => {
    expect(maskArguments({ count: 3, on: true, none: null }, TOKEN)).toEqual({ count: 3, on: true, none: null });
  });

  it.each([undefined, null, 'text', 7, ['a']])('logs %j as no arguments', (args) => {
    expect(maskArguments(args, TOKEN)).toEqual({});
  });

  it('logs nesting past the deepest level as a mark', () => {
    let deep: Record<string, unknown> = { leaf: 'x' };
    for (let level = 0; level < DEEPEST_LOGGED_LEVEL + 2; level += 1) deep = { next: deep };
    let logged = maskArguments(deep, TOKEN);
    let levels = 0;
    while (typeof logged.next === 'object' && logged.next !== null) {
      logged = logged.next as Record<string, unknown>;
      levels += 1;
    }
    expect(logged.next).toBe(DEEPER_MARK);
    expect(levels).toBe(DEEPEST_LOGGED_LEVEL - 1);
  });

  it('logs only so many keys and items, and counts the rest', () => {
    const many = MOST_LOGGED_ENTRIES + 3;
    const keys = Object.fromEntries(Array.from({ length: many }, (_, index) => [`k${index}`, index]));
    const logged = maskArguments({ keys, items: Array.from({ length: many }, (_, index) => index) }, TOKEN);
    expect(Object.keys(logged.keys as object)).toHaveLength(MOST_LOGGED_ENTRIES + 1);
    expect((logged.keys as Record<string, unknown>)[MORE_KEY]).toBe('3 more');
    expect(logged.items).toHaveLength(MOST_LOGGED_ENTRIES + 1);
    expect((logged.items as unknown[]).at(-1)).toBe('3 more');
  });

  it('cuts a long key short', () => {
    expect(Object.keys(maskArguments({ ['a'.repeat(LONGEST_LOGGED_VALUE + 1)]: 1 }, TOKEN))[0]).toHaveLength(
      LONGEST_LOGGED_VALUE + TRUNCATION_MARK.length,
    );
  });

  it('masks nothing by value when there is no token', () => {
    expect(maskArguments({ note: '' }, '')).toEqual({ note: '' });
  });
});

describe('tokenHash', () => {
  it('is null when no token was presented', () => {
    expect(tokenHash('')).toBeNull();
  });

  it('is a fixed-length prefix of the SHA-256, never the token', () => {
    const hash = tokenHash(TOKEN);
    expect(hash).toHaveLength(TOKEN_HASH_LENGTH);
    expect(hash).toMatch(/^[0-9a-f]+$/);
    expect(hash).not.toContain(TOKEN);
    expect(tokenHash(TOKEN)).toBe(hash);
    expect(tokenHash(`${TOKEN}x`)).not.toBe(hash);
  });
});

const FACTS: CallFacts = {
  caller: '10.42.0.7',
  method: 'tools/call',
  tool: 'set_value',
  arguments: {},
  outcome: 'ok',
  presentedToken: TOKEN,
};

describe('callLogLine', () => {
  it('holds the call, masked, with the token only as a hash', () => {
    const line = callLogLine(
      {
        caller: '10.42.0.7',
        method: 'tools/call',
        tool: 'set_value',
        arguments: { value: 'v', api_key: 'k', note: TOKEN },
        outcome: 'ok',
        presentedToken: TOKEN,
      },
      TOKEN,
      FIXED_TIME,
    );
    expect(line).toEqual({
      event: CALL_LOG_EVENT,
      time: FIXED_TIME.toISOString(),
      caller: '10.42.0.7',
      method: 'tools/call',
      tool: 'set_value',
      arguments: { value: 'v', api_key: MASKED, note: MASKED },
      outcome: 'ok',
      token_sha256: null,
    });
    expect(JSON.stringify(line)).not.toContain(TOKEN);
  });

  it("carries a refused caller's token as a hash, to tell callers apart", () => {
    const refused = callLogLine({ ...FACTS, outcome: 'unauthorized', presentedToken: 'other' }, TOKEN);
    expect(refused.token_sha256).toBe(tokenHash('other'));
  });

  it('cuts a long method and tool short', () => {
    const long = 'm'.repeat(LONGEST_LOGGED_VALUE + 1);
    const line = callLogLine({ ...FACTS, method: long, tool: long }, TOKEN);
    expect(line.method).toHaveLength(LONGEST_LOGGED_VALUE + TRUNCATION_MARK.length);
    expect(line.tool).toHaveLength(LONGEST_LOGGED_VALUE + TRUNCATION_MARK.length);
  });

  it('logs no caller, tool or token as null', () => {
    const line = callLogLine(
      {
        caller: undefined,
        method: 'GET',
        tool: undefined,
        arguments: undefined,
        outcome: 'refused',
        presentedToken: '',
      },
      TOKEN,
    );
    expect(line).toMatchObject({ caller: null, tool: null, arguments: {}, token_sha256: null, outcome: 'refused' });
  });
});

describe('safeCallLogLine', () => {
  it('is callLogLine when that works', () => {
    expect(safeCallLogLine(FACTS, TOKEN, FIXED_TIME)).toEqual(callLogLine(FACTS, TOKEN, FIXED_TIME));
  });

  it('still logs the call, without its arguments, when they cannot be read', () => {
    const unreadable = new Proxy(
      {},
      {
        ownKeys: () => {
          throw new Error('unreadable');
        },
      },
    );
    expect(safeCallLogLine({ ...FACTS, arguments: unreadable }, TOKEN, FIXED_TIME)).toEqual({
      event: CALL_LOG_EVENT,
      time: FIXED_TIME.toISOString(),
      caller: null,
      method: 'tools/call',
      tool: 'set_value',
      arguments: {},
      outcome: 'ok',
      token_sha256: null,
    });
  });
});
