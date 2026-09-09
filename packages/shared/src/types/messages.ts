// Generic client <-> server message envelope (the wire contract).
//
// The transport, lobby, room lifecycle and MCP plumbing are all game-agnostic.
// The ONLY game-defined seams here are `GameInput`, `GameSnapshot` and
// `GameSessionConfig` — every other field is generic infrastructure.

import type { PlayerId, GameId } from './common.js';

// ===== Opaque game-defined types. TODO(init): replace `unknown`. =====
/** TODO(game): replace with your game's validated per-tick/turn input shape. */
export type GameInput = unknown;
/** TODO(game): replace with your game's broadcast snapshot shape. */
export type GameSnapshot = unknown;
/** TODO(game): replace with your game's session config (seed, mode, etc.). */
export interface GameSessionConfig {
  maxPlayers: number;
  // TODO(game): add game-specific session config fields here.
}

// ===== Generic lobby / player descriptors =====
export interface LobbyPlayerInfo {
  playerId: PlayerId;
  playerName: string;
  avatarIndex: number;
}

export interface LobbyGameInfo {
  gameId: GameId;
  gameName: string;
  players: LobbyPlayerInfo[];
  maxPlayers: number;
  started: boolean;
  creatorId: PlayerId;
}

export interface ClientPerformanceReport {
  fps: number;
  frameTimeAvgMs: number;
  frameTimeP95Ms: number;
  frameTimePeakMs: number;
  heapMb: number | null;
}

// ===== Generic room / lobby view models =====
// Game-agnostic snapshots of server-side state, suitable for MCP/debug views
// and client lobby rendering. The `started` flag is the room lifecycle marker;
// `LobbyGameInfo` (above) is the trimmed form sent over the wire in `lobby_update`.
export interface RoomState {
  gameId: GameId;
  gameName: string;
  creatorId: PlayerId;
  maxPlayers: number;
  started: boolean;
  /** Players currently connected to the room. */
  connectedPlayerIds: PlayerId[];
  /** Players in a disconnect grace window (may reattach before removal). */
  disconnectedPlayerIds: PlayerId[];
  /** Every player ever in the room, in join order. */
  allPlayerIds: PlayerId[];
}

export interface LobbyState {
  /** Active (started) rooms. */
  rooms: RoomState[];
  /** Pending (not-yet-started) games awaiting players. */
  pending: LobbyGameInfo[];
}

// ===== Client -> Server =====
export type ClientMessage =
  | { type: 'join_lobby'; playerName: string; avatarIndex: number }
  | { type: 'update_player_info'; playerName: string; avatarIndex: number }
  | { type: 'create_game'; gameName: string; config: GameSessionConfig }
  | { type: 'join_game'; gameId: string }
  | { type: 'start_game'; gameId: string }
  | { type: 'delete_game'; gameId: string }
  | { type: 'player_input'; payload: GameInput } // TODO(game): typed input
  | { type: 'client_performance'; report: ClientPerformanceReport };
// TODO(game): add game-specific client message variants here.

// ===== Server -> Client =====
export type ServerMessage =
  | { type: 'lobby_update'; games: LobbyGameInfo[] }
  | {
      type: 'game_started';
      gameId: GameId;
      playerId: PlayerId;
      playerIds: PlayerId[];
      isHost: boolean;
      config: GameSessionConfig;
    }
  | {
      type: 'game_state';
      gameId: GameId;
      playerId: PlayerId;
      snapshot: GameSnapshot;
      config: GameSessionConfig;
      playerIds: PlayerId[];
      avatarAssignments: Record<string, number>;
    }
  | { type: 'game_snapshot'; snapshot: GameSnapshot }
  | { type: 'player_joined'; playerId: PlayerId; avatarIndex: number }
  | { type: 'player_disconnected'; playerId: PlayerId }
  | { type: 'error'; message: string };
// TODO(game): add game-specific server message variants here.

// Convenience unions for exhaustive handling.
export type ClientMessageType = ClientMessage['type'];
export type ServerMessageType = ServerMessage['type'];
