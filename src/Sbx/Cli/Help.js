export const configureArgs = () => {
  const separator=process.argv.indexOf('--');
  const limit=separator<0?process.argv.length:separator;
  const before=process.argv.slice(0,limit);
  if(before.includes('--no-color')){
    process.env.NO_COLOR='1';
    process.argv=[...before.filter(arg=>arg!=='--no-color'),...process.argv.slice(limit)];
  }
  return process.argv.length<=2 || before.includes('--help') || before.includes('-h');
};
