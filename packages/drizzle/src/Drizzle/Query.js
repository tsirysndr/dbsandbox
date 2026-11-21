export const selectImpl = db => table => condition => () => db.select().from(table).where(condition).all();
export const upsertImpl = db => table => row => () => { db.insert(table).values(row).onConflictDoUpdate({target:Object.values(table).find(column=>column?.primary===true),set:row}).run(); };
export const deleteWhere = db => table => condition => () => { db.delete(table).where(condition).run(); };
