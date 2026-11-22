mod api;
mod branch;
mod runner;
mod store;

use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    net::SocketAddr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use store::Store;
use tokio::{
    net::TcpListener,
    sync::{watch, Mutex},
};
use uuid::Uuid;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub node_id: String,
    pub listen: SocketAddr,
    pub advertise: String,
    pub backend: String,
    pub endpoint: String,
    pub namespace: String,
    pub token: String,
    pub api_token: String,
    pub store_token: Option<String>,
    pub join: Option<String>,
    pub executable: String,
    #[serde(default)]
    pub executable_args: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Node {
    pub id: String,
    pub url: String,
    pub incarnation: Uuid,
}

#[derive(Clone)]
pub(crate) struct State {
    config: Config,
    store: Store,
    node: Node,
    client: reqwest::Client,
    ready: Arc<AtomicBool>,
    execution: Arc<Mutex<()>>,
    operations: Arc<Mutex<std::collections::HashMap<Uuid, std::sync::Weak<Mutex<()>>>>>,
    snapshots: Arc<Mutex<std::collections::HashMap<Uuid, runner::Snapshot>>>,
    snapshot_dir: Arc<tempfile::TempDir>,
}

#[derive(Clone)]
pub struct Running {
    pub address: SocketAddr,
    shutdown: watch::Sender<bool>,
    result: watch::Receiver<Option<std::result::Result<(), String>>>,
}
impl Running {
    pub async fn wait(mut self) -> Result<()> {
        loop {
            if let Some(result) = self.result.borrow().clone() {
                return result.map_err(anyhow::Error::msg);
            }
            self.result.changed().await.context("cluster task closed")?;
        }
    }
    pub async fn stop(self) -> Result<()> {
        let _ = self.shutdown.send(true);
        self.wait().await
    }
}

pub fn valid_segment(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn valid_url(value: &str) -> Result<()> {
    let url = reqwest::Url::parse(value)?;
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "expected an http(s) origin URL"
    );
    Ok(())
}

pub async fn start(config: Config) -> Result<Running> {
    ensure!(
        valid_segment(&config.node_id) && valid_segment(&config.namespace),
        "invalid node ID or namespace"
    );
    ensure!(
        config.token.len() >= 32 && !config.token.contains(['\r', '\n']),
        "cluster token must contain at least 32 characters and no newlines"
    );
    ensure!(
        config.api_token.len() >= 32 && !config.api_token.contains(['\r', '\n']),
        "API token must contain at least 32 characters and no newlines"
    );
    ensure!(!config.executable.is_empty(), "executable is required");
    valid_url(&config.advertise)?;
    valid_url(&config.endpoint)?;
    if let Some(join) = &config.join {
        valid_url(join)?;
    }
    let store = Store::new(
        &config.backend,
        &config.endpoint,
        &config.namespace,
        config.store_token.clone(),
    )?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3660))
        .connect_timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let node = Node {
        id: config.node_id.clone(),
        url: config.advertise.trim_end_matches('/').into(),
        incarnation: Uuid::new_v4(),
    };
    let listener = TcpListener::bind(config.listen).await?;
    let address = listener.local_addr()?;
    // Validate the seed before publishing membership, so a failed join can never
    // receive a durable database placement.
    if let Some(join) = &config.join {
        let peer: api::ClusterInfo = client
            .post(format!("{}/v1/cluster/join", join.trim_end_matches('/')))
            .bearer_auth(&config.token)
            .json(&api::ClusterInfo {
                namespace: config.namespace.clone(),
                backend: config.backend.clone(),
                node: node.clone(),
            })
            .timeout(Duration::from_secs(10))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        ensure!(
            peer.namespace == config.namespace && peer.backend == config.backend,
            "cluster configuration does not match seed"
        );
        let members: Vec<Node> = store.members().await?;
        ensure!(
            members.contains(&peer.node),
            "seed uses a different state store"
        );
    }
    let session = store.session().await?;
    if let Err(error) = store.register(&node.id, &session, &node).await {
        let _ = store.destroy(&session).await;
        return Err(error);
    }
    let ready = Arc::new(AtomicBool::new(true));
    let state = State {
        config,
        store: store.clone(),
        node,
        client,
        ready: ready.clone(),
        execution: Arc::new(Mutex::new(())),
        operations: Arc::new(Mutex::new(std::collections::HashMap::new())),
        snapshots: Arc::new(Mutex::new(std::collections::HashMap::new())),
        snapshot_dir: Arc::new(tempfile::tempdir()?),
    };
    let state_for_cleanup = state.clone();
    let app = api::router(state);
    let (shutdown, mut receiver) = watch::channel(false);
    let mut server_shutdown = receiver.clone();
    let server_signal = shutdown.clone();
    let (result_sender, result) = watch::channel(None);
    tokio::spawn(async move {
        let mut server = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = server_shutdown.changed().await;
                })
                .await
        });
        let mut heartbeat = tokio::time::interval(Duration::from_secs(4));
        let mut finished = false;
        let outcome: Result<()> = loop {
            tokio::select! {
                result = &mut server => {
                    finished = true;
                    break match result {
                        Ok(result) => result.map_err(Into::into),
                        Err(error) => Err(error.into()),
                    };
                },
                _ = receiver.changed() => break Ok(()),
                _ = heartbeat.tick() => {
                    runner::cleanup_snapshots(&state_for_cleanup).await;
                    if let Err(error) = store.renew(&session).await {
                        break Err(error.context("membership lost; node stopped"));
                    }
                }
            }
        };
        ready.store(false, Ordering::SeqCst);
        let _ = server_signal.send(true);
        if !finished
            && tokio::time::timeout(Duration::from_secs(3), &mut server)
                .await
                .is_err()
        {
            server.abort();
            let _ = server.await;
        }
        let cleanup = store.destroy(&session).await;
        let outcome = outcome.and(cleanup).map_err(|error| error.to_string());
        let _ = result_sender.send(Some(outcome));
    });
    Ok(Running {
        address,
        shutdown,
        result,
    })
}
