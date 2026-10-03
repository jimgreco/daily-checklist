const test = require('node:test');
const assert = require('node:assert/strict');
const { assertSchemaCompatible, migrateSchema } = require('../src/schema-contract');
const contract = require('../src/schema-contract.json');

test('runtime schema check is read-only and rejects missing versions and drift', async () => {
  const queries = [];
  const queryable = { query: async sql => {
    queries.push(sql);
    return { rows: sql.startsWith('SELECT version') ? [{ version: contract.version }] : contract.objects };
  } };
  await assertSchemaCompatible(queryable);
  assert.ok(queries.every(sql => sql.trim().startsWith('SELECT')));
  await assert.rejects(assertSchemaCompatible({ query: async () => ({ rows: [] }) }), /incompatible/);
  await assert.rejects(assertSchemaCompatible({ query: async sql => ({ rows: sql.startsWith('SELECT version') ? [{}] : contract.objects.slice(1) }) }), /incompatible/);
});

test('adoption refuses drift and rolls back before recording a version or initializing data', async () => {
  const queries = []; let initialized = false; let released = false;
  const client = { query: async sql => {
    queries.push(sql);
    return { rows: sql.includes('count(*)') ? [{ count: 1 }] : [] };
  }, release: () => { released = true; } };
  await assert.rejects(migrateSchema({ connect: async () => client }, async () => { initialized = true; }, { adoptExisting: true }), /incompatible/);
  assert.equal(initialized, false);
  assert.equal(released, true);
  assert.ok(queries.includes('ROLLBACK'));
  assert.ok(!queries.some(sql => /CREATE TABLE|INSERT INTO/.test(sql)));
});
