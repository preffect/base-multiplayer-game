import type { WebSocket } from 'ws';
import type { ServerMessage } from '@base-multiplayer-game/shared';

/**
 * A live client connection. Generic transport-level concept — carries the
 * player's identity + lobby presence fields. No game-specific state lives here.
 */
export interface Connection {
  /** Stable identity (from ?clientId= or a freshly minted nanoid). */
  playerId: string;
  /** Display name chosen in the lobby. */
  playerName: string;
  /** Indexed avatar chosen in the lobby. */
  avatarIndex: number;
  /** The underlying socket. */
  socket: WebSocket;
  /**
   * Takeover flag. When a second tab connects with the same clientId we mark
   * the old connection as `replaced` so its close handler does NOT tear down
   * the player's lobby/room presence.
   */
  replaced?: boolean;
}

/** Send a single message to one connection (no-op if the socket is closed). */
export function sendMessage(conn: Connection, message: ServerMessage): number {
  const data = JSON.stringify(message);
  // 1 === WebSocket.OPEN
  if (conn.socket.readyState === 1) {
    conn.socket.send(data);
    return data.length;
  }
  return 0;
}

/**
 * Broadcast a message to many connections. Serializes once and reuses the
 * string. Returns the byte length sent to a single client (for perf metrics).
 */
export function broadcastMessage(conns: Iterable<Connection>, message: ServerMessage): number {
  const data = JSON.stringify(message);
  for (const conn of conns) {
    if (conn.socket.readyState === 1) {
      conn.socket.send(data);
    }
  }
  return data.length;
}
