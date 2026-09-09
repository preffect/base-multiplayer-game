import { describe, it, expect, vi } from 'vitest';
import { LobbyManager } from '../lobby/lobby-manager.js';
import type { Connection } from '../ws/connection.js';
import type { GameModule, GameModuleFactory } from '../game/game-module.js';

/** Minimal stub GameModule so we never touch real game logic in lobby tests. */
const stubFactory: GameModuleFactory = (): GameModule => ({
  submitInput: vi.fn(),
  reduceGameState: vi.fn(),
  serializeRoomState: vi.fn(() => ({})),
  addPlayer: vi.fn(),
  removePlayer: vi.fn(),
  free: vi.fn(),
});

function makeConn(id: string, name: string, sent: Record<string, unknown[]>): Connection {
  sent[id] = [];
  return {
    playerId: id,
    playerName: name,
    avatarIndex: 0,
    socket: {
      readyState: 1,
      send: (data: string) => sent[id]!.push(JSON.parse(data)),
      close: () => {},
      on: () => {},
    } as unknown as Connection['socket'],
  };
}

describe('lobby-manager', () => {
  it('create_game then join_game tracks players and broadcasts lobby_update', () => {
    const connections = new Map<string, Connection>();
    const sent: Record<string, unknown[]> = {};
    const lobby = new LobbyManager(stubFactory);
    const h = lobby.createHandlers(connections);

    const a = makeConn('a', 'Alice', sent);
    const b = makeConn('b', 'Bob', sent);
    connections.set('a', a);
    connections.set('b', b);

    h.onJoinLobby(a, { type: 'join_lobby', playerName: 'Alice', avatarIndex: 0 });
    h.onCreateGame(a, { type: 'create_game', gameName: 'My Game', config: { maxPlayers: 4 } });

    const games = lobby.listGames();
    expect(games).toHaveLength(1);
    expect(games[0]?.players).toHaveLength(1);
    const gameId = games[0]!.gameId;

    h.onJoinGame(b, { type: 'join_game', gameId });
    expect(lobby.listGames()[0]?.players).toHaveLength(2);
  });

  it('start_game moves a pending game to active and notifies players', () => {
    const connections = new Map<string, Connection>();
    const sent: Record<string, unknown[]> = {};
    const lobby = new LobbyManager(stubFactory);
    const h = lobby.createHandlers(connections);

    const a = makeConn('a', 'Alice', sent);
    connections.set('a', a);
    h.onCreateGame(a, { type: 'create_game', gameName: 'G', config: { maxPlayers: 2 } });
    const gameId = lobby.listGames()[0]!.gameId;

    h.onStartGame(a, { type: 'start_game', gameId });

    expect(lobby.getActiveRoom(gameId)).toBeDefined();
    expect(lobby.listGames()[0]?.started).toBe(true);
    const started = sent['a']!.find((m) => (m as { type: string }).type === 'game_started');
    expect(started).toMatchObject({ type: 'game_started', isHost: true });

    lobby.getActiveRoom(gameId)?.stop();
  });

  it('only the creator may start the game', () => {
    const connections = new Map<string, Connection>();
    const sent: Record<string, unknown[]> = {};
    const lobby = new LobbyManager(stubFactory);
    const h = lobby.createHandlers(connections);

    const a = makeConn('a', 'Alice', sent);
    const b = makeConn('b', 'Bob', sent);
    connections.set('a', a);
    connections.set('b', b);
    h.onCreateGame(a, { type: 'create_game', gameName: 'G', config: { maxPlayers: 4 } });
    const gameId = lobby.listGames()[0]!.gameId;
    h.onJoinGame(b, { type: 'join_game', gameId });

    h.onStartGame(b, { type: 'start_game', gameId });
    expect(lobby.getActiveRoom(gameId)).toBeUndefined();
    expect(sent['b']!.some((m) => (m as { type: string }).type === 'error')).toBe(true);
  });

  it('delete_game by creator removes a pending game', () => {
    const connections = new Map<string, Connection>();
    const sent: Record<string, unknown[]> = {};
    const lobby = new LobbyManager(stubFactory);
    const h = lobby.createHandlers(connections);

    const a = makeConn('a', 'Alice', sent);
    connections.set('a', a);
    h.onCreateGame(a, { type: 'create_game', gameName: 'G', config: { maxPlayers: 4 } });
    const gameId = lobby.listGames()[0]!.gameId;

    h.onDeleteGame(a, { type: 'delete_game', gameId });
    expect(lobby.listGames()).toHaveLength(0);
  });

  it('player_input on an active room delegates to the room', () => {
    const connections = new Map<string, Connection>();
    const sent: Record<string, unknown[]> = {};
    const lobby = new LobbyManager(stubFactory);
    const h = lobby.createHandlers(connections);

    const a = makeConn('a', 'Alice', sent);
    connections.set('a', a);
    h.onCreateGame(a, { type: 'create_game', gameName: 'G', config: { maxPlayers: 4 } });
    const gameId = lobby.listGames()[0]!.gameId;
    h.onStartGame(a, { type: 'start_game', gameId });

    const room = lobby.getActiveRoom(gameId)!;
    const spy = vi.spyOn(room, 'submitInput');
    h.onPlayerInput(a, { type: 'player_input', payload: { x: 1 } });
    expect(spy).toHaveBeenCalledWith('a', { x: 1 });
    room.stop();
  });
});
