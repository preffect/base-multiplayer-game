import { nanoid } from 'nanoid';
import type {
  PlayerId,
  GameId,
  LobbyGameInfo,
  LobbyPlayerInfo,
  GameSessionConfig,
} from '@base-multiplayer-game/shared';
import type { Connection } from '../ws/connection.js';
import { broadcastMessage, sendMessage } from '../ws/connection.js';
import type { MessageHandlers } from '../ws/message-router.js';
import { GameRoom } from './game-room.js';
import type { GameModuleFactory } from '../game/game-module.js';

const DISCONNECT_GRACE_MS = 30_000;

/** A game that has been created but not yet started — players gather here. */
export interface PendingGame {
  gameId: string;
  gameName: string;
  creatorId: string;
  config: GameSessionConfig;
  /** playerId -> presence. */
  players: Map<string, LobbyPlayerInfo>;
}

/**
 * Generic lobby + room lifecycle. Owns pending games, active rooms, the
 * player->game index, disconnect grace timers and lobby broadcasting. Game
 * logic is injected via a `GameModuleFactory` (the ONLY game seam here).
 */
export class LobbyManager {
  private readonly pendingGames = new Map<string, PendingGame>();
  private readonly activeRooms = new Map<string, GameRoom>();
  private readonly playerToGame = new Map<string, string>();
  /** playerId -> timer that will finalize their removal after the grace period. */
  private readonly pendingRemovals = new Map<string, ReturnType<typeof setTimeout>>();
  /** The shared connections registry (set when handlers are created). */
  private connections: Map<string, Connection> = new Map();

  constructor(private readonly gameFactory: GameModuleFactory) {}

  createHandlers(connections: Map<string, Connection>): MessageHandlers {
    this.connections = connections;
    return {
      onJoinLobby: (conn, msg) => this.onJoinLobby(conn, msg.playerName, msg.avatarIndex),
      onUpdatePlayerInfo: (conn, msg) => this.onUpdatePlayerInfo(conn, msg.playerName, msg.avatarIndex),
      onCreateGame: (conn, msg) => this.onCreateGame(conn, msg.gameName, msg.config),
      onJoinGame: (conn, msg) => this.onJoinGame(conn, msg.gameId),
      onStartGame: (conn, msg) => this.onStartGame(conn, msg.gameId),
      onDeleteGame: (conn, msg) => this.onDeleteGame(conn, msg.gameId),
      onPlayerInput: (conn, msg) => {
        const gid = this.playerToGame.get(conn.playerId);
        if (gid) this.activeRooms.get(gid)?.submitInput(conn.playerId, msg.payload);
      },
      onClientPerformance: (conn, msg) => {
        const gid = this.playerToGame.get(conn.playerId);
        if (gid) this.activeRooms.get(gid)?.recordClientPerf(conn.playerId, msg.report);
      },
    };
  }

  // ---- lobby verbs -------------------------------------------------------

  private onJoinLobby(conn: Connection, playerName: string, avatarIndex: number): void {
    conn.playerName = playerName;
    conn.avatarIndex = avatarIndex;
    sendMessage(conn, { type: 'lobby_update', games: this.listGames() });
  }

  private onUpdatePlayerInfo(conn: Connection, playerName: string, avatarIndex: number): void {
    conn.playerName = playerName;
    conn.avatarIndex = avatarIndex;
    // Reflect the change in any pending game the player has joined.
    const gid = this.playerToGame.get(conn.playerId);
    if (gid) {
      const pending = this.pendingGames.get(gid);
      pending?.players.set(conn.playerId, {
        playerId: conn.playerId as PlayerId,
        playerName,
        avatarIndex,
      });
    }
    this.broadcastLobbyUpdate();
  }

  private onCreateGame(conn: Connection, gameName: string, config: GameSessionConfig): void {
    const gameId = nanoid(10);
    const pending: PendingGame = {
      gameId,
      gameName,
      creatorId: conn.playerId,
      config,
      players: new Map([
        [
          conn.playerId,
          { playerId: conn.playerId as PlayerId, playerName: conn.playerName, avatarIndex: conn.avatarIndex },
        ],
      ]),
    };
    this.pendingGames.set(gameId, pending);
    this.playerToGame.set(conn.playerId, gameId);
    this.broadcastLobbyUpdate();
  }

