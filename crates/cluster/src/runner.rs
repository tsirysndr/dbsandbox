use crate::{
    branch::{self, Branch, Phase},
    Node, State,
};
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    future::Future,
    path::PathBuf,
    process::Stdio,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};
use tokio::{
    fs::File,
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    Inventory { database: String, branch: String },
    Start { database: String, branch: String },
    Stop { database: String, branch: String },
    Fork { database: String, branch: String },
    Delete { database: String, branch: String },
}
impl Operation {
    pub fn target(&self) -> (&str, &str) {
        match self {
            Self::Inventory { database, branch }
            | Self::Start { database, branch }
            | Self::Stop { database, branch }
            | Self::Fork { database, branch }
            | Self::Delete { database, branch } => (database, branch),
        }
    }
    pub fn validate(&self) -> Result<()> {
        let (database, branch) = self.target();
        validate(database, branch)
    }
}
pub(crate) fn validate(database: &str, branch: &str) -> Result<()> {
    ensure!(
        DATABASES.contains(&database),
        "unknown database; use its canonical dbsandbox name"
    );
    ensure!(
        !branch.is_empty()
            && branch.len() <= 64
            && !branch.starts_with(['-', '.'])
            && branch
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)),
        "invalid branch"
    );
    Ok(())
}
const DATABASES: &[&str] = &[
    "postgres",
    "mariadb",
    "duckdb",
    "sqlite",
    "mysql",
    "typesense",
    "chroma",
    "databend",
    "tigerbeetle",
    "yugabytedb",
    "vearch",
    "timescale",
    "tidb",
    "spicedb",
    "surrealdb",
    "scylladb",
    "qdrant",
    "mongodb",
    "cassandra",
    "clickhouse",
    "arangodb",
    "cockroachdb",
];

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct SnapshotInfo {
    pub id: Uuid,
    pub bytes: u64,
    pub sha256: String,
    pub state: Value,
}
pub(crate) struct Snapshot {
    pub info: SnapshotInfo,
    pub path: PathBuf,
    pub created: Instant,
}

pub(crate) async fn check(state: &State, database: &str, name: &str) -> Result<Branch> {
    ensure!(state.ready.load(Ordering::SeqCst), "node is not ready");
    let members: Vec<Node> = state.store.members().await?;
    ensure!(members.contains(&state.node), "node membership expired");
    let branch: Branch = state
        .store
        .get(&branch::key(database, name))
        .await?
        .context("branch not found")?;
    ensure!(
        branch.owner == state.node.id,
        "branch belongs to another node"
    );
    Ok(branch)
}

pub(crate) async fn cancellable<T>(
    state: &State,
    work: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::pin!(work);
    let deadline = tokio::time::sleep(Duration::from_secs(3600));
    tokio::pin!(deadline);
    let mut check = tokio::time::interval(Duration::from_millis(250));
    loop {
        tokio::select! {
            result=&mut work=>return result,
            _=&mut deadline=>bail!("operation timed out; inspect branch state before retrying"),
            _=check.tick()=>ensure!(state.ready.load(Ordering::SeqCst), "membership lost during operation; inspect branch state before retrying"),
        }
    }
}

async fn command(state: &State, payload: Value) -> Result<Value> {
    let mut child = Command::new(&state.config.executable)
        .args(&state.config.executable_args)
        .args(["__cluster-worker", &payload.to_string()])
        .env_remove("DBSANDBOX_TUI")
        .env("NO_COLOR", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let work = async {
        let (status, out, err) =
            tokio::try_join!(child.wait(), read_bounded(stdout), read_bounded(stderr))?;
        ensure!(
            status.success(),
            "branch command failed ({}): {}",
            status,
            String::from_utf8_lossy(&err)
        );
        serde_json::from_slice(&out).context("invalid worker response")
    };
    cancellable(state, work).await
}
async fn read_bounded(reader: impl tokio::io::AsyncRead + Unpin) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(std::io::Error::other("command output exceeds 4 MiB"));
    }
    Ok(bytes)
}

