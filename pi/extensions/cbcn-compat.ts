import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Flatten top-level anyOf/oneOf in tool parameter schemas.
 *
 * The code-mode extension's `notebook` tool (and any future tool) may declare
 * `Type.Union([...])` parameters, which serializes to a top-level `anyOf`.
 * Codebuddy's gateway (9router `cbcn/*` models) rejects that with
 * 400 code 11129/11133 "invalid function call parameters". OpenAI-compatible
 * function calling expects `parameters` to be a single object schema.
 *
 * The merge keeps the union's acceptance semantics: a property is required only
 * if every variant requires it, and enums for the same property are unioned.
 * Per-action validation still runs inside the tool at execution time.
 */

type Schema = Record<string, any>;

function isPlainObject(value: unknown): value is Schema {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Merge a top-level anyOf/oneOf into one object schema. Returns null if not applicable. */
export function flattenUnionParameters(schema: unknown): Schema | null {
  if (!isPlainObject(schema)) return null;
  const variants: unknown[] = schema.anyOf ?? schema.oneOf;
  if (!Array.isArray(variants) || variants.length === 0) return null;

  const objectVariants: Schema[] = variants.filter(isPlainObject);
  const properties: Record<string, Schema> = {};
  let required: string[] | null = null;
  let allForbidAdditional = true;

  for (const variant of objectVariants) {
    if (variant.additionalProperties !== false) allForbidAdditional = false;

    const variantRequired: string[] = Array.isArray(variant.required) ? variant.required : [];
    required = required === null ? variantRequired : required.filter((k) => variantRequired.includes(k));

    for (const [name, prop] of Object.entries(variant.properties ?? {})) {
      if (!isPlainObject(prop)) continue;
      const existing = properties[name];
      if (!existing) {
        properties[name] = { ...prop };
      } else if (Array.isArray(existing.enum) && Array.isArray(prop.enum)) {
        properties[name] = { ...existing, enum: [...new Set([...existing.enum, ...prop.enum])] };
      }
    }
  }

  // A non-object variant accepts anything, so nothing can stay required.
  if (objectVariants.length < variants.length) required = [];

  const merged: Schema = { type: "object", properties };
  if (required && required.length > 0) merged.required = required;
  if (allForbidAdditional && objectVariants.length > 0) merged.additionalProperties = false;
  if (typeof schema.description === "string") merged.description = schema.description;
  return merged;
}

/** Rewrite `tools` in an OpenAI/Anthropic-style payload. Returns null when nothing changed. */
export function flattenToolsPayload(payload: unknown): Schema | null {
  if (!isPlainObject(payload) || !Array.isArray(payload.tools)) return null;
  let changed = false;
  const tools = payload.tools.map((tool: any) => {
    if (!isPlainObject(tool)) return tool;
    const holder = isPlainObject(tool.function) ? tool.function : tool;
    const key = "parameters" in holder ? "parameters" : "input_schema" in holder ? "input_schema" : null;
    if (!key) return tool;
    const flat = flattenUnionParameters(holder[key]);
    if (!flat) return tool;
    changed = true;
    return { ...tool, function: tool.function ? { ...tool.function, [key]: flat } : { ...holder, [key]: flat } };
  });
  return changed ? { ...payload, tools } : null;
}

export default function (pi: ExtensionAPI): void {
  pi.on("before_provider_request", (event) => {
    const payload = event.payload as Schema;
    // Only codebuddy models behind 9router are known to reject union schemas.
    if (typeof payload?.model !== "string" || !payload.model.startsWith("cbcn/")) return;
    return flattenToolsPayload(payload) ?? undefined;
  });
}
