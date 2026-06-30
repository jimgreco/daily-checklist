const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { Pool } = require("pg");

const isProduction = process.env.NODE_ENV === "production";

function emptyDatabase() {
  return { users: {}, identities: {}, sessions: {}, accounts: {} };
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
      this.ready = (async () => {
        await this.pool.query(`
          CREATE TABLE IF NOT EXISTS daily_app_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            data JSONB NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
          );
        `);
        await this.pool.query(
          `INSERT INTO daily_app_state (id, data)
           VALUES (1, $1::jsonb)
           ON CONFLICT (id) DO NOTHING`,
          [JSON.stringify(emptyDatabase())]
        );
      })();
    }
    return this.ready;
  }

  async read() {
    await this.init();
    const result = await this.pool.query("SELECT data FROM daily_app_state WHERE id = 1");
    return cloneDatabase(result.rows[0]?.data);
  }

  async update(operation) {
    await this.init();
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await client.query("SELECT data FROM daily_app_state WHERE id = 1 FOR UPDATE");
      const database = cloneDatabase(result.rows[0]?.data);
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
    await this.pool.query("SELECT 1");
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
