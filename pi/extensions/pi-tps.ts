/**
 * Shows average output tokens per second in pi-fancy-footer.
 *
 * The calculation matches the previously working extension: output tokens
 * divided by model-response time, excluding tool execution after a tool call.
 * The average covers only the current model: a model switch starts a new one.
 */
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROTOCOL = 1;
const WIDGET_CHANNEL = "pi-fancy-footer:widget";
const READY_CHANNEL = "pi-fancy-footer:ready";
const WIDGET_ID = "pi-tps.token-rate";

export function averageTokenRate(outputTokens: number, elapsedMs: number): number | undefined {
  if (outputTokens <= 0 || elapsedMs <= 0) return undefined;
  const rate = outputTokens / (elapsedMs / 1_000);
  return Number.isFinite(rate) ? rate : undefined;
}

type ReadyMessage = { protocol?: number };
type ModelRef = { provider: string; id: string };

const sameModel = (a: ModelRef | undefined, b: ModelRef | undefined) =>
  a?.provider === b?.provider && a?.id === b?.id;

export default function (pi: ExtensionAPI) {
  let totalOutputTokens = 0;
  let totalMs = 0;
  let turnStartMs: number | undefined;
  let turnStreamEndMs: number | undefined;
  let currentRate: number | undefined;

  const reset = () => {
    totalOutputTokens = 0;
    totalMs = 0;
    turnStartMs = undefined;
    turnStreamEndMs = undefined;
    currentRate = undefined;
  };

  const publish = () => {
    pi.events.emit(WIDGET_CHANNEL, {
      protocol: PROTOCOL,
      type: "upsert",
      widget: {
        id: WIDGET_ID,
        label: "Token rate (TPS)",
        description: "Average output tokens per second for this session.",
        content: {
          type: "text",
          text: currentRate === undefined ? "-- tok/s" : `${currentRate.toFixed(1)} tok/s`,
        },
        icon: false,
        style: { textColor: "success" },
        layout: { row: 0, position: 3, align: "right" },
      },
    });
  };

  const stopReady = pi.events.on(READY_CHANNEL, (message: ReadyMessage) => {
    if (message?.protocol === PROTOCOL) publish();
  });

  publish();

  pi.on("session_start", () => {
    reset();
    publish();
  });

  pi.on("model_select", (event) => {
    if (sameModel(event.model, event.previousModel)) return;
    // Also drops a turn in flight: its tokens belong to the previous model.
    reset();
    publish();
  });

  pi.on("turn_start", (event) => {
    turnStartMs = event.timestamp ?? Date.now();
    turnStreamEndMs = undefined;
  });

  pi.on("tool_call", () => {
    if (turnStartMs !== undefined && turnStreamEndMs === undefined) {
      turnStreamEndMs = Date.now();
    }
  });

  pi.on("turn_end", (event) => {
    const message = event.message as AssistantMessage | undefined;
    if (!message || message.role !== "assistant" || turnStartMs === undefined) {
      turnStartMs = undefined;
      turnStreamEndMs = undefined;
      return;
    }

    const endMs = turnStreamEndMs ?? Date.now();
    const elapsedMs = Math.max(1, endMs - turnStartMs);
    const outputTokens = message.usage?.output ?? 0;

    if (outputTokens > 0) {
      totalOutputTokens += outputTokens;
      totalMs += elapsedMs;
      currentRate = averageTokenRate(totalOutputTokens, totalMs);
      publish();
    }

    turnStartMs = undefined;
    turnStreamEndMs = undefined;
  });

  pi.on("session_shutdown", () => {
    stopReady();
    pi.events.emit(WIDGET_CHANNEL, {
      protocol: PROTOCOL,
      type: "remove",
      id: WIDGET_ID,
    });
  });
}
