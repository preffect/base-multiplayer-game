import type { ServerMessage } from '@base-multiplayer-game/shared';
import type { Connection } from '../ws/connection.js';

const SOCKET_OPEN = 1;

export interface RecordingConnection {
  connection: Connection;
  /** Every message sent to this connection, oldest first. */
  sent: ServerMessage[];
}

/** A connection over a fake open socket that records what the server sends it. */
export function buildRecordingConnection(playerId: string, avatarIndex = 0): RecordingConnection {
  const sent: ServerMessage[] = [];
  const socket = {
    readyState: SOCKET_OPEN,
    send: (data: string) => sent.push(JSON.parse(data) as ServerMessage),
    close: () => {},
    on: () => {},
  } as unknown as Connection['socket'];
  return { connection: { playerId, playerName: playerId, avatarIndex, socket }, sent };
}

/** The messages of one type, narrowed to that variant. */
export function messagesOfType<Type extends ServerMessage['type']>(
  sent: ServerMessage[],
  type: Type,
): Extract<ServerMessage, { type: Type }>[] {
  return sent.filter((message): message is Extract<ServerMessage, { type: Type }> => message.type === type);
}
