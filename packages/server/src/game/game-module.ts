import type { PlayerId, GameSnapshot, GameInput } from '@base-multiplayer-game/shared';

/**
 * Per-room game logic. ONE instance per active GameRoom. This is THE place the
 * game plugs in. The default impl below is a working trust-client "echo" game so
 * the template runs end-to-end before any real game is defined.
 */
export interface GameModule {
  /** Store/merge the latest input for a player (called from the message router). */
  submitInput(pid: PlayerId, payload: GameInput): void;
  /** Advance the world one tick (called at TICK_HZ by GameRoom). */
  reduceGameState(): void;
  /** Produce the broadcast snapshot for this tick. */
  serializeRoomState(): GameSnapshot;
  /** A player joined mid-game. */
  addPlayer(pid: PlayerId, avatarIndex: number, playerName: string): void;
  /** A player left. Drop their entity so it stops appearing in snapshots. */
  removePlayer(pid: PlayerId): void;
  /** Free any resources on room teardown. */
  free?(): void;
}

export interface RoomInitArgs {
  creatorId: PlayerId;
  playerIds: PlayerId[];
  gameName: string;
  config: { maxPlayers: number };
  avatarAssignments: Record<string, number>;
  playerNames: Record<string, string>;
}

/** Factory the LobbyManager uses to create a room's game logic. */
export type GameModuleFactory = (args: RoomInitArgs) => GameModule;

/**
 * DEFAULT TODO IMPL: trust-client echo. Stores the latest input per player and
 * echoes `{ players: { [pid]: lastInput } }` as the snapshot. Replace in the
 * init step with the real game logic.
 */
export const defaultGameModuleFactory: GameModuleFactory = (args) => {
  const latest = new Map<string, GameInput>();
  const players = new Set<string>(args.playerIds);
  return {
    submitInput: (pid, payload) => {
      latest.set(pid, payload);
    },
    reduceGameState: () => {
      /* TODO(game): advance world one tick */
    },
    serializeRoomState: () => {
      const out: Record<string, GameInput> = {};
      for (const pid of players) out[pid] = latest.get(pid) ?? null;
      return { players: out } as unknown as GameSnapshot; // TODO(game): real snapshot
    },
    addPlayer: (pid) => {
      players.add(pid);
    },
    removePlayer: (pid) => {
      players.delete(pid);
      latest.delete(pid);
    },
  };
};
