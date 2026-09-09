import { describe, expect, it } from 'vitest';
import { clamp, playerId, gameId, isRoomJoinable } from '../types/common.js';

describe('clamp', () => {
  it('returns the value when within range', () => {
    expect(clamp(3, 0, 5)).toBe(3);
  });

  it('clamps below the minimum', () => {
    expect(clamp(-2, 0, 5)).toBe(0);
  });

  it('clamps above the maximum', () => {
    expect(clamp(9, 0, 5)).toBe(5);
  });

  it('respects inclusive bounds', () => {
    expect(clamp(0, 0, 5)).toBe(0);
    expect(clamp(5, 0, 5)).toBe(5);
  });
});

describe('branded id factories', () => {
  it('return the underlying string unchanged at runtime', () => {
    expect(playerId('abc')).toBe('abc');
    expect(gameId('room-1')).toBe('room-1');
  });
});

describe('isRoomJoinable', () => {
  it('is joinable when not started and below capacity', () => {
    expect(isRoomJoinable({ started: false, playerCount: 1, maxPlayers: 4 })).toBe(true);
  });

  it('is not joinable once started', () => {
    expect(isRoomJoinable({ started: true, playerCount: 1, maxPlayers: 4 })).toBe(false);
  });

  it('is not joinable when at capacity', () => {
    expect(isRoomJoinable({ started: false, playerCount: 4, maxPlayers: 4 })).toBe(false);
  });
});
