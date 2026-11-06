import { describe, expect, it } from 'vitest';
import { playerId } from '@base-multiplayer-game/shared';
import { defaultGameModuleFactory, type GameModule } from './game-module.js';

const ALICE = playerId('alice');
const BOB = playerId('bob');

function buildEchoGame(): GameModule {
  return defaultGameModuleFactory({
    creatorId: ALICE,
    playerIds: [ALICE],
    gameName: 'Echo',
    config: { maxPlayers: 2 },
    avatarAssignments: {},
    playerNames: {},
  });
}

describe('defaultGameModuleFactory', () => {
  it('echoes each player, with null until they send input', () => {
    const game = buildEchoGame();
    expect(game.serializeRoomState()).toEqual({ players: { alice: null } });
    game.submitInput(ALICE, { x: 1 });
    game.reduceGameState();
    expect(game.serializeRoomState()).toEqual({ players: { alice: { x: 1 } } });
  });

  it('adds a late player and forgets one who leaves', () => {
    const game = buildEchoGame();
    game.addPlayer(BOB, 0, 'Bob');
    game.submitInput(ALICE, 'input');
    game.removePlayer(ALICE);
    expect(game.serializeRoomState()).toEqual({ players: { bob: null } });
  });
});
