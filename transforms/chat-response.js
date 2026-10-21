/**
 * Promptfoo HTTP transformResponse for Meztli /api/chat.
 *
 * Frontend (api-client sendChatClient) displays `data.result.output` markdown.
 * Promptfoo must unwrap the same field. Live payloads may nest / re-stringify:
 *   { result: { output: "..." } }
 *   { data: "{ \"result\": { \"output\": \"...\" } }", status, headers }
 *   context.response = { data: "<raw body string>", status, statusText, headers, ... }
 *
 * Bug mode we guard against: returning context.response (or JSON.stringify of it)
 * fills the Output column with escaped JSON soup (data/status/modelId/toolsUsed).
 *
 * Always returns a plain string (assistant markdown or a short error summary).
 *
 * @param {unknown} json
 * @param {string} [_text]
 * @param {{ response?: unknown }} [context]
 * @returns {string}
 */
module.exports = function transformChatResponse(json, _text, context) {
  const candidates = [];
  if (json != null) candidates.push(json);
  if (
    context &&
    typeof context.response === 'object' &&
    context.response !== null
  ) {
    candidates.push(context.response);
  }
  if (typeof _text === 'string' && _text.trim()) {
    candidates.push(_text);
  }

  for (const candidate of candidates) {
    const extracted = extractAssistantText(candidate);
    if (extracted != null && extracted !== '') {
      return finalizeOutput(extracted);
    }
  }

  // Last resort: never dump nested JSON soup into the Output column.
  if (typeof json === 'string') {
    const again = extractAssistantText(json);
    if (again != null && again !== '') return finalizeOutput(again);
    // If it's still the axios-like envelope string, refuse to show it raw.
    if (looksLikeHttpEnvelope(json)) return '';
    return json;
  }
  if (typeof _text === 'string') {
    const again = extractAssistantText(_text);
    if (again != null && again !== '') return finalizeOutput(again);
    if (looksLikeHttpEnvelope(_text)) return '';
    return _text;
  }
  return '';
};

/**
 * @param {string} text
 * @returns {string}
 */
function finalizeOutput(text) {
  // If a prior buggy transform stored JSON.stringify(context.response) as output,
  // unwrap one more time when that string is fed back in.
  if (looksLikeHttpEnvelope(text) || looksLikeResultEnvelope(text)) {
    const again = extractAssistantText(text);
    if (again != null && again !== '' && again !== text) return again;
  }
  return text;
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
function looksLikeHttpEnvelope(value) {
  if (typeof value !== 'string') return false;
  const t = value.trim();
  return (
    t.startsWith('{') &&
    t.includes('"data"') &&
    (t.includes('"status"') || t.includes('"statusText"'))
  );
}

/**
 * @param {unknown} value
 * @returns {boolean}
 */
function looksLikeResultEnvelope(value) {
  if (typeof value !== 'string') return false;
  const t = value.trim();
  return t.startsWith('{') && t.includes('"result"') && t.includes('"output"');
}

/**
 * @param {unknown} value
 * @returns {string | null}
 */
function extractAssistantText(value) {
  const root = deepCoerce(value);
  if (root == null) return null;

  const nested = unwrapPayload(root);
  if (!nested) return null;

  if (nested.error != null && !(nested.result && nested.result.output != null)) {
    return formatError(nested);
  }

  const output = nested.result && nested.result.output;
  if (typeof output === 'string') return output;
  if (output != null) {
    try {
      return typeof output === 'object'
        ? JSON.stringify(output)
        : String(output);
    } catch {
      return String(output);
    }
  }

  // Some error bodies sit on the wrapper itself (no result).
  if (root.error != null) return formatError(root);

  return null;
}

/**
 * @param {Record<string, unknown>} body
 * @returns {string}
 */
function formatError(body) {
  const bits = [String(body.error)];
  if (body.code) bits.push(`code=${body.code}`);
  if (body.used != null && body.max != null) {
    bits.push(`used=${body.used}/${body.max}`);
  }
  if (body.planId) bits.push(`planId=${body.planId}`);
  return bits.join(' | ');
}

/**
 * Parse JSON strings repeatedly until we get a non-string value (or give up).
 * @param {unknown} value
 * @param {number} [depth]
 * @returns {unknown}
 */
function deepCoerce(value, depth = 0) {
  if (value == null || depth > 8) return value;
  if (typeof value === 'object') return value;
  if (typeof value !== 'string') return value;

  const trimmed = value.trim();
  if (!trimmed) return value;
  // Only attempt parse on JSON-looking strings
  if (trimmed[0] !== '{' && trimmed[0] !== '[') return value;

  try {
    return deepCoerce(JSON.parse(trimmed), depth + 1);
  } catch {
    return value;
  }
}

/**
 * Walk common wrappers until we find { result: { output } } or an error object.
 * Coerces stringified `data` / `result` / `body` along the way.
 * @param {unknown} body
 * @returns {Record<string, unknown> | null}
 */
function unwrapPayload(body) {
  let cur = deepCoerce(body);
  for (let i = 0; i < 8 && cur && typeof cur === 'object'; i++) {
    const obj = /** @type {Record<string, unknown>} */ (cur);

    // Coerce stringified result in place
    if (typeof obj.result === 'string') {
      obj.result = deepCoerce(obj.result);
    }

    if (
      obj.result &&
      typeof obj.result === 'object' &&
      /** @type {Record<string, unknown>} */ (obj.result).output != null
    ) {
      return obj;
    }
    if (obj.error != null) return obj;

    if (obj.data != null) {
      cur = deepCoerce(obj.data);
      continue;
    }
    if (obj.body != null) {
      cur = deepCoerce(obj.body);
      continue;
    }
    // Promptfoo sometimes nests the HTTP body under response.data
    if (
      obj.response &&
      typeof obj.response === 'object' &&
      /** @type {Record<string, unknown>} */ (obj.response).data != null
    ) {
      cur = deepCoerce(
        /** @type {Record<string, unknown>} */ (obj.response).data
      );
      continue;
    }
    break;
  }
  return cur && typeof cur === 'object'
    ? /** @type {Record<string, unknown>} */ (cur)
    : null;
}
