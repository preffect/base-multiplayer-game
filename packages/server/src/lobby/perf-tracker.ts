import type { PlayerId } from '@base-multiplayer-game/shared';
import type { ClientPerformanceReport } from '@base-multiplayer-game/shared';

/** Re-export the client report shape under the name the lobby layer uses. */
export type ClientPerfReport = ClientPerformanceReport;

const SAMPLE_CAPACITY = 300;

/** One server tick's measurements. Game-agnostic. */
export interface TickRecord {
  tickMs: number;
  snapshotBytes: number;
  broadcastClients: number;
  /** Optional free-form counts a game may report (e.g. { entities: 12 }). */
  entities?: Record<string, number>;
}

export interface PerfStats {
  sampleCount: number;
  tickAvgMs: number;
  tickP95Ms: number;
  tickPeakMs: number;
  broadcastBytesPerSec: number;
  worstTick: TickRecord | null;
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}

/**
 * Server-side tick telemetry with a fixed ring buffer, plus a per-client
 * performance-report store. Fully game-agnostic.
 */
export class PerfTracker {
  private readonly ticks: TickRecord[] = [];
  private cursor = 0;
  private worst: TickRecord | null = null;
  private readonly clientReports = new Map<string, ClientPerfReport>();

  recordTick(record: TickRecord): void {
    if (this.ticks.length < SAMPLE_CAPACITY) {
      this.ticks.push(record);
    } else {
      this.ticks[this.cursor] = record;
      this.cursor = (this.cursor + 1) % SAMPLE_CAPACITY;
    }
    if (!this.worst || record.tickMs > this.worst.tickMs) {
      this.worst = record;
    }
  }

  worstTick(): TickRecord | null {
    return this.worst;
  }

  recordClientReport(pid: PlayerId, report: ClientPerfReport): void {
    this.clientReports.set(pid, report);
  }

  removeClient(pid: PlayerId): void {
    this.clientReports.delete(pid);
  }

  clientReportsSnapshot(): Record<string, ClientPerfReport> {
    return Object.fromEntries(this.clientReports);
  }

  getStats(): PerfStats {
    const n = this.ticks.length;
    if (n === 0) {
      return {
        sampleCount: 0,
        tickAvgMs: 0,
        tickP95Ms: 0,
        tickPeakMs: 0,
        broadcastBytesPerSec: 0,
        worstTick: null,
      };
    }
    const tickTimes = this.ticks.map((t) => t.tickMs).sort((a, b) => a - b);
    const sum = tickTimes.reduce((acc, v) => acc + v, 0);
    const p95Index = Math.min(n - 1, Math.floor(n * 0.95));
    const avgMs = sum / n;
    // Approximate broadcast bytes/sec from average snapshot size * clients @ ~60Hz.
    const avgBytes = this.ticks.reduce((acc, t) => acc + t.snapshotBytes * t.broadcastClients, 0) / n;
    return {
      sampleCount: n,
      tickAvgMs: round(avgMs),
      tickP95Ms: round(tickTimes[p95Index] ?? 0),
      tickPeakMs: round(this.worst?.tickMs ?? 0),
      broadcastBytesPerSec: round(avgBytes * 60),
      worstTick: this.worst,
    };
  }

  /** Convenience accessor used by MCP performance handlers. */
  get stats(): PerfStats {
    return this.getStats();
  }
}
