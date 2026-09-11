// Unit (docs/ENGINEERING.md §2.2): MultiplayerService + WebSocketService over a fake browser
// socket — outbound verbs, queueing until the socket opens, and every inbound message variant.
import { TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { GameId, LobbyGameInfo, PlayerId } from '@base-multiplayer-game/shared';
import { MultiplayerService } from './multiplayer.service';
import { IdentityService } from './identity.service';
import { FakeWebSocket } from '../../testing/fake-websocket';

const CLIENT_ID = 'alice' as PlayerId;
const OTHER_PLAYER_ID = 'bob' as PlayerId;
const GAME_ID = 'g1' as GameId;
const MAX_PLAYERS = 4;
const AVATAR_INDEX = 2;
const FIRST_TICK = 1;
const SECOND_TICK = 2;
const REJOIN_TICK = 7;
const BINARY_FRAME = new ArrayBuffer(8);
const SESSION_CONFIG = { maxPlayers: MAX_PLAYERS };

function openService(): { service: MultiplayerService; socket: FakeWebSocket } {
  const service = TestBed.inject(MultiplayerService);
  service.connect();
  const socket = FakeWebSocket.latest();
  socket.open();
  return { service, socket };
}

function receive(socket: FakeWebSocket, message: object): void {
  socket.receive(JSON.stringify(message));
}

describe('MultiplayerService', () => {
  beforeEach(() => {
    FakeWebSocket.reset();
    vi.stubGlobal('WebSocket', FakeWebSocket);
    TestBed.configureTestingModule({ providers: [{ provide: IdentityService, useValue: { clientId: CLIENT_ID } }] });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('queues verbs until the socket opens, then sends every lobby verb and input in order', () => {
    const service = TestBed.inject(MultiplayerService);
    service.connect();
    service.joinLobby('Alice', AVATAR_INDEX);
    const socket = FakeWebSocket.latest();
    expect(socket.url).toContain(`clientId=${CLIENT_ID}`);
    expect(socket.sentMessages()).toEqual([]);
    expect(service.connected()).toBe(false);

    socket.open();
    service.updatePlayerInfo('Alice B', AVATAR_INDEX);
    service.createGame('Room', SESSION_CONFIG);
    service.joinGame(GAME_ID);
    service.startGame(GAME_ID);
    service.deleteGame(GAME_ID);
    service.sendInput({ move: 'up' });

    expect(service.connected()).toBe(true);
    expect(socket.sentMessages()).toEqual([
      { type: 'join_lobby', playerName: 'Alice', avatarIndex: AVATAR_INDEX },
      { type: 'update_player_info', playerName: 'Alice B', avatarIndex: AVATAR_INDEX },
      { type: 'create_game', gameName: 'Room', config: SESSION_CONFIG },
      { type: 'join_game', gameId: GAME_ID },
      { type: 'start_game', gameId: GAME_ID },
      { type: 'delete_game', gameId: GAME_ID },
      { type: 'player_input', payload: { move: 'up' } },
    ]);
  });

  it('does not open a second socket while one is connecting or open', () => {
    const { service } = openService();
    service.connect();
    expect(FakeWebSocket.instances).toHaveLength(1);
  });

  it('mirrors lobby updates and server errors into signals', () => {
    const { service, socket } = openService();
    const games: LobbyGameInfo[] = [
      { gameId: GAME_ID, gameName: 'Room', players: [], maxPlayers: MAX_PLAYERS, started: false, creatorId: CLIENT_ID },
    ];
    receive(socket, { type: 'lobby_update', games });
    receive(socket, { type: 'error', message: 'Game is full' });
    expect(service.games()).toEqual(games);
    expect(service.lastError()).toBe('Game is full');
    expect(service.inGame()).toBe(false);
  });

  it('enters the room on game_started and tracks players joining and leaving', () => {
    const { service, socket } = openService();
    receive(socket, {
      type: 'game_started',
      gameId: GAME_ID,
      playerId: CLIENT_ID,
      playerIds: [CLIENT_ID],
      isHost: true,
      config: SESSION_CONFIG,
    });
    expect(service.phase()).toBe('in-game');
    expect(service.gameId()).toBe(GAME_ID);
    expect(service.playerId()).toBe(CLIENT_ID);
    expect(service.isHost()).toBe(true);
    expect(service.sessionConfig()).toEqual(SESSION_CONFIG);

    receive(socket, { type: 'player_joined', playerId: OTHER_PLAYER_ID, avatarIndex: AVATAR_INDEX });
    receive(socket, { type: 'player_joined', playerId: OTHER_PLAYER_ID, avatarIndex: AVATAR_INDEX });
    expect(service.playerIds()).toEqual([CLIENT_ID, OTHER_PLAYER_ID]);
    expect(service.avatarAssignments()).toEqual({ [OTHER_PLAYER_ID]: AVATAR_INDEX });

    receive(socket, { type: 'player_disconnected', playerId: OTHER_PLAYER_ID });
    expect(service.playerIds()).toEqual([CLIENT_ID]);
  });

  it('rebuilds the room from game_state when (re)joining', () => {
    const { service, socket } = openService();
    const snapshot = { tick: REJOIN_TICK };
    receive(socket, {
      type: 'game_state',
      gameId: GAME_ID,
      playerId: CLIENT_ID,
      playerIds: [CLIENT_ID, OTHER_PLAYER_ID],
      config: SESSION_CONFIG,
      avatarAssignments: { [CLIENT_ID]: 0 },
      snapshot,
    });
    expect(service.inGame()).toBe(true);
    expect(service.playerIds()).toEqual([CLIENT_ID, OTHER_PLAYER_ID]);
    expect(service.avatarAssignments()).toEqual({ [CLIENT_ID]: 0 });
    expect(service.snapshot()).toEqual(snapshot);
  });

  it('coalesces snapshot frames: a drain returns only the freshest one, then null', () => {
    const { service, socket } = openService();
    receive(socket, { type: 'game_snapshot', snapshot: { tick: FIRST_TICK } });
    receive(socket, { type: 'game_snapshot', snapshot: { tick: SECOND_TICK } });
    expect(service.latestSnapshot()).toEqual({ tick: SECOND_TICK });
    expect(service.snapshot()).toEqual({ tick: SECOND_TICK });
    expect(service.latestSnapshot()).toBeNull();
  });

  it('ignores malformed frames and reconnects after an unexpected close', () => {
    vi.useFakeTimers();
    const { service, socket } = openService();
    receive(socket, { type: 'game_snapshot', snapshot: { tick: FIRST_TICK } });
    socket.receive('not json');
    socket.receive(BINARY_FRAME);
    socket.receive('{"type":"game_snapshot" broken');
    expect(service.lastError()).toBeNull();
    expect(service.latestSnapshot()).toEqual({ tick: FIRST_TICK });

    socket.close();
    expect(service.connected()).toBe(false);
    vi.runAllTimers();
    expect(FakeWebSocket.instances).toHaveLength(2);
  });

  it('does not reconnect after the user disconnects', () => {
    vi.useFakeTimers();
    const { service } = openService();
    service.disconnect();
    vi.runAllTimers();
    expect(service.connected()).toBe(false);
    expect(FakeWebSocket.instances).toHaveLength(1);
  });
});
