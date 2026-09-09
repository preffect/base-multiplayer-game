// Pure, reusable identity + math primitives shared by server and client.
// No framework dependencies. Game-agnostic.

export interface Vec2 {
  x: number;
  y: number;
}

// ===== Branded id types =====
// Branding keeps PlayerId / GameId / EntityId / Tick from being mixed up at
// the type level while remaining plain strings/numbers at runtime.

export type PlayerId = string & { readonly __brand: 'PlayerId' };
export type GameId = string & { readonly __brand: 'GameId' };
export type EntityId = string & { readonly __brand: 'EntityId' };
export type Tick = number & { readonly __brand: 'Tick' };

export const playerId = (s: string): PlayerId => s as PlayerId;
export const gameId = (s: string): GameId => s as GameId;
export const entityId = (s: string): EntityId => s as EntityId;
export const tick = (n: number): Tick => n as Tick;

// ===== Pure helpers =====

/** Clamp a number into the inclusive [min, max] range. */
export const clamp = (value: number, min: number, max: number): number =>
  value < min ? min : value > max ? max : value;

/**
 * True when a room can accept another player: it has not started and is not
 * yet at capacity. Pure helper shared by the lobby (server) and room browser
 * (client) so "joinable" is defined in exactly one place.
 */
export const isRoomJoinable = (room: { started: boolean; playerCount: number; maxPlayers: number }): boolean =>
  !room.started && room.playerCount < room.maxPlayers;
