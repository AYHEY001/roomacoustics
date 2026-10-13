# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## 分层约定（不要打破）

核心库 `haiou/roomacoustics`（`moon.pkg` 在仓库根）**只做数值计算**：

- 依赖**恰好**是 `moonbitlang/core/{math,double,debug}`，不加别的
- 公开接口只接受 `Array[Double]` 采样点 + 采样率，不绑定数据源
- 不碰文件、不解析格式、不做 FFT

WAV 读取（`Ridge-Lab/moonwavkit`）与 FFT（`chgttyyr/MoonSpectrum`）
都放在 CLI 层 `cmd/main/`，不进核心库。

**为什么**：这条分层是本项目「边界可核对」这一主张的支撑。核心库不依赖
I/O 与频谱库，意味着它的正确性可以用纯数值测试覆盖，也意味着替换数据源
不影响分析逻辑。一旦有人往核心库 import 一个 I/O 库，这个主张就失效了。

**怎么守住**：`docs/check_layering.py` 断言核心库依赖恰好等于白名单，
已接入 CI。它自带自检（喂越界样本确认会被拒），不是靠自律。
若确实需要给核心库加依赖，先改白名单并说明理由，别绕开。

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
