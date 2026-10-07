import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFileSync} from 'node:child_process';
import {cp,mkdtemp,readFile,rm,utimes,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

test('build mode switches rebuild binary and hosted WAT together regardless of timestamp ordering',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'wiw-build-mode-'));
  try {
    await cp(new URL('../Makefile',import.meta.url),join(directory,'Makefile'));
    await cp(new URL('../wat/',import.meta.url),join(directory,'wat'),{recursive:true});
    await cp(new URL('../scripts/',import.meta.url),join(directory,'scripts'),{recursive:true});
    // Lightweight tool doubles carry the selected mode through every real Makefile stage.
    const tool=join(directory,'tool.cjs');
    await writeFile(tool,`
      const fs=require('node:fs');
      const [kind,...args]=process.argv.slice(2);
      fs.appendFileSync('calls.jsonl',JSON.stringify({kind,args})+'\\n');
      if(kind==='m4') process.stdout.write(JSON.stringify({mode:args.includes('-DDEBUG')?'debug':'release'}));
      else {
        const input=args.find(arg=>arg.endsWith(kind==='wat2wasm'?'.wat':'.wasm'));
        const value=JSON.parse(fs.readFileSync(input,'utf8'));
        if(kind==='wasm-opt' && args.includes('--print-minified')) process.stdout.write(JSON.stringify(value));
        else {
          if(kind==='wasm-opt') value.optimization=args.find(arg=>/^-O[0-4]$/.test(arg));
          fs.writeFileSync(args[args.indexOf('-o')+1],JSON.stringify(value));
        }
      }
    `);
    const quote=value=>"'"+value.replaceAll("'","'\\''")+"'";
    const command=`${quote(process.execPath)} ${quote(tool)}`;
    const build=debug=>execFileSync('make',[
      `DEBUG=${debug}`,`M4=${command} m4`,`WAT2WASM=${command} wat2wasm`,
      `WASM_OPT=${command} wasm-opt`,'all'
    ],{cwd:directory,stdio:'pipe'});
    const artifacts=['wiw.wat','wiw.wasm','wiw-opt.wasm','wiw-opt.wat'];
    const check=async(mode,optimization)=>{
      for(const artifact of artifacts) {
        const value=JSON.parse(await readFile(join(directory,'build',artifact),'utf8'));
        assert.equal(value.mode,mode,artifact);
        if(artifact.startsWith('wiw-opt')) assert.equal(value.optimization,optimization,artifact);
      }
    };
    // Equal future timestamps defeat any rebuild that relies only on a newer flags-file mtime.
    const freeze=async()=>{
      const time=new Date(Math.floor(Date.now()/1000)*1000+600000);
      for(const file of ['flags',...artifacts]) await utimes(join(directory,'build',file),time,time);
    };
    build(0);await check('release','-O4');
    await freeze();build(1);await check('debug','-O0');
    await freeze();build(0);await check('release','-O4');
    const before=await readFile(join(directory,'calls.jsonl'),'utf8');
    await freeze();build(0);await check('release','-O4');
    assert.equal(await readFile(join(directory,'calls.jsonl'),'utf8'),before,'unchanged flags must not rerun build tools');
    assert.equal(before.trim().split('\n').length,12,'each mode requires expansion, compilation, optimization and text emission');
  } finally {
    await rm(directory,{recursive:true,force:true});
  }
});
