import { describe, expect, it } from 'vitest';
import {
  CALL_LOG_EVENT,
  LONGEST_LOGGED_VALUE,
  MASKED,
  TOKEN_HASH_LENGTH,
  TRUNCATION_MARK,
  callLogLine,
  maskArguments,
  tokenHash,
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
    expect(maskArguments(args, TOKEN)).toEqual({ outer: { password: MASKED, list: [{ secret: MASKED, name: 'kept' }] } });
  });

  it("masks any value that holds the app's token anywhere, whatever its name", () => {
    expect(maskArguments({ note: TOKEN, list: [TOKEN], header: `Bearer ${TOKEN}`, deep: { a: [`x${TOKEN}y`] } }, TOKEN)).toEqual({
      note: MASKED,
      list: [MASKED],
      header: MASKED,
      deep: { a: [MASKED] },
    });
  });

  it('cuts a long value short', () => {
    const long = 'a'.repeat(LONGEST_LOGGED_VALUE + 1);
    expect(maskArguments({ text: long }, TOKEN)).toEqual({ text: `${'a'.repeat(LONGEST_LOGGED_VALUE)}${TRUNCATION_MARK}` });
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
      token_sha256: tokenHash(TOKEN),
    });
    expect(JSON.stringify(line)).not.toContain(TOKEN);
  });

  it('logs no caller, tool or token as null', () => {
    const line = callLogLine(
      { caller: undefined, method: 'GET', tool: undefined, arguments: undefined, outcome: 'refused', presentedToken: '' },
      TOKEN,
    );
    expect(line).toMatchObject({ caller: null, tool: null, arguments: {}, token_sha256: null, outcome: 'refused' });
  });
});
