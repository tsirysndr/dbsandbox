<script>
  import { onMount, tick } from 'svelte';
  import Skeleton from './Skeleton.svelte';
  import BranchGraph from './BranchGraph.svelte';
  import { branchGraph } from './graph.js';
  import {
    Database,
    GitBranch,
    Search,
    X,
    ChevronDown,
    ChevronLeft,
    ChevronRight,
    RefreshCw,
    Square,
    Play,
    GitFork,
    Check,
    ExternalLink,
    Plus,
    Server,
    Cpu,
    Circle,
    ListFilter,
    LoaderCircle,
    CircleAlert,
    ArrowRight,
    SlidersHorizontal,
    Copy,
    ScrollText,
    Pause,
    Radio,
    Keyboard,
    Download,
    ArrowUp,
    Trash2,
  } from '@lucide/svelte';
  import { filterBranches } from './search.js';
  import { paginate } from './pagination.js';
  import { filterLogLines, highlightMatches, datedLogLine } from './logs.js';
  let { token } = $props();
  let snapshot = $state({
    rows: [],
    catalog: [],
    jobs: [],
    errors: [],
    engine: {},
  });
  let page = $state(1),
    pageSize = $state(10);
  let scrollY = $state(0);
  let copied = $state('');
  let copyTimer;
  let logTarget = $state(null),
    logText = $state(''),
    logError = $state(''),
    logFollowing = $state(true),
    logLoading = $state(false),
    logTruncated = $state(false);
  let logDialog, logElement, shortcutsDialog;
  let logFilter = $state('');
  let logTimestamps = $state(true),
    logCapturedAt = $state('');
  const presentedLogs = $derived(
    filteredLogs.text
      ? filteredLogs.text
          .replace(/\n$/, '')
          .split('\n')
          .map((line) => datedLogLine(line, logCapturedAt))
      : [],
  );
  const filteredLogs = $derived(filterLogLines(logText, logFilter));
  let keyboardTool = $state('');
  const keyboardRow = $derived(
    visible.find((row) => row.tool === keyboardTool),
  );

  function openLogs(row, source = 'server', id = '') {
    if (row?.kind === 'data' && source === 'server') source = 'vm';
    logText = '';
    logFilter = '';
    logError = '';
    logFollowing = true;
    logTarget = {
      database: row?.database || '',
      branch: row?.branch || '',
      source,
      id,
    };
  }

  $effect(() => {
    if (logTarget && logDialog && !logDialog.open) logDialog.showModal();
    if (!logTarget && logDialog?.open) logDialog.close();
  });

  $effect(() => {
    const target = logTarget,
      following = logFollowing;
    if (!target) return;
    const controller = new AbortController();
    let busy = false,
      cancelled = false;
    async function load() {
      if (busy) return;
      busy = true;
      logLoading = true;
      try {
        const params = new URLSearchParams(target);
        const result = await request(
          '/api/logs?' + params,
          undefined,
          controller.signal,
        );
        if (!cancelled) {
          const nextText = result.text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
          if (nextText !== logText || !logCapturedAt)
            logCapturedAt = new Date().toISOString();
          logText = nextText;
          logTruncated = result.truncated;
          logError = '';
          await tick();
          if (following && logElement)
            logElement.scrollTop = logElement.scrollHeight;
        }
      } catch (e) {
        if (!cancelled) logError = e.message;
      } finally {
        if (!cancelled) logLoading = false;
        busy = false;
      }
    }
    load();
    const timer = following ? setInterval(load, 2000) : undefined;
    return () => {
      cancelled = true;
      controller.abort();
      clearInterval(timer);
    };
  });
  let hasSnapshot = $state(false);
  let loading = $state(true),
    refreshing = $state(false),
    error = $state('');
  let matches = $state(null),
    searchError = $state(''),
    resourcesOpen = $state(false),
    engineCpus = $state(2),
    engineMem = $state(2048);
  let cpus = $state(''),
    mem = $state('');
  let query = $state(''),
    database = $state(''),
    guest = $state('linux'),
    version = $state('');
  const available = $derived(
    snapshot.catalog.filter(
      (db) => !snapshot.rows.some((r) => r.database === db.name),
    ),
  );
  const selected = $derived(available.find((db) => db.name === database));
  let graphView = $state(true);
  let branchDatabase = $state('');
  const branchDatabases = $derived(
    [...new Set(snapshot.rows.map((row) => row.database))].sort(),
  );
  const selectedBranchDatabase = $derived(
    branchDatabases.includes(branchDatabase)
      ? branchDatabase
      : branchDatabases[0] || '',
  );
  const databaseBranches = $derived(
    snapshot.rows.filter((row) => row.database === selectedBranchDatabase),
  );
  const visible = $derived(
    branchGraph(
      matches && query.trim()
        ? databaseBranches.filter((row) => matches.includes(row.tool))
        : filterBranches(databaseBranches, query),
    ),
  );
  const pagination = $derived(paginate(visible, page, pageSize));

  $effect(() => {
    query;
    selectedBranchDatabase;
    page = 1;
    keyboardTool = '';
  });

  const busy = $derived(
    snapshot.jobs.some((job) => job.status === 'RUNNING' && !job.url),
  );
  const running = $derived(snapshot.rows.filter((row) => row.running).length);

  const shortcuts = [
    ['/', 'Focus branch quick search'],
    ['?', 'Open keyboard shortcuts'],
    ['j / k or ↑ / ↓', 'Move between branch rows'],
    ['Enter', 'Select highlighted branch'],
    ['Page Up / Page Down', 'Previous / next table page'],
    ['g', 'Toggle branch graph / table'],
    ['b', 'Fork highlighted branch'],
    ['d', 'Delete inactive branch, with confirmation'],
    ['s', 'Start / stop highlighted server'],
    ['u', 'Open its database UI'],
    ['y', 'Copy its full connection URL'],
    ['l', 'View its database logs'],
    ['Shift-L', 'View shared VM logs'],
    ['n', 'Focus the new database form'],
    ['e', 'Open VM resource settings'],
    ['r', 'Refresh dashboard'],
    ['Shift-S', 'Stop all servers, with confirmation'],
    ['Esc', 'Close a dialog, or clear / leave search'],
  ];

  function downloadLogs() {
    const label = [
      'dbsandbox',
      logTarget?.database || 'vm',
      logTarget?.branch,
      logTarget?.source || 'logs',
    ]
      .filter(Boolean)
      .join('-')
      .replace(/[^a-zA-Z0-9._-]/g, '-');
    const link = document.createElement('a');
    const url = URL.createObjectURL(
      new Blob([logText], { type: 'text/plain;charset=utf-8' }),
    );
    link.href = url;
    link.download = label + '.txt';
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function handleShortcut(event) {
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    if (logDialog?.open) {
      if (
        event.key === '/' &&
        !document.activeElement?.matches('input, textarea')
      ) {
        event.preventDefault();
        document.getElementById('log-filter')?.focus();
      }
      return;
    }
    if (shortcutsDialog?.open) return;
    const active = document.activeElement;
    const search = document.getElementById('branch-search');
    if (active === search && event.key === 'Escape') {
      event.preventDefault();
      if (query) query = '';
      else search.blur();
      return;
    }
    if (active === search && event.key === 'Enter' && pagination.items.length) {
      event.preventDefault();
      keyboardTool = pagination.items[0].tool;
      search.blur();
      return;
    }
    if (active?.matches('input, select, textarea, [contenteditable="true"]'))
      return;
    if (event.repeat && !['j', 'k', 'ArrowUp', 'ArrowDown'].includes(event.key))
      return;
    const key = event.key;
    if (key === 'Enter' && active?.matches('button, a')) return;
    if (
      ![
        '/',
        '?',
        'j',
        'k',
        'ArrowUp',
        'ArrowDown',
        'Enter',
        'PageUp',
        'PageDown',
        'g',
        'b',
        'd',
        's',
        'u',
        'y',
        'l',
        'L',
        'n',
        'e',
        'r',
        'S',
      ].includes(key)
    )
      return;
    event.preventDefault();
    if (key === '/') {
      search.focus();
      search.select();
      return;
    }
    if (key === '?') {
      shortcutsDialog.showModal();
      return;
    }
    if (key === 'g') {
      graphView = !graphView;
      return;
    }
    if (key === 'r') {
      refresh();
      return;
    }
    if (key === 'n') {
      document.getElementById('database').focus();
      return;
    }
    if (key === 'e') {
      engineCpus = snapshot.engine.cpus || 2;
      engineMem = snapshot.engine.memoryMiB || 2048;
      resourcesOpen = true;
      await tick();
      document
        .getElementById('resources-title')
        ?.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (key === 'L') {
      openLogs(null, 'vm');
      return;
    }
    if (key === 'S') {
      if (
        !busy &&
        confirm(
          'Stop every configured database server? Data will be preserved.',
        )
      )
        action({ action: 'stop-all' });
      return;
    }
    if (key === 'PageUp' || key === 'PageDown') {
      page = Math.max(
        1,
        Math.min(
          pagination.pages,
          pagination.page + (key === 'PageUp' ? -1 : 1),
        ),
      );
      keyboardTool = '';
      return;
    }
    if (['j', 'k', 'ArrowUp', 'ArrowDown'].includes(key)) {
      active?.blur();
      const current = visible.findIndex((row) => row.tool === keyboardTool);
      const delta = key === 'j' || key === 'ArrowDown' ? 1 : -1;
      const index =
        current < 0
          ? (pagination.page - 1) * Number(pageSize)
          : Math.max(0, Math.min(visible.length - 1, current + delta));
      if (visible[index]) {
        keyboardTool = visible[index].tool;
        page = Math.floor(index / Number(pageSize)) + 1;
        await tick();
        document
          .querySelector('[data-tool="' + keyboardTool + '"]')
          ?.scrollIntoView({ block: 'nearest' });
      }
      return;
    }
    if (!keyboardRow) {
      error = 'Highlight a branch with j / k first.';
      return;
    }
    if (key === 'y') {
      copyConnection(keyboardRow);
      return;
    }
    if (key === 'l') {
      openLogs(keyboardRow);
      return;
    }
    if (busy) return;
    if (key === 's' && keyboardRow.kind === 'data') {
      send(keyboardRow, 'checkout');
      return;
    }
    if (key === 'Enter') send(keyboardRow, 'checkout');
    if (key === 'b') fork(keyboardRow);
    if (key === 'd') deleteBranch(keyboardRow);
    if (
      key === 's' &&
      (!keyboardRow.running ||
        confirm(
          'Stop ' + keyboardRow.database + '/' + keyboardRow.branch + '?',
        ))
    )
      send(keyboardRow, keyboardRow.running ? 'stop' : 'start');
    if (key === 'u' && keyboardRow.running && keyboardRow.ui)
      send(keyboardRow, 'open-ui');
  }

  async function request(path, body, signal) {
    const response = await fetch(path, {
      method: body ? 'POST' : 'GET',
      signal,
      headers: {
        'X-Dbsandbox-Token': token,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await response.json();
    if (!response.ok) throw Error(data.error || 'Request failed');
    return data;
  }

  function chooseDatabase() {
    const db = available.find((db) => db.name === database);
    guest = db?.guests[0] || 'linux';
    version = db?.version || '';
  }

  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    if (!hasSnapshot) loading = true;
    try {
      snapshot = await request('/api/snapshot');
      if (!branchDatabases.includes(branchDatabase))
        branchDatabase = branchDatabases[0] || '';
      hasSnapshot = true;
      error = '';
      if (!available.some((db) => db.name === database)) {
        database = available[0]?.name || '';
        chooseDatabase();
      }
    } catch (e) {
      error = e.message;
    } finally {
      refreshing = false;
      loading = false;
    }
  }

  async function action(data) {
    try {
      await request('/api/action', data);
      await refresh();
    } catch (e) {
      error = e.message;
    }
  }
  $effect(() => {
    const current = query.trim();
    const revision = snapshot.rows
      .map((row) => row.tool + ':' + row.branch)
      .join('|');
    void revision;
    matches = null;
    searchError = '';
    if (!current) return;
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const result = await request(
          '/api/search?q=' + encodeURIComponent(current),
        );
        if (!cancelled) matches = result;
      } catch (e) {
        if (!cancelled) searchError = e.message;
      }
    }, 150);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  });

  const resourceOptions = () => ({
    ...(cpus !== '' && cpus != null ? { cpus: Number(cpus) } : {}),
    ...(mem !== '' && mem != null ? { mem: Number(mem) } : {}),
  });

  function createDatabase(e) {
    e.preventDefault();
    if (
      guest === 'linux' &&
      ((cpus !== '' && cpus != null) || (mem !== '' && mem != null)) &&
      snapshot.engine.status === 'RUNNING' &&
      !confirm(
        'Resource overrides resize the shared Linux VM and may restart every Linux server. Continue?',
      )
    )
      return;
    action({ action: 'start', database, guest, version, ...resourceOptions() });
  }

  async function copyConnection(row) {
    try {
      const result = await request(
        '/api/connection?database=' +
          encodeURIComponent(row.database) +
          '&branch=' +
          encodeURIComponent(row.branch),
      );
      await navigator.clipboard.writeText(result.url);
      copied = row.tool;
      clearTimeout(copyTimer);
      copyTimer = setTimeout(() => (copied = ''), 1800);
    } catch (e) {
      error = 'Could not copy connection URL: ' + e.message;
    }
  }

  const send = (row, actionName) =>
    action({ action: actionName, database: row.database, branch: row.branch });

  function deleteBranch(row) {
    if (!row.deletable || busy) return;
    if (
      confirm(
        `Delete ${row.database}/${row.branch} and all its data? Its server will be stopped. This cannot be undone.`,
      )
    )
      send(row, 'delete');
  }

  function fork(row) {
    const name = prompt('New branch name');
    if (name)
      action({
        action: 'branch',
        database: row.database,
        branch: row.branch,
        name,
      });
  }

  onMount(() => {
    refresh();
    const timer = setInterval(refresh, 3000);
    return () => {
      clearInterval(timer);
      clearTimeout(copyTimer);
    };
  });
</script>

<svelte:window onkeydown={handleShortcut} bind:scrollY />

<main
  aria-busy={loading}
  class="mx-auto max-w-[1380px] px-4 py-8 md:px-8 md:py-12"
>
  {#if loading}<p class="sr-only" role="status">Loading dashboard…</p>{/if}
  <header
    class="flex flex-col justify-between gap-6 sm:flex-row sm:items-center"
  >
    <div>
      <div class="mb-2 flex items-center gap-3">
        <span
          class="flex size-9 items-center justify-center border border-accent/20 bg-accent/5 text-accent"
        >
          <Database size={19} strokeWidth={1.6} />
        </span>
        <h1 class="text-3xl font-semibold tracking-tight">
          dbsandbox<span class="text-accent">_</span>
        </h1>
      </div>
      <p class="text-xs text-zinc-500">
        Independent databases. Parallel branches.
      </p>
    </div>
    <div class="flex flex-wrap gap-2">
      <button
        class="button"
        aria-label="Keyboard shortcuts"
        aria-keyshortcuts="Shift+/"
        title="Keyboard shortcuts (?)"
        onclick={() => shortcutsDialog.showModal()}
      >
        <Keyboard size={15} />Shortcuts
      </button>
      <button
        class="button"
        onclick={refresh}
        disabled={refreshing}
        aria-label="Refresh dashboard"
      >
        <RefreshCw size={14} class={refreshing ? 'animate-spin' : ''} />Refresh
      </button><button
        class="button"
        disabled={busy || !running}
        onclick={() => {
          if (
            confirm(
              'Stop every configured database server? Data will be preserved.',
            )
          )
            action({ action: 'stop-all' });
        }}
      >
        <Square size={13} />Stop all servers
      </button>
    </div>
  </header>
  <div class="my-8 grid gap-4 sm:grid-cols-3">
    <div class="panel p-5">
      <div class="mb-3 flex items-center gap-2 text-xs text-zinc-500">
        <Server size={14} />Shared engine
      </div>
      <div
        class="flex items-center gap-2 text-base font-medium"
        class:text-running={snapshot.engine.status === 'RUNNING'}
      >
        {#if loading}<Skeleton class="h-6 w-28" />{:else}<Circle
            size={8}
            fill="currentColor"
          />{snapshot.engine.status || 'Unavailable'}{/if}
      </div>
    </div>
    <div class="panel p-5">
      <div class="mb-3 flex items-center gap-2 text-xs text-zinc-500">
        <Cpu size={14} />VM resources<button
          class="ml-auto text-zinc-500 hover:text-accent"
          aria-label="Configure VM resources"
          onclick={() => {
            engineCpus = snapshot.engine.cpus || 2;
            engineMem = snapshot.engine.memoryMiB || 2048;
            resourcesOpen = !resourcesOpen;
          }}
        >
          <SlidersHorizontal size={14} />
        </button><button
          class="text-zinc-500 hover:text-accent"
          aria-label="View shared VM logs"
          title="View shared VM logs"
          onclick={() => openLogs(null, 'vm')}
        >
          <ScrollText size={14} />
        </button>
      </div>
      <div class="text-base font-medium">
        {#if loading}<Skeleton class="h-6 w-48 max-w-full" />{:else}{snapshot
            .engine.cpus
            ? `${snapshot.engine.cpus} vCPU · ${snapshot.engine.memoryMiB} MiB`
            : 'Not configured'}{/if}
      </div>
    </div>
    <div class="panel p-5">
      <div class="mb-3 flex items-center gap-2 text-xs text-zinc-500">
        <Database size={14} />Database servers
      </div>
      <div class="text-base font-medium">
        {#if loading}<Skeleton class="h-6 w-56 max-w-full" />{:else}<span
            class="text-accent"
          >
            {running}
          </span>
          running <span class="text-zinc-600">/</span>
          {snapshot.rows.length} configured{/if}
      </div>
    </div>
  </div>
  {#if resourcesOpen}<section
      class="panel mb-5 p-5"
      aria-labelledby="resources-title"
    >
      <h2 id="resources-title" class="mb-2 font-medium">
        Shared Linux VM resources
      </h2>
      <p class="mb-4 text-xs text-zinc-500">
        Changing these values restarts the engine and its Linux servers.
        Database volumes are preserved.
      </p>
      <form
        class="flex flex-wrap items-end gap-3"
        onsubmit={(e) => {
          e.preventDefault();
          if (
            confirm(
              'Resize the shared Linux VM? All Linux servers will restart.',
            )
          )
            action({
              action: 'configure-engine',
              cpus: Number(engineCpus),
              mem: Number(engineMem),
            });
        }}
      >
        <label class="flex flex-col gap-2 text-xs text-zinc-500">
          CPU cores<input
            class="control w-32"
            type="number"
            min="1"
            max="256"
            required
            bind:value={engineCpus}
          />
        </label><label class="flex flex-col gap-2 text-xs text-zinc-500">
          Memory (MiB)<input
            class="control w-40"
            type="number"
            min="128"
            max="1048576"
            required
            bind:value={engineMem}
          />
        </label><button class="button" disabled={busy}>
          <Check size={14} />Apply resources
        </button><button
          type="button"
          class="button"
          onclick={() => (resourcesOpen = false)}
        >
          <X size={14} />Close
        </button>
      </form>
    </section>{/if}
  {#if error || searchError || snapshot.errors.length}<div
      role="alert"
      class="mb-5 flex items-center gap-2 border border-amber-900/50 bg-amber-950/20 p-3 text-xs text-amber-300"
    >
      <CircleAlert size={16} />{error ||
        searchError ||
        snapshot.errors.join(' · ')}
    </div>{/if}
  <section class="panel" aria-labelledby="branches-title">
    <div
      class="sticky top-0 z-20 flex flex-col justify-between gap-4 border-b border-line bg-panel px-5 py-5 md:flex-row md:items-center"
    >
      <div class="flex items-center gap-2.5">
        <GitBranch size={17} class="text-zinc-500" />
        <h2 id="branches-title" class="font-medium">Servers &amp; branches</h2>
        <span
          class="border border-line px-1.5 py-0.5 text-[10px] text-zinc-500"
        >
          {#if loading}<Skeleton
              class="h-3 w-3"
            />{:else}{databaseBranches.length}{/if}
        </span>
      </div>
      <div class="flex w-full flex-col gap-3 sm:flex-row md:w-auto">
        <button
          class="button"
          aria-pressed={graphView}
          aria-label="Toggle branch graph"
          onclick={() => (graphView = !graphView)}
        >
          <GitBranch size={14} />{graphView ? 'Graph' : 'Table'}
        </button>
        <label class="relative shrink-0">
          <span class="sr-only">Branch database</span>
          <select
            aria-label="Branch database"
            class="control min-w-40 appearance-none pr-11"
            value={selectedBranchDatabase}
            disabled={loading || !branchDatabases.length}
            onchange={(event) => {
              branchDatabase = event.currentTarget.value;
              query = '';
              matches = null;
            }}
          >
            {#if !branchDatabases.length}<option value="">
                No databases
              </option>{/if}
            {#each branchDatabases as name}<option value={name}>
                {name}
              </option>{/each}
          </select>
          <ChevronDown
            size={14}
            class="pointer-events-none absolute top-3 right-3.5 text-zinc-500"
          />
        </label>
        <div class="relative w-full sm:w-72">
          <Search
            size={15}
            class="pointer-events-none absolute top-3 left-3 text-zinc-500"
          /><input
            id="branch-search"
            type="search"
            aria-label="Search branches"
            aria-keyshortcuts="/"
            placeholder="Search branches…"
            bind:value={query}
            class="control pr-16 pl-9 [&::-webkit-search-cancel-button]:appearance-none"
            autocomplete="off"
          />{#if query}<button
              class="absolute top-2 right-9 flex size-6 items-center justify-center text-zinc-500 hover:text-white"
              aria-label="Clear branch search"
              onclick={() => (query = '')}
            >
              <X size={14} />
            </button>{/if}
          <kbd
            aria-hidden="true"
            class="pointer-events-none absolute top-2 right-2 flex size-6 items-center justify-center border border-line text-xs text-zinc-500"
          >
            /
          </kbd>
        </div>
      </div>
    </div>
    <div class="overflow-x-auto">
      <table class="w-full min-w-[850px] text-left text-xs">
        <thead class="bg-canvas/40 text-zinc-500">
          <tr>
            {#if graphView}<th class="px-3 py-3 font-normal">Graph</th>{/if}
            {#each ['Branch', 'Created (local)', 'Guest', 'Status', 'Connection', 'Actions'] as column}<th
                class="px-5 py-3 font-normal"
              >
                {column}
              </th>{/each}
          </tr>
        </thead><tbody id="servers">
          {#if loading}
            {#each Array(5) as _}<tr
                class="h-16 border-t border-line"
                aria-hidden="true"
                data-skeleton-row
              >
                {#if graphView}<td class="px-3 py-4">
                    <Skeleton class="w-12" />
                  </td>{/if}
                {#each ['w-32', 'w-28', 'w-14', 'w-20', 'w-48', 'w-44'] as width}<td
                    class="px-5 py-4"
                  >
                    <Skeleton class={width + ' max-w-full'} />
                  </td>{/each}
              </tr>{/each}
          {:else}{#each pagination.items as row (row.tool)}<tr
                class={'border-t border-line transition-colors hover:bg-zinc-900/40' +
                  (keyboardTool === row.tool ? ' bg-accent/10' : '')}
                data-tool={row.tool}
                aria-selected={keyboardTool === row.tool}
              >
                {#if graphView}<td
                    class="relative p-0"
                    style:min-width={`${row.graph.lanes * 24 + 8}px`}
                    data-graph-cell
                  >
                    <BranchGraph
                      {row}
                      onselect={() => (keyboardTool = row.tool)}
                    />
                  </td>{/if}
                <td class="px-5 py-4">
                  <span
                    class="inline-flex items-center gap-2 font-medium whitespace-nowrap"
                    class:text-accent={row.active}
                  >
                    <GitBranch size={13} />{row.branch}{#if row.active}<span
                        class="sr-only"
                      >
                        (selected)
                      </span><Check size={12} />{/if}
                  </span>
                  <div class="mt-1 text-[10px] text-zinc-600">
                    {row.parent
                      ? 'from ' +
                        row.parent +
                        (row.graph.unknown ? ' · not in view' : '')
                      : row.branch === 'main'
                        ? 'root'
                        : 'parent unknown'}
                  </div>
                </td><td
                  class="px-5 py-4 text-[11px] whitespace-nowrap text-zinc-500"
                >
                  {#if row.createdAt != null}<time
                      datetime={new Date(row.createdAt * 1000).toISOString()}
                    >
                      {row.created}
                    </time>{:else}Unknown{/if}
                </td><td class="px-5 py-4 text-zinc-500">{row.guest}</td><td
                  class="px-5 py-4"
                >
                  <span
                    class="inline-flex items-center gap-2 text-[11px]"
                    class:text-running={row.running}
                    class:text-amber-300={row.status === 'UNKNOWN'}
                    class:text-zinc-500={!row.running &&
                      row.status !== 'UNKNOWN'}
                  >
                    <Circle size={6} fill="currentColor" />{row.status}
                  </span>
                </td><td class="max-w-72 px-5 py-4 text-[11px] text-zinc-500">
                  <div class="flex items-center gap-2">
                    <span class="break-all">
                      {row.url}
                    </span>{#if row.port > 0}<button
                        class="flex size-7 shrink-0 items-center justify-center text-zinc-500 transition-colors hover:bg-zinc-800 hover:text-accent"
                        aria-label={copied === row.tool
                          ? 'Connection URL copied'
                          : 'Copy connection URL for ' +
                            row.database +
                            '/' +
                            row.branch}
                        title={copied === row.tool
                          ? 'Copied!'
                          : 'Copy connection URL'}
                        onclick={() => copyConnection(row)}
                      >
                        {#if copied === row.tool}<Check
                            size={14}
                            class="text-accent"
                          />{:else}<Copy size={14} />{/if}
                      </button>{/if}
                    {#if row.deletable}<button
                        class="button-small hover:border-red-400/50 hover:text-red-400"
                        disabled={busy}
                        aria-label={'Delete ' + row.database + '/' + row.branch}
                        onclick={() => deleteBranch(row)}
                      >
                        <Trash2 size={12} />Delete
                      </button>{/if}
                  </div>
                </td><td class="px-5 py-4">
                  <div class="flex flex-wrap gap-1.5">
                    <button
                      class="button-small"
                      disabled={busy}
                      onclick={() =>
                        send(
                          row,
                          row.kind === 'data'
                            ? 'checkout'
                            : row.running
                              ? 'stop'
                              : 'start',
                        )}
                    >
                      {#if row.kind === 'data'}<GitBranch
                          size={12}
                        />Switch{:else if row.running}<Square
                          size={12}
                        />Stop{:else}<Play size={12} />Start{/if}
                    </button><button
                      class="button-small"
                      disabled={busy}
                      onclick={() => fork(row)}
                    >
                      <GitFork size={12} />Fork
                    </button><button
                      class="button-small"
                      onclick={() => openLogs(row)}
                    >
                      <ScrollText size={12} />Logs
                    </button>{#if !row.active && row.kind !== 'data'}<button
                        class="button-small"
                        disabled={busy}
                        onclick={() => send(row, 'checkout')}
                      >
                        <Check size={12} />Select
                      </button>{/if}{#if row.running && row.ui}<button
                        class="button-small"
                        disabled={busy}
                        onclick={() => send(row, 'open-ui')}
                      >
                        <ExternalLink size={12} />Open UI
                      </button>{/if}
                  </div>
                </td>
              </tr>{/each}{/if}
        </tbody>
      </table>
    </div>
    {#if !loading && !visible.length}<div
        class="flex flex-col items-center gap-3 px-5 py-12 text-zinc-500"
      >
        <ListFilter size={24} strokeWidth={1.4} />
        <p>
          {loading
            ? 'Loading servers…'
            : query.trim()
              ? 'No branches match your search.'
              : 'No configured databases. Start one below.'}
        </p>
        {#if query}<button class="button-small" onclick={() => (query = '')}>
            Clear search<X size={12} />
          </button>{/if}
      </div>{/if}
    <nav
      class="flex flex-wrap items-center justify-between gap-4 border-t border-line px-5 py-4 text-xs text-zinc-500"
      aria-label="Branch table pagination"
    >
      <p role="status">
        {#if loading}<Skeleton
            class="w-40"
          />{:else}{pagination.start}–{pagination.end} of {pagination.total}
          {query.trim() ? 'matching branches' : 'branches'}{/if}
      </p>
      <div class="flex flex-wrap items-center gap-4">
        <label class="flex items-center gap-2">
          Rows per page<span class="relative">
            <select
              aria-label="Branches per page"
              disabled={loading}
              class="control h-8 w-20 appearance-none pr-9 text-xs"
              bind:value={pageSize}
              onchange={() => (page = 1)}
            >
              {#each [10, 25, 50] as size}<option value={size}>
                  {size}
                </option>{/each}
            </select><ChevronDown
              size={13}
              class="pointer-events-none absolute top-2.5 right-3"
            />
          </span>
        </label>
        <span aria-label="Current branch page">
          Page {pagination.page} of {pagination.pages}
        </span>
        <div class="flex gap-1.5">
          <button
            class="button-small"
            aria-label="Previous branch page"
            disabled={loading || pagination.page === 1}
            onclick={() => (page = pagination.page - 1)}
          >
            <ChevronLeft size={13} />Previous
          </button><button
            class="button-small"
            aria-label="Next branch page"
            disabled={loading || pagination.page === pagination.pages}
            onclick={() => (page = pagination.page + 1)}
          >
            Next<ChevronRight size={13} />
          </button>
        </div>
      </div>
    </nav>
  </section>
  <section class="panel mt-5 p-5" aria-labelledby="create-title">
    <div class="mb-5 flex items-center gap-2.5">
      <Plus size={17} class="text-zinc-500" />
      <h2 id="create-title" class="font-medium">Start a database</h2>
    </div>
    {#if loading}<div class="flex flex-wrap items-end gap-3" aria-hidden="true">
        {#each ['w-52', 'w-36', 'w-44', 'w-28', 'w-36'] as width}<div
            class={width + ' max-w-full space-y-2'}
          >
            <Skeleton class="h-3 w-16" /><Skeleton class="h-10 w-full" />
          </div>{/each}<Skeleton class="h-10 w-36" />
      </div>{:else}<form
        class="flex flex-col flex-wrap gap-3 sm:flex-row sm:items-end"
        onsubmit={createDatabase}
      >
        <label class="flex flex-col gap-2 text-xs text-zinc-500 sm:w-52">
          Database<span class="relative">
            <select
              id="database"
              class="control appearance-none pr-11"
              bind:value={database}
              onchange={chooseDatabase}
              disabled={!available.length}
            >
              {#each available as db}<option value={db.name}>
                  {db.product}
                </option>{/each}
            </select><ChevronDown
              size={15}
              class="pointer-events-none absolute top-3 right-3.5 text-zinc-500"
            />
          </span>
        </label>
        <label class="flex flex-col gap-2 text-xs text-zinc-500 sm:w-36">
          Guest<span class="relative">
            <select
              id="guest"
              class="control appearance-none pr-11"
              bind:value={guest}
              onchange={() =>
                (version = guest === 'linux' ? selected?.version || '' : '')}
              disabled={!available.length}
            >
              {#each selected?.guests || [] as os}<option value={os}>
                  {os}
                </option>{/each}
            </select><ChevronDown
              size={15}
              class="pointer-events-none absolute top-3 right-3.5 text-zinc-500"
            />
          </span>
        </label>
        <label class="flex flex-col gap-2 text-xs text-zinc-500 sm:w-44">
          Version<input
            id="version"
            class="control"
            bind:value={version}
            placeholder={guest === 'linux'
              ? selected?.version
              : 'Latest OS release'}
            maxlength="200"
            autocomplete="off"
            disabled={!available.length}
          />
        </label>
        <label class="flex flex-col gap-2 text-xs text-zinc-500 sm:w-28">
          CPU cores<input
            class="control"
            type="number"
            min="1"
            max="256"
            placeholder="Auto"
            bind:value={cpus}
            disabled={!available.length}
          />
        </label>
        <label class="flex flex-col gap-2 text-xs text-zinc-500 sm:w-36">
          Memory (MiB)<input
            class="control"
            type="number"
            min="128"
            max="1048576"
            placeholder="Auto"
            bind:value={mem}
            disabled={!available.length}
          />
        </label>
        <button
          class="button h-10 border-accent bg-accent font-bold text-white hover:border-accent hover:bg-accent/90 hover:text-white"
          disabled={busy || !available.length}
        >
          <Plus size={15} />Start database
        </button>
      </form>{/if}
    <p class="mt-4 text-[11px] text-zinc-600">
      Configured databases resume from their server rows above. Credentials use
      each database's CLI defaults.
    </p>
  </section>
  <section class="panel mt-5 p-5" aria-labelledby="tasks-title">
    <div class="mb-4 flex items-center gap-2.5">
      <ArrowRight size={17} class="text-zinc-500" />
      <h2 id="tasks-title" class="font-medium">Tasks &amp; database UIs</h2>
    </div>
    <div id="jobs" aria-live="polite">
      {#if loading}<div class="space-y-3 py-2" aria-hidden="true">
          <Skeleton class="w-72 max-w-full" /><Skeleton
            class="w-48 max-w-full"
          />
        </div>{:else}{#each [...snapshot.jobs].reverse() as job (job.id)}<div
            class="flex flex-wrap items-center gap-2 border-b border-line py-3 text-xs"
          >
            <span>
              {job.action}
              {job.database}{job.branch ? '/' + job.branch : ''}
            </span><span class="text-zinc-600">·</span><span
              class:text-running={job.status === 'RUNNING'}
              class:text-amber-300={job.status === 'FAILED'}
              class="inline-flex items-center gap-1.5 text-zinc-500"
            >
              {#if job.status === 'RUNNING'}<LoaderCircle
                  size={12}
                  class="animate-spin"
                />{/if}{job.status}
            </span><button
              class="button-small ml-2"
              onclick={() => openLogs(job, 'operation', job.id)}
            >
              <ScrollText size={12} />Logs
            </button>{#if job.url && job.ready}<a
                class="ml-2 inline-flex items-center gap-1.5 text-accent hover:underline"
                href={job.url}
                target="_blank"
                rel="noopener noreferrer"
              >
                Open UI<ExternalLink size={12} />
              </a>{/if}{#if job.status === 'RUNNING' && job.url}<button
                class="button-small ml-2"
                onclick={() => action({ action: 'close-ui', id: job.id })}
              >
                <X size={12} />Close UI
              </button>{/if}
          </div>{:else}<p class="py-2 text-xs text-zinc-600">
            No tasks yet.
          </p>{/each}{/if}
    </div>
    {#if snapshot.engine.filesystem || snapshot.engine.message}<p
        class="mt-4 text-[10px] break-all text-zinc-600"
      >
        {snapshot.engine.filesystem
          ? 'Image-store filesystem: ' + snapshot.engine.filesystem
          : snapshot.engine.message}
      </p>{/if}
  </section>
  <span class="sr-only" role="status" aria-live="polite">
    {copied ? 'Connection URL copied to clipboard' : ''}
  </span>
  <footer class="mt-6 flex items-start gap-2 text-[11px] text-zinc-600">
    <Circle size={10} class="mt-1 shrink-0" />
    <p>
      Keep this command running. Closing the dashboard stops its web UI
      sessions; database servers and data stay in place.
    </p>
  </footer>
</main>

<dialog
  bind:this={logDialog}
  onclose={() => (logTarget = null)}
  oncancel={() => (logTarget = null)}
  aria-labelledby="logs-title"
  class="m-auto h-[80vh] max-h-[900px] w-[calc(100%-2rem)] max-w-6xl border border-line bg-canvas p-0 text-zinc-100 backdrop:bg-black/80 open:flex open:flex-col"
>
  <header
    class="flex flex-wrap items-center justify-between gap-3 border-b border-line px-5 py-4"
  >
    <div>
      <h2 id="logs-title" class="flex items-center gap-2 font-medium">
        <ScrollText size={17} class="text-accent" />{logTarget?.database
          ? logTarget.database +
            (logTarget.branch ? '/' + logTarget.branch : '')
          : 'Shared Linux VM'} logs
      </h2>
      <p class="mt-1 text-xs text-zinc-500">
        {logTarget?.source === 'operation'
          ? 'Captured operation output'
          : logTarget?.source === 'server'
            ? 'Database server output'
            : logTarget?.source === 'boot'
              ? 'VM boot log'
              : 'VM console output'}
      </p>
    </div>
    <div class="flex flex-wrap items-center gap-2">
      <label class="relative">
        <span class="sr-only">Log source</span><select
          aria-label="Log source"
          class="control appearance-none pr-11 text-xs"
          value={logTarget?.source || 'server'}
          onchange={(event) => {
            logText = '';
            logTarget = { ...logTarget, source: event.currentTarget.value };
          }}
        >
          <option value="server" disabled={!logTarget?.database}>
            Database / container
          </option><option value="vm">VM console</option><option value="boot">
            VM boot
          </option>{#if logTarget?.id}<option value="operation">
              Operation output
            </option>{/if}
        </select><ChevronDown
          size={14}
          class="pointer-events-none absolute top-3 right-3.5 text-zinc-500"
        />
      </label>
      <button
        class="button"
        aria-label="Toggle log timestamps"
        aria-pressed={logTimestamps}
        title="Local time; untimed lines show capture time"
        onclick={() => (logTimestamps = !logTimestamps)}
      >
        Dates {logTimestamps ? 'on' : 'off'}
      </button>
      <button
        class="button"
        aria-pressed={logFollowing}
        onclick={() => (logFollowing = !logFollowing)}
      >
        {#if logFollowing}<Pause size={13} />Pause{:else}<Radio
            size={13}
          />Follow{/if}
      </button>
      <button
        class="button"
        aria-label="Close log viewer"
        onclick={() => (logTarget = null)}
      >
        <X size={15} />
      </button>
    </div>
  </header>
  <div
    class="flex flex-wrap items-center justify-between gap-3 border-b border-line px-5 py-3"
  >
    <div class="relative min-w-48 flex-1">
      <Search
        size={14}
        class="pointer-events-none absolute top-3 left-3 text-zinc-500"
      /><input
        id="log-filter"
        aria-label="Quick filter logs"
        placeholder="Quick filter logs… (/ to focus)"
        class="control pr-10 pl-9 text-xs"
        bind:value={logFilter}
        autocomplete="off"
      />{#if logFilter}<button
          class="absolute top-2 right-2 flex size-6 items-center justify-center text-zinc-500 hover:text-white"
          aria-label="Clear log filter"
          onclick={() => (logFilter = '')}
        >
          <X size={13} />
        </button>{/if}
    </div>
    <span class="text-[11px] text-zinc-500" role="status">
      {filteredLogs.matched} / {filteredLogs.total} lines
    </span>
    <button
      class="button"
      disabled={!logText}
      onclick={downloadLogs}
      title="Download the full current log snapshot as plain text"
    >
      <Download size={14} />Download .txt
    </button>
  </div>
  {#if logError}<p
      role="alert"
      class="border-b border-line px-5 py-3 text-xs text-amber-300"
    >
      {logError}
    </p>{/if}
  <pre
    bind:this={logElement}
    aria-label="Log output"
    class="min-h-0 flex-1 overflow-auto bg-[#070708] p-5 font-mono text-xs leading-6 whitespace-pre text-zinc-300">{#if presentedLogs.length}{#each presentedLogs as line, i}{#if i > 0}{'\n'}{/if}{#if logTimestamps}<span
            class="text-zinc-500"
            data-log-date
            >{#each highlightMatches(line.date, logFilter) as span}{#if span.match}<mark
                  class="bg-accent text-white">{span.text}</mark
                >{:else}{span.text}{/if}{/each}{'  '}</span
          >{/if}{#each highlightMatches(line.text, logFilter) as span}{#if span.match}<mark
              class="bg-accent text-white">{span.text}</mark
            >{:else}{span.text}{/if}{/each}{/each}{:else}{logLoading && !logText
        ? 'Loading logs…'
        : logFilter.trim() && logText
          ? 'No log lines match this filter.'
          : 'No log output yet.'}{/if}</pre>
  <footer
    class="flex flex-wrap justify-between gap-2 border-t border-line px-5 py-3 text-[11px] text-zinc-500"
  >
    <span>
      {logFollowing
        ? 'Following · refreshes every 2s'
        : 'Paused · enable Follow to resume'}{logLoading ? ' · reading…' : ''}
    </span><span>
      {logTruncated
        ? 'Showing the latest 256 KiB'
        : 'Latest output · container tail: 500 lines'} · known credentials redacted
    </span>
  </footer>
</dialog>

<dialog
  id="shortcuts-modal"
  bind:this={shortcutsDialog}
  aria-labelledby="shortcuts-title"
  class="m-auto max-h-[85vh] w-[calc(100%-2rem)] max-w-xl overflow-auto border border-line bg-panel p-0 text-zinc-100 backdrop:bg-black/80"
>
  <header
    class="flex items-center justify-between border-b border-line px-5 py-4"
  >
    <h2 id="shortcuts-title" class="flex items-center gap-2 font-medium">
      <Keyboard size={18} class="text-accent" />Keyboard shortcuts
    </h2>
    <button
      class="button"
      aria-label="Close keyboard shortcuts"
      onclick={() => shortcutsDialog.close()}
    >
      <X size={15} />
    </button>
  </header>
  <dl class="space-y-3 p-5 text-xs">
    {#each shortcuts as [keys, description]}<div
        class="flex items-center justify-between gap-4"
      >
        <dt>
          <kbd
            class="inline-block border border-line bg-canvas px-2 py-1 font-mono text-zinc-200"
          >
            {keys}
          </kbd>
        </dt>
        <dd class="text-right text-zinc-400">{description}</dd>
      </div>{/each}
  </dl>
  <p class="border-t border-line px-5 py-3 text-[11px] text-zinc-500">
    Shortcuts pause while typing in form fields or while a dialog is open. Use
    Esc to close.
  </p>
</dialog>

{#if scrollY > 300}
  <button
    class="fixed right-5 bottom-5 z-30 flex size-11 items-center justify-center rounded-full border border-line bg-panel text-zinc-300 shadow-lg transition-colors hover:border-accent hover:text-accent"
    aria-label="Scroll to top"
    onclick={() =>
      window.scrollTo({
        top: 0,
        behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches
          ? 'instant'
          : 'smooth',
      })}
  >
    <ArrowUp size={19} />
  </button>
{/if}
