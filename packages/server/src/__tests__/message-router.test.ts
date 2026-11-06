import { describe, it, expect } from 'vitest';
import { buildRecordingConnection } from '../testing/connection-builders.js';
import { buildStubHandlers } from '../testing/handler-builders.js';
import { createMessageRouter } from '../ws/message-router.js';

describe('message-router', () => {
  it('rejects invalid JSON with an error message', () => {
    const h = buildStubHandlers();
    const route = createMessageRouter(h);
    const { connection: conn, sent } = buildRecordingConnection('p1');
    route(conn, 'not json');
    expect(sent).toEqual([{ type: 'error', message: 'Invalid JSON' }]);
  });

  it('rejects schema-invalid messages', () => {
    const h = buildStubHandlers();
    const route = createMessageRouter(h);
    const { connection: conn, sent } = buildRecordingConnection('p1');
    route(conn, JSON.stringify({ type: 'join_lobby' }));
    expect(sent[0]).toMatchObject({ type: 'error' });
    expect(h.onJoinLobby).not.toHaveBeenCalled();
  });

  it('routes a valid join_lobby to the handler', () => {
    const h = buildStubHandlers();
    const route = createMessageRouter(h);
    const { connection: conn } = buildRecordingConnection('p1');
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
    const h = buildStubHandlers();
    const route = createMessageRouter(h);
    const { connection: conn, sent } = buildRecordingConnection('p1');
    route(conn, JSON.stringify(message));
    expect(h[handlerName]).toHaveBeenCalledWith(conn, expect.objectContaining(message));
    expect(sent).toEqual([]);
  });

  it('rejects an unknown message type', () => {
    const route = createMessageRouter(buildStubHandlers());
    const { connection: conn, sent } = buildRecordingConnection('p1');
    route(conn, JSON.stringify({ type: 'not_a_verb' }));
    expect(sent[0]).toMatchObject({ type: 'error' });
  });

  it('routes player_input with an opaque payload (client-trust)', () => {
    const h = buildStubHandlers();
    const route = createMessageRouter(h);
    const { connection: conn } = buildRecordingConnection('p1');
    const payload = { anything: [1, 2, 3] };
    route(conn, JSON.stringify({ type: 'player_input', payload }));
    expect(h.onPlayerInput).toHaveBeenCalledWith(conn, expect.objectContaining({ type: 'player_input', payload }));
  });
});
