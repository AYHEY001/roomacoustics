# NOTES.md

开发过程中的实测记录。与提交给评委的材料无关，只为让后来的自己（或维护者）
知道"哪些结论是撞出来的，哪些是推出来的"。

---

## 2026-10-12 · 物理验证探针

在写 MoonBit 之前先跑了一遍 Python 探针，确认三块算法在解析层面成立。
结果全部通过，但探针自己先错了一次——记录如下。

### 坑 1：探针里的"手算核对"用了错的数字

第一次跑 `[1] Sabine`，输出 `一致=False`：

```
Sabine RT60 = 0.4823 s
手算核对   = 0.7995 s   一致=False
```

第一反应是"Sabine 实现错了"。实际是**核对基准写错了**：
Sabine 算的 0.4823 是对的（`0.161×52.0/(86.8×0.2)`），
但硬编码的对照值用了另一组数字（58.0 / 58.4），和上面的房间尺寸不同源。

修法：让手算表达式与被测变量同源，并把 `一致=False` 升级成 `assert`。
现在这行错了会直接抛异常，不会再让人误以为公式有问题。

**教训**：探针里的"期望值"如果和输入不是同源推导的，它本身就是不可信的。
这类错误比实现错误更危险——它会让人去修没坏的代码。

### 坑 2：噪声底会让 T20 严重失真

加性噪声扫描的结果很极端：

| SNR | 反演 T20 | 误差 |
|---|---|---|
| 60 dB | 0.8011 s | +0.13% |
| 40 dB | 0.8043 s | +0.54% |
| **20 dB** | **6.7656 s** | **+746%** |

20 dB 时不是"稍微偏了一点"，是**差了近 8 倍**。

原因：Schroeder 积分对全曲线做累积求和，噪声能量在尾部不断累加，
把 EDC 的底部**抬高变平**。直线拟合的 -5~-25 dB 区间一旦落进噪声底，
斜率就趋近于 0，外推到 -60 dB 会得到一个巨大的时间值。

这直接决定了产品设计：**工具必须报告噪声底，并且在校验区间触到噪声底时
明确告知结果不可信**，而不是照样吐一个 T20 数字让人以为测量成功了。
这正是 ISO 3382 要求"评价衰减区间至少低于噪声底 20 dB"的物理原因。

→ 已在 README 的边界一节写明这个约束，实现阶段要做成显式检查。

### 坑 3：采样率与时长几乎不影响 T20

16 kHz / 44.1 kHz / 48 kHz、1.5 s / 2.5 s / 4.0 s，误差都在 ±0.8% 以内。
说明 Schroeder 积分对采样率不敏感（它只做累加，不涉及频域运算）。
这与"本项目不实现 FFT"的边界一致——主算法确实不需要频谱。

→ 意味着采样率相关的边界情况不会成为实现难点。

---

## 2026-10-12 · 生态检索脚本

### 坑 4：裸子串匹配造出 4 个假阳性

`docs/check_ecosystem.py` 第一版用 `term in text` 做检索，报出 4 个"命中"：

```
[核心指标] 3 个模块命中
    OrisGo/nestedtext          <- edt
    Project2026-creator/moontemplate  <- t20
    yyqdbngt/moon_edtf          <- edt
[方法/公式] 1 个模块命中
    moonbitstack/moonrpc        <- edc
```

全是子串巧合：`nestedtext` 里含 `edt`、`moontemplate` 里含 `t20`、
`moonrpc` 里含 `edc`。改成词边界正则
（`(?<![a-z0-9])edt(?![a-z0-9])`）后归零。

**为什么这个坑必须记**：如果拿第一版结果去写差异化说明，
会写出"4 个模块涉及相关术语"——虽然不致命，但评委只要看一眼
`moon_edtf` 这个名字就能问倒，事实性主张一旦被质疑，整份说明的可信度都受影响。

**教训**：检索类脚本里，"没搜到"和"搜法不对"是两个完全不同的结论。
子串匹配是"搜法不对"的一种典型表现，而它输出的数字看起来和正确答案一模一样。

→ 脚本现在跑全量之前先过 9 条自检（3 正 6 负），任一条不符直接 `exit(1)`。

### 坑 5：自检样本自己也写错过一次

改词边界之后跑自检，出现 `[BAD] 假阳性：moonrpc 里的 edc: 命中=True`。
查下来是我的**样本写错了**——样本写成 `an rpc library with edc support`，
`edc` 在这里是独立成词的，按规则就该命中，是我把它写成了负样本。

差点误以为是新规则有问题。负样本必须真的含目标子串，才是有效负样本。

---

## 2026-10-12 · MoonBit 语法与测试 API（实测）

这批是写测试时连着踩的，与已有的 `moonbit-dev` skill 记录不重复：

### 坑 6：常量必须用 `const`，`let` 不能大写开头

```moonbit
pub let SOUND_SPEED : Double = 343.0     // ❌ Expected lower case identifier
pub const SOUND_SPEED : Double = 343.0  // ✅
```

报错信息会提示 `Did you mean const?`，但连带报一个 `SOUND_SPEED is unbound`，
容易让人以为是作用域问题。

### 坑 7：没有 `assert`，而且 `assert` 是保留字

```moonbit
assert(cond, "msg")                        // ❌ assert is unbound + reserved_keyword
assert_true(cond, "msg")                   // ❌ msg 是命名参数
assert_true(cond, msg="msg")               // ✅
```

核心库实际导出的是 `assert_true(Bool, msg? : StringView, loc~ : SourceLoc)`。
注意签名里 `msg` 带 `?`，是可选命名参数，不是第二个位置参数。

