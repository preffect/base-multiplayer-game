import type { AddressInfo } from 'node:net';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { MCP_INITIALIZE_REQUEST, MCP_POST_HEADERS, TEST_CLIENT_INFO } from '../testing/debug-mcp-builders.js';
import {
  FAILING_TOOL_NAME,
  PROD_MCP_TEST_TOKEN,
  SETTING_TOOL_NAME,
  createProbeProdServer,
  prodMcpEnvironment,
} from '../testing/prod-mcp-builders.js';
import { MASKED, tokenHash, type CallLogLine } from './call-log.js';
import {
  HTTP_INTERNAL_SERVER_ERROR,
  HTTP_METHOD_NOT_ALLOWED,
  HTTP_NOT_FOUND,
  HTTP_OK,
  HTTP_UNAUTHORIZED,
} from './http-status.js';
import {
  BEARER_PREFIX,
  PROD_MCP_PATH,
  PROD_MCP_PORT_ENV,
  PROD_MCP_BODY_LIMIT,
  PROD_MCP_TOKEN_ENV,
  SHORTEST_TOKEN,
  type ProdMcpServerFactory,
  presentedToken,
  prodMcpSettings,
  requestedCalls,
  responseOutcome,
  startProdMcp,
  tokenMatches,
} from './prod-mcp-http.js';

const HTTP_ACCEPTED = 202;
const HTTP_PAYLOAD_TOO_LARGE = 413;
const WRONG_TOKEN = `${PROD_MCP_TEST_TOKEN}-wrong`;
const INITIALIZED_NOTIFICATION = { jsonrpc: '2.0', method: 'notifications/initialized' };

describe('prodMcpSettings', () => {
  it.each([{}, { [PROD_MCP_PORT_ENV]: '' }])('leaves the prod MCP off without a port: %j', (environment) => {
    expect(prodMcpSettings(environment)).toBeUndefined();
  });

  it('wants the token once a port is set', () => {
    expect(() => prodMcpSettings({ [PROD_MCP_PORT_ENV]: '9090' })).toThrow(PROD_MCP_TOKEN_ENV);
    expect(() => prodMcpSettings({ [PROD_MCP_PORT_ENV]: '9090', [PROD_MCP_TOKEN_ENV]: '' })).toThrow(
      PROD_MCP_TOKEN_ENV,
    );
  });

  it.each([
    ['short', 'a'.repeat(SHORTEST_TOKEN - 1)],
    ['spaced', ` ${'a'.repeat(SHORTEST_TOKEN)}`],
    ['trailing newline', `${'a'.repeat(SHORTEST_TOKEN)}\n`],
  ])('refuses a %s token', (_name, token) => {
    expect(() => prodMcpSettings({ [PROD_MCP_PORT_ENV]: '9090', [PROD_MCP_TOKEN_ENV]: token })).toThrow(
      `at least ${SHORTEST_TOKEN} characters`,
    );
  });

  it.each(['x', '-1', '65536', '1.5'])('refuses the port %s', (port) => {
    expect(() => prodMcpSettings(prodMcpEnvironment(port))).toThrow("isn't a port");
  });

  it('answers the port and token', () => {
    expect(prodMcpSettings(prodMcpEnvironment('9090'))).toEqual({ port: 9090, token: PROD_MCP_TEST_TOKEN });
  });
});

describe('the token check', () => {
  it.each([
    [undefined, ''],
    ['Basic abc', ''],
    [`${BEARER_PREFIX}abc`, 'abc'],
  ])('reads %s as %j', (header, token) => {
    expect(presentedToken(header)).toBe(token);
  });

  it('matches the token only', () => {
    expect(tokenMatches(PROD_MCP_TEST_TOKEN, PROD_MCP_TEST_TOKEN)).toBe(true);
    expect(tokenMatches(WRONG_TOKEN, PROD_MCP_TEST_TOKEN)).toBe(false);
    expect(tokenMatches('', PROD_MCP_TEST_TOKEN)).toBe(false);
  });
});

