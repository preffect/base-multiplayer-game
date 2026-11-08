import { describe, expect, it } from 'vitest';
import { BRIDGE_GATEWAY_ADDRESS, LAN_PEER_ADDRESS, LOOPBACK_HOST_WITH_PORT } from '../testing/debug-mcp-builders.js';
import {
  LOOPBACK_PEER_ADDRESSES,
  isAllowedDebugMcpRequest,
  isLoopbackHost,
  isLoopbackOrigin,
  isLoopbackPeer,
} from './loopback-guard.js';

describe('mcp/loopback-guard', () => {
  it.each([
    'localhost',
    LOOPBACK_HOST_WITH_PORT,
    'LOCALHOST:9000',
    '127.0.0.1',
    '127.0.0.1:9000',
    '[::1]',
    '[::1]:9000',
  ])('allows the loopback Host %s', (host) => expect(isLoopbackHost(host)).toBe(true));

  it.each([undefined, '', 'example.com', 'localhost.example.com', '127.0.0.2', '10.0.0.5:9000', 'localhost:', '::1'])(
    'refuses the Host %s',
    (host) => expect(isLoopbackHost(host)).toBe(false),
  );

  it.each([undefined, 'http://localhost:9000', 'https://127.0.0.1', 'http://[::1]:9000'])(
    'allows the Origin %s',
    (origin) => expect(isLoopbackOrigin(origin)).toBe(true),
  );

  it.each(['null', 'http://example.com', 'http://localhost.example.com', 'file://localhost', 'http://localhost/path'])(
    'refuses the Origin %s',
    (origin) => expect(isLoopbackOrigin(origin)).toBe(false),
  );

  it.each(LOOPBACK_PEER_ADDRESSES)('allows the loopback peer %s', (peerAddress) => {
    expect(isLoopbackPeer(peerAddress)).toBe(true);
  });

  it.each([undefined, LAN_PEER_ADDRESS, BRIDGE_GATEWAY_ADDRESS, `::ffff:${BRIDGE_GATEWAY_ADDRESS}`, '127.0.0.2'])(
    'refuses the peer %s',
    (peerAddress) => expect(isLoopbackPeer(peerAddress)).toBe(false),
  );

  it('needs the peer, the Host and the Origin to pass together', () => {
    const allowed = { host: LOOPBACK_HOST_WITH_PORT, origin: undefined, peerAddress: '127.0.0.1' };
    expect(isAllowedDebugMcpRequest(allowed)).toBe(true);
    expect(isAllowedDebugMcpRequest({ ...allowed, peerAddress: LAN_PEER_ADDRESS })).toBe(false);
    expect(isAllowedDebugMcpRequest({ ...allowed, host: 'example.com' })).toBe(false);
    expect(isAllowedDebugMcpRequest({ ...allowed, origin: 'http://example.com' })).toBe(false);
  });
});