### 坑 8：不支持科学计数法字面量

`1e-9` / `1e-12` 全部解析失败，报 `Parse error, unexpected token id (lowercase start)` ——
因为 `1e` 被解析成了标识符。必须写全：`0.000000001`。

### 坑 9：README 文档测试需要 `///|` 标记 + `test` 块

代码块里不能直接写顶层语句。要写成：

````markdown
```mbt check
///|
test "说明文字" {
  inspect(x, content="...")
}
```
````

漏了 `///|` 或 `test` 会报 `Cannot infer the type of variable` 和一堆
莫名其妙的 parse error。

### 坑 10：`inspect` 对 Option 要用 `debug_inspect`

用 `inspect` 断言 `Option` 值会报
`Warning (deprecated): Use Debug instead of Show`。
用 `debug_inspect` 才不报。

### 坑 11：`content=` 支持通配吗？不支持，是精确匹配

想写 `content="68.6..."` 来容忍精度差异是**不行**的，输出
`Some(68.60000000000001)` 会直接失败。必须填精确值。

→ 顺带一个教训：我第一次是从探针输出里抄的期望值，抄错了小数位，
测试立刻变红才发现。这正是精确断言的价值——宽松断言会把我的错误藏起来。

### 坑 12：Double 的展示会省略小数部分

`Some(0.0)` 的实际输出是 `Some(0)`。写快照时别按直觉填。

---

## 待验证（进入实现阶段后补）

- 真实房间 IR 语料来源（需可公开、可复现分发）
- 评价区间的有效性判据怎么暴露给命令行用户
- 模态频率检测是否需要依赖 `MoonSpectrum` 的 FFT，还是解析式列举就够
  （当前实现倾向解析式列举 + 可选的 FFT 峰值交叉验证）
---

## 2026-10-12 · CI 排查（绕了五轮，值得记）

本地 `moon fmt --check` 通过，GitHub Actions 上却失败。查下来根因比预想的深。

### 坑 13：新版 moon fmt 有两处行为变化，不止一处

本机 `moon 0.1.20260920`，CI 装的是最新版 `0.1.20261012`。差异有：

1. `Int` 被规范化成 `Int32`
2. 超过 ~75 字符的参数列表**拆成多行**

只发现第1 处时，我写了三版脚本去"容忍"它 —— 方向就错了。
**差异本身会随工具链升级消失，正确做法是让代码跟上新版格式**，
而不是在 CI 里想办法忽略它。

### 坑 14：锁工具链版本这条路走不通

试过在 CI 里锁版本，两个障碍：
- `install/unix.sh` 的版本是**位置参数**（`version=${ARGUMENTS[0]}`），
  不是 `--version` 选项 —— 写成 `--version 0.1.x` 会被当未知参数，静默装最新版
- 历史版本二进制已从发布服务器清理，实测 `binaries/0.1.20260920/...` 返回
  **HTTP 403**，只有 `latest` 和 `nightly` 可下

### 坑 15：逐行配对统计出现次数来判"差异是否无害"，会数错

写"把 diff 两侧的 Int32 还原成 Int，再数每行出现次数是否为偶数"来判断无害差异，
结果同一行文本在文件里出现两次时（`sample_rate : Int,`）计数是 4，
次数稍不对称就误判成有害。**改成文件级归一化比对**才可靠。

教训：这类"配平"判断，别用计数，用整体比对。

### 坑 16：注释里提到 Int32 也会被还原，破坏比对

第二版里把 diff 两侧所有 `Int32` 还原成 `Int`，但注释里本来就解释过
"新版会把 Int 规范化成 Int32"—— 还原后与另一侧对不上，误判为有害。
最后干脆不做任何"无害判定"，直接统一到新版格式。

### 装新版工具链（Windows，隔离目录）

```bash
mkdir -p ~/.workbuddy/binaries/moonbit-latest && cd $_
curl -sL https://cli.moonbitlang.com/binaries/latest/moonbit-windows-x86_64.zip -o m.zip
unzip -o -q m.zip
# 标准库要单独下（老坑：官方包不含 lib/core）
curl -sL https://cli.moonbitlang.com/cores/core-latest.zip -o core.zip
unzip -o -q core.zip -d lib/core && mv lib/core/core/* lib/core/ && rmdir lib/core/core
cd lib/core && moon bundle --target wasm      # 漏这步每个项目都报 Cannot load the core file
```

之后 `export PATH="/c/Users/admin/.workbuddy/binaries/moonbit-latest/bin:$PATH"`
和 `export MOON_HOME="C:/Users/admin/.workbuddy/binaries/moonbit-latest"`，
**本项目的开发环境应该用这套新版**，旧版留着以防需要对比。

新版下 `moon test` 38/38 全绿，`moon fmt --check` 通过，
CI 全部 11 步 success。

### 其他踩到的

- 字符串插值必须写 `\{expr}`（反斜杠转义），写 `{expr}` 会被当普通字符。
  CLI 输出统一改用字符串拼接，避开这个坑。
- `Json` 类型不是 `pub`，外部包写不出 `@json.Json` 的类型标注，
  也用不了 `@json.Object(...)` 形式的模式匹配 —— 得用 `if j is Object(obj)`，
  且 `Number` 有两个字段，必须写 `Number(n, ..)`。
- `@lib` 是**包别名**不是"这是库"的标记，要显式命名：
  `"haiou/roomacoustics" @ra` → 源码里用 `@ra.foo()`。
