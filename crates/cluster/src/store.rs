use anyhow::{bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use reqwest::{Client, StatusCode};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use std::time::Duration;

#[derive(Clone)]
pub struct Consul {
    client: Client,
    url: String,
    prefix: String,
    token: Option<String>,
}

#[derive(Deserialize)]
struct Entry {
    #[serde(rename = "ModifyIndex")]
    index: u64,
    #[serde(rename = "Value")]
    value: Option<String>,
    #[serde(rename = "Session")]
    session: Option<String>,
}

impl Consul {
    pub fn new(url: &str, prefix: &str, token: Option<String>) -> Result<Self> {
        let parsed = reqwest::Url::parse(url)?;
        anyhow::ensure!(
            matches!(parsed.scheme(), "http" | "https"),
            "invalid Consul URL"
        );
        Ok(Self {
            client: Client::builder()
                .timeout(Duration::from_secs(5))
                .redirect(reqwest::redirect::Policy::none())
                .build()?,
            url: url.trim_end_matches('/').into(),
            prefix: prefix.into(),
            token,
        })
    }
    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let request = self.client.request(method, format!("{}{path}", self.url));
        if let Some(token) = &self.token {
            request.header("X-Consul-Token", token)
        } else {
            request
        }
    }
    fn key(&self, key: &str) -> String {
        format!("/v1/kv/{}/{key}", self.prefix)
    }
    pub async fn session(&self) -> Result<String> {
        let response: Value = self.request(reqwest::Method::PUT, "/v1/session/create")
            .json(&json!({"Name":"dbsandbox", "TTL":"15s", "Behavior":"delete", "LockDelay":"0s", "Checks":[]}))
            .send().await?.error_for_status()?.json().await?;
        Ok(response["ID"]
            .as_str()
            .context("missing session ID")?
            .into())
    }
    pub async fn renew(&self, session: &str) -> Result<()> {
        self.request(
            reqwest::Method::PUT,
            &format!("/v1/session/renew/{session}"),
        )
        .send()
        .await?
        .error_for_status()?;
        Ok(())
    }
    pub async fn destroy(&self, session: &str) -> Result<()> {
        self.request(
            reqwest::Method::PUT,
            &format!("/v1/session/destroy/{session}"),
        )
        .send()
        .await?
        .error_for_status()?;
        Ok(())
    }
    pub async fn put(
        &self,
        key: &str,
        value: &impl serde::Serialize,
        query: &[(&str, &str)],
    ) -> Result<bool> {
        Ok(self
            .request(reqwest::Method::PUT, &self.key(key))
            .query(query)
            .body(serde_json::to_vec(value)?)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }
    pub async fn get<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let response = self
            .request(reqwest::Method::GET, &self.key(key))
            .query(&[("raw", "true"), ("consistent", "true")])
            .send()
            .await?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        Ok(Some(response.error_for_status()?.json().await?))
    }
    pub async fn members<T: DeserializeOwned>(&self) -> Result<Vec<T>> {
        let response = self
            .request(reqwest::Method::GET, &self.key("nodes/"))
            .query(&[("recurse", "true"), ("consistent", "true")])
            .send()
            .await?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        let entries: Vec<Entry> = response.error_for_status()?.json().await?;
        entries
            .into_iter()
            .filter(|e| e.session.as_deref().is_some_and(|s| !s.is_empty()))
            .map(|e| {
                Ok(serde_json::from_slice(
                    &STANDARD.decode(e.value.context("empty member")?)?,
                )?)
            })
            .collect()
    }
    pub async fn register(
        &self,
        id: &str,
        session: &str,
        value: &impl serde::Serialize,
    ) -> Result<()> {
        if !self
            .put(&format!("nodes/{id}"), value, &[("acquire", session)])
            .await?
        {
            bail!("node ID already registered");
        }
        Ok(())
    }
}

#[derive(Clone)]
pub enum Store {
    Consul(Consul),
    Etcd(Etcd),
}

