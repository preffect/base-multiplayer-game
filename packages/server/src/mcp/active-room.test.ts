import { describe, expect, it, vi } from 'vitest';
import type { GameRoom } from '../lobby/game-room.js';
import { withActiveRoom } from './active-room.js';
import type { DebugContext } from './debug-context.js';
import { gameNotFoundResult, textResult } from './tool-result.js';

function contextWithRoom(room: GameRoom | undefined): DebugContext {
  return {
    lobbyManager: { getActiveRoom: vi.fn(() => room) },
    connections: new Map(),
  } as unknown as DebugContext;
}

describe('mcp/active-room', () => {
  it('runs the handler with the active room', () => {
    const room = { gameName: 'Room' } as GameRoom;
    const handler = vi.fn((activeRoom: GameRoom) => textResult(activeRoom.gameName));
    expect(withActiveRoom(contextWithRoom(room), 'g1', handler)).toEqual(textResult('Room'));
    expect(handler).toHaveBeenCalledWith(room);
  });

  it('answers with the shared not-found error and never calls the handler', () => {
    const handler = vi.fn();
    expect(withActiveRoom(contextWithRoom(undefined), 'missing', handler)).toEqual(gameNotFoundResult('missing'));
    expect(handler).not.toHaveBeenCalled();
  });
});
