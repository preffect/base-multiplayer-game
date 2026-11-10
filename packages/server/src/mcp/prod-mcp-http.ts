import { createHash, timingSafeEqual } from 'node:crypto';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import type { JSONRPCMessage } from '@modelcontextprotocol/sdk/types.js';
import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { safeCallLogLine, type CallLogLine, type CallOutcome } from './call-log.js';
import { JSON_RPC_SERVER_ERROR, answerStatelessMcpRequest, jsonRpcErrorBody } from './debug-mcp-http.js';
import { HTTP_METHOD_NOT_ALLOWED, HTTP_UNAUTHORIZED } from './http-status.js';

/**
 * The prod MCP: the game's own tools, writes included, for its dev workspace to debug prod (preffect-home #73).
 * It listens on a port of its own, MCP_PORT, which the platform opens to that workspace alone and never routes,
 * and answers only a caller with the app's token, MCP_BEARER_TOKEN. Each call is one line of the call log
 * (call-log.ts). It's off unless MCP_PORT is set, and won't start without the token.
 * Template-owned: it takes a server factory and names nothing game-specific.
 */

export const PRODUCTION_MCP_PATH = '/mcp';
export const PRODUCTION_MCP_PORT_ENV = 'MCP_PORT';
export const PRODUCTION_MCP_TOKEN_ENV = 'MCP_BEARER_TOKEN';
/** Every address: the platform's network policy, not the bind address, decides who reaches the port. */
export const PRODUCTION_MCP_LISTEN_HOST = '0.0.0.0';
export const BEARER_PREFIX = 'Bearer ';
const HIGHEST_PORT = 65_535;
/** A token's own hash prefix is only logged for a refused caller, but a short token would still be easy to guess. */
export const SHORTEST_TOKEN = 32;
const BYTES_PER_KIBIBYTE = 1024;
/** MCP calls are small; a bigger body is refused before it's read. */
const PRODUCTION_MCP_BODY_LIMIT_KIBIBYTES = 64;
export const PRODUCTION_MCP_BODY_LIMIT = PRODUCTION_MCP_BODY_LIMIT_KIBIBYTES * BYTES_PER_KIBIBYTE;
const TOOLS_CALL_METHOD = 'tools/call';
/** Only problems: the call log is the record of calls. */
const PRODUCTION_MCP_LOG_LEVEL = 'warn';
/** The prod MCP's name in its log lines. */
const PRODUCTION_MCP_LABEL = 'prod MCP';

export type ProductionMcpServerFactory = () => McpServer;
export type CallLogWriter = (line: CallLogLine) => void;

export interface ProductionMcpSettings {
  port: number;
  token: string;
}

/** One JSON-RPC request or notification in a POST body, as the log needs it. */
export interface RequestedCall {
  id: string | number | undefined;
  method: string;
  tool: string | undefined;
  arguments: unknown;
}

export function writeCallLogLine(line: CallLogLine): void {
  process.stdout.write(`${JSON.stringify(line)}\n`);
}

/** The port and token, undefined when MCP_PORT is unset. A port without a strong token, or a bad port, stops the start. */
export function productionMcpSettings(environment: NodeJS.ProcessEnv): ProductionMcpSettings | undefined {
  const portText = environment[PRODUCTION_MCP_PORT_ENV];
  if (portText === undefined || portText === '') return undefined;
  const port = Number(portText);
  if (!Number.isInteger(port) || port < 0 || port > HIGHEST_PORT) {
    throw new Error(`${PRODUCTION_MCP_PORT_ENV} isn't a port: ${portText}`);
  }
  const token = environment[PRODUCTION_MCP_TOKEN_ENV] ?? '';
  if (token === '')
    throw new Error(
      `${PRODUCTION_MCP_PORT_ENV} is set, so the prod MCP needs its token on ${PRODUCTION_MCP_TOKEN_ENV}`,
    );
  if (token.length < SHORTEST_TOKEN || token.trim() !== token) {
    throw new Error(
      `${PRODUCTION_MCP_TOKEN_ENV} has to be at least ${SHORTEST_TOKEN} characters, with no space around it`,
    );
  }
  return { port, token };
}

/** The token an Authorization header presents, or '' for none. */
export function presentedToken(authorization: string | undefined): string {
  return authorization?.startsWith(BEARER_PREFIX) === true ? authorization.slice(BEARER_PREFIX.length) : '';
}

function digest(text: string): Buffer {
  return createHash('sha256').update(text).digest();
}

/** Compared as digests, so the time taken says nothing about the token, its length included. */
export function tokenMatches(presented: string, token: string): boolean {
  return presented !== '' && timingSafeEqual(digest(presented), digest(token));
}

/** A JSON-RPC message as the log reads it: every field may be missing or of the wrong type. */
interface UncheckedMessage {
  id?: unknown;
  method?: unknown;
  params?: { name?: unknown; arguments?: unknown };
}

function requestId(id: unknown): string | number | undefined {
  return typeof id === 'string' || typeof id === 'number' ? id : undefined;
}

/** One message as a call, or undefined when it isn't a request or notification. */
function requestedCall(message: unknown): RequestedCall | undefined {
  if (message === null || typeof message !== 'object') return undefined;
  const { id, method, params } = message as UncheckedMessage;
  if (typeof method !== 'string') return undefined;
  if (method !== TOOLS_CALL_METHOD) return { id: requestId(id), method, tool: undefined, arguments: undefined };
  const tool = typeof params?.name === 'string' ? params.name : undefined;
  return { id: requestId(id), method, tool, arguments: params?.arguments };
}

