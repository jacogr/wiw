// Strict floating SIMD operations checked against independent native guest Wasm.
export const floatOperations=[
  {
    "name": "f32x4.eq",
    "inputs": 2
  },
  {
    "name": "f32x4.ne",
    "inputs": 2
  },
  {
    "name": "f32x4.lt",
    "inputs": 2
  },
  {
    "name": "f32x4.gt",
    "inputs": 2
  },
  {
    "name": "f32x4.le",
    "inputs": 2
  },
  {
    "name": "f32x4.ge",
    "inputs": 2
  },
  {
    "name": "f64x2.eq",
    "inputs": 2
  },
  {
    "name": "f64x2.ne",
    "inputs": 2
  },
  {
    "name": "f64x2.lt",
    "inputs": 2
  },
  {
    "name": "f64x2.gt",
    "inputs": 2
  },
  {
    "name": "f64x2.le",
    "inputs": 2
  },
  {
    "name": "f64x2.ge",
    "inputs": 2
  },
  {
    "name": "f32x4.ceil",
    "inputs": 1
  },
  {
    "name": "f32x4.floor",
    "inputs": 1
  },
  {
    "name": "f32x4.trunc",
    "inputs": 1
  },
  {
    "name": "f32x4.nearest",
    "inputs": 1
  },
  {
    "name": "f64x2.ceil",
    "inputs": 1
  },
  {
    "name": "f64x2.floor",
    "inputs": 1
  },
  {
    "name": "f64x2.trunc",
    "inputs": 1
  },
  {
    "name": "f64x2.nearest",
    "inputs": 1
  },
  {
    "name": "f32x4.abs",
    "inputs": 1
  },
  {
    "name": "f32x4.neg",
    "inputs": 1
  },
  {
    "name": "f32x4.sqrt",
    "inputs": 1
  },
  {
    "name": "f32x4.add",
    "inputs": 2
  },
  {
    "name": "f32x4.sub",
    "inputs": 2
  },
  {
    "name": "f32x4.mul",
    "inputs": 2
  },
  {
    "name": "f32x4.div",
    "inputs": 2
  },
  {
    "name": "f32x4.min",
    "inputs": 2
  },
  {
    "name": "f32x4.max",
    "inputs": 2
  },
  {
    "name": "f32x4.pmin",
    "inputs": 2
  },
  {
    "name": "f32x4.pmax",
    "inputs": 2
  },
  {
    "name": "f64x2.abs",
    "inputs": 1
  },
  {
    "name": "f64x2.neg",
    "inputs": 1
  },
  {
    "name": "f64x2.sqrt",
    "inputs": 1
  },
  {
    "name": "f64x2.add",
    "inputs": 2
  },
  {
    "name": "f64x2.sub",
    "inputs": 2
  },
  {
    "name": "f64x2.mul",
    "inputs": 2
  },
  {
    "name": "f64x2.div",
    "inputs": 2
  },
  {
    "name": "f64x2.min",
    "inputs": 2
  },
  {
    "name": "f64x2.max",
    "inputs": 2
  },
  {
    "name": "f64x2.pmin",
    "inputs": 2
  },
  {
    "name": "f64x2.pmax",
    "inputs": 2
  },
  {
    "name": "f32x4.demote_f64x2_zero",
    "inputs": 1
  },
  {
    "name": "f64x2.promote_low_f32x4",
    "inputs": 1
  },
  {
    "name": "i32x4.trunc_sat_f32x4_s",
    "inputs": 1
  },
  {
    "name": "i32x4.trunc_sat_f32x4_u",
    "inputs": 1
  },
  {
    "name": "f32x4.convert_i32x4_s",
    "inputs": 1
  },
  {
    "name": "f32x4.convert_i32x4_u",
    "inputs": 1
  },
  {
    "name": "i32x4.trunc_sat_f64x2_s_zero",
    "inputs": 1
  },
  {
    "name": "i32x4.trunc_sat_f64x2_u_zero",
    "inputs": 1
  },
  {
    "name": "f64x2.convert_low_i32x4_s",
    "inputs": 1
  },
  {
    "name": "f64x2.convert_low_i32x4_u",
    "inputs": 1
  }
];
