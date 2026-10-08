import {WASI} from 'node:wasi';

/** A guest process exit, without terminating the Node test process. */
export class WasiExit extends Error {
  constructor(code) {
    super(`WASI process exited with code ${code}`);
    this.name='WasiExit';
    this.code=code;
  }
}

/**
 * Test-only Preview 1 host for a single wasm32 guest and its memory zero.
 * Pass imports to engine.load/loadBinary, then call start() or invoke().
 * Node WASI requires zero-origin native memory, so copy the guest image around
 * each syscall. Guest growth is tracked; create a fresh host after reload.
 */
export function createWasiHost(engine,options={}) {
  const wasi=new WASI({...options,version:'preview1',returnOnExit:true});
  const memory=new WebAssembly.Memory({initial:0});
  wasi.initialize({exports:{memory}});
  let pages=0,started=false;

  function synchronizeIn() {
    const current=engine.growMemory(0);
    if(current<pages) throw new Error('create a fresh WASI host after guest reload');
    if(current>pages) {
      memory.grow(current-pages);
      pages=current;
    }
    new Uint8Array(memory.buffer).set(engine.readMemory(0,pages*65536));
  }

  const namespace=Object.create(null);
  for(const [name,callback] of Object.entries(wasi.wasiImport)) {
    // Node's proc_exit sentinel is private; retain the code through wiw's host-error cause.
    namespace[name]=name==='proc_exit'
      ? code=>{throw new WasiExit(code>>>0);}
      : (...args)=>{
        synchronizeIn();
        try {return callback(...args);}
        finally {engine.writeMemory(0,new Uint8Array(memory.buffer));}
      };
  }

  function invoke(name,...args) {
    try {return engine.invoke(name,...args);}
    catch(error) {
      if(error.cause instanceof WasiExit) throw error.cause;
      throw error;
    }
  }

  return {
    imports:{wasi_snapshot_preview1:namespace},
    invoke,
    start() {
      if(started) throw new Error('WASI guest already started');
      started=true;
      try {invoke('_start');return 0;}
      catch(error) {
        if(error instanceof WasiExit) return error.code;
        throw error;
      }
    }
  };
}
