import type { PlayerId, GameId, GameSnapshot, GameInput, GameSessionConfig } from '@base-multiplayer-game/shared';
import type { Connection } from '../ws/connection.js';
import { broadcastMessage, sendMessage } from '../ws/connection.js';
import { PerfTracker, type ClientPerfReport } from './perf-tracker.js';
import type { GameModule } from '../game/game-module.js';

const TICK_HZ = 60;
const TICK_INTERVAL_MS = 1000 / TICK_HZ;

/**
 * A running game session. Owns the connections, the late-join/disconnect
 * bookkeeping, the fixed-tick loop and perf telemetry. All game-specific guts
 * live behind the injected `GameModule` (the 3 tick hooks + add/removePlayer).
 */
export class GameRoom {
  readonly playerConnections = new Map<string, Connection>();
  readonly disconnectedPlayers = new Set<string>();
  readonly allPlayerIds: string[];
  readonly creatorId: PlayerId;
  readonly gameName: string;
  readonly sessionConfig: GameSessionConfig;
  readonly avatarAssignments: Record<string, number>;
  readonly playerNames: Record<string, string>;
  readonly perfTracker = new PerfTracker();

  private readonly game: GameModule;
  private tickInterval: ReturnType<typeof setInterval> | null = null;

  constructor(
    game: GameModule,
    creatorId: PlayerId,
    allPlayerIds: string[],
    gameName: string,
    sessionConfig: GameSessionConfig,
    avatarAssignments: Record<string, number>,
    playerNames: Record<string, string> = {},
  ) {
    this.game = game;
    this.creatorId = creatorId;
    this.allPlayerIds = [...allPlayerIds];
    this.gameName = gameName;
    this.sessionConfig = sessionConfig;
    this.avatarAssignments = { ...avatarAssignments };
    this.playerNames = { ...playerNames };
  }

  start(): void {
    if (!this.tickInterval) {
      this.tickInterval = setInterval(() => this.tickStep(), TICK_INTERVAL_MS);
    }
  }

  stop(): void {
    if (this.tickInterval) {
      clearInterval(this.tickInterval);
      this.tickInterval = null;
    }
    this.game.free?.();
  }

  addPlayer(conn: Connection): void {
    this.playerConnections.set(conn.playerId, conn);
  }

  reattachPlayer(conn: Connection): void {
    this.playerConnections.set(conn.playerId, conn);
    this.disconnectedPlayers.delete(conn.playerId);
  }

  submitInput(pid: string, payload: GameInput): void {
    this.game.submitInput(pid as PlayerId, payload);
  }

  recordClientPerf(pid: string, r: ClientPerfReport): void {
    this.perfTracker.recordClientReport(pid as PlayerId, r);
  }

  getSnapshot(): GameSnapshot {
    return this.game.serializeRoomState();
  }

  /** Player who was never part of the session joins an in-progress game. */
  addLatePlayer(conn: Connection, gid: string): void {
    const pid = conn.playerId;
    this.allPlayerIds.push(pid);
    this.avatarAssignments[pid] = conn.avatarIndex;
    this.playerNames[pid] = conn.playerName;
    this.playerConnections.set(pid, conn);
    this.game.addPlayer(pid as PlayerId, conn.avatarIndex, conn.playerName);
    broadcastMessage(
      Array.from(this.playerConnections.values()).filter((c) => c.playerId !== pid),
      { type: 'player_joined', playerId: pid as PlayerId, avatarIndex: conn.avatarIndex },
    );
    sendMessage(conn, {
      type: 'game_state',
      gameId: gid as GameId,
      playerId: pid as PlayerId,
      snapshot: this.game.serializeRoomState(),
      config: this.sessionConfig,
      playerIds: this.allPlayerIds as PlayerId[],
      avatarAssignments: this.avatarAssignments,
    });
  }

  removePlayer(pid: string): void {
    this.playerConnections.delete(pid);
    this.disconnectedPlayers.add(pid);
    this.perfTracker.removeClient(pid as PlayerId);
    this.game.removePlayer(pid as PlayerId);
    const i = this.allPlayerIds.indexOf(pid);
    if (i >= 0) this.allPlayerIds.splice(i, 1);
  }

  private tickStep(): void {
    const t0 = performance.now();
    this.game.reduceGameState(); // TODO hook: advance one tick
    const snapshot = this.game.serializeRoomState(); // TODO hook: build broadcast payload
    const bytes = broadcastMessage(this.playerConnections.values(), {
      type: 'game_snapshot',
      snapshot,
    });
    this.perfTracker.recordTick({
      tickMs: performance.now() - t0,
      snapshotBytes: bytes,
      broadcastClients: this.playerConnections.size,
    });
  }
}
