export const execute = db => query => () => { db.run(query); };
export const all = db => query => () => db.all(query);
export const transaction = db => action => () => db.transaction(tx => action(tx)(), {behavior:'immediate'});
