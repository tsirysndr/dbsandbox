<script>
  import { segmentPath } from './graph.js';
  let { row, onselect } = $props();
  const graph = $derived(row.graph);
</script>

<svg
  aria-hidden="true"
  class="pointer-events-none absolute inset-y-0 left-0 h-full"
  width={graph.lanes * 24 + 8}
  viewBox={`0 0 ${graph.lanes * 24 + 8} 100`}
  preserveAspectRatio="none"
>
  {#each graph.segments as segment}<path
      d={segmentPath(segment)}
      fill="none"
      stroke={segment.color}
      stroke-width="2"
      vector-effect="non-scaling-stroke"
    />{/each}
</svg>
<button
  class="absolute top-1/2 flex size-6 -translate-x-1/2 -translate-y-1/2 items-center justify-center"
  style:left={`${16 + graph.lane * 24}px`}
  aria-label={'Highlight branch ' + row.branch}
  title={row.branch +
    ' · ' +
    (row.parent
      ? 'from ' + row.parent
      : row.branch === 'main'
        ? 'root'
        : 'parent unknown') +
    ' · ' +
    (row.created || 'Unknown')}
  onclick={onselect}
>
  <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
    {#if graph.unknown}<path
        d="M7 1 L13 7 L7 13 L1 7 Z"
        fill="#111113"
        stroke={graph.color}
        stroke-width="2"
      />{:else}<circle
        cx="7"
        cy="7"
        r={row.active ? 5 : 4}
        fill={graph.color}
      />{#if row.active}<circle cx="7" cy="7" r="2" fill="#111113" />{/if}{/if}
  </svg>
</button>
