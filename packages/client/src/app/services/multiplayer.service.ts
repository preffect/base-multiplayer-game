import { Injectable, computed, inject, signal } from '@angular/core';
import type {
  GameId,
  GameInput,
  GameSessionConfig,
  GameSnapshot,
  LobbyGameInfo,
  PlayerId,
  ServerMessage,
} from '@base-multiplayer-game/shared';
import { WebSocketService } from './websocket.service';

/**
 * Generic, GAME-AGNOSTIC multiplayer networking + state service.
 *
 * This is the primary client entry point for multiplayer. It owns the
 * connection lifecycle, drives the lobby -> create/join -> in-game flow, and
 * exposes everything the UI needs as Angular signals. It deliberately knows
 * NOTHING about any specific game's rules, board, or rendering.
 *
 * Game-specific code plugs in at two clearly marked seams:
 *   1. `sendInput(payload)` — outbound: wrap your game's input shape (`GameInput`).
 *   2. `snapshot` signal + `latestSnapshot()` — inbound: the opaque
 *      `GameSnapshot` your renderer consumes. See `game/game-setup.ts`.
 */
export type Phase = 'lobby' | 'in-game';

@Injectable({ providedIn: 'root' })
export class MultiplayerService {
  private readonly ws = inject(WebSocketService);

  // ===== Connection =====
  /** Live WebSocket connection flag (mirrors the transport). */
  readonly connected = this.ws.connected;

  // ===== Lobby / room state (generic) =====
  readonly phase = signal<Phase>('lobby');
  readonly games = signal<LobbyGameInfo[]>([]);
  readonly playerId = signal<PlayerId | null>(null);
  readonly gameId = signal<GameId | null>(null);
  readonly playerIds = signal<PlayerId[]>([]);
  readonly isHost = signal(false);
  readonly avatarAssignments = signal<Record<string, number>>({});
  readonly sessionConfig = signal<GameSessionConfig | null>(null);
  readonly lastError = signal<string | null>(null);

  /**
   * Most recent opaque game snapshot received from the server. The template's
   * default "echo" GameModule fills this in; a real game replaces the
   * `GameSnapshot` type and renders it. TODO(game): consume in your renderer.
   */
  readonly snapshot = signal<GameSnapshot | null>(null);

  readonly inGame = computed(() => this.phase() === 'in-game');

  constructor() {
    this.ws.messages$.subscribe((msg) => this.handle(msg));
  }

  // ===== Lifecycle =====
  connect(): void {
    this.ws.connect();
  }

  disconnect(): void {
    this.ws.disconnect();
  }

  // ===== Lobby actions (generic verbs) =====
  joinLobby(playerName: string, avatarIndex = 0): void {
    this.ws.send({ type: 'join_lobby', playerName, avatarIndex });
  }

  updatePlayerInfo(playerName: string, avatarIndex: number): void {
    this.ws.send({ type: 'update_player_info', playerName, avatarIndex });
  }

  createGame(gameName: string, config: GameSessionConfig): void {
    // TODO(game): extend `config` with game-specific session fields before send.
    this.ws.send({ type: 'create_game', gameName, config });
  }

  joinGame(id: string): void {
    this.ws.send({ type: 'join_game', gameId: id });
  }

  startGame(id: string): void {
    this.ws.send({ type: 'start_game', gameId: id });
  }

  deleteGame(id: string): void {
    this.ws.send({ type: 'delete_game', gameId: id });
  }

  // ===== Gameplay =====
  /**
   * Send one unit of game input. The payload is the opaque `GameInput` defined
   * by the concrete game. Local-only / client-trusted: the server forwards this
   * to the room's GameModule without semantic validation.
   * TODO(game): call this from your input loop with your typed input shape.
   */
  sendInput(payload: GameInput): void {
    this.ws.send({ type: 'player_input', payload });
  }

  /** Drain the freshest un-rendered snapshot frame (call once per render frame). */
  latestSnapshot(): GameSnapshot | null {
    const msg = this.ws.drainLatestSnapshot();
    if (msg && msg.type === 'game_snapshot') {
      this.snapshot.set(msg.snapshot);
      return msg.snapshot;
    }
    return null;
  }

  // ===== Inbound message handling =====
  private handle(msg: ServerMessage): void {
    switch (msg.type) {
      case 'lobby_update':
        this.games.set(msg.games);
        break;

      case 'game_started':
        this.playerId.set(msg.playerId);
        this.gameId.set(msg.gameId);
        this.playerIds.set(msg.playerIds);
        this.isHost.set(msg.isHost);
        this.sessionConfig.set(msg.config);
        this.phase.set('in-game');
        break;

      case 'game_state':
        // Sent to a (re)joining player: full room state to (re)build the view.
        this.playerId.set(msg.playerId);
        this.gameId.set(msg.gameId);
        this.playerIds.set(msg.playerIds);
        this.sessionConfig.set(msg.config);
        this.avatarAssignments.set(msg.avatarAssignments);
        this.snapshot.set(msg.snapshot);
        this.phase.set('in-game');
        break;

      case 'game_snapshot':
        // Hot path is normally handled by the coalescing drain in the render
        // loop; this branch covers any snapshot that arrives via messages$.
        this.snapshot.set(msg.snapshot);
        break;

      case 'player_joined':
        this.playerIds.update((ids) => (ids.includes(msg.playerId) ? ids : [...ids, msg.playerId]));
        this.avatarAssignments.update((a) => ({ ...a, [msg.playerId]: msg.avatarIndex }));
        // TODO(game): react to a player joining mid-game (spawn entity, etc.).
        break;

      case 'player_disconnected':
        this.playerIds.update((ids) => ids.filter((id) => id !== msg.playerId));
        // TODO(game): react to a player leaving (remove entity, pause, etc.).
        break;

      case 'error':
        this.lastError.set(msg.message);
        break;

      // TODO(game): handle game-specific server message variants here.
    }
  }
}
