export interface Config {
  /** Stable identity of the host holding the local database datasets. */
  node_id: string;
  listen: string;
  /** Origin reachable by all other nodes, e.g. http://10.0.0.2:8788. */
  advertise: string;
  backend: 'consul' | 'etcd';
  endpoint: string;
  namespace: string;
  /** Shared cluster bearer token, at least 32 characters. */
  token: string;
  /** Separate bearer token for remote database and branch API requests. */
  api_token: string;
  /** Consul ACL token or etcd gateway authentication token. */
  store_token?: string;
  join?: string;
  /** dbsandbox executable, or Node/Bun with the CLI path in executable_args. */
  executable: string;
  executable_args?: string[];
}
export interface Running {
  address: string;
  /** Resolves on shutdown; rejects if membership or the API fails. */
  closed: Promise<void>;
  /** Idempotent; waits for shutdown and membership removal. */
  stop(): Promise<void>;
}
export function start(config: Config): Promise<Running>;