  /** The pending game with this id, or undefined after telling the connection it does not exist. */
  private requirePendingGame(conn: Connection, gameId: string): PendingGame | undefined {
    const pending = this.pendingGames.get(gameId);
    if (!pending) sendMessage(conn, { type: 'error', message: 'Game not found' });
    return pending;
  }

  private onJoinGame(conn: Connection, gameId: string): void {
    // Joining an in-progress game = late join.
    const active = this.activeRooms.get(gameId);
    if (active) {
      this.playerToGame.set(conn.playerId, gameId);
      active.addLatePlayer(conn, gameId);
      this.broadcastLobbyUpdate();
      return;
    }

    const pending = this.requirePendingGame(conn, gameId);
    if (!pending) return;
    if (pending.players.size >= pending.config.maxPlayers) {
      sendMessage(conn, { type: 'error', message: 'Game is full' });
      return;
    }
    pending.players.set(conn.playerId, {
      playerId: conn.playerId as PlayerId,
      playerName: conn.playerName,
      avatarIndex: conn.avatarIndex,
    });
    this.playerToGame.set(conn.playerId, gameId);
    this.broadcastLobbyUpdate();
  }

  private onStartGame(conn: Connection, gameId: string): void {
    const pending = this.requirePendingGame(conn, gameId);
    if (!pending) return;
    if (pending.creatorId !== conn.playerId) {
      sendMessage(conn, { type: 'error', message: 'Only the creator can start the game' });
      return;
    }

    const playerIds = Array.from(pending.players.keys());
    const avatarAssignments: Record<string, number> = {};
    const playerNames: Record<string, string> = {};
    for (const [pid, info] of pending.players) {
      avatarAssignments[pid] = info.avatarIndex;
      playerNames[pid] = info.playerName;
    }

    const gameModule = this.gameFactory({
      creatorId: pending.creatorId as PlayerId,
      playerIds: playerIds as PlayerId[],
      gameName: pending.gameName,
      config: pending.config,
      avatarAssignments,
      playerNames,
    });

    const room = new GameRoom(
      gameModule,
      pending.creatorId as PlayerId,
      playerIds,
      pending.gameName,
      pending.config,
      avatarAssignments,
      playerNames,
    );

    for (const pid of playerIds) {
      const c = this.connections.get(pid);
      if (c) room.addPlayer(c);
    }

    // Tell each player the game has begun.
    for (const pid of playerIds) {
      const c = this.connections.get(pid);
      if (!c) continue;
      sendMessage(c, {
        type: 'game_started',
        gameId: gameId as GameId,
        playerId: pid as PlayerId,
        playerIds: playerIds as PlayerId[],
        isHost: pid === pending.creatorId,
        config: pending.config,
      });
    }

    this.pendingGames.delete(gameId);
    this.activeRooms.set(gameId, room);
    room.start();
    this.broadcastLobbyUpdate();
  }

  private onDeleteGame(conn: Connection, gameId: string): void {
    const pending = this.pendingGames.get(gameId);
    if (pending) {
      if (pending.creatorId !== conn.playerId) {
        sendMessage(conn, { type: 'error', message: 'Only the creator can delete the game' });
        return;
      }
      for (const pid of pending.players.keys()) this.playerToGame.delete(pid);
      this.pendingGames.delete(gameId);
      this.broadcastLobbyUpdate();
      return;
    }
    const active = this.activeRooms.get(gameId);
    if (active) {
      if (active.creatorId !== conn.playerId) {
        sendMessage(conn, { type: 'error', message: 'Only the creator can delete the game' });
        return;
      }
      this.teardownRoom(gameId);
    }
  }

  // ---- connection lifecycle ----------------------------------------------

