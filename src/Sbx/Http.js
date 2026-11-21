import { async } from '../Bsdkrun.Internal/foreign.js';
export const requestImpl = base => headers => spec => timeout => async(async signal => {
  const response = await fetch(base + spec.path, {
    method: spec.method, headers: { 'Content-Type': 'application/json', ...headers },
    ...(spec.body ? { body: spec.body } : {}), redirect: 'manual',
    signal: AbortSignal.any([signal, AbortSignal.timeout(timeout)]),
  });
  return { status: response.status, body: await response.text() };
});
