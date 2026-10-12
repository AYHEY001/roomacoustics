// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "haiou/roomacoustics"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = [ "acoustics", "audio", "reverberation", "impulse-response" ]

preferred_target = "wasm"

description = "Room acoustics measurements in MoonBit: compute reverberation time, energy decay curves and room modal frequencies from an impulse response."

import {
  "moonbitlang/x@0.5.5",
  "Ridge-Lab/moonwavkit@0.1.3",
  "chgttyyr/MoonSpectrum@0.2.2",
}