describe('requestedCalls', () => {
  it('reads a tool call, its name and arguments', () => {
    const call = { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'x', arguments: { a: 1 } } };
    expect(requestedCalls(call)).toEqual([{ id: 3, method: 'tools/call', tool: 'x', arguments: { a: 1 } }]);
  });

  it('reads a batch, and a notification has no id', () => {
    expect(requestedCalls([MCP_INITIALIZE_REQUEST, INITIALIZED_NOTIFICATION])).toEqual([
      { id: 1, method: 'initialize', tool: undefined, arguments: undefined },
      { id: undefined, method: 'notifications/initialized', tool: undefined, arguments: undefined },
    ]);
  });

  it('skips what is not a request, and an id that is not one', () => {
    expect(requestedCalls([null, 'x', { id: 1 }, { id: {}, method: 'ping' }])).toEqual([
      { id: undefined, method: 'ping', tool: undefined, arguments: undefined },
    ]);
  });

  it('takes no tool name that is not a string', () => {
    expect(requestedCalls({ id: 'a', method: 'tools/call', params: { name: 7 } })[0]?.tool).toBeUndefined();
  });
});

describe('responseOutcome', () => {
  it('is error for a JSON-RPC error or a failed tool, else ok', () => {
    expect(responseOutcome({ jsonrpc: '2.0', id: 1, error: { code: -1, message: 'x' } })).toBe('error');
    expect(responseOutcome({ jsonrpc: '2.0', id: 1, result: { content: [], isError: true } })).toBe('error');
    expect(responseOutcome({ jsonrpc: '2.0', id: 1, result: {} })).toBe('ok');
  });
});