impl Store {
    pub fn new(kind: &str, url: &str, prefix: &str, token: Option<String>) -> Result<Self> {
        match kind {
            "consul" => Ok(Self::Consul(Consul::new(url, prefix, token)?)),
            "etcd" => Ok(Self::Etcd(Etcd {
                transport: Consul::new(url, prefix, token)?,
            })),
            _ => bail!("backend must be consul or etcd"),
        }
    }
    pub async fn session(&self) -> Result<String> {
        match self {
            Self::Consul(s) => s.session().await,
            Self::Etcd(s) => s.session().await,
        }
    }
    pub async fn renew(&self, id: &str) -> Result<()> {
        match self {
            Self::Consul(s) => s.renew(id).await,
            Self::Etcd(s) => s.renew(id).await,
        }
    }
    pub async fn destroy(&self, id: &str) -> Result<()> {
        match self {
            Self::Consul(s) => s.destroy(id).await,
            Self::Etcd(s) => s.destroy(id).await,
        }
    }
    pub async fn get<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        match self {
            Self::Consul(s) => s.get(key).await,
            Self::Etcd(s) => s.get(key).await,
        }
    }
    pub async fn create(&self, key: &str, value: &impl serde::Serialize) -> Result<bool> {
        match self {
            Self::Consul(s) => s.put(key, value, &[("cas", "0")]).await,
            Self::Etcd(s) => s.create(key, value, None).await,
        }
    }
    pub async fn register(
        &self,
        id: &str,
        session: &str,
        value: &impl serde::Serialize,
    ) -> Result<()> {
        match self {
            Self::Consul(s) => s.register(id, session, value).await,
            Self::Etcd(s) => {
                anyhow::ensure!(
                    s.create(&format!("nodes/{id}"), value, Some(session))
                        .await?,
                    "node ID already registered"
                );
                Ok(())
            }
        }
    }
    pub async fn members<T: DeserializeOwned>(&self) -> Result<Vec<T>> {
        match self {
            Self::Consul(s) => s.members().await,
            Self::Etcd(s) => s.members().await,
        }
    }
}

#[derive(Clone)]
pub struct Etcd {
    transport: Consul,
}
impl Etcd {
    fn key(&self, key: &str) -> String {
        STANDARD.encode(format!("{}/{key}", self.transport.prefix))
    }
    fn request(&self, path: &str) -> reqwest::RequestBuilder {
        let request = self
            .transport
            .client
            .post(format!("{}{path}", self.transport.url));
        if let Some(token) = &self.transport.token {
            request.header("Authorization", token)
        } else {
            request
        }
    }
    async fn post(&self, path: &str, body: Value) -> Result<Value> {
        Ok(self
            .request(path)
            .json(&body)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }
    async fn session(&self) -> Result<String> {
        let value = self.post("/v3/lease/grant", json!({"TTL":"15"})).await?;
        Ok(value["ID"].as_str().context("missing lease ID")?.into())
    }
    async fn renew(&self, id: &str) -> Result<()> {
        // The gateway is streaming: consume one acknowledgement, then close it.
        let mut response = self
            .request("/v3/lease/keepalive")
            .json(&json!({"ID":id}))
            .send()
            .await?
            .error_for_status()?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            bytes.extend_from_slice(&chunk);
            if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
                let ttl = value["result"]["TTL"]
                    .as_str()
                    .and_then(|s| s.parse::<i64>().ok())
                    .unwrap_or(0);
                anyhow::ensure!(ttl > 0, "etcd lease expired");
                return Ok(());
            }
            anyhow::ensure!(bytes.len() < 65536, "invalid lease acknowledgement");
        }
        bail!("missing lease acknowledgement")
    }
    async fn destroy(&self, id: &str) -> Result<()> {
        self.post("/v3/lease/revoke", json!({"ID":id})).await?;
        Ok(())
    }
    async fn create(
        &self,
        key: &str,
        value: &impl serde::Serialize,
        lease: Option<&str>,
    ) -> Result<bool> {
        let key = self.key(key);
        let mut put = json!({"key":key, "value":STANDARD.encode(serde_json::to_vec(value)?)});
        if let Some(lease) = lease {
            put["lease"] = json!(lease);
        }
        let response = self
            .post(
                "/v3/kv/txn",
                json!({
                    "compare":[{"key":key,"target":"VERSION","result":"EQUAL","version":"0"}],
                    "success":[{"request_put":put}],"failure":[]
                }),
            )
            .await?;
        Ok(response["succeeded"].as_bool().unwrap_or(false))
    }
    async fn get<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let value = self
            .post("/v3/kv/range", json!({"key":self.key(key)}))
            .await?;
        value["kvs"]
            .as_array()
            .and_then(|v| v.first())
            .map(Self::decode)
            .transpose()
    }
    fn decode<T: DeserializeOwned>(value: &Value) -> Result<T> {
        Ok(serde_json::from_slice(&STANDARD.decode(
            value["value"].as_str().context("missing etcd value")?,
        )?)?)
    }
    async fn members<T: DeserializeOwned>(&self) -> Result<Vec<T>> {
        let prefix = format!("{}/nodes/", self.transport.prefix);
        let mut end = prefix.as_bytes().to_vec();
        *end.last_mut().context("empty prefix")? += 1;
        let value = self
            .post(
                "/v3/kv/range",
                json!({"key":STANDARD.encode(prefix),"range_end":STANDARD.encode(end)}),
            )
            .await?;
        value["kvs"]
            .as_array()
            .into_iter()
            .flatten()
            .map(Self::decode)
            .collect()
    }
}

