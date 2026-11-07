import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { afterEach, describe, expect, it } from 'vitest';
import { defaultGameModuleFactory } from '../../game/game-module.js';
import { LobbyManager } from '../../lobby/lobby-manager.js';
import { buildRecordingConnection } from '../../testing/connection-builders.js';
import type { Connection } from '../../ws/connection.js';
import type { DebugContext } from '../debug-context.js';
import { registerConnectionTools } from './connections.js';
import { registerGameSpecificTools } from './game-specific.js';
import { registerGameStateTools } from './game-state.js';
import { registerPerformanceTools } from './performance.js';
import { registerRoomTools } from './rooms.js';

interface Harness {
  lobbyManager: LobbyManager;
  call: (name: string, args?: Record<string, unknown>) => Promise<CallToolResult>;
  /** Creates a game for `alice`; it stays pending until `startGame`. */
  createGame: () => string;
  startGame: (gameId: string) => void;
}

const openClients: Client[] = [];
const openLobbies: LobbyManager[] = [];

function textOf(result: CallToolResult): string {
  const [block] = result.content;
  return block?.type === 'text' ? block.text : '';
}

function jsonOf(result: CallToolResult): unknown {
  return JSON.parse(textOf(result));
}

async function buildHarness(getRoomGameState?: DebugContext['getRoomGameState']): Promise<Harness> {
  const lobbyManager = new LobbyManager(defaultGameModuleFactory);
  const connections = new Map<string, Connection>();
  const handlers = lobbyManager.createHandlers(connections);
  const { connection: alice } = buildRecordingConnection('alice', 2);
  connections.set('alice', alice);

  const context: DebugContext = { lobbyManager, connections, getRoomGameState };
  const mcp = new McpServer({ name: 'test', version: '1.0.0' });
  registerConnectionTools(mcp, context);
  registerPerformanceTools(mcp, context);
  registerRoomTools(mcp, context);
  registerGameStateTools(mcp, context);
  registerGameSpecificTools(mcp, context);

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'test', version: '1.0.0' });
  await Promise.all([mcp.connect(serverTransport), client.connect(clientTransport)]);
  openClients.push(client);
  openLobbies.push(lobbyManager);

  return {
    lobbyManager,
    call: async (name, args = {}) => (await client.callTool({ name, arguments: args })) as CallToolResult,
    createGame: () => {
      handlers.onCreateGame(alice, { type: 'create_game', gameName: 'Arena', config: { maxPlayers: 4 } });
      return lobbyManager.listGames()[0]!.gameId;
    },
    startGame: (gameId) => handlers.onStartGame(alice, { type: 'start_game', gameId }),
  };
}

describe('debug MCP tools', () => {
  afterEach(async () => {
    for (const lobby of openLobbies.splice(0)) {
      for (const room of lobby.listActiveRooms().values()) room.stop();
    }
    await Promise.all(openClients.splice(0).map((client) => client.close()));
  });

  it('debug_get_connections lists the connected players', async () => {
    const { call } = await buildHarness();
    expect(jsonOf(await call('debug_get_connections'))).toEqual([
      { playerId: 'alice', playerName: 'alice', avatarIndex: 2, readyState: 1 },
    ]);
  });

  it('debug_get_performance counts rooms, pending games and connections', async () => {
    const harness = await buildHarness();
    harness.startGame(harness.createGame());
    harness.createGame();
    expect(jsonOf(await harness.call('debug_get_performance'))).toMatchObject({
      activeRooms: 1,
      pendingGames: 1,
      totalConnections: 1,
    });
  });

  it('debug_get_room_performance reports one room, every room, or why it has none', async () => {
    const harness = await buildHarness();
    expect(textOf(await harness.call('debug_get_room_performance'))).toBe('No active rooms');

    const missing = await harness.call('debug_get_room_performance', { gameId: 'missing' });
    expect(missing.isError).toBe(true);
    expect(textOf(missing)).toBe('Room "missing" not found');

    const gameId = harness.createGame();
    harness.startGame(gameId);
    const expectedRoom = { gameId, playerCount: 1, sampleCount: 0 };
    expect(jsonOf(await harness.call('debug_get_room_performance', { gameId }))).toMatchObject([expectedRoom]);
    expect(jsonOf(await harness.call('debug_get_room_performance'))).toMatchObject([expectedRoom]);
  });

  it('debug_list_games lists pending and active games', async () => {
    const harness = await buildHarness();
    const startedId = harness.createGame();
    harness.startGame(startedId);
    const pendingId = harness.createGame();
    const common = { gameName: 'Arena', creatorId: 'alice', playerCount: 1, maxPlayers: 4 };
    expect(jsonOf(await harness.call('debug_list_games'))).toEqual([
      { gameId: pendingId, status: 'pending', ...common },
      { gameId: startedId, status: 'active', ...common },
    ]);
  });

  it('debug_get_room shows membership, and a shared error for an unknown game', async () => {
    const harness = await buildHarness();
    const gameId = harness.createGame();
    harness.startGame(gameId);
    expect(jsonOf(await harness.call('debug_get_room', { gameId }))).toMatchObject({
      gameId,
      connected: ['alice'],
      disconnected: [],
      allPlayerIds: ['alice'],
    });
    expect((await harness.call('debug_get_room', { gameId: 'missing' })).isError).toBe(true);
  });

  it('debug_get_game_state falls back to the snapshot until a game wires its own state', async () => {
    const harness = await buildHarness();
    const gameId = harness.createGame();
    harness.startGame(gameId);
    expect(jsonOf(await harness.call('debug_get_game_state', { gameId }))).toMatchObject({
      snapshot: { players: { alice: null } },
    });
  });

  it('debug_get_game_state returns the wired game state', async () => {
    const harness = await buildHarness((gameId) => ({ wiredFor: gameId }));
    const gameId = harness.createGame();
    harness.startGame(gameId);
    expect(jsonOf(await harness.call('debug_get_game_state', { gameId }))).toEqual({ wiredFor: gameId });
  });

  it('rejects a call without its required argument', async () => {
    const { call } = await buildHarness();
    expect((await call('debug_get_room')).isError).toBe(true);
  });
});
