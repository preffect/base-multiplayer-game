import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { LATEST_PROTOCOL_VERSION } from '@modelcontextprotocol/sdk/types.js';
import { DEBUG_MCP_ENABLED_VALUE, DEBUG_MCP_SWITCH } from '../mcp/debug-mcp-http.js';

/** Template-owned test doubles for the debug MCP gate. Nothing here is game-specific. */

export const TEST_CLIENT_INFO = { name: 'test', version: '1.0.0' };
export const PROBE_TOOL_NAME = 'debug_probe';
export const PROBE_TOOL_ANSWER = 'ok';

/** A server's port as clients write it in Host; the guard ignores the port, so any value works. */
export const LOOPBACK_HOST_WITH_PORT = 'localhost:4400';
export const LOOPBACK_ORIGIN = 'http://localhost:4402';
/** Peers off this machine's loopback: another machine on the LAN, and Docker's bridge gateway. */
export const LAN_PEER_ADDRESS = '192.168.1.20';
export const BRIDGE_GATEWAY_ADDRESS = '172.17.0.1';

/** A debug MCP server with one probe tool, standing in for a game's tools. */
export function createProbeDebugServer(): McpServer {
  const server = new McpServer({ name: 'debug-probe', version: TEST_CLIENT_INFO.version });
  server.registerTool(PROBE_TOOL_NAME, { description: 'Answers ok' }, () => ({
    content: [{ type: 'text', text: PROBE_TOOL_ANSWER }],
  }));
  return server;
}

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
  params: { protocolVersion: LATEST_PROTOCOL_VERSION, capabilities: {}, clientInfo: TEST_CLIENT_INFO },
};

export const MCP_POST_HEADERS = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
