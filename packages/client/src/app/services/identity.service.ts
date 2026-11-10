import { Injectable } from '@angular/core';
import { CLIENT_ID_STORAGE_KEY } from '@base-multiplayer-game/shared';

/**
 * Stable per-browser client identity. The clientId is persisted in
 * localStorage and sent on the WS handshake (`/ws?clientId=...`) so the server
 * can recognise a reconnecting / multi-tab player and hand them back their
 * existing seat (takeover / reattach) instead of treating them as brand new.
 *
 * Game-agnostic: nothing here is specific to any particular game.
 */
@Injectable({ providedIn: 'root' })
export class IdentityService {
  readonly clientId: string;

  constructor() {
    let id = this.read();
    if (!id) {
      id = this.generate();
      this.write(id);
    }
    this.clientId = id;
  }

  private read(): string | null {
    try {
      return localStorage.getItem(CLIENT_ID_STORAGE_KEY);
    } catch {
      return null;
    }
  }

  private write(id: string): void {
    try {
      localStorage.setItem(CLIENT_ID_STORAGE_KEY, id);
    } catch {
      /* localStorage unavailable (private mode, etc.) — ephemeral id is fine. */
    }
  }

  private generate(): string {
    if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) {
      return crypto.randomUUID();
    }
    return `c_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
  }
}
