import { GAME_NAME_MAX_LEN, PLAYER_NAME_MAX_LEN } from '@base-multiplayer-game/shared';
import { describe, expect, it } from 'vitest';
import { clientMessageSchema } from './message-schemas.js';

/** One emoji: a single code point, but two UTF-16 code units, so two towards `String.length`. */
const WIDE_CHARACTER = '😀';
const CLIENT_REPORT = { fps: 60, frameTimeAvgMs: 16, frameTimeP95Ms: 18, frameTimePeakMs: 30, heapMb: null };

function joinLobbyAs(playerName: string): unknown {
  return { type: 'join_lobby', playerName, avatarIndex: 0 };
}

function createGameNamed(gameName: string): unknown {
  return { type: 'create_game', gameName, config: { maxPlayers: 2 } };
}

function isAccepted(message: unknown): boolean {
  return clientMessageSchema.safeParse(message).success;
}

describe('ws/message-schemas', () => {
  describe.each([
    ['player name', PLAYER_NAME_MAX_LEN, joinLobbyAs],
    ['game name', GAME_NAME_MAX_LEN, createGameNamed],
  ])('%s length, in String.length units', (_label, maxLength, messageWith) => {
    it('accepts the limit', () => {
      expect(isAccepted(messageWith('a'.repeat(maxLength)))).toBe(true);
    });

    it('rejects one over the limit', () => {
      expect(isAccepted(messageWith('a'.repeat(maxLength + 1)))).toBe(false);
    });

    it('counts a character outside the basic plane as two', () => {
      expect(isAccepted(messageWith(WIDE_CHARACTER.repeat(maxLength / 2)))).toBe(true);
      expect(isAccepted(messageWith(WIDE_CHARACTER.repeat(maxLength / 2 + 1)))).toBe(false);
    });

    it('rejects empty text', () => {
      expect(isAccepted(messageWith(''))).toBe(false);
    });
  });

  it('player_input needs a payload, and null counts as one', () => {
    expect(isAccepted({ type: 'player_input' })).toBe(false);
    expect(isAccepted({ type: 'player_input', payload: null })).toBe(true);
  });

  it('client_performance rejects the Infinity a JSON overflow produces', () => {
    const overflowing = JSON.stringify({ type: 'client_performance', report: CLIENT_REPORT }).replace(
      '"fps":60',
      '"fps":1e999',
    );
    expect(isAccepted(JSON.parse(overflowing))).toBe(false);
    expect(isAccepted({ type: 'client_performance', report: CLIENT_REPORT })).toBe(true);
  });

  it('create_game keeps the config fields a game adds', () => {
    const parsed = clientMessageSchema.parse({
      type: 'create_game',
      gameName: 'Arena',
      config: { maxPlayers: 2, seed: 7 },
    });
    expect(parsed).toMatchObject({ config: { seed: 7 } });
  });
});
