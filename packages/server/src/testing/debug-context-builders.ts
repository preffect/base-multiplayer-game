import { defaultGameModuleFactory } from '../game/game-module.js';
import { LobbyManager } from '../lobby/lobby-manager.js';
import type { DebugContext } from '../mcp/debug-context.js';
import { DEBUG_MCP_ENABLED_VALUE, DEBUG_MCP_SWITCH } from '../mcp/mcp-server.js';

/** A debug context over a fresh lobby with no games and no connections. */
export function buildEmptyDebugContext(): DebugContext {
  return { lobbyManager: new LobbyManager(defaultGameModuleFactory), connections: new Map() };
}

/** An environment with the debug MCP switch on. */
export const DEBUG_MCP_SWITCHED_ON: NodeJS.ProcessEnv = { [DEBUG_MCP_SWITCH]: DEBUG_MCP_ENABLED_VALUE };

/** Environments that must leave the debug MCP unmounted: unset, off, and near-misses of the on value. */
export const DEBUG_MCP_SWITCHED_OFF: NodeJS.ProcessEnv[] = [
  {},
  { [DEBUG_MCP_SWITCH]: '0' },
  { [DEBUG_MCP_SWITCH]: 'true' },
];

export const MCP_INITIALIZE_REQUEST = {
  jsonrpc: '2.0',
  id: 1,
  method: 'initialize',
  params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } },
};

export const MCP_POST_HEADERS = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
