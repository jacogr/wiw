import {createBootstrapInterpreter,createInterpreter as createHostedInterpreter} from '../wiw.js';

// Select only test execution; the public API and production default remain unchanged.
export const testMode=process.env.WIW_TEST_RUNTIME ?? 'wat';
if(!['wat','wasm'].includes(testMode)) throw new Error(`invalid WIW_TEST_RUNTIME: ${testMode}; expected wat or wasm`);
export const interpreted=testMode==='wat';
export const createInterpreter=interpreted?createHostedInterpreter:createBootstrapInterpreter;
// Each CI target executes the shared cases once at its selected runtime level.
export const runtimeNames=[interpreted?'interpreted':'bootstrap'];
export const runtimeFactories=[[runtimeNames[0],createInterpreter]];
export * from '../wiw.js';
