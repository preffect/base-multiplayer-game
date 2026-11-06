import { describe, it, expect, vi } from 'vitest';
import { createMessageRouter, type MessageHandlers } from '../ws/message-router.js';
import type { Connection } from '../ws/connection.js';

function makeConn(): { conn: Connection; sent: unknown[] } {
  const sent: unknown[] = [];
  const conn = {
    playerId: 'p1',
    playerName: 'Alice',
    avatarIndex: 0,
    socket: {
      readyState: 1,
      send: (data: string) => sent.push(JSON.parse(data)),
      close: () => {},
      on: () => {},
    } as unknown as Connection['socket'],
  } satisfies Connection;
  return { conn, sent };
}

function stubHandlers(): MessageHandlers {
  return {
    onJoinLobby: vi.fn(),
    onUpdatePlayerInfo: vi.fn(),
    onCreateGame: vi.fn(),
    onJoinGame: vi.fn(),
    onStartGame: vi.fn(),
    onDeleteGame: vi.fn(),
    onPlayerInput: vi.fn(),
    onClientPerformance: vi.fn(),
  };
}

describe('message-router', () => {
  it('rejects invalid JSON with an error message', () => {
    const h = stubHandlers();
    const route = createMessageRouter(h);
    const { conn, sent } = makeConn();
    route(conn, 'not json');
    expect(sent).toEqual([{ type: 'error', message: 'Invalid JSON' }]);
  });

  it('rejects schema-invalid messages', () => {
    const h = stubHandlers();
    const route = createMessageRouter(h);
    const { conn, sent } = makeConn();
    route(conn, JSON.stringify({ type: 'join_lobby' }));
    expect(sent[0]).toMatchObject({ type: 'error' });
    expect(h.onJoinLobby).not.toHaveBeenCalled();
  });

  it('routes a valid join_lobby to the handler', () => {
    const h = stubHandlers();
    const route = createMessageRouter(h);
    const { conn } = makeConn();
    route(conn, JSON.stringify({ type: 'join_lobby', playerName: 'Bob', avatarIndex: 2 }));
    expect(h.onJoinLobby).toHaveBeenCalledWith(
      conn,
      expect.objectContaining({ type: 'join_lobby', playerName: 'Bob', avatarIndex: 2 }),
    );
  });

  it.each([
    ['onUpdatePlayerInfo', { type: 'update_player_info', playerName: 'Bob', avatarIndex: 1 }],
    ['onCreateGame', { type: 'create_game', gameName: 'Arena', config: { maxPlayers: 2 } }],
    ['onJoinGame', { type: 'join_game', gameId: 'game' }],
    ['onStartGame', { type: 'start_game', gameId: 'game' }],
    ['onDeleteGame', { type: 'delete_game', gameId: 'game' }],
    [
      'onClientPerformance',
      {
        type: 'client_performance',
        report: { fps: 60, frameTimeAvgMs: 16, frameTimeP95Ms: 18, frameTimePeakMs: 30, heapMb: null },
      },
    ],
  ] as const)('routes to %s', (handlerName, message) => {
    const h = stubHandlers();
    const route = createMessageRouter(h);
    const { conn, sent } = makeConn();
    route(conn, JSON.stringify(message));
    expect(h[handlerName]).toHaveBeenCalledWith(conn, expect.objectContaining(message));
    expect(sent).toEqual([]);
  });

  it('rejects an unknown message type', () => {
    const route = createMessageRouter(stubHandlers());
    const { conn, sent } = makeConn();
    route(conn, JSON.stringify({ type: 'not_a_verb' }));
    expect(sent[0]).toMatchObject({ type: 'error' });
  });

  it('routes player_input with an opaque payload (client-trust)', () => {
    const h = stubHandlers();
    const route = createMessageRouter(h);
    const { conn } = makeConn();
    const payload = { anything: [1, 2, 3] };
    route(conn, JSON.stringify({ type: 'player_input', payload }));
    expect(h.onPlayerInput).toHaveBeenCalledWith(conn, expect.objectContaining({ type: 'player_input', payload }));
  });
});
