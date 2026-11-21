// Bun provides require in ESM; keeping these literal calls lets bun build
// include the adapter inside standalone executables without node_modules.
export const available = () => typeof Bun !== 'undefined';
export const open = filename => () => {
  if (!available()) throw Error('Database state requires Bun. Run `bun bin/dbsandbox.js` or use the standalone executable.');
  const {Database} = require('bun:sqlite');
  const {drizzle} = require('drizzle-orm/bun-sqlite');
  return drizzle(new Database(filename, {create:true,strict:true}));
};
export const close = db => () => db.$client.close();
