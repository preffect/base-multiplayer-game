import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import type { GameRoom } from '../lobby/game-room.js';
import type { DebugContext } from './debug-context.js';
import { gameNotFoundResult } from './tool-result.js';

/** Runs `handler` with the active room for `gameId`, or answers with the not-found error every room tool shares. */
export function withActiveRoom(
  ctx: DebugContext,
  gameId: string,
  handler: (room: GameRoom) => CallToolResult,
): CallToolResult {
  const room = ctx.lobbyManager.getActiveRoom(gameId);
  return room ? handler(room) : gameNotFoundResult(gameId);
}
