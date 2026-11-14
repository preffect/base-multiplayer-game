/**
 * Serves the built client from the game server, so a deployed game is one port: the page, /api and the WebSocket
 * at /ws, all on one origin, as the client expects (it opens `/ws` on its own host). In dev the Angular server does
 * this instead, and the variable is unset. The platform's prod image sets it (Dockerfile).
 * Template-owned: it names nothing game-specific.
 */
import fastifyStatic from '@fastify/static';
import type { FastifyInstance } from 'fastify';
import { DEBUG_MCP_PATH } from '../mcp/debug-mcp-http.js';
import { HTTP_NOT_FOUND } from '../mcp/http-status.js';

/** Where the built client is. Unset, the server serves no page. */
export const CLIENT_DIR_VARIABLE = 'GAME_CLIENT_DIR';
/** The page every client-side route loads. */
export const CLIENT_INDEX = 'index.html';
/**
 * The server's own paths on the game port: the game's API and WebSocket, and the debug MCP. An unknown one is a 404,
 * never the page. The prod MCP is on a port of its own (MCP_PORT), so it isn't here, and this file needs nothing a
 * game made before it lacks.
 */
export const SERVER_PATH_PREFIXES: readonly string[] = ['/api', '/ws', DEBUG_MCP_PATH];

/** Whether a request path is one of the server's own, or under one. */
export function isServerPath(path: string): boolean {
  return SERVER_PATH_PREFIXES.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
}

/**
 * Registers the client's files, and a fallback to its page for any other GET, so a client-side route loads on
 * a reload. Returns whether it did: it does nothing unless the environment names the client's folder.
 */
export async function serveClientFiles(
  server: FastifyInstance,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<boolean> {
  const root = environment[CLIENT_DIR_VARIABLE];
  if (!root) return false;
  await server.register(fastifyStatic, { root, index: CLIENT_INDEX });
  server.setNotFoundHandler(async (request, reply) => {
    const path = request.url.split('?')[0] ?? '';
    if (request.method !== 'GET' || isServerPath(path)) {
      return reply.code(HTTP_NOT_FOUND).send({ error: 'not found' });
    }
    return reply.sendFile(CLIENT_INDEX);
  });
  return true;
}