describe('the prod MCP over a real socket', () => {
  let app: FastifyInstance | undefined;
  let client: Client | undefined;
  let lines: CallLogLine[] = [];

  afterEach(async () => {
    await client?.close();
    await app?.close();
    client = undefined;
    app = undefined;
    lines = [];
  });

  async function listen(createServer: ProdMcpServerFactory = createProbeProdServer): Promise<string> {
    app = await startProdMcp(createServer, prodMcpEnvironment('0'), (line) => lines.push(line));
    if (app === undefined) throw new Error('the prod MCP did not start');
    return `http://127.0.0.1:${(app.server.address() as AddressInfo).port}${PROD_MCP_PATH}`;
  }

  async function post(url: string, body: unknown, token?: string): Promise<Response> {
    const authorization: Record<string, string> =
      token === undefined ? {} : { authorization: `${BEARER_PREFIX}${token}` };
    return fetch(url, {
      method: 'POST',
      headers: { ...MCP_POST_HEADERS, ...authorization },
      body: JSON.stringify(body),
    });
  }

  it('is off without a port, and listens nowhere', async () => {
    expect(await startProdMcp(createProbeProdServer, {}, (line) => lines.push(line))).toBeUndefined();
  });

  it('refuses a call without the token before reading it: one line, no body, no hash', async () => {
    const answer = await post(await listen(), [MCP_INITIALIZE_REQUEST, MCP_INITIALIZE_REQUEST, INITIALIZED_NOTIFICATION]);
    expect(answer.status).toBe(HTTP_UNAUTHORIZED);
    expect(answer.headers.get('www-authenticate')).toBe('Bearer');
    expect(lines).toEqual([expect.objectContaining({ method: 'POST', tool: null, arguments: {}, outcome: 'unauthorized', token_sha256: null })]);
  });

  it('refuses a big body without the token, unread, and with it, as too big', async () => {
    const url = await listen();
    const big = { ...MCP_INITIALIZE_REQUEST, params: { padding: 'x'.repeat(PROD_MCP_BODY_LIMIT) } };
    expect((await post(url, big)).status).toBe(HTTP_UNAUTHORIZED);
    expect((await post(url, big, PROD_MCP_TEST_TOKEN)).status).toBe(HTTP_PAYLOAD_TOO_LARGE);
    expect(lines).toEqual([expect.objectContaining({ method: 'POST', outcome: 'unauthorized' })]);
  });

  it('refuses a GET without the token, and logs it once', async () => {
    expect((await fetch(await listen())).status).toBe(HTTP_UNAUTHORIZED);
    expect(lines).toEqual([expect.objectContaining({ method: 'GET', outcome: 'unauthorized' })]);
  });

  it("refuses a wrong token, and logs the wrong token's hash", async () => {
    expect((await post(await listen(), MCP_INITIALIZE_REQUEST, WRONG_TOKEN)).status).toBe(HTTP_UNAUTHORIZED);
    expect(lines).toMatchObject([{ outcome: 'unauthorized', token_sha256: tokenHash(WRONG_TOKEN) }]);
  });

  it('answers the token through the SDK client, and logs every call, masked', async () => {
    const url = await listen();
    const headers = { authorization: `${BEARER_PREFIX}${PROD_MCP_TEST_TOKEN}` };
    client = new Client(TEST_CLIENT_INFO);
    await client.connect(new StreamableHTTPClientTransport(new URL(url), { requestInit: { headers } }));
    expect((await client.listTools()).tools.map((tool) => tool.name)).toEqual([SETTING_TOOL_NAME, FAILING_TOOL_NAME]);
    const args = { value: 'v', api_key: 'k', note: PROD_MCP_TEST_TOKEN };
    expect((await client.callTool({ name: SETTING_TOOL_NAME, arguments: args })).isError).toBeFalsy();
    expect((await client.callTool({ name: FAILING_TOOL_NAME, arguments: {} })).isError).toBe(true);
    // The SDK client also opens a GET stream, whenever it likes; it's refused, and logged, and not a call.
    expect(lines.filter((line) => line.method === 'GET').every((line) => line.outcome === 'refused')).toBe(true);
    const calls = lines.filter((line) => line.method !== 'GET');
    expect(calls.map((line) => [line.method, line.tool, line.outcome])).toEqual([
      ['initialize', null, 'ok'],
      ['notifications/initialized', null, 'ok'],
      ['tools/list', null, 'ok'],
      ['tools/call', SETTING_TOOL_NAME, 'ok'],
      ['tools/call', FAILING_TOOL_NAME, 'error'],
    ]);
    expect(calls[3]?.arguments).toEqual({ value: 'v', api_key: MASKED, note: MASKED });
    // An accepted call presented the app's own token, so it carries no hash of it.
    expect(lines.every((line) => line.token_sha256 === null)).toBe(true);
    expect(JSON.stringify(lines)).not.toContain(PROD_MCP_TEST_TOKEN);
  });

  it('takes a notification and logs it as it is taken', async () => {
    expect((await post(await listen(), INITIALIZED_NOTIFICATION, PROD_MCP_TEST_TOKEN)).status).toBe(HTTP_ACCEPTED);
    expect(lines).toMatchObject([{ method: 'notifications/initialized', outcome: 'ok' }]);
  });

  it('refuses GET and DELETE, and logs them', async () => {
    const url = await listen();
    const headers = { authorization: `${BEARER_PREFIX}${PROD_MCP_TEST_TOKEN}` };
    expect((await fetch(url, { headers })).status).toBe(HTTP_METHOD_NOT_ALLOWED);
    expect((await fetch(url, { method: 'DELETE', headers })).status).toBe(HTTP_METHOD_NOT_ALLOWED);
    expect(lines).toMatchObject([
      { method: 'GET', outcome: 'refused' },
      { method: 'DELETE', outcome: 'refused' },
    ]);
  });

  it('answers nothing on another path', async () => {
    const url = (await listen()).replace(PROD_MCP_PATH, '/other');
    expect((await post(url, MCP_INITIALIZE_REQUEST, PROD_MCP_TEST_TOKEN)).status).toBe(HTTP_NOT_FOUND);
    expect(lines).toEqual([]);
  });

  it('answers a 500 when a server cannot be built, and logs the call as an error', async () => {
    let builds = 0;
    const url = await listen(() => {
      builds += 1;
      if (builds > 1) throw new Error('broken registration');
      return createProbeProdServer();
    });
    expect((await post(url, MCP_INITIALIZE_REQUEST, PROD_MCP_TEST_TOKEN)).status).toBe(HTTP_INTERNAL_SERVER_ERROR);
    expect(lines).toMatchObject([{ method: 'initialize', outcome: 'error' }]);
  });

  it('answers an initialize with the token', async () => {
    expect((await post(await listen(), MCP_INITIALIZE_REQUEST, PROD_MCP_TEST_TOKEN)).status).toBe(HTTP_OK);
  });
});
