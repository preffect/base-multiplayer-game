import type { FastifyReply, FastifyRequest } from 'fastify';

const HTTP_FORBIDDEN = 403;

/** localhost, 127.0.0.1 or [::1], with an optional port. Anything else, such as a rebinding name, is refused. */
const LOOPBACK_AUTHORITY = String.raw`(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?`;
const LOOPBACK_HOST_PATTERN = new RegExp(`^${LOOPBACK_AUTHORITY}$`, 'i');
const LOOPBACK_ORIGIN_PATTERN = new RegExp(`^https?://${LOOPBACK_AUTHORITY}$`, 'i');

/** Whether a Host header names this machine's loopback. A missing Host is not. */
export function isLoopbackHost(host: string | undefined): boolean {
  return host !== undefined && LOOPBACK_HOST_PATTERN.test(host);
}

/** Whether an Origin header is absent (a non-browser client) or a loopback page. */
export function isLoopbackOrigin(origin: string | undefined): boolean {
  return origin === undefined || LOOPBACK_ORIGIN_PATTERN.test(origin);
}

/**
 * An onRequest hook that refuses any request whose Host or Origin is not loopback, so neither a
 * remote client nor a page on another site (DNS rebinding) can read the debug tools. A hook rather
 * than the transport's `allowedHosts`, which SDK 1.27 deprecates.
 */
export async function refuseNonLoopback(
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<FastifyReply | undefined> {
  if (isLoopbackHost(request.headers.host) && isLoopbackOrigin(request.headers.origin)) return undefined;
  return reply.code(HTTP_FORBIDDEN).send({ error: 'The debug MCP only answers on localhost' });
}
