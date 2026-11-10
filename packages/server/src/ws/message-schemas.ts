import { z } from 'zod';
import {
  AVATAR_INDEX_MAX,
  AVATAR_INDEX_MIN,
  GAME_NAME_MAX_LEN,
  MAX_PLAYERS_PER_GAME,
  MIN_PLAYERS_PER_GAME,
  PLAYER_NAME_MAX_LEN,
} from '@base-multiplayer-game/shared';

/**
 * Inbound message validation. Lobby/perf verbs are fully validated; the single
 * gameplay verb's payload is `z.unknown()` because this is LOCAL-ONLY play and
 * we trust the client wholesale (no anti-cheat). The init step replaces the
 * payload schema with the real game input shape.
 *
 * Two zod 4 behaviours are deliberate here. `payload` must be present, as `ClientMessage` declares it,
 * so a client with no input sends `null`. `z.number()` rejects Infinity, which JSON can only produce by
 * overflow (`1e999`), and the perf stats need finite numbers.
 */

/**
 * Non-empty text of at most `maxLength` UTF-16 code units, which is what the `*_MAX_LEN` constants and
 * `String.length` mean. zod 4's `.max()` counts code points, so it would let in twice as many emoji.
 */
function boundedText(maxLength: number) {
  return z
    .string()
    .min(1)
    .refine((text) => text.length <= maxLength, { error: `Too long: at most ${maxLength} characters` });
}

/** The profile a player sends when joining the lobby and when updating it. */
const playerProfileFields = {
  playerName: boundedText(PLAYER_NAME_MAX_LEN),
  avatarIndex: z.number().int().min(AVATAR_INDEX_MIN).max(AVATAR_INDEX_MAX),
};

const joinLobbySchema = z.object({ type: z.literal('join_lobby'), ...playerProfileFields });

const updatePlayerInfoSchema = z.object({ type: z.literal('update_player_info'), ...playerProfileFields });

const createGameSchema = z.object({
  type: z.literal('create_game'),
  gameName: boundedText(GAME_NAME_MAX_LEN),
  config: z
    .object({
      maxPlayers: z.number().int().min(MIN_PLAYERS_PER_GAME).max(MAX_PLAYERS_PER_GAME),
      // TODO(game): add game-specific session config fields here.
    })
    .loose(),
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
