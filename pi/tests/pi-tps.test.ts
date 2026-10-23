import assert from "node:assert/strict";
import test from "node:test";
import register, { averageTokenRate } from "../extensions/pi-tps.ts";

const WIDGET_CHANNEL = "pi-fancy-footer:widget";
const READY_CHANNEL = "pi-fancy-footer:ready";

type WidgetMessage = {
  type: "upsert" | "remove";
  widget?: { content: { text: string } };
  id?: string;
};

function createHarness() {
  const bus = new Map<string, Array<(payload: never) => void>>();
  const events = new Map<string, Array<(payload: never) => void>>();
  const published: WidgetMessage[] = [];

  const pi = {
    events: {
      on<T>(channel: string, handler: (payload: T) => void) {
        const listener = handler as (payload: never) => void;
        bus.set(channel, [...(bus.get(channel) ?? []), listener]);
        return () => bus.set(channel, (bus.get(channel) ?? []).filter((item) => item !== listener));
      },
      emit(channel: string, payload: never) {
        if (channel === WIDGET_CHANNEL) published.push(payload);
        for (const handler of bus.get(channel) ?? []) handler(payload);
      },
    },
    on<T>(event: string, handler: (payload: T) => void) {
      events.set(event, [...(events.get(event) ?? []), handler as (payload: never) => void]);
    },
  };

  register(pi as never);

  return {
    published,
    emit(event: string, payload: unknown = {}) {
      for (const handler of events.get(event) ?? []) handler(payload as never);
    },
    ready() {
      for (const handler of bus.get(READY_CHANNEL) ?? []) handler({ protocol: 1 } as never);
    },
    lastText() {
      for (let index = published.length - 1; index >= 0; index--) {
        const message = published[index];
        if (message.type === "remove") return undefined;
        if (message.type === "upsert") return message.widget?.content.text;
      }
      return undefined;
    },
  };
}

async function withFrozenNow(run: (advance: (ms: number) => void) => void) {
  const originalNow = Date.now;
  let now = 1_000;
  Date.now = () => now;
  try {
    run((ms) => {
      now += ms;
    });
  } finally {
    Date.now = originalNow;
  }
}

test("averageTokenRate calculates output tokens per second", () => {
  assert.equal(averageTokenRate(100, 2_000), 50);
  assert.equal(averageTokenRate(0, 2_000), undefined);
  assert.equal(averageTokenRate(100, 0), undefined);
});

test("the footer starts without a measured rate", () => {
  assert.equal(createHarness().lastText(), "-- tok/s");
});

test("a completed turn publishes its measured token rate", () => {
  withFrozenNow((advance) => {
    const harness = createHarness();
    harness.emit("turn_start", { timestamp: Date.now() });
    advance(2_000);
    harness.emit("turn_end", {
      message: { role: "assistant", usage: { output: 100 } },
    });
    assert.equal(harness.lastText(), "50.0 tok/s");
  });
});

test("tool execution time is excluded", () => {
  withFrozenNow((advance) => {
    const harness = createHarness();
    harness.emit("turn_start", { timestamp: Date.now() });
    advance(1_000);
    harness.emit("tool_call");
    advance(9_000);
    harness.emit("turn_end", {
      message: { role: "assistant", usage: { output: 100 } },
    });
    assert.equal(harness.lastText(), "100.0 tok/s");
  });
});

test("the session rate is weighted by elapsed time", () => {
  withFrozenNow((advance) => {
    const harness = createHarness();
    harness.emit("turn_start", { timestamp: Date.now() });
    advance(1_000);
    harness.emit("turn_end", { message: { role: "assistant", usage: { output: 100 } } });
    harness.emit("turn_start", { timestamp: Date.now() });
    advance(3_000);
    harness.emit("turn_end", { message: { role: "assistant", usage: { output: 100 } } });
    assert.equal(harness.lastText(), "50.0 tok/s");
  });
});

test("footer ready republishes and shutdown removes the widget", () => {
  const harness = createHarness();
  const before = harness.published.length;
  harness.ready();
  assert.ok(harness.published.length > before);
  harness.emit("session_shutdown");
  assert.equal(harness.lastText(), undefined);
  assert.equal(harness.published.at(-1)?.id, "pi-tps.token-rate");
});
