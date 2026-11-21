import { async } from '../Bsdkrun.Internal/foreign.js';

export const queryImpl = spec => async(signal => new Promise((resolve, reject) => {
  let close = () => {};
  const cancel = () => { close(); reject(Error('Database query interrupted')); };
  const timer = setTimeout(() => { close(); reject(Error('Database query timed out')); }, 45000);
  signal.addEventListener('abort', cancel, { once: true });
  (async () => {
    if (spec.driver === 'pg') {
    const { Client } = await import('pg');
    const client = new Client({ connectionString: spec.url, connectionTimeoutMillis: 10000, query_timeout: 30000 });
    close = () => client.end();
    try { await client.connect(); const result = await client.query(spec.sql); return result.rows.map(row => Object.values(row).map(String)); }
    finally { await client.end(); }
    } else if (spec.driver === 'mysql2') {
    const { createConnection } = await import('mysql2/promise');
    const client = await createConnection(spec.url);
    close = () => client.destroy();
    try { const [rows] = await client.query({ sql: spec.sql, timeout: 30000 }); return Array.isArray(rows) ? rows.map(row => Object.values(row).map(String)) : []; }
    finally { await client.end(); }
    } else if (spec.driver === '@libsql/client') {
    const { createClient } = await import('@libsql/client');
    const client = createClient({ url: spec.url });
    close = () => client.close();
    try { const result = await client.execute(spec.sql); return result.rows.map(row => Array.from(row, String)); }
    finally { client.close(); }
    } else throw Error('Unsupported database driver');
  })().then(resolve, reject).finally(() => { clearTimeout(timer); signal.removeEventListener('abort', cancel); });
}));
