import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import {
  GAME_NAME_MAX_LEN,
  MAX_PLAYERS_PER_GAME,
  MIN_PLAYERS_PER_GAME,
  PLAYER_NAME_MAX_LEN,
} from '@base-multiplayer-game/shared';
import { MultiplayerService } from './services/multiplayer.service';

/**
 * Minimal, GAME-AGNOSTIC lobby / connection UI stub.
 *
 * It exercises the full multiplayer plumbing — connect, join lobby, create /
 * join / start a game, and view the live room state + latest snapshot JSON —
 * without implementing any specific game. The marked `TODO(game)` area is where the
 * real game canvas/board mounts (see `game/game-setup.ts`).
 */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [FormsModule],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent {
  readonly title = 'Base Multiplayer Game';

  readonly mp = inject(MultiplayerService);

  // The limits the server enforces, for the form's inputs.
  readonly playerNameMaxLength = PLAYER_NAME_MAX_LEN;
  readonly gameNameMaxLength = GAME_NAME_MAX_LEN;
  readonly minPlayers = MIN_PLAYERS_PER_GAME;
  readonly maxPlayersAllowed = MAX_PLAYERS_PER_GAME;

  // Local lobby form state.
  readonly playerName = signal('Player');
  readonly newGameName = signal('New Game');
  readonly maxPlayers = signal(4);

  readonly snapshotJson = computed(() => {
    const snap = this.mp.snapshot();
    return snap == null ? '(no snapshot yet)' : JSON.stringify(snap, null, 2);
  });

  connect(): void {
    this.mp.connect();
    // Immediately announce ourselves to the lobby (queued until the WS opens).
    this.mp.joinLobby(this.playerName(), 0);
  }

  disconnect(): void {
    this.mp.disconnect();
  }

  createGame(): void {
    this.mp.createGame(this.newGameName(), { maxPlayers: this.maxPlayers() });
  }

  joinGame(id: string): void {
    this.mp.joinGame(id);
  }

  startGame(id: string): void {
    this.mp.startGame(id);
  }

  deleteGame(id: string): void {
    this.mp.deleteGame(id);
  }
}