  handleConnect(conn: Connection, _connections: Map<string, Connection>): void {
    // Cancel any pending removal — the player came back within the grace window.
    const timer = this.pendingRemovals.get(conn.playerId);
    if (timer) {
      clearTimeout(timer);
      this.pendingRemovals.delete(conn.playerId);
    }

    const gid = this.playerToGame.get(conn.playerId);
    if (!gid) return;
    const room = this.activeRooms.get(gid);
    if (room) {
      room.reattachPlayer(conn);
      // Resend the full game state so the reconnected client can resync.
      sendMessage(conn, {
        type: 'game_state',
        gameId: gid as GameId,
        playerId: conn.playerId as PlayerId,
        snapshot: room.getSnapshot(),
        config: room.sessionConfig,
        playerIds: room.allPlayerIds as PlayerId[],
        avatarAssignments: room.avatarAssignments,
      });
    }
  }

  handleDisconnect(conn: Connection): void {
    const gid = this.playerToGame.get(conn.playerId);
    if (!gid) return;

    // Pending game: remove immediately (no in-progress state to preserve).
    const pending = this.pendingGames.get(gid);
    if (pending) {
      pending.players.delete(conn.playerId);
      this.playerToGame.delete(conn.playerId);
      if (pending.players.size === 0) {
        this.pendingGames.delete(gid);
      } else if (pending.creatorId === conn.playerId) {
        // Hand creator role to the next remaining player.
        const next = pending.players.keys().next().value;
        if (next) pending.creatorId = next;
      }
      this.broadcastLobbyUpdate();
      return;
    }

    // Active room: keep a grace window for reconnect.
    const room = this.activeRooms.get(gid);
    if (!room) return;
    room.disconnectedPlayers.add(conn.playerId);
    broadcastMessage(room.playerConnections.values(), {
      type: 'player_disconnected',
      playerId: conn.playerId as PlayerId,
    });

    const timer = setTimeout(() => {
      this.pendingRemovals.delete(conn.playerId);
      const r = this.activeRooms.get(gid);
      if (!r) return;
      r.removePlayer(conn.playerId);
      this.playerToGame.delete(conn.playerId);
      if (r.playerConnections.size === 0) {
        this.teardownRoom(gid);
      }
    }, DISCONNECT_GRACE_MS);
    this.pendingRemovals.set(conn.playerId, timer);
  }

  private teardownRoom(gameId: string): void {
    const room = this.activeRooms.get(gameId);
    if (!room) return;
    room.stop();
    for (const pid of room.allPlayerIds) this.playerToGame.delete(pid);
    this.activeRooms.delete(gameId);
    this.broadcastLobbyUpdate();
  }

  // ---- queries (also used by MCP) ----------------------------------------

  listGames(): LobbyGameInfo[] {
    const out: LobbyGameInfo[] = [];
    for (const p of this.pendingGames.values()) {
      out.push({
        gameId: p.gameId as GameId,
        gameName: p.gameName,
        players: Array.from(p.players.values()),
        maxPlayers: p.config.maxPlayers,
        started: false,
        creatorId: p.creatorId as PlayerId,
      });
    }
    for (const [gid, room] of this.activeRooms) {
      out.push({
        gameId: gid as GameId,
        gameName: room.gameName,
        players: room.allPlayerIds.map((pid) => ({
          playerId: pid as PlayerId,
          playerName: room.playerNames[pid] ?? '',
          avatarIndex: room.avatarAssignments[pid] ?? 0,
        })),
        maxPlayers: room.sessionConfig.maxPlayers,
        started: true,
        creatorId: room.creatorId,
      });
    }
    return out;
  }

  getActiveRoom(gameId: string): GameRoom | undefined {
    return this.activeRooms.get(gameId);
  }

  listActiveRooms(): ReadonlyMap<string, GameRoom> {
    return this.activeRooms;
  }

  /** Pending (not-yet-started) games keyed by gameId. Used by MCP + tests. */
  listPendingGames(): ReadonlyMap<string, PendingGame> {
    return this.pendingGames;
  }

  private broadcastLobbyUpdate(): void {
    const games = this.listGames();
    broadcastMessage(this.connections.values(), { type: 'lobby_update', games });
  }
}
