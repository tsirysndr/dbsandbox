use dbsandbox_cluster::{Config, Running};
use neon::prelude::*;
use std::sync::{Mutex, OnceLock};
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("Tokio runtime"))
}
struct Handle(Mutex<Option<Running>>);
impl Finalize for Handle {
    fn finalize<'a, C: Context<'a>>(self, _: &mut C) {
        if let Some(running) = self.0.into_inner().unwrap() {
            runtime().spawn(async move {
                let _ = running.stop().await;
            });
        }
    }
}
fn start(mut cx: FunctionContext) -> JsResult<JsPromise> {
    let config = cx.argument::<JsString>(0)?.value(&mut cx);
    let config: Config = match serde_json::from_str(&config) {
        Ok(config) => config,
        Err(error) => return cx.throw_type_error(error.to_string()),
    };
    let channel = cx.channel();
    let (deferred, promise) = cx.promise();
    runtime().spawn(async move {
        let result = dbsandbox_cluster::start(config).await;
        deferred.settle_with(&channel, move |mut cx| match result {
            Ok(running) => {
                let address = cx.string(running.address.to_string());
                let handle = cx.boxed(Handle(Mutex::new(Some(running))));
                let object = cx.empty_object();
                object.set(&mut cx, "address", address)?;
                object.set(&mut cx, "handle", handle)?;
                Ok(object)
            }
            Err(error) => cx.throw_error(error.to_string()),
        });
    });
    Ok(promise)
}
fn stop(mut cx: FunctionContext) -> JsResult<JsPromise> {
    let handle = cx.argument::<JsBox<Handle>>(0)?;
    let running = handle.0.lock().unwrap().take();
    let channel = cx.channel();
    let (deferred, promise) = cx.promise();
    runtime().spawn(async move {
        let result = match running {
            Some(running) => running.stop().await,
            None => Ok(()),
        };
        deferred.settle_with(&channel, move |mut cx| match result {
            Ok(()) => Ok(cx.undefined()),
            Err(error) => cx.throw_error(error.to_string()),
        });
    });
    Ok(promise)
}
fn wait(mut cx: FunctionContext) -> JsResult<JsPromise> {
    let handle = cx.argument::<JsBox<Handle>>(0)?;
    let running = handle.0.lock().unwrap().clone();
    let channel = cx.channel();
    let (deferred, promise) = cx.promise();
    runtime().spawn(async move {
        let result = match running {
            Some(running) => running.wait().await,
            None => Ok(()),
        };
        deferred.settle_with(&channel, move |mut cx| match result {
            Ok(()) => Ok(cx.undefined()),
            Err(error) => cx.throw_error(error.to_string()),
        });
    });
    Ok(promise)
}
#[neon::main]
fn main(mut cx: ModuleContext) -> NeonResult<()> {
    cx.export_function("start", start)?;
    cx.export_function("stop", stop)?;
    cx.export_function("wait", wait)?;
    Ok(())
}
