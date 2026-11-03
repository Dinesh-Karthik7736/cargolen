import assert from 'node:assert/strict';
import test from 'node:test';
import { extractionErrorMessage } from '../src/lib/edge-function-errors.js';

const functionError = (status, message) => ({
  context: new Response(JSON.stringify({ error: message }), { status, headers: { 'Content-Type': 'application/json' } }),
});

test('explains an undeployed extraction function', async () => {
  assert.match(await extractionErrorMessage(functionError(404, 'not found')), /not deployed/i);
});

test('shows the safe missing-secret response from the function', async () => {
  assert.match(await extractionErrorMessage(functionError(503, 'Add LLAMA_CLOUD_API_KEY to Supabase Function secrets.')), /LLAMA_CLOUD_API_KEY/);
});

test('shows model and quota errors returned by the function', async () => {
  assert.match(await extractionErrorMessage(functionError(422, 'AI provider returned 400. Check the model key, quota and model availability.')), /provider returned 400/);
});

test('gives a useful fallback for network failures without an HTTP response', async () => {
  assert.match(await extractionErrorMessage(new Error('Failed to fetch')), /Could not reach/i);
});

