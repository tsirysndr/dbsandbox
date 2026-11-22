use crate::{
    branch::{self, Branch, Phase},
    runner::{self, Operation, SnapshotInfo},
    Node, State,
};
use anyhow::Context;
use axum::{
    body::Body,
    extract::{Path, Request, State as Extract},
    http::{
        header::{AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE},
        StatusCode,
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use uuid::Uuid;

struct Error(anyhow::Error);
impl From<anyhow::Error> for Error {
    fn from(error: anyhow::Error) -> Self {
        Self(error)
    }
}
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":self.0.to_string()})),
        )
            .into_response()
    }
}
type Result<T> = std::result::Result<Json<T>, Error>;
#[derive(Serialize, Deserialize)]
pub(crate) struct ClusterInfo {
    pub namespace: String,
    pub backend: String,
    pub node: Node,
}

pub(crate) fn router(state: State) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/cluster/join", post(join))
        .route("/v1/databases", get(inventory))
        .route("/v1/databases/{database}/start", post(start))
        .route("/v1/databases/{database}/stop", post(stop))
        .route(
            "/v1/databases/{database}/branches",
            get(branches).post(create),
        )
        .route("/v1/databases/{database}/branches/{name}", delete(remove))
        .route(
            "/v1/databases/{database}/branches/{name}/start",
            post(start_branch),
        )
        .route(
            "/v1/databases/{database}/branches/{name}/stop",
            post(stop_branch),
        )
        .route("/internal/execute", post(internal))
        .route("/internal/snapshots", post(snapshot))
        .route(
            "/internal/snapshots/{id}",
            get(stream_snapshot).delete(release_snapshot),
        )
        .layer(axum::extract::DefaultBodyLimit::max(16384))
        .layer(middleware::from_fn_with_state(state.clone(), authenticate))
        .with_state(state)
}
async fn authenticate(Extract(state): Extract<State>, request: Request, next: Next) -> Response {
    let internal = request.uri().path().starts_with("/internal/")
        || request.uri().path() == "/v1/cluster/join";
    let token = if internal {
        &state.config.token
    } else {
        &state.config.api_token
    };
    let expected = format!("Bearer {token}");
    let supplied = request
        .headers()
        .get(AUTHORIZATION)
        .map(|v| v.as_bytes())
        .unwrap_or_default();
    let difference = supplied
        .iter()
        .zip(expected.bytes())
        .fold(supplied.len() ^ expected.len(), |acc, (a, b)| {
            acc | usize::from(*a ^ b)
        });
    if difference != 0 {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"unauthorized"})),
        )
            .into_response();
    }
    if !state.ready.load(Ordering::SeqCst) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"node is not ready"})),
        )
            .into_response();
    }
    next.run(request).await
}
async fn health(Extract(state): Extract<State>) -> Result<Value> {
    let members: Vec<Node> = state.store.members().await?;
    if !members.contains(&state.node) {
        return Err(anyhow::anyhow!("membership expired").into());
    }
    Ok(Json(json!({"ready":true})))
}
async fn join(
    Extract(state): Extract<State>,
    Json(joining): Json<ClusterInfo>,
) -> Result<ClusterInfo> {
    let members: Vec<Node> = state.store.members().await?;
    if joining.namespace != state.config.namespace || joining.backend != state.config.backend {
        return Err(anyhow::anyhow!("cluster configuration does not match seed").into());
    }
    if !members.contains(&state.node) {
        return Err(anyhow::anyhow!("seed membership expired").into());
    }
    Ok(Json(ClusterInfo {
        namespace: state.config.namespace.clone(),
        backend: state.config.backend.clone(),
        node: state.node.clone(),
    }))
}
async fn internal(
    Extract(state): Extract<State>,
    Json(operation): Json<Operation>,
) -> Result<Value> {
    Ok(Json(runner::execute(&state, &operation).await?))
}
#[derive(Deserialize)]
struct SnapshotRequest {
    database: String,
    branch: String,
}
async fn snapshot(
    Extract(state): Extract<State>,
    Json(request): Json<SnapshotRequest>,
) -> Result<SnapshotInfo> {
    runner::validate(&request.database, &request.branch)?;
    Ok(Json(
        runner::prepare_snapshot(&state, &request.database, &request.branch).await?,
    ))
}
async fn stream_snapshot(
    Extract(state): Extract<State>,
    Path(id): Path<Uuid>,
) -> std::result::Result<Response, Error> {
    let snapshots = state.snapshots.lock().await;
    let snapshot = snapshots.get(&id).context("snapshot expired")?;
    let file = tokio::fs::File::open(&snapshot.path)
        .await
        .map_err(anyhow::Error::from)?;
    let bytes = snapshot.info.bytes;
    drop(snapshots);
    let body = Body::from_stream(tokio_util::io::ReaderStream::new(file));
    Ok((
        [
            (CONTENT_TYPE, "application/octet-stream".to_string()),
            (CONTENT_LENGTH, bytes.to_string()),
        ],
        body,
    )
        .into_response())
}
async fn release_snapshot(Extract(state): Extract<State>, Path(id): Path<Uuid>) -> Json<Value> {
    runner::release_snapshot(&state, id).await;
    Json(json!({"ok":true}))
}
async fn dispatch(state: &State, record: &Branch, operation: &Operation) -> anyhow::Result<Value> {
    let members: Vec<Node> = state.store.members().await?;
    let node = members
        .iter()
        .find(|n| n.id == record.owner)
        .context("branch owner is offline; placement and data are preserved")?;
    if node == &state.node {
        return runner::execute(state, operation).await;
    }
    let response = state
        .client
        .post(format!("{}/internal/execute", node.url))
        .bearer_auth(&state.config.token)
        .json(operation)
        .send()
        .await?;
    if !response.status().is_success() {
        let error: Value = response.json().await.unwrap_or_default();
        anyhow::bail!(
            "{}",
            error["error"]
                .as_str()
                .unwrap_or("owner operation failed; inspect branch state before retrying")
        );
    }
    Ok(response.json().await?)
}
async fn route(state: &State, operation: Operation) -> Result<Value> {
    operation.validate()?;
    let (database, name) = operation.target();
    let record = if name == "main" && matches!(operation, Operation::Start { .. }) {
        branch::allocate(state, database, name, None).await?
    } else {
        state
            .store
            .get(&branch::key(database, name))
            .await?
            .context("branch not found")?
    };
    Ok(Json(dispatch(state, &record, &operation).await?))
}
async fn start(Extract(s): Extract<State>, Path(database): Path<String>) -> Result<Value> {
    route(
        &s,
        Operation::Start {
            database,
            branch: "main".into(),
        },
    )
    .await
}
async fn stop(Extract(s): Extract<State>, Path(database): Path<String>) -> Result<Value> {
    route(
        &s,
        Operation::Stop {
            database,
            branch: "main".into(),
        },
    )
    .await
}
async fn start_branch(
    Extract(s): Extract<State>,
    Path((database, branch)): Path<(String, String)>,
) -> Result<Value> {
    route(&s, Operation::Start { database, branch }).await
}
async fn stop_branch(
    Extract(s): Extract<State>,
    Path((database, branch)): Path<(String, String)>,
) -> Result<Value> {
    route(&s, Operation::Stop { database, branch }).await
}
async fn remove(
    Extract(s): Extract<State>,
    Path((database, branch)): Path<(String, String)>,
) -> Result<Value> {
    route(&s, Operation::Delete { database, branch }).await
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    name: String,
    from: String,
}
async fn create(
    Extract(s): Extract<State>,
    Path(database): Path<String>,
    Json(body): Json<Create>,
) -> Result<Value> {
    runner::validate(&database, &body.name)?;
    runner::validate(&database, &body.from)?;
    if body.name == "main" || body.name == body.from {
        return Err(anyhow::anyhow!("choose a new branch name").into());
    }
    let source: Branch = s
        .store
        .get(&branch::key(&database, &body.from))
        .await?
        .context("source branch not found")?;
    if source.phase != Phase::Ready {
        return Err(anyhow::anyhow!("source branch is not ready").into());
    }
    let record = branch::allocate(&s, &database, &body.name, Some(&body.from)).await?;
    if record.parent.as_deref() != Some(&body.from) || record.parent_id != Some(source.id) {
        return Err(anyhow::anyhow!("branch has a different parent").into());
    }
    Ok(Json(
        dispatch(
            &s,
            &record,
            &Operation::Fork {
                database,
                branch: body.name,
            },
        )
        .await?,
    ))
}
async fn inventory_rows(state: &State, database: Option<&str>) -> anyhow::Result<Value> {
    let records: Vec<Branch> = state.store.list("branches/").await?;
    let mut tasks = tokio::task::JoinSet::new();
    for record in records
        .into_iter()
        .filter(|b| database.is_none_or(|d| b.database == d))
    {
        let state = state.clone();
        tasks.spawn(async move {
            let mut row=json!({"database":record.database,"branch":record.name,"parent":record.parent,"phase":record.phase,"status":"UNAVAILABLE","running":false,"error":record.error});
            if record.phase==Phase::Ready {
                match dispatch(&state,&record,&Operation::Inventory{database:record.database.clone(),branch:record.name.clone()}).await {
                    Ok(value)=>if let Some(fields)=value.as_object() {row.as_object_mut().unwrap().extend(fields.clone());},
                    Err(_)=>row["error"]=json!("branch owner is unavailable"),
                }
            }
            row
        });
    }
    let mut rows = Vec::new();
    while let Some(row) = tasks.join_next().await {
        rows.push(row.context("inventory task failed")?);
    }
    rows.sort_by(|a, b| {
        (a["database"].as_str(), a["branch"].as_str())
            .cmp(&(b["database"].as_str(), b["branch"].as_str()))
    });
    Ok(json!(rows))
}
async fn inventory(Extract(s): Extract<State>) -> Result<Value> {
    Ok(Json(inventory_rows(&s, None).await?))
}
async fn branches(Extract(s): Extract<State>, Path(database): Path<String>) -> Result<Value> {
    runner::validate(&database, "main")?;
    Ok(Json(inventory_rows(&s, Some(&database)).await?))
}
