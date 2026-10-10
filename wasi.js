import {WASI} from 'node:wasi';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {createInterpreter,createBootstrapInterpreter} from './wiw.js';

/** A guest exit status that never terminates the embedding Node process. */
export class WasiExit extends Error {
  constructor(code) {
    super(`WASI process exited with code ${code>>>0}`);
    this.name='WasiExit';
    this.code=code>>>0;
  }
}

function exitError(error) {
  const seen=new Set();
  for(let cause=error;cause instanceof Error&&!seen.has(cause);cause=cause.cause) {
    if(cause instanceof WasiExit)return cause;
    seen.add(cause);
  }
  return error;
}

/** Preview 1 imports for one wasm32 guest. Standard streams are borrowed descriptors. */
export function createWasiHost(engine,options={}) {
  const {memory:selector='memory',args=[],env={},preopens={},stdin=0,stdout=1,stderr=2,...unknown}=options;
  if(Object.keys(unknown).length)throw new Error(`unknown WASI option ${Object.keys(unknown)[0]}`);
  const wasi=new WASI({args,env,preopens,stdin,stdout,stderr,version:'preview1',returnOnExit:true});
  const memory=new WebAssembly.Memory({initial:0});
  wasi.initialize({exports:{memory}});
  const descriptors=new Map([[0,false],[1,false],[2,false],...Object.keys(preopens).map((_,i)=>[i+3,true])]);
  let generation,pages=0,phase='fresh',closed=false,active=0;

  function bind() {
    if(closed)throw new Error('WASI host is closed');
    if(generation!==undefined&&generation!==engine.generation)throw new Error('create a fresh WASI host after guest reload');
    if(engine.memoryType(selector)!=='i32')throw new Error('WASI Preview 1 requires wasm32 memory');
    generation=engine.generation;
  }
  function synchronizeIn() {
    bind();
    const current=engine.memoryPages(selector);
    if(current>pages)memory.grow(current-pages);
    pages=current;
    new Uint8Array(memory.buffer).set(engine.readMemory(0,pages*65536,selector));
  }
  function descriptorEffect(name,arguments_,result) {
    if(result!==0)return;
    if(name==='path_open'||name==='sock_accept') {
      const pointer=arguments_[name==='path_open'?8:2]>>>0;
      descriptors.set(new DataView(memory.buffer).getUint32(pointer,true),true);
    }
    if(name==='fd_close')descriptors.delete(arguments_[0]>>>0);
    if(name==='fd_renumber') {
      const from=arguments_[0]>>>0,to=arguments_[1]>>>0;
      if(from!==to){const owned=descriptors.get(from);descriptors.delete(from);descriptors.set(to,owned);}
    }
  }
  const namespace=Object.create(null);
  for(const [name,callback] of Object.entries(wasi.wasiImport)) {
    namespace[name]=(...arguments_)=>{
      bind();
      if(name==='proc_exit')throw new WasiExit(arguments_[0]);
      synchronizeIn();
      active++;
      try {
        // WASI i32 parameters are unsigned; Node’s JavaScript binding needs the same bits as its native Wasm path.
        const result=callback(...arguments_.map(value=>typeof value==='number'?value>>>0:value));
        descriptorEffect(name,arguments_,result);
        return result;
      } finally {try{engine.writeMemory(0,new Uint8Array(memory.buffer),selector);}finally{active--;}}
    };
  }
  function invoke(name,...arguments_) {
    bind();active++;
    try{return engine.invoke(name,...arguments_);}catch(error){throw exitError(error);}finally{active--;}
  }
  async function invokeAsync(name,...arguments_) {
    bind();active++;
    try{return await engine.invokeAsync(name,...arguments_);}catch(error){throw exitError(error);}finally{active--;}
  }
  function begin(mode) {
    bind();
    if(phase!=='fresh')throw new Error('WASI guest already started or initialized');
    const exports=engine.exportNamespace();
    const name=mode==='command'?'_start':'_initialize';
    if(Object.hasOwn(exports,mode==='command'?'_initialize':'_start'))throw new Error(`WASI ${mode} has an incompatible entry point`);
    const present=Object.hasOwn(exports,name);
    if(mode==='command'||present) {
      const signature=engine.signature(name);
      if(signature.params.length||signature.result!==null)throw new Error(`WASI ${name} must have no parameters or results`);
    }
    phase=mode;
    return present?name:undefined;
  }
  return Object.freeze({
    imports:Object.freeze({wasi_snapshot_preview1:Object.freeze(namespace)}),
    invoke,invokeAsync,
    start() {
      const name=begin('command');
      try{invoke(name);return 0;}catch(error){if(error instanceof WasiExit)return error.code;throw error;}
    },
    async startAsync() {
      const name=begin('command');
      try{await invokeAsync(name);return 0;}catch(error){if(error instanceof WasiExit)return error.code;throw error;}
    },
    initialize(){const name=begin('reactor');if(name)invoke(name);},
    async initializeAsync(){const name=begin('reactor');if(name)await invokeAsync(name);},
    close() {
      if(closed)return;
      if(active)throw new Error('WASI host is active');
      closed=true;
      const failures=[];
      for(const [fd,owned] of descriptors)if(owned) {
        try{const errno=wasi.wasiImport.fd_close(fd);if(errno&&errno!==8)failures.push(new Error(`WASI fd_close ${fd}: errno ${errno}`));}
        catch(error){failures.push(error);}
      }
      descriptors.clear();
      if(failures.length)throw new AggregateError(failures,'WASI descriptor cleanup failed');
    }
  });
}

