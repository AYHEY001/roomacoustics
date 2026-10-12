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

---

## 2026-10-12 · 接入 moonwavkit

### moonwavkit 的实际坐标与 API

**不是 `moonbitlang/moonwavkit`，是 `Ridge-Lab/moonwavkit@0.1.3`。**
仓库 https://github.com/Ridge-Lab/MoonWavKit.git。

常用 API（读 `pkg.generated.mbti` 得到，不是猜的）：

```moonbit
parse_and_decode(Array[Int], options? : DecodeOptions) -> DecodeResult
downmix_to_mono(FloatBuffer) -> FloatBuffer

pub(all) struct FloatBuffer {
  channels : Int
  sample_rate : Int
  samples : Array[Double]
}
pub(all) struct DecodeResult {
  ok : Bool
  pcm : PcmBuffer
  float_buffer : FloatBuffer
  error : WavError
}
```

输入是 `Array[Int]`（每个元素一个字节），不是文件路径 —— 所以还得自己
用 `@fs.read_file_to_bytes` 读字节再转。

### 坑 17：`FloatBuffer::samples` 是**交错**的，不是每声道一个数组

立体声文件读进来：`channels=2`，`samples.length()=220500`。
**220500 = 110250 帧 × 2 声道**，也就是 `[L0,R0,L1,R1,...]` 交错排布。

不注意这一点就会踩坑：把一个 220500 长的交错数组当成 44100Hz 单声道信号，
时间轴凭空拉长一倍，衰减率减半，算出的 T20 会**正好翻倍**。
而且没有任何报错——数字看着很合理。

所以立体声必须先 `downmix_to_mono`。实测下混后 `samples.length()=110250`，
与单声道文件一致。

### 坑 18：注入了错误实现，但没确认注入是否生效 —— 白测一轮

验证"立体声测试是否真的有效"时，我用字符串替换把 `downmix_to_mono` 那段删掉，
跑测试 —— **44 个全绿**。第一反应是"测试是假的"。

实际原因是：**替换根本没匹配上**（代码经过 `moon fmt` 格式化，
缩进和我写的不一致），`print("已移除下混逻辑")` 照样执行了，
看起来像成功。

改成正则替换后再跑，测试立刻变红（`-110250 +220500`），
而且只有那一条红。

**教训**：注入错误之后要**确认注入生效**（`grep -c` 数一下目标字符串还在不在），
否则"测试没红"这个观察毫无意义 —— 它既可能是"测试没用"，
也可能是"改动没生效"。这两种情况的处理方式完全不同。

这条是对 skill 里"改了断言就把实现换回旧的验一遍"的补充：
换回去之后，还得回头看**换成功了没有**。

### 坏输入的实际表现（实测）

| 输入 | 输出 |
|---|---|
| 文本改后缀成 `.wav` | `WAV 解析失败：not-riff（expected RIFF signature）` |
| 截断的 WAV（前 100 字节） | `WAV 解析失败：chunk-out-of-bounds（chunk extends beyond...）` |
| 空文件 | `文件为空：<路径>` |
| 不存在的文件 | `读不了 <路径>：Failed to read file ... (os error 2)` |

`WavError` 有 `message` 字段，把它拼进错误信息比只报错误码有用得多。

### 量化噪声的一个观察

干净的合成 IR 经 16-bit PCM 量化后，尾部衰减到 10⁻⁹ 量级 → 取整后就是 0。
于是 `estimate_noise_floor` 返回 `None`，CLI 显示"噪声底低于仪器分辨率"。

**这是正常行为，不是 bug**：尾部确实没有可测噪声。
真实录音不会这样（总有环境噪声），所以噪声污染校验在真实场景下仍会生效。
一开始我把提示语写成"样本太少或信号全零"，容易让人误以为出错了，已改。

---

## 2026-10-12 · 接入 MoonSpectrum + 模态交叉验证

### 座标

`chgttyyr/MoonSpectrum@0.2.2`（不是 moonbitlang 官方）。
仓库 https://github.com/chgttyyr/MoonSpectrum

用到的 API：
```moonbit
fft(ArrayView[Complex]) -> Array[Complex] raise SpectrumError
ifft(ArrayView[Complex]) -> Array[Complex] raise SpectrumError
window(WindowKind, Int) -> Array[Double] raise SpectrumError
magnitude_spectrum(ArrayView[Complex]) -> Array[Double]
complex(re~ : Double, im~ : Double) -> Complex
```

