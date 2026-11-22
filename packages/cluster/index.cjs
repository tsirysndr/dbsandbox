'use strict';

/** Start the Tokio/Axum coordinator in this process. */
exports.start = async function start(config) {
  const native = require('./native.node');
  const running = await native.start(JSON.stringify(config));
  let stopping;
  const closed = native.wait(running.handle);
  closed.catch(() => {});
  return Object.freeze({
    address: running.address,
    closed,
    stop() {
      return (stopping ??= native.stop(running.handle));
    },
  });
};
