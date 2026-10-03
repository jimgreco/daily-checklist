const { PostgresStore, emptyDatabase } = require('./database');
const { migrateSchema } = require('./schema-contract');
async function initialize(client) {
  await client.query(`CREATE TABLE daily_app_state (
    id INTEGER PRIMARY KEY CHECK (id = 1), data JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`);
  await client.query('INSERT INTO daily_app_state (id, data) VALUES (1, $1::jsonb)', [JSON.stringify(emptyDatabase())]);
}
async function main() {
  if (!process.env.MIGRATION_DATABASE_URL) throw new Error('MIGRATION_DATABASE_URL is required.');
  const args = process.argv.slice(2);
  if (args.some(arg => arg !== '--adopt-existing')) throw new Error('Usage: npm run db:migrate -- [--adopt-existing]');
  const store = new PostgresStore(process.env.MIGRATION_DATABASE_URL);
  try {
    await migrateSchema(store.pool, initialize, {
      adoptExisting: args.includes('--adopt-existing'),
      validate: async client => {
        // Never silently seed a lost singleton during existing-schema adoption.
        const result = await client.query("SELECT id FROM daily_app_state WHERE id=1 AND jsonb_typeof(data)='object' FOR UPDATE");
        if (result.rows.length !== 1) throw new Error('Singleton recovery is required before adoption.');
      }
    });
    console.log('Database schema ready.');
  } finally { await store.pool.end(); }
}
if (require.main === module) main().catch(() => {
  console.error('Schema migration failed; verify migration access, schema compatibility and singleton state. No server started.');
  process.exitCode = 1;
});
module.exports = { initialize, main };
