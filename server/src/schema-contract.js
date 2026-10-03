// This manifest describes structure only; no application rows are read.
const contract = require('./schema-contract.json');
const catalogSQL = require('node:fs').readFileSync(require('node:path').join(__dirname, 'schema-catalog.sql'), 'utf8');

async function assertSchemaCompatible(queryable, { requireVersion = true } = {}) {
  try {
    if (requireVersion) {
      const result = await queryable.query(
        'SELECT version FROM public.app_schema_versions WHERE app = $1 AND version = $2',
        [contract.app, contract.version]);
      if (result.rows.length !== 1) throw new Error('missing compatibility version');
    }
    const actual = new Map((await queryable.query(catalogSQL)).rows.map(row => [row.kind + ':' + row.name, row.definition]));
    const missing = contract.objects.filter(row => ![row, ...(row.alternatives || [])]
      .some(candidate => actual.get(row.kind + ':' + candidate.name) === candidate.definition));
    if (missing.length) throw new Error('schema structure mismatch');
  } catch {
    throw new Error('Database schema is incompatible. Run the reviewed migration/adoption command before starting this release.');
  }
}

async function migrateSchema(pool, initialize, { adoptExisting = false, validate = async () => {} } = {}) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout = '10s'");
    await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [contract.app + ':schema']);
    const { rows } = await client.query("SELECT count(*)::int AS count FROM pg_tables WHERE schemaname='public'");
    if (rows[0].count) {
      if (!adoptExisting) {
        // An already adopted, compatible database is a read-only no-op.
        await assertSchemaCompatible(client);
        await validate(client);
        await client.query('COMMIT');
        return;
      }
      await assertSchemaCompatible(client, { requireVersion: false });
    } else {
      if (adoptExisting) throw new Error('Cannot adopt an empty database');
      await initialize(client);
      await assertSchemaCompatible(client, { requireVersion: false });
    }
    await validate(client);
    await client.query(`CREATE TABLE IF NOT EXISTS public.app_schema_versions (
      app TEXT NOT NULL, version INTEGER NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (app, version))`);
    await client.query('INSERT INTO public.app_schema_versions (app, version) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [contract.app, contract.version]);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}
module.exports = { assertSchemaCompatible, migrateSchema, catalogSQL };
