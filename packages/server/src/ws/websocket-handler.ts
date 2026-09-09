import type { FastifyInstance } from 'fastify';
import { nanoid } from 'nanoid';
import type { Connection } from './connection.js';
import { createMessageRouter, type MessageHandlers } from './message-router.js';

export interface WebSocketContext {
  /** The shared registry of live connections, keyed by playerId. */
  connections: Map<string, Connection>;
  /** Lobby-provided message handlers. */
  handlers: MessageHandlers;
  /** Called after a connection is registered (cancel removal / reattach). */
  onConnect?: (conn: Connection) => void;
  /** Called when a connection closes for good (not on takeover). */
  onDisconnect?: (conn: Connection) => void;
}

/**
 * Mount the `/ws` route. Identity comes from `?clientId=` when present (enabling
 * reconnect + multi-tab takeover); otherwise a fresh nanoid is minted. When a
 * second connection arrives with an existing clientId, the previous socket is
 * marked `replaced` and closed so its disconnect handler is a no-op.
 */
export function registerWebSocketHandler(server: FastifyInstance, ctx: WebSocketContext): void {
  const route = createMessageRouter(ctx.handlers);

  server.get('/ws', { websocket: true }, (socket, request) => {
    const url = new URL(request.url, 'http://localhost');
    const requestedId = url.searchParams.get('clientId');
    const playerId = requestedId && requestedId.length > 0 ? requestedId : nanoid();

    // Takeover: a previous connection with the same id is replaced, not removed.
    const existing = ctx.connections.get(playerId);
    if (existing) {
      existing.replaced = true;
      try {
        existing.socket.close();
      } catch {
        // socket may already be closed
      }
    }

    const conn: Connection = {
      playerId,
      playerName: existing?.playerName ?? '',
      avatarIndex: existing?.avatarIndex ?? 0,
      socket,
    };
    ctx.connections.set(playerId, conn);
    ctx.onConnect?.(conn);

    socket.on('message', (data: Buffer) => {
      route(conn, data.toString());
    });

    socket.on('close', () => {
      // Only tear down if this is still the active connection for the id and it
      // was not superseded by a takeover.
      if (conn.replaced) return;
      if (ctx.connections.get(playerId) === conn) {
        ctx.connections.delete(playerId);
      }
      ctx.onDisconnect?.(conn);
    });

    socket.on('error', () => {
      // Errors are followed by a `close`; nothing extra to do here.
    });
  });
}