注意这些是**抛异常**而不是返回 Result，所以要用 `catch`：
```moonbit
let w : Array[Double] = @msp.window(@msp.WindowKind::Hann, n) catch { _ => return }
```
枚举构造写 `@msp.WindowKind::Hann`（`@msp.WindowKind.Hann` 会解析失败）。

### 坑 19：`fft` 只接受 2 的幂长度

实测：1024 / 4096 / 16384 / 65536 / 131072 正常，
**88200 抛异常**（88200 = 2³×3²×5²×7²，不是 2 的幂）。

脉冲响应长度是任意的（采样率 × 秒数），所以必须先截断到
不大于它的最大 2 的幂。代价是丢掉尾部一点数据 + 分辨率变成
`sr / n_fft`（本项目 44100/65536 = 0.673 Hz），都要在输出里如实报告。

### 坑 20：幅度谱必须只取正频率半段

在**全长**上找最大值时，会取到负频率镜像 —— 因为实数信号的 FFT
关于 N/2 对称，`|X[k]| == |X[N-k]|`。浮点噪声决定哪个略大，
于是同一个 1000 Hz 正弦，在 n=16384/65536 时被报成 **43098 Hz**
（= 44100 - 1002，正好是镜像位置），在 1024/131072 时又是对的。
这种"有时对有时错"最难查。取前半段 `0..N/2` 即可。

### 坑 21：阈值不能用全局最大值 —— 直流分量会把它抬得极高

镜像声源法生成的 IR 求和不为零，0 Hz 的直流分量在幅度谱里
**高出低频段均值两个数量级**（实测 5.36 vs 0.038）。
用 `全局最大值 × 0.18` 当阈值，结果一个模态峰都检不出来（0 个）。

改用**局部中值基线**（窗口 161 bin）+ 相对阈值 1.5，
立刻检出 23 个峰。要先去掉直流（减均值）更稳。

### 交叉验证发现的边界差异（值得记）

MoonBit 侧第一版检出 21 个峰，Python 参考检出 23 个，
少的是两个贴着频段边界的弱峰（55 Hz、480 Hz）。
逐项排查后定位到三处实现细节不一致：

1. **频段下界的取整**：Python 的 `np.where(freqs >= lo)` 等价于 `ceil`，
   我用了 `to_int()`（截断/floor），多包含了一个 bin
2. **最小间距的取整**：Python 用 `round(8/0.673)` = 12，
   `to_int()` 截断得 11 —— 差 1 个 bin 足以改变"簇内合并"的判定
3. **局部基线的边界处理**：Python 先把频段内的点取成独立数组再
   `np.pad(mode="edge")`，复制的是**频段内**边缘值；
   我直接在完整频谱上 clamp，取到的是**频段外**的值

第 3 条是真正的原因（前两条改了之后仍是 21 个）。
三处对齐后，MoonBit 与 Python 完全一致：23 个峰逐位相同、21/23 配对。

**教训**：交叉验证的价值不只是"证明结果对"，更是**定位出自己都没意识到的
实现假设差异**。这三处里有两处如果没做对账，会一直留在代码里，
而且永远不会报错 —— 只会让边缘结果看起来"略有不同"。

### 一个物理事实（决定功能怎么表述）

镜像声源 IR 里，并非所有预测模态都出现在频谱上。
63 个预测模态中只有约 23 个在频谱里形成峰。
原因是**节面效应**：单点声源到单点接收的传递函数里，
若声源或接收点落在某模态的节面上，该模态不被激励。

所以验证方向必须是「**检测到的峰能否对应到预测模态**」，
而不是「预测模态是否全部被检测到」—— 后者物理上做不到，
硬按那个方向写会得到一个永远失败的功能。

### Hann 窗的定义（确认过，与 numpy 一致）

MoonSpectrum 的 `Hann(8)` = 0/188/611/950/950/611/188/0（千分位），
与 `numpy.hanning(8)` 的对称窗 `0.5-0.5cos(2πn/(N-1))` 相同。
（有些库的 Hann 是周期窗 `2πn/N`，那会不一样 —— 这个坑没踩到，
但值得知道怎么快速验。）
