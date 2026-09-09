import { z } from 'zod';

/**
 * Inbound message validation. Lobby/perf verbs are fully validated; the single
 * gameplay verb's payload is `z.unknown()` because this is LOCAL-ONLY play and
 * we trust the client wholesale (no anti-cheat). The init step replaces the
 * payload schema with the real game input shape.
 */

const joinLobbySchema = z.object({
  type: z.literal('join_lobby'),
  playerName: z.string().min(1).max(20),
  avatarIndex: z.number().int().min(0).max(5),
});

const updatePlayerInfoSchema = z.object({
  type: z.literal('update_player_info'),
  playerName: z.string().min(1).max(20),
  avatarIndex: z.number().int().min(0).max(5),
});

const createGameSchema = z.object({
  type: z.literal('create_game'),
  gameName: z.string().min(1).max(40),
  config: z
    .object({
      maxPlayers: z.number().int().min(1).max(8),
      // TODO(game): add game-specific session config fields here.
    })
    .passthrough(),
});

const joinGameSchema = z.object({ type: z.literal('join_game'), gameId: z.string().min(1) });
const startGameSchema = z.object({ type: z.literal('start_game'), gameId: z.string().min(1) });
const deleteGameSchema = z.object({ type: z.literal('delete_game'), gameId: z.string().min(1) });

// TODO(game): replace z.unknown() with your validated input schema (local-only: trusting client).
const playerInputSchema = z.object({
  type: z.literal('player_input'),
  payload: z.unknown(),
});

const clientPerformanceSchema = z.object({
  type: z.literal('client_performance'),
  report: z.object({
    fps: z.number(),
    frameTimeAvgMs: z.number(),
    frameTimeP95Ms: z.number(),
    frameTimePeakMs: z.number(),
    heapMb: z.number().nullable(),
  }),
});

export const clientMessageSchema = z.discriminatedUnion('type', [
  joinLobbySchema,
  updatePlayerInfoSchema,
  createGameSchema,
  joinGameSchema,
  startGameSchema,
  deleteGameSchema,
  playerInputSchema,
  clientPerformanceSchema,
]);

export type ValidatedClientMessage = z.infer<typeof clientMessageSchema>;
