// Shared constants used by both the server and the client.
// Game-agnostic infrastructure values live here.

/** Default server port: serves /api + /ws + /debug-mcp (single Fastify instance). */
export const DEFAULT_SERVER_PORT = 4400;
/** Default Angular dev-server port (proxies /api + /ws + /debug-mcp to the server). */
export const DEFAULT_CLIENT_PORT = 4402;

/**
 * Server simulation tick rate (Hz). The GameRoom broadcasts a `game_snapshot`
 * each tick. TODO(game): turn-based games can lower this or move to an
 * event-driven broadcast instead of a fixed tick.
 */
export const TICK_HZ = 60;
/** Derived fixed-step interval in milliseconds. */
export const TICK_INTERVAL_MS = 1000 / TICK_HZ;

/** Grace window before a disconnected player is fully removed from a room. */
export const DISCONNECT_GRACE_MS = 30_000;

/** localStorage key the client uses to persist its stable identity. */
export const CLIENT_ID_STORAGE_KEY = 'base-mp.clientId';

/** Bounds enforced on lobby player descriptors (kept in sync with server zod schemas). */
export const PLAYER_NAME_MAX_LEN = 20;
export const GAME_NAME_MAX_LEN = 40;
/** Inclusive avatar index range for the generic lobby. TODO(game): adjust if needed. */
export const AVATAR_INDEX_MIN = 0;
export const AVATAR_INDEX_MAX = 5;
/** Default per-room player-count bounds. TODO(game): override via GameSessionConfig. */
export const MIN_PLAYERS_PER_GAME = 1;
export const MAX_PLAYERS_PER_GAME = 8;
