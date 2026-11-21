<script>
  import { onMount, onDestroy } from 'svelte';
  import { Terminal } from '@wterm/svelte';
  let { session, active, onreconnect } = $props();
  let fontReady = $state(false),
    status = $state('Loading terminal…'),
    stopped = $state(false);
  let term,
    socket,
    disposed = false;
  const send = (value) => {
    if (socket?.readyState === WebSocket.OPEN)
      socket.send(JSON.stringify(value));
  };

  onMount(async () => {
    try {
      await document.fonts.load('14px "Caskaydia Nerd Mono"');
    } finally {
      if (!disposed) fontReady = true;
    }
  });

  function ready(instance) {
    term = instance;
    term.fit();
    status = 'Connecting…';
    socket = new WebSocket(
      `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/api/terminal/socket?id=${session.id}&ticket=${session.ticket}`,
    );
    socket.onopen = () => {
      status = 'Connected';
      send({ type: 'resize', cols: term.cols, rows: term.rows });
      if (active) term.focus();
    };
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.type === 'output') term.write(message.data);
      else if (message.type === 'exit') {
        status = `Exited (${message.code})`;
        stopped = true;
      } else if (message.type === 'error') {
        status = message.message;
        stopped = true;
      }
    };
    socket.onerror = () => {
      status = 'Connection failed';
      stopped = true;
    };
    socket.onclose = () => {
      if (!disposed) {
        if (!stopped) status = 'Disconnected';
        stopped = true;
      }
    };
  }

  $effect(() => {
    if (active && term) {
      requestAnimationFrame(() => {
        if (!disposed) {
          term.fit();
          term.focus();
          send({ type: 'resize', cols: term.cols, rows: term.rows });
        }
      });
    }
  });
  onDestroy(() => {
    disposed = true;
    socket?.close();
  });
</script>

<div
  class:invisible={!active}
  class="web-terminal absolute inset-0 flex flex-col"
  aria-hidden={!active}
  inert={!active}
>
  <div class="min-h-0 flex-1 px-3 py-2">
    {#if fontReady}<Terminal
        class="h-full"
        aria-label={session.label}
        autoResize={true}
        renderingPaused={!active}
        scrollbackLines={2000}
        onReady={ready}
        onData={(data) => send({ type: 'input', data })}
        onBinary={(data) =>
          send({ type: 'input', data: new TextDecoder().decode(data) })}
        onResize={(cols, rows) => send({ type: 'resize', cols, rows })}
        onError={(error) => {
          status = String(error);
          stopped = true;
        }}
      />{/if}
  </div>
  <div
    class="flex shrink-0 items-center justify-between border-t border-line px-3 py-1 text-[10px] text-zinc-500"
    role="status"
  >
    <span>{status}</span>{#if stopped}<button
        class="text-accent hover:text-white"
        onclick={() => onreconnect(session)}
      >
        Reconnect
      </button>{/if}
  </div>
</div>
