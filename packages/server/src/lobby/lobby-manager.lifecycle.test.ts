import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { LobbyGameInfo } from '@base-multiplayer-game/shared';
import type { GameModule, GameModuleFactory, RoomInitArgs } from '../game/game-module.js';
import { buildRecordingConnection, messagesOfType, type RecordingConnection } from '../testing/connection-builders.js';
import type { Connection } from '../ws/connection.js';
import type { MessageHandlers } from '../ws/message-router.js';
import { DISCONNECT_GRACE_MS, LobbyManager } from './lobby-manager.js';

const CLIENT_REPORT = { fps: 60, frameTimeAvgMs: 16, frameTimeP95Ms: 18, frameTimePeakMs: 30, heapMb: null };

interface Lobby {
  lobby: LobbyManager;
  handlers: MessageHandlers;
  connections: Map<string, Connection>;
  gameModule: GameModule;
  factory: ReturnType<typeof vi.fn<(args: RoomInitArgs) => GameModule>>;
  alice: RecordingConnection;
  bob: RecordingConnection;
}

/** A lobby with two connected players, Alice and Bob, neither in a game yet. */
function buildLobby(): Lobby {
  const gameModule: GameModule = {
    submitInput: vi.fn(),
    reduceGameState: vi.fn(),
    serializeRoomState: vi.fn(() => ({ tick: 7 })),
    addPlayer: vi.fn(),
    removePlayer: vi.fn(),
    free: vi.fn(),
  };
  const factory = vi.fn<GameModuleFactory>(() => gameModule);
  const lobby = new LobbyManager(factory);
  const connections = new Map<string, Connection>();
  const handlers = lobby.createHandlers(connections);
  const alice = buildRecordingConnection('alice', 1);
  const bob = buildRecordingConnection('bob', 2);
  connections.set('alice', alice.connection);
  connections.set('bob', bob.connection);
  return { lobby, handlers, connections, gameModule, factory, alice, bob };
}

function createGame({ lobby, handlers, alice }: Lobby, maxPlayers = 4): string {
  handlers.onCreateGame(alice.connection, { type: 'create_game', gameName: 'Arena', config: { maxPlayers } });
  return lobby.listGames()[0]!.gameId;
}

function joinGame({ handlers, bob }: Lobby, gameId: string): void {
  handlers.onJoinGame(bob.connection, { type: 'join_game', gameId });
}

function startGame({ handlers, alice }: Lobby, gameId: string): void {
  handlers.onStartGame(alice.connection, { type: 'start_game', gameId });
}

/** A game Alice created and started, with Bob in it. */
function startTwoPlayerGame(context: Lobby): string {
  const gameId = createGame(context);
  joinGame(context, gameId);
  startGame(context, gameId);
  return gameId;
}

/** Runs `action` and returns the games from the single lobby_update it must have sent `watcher`. */
function gamesFromOneUpdate(watcher: RecordingConnection, action: () => void): LobbyGameInfo[] {
  const updatesBefore = messagesOfType(watcher.sent, 'lobby_update').length;
  action();
  const updates = messagesOfType(watcher.sent, 'lobby_update');
  expect(updates).toHaveLength(updatesBefore + 1);
  return updates.at(-1)!.games;
}

