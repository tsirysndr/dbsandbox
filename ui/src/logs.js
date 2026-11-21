import { timestamp } from '../../output/Sbx.UI.Time/foreign.js';
export function filterLogLines(text, query) {
  const lines = text.split('\n');
  const total = lines.length - (lines.at(-1) === '' ? 1 : 0);
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return { text, matched: total, total };
  const matches = lines.filter((line) =>
    terms.every((term) => line.toLowerCase().includes(term)),
  );
  return { text: matches.join('\n'), matched: matches.length, total };
}

export function highlightMatches(text, query) {
  const terms = query.trim().split(/\s+/).filter(Boolean);
  if (!terms.length) return [{ text, match: false }];
  const lower = text.toLowerCase(),
    ranges = [];
  for (const term of terms) {
    const needle = term.toLowerCase();
    for (
      let start = lower.indexOf(needle);
      start !== -1;
      start = lower.indexOf(needle, start + 1)
    )
      ranges.push([start, start + needle.length]);
  }
  ranges.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const range of ranges) {
    const last = merged.at(-1);
    if (last && range[0] <= last[1]) last[1] = Math.max(last[1], range[1]);
    else merged.push([...range]);
  }
  const spans = [];
  let end = 0;
  for (const [start, next] of merged) {
    if (start > end) spans.push({ text: text.slice(end, start), match: false });
    spans.push({ text: text.slice(start, next), match: true });
    end = next;
  }
  if (end < text.length) spans.push({ text: text.slice(end), match: false });
  return spans;
}

export function datedLogLine(text, capturedAt) {
  const prefix = text.match(
    /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+/,
  )?.[0];
  return {
    date: timestamp(prefix?.trim() || capturedAt),
    text: prefix ? text.slice(prefix.length) : text,
  };
}
