// Integration (docs/ENGINEERING.md §2.2): the lobby shell wired to the REAL MultiplayerService and
// WebSocketService over a fake browser socket — connect, create a game, receive game_started and a
// snapshot, enter the room. Run with `./validate.sh integration`.
import { TestBed } from '@angular/core/testing';
import {
  GAME_NAME_MAX_LEN,
  MAX_PLAYERS_PER_GAME,
  MIN_PLAYERS_PER_GAME,
  PLAYER_NAME_MAX_LEN,
} from '@base-multiplayer-game/shared';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AppComponent } from './app.component';
import { IdentityService } from './services/identity.service';
import { FakeWebSocket } from '../testing/fake-websocket';

const CLIENT_ID = 'alice';
const GAME_ID = 'g1';
const MAX_PLAYERS = 4;
const SNAPSHOT_TICK = 3;

describe('lobby shell + multiplayer services', () => {
  beforeEach(async () => {
    FakeWebSocket.reset();
    vi.stubGlobal('WebSocket', FakeWebSocket);
    await TestBed.configureTestingModule({
      imports: [AppComponent],
      providers: [{ provide: IdentityService, useValue: { clientId: CLIENT_ID } }],
    }).compileComponents();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function renderedInputs(selector: string): HTMLInputElement[] {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    return Array.from((fixture.nativeElement as HTMLElement).querySelectorAll<HTMLInputElement>(selector));
  }

  it('limits the player and game names to what the server accepts', () => {
    expect(renderedInputs('input[type="text"]').map((input) => input.maxLength)).toEqual([
      PLAYER_NAME_MAX_LEN,
      GAME_NAME_MAX_LEN,
    ]);
  });

  it('limits the player count to what the server accepts', () => {
    const [playerCount] = renderedInputs('input[type="number"]');
    expect(playerCount?.min).toBe(String(MIN_PLAYERS_PER_GAME));
    expect(playerCount?.max).toBe(String(MAX_PLAYERS_PER_GAME));
  });

  it('connects, creates a game and enters the room when the server starts it', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const component = fixture.componentInstance;
    component.connect();
    const socket = FakeWebSocket.latest();
    expect(socket.url).toContain(`clientId=${CLIENT_ID}`);
    socket.open();
    component.createGame();
    expect(socket.sentMessages()).toEqual([
      { type: 'join_lobby', playerName: 'Player', avatarIndex: 0 },
      { type: 'create_game', gameName: 'New Game', config: { maxPlayers: MAX_PLAYERS } },
    ]);

    socket.receive(
      JSON.stringify({
        type: 'game_started',
        gameId: GAME_ID,
        playerId: CLIENT_ID,
        playerIds: [CLIENT_ID],
        isHost: true,
        config: { maxPlayers: MAX_PLAYERS },
      }),
    );
    const snapshot = { tick: SNAPSHOT_TICK };
    socket.receive(JSON.stringify({ type: 'game_snapshot', snapshot }));
    await fixture.whenStable();
    fixture.detectChanges();

    const text = (fixture.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain(GAME_ID);
    expect(text).toContain('(host)');
    expect(component.mp.inGame()).toBe(true);
    expect(component.mp.gameId()).toBe(GAME_ID);
    expect(component.mp.isHost()).toBe(true);
    expect(component.mp.latestSnapshot()).toEqual(snapshot);
  });
});
