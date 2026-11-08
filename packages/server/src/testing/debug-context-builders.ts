import { defaultGameModuleFactory } from '../game/game-module.js';
import { LobbyManager } from '../lobby/lobby-manager.js';
import type { DebugContext } from '../mcp/debug-context.js';

/** A debug context over a fresh lobby with no games and no connections. */
export function buildEmptyDebugContext(): DebugContext {
  return { lobbyManager: new LobbyManager(defaultGameModuleFactory), connections: new Map() };
}
