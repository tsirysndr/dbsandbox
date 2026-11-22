use crate::{Node, State};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Creating,
    Ready,
    Failed,
    Deleting,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Branch {
    pub id: Uuid,
    pub database: String,
    pub name: String,
    pub parent: Option<String>,
    pub parent_id: Option<Uuid>,
    pub owner: String,
    pub phase: Phase,
    pub error: Option<String>,
}
impl Branch {
    pub fn key(&self) -> String {
        key(&self.database, &self.name)
    }
}
pub fn key(database: &str, branch: &str) -> String {
    format!("branches/{database}/{branch}")
}

pub(crate) async fn allocate(
    state: &State,
    database: &str,
    name: &str,
    parent: Option<&str>,
) -> Result<Branch> {
    if let Some(existing) = state.store.get::<Branch>(&key(database, name)).await? {
        ensure!(
            existing.parent.as_deref() == parent,
            "branch exists with another parent"
        );
        return Ok(existing);
    }
    let members: Vec<Node> = state.store.members().await?;
    let branches: Vec<Branch> = state.store.list("branches/").await?;
    let source_owner = parent
        .and_then(|parent| {
            branches
                .iter()
                .find(|b| b.database == database && b.name == parent)
        })
        .map(|b| b.owner.as_str());
    let owner = members
        .iter()
        .min_by_key(|node| {
            (
                branches.iter().filter(|b| b.owner == node.id).count(),
                usize::from(source_owner == Some(node.id.as_str())),
                node.id.clone(),
            )
        })
        .context("no live nodes")?;
    let branch = Branch {
        id: Uuid::new_v4(),
        database: database.into(),
        name: name.into(),
        parent: parent.map(Into::into),
        parent_id: parent
            .and_then(|name| {
                branches
                    .iter()
                    .find(|b| b.database == database && b.name == name)
            })
            .map(|b| b.id),
        owner: owner.id.clone(),
        phase: Phase::Creating,
        error: None,
    };
    state.store.create(&branch.key(), &branch).await?;
    state
        .store
        .get(&branch.key())
        .await?
        .context("placement disappeared")
}
pub(crate) async fn transition(
    state: &State,
    branch: &Branch,
    phase: Phase,
    error: Option<String>,
) -> Result<Branch> {
    let (current, revision) = state
        .store
        .versioned::<Branch>(&branch.key())
        .await?
        .context("branch missing")?;
    ensure!(
        current.id == branch.id && current.owner == state.node.id,
        "branch ownership changed"
    );
    let next = Branch {
        phase,
        error,
        ..current
    };
    ensure!(
        state.store.replace(&next.key(), &revision, &next).await?,
        "branch state changed concurrently"
    );
    Ok(next)
}
