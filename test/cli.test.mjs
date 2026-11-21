import { test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { all } from '../output/Sbx.Profiles/index.js';
import { instanceName } from '../output/Sbx.Identity/index.js';
const run = (args, env={}) => spawnSync(process.execPath, ['bin/dbsandbox.js', ...args], {
  encoding:'utf8', timeout:10000, env:{...process.env,BSDKRUN_BIN:'/nonexistent/bsdkrun',BSDKRUN_NO_AUTO_INSTALL:'1',...env},
});

test('one CLI exposes all database profiles and version without a VM runtime', () => {
  expect(run(['--version']).stdout.trim()).toBe('dbsandbox 0.1.0');
  const help=run(['--help']); expect(help.status,help.stderr).toBe(0);
  for (const {name} of all) expect(help.stdout).toContain(name);
  for (const alias of ['postgresql','pg','mysql','libsql']) expect(run([alias,'--help']).status).toBe(0);
  expect(run(['unknown','start']).status).not.toBe(0);
});

for (const {name,profile} of all) {
  test(`${name}: capabilities and SQL argument forwarding appear in help`, () => {
    const help=run([name,'--help']); expect(help.status,help.stderr).toBe(0);
    for (const cmd of ['start','stop','branch','checkout','status','--branch']) expect(help.stdout).toContain(cmd);
    expect(help.stdout.includes('token')).toBe(profile.hasToken);
    expect(help.stdout.includes('studio')).toBe(profile.dialect !== '');
    expect(help.stdout.includes('migrate')).toBe(name==='postgres');
    expect(run([name,profile.clientName,'--help']).status).toBe(0);
    expect(run([name,'branch','--help']).stdout).toContain('--port');
  });
  test(`${name}: existing state and branch selection are adopted without booting or rewriting data`, () => {
    const dir=mkdtempSync(join(tmpdir(),'dbsandbox-adopt-')), tool=profile.tool;
    const state={os:'linux',version:profile.defaultTag,port:profile.guestPort+10000,user:'app',password:'unit-password',db:'demo',branch:'main',cpus:2,mem:1024};
    const child=instanceName(tool)('feature'), next={...state,port:state.port+1,branch:'feature'};
    try {
      mkdirSync(join(dir,tool)); mkdirSync(join(dir,child));
      const original=JSON.stringify(state);
      writeFileSync(join(dir,tool,'state.json'),original);
      writeFileSync(join(dir,child,'state.json'),JSON.stringify(next));
      writeFileSync(join(dir,tool,'branches.json'),JSON.stringify([{name:'feature',tool:child,running:false}]));
      writeFileSync(join(dir,tool,'active.json'),JSON.stringify('feature'));
      const env={XDG_CONFIG_HOME:dir};
      const expected=profile.url(state.version)({user:state.user,password:state.password,db:state.db});
      expect(run([name,'url'],env).stdout.trim()).toBe(expected(next.port));
      expect(run([name,'--branch','main','url'],env).stdout.trim()).toBe(expected(state.port));
      expect(run([name,'checkout','main'],env).status).toBe(0);
      expect(run([name,'url'],env).stdout.trim()).toBe(expected(state.port));
      expect(readFileSync(join(dir,tool,'state.json'),'utf8')).toBe(original);
      if (profile.hasToken) expect(run([name,'token'],env).stdout.trim()).toBe(state.password);
    } finally {rmSync(dir,{recursive:true,force:true});}
  });
}

test('unsupported versions and platforms fail before touching the VM runtime', () => {
  const dir=mkdtempSync(join(tmpdir(),'dbsandbox-invalid-'));
  try {
    const env={XDG_CONFIG_HOME:dir};
    for (const args of [['duckdb','start','linux','1.5.6'],['duckdb','start','--port','0'],['duckdb','start','--password','bad'],['sqlite','start','freebsd']]) {
      const r=run(args,env); expect(r.status).not.toBe(0); expect(r.stderr).not.toContain('ENOENT');
    }
  } finally {rmSync(dir,{recursive:true,force:true});}
});
