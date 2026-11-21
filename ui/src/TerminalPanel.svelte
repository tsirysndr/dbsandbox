<script>
  import { Maximize2, Minimize2, X, TerminalSquare } from '@lucide/svelte';
  import TerminalPane from './TerminalPane.svelte';
  let { sessions, active, onactivate, onclose, onreconnect, onheight } =
    $props();
  let height = $state(340),
    fullscreen = $state(false),
    drag = $state(null);
  const clamp = (value) =>
    Math.max(160, Math.min(window.innerHeight - 100, value));
  $effect(() => {
    onheight(fullscreen ? 0 : height);
  });
  function resize(event) {
    if (!drag) return;
    height = clamp(drag.height + drag.y - event.clientY);
  }
</script>

<svelte:window
  onresize={() => {
    if (!fullscreen) height = clamp(height);
  }}
/>
<section
  data-web-terminal
  data-terminal-fullscreen={fullscreen ? '' : undefined}
  aria-label="Branch terminals"
  class="fixed inset-x-0 bottom-0 z-40 flex flex-col border-t border-line bg-canvas shadow-2xl"
  style:height={fullscreen ? '100dvh' : height + 'px'}
>
  <button
    type="button"
    aria-label="Resize terminal panel"
    tabindex="0"
    class="absolute inset-x-0 -top-1 z-10 h-2 cursor-ns-resize touch-none border-0 bg-transparent"
    onpointerdown={(event) => {
      if (fullscreen) return;
      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);
      drag = { height, y: event.clientY };
    }}
    onpointermove={resize}
    onpointerup={() => (drag = null)}
    onpointercancel={() => (drag = null)}
    onkeydown={(event) => {
      if (!fullscreen && ['ArrowUp', 'ArrowDown'].includes(event.key)) {
        event.preventDefault();
        height = clamp(height + (event.key === 'ArrowUp' ? 20 : -20));
      }
    }}
  ></button>
  <header
    class="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3"
  >
    <TerminalSquare size={15} class="shrink-0 text-accent" />
    <div
      role="tablist"
      aria-label="Terminal sessions"
      class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
    >
      {#each sessions as session (session.id)}<div
          class={'flex shrink-0 items-center border border-line' +
            (active === session.id ? ' bg-accent/10' : '')}
        >
          <button
            role="tab"
            aria-selected={active === session.id}
            class="px-3 py-1 text-xs"
            class:text-accent={active === session.id}
            onclick={() => onactivate(session.id)}
          >
            {session.label}
          </button>
          <button
            class="p-1 text-zinc-500 hover:text-white"
            aria-label={'Close ' + session.label}
            onclick={() => onclose(session.id)}
          >
            <X size={12} />
          </button>
        </div>{/each}
    </div>
    <button
      class="button-small shrink-0"
      aria-label={fullscreen ? 'Restore terminal panel' : 'Fullscreen terminal'}
      onclick={() => (fullscreen = !fullscreen)}
    >
      {#if fullscreen}<Minimize2 size={14} />{:else}<Maximize2 size={14} />{/if}
    </button>
    <button
      class="button-small shrink-0"
      aria-label="Close all terminals"
      onclick={() => sessions.forEach((session) => onclose(session.id))}
    >
      <X size={14} />
    </button>
  </header>
  <div class="relative min-h-0 flex-1">
    {#each sessions as session (session.id)}<TerminalPane
        {session}
        active={active === session.id}
        {onreconnect}
      />{/each}
  </div>
</section>
