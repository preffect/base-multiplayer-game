import type { Connection } from './connection.js';
import { clientMessageSchema, type ValidatedClientMessage } from './message-schemas.js';
import { sendMessage } from './connection.js';

type M<T extends string> = Extract<ValidatedClientMessage, { type: T }>;

/**
 * The set of handlers the lobby provides. This is the generic seam between the
 * transport (router) and the application (lobby). Game-specific verbs are added
 * by extending the schema + this interface + the switch below (see TODO).
 */
export interface MessageHandlers {
  onJoinLobby: (c: Connection, m: M<'join_lobby'>) => void;
  onUpdatePlayerInfo: (c: Connection, m: M<'update_player_info'>) => void;
  onCreateGame: (c: Connection, m: M<'create_game'>) => void;
  onJoinGame: (c: Connection, m: M<'join_game'>) => void;
  onStartGame: (c: Connection, m: M<'start_game'>) => void;
  onDeleteGame: (c: Connection, m: M<'delete_game'>) => void;
  onPlayerInput: (c: Connection, m: M<'player_input'>) => void;
  onClientPerformance: (c: Connection, m: M<'client_performance'>) => void;
}

/**
 * Build a per-message dispatcher. Parses JSON, validates against the schema,
 * and routes to the matching handler. Invalid messages get an `error` reply.
 */
export function createMessageRouter(h: MessageHandlers) {
  return (conn: Connection, raw: string): void => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      sendMessage(conn, { type: 'error', message: 'Invalid JSON' });
      return;
    }
    const r = clientMessageSchema.safeParse(parsed);
    if (!r.success) {
      sendMessage(conn, {
        type: 'error',
        message: `Invalid message: ${r.error.issues[0]?.message ?? 'unknown'}`,
      });
      return;
    }
    const msg = r.data;
    switch (msg.type) {
      case 'join_lobby':
        h.onJoinLobby(conn, msg);
        break;
      case 'update_player_info':
        h.onUpdatePlayerInfo(conn, msg);
        break;
      case 'create_game':
        h.onCreateGame(conn, msg);
        break;
      case 'join_game':
        h.onJoinGame(conn, msg);
        break;
      case 'start_game':
        h.onStartGame(conn, msg);
        break;
      case 'delete_game':
        h.onDeleteGame(conn, msg);
        break;
      case 'player_input':
        h.onPlayerInput(conn, msg);
        break;
      case 'client_performance':
        h.onClientPerformance(conn, msg);
        break;
      // TODO(game): add game-specific message cases here.
    }
  };
}
