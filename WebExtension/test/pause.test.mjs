import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isPaused, withPaused } from '../src/pause.js';

test('a paused host covers itself and its subdomains', () => {
  const paused = ['example.com'];
  assert.equal(isPaused(paused, 'example.com'), true);
  assert.equal(isPaused(paused, 'www.example.com'), true);
  assert.equal(isPaused(paused, 'notexample.com'), false);
  assert.equal(isPaused(paused, 'com'), false);
  assert.equal(isPaused(paused, ''), false);
  assert.equal(isPaused(new Set(paused), 'a.example.com'), true);
});

test('withPaused adds and removes hosts', () => {
  assert.deepEqual(withPaused([], 'News.Example.com.', true), ['news.example.com']);
  assert.deepEqual(withPaused(['news.example.com', 'other.org'], 'news.example.com', true), ['news.example.com', 'other.org']);
  // Resuming a subdomain also removes the parent entry that paused it.
  assert.deepEqual(withPaused(['example.com', 'other.org'], 'www.example.com', false), ['other.org']);
});
