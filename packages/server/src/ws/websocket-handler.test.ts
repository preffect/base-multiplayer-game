import fastifyWebsocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { WebSocket } from 'ws';
import { buildStubHandlers } from '../testing/handler-builders.js';
import type { Connection } from './connection.js';
import { registerWebSocketHandler, type WebSocketContext } from './websocket-handler.js';

function buildContext(overrides: Partial<WebSocketContext> = {}): WebSocketContext {
  return {
    connections: new Map<string, Connection>(),
    handlers: buildStubHandlers(),
    onConnect: vi.fn(),
    onDisconnect: vi.fn(),
    ...overrides,
  };
}

async function buildServer(context: WebSocketContext): Promise<FastifyInstance> {
  const server = Fastify();
  await server.register(fastifyWebsocket);
  registerWebSocketHandler(server, context);
  await server.ready();
  return server;
}

async function closeClient(client: WebSocket): Promise<void> {
  const closed = new Promise((resolve) => client.once('close', resolve));
  client.terminate();
  await closed;
}

describe('ws/websocket-handler', () => {
  let server: FastifyInstance | undefined;

  afterEach(async () => {
    await server?.close();
  });

  it('registers a connection under the requested client id', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const client = await server.injectWS('/ws?clientId=alice');

    expect([...context.connections.keys()]).toEqual(['alice']);
    expect(context.onConnect).toHaveBeenCalledWith(context.connections.get('alice'));
    client.terminate();
  });

  it.each(['/ws', '/ws?clientId='])('mints an id for %s', async (path) => {
    const context = buildContext();
    server = await buildServer(context);
    const client = await server.injectWS(path);

    const [playerId] = context.connections.keys();
    expect(playerId?.length).toBeGreaterThan(0);
    client.terminate();
  });

  it('routes what the client sends to the handlers', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const client = await server.injectWS('/ws?clientId=alice');

    const handled = vi.mocked(context.handlers.onJoinGame);
    client.send(JSON.stringify({ type: 'join_game', gameId: 'game' }));
    await vi.waitFor(() => expect(handled).toHaveBeenCalledOnce());
    expect(handled.mock.calls[0]?.[1]).toEqual({ type: 'join_game', gameId: 'game' });
    client.terminate();
  });

  it('removes the connection and reports the disconnect on close', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const client = await server.injectWS('/ws?clientId=alice');
    const connection = context.connections.get('alice');

    await closeClient(client);
    await vi.waitFor(() => expect(context.onDisconnect).toHaveBeenCalledWith(connection));
    expect(context.connections.size).toBe(0);
  });

  it('lets a second tab take over, keeping the profile and skipping the disconnect', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const firstTab = await server.injectWS('/ws?clientId=alice');
    const firstConnection = context.connections.get('alice')!;
    firstConnection.playerName = 'Alice';
    firstConnection.avatarIndex = 4;

    const secondTab = await server.injectWS('/ws?clientId=alice');
    await vi.waitFor(() => expect(firstTab.readyState).toBe(firstTab.CLOSED));
    firstConnection.socket.emit('close');

    expect(firstConnection.replaced).toBe(true);
    expect(context.connections.get('alice')).toMatchObject({ playerName: 'Alice', avatarIndex: 4 });
    expect(context.onDisconnect).not.toHaveBeenCalled();
    secondTab.terminate();
  });

  it('survives a replaced socket that refuses to close', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const firstTab = await server.injectWS('/ws?clientId=alice');
    const firstConnection = context.connections.get('alice')!;
    vi.spyOn(firstConnection.socket, 'close').mockImplementationOnce(() => {
      throw new Error('already closed');
    });

    const secondTab = await server.injectWS('/ws?clientId=alice');
    expect(context.connections.get('alice')).not.toBe(firstConnection);
    firstTab.terminate();
    secondTab.terminate();
  });

  it('leaves a newer registered connection in place when an older socket closes', async () => {
    const context = buildContext();
    server = await buildServer(context);
    const client = await server.injectWS('/ws?clientId=alice');
    const newer = { ...context.connections.get('alice')! };
    context.connections.set('alice', newer);

    await closeClient(client);
    await vi.waitFor(() => expect(context.onDisconnect).toHaveBeenCalledOnce());
    expect(context.connections.get('alice')).toBe(newer);
  });

  it('works without the optional lifecycle callbacks', async () => {
    const context = buildContext({ onConnect: undefined, onDisconnect: undefined });
    server = await buildServer(context);
    const client = await server.injectWS('/ws?clientId=alice');

    await closeClient(client);
    await vi.waitFor(() => expect(context.connections.size).toBe(0));
  });
});
