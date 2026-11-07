import { describe, expect, it } from 'vitest';
import { playerId, TICK_HZ, type ClientPerformanceReport } from '@base-multiplayer-game/shared';
import { PerfTracker, type TickRecord } from './perf-tracker.js';

const SAMPLE_CAPACITY = 300;
const CLIENT_REPORT: ClientPerformanceReport = {
  fps: 60,
  frameTimeAvgMs: 16,
  frameTimeP95Ms: 18,
  frameTimePeakMs: 30,
  heapMb: null,
};

function tickOf(tickMs: number, snapshotBytes = 0, broadcastClients = 0): TickRecord {
  return { tickMs, snapshotBytes, broadcastClients };
}

describe('PerfTracker', () => {
  it('reports zeroes before any tick', () => {
    expect(new PerfTracker().stats).toEqual({
      sampleCount: 0,
      tickAvgMs: 0,
      tickP95Ms: 0,
      tickPeakMs: 0,
      broadcastBytesPerSec: 0,
      worstTick: null,
    });
  });

  it('averages ticks and estimates broadcast bytes per second', () => {
    const tracker = new PerfTracker();
    tracker.recordTick(tickOf(1, 100, 2));
    tracker.recordTick(tickOf(3, 300, 2));
    expect(tracker.getStats()).toMatchObject({
      sampleCount: 2,
      tickAvgMs: 2,
      tickPeakMs: 3,
      broadcastBytesPerSec: 400 * TICK_HZ,
    });
  });

  it('keeps the slowest tick, whatever order ticks arrive in', () => {
    const tracker = new PerfTracker();
    const slowest = tickOf(9);
    tracker.recordTick(tickOf(1));
    tracker.recordTick(slowest);
    tracker.recordTick(tickOf(2));
    expect(tracker.worstTick()).toBe(slowest);
  });

  it('holds a fixed number of samples, overwriting the oldest', () => {
    const tracker = new PerfTracker();
    for (let index = 0; index < SAMPLE_CAPACITY; index += 1) tracker.recordTick(tickOf(100));
    for (let index = 0; index < SAMPLE_CAPACITY; index += 1) tracker.recordTick(tickOf(1));
    expect(tracker.getStats()).toMatchObject({ sampleCount: SAMPLE_CAPACITY, tickAvgMs: 1, tickPeakMs: 100 });
  });

  it('stores the latest report per client until the client is removed', () => {
    const tracker = new PerfTracker();
    const client = playerId('client');
    tracker.recordClientReport(client, CLIENT_REPORT);
    expect(tracker.clientReportsSnapshot()).toEqual({ client: CLIENT_REPORT });
    tracker.removeClient(client);
    expect(tracker.clientReportsSnapshot()).toEqual({});
  });
});
