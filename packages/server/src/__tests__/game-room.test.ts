import { describe, it, expect, vi, afterEach } from 'vitest';
import { GameRoom } from '../lobby/game-room.js';
import type { GameModule } from '../game/game-module.js';
import type { Connection } from '../ws/connection.js';
import type { PlayerId } from '@base-multiplayer-game/shared';

function makeConn(id: string): Connection {
  return {
    playerId: id,
    playerName: id,
    avatarIndex: 0,
    socket: { readyState: 1, send: () => {}, close: () => {}, on: () => {} } as unknown as Connection['socket'],
  };
}

function spyModule(): GameModule & { reduceCalls: () => number } {
  let reduceCalls = 0;
  const players = new Set<string>();
  return {
    submitInput: vi.fn(),
    reduceGameState: vi.fn(() => {
      reduceCalls++;
    }),
    serializeRoomState: vi.fn(() => ({ players: [...players] })),
    addPlayer: vi.fn((pid: PlayerId) => {
      players.add(pid);
    }),
    removePlayer: vi.fn((pid: PlayerId) => {
      players.delete(pid);
    }),
    free: vi.fn(),
    reduceCalls: () => reduceCalls,
  };
}

describe('game-room', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('runs the tick loop calling reduce + serialize while started', () => {
    vi.useFakeTimers();
    const mod = spyModule();
    const room = new GameRoom(mod, 'p1' as PlayerId, ['p1'], 'Test', { maxPlayers: 4 }, { p1: 0 });
    room.start();
    vi.advanceTimersByTime((1000 / 60) * 3 + 1);
    room.stop();
    expect(mod.reduceCalls()).toBeGreaterThanOrEqual(3);
    expect(mod.serializeRoomState).toHaveBeenCalled();
    expect(mod.free).toHaveBeenCalled();
  });

  it('stop() halts the loop', () => {
    vi.useFakeTimers();
    const mod = spyModule();
    const room = new GameRoom(mod, 'p1' as PlayerId, ['p1'], 'Test', { maxPlayers: 4 }, { p1: 0 });
    room.start();
    room.stop();
    const before = mod.reduceCalls();
    vi.advanceTimersByTime(1000);
    expect(mod.reduceCalls()).toBe(before);
  });

  it('submitInput delegates to the game module', () => {
    const mod = spyModule();
    const room = new GameRoom(mod, 'p1' as PlayerId, ['p1'], 'Test', { maxPlayers: 4 }, { p1: 0 });
    room.submitInput('p1', { jump: true });
    expect(mod.submitInput).toHaveBeenCalledWith('p1', { jump: true });
  });

  it('removePlayer drops the player from the module and roster', () => {
    const mod = spyModule();
    const room = new GameRoom(mod, 'p1' as PlayerId, ['p1', 'p2'], 'Test', { maxPlayers: 4 }, { p1: 0, p2: 1 });
    room.removePlayer('p2');
    expect(mod.removePlayer).toHaveBeenCalledWith('p2');
    expect(room.allPlayerIds).not.toContain('p2');
    expect(room.disconnectedPlayers.has('p2')).toBe(true);
  });

  it('addLatePlayer registers the player and adds them to the module', () => {
    const mod = spyModule();
    const room = new GameRoom(mod, 'p1' as PlayerId, ['p1'], 'Test', { maxPlayers: 4 }, { p1: 0 });
    const late = makeConn('p3');
    room.addLatePlayer(late, 'g1');
    expect(mod.addPlayer).toHaveBeenCalledWith('p3', 0, 'p3');
    expect(room.allPlayerIds).toContain('p3');
    expect(room.playerConnections.has('p3')).toBe(true);
  });
});
