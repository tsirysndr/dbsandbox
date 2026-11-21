export function paginate(items, requestedPage, pageSize) {
  const size = [10, 25, 50].includes(Number(pageSize)) ? Number(pageSize) : 10;
  const pages = Math.max(1, Math.ceil(items.length / size));
  const page = Math.max(1, Math.min(pages, Number(requestedPage) || 1));
  const offset = (page - 1) * size;
  return {
    items: items.slice(offset, offset + size),
    page,
    pages,
    start: items.length ? offset + 1 : 0,
    end: Math.min(offset + size, items.length),
    total: items.length,
  };
}