/** The calls in a POST body: one message or a batch. Anything that isn't a request or notification is skipped. */
export function requestedCalls(body: unknown): RequestedCall[] {
  const messages: unknown[] = Array.isArray(body) ? body : [body];
  return messages.map(requestedCall).filter((call): call is RequestedCall => call !== undefined);
}

/** A response's outcome: a JSON-RPC error, or a tool result that says it failed, is an error. */
export function responseOutcome(message: JSONRPCMessage): CallOutcome {
  if ('error' in message) return 'error';
  if ('result' in message && (message.result as { isError?: unknown }).isError === true) return 'error';
  return 'ok';
}

function responseId(message: JSONRPCMessage): string | number | undefined {
  return ('result' in message || 'error' in message) && 'id' in message ? message.id : undefined;
}

type LogCall = (call: RequestedCall, outcome: CallOutcome) => void;

function callLogger(request: FastifyRequest, settings: ProductionMcpSettings, write: CallLogWriter): LogCall {
  const presented = presentedToken(request.headers.authorization);
  return (call, outcome) =>
    write(
      safeCallLogLine(
        {
          caller: request.socket.remoteAddress,
          method: call.method,
          tool: call.tool,
          arguments: call.arguments,
          outcome,
          presentedToken: presented,
        },
        settings.token,
      ),
    );
}

/**
 * Answers one request statelessly, as the debug MCP does, and logs each call with its outcome: a notification
 * when it's taken, a request when its response goes out, and any left unanswered as an error.
 */
async function answerMcpRequest(
  createServer: ProductionMcpServerFactory,
  request: FastifyRequest,
  reply: FastifyReply,
  logCall: LogCall,
): Promise<void> {
  const calls = requestedCalls(request.body);
  const pending = new Map(calls.filter((call) => call.id !== undefined).map((call) => [call.id, call]));
  calls.filter((call) => call.id === undefined).forEach((call) => logCall(call, 'ok'));
  const settle = (): void => {
    pending.forEach((call) => logCall(call, 'error'));
    pending.clear();
  };
  const logResponses = (transport: StreamableHTTPServerTransport): void => {
    const send = transport.send.bind(transport);
    transport.send = async (message, options) => {
      const call = pending.get(responseId(message));
      if (call !== undefined) {
        pending.delete(call.id);
        logCall(call, responseOutcome(message));
      }
      return send(message, options);
    };
  };
  await answerStatelessMcpRequest(createServer, request, reply, {
    label: PRODUCTION_MCP_LABEL,
    onTransport: logResponses,
    onClose: settle,
    onFailure: settle,
  });
}

function routes(
  app: FastifyInstance,
  createServer: ProductionMcpServerFactory,
  settings: ProductionMcpSettings,
  write: CallLogWriter,
): void {
  // Before the body is read: a caller without the token costs one short line and a 401, whatever it sent.
  app.addHook('onRequest', async (request, reply) => {
    if (tokenMatches(presentedToken(request.headers.authorization), settings.token)) return undefined;
    callLogger(
      request,
      settings,
      write,
    )({ id: undefined, method: request.method, tool: undefined, arguments: undefined }, 'unauthorized');
    return reply
      .code(HTTP_UNAUTHORIZED)
      .header('www-authenticate', 'Bearer')
      .send(jsonRpcErrorBody(JSON_RPC_SERVER_ERROR, 'The prod MCP needs the app token'));
  });
  app.post(PRODUCTION_MCP_PATH, (request, reply) =>
    answerMcpRequest(createServer, request, reply, callLogger(request, settings, write)),
  );
  // Stateless mode has no stream to open (GET) or session to end (DELETE).
  app.route({
    method: ['GET', 'DELETE'],
    url: PRODUCTION_MCP_PATH,
    handler: async (request, reply) => {
      callLogger(
        request,
        settings,
        write,
      )({ id: undefined, method: request.method, tool: undefined, arguments: undefined }, 'refused');
      return reply
        .code(HTTP_METHOD_NOT_ALLOWED)
        .header('allow', 'POST')
        .send(jsonRpcErrorBody(JSON_RPC_SERVER_ERROR, 'Method not allowed.'));
    },
  });
}

/**
 * Starts the prod MCP on its own port when MCP_PORT is set, and answers the listener, or undefined when it's off.
 * One server is built first, so a broken tool registration fails the start rather than every call.
 */
export async function startProductionMcp(
  createServer: ProductionMcpServerFactory,
  environment: NodeJS.ProcessEnv = process.env,
  write: CallLogWriter = writeCallLogLine,
): Promise<FastifyInstance | undefined> {
  const settings = productionMcpSettings(environment);
  if (settings === undefined) return undefined;
  await createServer().close();
  const app = Fastify({ logger: { level: PRODUCTION_MCP_LOG_LEVEL }, bodyLimit: PRODUCTION_MCP_BODY_LIMIT });
  routes(app, createServer, settings, write);
  await app.listen({ port: settings.port, host: PRODUCTION_MCP_LISTEN_HOST });
  return app;
}
