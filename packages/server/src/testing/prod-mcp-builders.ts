import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { PRODUCTION_MCP_PORT_ENV, PRODUCTION_MCP_TOKEN_ENV } from '../mcp/prod-mcp-http.js';
import { TEST_CLIENT_INFO } from './debug-mcp-builders.js';

/** Template-owned test doubles for the prod MCP. Nothing here is game-specific. */

/** As long as the prod MCP asks for, and no longer. */
export const PRODUCTION_MCP_TEST_TOKEN = 'prod-mcp-test-token-0123456789abc';
export const SETTING_TOOL_NAME = 'prod_probe_set';
export const SETTING_TOOL_ANSWER = 'set';
export const FAILING_TOOL_NAME = 'prod_probe_fail';
/** An argument name the call log masks, as a game's secret-looking argument would be. */
export const SECRET_ARGUMENT_NAME = 'api_key';

/** The prod MCP's settings: a port (0 for any free one) and the test token. */
export function productionMcpEnvironment(port: string): NodeJS.ProcessEnv {
  return { [PRODUCTION_MCP_PORT_ENV]: port, [PRODUCTION_MCP_TOKEN_ENV]: PRODUCTION_MCP_TEST_TOKEN };
}

/** A server with a tool that takes arguments, some of them secret, and one that fails. */
export function createProbeProductionServer(): McpServer {
  const server = new McpServer({ name: 'prod-probe', version: TEST_CLIENT_INFO.version });
  server.registerTool(
    SETTING_TOOL_NAME,
    {
      description: 'Takes a value',
      inputSchema: { value: z.string(), [SECRET_ARGUMENT_NAME]: z.string().optional(), note: z.string().optional() },
    },
    () => ({ content: [{ type: 'text', text: SETTING_TOOL_ANSWER }] }),
  );
  server.registerTool(FAILING_TOOL_NAME, { description: 'Always fails' }, () => {
    throw new Error('probe failure');
  });
  return server;
}
