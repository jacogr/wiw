// Independent per-lane integer model used by regression tests and checked benchmarks.
export const integerSimdCases=[];
for(const width of [8,16,32,64]) {
  const shape=`i${width}x${128/width}`;
  for(const relation of ['lt','gt','le','ge']) for(const sign of width===64?['s']:['s','u'])
    integerSimdCases.push({name:`${shape}.${relation}_${sign}`,width,kind:'compare',relation,sign});
  for(const operation of ['shl','shr_s','shr_u'])
    integerSimdCases.push({name:`${shape}.${operation}`,width,kind:'shift',operation});
  integerSimdCases.push({name:`${shape}.bitmask`,width,kind:'bitmask'});
  if(width<=16) {
    for(const operation of ['add','sub']) for(const sign of ['s','u'])
      integerSimdCases.push({name:`${shape}.${operation}_sat_${sign}`,width,kind:'saturate',operation,sign});
    for(const sign of ['s','u']) integerSimdCases.push({name:`${shape}.narrow_i${width*2}x${64/width}_${sign}`,width,kind:'narrow',sign});
  }
}
export const integerPatterns=[0n,1n,(1n<<128n)-1n,
  0x7fffffffffffffffffffffffffffffffn,0x80000000000000000000000000000000n,
  0x0123456789abcdeffedcba9876543210n,0xff807f0100fffeff800080007fffffffn];
const lane=(bits,width,index)=>BigInt.asUintN(width,bits>>BigInt(width*index));
const clamp=(value,width,sign)=>{
  const low=sign==='s'?-(1n<<BigInt(width-1)):0n;
  const high=sign==='s'?(1n<<BigInt(width-1))-1n:(1n<<BigInt(width))-1n;
  return value<low?low:value>high?high:value;
};
export function integerSimdExpected(spec,a,b=0n) {
  const {width,kind,sign,operation,relation}=spec,count=128/width;
  let result=0n;
  for(let i=0;i<count;i++) {
    const x=lane(a,width,i),y=kind==='shift'||kind==='bitmask'?0n:lane(b,width,i);
    let value;
    if(kind==='compare') {
      const left=sign==='s'?BigInt.asIntN(width,x):x,right=sign==='s'?BigInt.asIntN(width,y):y;
      const matched=relation==='lt'?left<right:relation==='gt'?left>right:relation==='le'?left<=right:left>=right;
      value=matched?-1n:0n;
    } else if(kind==='shift') {
      const shift=BigInt(Number(b)>>>0)%BigInt(width);
      value=operation==='shl'?x<<shift:operation==='shr_s'?BigInt.asIntN(width,x)>>shift:x>>shift;
    } else if(kind==='saturate') {
      const left=sign==='s'?BigInt.asIntN(width,x):x,right=sign==='s'?BigInt.asIntN(width,y):y;
      value=clamp(operation==='add'?left+right:left-right,width,sign);
    } else if(kind==='narrow') {
      const source=i<count/2?a:b,index=i%(count/2);
      value=clamp(BigInt.asIntN(width*2,lane(source,width*2,index)),width,sign);
    } else {
      result|=(x>>BigInt(width-1))<<BigInt(i);
      continue;
    }
    result|=BigInt.asUintN(width,value)<<BigInt(width*i);
  }
  return kind==='bitmask'?Number(result):result;
}
