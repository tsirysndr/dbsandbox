import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
const encode = (value) => Buffer.from(value).toString('base64');
const decode = (value) => Buffer.from(value, 'base64').toString();
export async function storeFixture(backend) {
  const entries = new Map(),
    sessions = new Set();
  let revision = 1,
    failRenew = false;
  const put = (key, value, session) =>
    entries.set(key, { value, session, index: revision++ });
  const revoke = (id) => {
    sessions.delete(id);
    for (const [key, entry] of entries)
      if (entry.session === id) entries.delete(key);
  };
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let body = '';
    for await (const chunk of req) body += chunk;
    const send = (value, status = 200) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(value));
    };
    if (backend === 'consul') {
      if (url.pathname === '/v1/session/create') {
        const ID = randomUUID();
        sessions.add(ID);
        return send({ ID });
      }
      if (url.pathname.startsWith('/v1/session/renew/'))
        return send(failRenew ? {} : [{}], failRenew ? 500 : 200);
      if (url.pathname.startsWith('/v1/session/destroy/')) {
        revoke(url.pathname.split('/').at(-1));
        return send(true);
      }
      const key = url.pathname.replace('/v1/kv/', ''),
        current = entries.get(key);
      const cas = url.searchParams.get('cas');
      if (req.method === 'PUT') {
        const session = url.searchParams.get('acquire');
        if (
          cas !== null &&
          (cas === '0' ? !!current : String(current?.index) !== cas)
        )
          return send(false);
        if (session && (!sessions.has(session) || current?.session))
          return send(false);
        put(key, JSON.parse(body), session);
        return send(true);
      }
      if (req.method === 'DELETE') {
        if (!current || String(current.index) !== cas) return send(false);
        entries.delete(key);
        return send(true);
      }
      const matches = url.searchParams.has('recurse')
        ? [...entries].filter(([name]) => name.startsWith(key))
        : current
          ? [[key, current]]
          : [];
      if (!matches.length) return send({}, 404);
      if (url.searchParams.has('raw')) return send(current.value);
      return send(
        matches.map(([, entry]) => ({
          Value: encode(JSON.stringify(entry.value)),
          Session: entry.session,
          ModifyIndex: entry.index,
        })),
      );
    }
    const input = JSON.parse(body);
    if (url.pathname === '/v3/lease/grant') {
      const ID = String(revision++);
      sessions.add(ID);
      return send({ ID, TTL: '15' });
    }
    if (url.pathname === '/v3/lease/keepalive')
      return send({ result: { ID: input.ID, TTL: failRenew ? '0' : '15' } });
    if (url.pathname === '/v3/lease/revoke') {
      revoke(input.ID);
      return send({});
    }
    if (url.pathname === '/v3/kv/txn') {
      const comparison = input.compare[0],
        key = decode(comparison.key),
        current = entries.get(key);
      if (
        comparison.target === 'VERSION'
          ? !!current
          : String(current?.index) !== comparison.mod_revision
      )
        return send({ succeeded: false });
      const operation = input.success[0];
      if (operation.request_put) {
        const item = operation.request_put;
        put(decode(item.key), JSON.parse(decode(item.value)), item.lease);
      } else if (operation.request_delete_range)
        entries.delete(decode(operation.request_delete_range.key));
      return send({ succeeded: true });
    }
    if (url.pathname === '/v3/kv/range') {
      const key = decode(input.key),
        values = [...entries].filter(([name]) =>
          input.range_end
            ? name >= key && name < decode(input.range_end)
            : name === key,
        );
      return send({
        kvs: values.map(([key, entry]) => ({
          key: encode(key),
          value: encode(JSON.stringify(entry.value)),
          mod_revision: String(entry.index),
        })),
      });
    }
    send({}, 404);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    endpoint: `http://127.0.0.1:${server.address().port}`,
    failRenew() {
      failRenew = true;
    },
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(resolve);
      }),
  };
}
