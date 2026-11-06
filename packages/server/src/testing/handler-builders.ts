import { vi } from 'vitest';
import type { MessageHandlers } from '../ws/message-router.js';

/** Every message handler as a spy, for tests of the transport rather than the lobby. */
export function buildStubHandlers(): MessageHandlers {
  return {
    onJoinLobby: vi.fn(),
    onUpdatePlayerInfo: vi.fn(),
    onCreateGame: vi.fn(),
    onJoinGame: vi.fn(),
    onStartGame: vi.fn(),
    onDeleteGame: vi.fn(),
    onPlayerInput: vi.fn(),
    onClientPerformance: vi.fn(),
  };
}
