# 可复现的演示

这份文档的目标：**让评审在几分钟内跑起来，并自己验证结论**。

每一步都给出预期输出。**如果你得到的不一样，那就是有问题** —— 请提 Issue。

---

## 1. 环境

只需要 MoonBit 工具链，版本 `moon 0.1.20261012` 或更新：

```bash
# macOS / Linux
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
```

Windows 见 [moonbitlang.com/download](https://www.moonbitlang.com/download)。

**不需要 Python，不需要 numpy，不需要音频工具。**
所有测试语料（WAV 与 JSON）都已提交在仓库里，克隆下来就能跑。

---

## 2. 最短路径

```bash
git clone https://github.com/AYHEY001/roomacoustics.git
cd roomacoustics
moon update          # 全新环境的注册表索引为空，缺这步会报依赖找不到
moon test --deny-warn
```

预期输出（最后一行）：

```
Total tests: 51, passed: 51, failed: 0.
```

`moon update` 是必须的：它拉取注册表索引和两个依赖
（`Ridge-Lab/moonwavkit`、`chgttyyr/MoonSpectrum`）。
全新环境不做这步会报 `module was not found in the registry`。

---

## 3. 五个演示

### 3.1 从 WAV 脉冲响应算混响时间

```bash
moon run cmd/main -- decay -f testdata/ir_mono_0.8.wav
```

预期输出：

```
=== 衰减时间测量 ===
采样率    44100 Hz
样本数    110250  (2.50s)

噪声底    低于仪器分辨率（尾部已衰减到 0）

参数      值        备注
-------   ------    ----------------
EDT  0.800s   (斜率 -75.0 dB/s, 区间 10 dB, 5991 点)
T20  0.810s   (斜率 -74.0 dB/s, 区间 20 dB, 11788 点)
T30  0.806s   (斜率 -74.5 dB/s, 区间 30 dB, 17667 点)
```

这份语料的真值 T60 是 **0.8 s**，反演出的 T20 = 0.810 s，误差 1.3%。

这是**真实读 WAV**：文件是 44.1 kHz / 16-bit / 单声道的标准 RIFF/WAVE，
解析与 PCM 解码走 `Ridge-Lab/moonwavkit`。

想确认它真是合法 WAV，用任意播放器打开 `testdata/ir_mono_0.8.wav` 即可。

立体声也能读（自动下混）：

```bash
moon run cmd/main -- decay -f testdata/ir_stereo_0.8.wav
```

预期 T20 同样是 **0.810s** —— 与单声道文件逐位一致。

---

### 3.2 噪声污染时**拒绝给数字**（本项目最重要的行为）

```bash
moon run cmd/main -- decay -f testdata/noisy_snr20.json
```

预期输出：

```
=== 衰减时间测量 ===
采样率    44100 Hz
样本数    110250  (2.50s)

噪声底    -30.1 dB

参数      值        备注
-------   ------    ----------------
EDT  0.820s   (斜率 -73.4 dB/s, 区间 10 dB, 6195 点)
T20  不可用：评价区间落进噪声底 (余量 5.1 dB)，结果不可信 —— 建议延长测量或降噪
T30  不可用：评价区间落进噪声底 (余量 -4.9 dB)，结果不可信 —— 建议延长测量或降噪
```

**这里的关键不是它算出了什么，而是它拒绝了什么。**

同一份语料，跳过噪声校验会报 **T20 = 8.92 s** ——
真值只有 0.8 s，**偏差超过 11 倍**。原因是噪声底抬高 EDC 尾部，
把 -5~-25 dB 的拟合区间整个推进噪声里，斜率趋近于 0，
外推到 -60 dB 就得到一个巨大的假值。

这是 ISO 3382 要求"评价衰减区间须低于噪声底至少 20 dB"的物理原因。
本项目把这条校验做成**显式的失败**，而不是照报一个错数字。

想自己印证这个偏差，用 Python 参考实现（需要一个装好 numpy 的 Python）：

```bash
python _probe/physics_probe.py
```

它会打印各 SNR 下的反演结果，其中 `SNR= 20dB -> T20=9.0272s  误差+1028.40%`。

（注意这个 9.03 s 与上面语料的 8.92 s 略有差别 —— 探针用的是它自己合成的
另一份噪声信号，不是同一个文件。两者说明的是同一件事。）

---

### 3.3 解析式模态频率

```bash
moon run cmd/main -- modes --length 5 --width 4 --height 2.6 --count 8
```

预期输出：

```
=== 矩形房间模态频率 ===
房间尺寸  5.00 × 4.00 × 2.60 m
声速      343 m/s (20 °C 干空气)

频率 (Hz)  (nx,ny,nz)  类型
--------  ----------  ----
34.30    (1,0,0)     轴向
42.88    (0,1,0)     轴向
54.91    (1,1,0)     切向
65.96    (0,0,1)     轴向
68.60    (2,0,0)     轴向
74.35    (1,0,1)     切向
78.67    (0,1,1)     切向
80.90    (2,1,0)     切向
```

轴向基频 34.30 Hz = c/(2L) = 343/(2×5)。**手算可验。**

> 那个 1/2 是推导出来的：刚壁下法向速度为零，声压沿各轴呈 `cos(k·x)`，
> 极值条件 `k·L = n·π` 给出 `k = nπ/L`；代入 `k = 2πf/c` 约掉 π 即得
> `f = (c/2)·√((nx/Lx)²+…)`。
>
> 这个系数曾经写错过（少了个 1/2），当时连同自检脚本一起错，
> 测试全绿却输出 68.6 Hz。是对着下面 3.4 的实测频谱才发现的 ——
> 详见 [`NOTES.md`](NOTES.md) 的「模态公式少了 1/2」。

---

### 3.4 模态频率的实测交叉验证

这一步回答的问题是：**解析式算出来的模态，在实测响应里真的存在吗？**

```bash
moon run cmd/main -- modes --length 5 --width 4 --height 2.6 \
  --from-ir testdata/room_5x4x2.6_image_source.wav
```

预期输出（节选）：

```
实测频谱分析
  数据源    testdata/room_5x4x2.6_image_source.wav
  FFT 长度  65536（2 的幂；原信号 88200 点）
  分辨率    0.673 Hz

对照（峰 -> 最近的预测模态，容差 max(5Hz, 5%)）
峰 (Hz)   突出度   预测模态 (Hz)  阶次        偏差 (Hz)
--------  ------   -------------  ----------  ---------
   55.18    1.65           54.91  (1,1,0)         0.27
   67.96    5.42           68.60  (2,0,0)        -0.64
   87.48    3.34           85.82  (1,1,1)         1.66
  102.96    7.37          102.90  (3,0,0)         0.06
  133.91    7.02          133.95  (3,2,0)        -0.04
  ...
  297.43    2.38          297.39  (4,0,4)         0.04
  464.98    3.17          464.98  (1,1,7)        -0.00
  ...

配对率： 23/23 = 100%
```

**23 个检测到的峰全部对应上了解析式预测的模态**，多个偏差在 0.1 Hz 以内，
其中一个精确到 0.00 Hz。

图上看得更清楚：

![模态对照](docs/img/mode_comparison.png)

上方是传递函数（灰线）、预测模态位置（蓝虚线）、检测到的峰（红三角）；
下方是每个峰的偏差，绿带是容差 `max(5Hz, 5%)`。

**判定方向很重要**：判定的是「检测到的峰能否对应到预测模态」，
而不是「预测模态是否全部出现」。后者物理上做不到 ——
500 Hz 以下有数百个模态（密度随频率平方增长），
频谱里只有 23 个形成峰；声源或接收点若落在某模态的节面上，
该模态就不被激励。这是单点测量的固有局限，不是算法问题。

（上面的 CLI 输出末尾也会打印这段说明。）

---

### 3.5 Sabine 解析估算

```bash
moon run cmd/main -- sabine --length 5 --width 4 --height 2.6 --alpha 0.2
```

预期输出：

```
=== Sabine 估算 ===
房间尺寸  5.00 × 4.00 × 2.60 m
体积      52.00 m³
表面积    86.80 m²
吸声系数  0.200
RT60      0.482 s

注意：Sabine 假设声场完全扩散，与实测总有偏差。
     需要实测结果请用 decay 子命令。
```

手算可验：`RT60 = 0.161·V/(S·α) = 0.161×52/(86.8×0.2) = 0.482 s`。

---

## 4. 语料是怎么来的

`testdata/` 里的文件都由仓库内的脚本生成，可以重新跑：

| 文件 | 生成脚本 | 说明 |
|---|---|---|
| `ir_*.wav` | `docs/make_wav_testdata.py` | 16-bit PCM WAV，`wave` 标准库写出 |
| `clean_*.json`、`noisy_snr20.json` | `docs/make_testdata.py` | 浮点采样点，用于衰减测试 |
| `room_5x4x2.6_image_source.wav` | `docs/make_image_source_ir.py` | **镜像声源法**生成的房间响应 |
| `room_5x4x2.6_modes.json` | 同上 | 配对结果，供图与测试复用 |

其中**镜像声源法**那份是模态验证的前提：它不是"白噪声 × 指数包络"
那种人造信号（频谱平坦、不含模态信息），而是把墙面反射展开成
无穷多个镜像声源叠加起来，其传递函数的峰就是真实房间模态。

该脚本生成后会**自检**（Python 侧 FFT 检测峰 vs 解析式预测），
并硬断言轴向基频等于 `c/(2L)`。自检不过就不会往下走。

跑它需要装好 numpy 的 Python：

```bash
python docs/make_image_source_ir.py
```

---

## 5. 完整检查（与 CI 一致）

CI 跑的就是这几条（见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)）：

```bash
moon check --deny-warn
moon fmt --check
moon test --deny-warn
moon run cmd/main -- sabine --length 5 --width 4 --height 2.6 --alpha 0.2
moon run cmd/main -- modes --count 5
moon run cmd/main -- decay -f testdata/clean_0.8.json
moon run cmd/main -- decay -f testdata/ir_mono_0.8.wav
moon run cmd/main -- decay -f testdata/ir_stereo_0.8.wav
moon run cmd/main -- modes --from-ir testdata/room_5x4x2.6_image_source.wav
```

`--deny-warn` 表示把警告当错误。三项必须零警告通过。

---

## 6. 从零到现在的过程记录

开发过程中撞到的坑（MoonBit 语言、两个依赖库、CI、以及那个模态公式的 1/2）
都记在 [`NOTES.md`](NOTES.md)。里面包括若干"看起来对但其实是错的"情形，
以及是怎么被发现的。