pub(crate) async fn prepare_snapshot(
    state: &State,
    database: &str,
    name: &str,
) -> Result<SnapshotInfo> {
    let _guard = state.execution.lock().await;
    let branch = check(state, database, name).await?;
    ensure!(branch.phase == Phase::Ready, "source branch is not ready");
    cleanup_snapshots(state).await;
    let id = Uuid::new_v4();
    let path = state.snapshot_dir.path().join(id.to_string());
    let result = command(
        state,
        json!({"action":"export","record":branch,"path":path}),
    )
    .await;
    let value = match result {
        Ok(value) => value,
        Err(error) => {
            let _ = tokio::fs::remove_file(&path).await;
            return Err(error);
        }
    };
    let info = SnapshotInfo {
        id,
        bytes: tokio::fs::metadata(&path).await?.len(),
        sha256: value["sha256"]
            .as_str()
            .context("missing snapshot checksum")?
            .into(),
        state: value["state"].clone(),
    };
    state.snapshots.lock().await.insert(
        id,
        Snapshot {
            info: info.clone(),
            path,
            created: Instant::now(),
        },
    );
    Ok(info)
}
pub(crate) async fn cleanup_snapshots(state: &State) {
    let mut snapshots = state.snapshots.lock().await;
    let expired = snapshots
        .iter()
        .filter(|(_, s)| s.created.elapsed() > Duration::from_secs(3600))
        .map(|(id, _)| *id)
        .collect::<Vec<_>>();
    for id in expired {
        if let Some(snapshot) = snapshots.remove(&id) {
            let _ = tokio::fs::remove_file(snapshot.path).await;
        }
    }
}
pub(crate) async fn release_snapshot(state: &State, id: Uuid) {
    if let Some(snapshot) = state.snapshots.lock().await.remove(&id) {
        let _ = tokio::fs::remove_file(snapshot.path).await;
    }
}