impl Store {
    pub async fn list<T: DeserializeOwned>(&self, prefix: &str) -> Result<Vec<T>> {
        match self {
            Self::Consul(s) => {
                let response = s
                    .request(reqwest::Method::GET, &s.key(prefix))
                    .query(&[("recurse", "true"), ("consistent", "true")])
                    .send()
                    .await?;
                if response.status() == StatusCode::NOT_FOUND {
                    return Ok(vec![]);
                }
                let entries: Vec<Entry> = response.error_for_status()?.json().await?;
                entries
                    .into_iter()
                    .map(|e| {
                        Ok(serde_json::from_slice(
                            &STANDARD.decode(e.value.context("empty value")?)?,
                        )?)
                    })
                    .collect()
            }
            Self::Etcd(s) => {
                let prefix = format!("{}/{prefix}", s.transport.prefix);
                let mut end = prefix.as_bytes().to_vec();
                *end.last_mut().context("empty prefix")? += 1;
                let value = s
                    .post(
                        "/v3/kv/range",
                        json!({"key":STANDARD.encode(prefix),"range_end":STANDARD.encode(end)}),
                    )
                    .await?;
                value["kvs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(Etcd::decode)
                    .collect()
            }
        }
    }
    pub async fn versioned<T: DeserializeOwned>(&self, key: &str) -> Result<Option<(T, String)>> {
        match self {
            Self::Consul(s) => {
                let response = s
                    .request(reqwest::Method::GET, &s.key(key))
                    .query(&[("consistent", "true")])
                    .send()
                    .await?;
                if response.status() == StatusCode::NOT_FOUND {
                    return Ok(None);
                }
                let mut entries: Vec<Entry> = response.error_for_status()?.json().await?;
                entries
                    .pop()
                    .map(|e| {
                        Ok((
                            serde_json::from_slice(
                                &STANDARD.decode(e.value.context("empty value")?)?,
                            )?,
                            e.index.to_string(),
                        ))
                    })
                    .transpose()
            }
            Self::Etcd(s) => {
                let value = s.post("/v3/kv/range", json!({"key":s.key(key)})).await?;
                value["kvs"]
                    .as_array()
                    .and_then(|v| v.first())
                    .map(|kv| {
                        Ok((
                            Etcd::decode(kv)?,
                            kv["mod_revision"]
                                .as_str()
                                .context("missing revision")?
                                .into(),
                        ))
                    })
                    .transpose()
            }
        }
    }
    pub async fn replace(
        &self,
        key: &str,
        revision: &str,
        value: &impl serde::Serialize,
    ) -> Result<bool> {
        match self {
            Self::Consul(s) => s.put(key, value, &[("cas", revision)]).await,
            Self::Etcd(s) => {
                let response = s.post("/v3/kv/txn",json!({"compare":[{"key":s.key(key),"target":"MOD","result":"EQUAL","mod_revision":revision}],"success":[{"request_put":{"key":s.key(key),"value":STANDARD.encode(serde_json::to_vec(value)?)}}],"failure":[]})).await?;
                Ok(response["succeeded"].as_bool().unwrap_or(false))
            }
        }
    }
    pub async fn remove(&self, key: &str, revision: &str) -> Result<bool> {
        match self {
            Self::Consul(s) => Ok(s
                .request(reqwest::Method::DELETE, &s.key(key))
                .query(&[("cas", revision)])
                .send()
                .await?
                .error_for_status()?
                .json()
                .await?),
            Self::Etcd(s) => {
                let response = s.post("/v3/kv/txn",json!({"compare":[{"key":s.key(key),"target":"MOD","result":"EQUAL","mod_revision":revision}],"success":[{"request_delete_range":{"key":s.key(key)}}],"failure":[]})).await?;
                Ok(response["succeeded"].as_bool().unwrap_or(false))
            }
        }
    }
}
