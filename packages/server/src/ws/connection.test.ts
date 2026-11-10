import { describe, expect, it } from 'vitest';
import { buildRecordingConnection } from '../testing/connection-builders.js';
import { broadcastMessage, sendMessage, type Connection } from './connection.js';

const SOCKET_CLOSED = 3;
const MESSAGE = { type: 'error', message: 'nope' } as const;

function closedConnection(): ReturnType<typeof buildRecordingConnection> {
  const recording = buildRecordingConnection('closed');
  const socket = { ...recording.connection.socket, readyState: SOCKET_CLOSED } as Connection['socket'];
  return { ...recording, connection: { ...recording.connection, socket } };
}

describe('ws/connection', () => {
  it('sendMessage delivers to an open socket and returns the length', () => {
    const { connection, sent } = buildRecordingConnection('open');
    expect(sendMessage(connection, MESSAGE)).toBe(JSON.stringify(MESSAGE).length);
    expect(sent).toEqual([MESSAGE]);
  });

  it('sendMessage skips a closed socket', () => {
    const { connection, sent } = closedConnection();
    expect(sendMessage(connection, MESSAGE)).toBe(0);
    expect(sent).toEqual([]);
  });

  it('broadcastMessage reaches only the open sockets', () => {
    const open = buildRecordingConnection('open');
    const closed = closedConnection();
    expect(broadcastMessage([open.connection, closed.connection], MESSAGE)).toBe(JSON.stringify(MESSAGE).length);
    expect(open.sent).toEqual([MESSAGE]);
    expect(closed.sent).toEqual([]);
  });
});