pub(crate) async fn execute(state: &State, operation: &Operation) -> Result<Value> {
    operation.validate()?;
    let (database, name) = operation.target();
    let first = check(state, database, name).await?;
    let lock = {
        let mut operations = state.operations.lock().await;
        operations.retain(|_, lock| lock.strong_count() > 0);
        let lock = operations
            .get(&first.id)
            .and_then(|lock| lock.upgrade())
            .unwrap_or_default();
        operations.insert(first.id, std::sync::Arc::downgrade(&lock));
        lock
    };
    let _operation_guard = lock.lock().await;
    let record = check(state, database, name).await?;
    ensure!(record.id == first.id, "branch was replaced");
    if matches!(operation, Operation::Fork { .. }) {
        let result = fork(state, &record).await;
        if result.is_err() && record.phase != Phase::Deleting {
            let _ = branch::transition(
                state,
                &record,
                Phase::Failed,
                Some("branch creation failed; inspect the owning node".into()),
            )
            .await;
        }
        return result;
    }
    let _guard = state.execution.lock().await;
    let record = check(state, database, name).await?;
    match operation {
        Operation::Inventory { .. } => {
            command(state, json!({"action":"inventory","record":record})).await
        }
        Operation::Start { .. } => {
            ensure!(record.phase != Phase::Deleting, "branch is being deleted");
            ensure!(
                record.parent.is_none() || record.phase == Phase::Ready,
                "fork not ready; retry its creation first"
            );
            let result = command(state, json!({"action":"start","record":record})).await;
            match result {
                Ok(value) => {
                    branch::transition(state, &record, Phase::Ready, None).await?;
                    Ok(value)
                }
                Err(error) => {
                    if record.phase != Phase::Ready {
                        let _ = branch::transition(
                            state,
                            &record,
                            Phase::Failed,
                            Some("branch operation failed; inspect the owning node".into()),
                        )
                        .await;
                    }
                    Err(error)
                }
            }
        }
        Operation::Stop { .. } => {
            ensure!(record.phase == Phase::Ready, "branch is not ready");
            command(state, json!({"action":"stop","record":record})).await
        }
        Operation::Delete { .. } => {
            ensure!(record.name != "main", "main cannot be deleted");
            let record = branch::transition(state, &record, Phase::Deleting, None).await?;
            let result = command(state, json!({"action":"delete","record":record})).await;
            match result {
                Ok(value) => {
                    let (current, revision) = state
                        .store
                        .versioned::<Branch>(&record.key())
                        .await?
                        .context("branch disappeared")?;
                    ensure!(
                        current.id == record.id && current.phase == Phase::Deleting,
                        "branch state changed"
                    );
                    ensure!(
                        state.store.remove(&record.key(), &revision).await?,
                        "branch state changed"
                    );
                    Ok(value)
                }
                Err(error) => {
                    let _ = branch::transition(
                        state,
                        &record,
                        Phase::Failed,
                        Some("branch operation failed; inspect the owning node".into()),
                    )
                    .await;
                    Err(error)
                }
            }
        }
        Operation::Fork { .. } => unreachable!(),
    }
}
async fn fork(state: &State, record: &Branch) -> Result<Value> {
    ensure!(record.phase != Phase::Deleting, "branch is being deleted");
    if record.phase == Phase::Ready {
        return Ok(json!({"ok":true,"branch":record.name}));
    }
    let parent = record.parent.as_ref().context("fork source missing")?;
    let source: Branch = state
        .store
        .get(&branch::key(&record.database, parent))
        .await?
        .context("source branch missing")?;
    ensure!(
        Some(source.id) == record.parent_id,
        "source branch was replaced"
    );
    ensure!(source.phase == Phase::Ready, "source branch is not ready");
    let members: Vec<Node> = state.store.members().await?;
    let source_node = members
        .iter()
        .find(|n| n.id == source.owner)
        .context("source owner is offline")?;
    // Never hold the destination execution lock while asking a local source to export.
    let info: SnapshotInfo = if source_node == &state.node {
        prepare_snapshot(state, &source.database, &source.name).await?
    } else {
        state
            .client
            .post(format!("{}/internal/snapshots", source_node.url))
            .bearer_auth(&state.config.token)
            .json(&json!({"database":source.database,"branch":source.name}))
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?
    };
    let work = async {
        let download = tokio::fs::File::create(
            state
                .snapshot_dir
                .path()
                .join(format!("import-{}", record.id)),
        )
        .await?;
        let import_path = state
            .snapshot_dir
            .path()
            .join(format!("import-{}", record.id));
        let mut file = download;
        let mut hash = Sha256::new();
        let mut size = 0u64;
        if source_node == &state.node {
            let path = state
                .snapshots
                .lock()
                .await
                .get(&info.id)
                .context("snapshot expired")?
                .path
                .clone();
            let mut source = File::open(path).await?;
            let mut buffer = vec![0; 65536];
            loop {
                let read = source.read(&mut buffer).await?;
                if read == 0 {
                    break;
                }
                file.write_all(&buffer[..read]).await?;
                hash.update(&buffer[..read]);
                size += read as u64;
            }
        } else {
            let mut response = state
                .client
                .get(format!(
                    "{}/internal/snapshots/{}",
                    source_node.url, info.id
                ))
                .bearer_auth(&state.config.token)
                .send()
                .await?
                .error_for_status()?;
            while let Some(chunk) = response.chunk().await? {
                size += chunk.len() as u64;
                ensure!(size <= info.bytes, "snapshot exceeds declared size");
                file.write_all(&chunk).await?;
                hash.update(&chunk);
            }
        }
        file.flush().await?;
        drop(file);
        ensure!(
            size == info.bytes && format!("{:x}", hash.finalize()) == info.sha256,
            "snapshot checksum or size mismatch"
        );
        let _guard = state.execution.lock().await;
        let current = check(state, &record.database, &record.name).await?;
        ensure!(
            current.id == record.id && current.phase != Phase::Deleting,
            "branch changed during transfer"
        );
        let result = command(
            state,
            json!({"action":"import","record":record,"path":import_path,"state":info.state}),
        )
        .await?;
        branch::transition(state, record, Phase::Ready, None).await?;
        Ok(result)
    };
    let result = cancellable(state, work).await;
    let _ = tokio::fs::remove_file(
        state
            .snapshot_dir
            .path()
            .join(format!("import-{}", record.id)),
    )
    .await;
    if source_node == &state.node {
        release_snapshot(state, info.id).await;
    } else {
        let _ = state
            .client
            .delete(format!(
                "{}/internal/snapshots/{}",
                source_node.url, info.id
            ))
            .bearer_auth(&state.config.token)
            .timeout(Duration::from_secs(5))
            .send()
            .await;
    }
    if result.is_err() {
        let _ = branch::transition(
            state,
            record,
            Phase::Failed,
            Some("branch operation failed; inspect the owning node".into()),
        )
        .await;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_branch_identity() {
        assert!(validate("postgres", "feature.one").is_ok());
        assert!(validate("--help", "feature").is_err());
        assert!(validate("postgres", "--all").is_err());
        assert!(validate("postgres", "../parent").is_err());
    }
}
