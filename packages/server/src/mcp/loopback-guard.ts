/**
 * Who may reach the debug MCP: a client on this machine's loopback, asking for a loopback host.
 * The policy is in the README's "MCP visibility" section; this file is its one implementation.
 * Template-owned: it names nothing game-specific.
 */

/** localhost, 127.0.0.1 or [::1], with an optional port. Anything else, such as a rebinding name, is refused. */
const LOOPBACK_AUTHORITY = String.raw`(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?`;
const LOOPBACK_HOST_PATTERN = new RegExp(`^${LOOPBACK_AUTHORITY}$`, 'i');
const LOOPBACK_ORIGIN_PATTERN = new RegExp(`^https?://${LOOPBACK_AUTHORITY}$`, 'i');

/** The loopback peer addresses as Node reports them: IPv4, IPv6, and IPv4 mapped into IPv6. */
export const LOOPBACK_PEER_ADDRESSES: readonly string[] = ['127.0.0.1', '::1', '::ffff:127.0.0.1'];

/** The parts of a request the guard reads. */
export interface DebugMcpRequestSource {
  host: string | undefined;
  origin: string | undefined;
  peerAddress: string | undefined;
}

/** Whether a Host header names this machine's loopback. A missing Host is not. */
export function isLoopbackHost(host: string | undefined): boolean {
  return host !== undefined && LOOPBACK_HOST_PATTERN.test(host);
}

/** Whether an Origin header is absent (a non-browser client) or a loopback page. */
export function isLoopbackOrigin(origin: string | undefined): boolean {
  return origin === undefined || LOOPBACK_ORIGIN_PATTERN.test(origin);
}

/**
 * Whether the connection comes from loopback. This is what stops another machine, which can forge
 * any Host header but not its own address. A Docker-published port is reached from the bridge
 * gateway, so it is refused too: every outside client arrives from that same address.
 */
export function isLoopbackPeer(peerAddress: string | undefined): boolean {
  return peerAddress !== undefined && LOOPBACK_PEER_ADDRESSES.includes(peerAddress);
}

/** Whether the peer, the Host and the Origin all pass. */
export function isAllowedDebugMcpRequest(source: DebugMcpRequestSource): boolean {
  return isLoopbackPeer(source.peerAddress) && isLoopbackHost(source.host) && isLoopbackOrigin(source.origin);
}
