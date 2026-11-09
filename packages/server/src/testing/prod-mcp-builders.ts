import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { PROD_MCP_PORT_ENV, PROD_MCP_TOKEN_ENV } from '../mcp/prod-mcp-http.js';
import { TEST_CLIENT_INFO } from './debug-mcp-builders.js';

/** Template-owned test doubles for the prod MCP. Nothing here is game-specific. */

export const PROD_MCP_TEST_TOKEN = 'prod-mcp-test-token';
export const SETTING_TOOL_NAME = 'prod_probe_set';
export const FAILING_TOOL_NAME = 'prod_probe_fail';

/** The prod MCP's settings: a port (0 for any free one) and the test token. */
export function prodMcpEnvironment(port: string): NodeJS.ProcessEnv {
  return { [PROD_MCP_PORT_ENV]: port, [PROD_MCP_TOKEN_ENV]: PROD_MCP_TEST_TOKEN };
}

/** A server with a tool that takes arguments, some of them secret, and one that fails. */
export function createProbeProdServer(): McpServer {
  const server = new McpServer({ name: 'prod-probe', version: TEST_CLIENT_INFO.version });
  server.registerTool(
    SETTING_TOOL_NAME,
    {
      description: 'Takes a value',
      inputSchema: { value: z.string(), api_key: z.string().optional(), note: z.string().optional() },
    },
    () => ({ content: [{ type: 'text', text: 'set' }] }),
  );
  server.registerTool(FAILING_TOOL_NAME, { description: 'Always fails' }, () => {
    throw new Error('probe failure');
  });
  return server;
}