describe('lobby-manager lifecycle', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('lobby verbs', () => {
    it('join_lobby stores the profile and answers with the games', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      context.handlers.onJoinLobby(context.bob.connection, {
        type: 'join_lobby',
        playerName: 'Robert',
        avatarIndex: 3,
      });
      expect(context.bob.connection).toMatchObject({ playerName: 'Robert', avatarIndex: 3 });
      expect(messagesOfType(context.bob.sent, 'lobby_update').at(-1)?.games[0]?.gameId).toBe(gameId);
    });

    it('update_player_info refreshes the player in their pending game', () => {
      const context = buildLobby();
      createGame(context);
      context.handlers.onUpdatePlayerInfo(context.alice.connection, {
        type: 'update_player_info',
        playerName: 'Alicia',
        avatarIndex: 5,
      });
      expect(context.lobby.listGames()[0]?.players).toEqual([
        { playerId: 'alice', playerName: 'Alicia', avatarIndex: 5 },
      ]);
    });

    it('update_player_info outside a game still updates the connection and tells the lobby', () => {
      const context = buildLobby();
      context.handlers.onUpdatePlayerInfo(context.bob.connection, {
        type: 'update_player_info',
        playerName: 'Robert',
        avatarIndex: 3,
      });
      expect(context.bob.connection.playerName).toBe('Robert');
      expect(messagesOfType(context.alice.sent, 'lobby_update')).toHaveLength(1);
    });

    it('update_player_info during a started game leaves the room as it was', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.handlers.onUpdatePlayerInfo(context.bob.connection, {
        type: 'update_player_info',
        playerName: 'Robert',
        avatarIndex: 3,
      });
      expect(context.lobby.getActiveRoom(gameId)?.playerNames['bob']).toBe('bob');
    });

    it('join_game refuses a full game', () => {
      const context = buildLobby();
      const gameId = createGame(context, 1);
      joinGame(context, gameId);
      expect(context.bob.sent).toContainEqual({ type: 'error', message: 'Game is full' });
      expect(context.lobby.listGames()[0]?.players).toHaveLength(1);
    });

    it('join_game on a started game is a late join', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      startGame(context, gameId);
      joinGame(context, gameId);
      expect(context.gameModule.addPlayer).toHaveBeenCalledWith('bob', 2, 'bob');
      expect(messagesOfType(context.bob.sent, 'game_state')).toHaveLength(1);
      expect(context.alice.sent).toContainEqual({ type: 'player_joined', playerId: 'bob', avatarIndex: 2 });
      expect(context.lobby.listGames()[0]?.players.map((player) => player.playerId)).toEqual(['alice', 'bob']);

      context.handlers.onPlayerInput(context.bob.connection, { type: 'player_input', payload: 'late' });
      expect(context.gameModule.submitInput).toHaveBeenCalledWith('bob', 'late');
      expect(messagesOfType(context.bob.sent, 'error')).toEqual([]);
    });

    it('start_game hands the game module every player and their profile', () => {
      const context = buildLobby();
      startTwoPlayerGame(context);
      expect(context.factory).toHaveBeenCalledWith({
        creatorId: 'alice',
        playerIds: ['alice', 'bob'],
        gameName: 'Arena',
        config: { maxPlayers: 4 },
        avatarAssignments: { alice: 1, bob: 2 },
        playerNames: { alice: 'alice', bob: 'bob' },
      });
    });

    it('start_game tells each player whether they host', () => {
      const context = buildLobby();
      startTwoPlayerGame(context);
      expect(messagesOfType(context.alice.sent, 'game_started')[0]?.isHost).toBe(true);
      expect(messagesOfType(context.bob.sent, 'game_started')[0]?.isHost).toBe(false);
    });

    it('start_game skips a player who has no live connection', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      joinGame(context, gameId);
      context.connections.delete('bob');
      startGame(context, gameId);
      expect(context.lobby.getActiveRoom(gameId)?.playerConnections.has('bob')).toBe(false);
      expect(messagesOfType(context.bob.sent, 'game_started')).toHaveLength(0);
    });

    it('delete_game refuses anyone but the creator, pending or started', () => {
      const context = buildLobby();
      const refusal = { type: 'error', message: 'Only the creator can delete the game' };
      const pendingId = createGame(context);
      joinGame(context, pendingId);
      context.handlers.onDeleteGame(context.bob.connection, { type: 'delete_game', gameId: pendingId });
      expect(context.bob.sent.filter((message) => message.type === 'error')).toEqual([refusal]);

      startGame(context, pendingId);
      context.handlers.onDeleteGame(context.bob.connection, { type: 'delete_game', gameId: pendingId });
      expect(context.bob.sent.filter((message) => message.type === 'error')).toEqual([refusal, refusal]);
      expect(context.lobby.getActiveRoom(pendingId)).toBeDefined();
    });

    it('delete_game by the creator tears a started game down and frees its players', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.handlers.onDeleteGame(context.alice.connection, { type: 'delete_game', gameId });
      expect(context.lobby.getActiveRoom(gameId)).toBeUndefined();
      expect(context.gameModule.free).toHaveBeenCalledOnce();
      expect(context.lobby.gameIdOfPlayer('alice')).toBeUndefined();
      expect(context.lobby.gameIdOfPlayer('bob')).toBeUndefined();
    });

    it('delete_game on an unknown id does nothing', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      context.handlers.onDeleteGame(context.alice.connection, { type: 'delete_game', gameId: 'missing' });
      expect(context.lobby.listGames().map((game) => game.gameId)).toEqual([gameId]);
    });

    it('player_input and client_performance are dropped outside a started game', () => {
      const context = buildLobby();
      context.handlers.onPlayerInput(context.bob.connection, { type: 'player_input', payload: 1 });
      context.handlers.onClientPerformance(context.bob.connection, {
        type: 'client_performance',
        report: CLIENT_REPORT,
      });
      createGame(context);
      context.handlers.onPlayerInput(context.alice.connection, { type: 'player_input', payload: 1 });
      expect(context.gameModule.submitInput).not.toHaveBeenCalled();
    });

    it('client_performance reaches the room the player is in', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.handlers.onClientPerformance(context.bob.connection, {
        type: 'client_performance',
        report: CLIENT_REPORT,
      });
      expect(context.lobby.getActiveRoom(gameId)?.perfTracker.clientReportsSnapshot()).toEqual({ bob: CLIENT_REPORT });
    });
  });

  describe('lobby_update broadcasts', () => {
    it('create_game announces the new game', () => {
      const context = buildLobby();
      const games = gamesFromOneUpdate(context.bob, () => createGame(context));
      expect(games.map((game) => game.gameName)).toEqual(['Arena']);
    });

    it('join_game announces the new player in a pending game', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      const games = gamesFromOneUpdate(context.alice, () => joinGame(context, gameId));
      expect(games[0]?.players).toHaveLength(2);
    });

    it('join_game announces a late player in a started game', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      startGame(context, gameId);
      const games = gamesFromOneUpdate(context.alice, () => joinGame(context, gameId));
      expect(games[0]?.players).toHaveLength(2);
    });

    it('start_game announces the started game', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      const games = gamesFromOneUpdate(context.bob, () => startGame(context, gameId));
      expect(games[0]?.started).toBe(true);
    });

    it('delete_game announces a removed pending game', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      const games = gamesFromOneUpdate(context.bob, () =>
        context.handlers.onDeleteGame(context.alice.connection, { type: 'delete_game', gameId }),
      );
      expect(games).toEqual([]);
    });

    it('delete_game announces a removed started game', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      const games = gamesFromOneUpdate(context.bob, () =>
        context.handlers.onDeleteGame(context.alice.connection, { type: 'delete_game', gameId }),
      );
      expect(games).toEqual([]);
    });

    it('a disconnect from a pending game announces the change', () => {
      const context = buildLobby();
      joinGame(context, createGame(context));
      const games = gamesFromOneUpdate(context.alice, () => context.lobby.handleDisconnect(context.bob.connection));
      expect(games[0]?.players).toHaveLength(1);
    });
  });

  describe('pending-game disconnects', () => {
    it('ignores a player who is in no game', () => {
      const context = buildLobby();
      context.lobby.handleDisconnect(context.bob.connection);
      expect(context.bob.sent).toEqual([]);
    });

    it('removes a pending game when its last player leaves', () => {
      const context = buildLobby();
      createGame(context);
      context.lobby.handleDisconnect(context.alice.connection);
      expect(context.lobby.listGames()).toEqual([]);
    });

    it('hands the creator role on when the creator leaves', () => {
      const context = buildLobby();
      joinGame(context, createGame(context));
      context.lobby.handleDisconnect(context.alice.connection);
      expect(context.lobby.listGames()[0]).toMatchObject({ creatorId: 'bob' });
    });

    it('keeps the creator when another player leaves', () => {
      const context = buildLobby();
      joinGame(context, createGame(context));
      context.lobby.handleDisconnect(context.bob.connection);
      expect(context.lobby.listGames()[0]).toMatchObject({ creatorId: 'alice' });
      expect(context.lobby.listGames()[0]?.players).toHaveLength(1);
    });
  });

  describe('started-game disconnect grace', () => {
    it('tells the room and keeps the player until the grace window ends', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.lobby.handleDisconnect(context.bob.connection);
      expect(context.alice.sent).toContainEqual({ type: 'player_disconnected', playerId: 'bob' });
      expect(context.lobby.getActiveRoom(gameId)?.disconnectedPlayers.has('bob')).toBe(true);

      vi.advanceTimersByTime(DISCONNECT_GRACE_MS - 1);
      expect(context.gameModule.removePlayer).not.toHaveBeenCalled();
      vi.advanceTimersByTime(1);
      expect(context.gameModule.removePlayer).toHaveBeenCalledWith('bob');
      expect(context.lobby.getActiveRoom(gameId)?.allPlayerIds).toEqual(['alice']);
    });

    it('tears the room down when the grace window ends for the last player', () => {
      const context = buildLobby();
      const gameId = createGame(context);
      startGame(context, gameId);
      context.lobby.handleDisconnect(context.alice.connection);
      vi.advanceTimersByTime(DISCONNECT_GRACE_MS);
      expect(context.lobby.getActiveRoom(gameId)).toBeUndefined();
      expect(context.gameModule.free).toHaveBeenCalledOnce();
    });

    it('does nothing when the grace window ends after the room is gone', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.lobby.handleDisconnect(context.bob.connection);
      context.handlers.onDeleteGame(context.alice.connection, { type: 'delete_game', gameId });
      vi.advanceTimersByTime(DISCONNECT_GRACE_MS);
      expect(context.gameModule.removePlayer).not.toHaveBeenCalled();
    });

    it('a reconnect within the window cancels the removal and resends the game', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.lobby.handleDisconnect(context.bob.connection);

      const returning = buildRecordingConnection('bob', 2);
      context.lobby.handleConnect(returning.connection, context.connections);
      vi.advanceTimersByTime(DISCONNECT_GRACE_MS);

      const room = context.lobby.getActiveRoom(gameId);
      expect(context.gameModule.removePlayer).not.toHaveBeenCalled();
      expect(room?.disconnectedPlayers.has('bob')).toBe(false);
      expect(room?.playerConnections.get('bob')).toBe(returning.connection);
      expect(messagesOfType(returning.sent, 'game_snapshot').length).toBeGreaterThan(0);
      expect(messagesOfType(returning.sent, 'game_state')[0]).toMatchObject({
        gameId,
        playerId: 'bob',
        snapshot: { tick: 7 },
        playerIds: ['alice', 'bob'],
      });
    });

    it('a reconnect after the window has no game left to rejoin', () => {
      const context = buildLobby();
      const gameId = startTwoPlayerGame(context);
      context.lobby.handleDisconnect(context.bob.connection);
      vi.advanceTimersByTime(DISCONNECT_GRACE_MS);

      const returning = buildRecordingConnection('bob', 2);
      context.lobby.handleConnect(returning.connection, context.connections);

      expect(context.lobby.gameIdOfPlayer('bob')).toBeUndefined();
      expect(context.lobby.getActiveRoom(gameId)?.playerConnections.has('bob')).toBe(false);
      expect(messagesOfType(returning.sent, 'game_state')).toEqual([]);
    });

    it('a connect from a player with no game or only a pending game sends no state', () => {
      const context = buildLobby();
      createGame(context);
      context.lobby.handleConnect(context.alice.connection, context.connections);
      context.lobby.handleConnect(context.bob.connection, context.connections);
      expect(messagesOfType(context.alice.sent, 'game_state')).toEqual([]);
      expect(messagesOfType(context.bob.sent, 'game_state')).toEqual([]);
    });
  });
});
