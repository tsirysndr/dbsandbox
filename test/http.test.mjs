import {test, expect} from 'bun:test';
import {createServer} from 'node:http';
import {parse,request,healthy,client} from '../output/Sbx.Net.Http/index.js';
import {Left} from '../output/Data.Either/index.js';
import {profile as typesense} from '../output/Sbx.Database.Typesense/index.js';
import {profile as chroma} from '../output/Sbx.Database.Chroma/index.js';
import {profile as mysql} from '../output/Sbx.Database.MySQL/index.js';
import {find} from '../output/Sbx.Database.Profiles/index.js';
import {promise} from './support/aff.mjs';

test('HTTP requests stay on the selected sandbox and validate methods and arguments',()=>{
  expect(parse(['/health']).value0).toEqual({method:'GET',path:'/health',body:''});
  expect(parse(['post','/collections','{}']).value0.method).toBe('POST');
  for(const args of [[],['https://elsewhere'],['//elsewhere'],['/\\elsewhere'],['TRACE','/'],['GET','/','a','b']]) expect(parse(args)).toBeInstanceOf(Left);
});

test('API profiles separate MySQL from MariaDB and keep tokens out of URLs and commands',()=>{
  expect(find('mysql').value0.profile.product).toBe('MySQL');
  expect(mysql.env({user:'app',password:'secret',db:'demo'})).toEqual({MYSQL_ROOT_PASSWORD:'secret',MYSQL_DATABASE:'demo',MYSQL_USER:'app',MYSQL_PASSWORD:'secret'});
  expect(mysql.env(mysql.defaults).MYSQL_USER).toBeUndefined();
  expect(mysql.command('8.4').value0).toContain('--skip-log-bin');
  expect(mysql.ready({})('8.4')(mysql.defaults).join(' ')).toContain('SELECT 1');
  expect(typesense.http.value0.headers({password:'secret'})).toEqual({'X-TYPESENSE-API-KEY':'secret'});
  expect(typesense.url('30.2')({password:'secret'})(8108)).not.toContain('secret');
  expect(mysql.linuxOnly).toBe(false);
  const uri=new URL(mysql.url('8.4')({user:'a@b',password:'quote\'and\\slash:/@',db:'my db'})(3306));
  expect(decodeURIComponent(uri.password)).toBe('quote\'and\\slash:/@');
  expect(decodeURIComponent(uri.pathname.slice(1))).toBe('my db');
  for(const p of [typesense,chroma]) {expect(p.dataDir({})).toBe('/data');expect(p.linuxOnly).toBe(true);expect(p.dialect).toBe('');}
  expect(chroma.http.value0.headers({password:''})).toEqual({});
});

test('HTTP I/O sends auth and JSON, reports errors, refuses redirects and times out',async()=>{
  let redirected=false;
  const server=createServer(async(req,res)=>{
    if(req.url==='/slow') return;
    if(req.url==='/redirect'){res.writeHead(302,{location:'/leak'});return res.end();}
    if(req.url==='/leak') redirected=true;
    if(req.headers['x-typesense-api-key']!=='secret'){res.writeHead(401);return res.end('denied');}
    let body='';for await(const chunk of req)body+=chunk;
    res.end(JSON.stringify({method:req.method,body:body&&JSON.parse(body)}));
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const base=`http://127.0.0.1:${server.address().port}`,headers={'X-TYPESENSE-API-KEY':'secret'};
  try{
    const r=await promise(request(base)(headers)({method:'POST',path:'/collections',body:'{"name":"demo"}'})(1000));
    expect(JSON.parse(r.body)).toEqual({method:'POST',body:{name:'demo'}});
    expect(await promise(healthy(base)(headers))).toBe(true);
    expect(await promise(healthy(base)({}))).toBe(false);
    expect(await promise(client(base)({})(['/collections']))).toBe(1);
    expect((await promise(request(base)(headers)({method:'GET',path:'/redirect',body:''})(1000))).status).toBe(302);
    expect(redirected).toBe(false);
    await expect(promise(request(base)(headers)({method:'GET',path:'/slow',body:''})(30))).rejects.toThrow();
  }finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
});
