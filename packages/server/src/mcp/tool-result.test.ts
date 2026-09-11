import { describe, expect, it } from 'vitest';
import { errorResult, gameNotFoundResult, jsonResult, textResult } from './tool-result.js';

const PRETTY_JSON_INDENT_SPACES = 2;

describe('mcp/tool-result', () => {
  it('textResult wraps the text in one content block without an error flag', () => {
    expect(textResult('hello')).toEqual({ content: [{ type: 'text', text: 'hello' }] });
  });

  it('jsonResult pretty-prints the value', () => {
    const value = { rooms: [], count: 0 };
    expect(jsonResult(value)).toEqual({
      content: [{ type: 'text', text: JSON.stringify(value, null, PRETTY_JSON_INDENT_SPACES) }],
    });
  });

  it('errorResult flags the block as an error', () => {
    expect(errorResult('boom')).toEqual({ content: [{ type: 'text', text: 'boom' }], isError: true });
  });

  it('gameNotFoundResult names the game in the shared error text', () => {
    expect(gameNotFoundResult('g1')).toEqual(errorResult('Game "g1" not found or not active'));
  });
});
