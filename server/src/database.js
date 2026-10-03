const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { Pool } = require("pg");

const isProduction = process.env.NODE_ENV === "production";

function emptyDatabase() {
  return { users: {}, identities: {}, sessions: {}, accounts: {}, auditEvents: [] };
}

function cloneDatabase(database) {
  return { ...emptyDatabase(), ...JSON.parse(JSON.stringify(database || {})) };
}

class JSONFileStore {
  constructor(file) {
    this.file = file;
    this.writeQueue = Promise.resolve();
  }

  async read() {
    try {
      return { ...emptyDatabase(), ...JSON.parse(await fs.readFile(this.file, "utf8")) };
    } catch (error) {
      if (error.code === "ENOENT") return emptyDatabase();
      throw error;
    }
  }

  async update(operation) {
    const result = this.writeQueue.then(async () => {
      const database = await this.read();
      const value = await operation(database);
      await fs.mkdir(path.dirname(this.file), { recursive: true });
      const temporary = `${this.file}.${crypto.randomUUID()}.tmp`;
      await fs.writeFile(temporary, JSON.stringify(database, null, 2));
      await fs.rename(temporary, this.file);
      return value;
    });
    this.writeQueue = result.catch(() => {});
    return result;
  }

  async health() {
    await this.read();
    return { ok: true };
  }
}

class PostgresStore {
  constructor(databaseURL) {
    this.pool = new Pool({
      connectionString: databaseURL,
      ssl: process.env.PGSSL === "true" || process.env.PGSSL === "require"
        ? { rejectUnauthorized: process.env.PGSSL_REJECT_UNAUTHORIZED !== "false" }
        : undefined,
      max: Number(process.env.PG_POOL_MAX || 5)
    });
    this.ready = null;
  }

  async init() {
    if (!this.ready) {
      this.ready = require('./schema-contract').assertSchemaCompatible(this.pool)
        .then(async () => {
          const result = await this.pool.query("SELECT id FROM daily_app_state WHERE id = 1 AND jsonb_typeof(data) = 'object'");
          if (result.rows.length !== 1) throw new Error('Database singleton state is missing or invalid; owner recovery is required.');
        });
    }
    return this.ready;
  }

  async read() {
    await this.init();
    const result = await this.pool.query("SELECT data FROM daily_app_state WHERE id = 1");
    if (!result.rows[0]) throw new Error('Database singleton state is missing; owner recovery is required.');
    return cloneDatabase(result.rows[0].data);
  }

  async update(operation) {
    await this.init();
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query("SELECT data FROM daily_app_state WHERE id = 1 FOR UPDATE");
      if (!result.rows[0]) throw new Error('Database singleton state is missing; owner recovery is required.');
      const database = cloneDatabase(result.rows[0].data);
      const value = await operation(database);
      await client.query(
        "UPDATE daily_app_state SET data = $1::jsonb, updated_at = NOW() WHERE id = 1",
        [JSON.stringify(database)]
      );
      await client.query("COMMIT");
      return value;
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async health() {
    await this.init();
    await this.read();
    return { ok: true };
  }
}

function createStore() {
  const databaseURL = process.env.DATABASE_URL || "";
  if (databaseURL) return new PostgresStore(databaseURL);
  if (isProduction) throw new Error("DATABASE_URL is required in production.");
  return new JSONFileStore(process.env.DATA_FILE || path.join(__dirname, "..", "data", "database.json"));
}

module.exports = {
  createStore,
  emptyDatabase,
  PostgresStore
};
