import type { LobbyManager } from '../lobby/lobby-manager.js';
import type { Connection } from '../ws/connection.js';

/**
 * Shared context passed to every MCP debug tool handler.
 *
 * Gives the debug MCP endpoint read-only access to the live lobby manager
 * (rooms + pending games), the active WebSocket connections, and per-room
 * performance telemetry. All generic plumbing reads through this — no game
 * logic lives here.
 */
export interface DebugContext {
  /** The lobby manager (source of truth for pending games + active rooms). */
  readonly lobbyManager: LobbyManager;
  /** All active WebSocket connections, keyed by playerId. */
  readonly connections: ReadonlyMap<string, Connection>;

  /**
   * EXTENSION POINT (init step): return a JSON-serializable snapshot of a
   * room's game-specific state, given its gameId. The generic
   * `debug_get_game_state` tool calls this; when it is `undefined` the tool
   * falls back to the room's opaque snapshot from `room.getSnapshot()` plus a
   * "no game logic wired yet" note.
   *
   * Wire this to your real game state in the init step (see init-game-prompt.md).
   */
  readonly getRoomGameState?: (gameId: string) => unknown;
}
