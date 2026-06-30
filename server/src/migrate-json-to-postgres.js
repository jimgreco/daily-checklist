const fs = require("node:fs/promises");
const { PostgresStore, emptyDatabase } = require("./database");

function hasData(database) {
  return Boolean(
    Object.keys(database.users || {}).length
      || Object.keys(database.identities || {}).length
      || Object.keys(database.sessions || {}).length
      || Object.keys(database.accounts || {}).length
  );
}

async function main() {
  const databaseURL = process.env.DATABASE_URL || "";
  const sourceFile = process.env.MIGRATE_JSON_FILE || process.env.DATA_FILE || "";
  if (!databaseURL) throw new Error("DATABASE_URL is required.");
  if (!sourceFile) {
    console.log("No MIGRATE_JSON_FILE provided; skipping JSON migration.");
    return;
  }

  let source;
  try {
    source = { ...emptyDatabase(), ...JSON.parse(await fs.readFile(sourceFile, "utf8")) };
  } catch (error) {
    if (error.code === "ENOENT") {
      console.log(`Migration source not found at ${sourceFile}; skipping.`);
      return;
    }
    throw error;
  }

  if (!hasData(source)) {
    console.log(`Migration source at ${sourceFile} is empty; skipping.`);
    return;
  }

  const store = new PostgresStore(databaseURL);
  await store.update((target) => {
    if (hasData(target)) {
      console.log("Postgres already contains Daily data; skipping JSON migration.");
      return null;
    }
    target.users = source.users || {};
    target.identities = source.identities || {};
    target.sessions = source.sessions || {};
    target.accounts = source.accounts || {};
    console.log(`Migrated Daily JSON data from ${sourceFile} into Postgres.`);
    return null;
  });
  await store.pool.end();
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = {
  hasData
};
