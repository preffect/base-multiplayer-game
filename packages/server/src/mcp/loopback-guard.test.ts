import { describe, expect, it } from 'vitest';
import { isLoopbackHost, isLoopbackOrigin } from './loopback-guard.js';

describe('mcp/loopback-guard', () => {
  it.each(['localhost', 'localhost:4400', 'LOCALHOST:4400', '127.0.0.1', '127.0.0.1:4400', '[::1]', '[::1]:4400'])(
    'allows the loopback Host %s',
    (host) => expect(isLoopbackHost(host)).toBe(true),
  );

  it.each([undefined, '', 'example.com', 'localhost.example.com', '127.0.0.2', '10.0.0.5:4400', 'localhost:', '::1'])(
    'refuses the Host %s',
    (host) => expect(isLoopbackHost(host)).toBe(false),
  );

  it.each([undefined, 'http://localhost:4402', 'https://127.0.0.1', 'http://[::1]:4400'])(
    'allows the Origin %s',
    (origin) => expect(isLoopbackOrigin(origin)).toBe(true),
  );

  it.each(['null', 'http://example.com', 'http://localhost.example.com', 'file://localhost', 'http://localhost/path'])(
    'refuses the Origin %s',
    (origin) => expect(isLoopbackOrigin(origin)).toBe(false),
  );
});