/** Load WAT or Wasm with fresh Preview 1 imports; the caller owns the returned host. */
export async function loadWasi(source,options={}) {
  const {runtime='wat',fuel=100_000_000n,limits,parentLimits,parentFuel,imports={},mode,...hostOptions}=options;
  if(!['wat','wasm'].includes(runtime))throw new Error('WASI runtime must be wat or wasm');
  if(mode!==undefined&&!['command','reactor'].includes(mode))throw new Error('WASI mode must be command or reactor');
  const engine=await (runtime==='wasm'?createBootstrapInterpreter:createInterpreter)(undefined,{limits,parentLimits,parentFuel});
  engine.setFuel64(fuel);
  const host=createWasiHost(engine,hostOptions);
  try {
    if(Object.hasOwn(imports,'wasi_snapshot_preview1'))throw new Error('additional imports cannot replace WASI Preview 1');
    const bindings={...imports,...host.imports};
    if(source instanceof Uint8Array) {
      if(source[0]===0&&source[1]===97&&source[2]===115&&source[3]===109)await engine.loadBinaryAsync(source,bindings);
      else await engine.loadAsync(new TextDecoder('utf-8',{fatal:true}).decode(source),bindings);
    } else if(typeof source==='string')await engine.loadAsync(source,bindings);
    else throw new Error('WASI source must be WAT text or a Uint8Array');
    return {engine,host};
  }catch(error){host.close();throw exitError(error);}
}

/** Execute a command or initialize a reactor, returning its unsigned exit code and closing owned descriptors. */
export async function runWasi(source,options={}) {
  let host;
  try {
    ({host}=await loadWasi(source,options));
    if(options.mode==='reactor'){await host.initializeAsync();return 0;}
    return await host.startAsync();
  }catch(error){if(error instanceof WasiExit)return error.code;throw error;}
  finally{host?.close();}
}

const usage=`Usage: node wasi.js [options] <guest.wat|guest.wasm> [--] [guest arguments...]
  --runtime wat|wasm   Self-hosted (default) or compiled interpreter
  --bootstrap          Alias for --runtime wasm
  --fuel INTEGER       Per-invocation fuel (default 100000000)
  --env NAME=VALUE     Guest environment entry; repeatable
  --dir GUEST=HOST     Preopened directory mapping; repeatable
  --reactor            Initialize _initialize instead of invoking _start
  --help               Show usage
Arguments include the guest filename as argv[0]. Environment and preopens default to empty.`;

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  try {
    const arguments_=process.argv.slice(2),options={env:Object.create(null),preopens:Object.create(null)};
    let file;
    while(arguments_.length) {
      const argument=arguments_.shift();
      if(argument==='--help'){console.log(usage);break;}
      if(argument==='--'){file=arguments_.shift();break;}
      if(argument==='--bootstrap'){options.runtime='wasm';continue;}
      if(argument==='--reactor'){options.mode='reactor';continue;}
      if(['--runtime','--fuel','--env','--dir'].includes(argument)) {
        const value=arguments_.shift();if(value===undefined)throw new Error(`missing value for ${argument}`);
        if(argument==='--runtime')options.runtime=value;
        else if(argument==='--fuel') {if(!/^\d+$/.test(value))throw new Error('fuel must be an unsigned integer');options.fuel=BigInt(value);}
        else {
          const split=value.indexOf('=');if(split<1)throw new Error(`${argument} requires NAME=VALUE`);
          const key=value.slice(0,split),content=value.slice(split+1);
          if(argument==='--dir'&&!content)throw new Error('--dir requires a host directory');
          options[argument==='--env'?'env':'preopens'][key]=content;
        }
        continue;
      }
      if(argument.startsWith('-'))throw new Error(`unknown option ${argument}`);
      file=argument;break;
    }
    if(file) {
      if(arguments_[0]==='--')arguments_.shift();
      options.args=[file,...arguments_];
      process.exitCode=(await runWasi(await readFile(file),options))&255;
    }else if(!process.argv.slice(2).includes('--help'))throw new Error(usage);
  }catch(error){console.error(error instanceof Error?error.message:error);process.exitCode=1;}
}
