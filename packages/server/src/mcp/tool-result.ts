import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';

/** Every debug tool answers with one text block, so the helpers below are the only result builders. */
const JSON_INDENT_SPACES = 2;

/** A successful result carrying `text` verbatim. */
export function textResult(text: string): CallToolResult {
  return { content: [{ type: 'text', text }] };
}

/** A successful result carrying `value` pretty-printed as JSON. */
export function jsonResult(value: unknown): CallToolResult {
  return textResult(JSON.stringify(value, null, JSON_INDENT_SPACES));
}

/** A failed result carrying a one-line explanation. */
export function errorResult(text: string): CallToolResult {
  return { ...textResult(text), isError: true };
}

export function gameNotFoundResult(gameId: string): CallToolResult {
  return errorResult(`Game "${gameId}" not found or not active`);
}
