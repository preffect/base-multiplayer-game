import { Injectable, inject, signal } from '@angular/core';
import { Subject, type Observable } from 'rxjs';
import type { ClientMessage, ServerMessage } from '@base-multiplayer-game/shared';
import { IdentityService } from './identity.service';

/**
 * Low-level WebSocket transport. Game-agnostic.
 *
 * Responsibilities:
 *  - Open/keep-alive a single WS to `/ws?clientId=...` (proxied to the server).
 *  - Auto-reconnect with a small backoff.
 *  - Queue outbound messages while disconnected and flush on (re)connect.
 *  - Expose every inbound `ServerMessage` via `messages$`.
 *  - Provide a `drainLatestSnapshot()` fast-path that coalesces high-frequency
 *    `game_snapshot` frames so a render loop only ever consumes the newest one.
 *
 * Higher-level lobby/room/game state lives in MultiplayerService.
 */
const RECONNECT_DELAY_MS = 500;

@Injectable({ providedIn: 'root' })
export class WebSocketService {
  /** Reactive connection flag for UI binding. */
  readonly connected = signal(false);

  private socket: WebSocket | null = null;
  private readonly outbound: string[] = [];
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private closedByUser = false;

  private readonly messages = new Subject<ServerMessage>();
  /** Stream of all decoded inbound server messages. */
  readonly messages$: Observable<ServerMessage> = this.messages.asObservable();

  /**
   * Coalescing fast-path: the most recent `game_snapshot` message that has not
   * yet been drained. A render loop calls `drainLatestSnapshot()` once per
   * frame and renders only the freshest world state, dropping intermediate
   * frames that arrived faster than it can render.
   */
  private latestSnapshot: ServerMessage | null = null;

  private readonly identity = inject(IdentityService);

  connect(): void {
    if (this.socket && (this.socket.readyState === WebSocket.OPEN || this.socket.readyState === WebSocket.CONNECTING)) {
      return;
    }
    this.closedByUser = false;
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const url = `${proto}://${location.host}/ws?clientId=${encodeURIComponent(this.identity.clientId)}`;
    const ws = new WebSocket(url);
    this.socket = ws;

    ws.onopen = () => {
      this.connected.set(true);
      // Flush anything queued while we were offline.
      for (const raw of this.outbound.splice(0)) {
        ws.send(raw);
      }
    };

    ws.onmessage = (ev) => {
      const raw = typeof ev.data === 'string' ? ev.data : '';
      if (!raw) return;
      // Fast-path: coalesce snapshot frames without JSON-parsing on the hot path
      // unless we actually need the object.
      if (raw.startsWith('{"type":"game_snapshot"')) {
        try {
          this.latestSnapshot = JSON.parse(raw) as ServerMessage;
        } catch {
          /* ignore malformed frame */
        }
        return;
      }
      let msg: ServerMessage;
      try {
        msg = JSON.parse(raw) as ServerMessage;
      } catch {
        return;
      }
      this.messages.next(msg);
    };

    ws.onclose = () => {
      this.connected.set(false);
      this.socket = null;
      if (!this.closedByUser) {
        this.scheduleReconnect();
      }
    };

    ws.onerror = () => {
      // Let onclose drive reconnection.
      ws.close();
    };
  }

  disconnect(): void {
    this.closedByUser = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.socket?.close();
    this.socket = null;
    this.connected.set(false);
  }

  /** Send a typed client message (queued if currently disconnected). */
  send(msg: ClientMessage): void {
    const raw = JSON.stringify(msg);
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(raw);
    } else {
      this.outbound.push(raw);
    }
  }

  /**
   * Return the freshest un-rendered `game_snapshot` message, or null if none
   * has arrived since the last drain. Intended to be called once per render
   * frame so the UI always renders the latest world state.
   */
  drainLatestSnapshot(): ServerMessage | null {
    const s = this.latestSnapshot;
    this.latestSnapshot = null;
    return s;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, RECONNECT_DELAY_MS);
  }
}
