// Also used while a new FTS response is pending, so typing filters immediately.
export function filterBranches(rows, query) {
  const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return terms.length
    ? rows.filter((row) =>
        terms.every((term) =>
          [row.branch, row.database, row.guest, row.version].some((value) =>
            String(value ?? '')
              .toLocaleLowerCase()
              .includes(term),
          ),
        ),
      )
    : rows;
}
