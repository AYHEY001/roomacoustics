# roomacoustics 项目申报书

**基本信息**

- 项目名称：roomacoustics：MoonBit 房间声学测量库
- 参赛者：欧海翔（GitHub：AYHEY001）
- 联系方式：202411590906@stu.blcu.edu.cn
- GitHub 仓库链接：https://github.com/AYHEY001/roomacoustics
- 项目方向：MoonBit 声学与信号衰减分析基础库
- 是否为移植项目：否

**项目简介**

roomacoustics 用 MoonBit 实现房间声学测量的核心计算：从一段脉冲响应得到混响时间、能量衰减曲线和房间模态频率。面向需要评估空间声学特性的开发者，也适用于需要从衰减信号里取参数的信号处理场景。

房间声学测量有个不易察觉的失败：录音里的环境噪声会抬高能量衰减曲线的尾部，把拟合区间推进噪声里，斜率随之趋近于零。外推到 -60 dB 时，同一个房间算出的混响时间可以从 0.8 秒变成 8.9 秒，而计算过程不会报错。多数工具照样输出这个数字。本项目把 ISO 3382 对评价区间的要求做成显式失败：噪声底不足时拒绝给出数值，并指出未通过的是哪一项校验。

技术上还有一层交叉验证：解析式预测的模态频率，在实测频谱里是否真的存在。验证用的是镜像声源法生成的房间响应。同时用对照实验量出了这个验证方法自身的判别力边界，数据写在 README 里。

**核心功能范围**

- Schroeder 能量衰减曲线（EDC）反演，对脉冲响应平方做后向累积；
- EDT / T20 / T30 拟合，按 ISO 3382 规定区间做最小二乘，外推到 -60 dB；
- 噪声底估计，评价区间落入噪声底时返回失败原因，不返回数值；
- Sabine 公式估算 RT60，参数非法时返回 `None` 而非 `inf`；
- 矩形房间模态频率闭式解，区分轴向、切向、斜向模态；
- 模态频率的实测交叉验证：对脉冲响应做 FFT 检测谱峰，与解析式预测逐个配对；
- 命令行工具三个子命令：`decay`（衰减时间）、`modes`（模态频率）、`sabine`（Sabine 估算）；
- 直接读取 WAV（含立体声下混）与 JSON 两种格式的脉冲响应；
- 参数非法时明确报错，不静默按 0 处理；
- 65 个回归测试，含测试有效性验证；
- 可复现的演示说明（`DEMO.md`）与两个独立验证探针。

**边界与依赖**

不实现 WAV 解析，不实现 FFT。这两件事交给生态里已有的库：

| 环节 | 依赖 | 许可证 |
|---|---|---|
| WAV 容器解析与 PCM 解码 | `Ridge-Lab/moonwavkit@0.1.3` | 见该库 |
| FFT 与窗函数 | `chgttyyr/MoonSpectrum@0.2.2` | 见该库 |

核心库 `haiou/roomacoustics` 只依赖标准库的 `math`、`double`、`debug`。接口只接受 `Array[Double]` 采样点与采样率，不绑定数据源，I/O 与频谱处理放在 CLI 层（`cmd/main/`）。

这条分层由 CI 里的断言脚本 `docs/check_layering.py` 检查：核心库的依赖集合必须恰好等于白名单，多一个或少一个都会让 CI 失败。断言脚本本身带自检，先喂越界样本确认判定逻辑有效，再看真实文件。

**参考来源说明**

算法来自公开发表的公式与标准，不涉及代码移植：

- Schroeder, V. R. (1965), *New Method of Measuring the Reverberation Time*, Acustica 18
- Sabine, W. C. (1899), 混响时间与房间吸声量的关系式
- ISO 3382-1:2009, 衰减时间的定义与评价区间
- 矩形房间模态频率为波动方程在刚壁边界下的解析解

同领域的 Python / C++ 项目（`jmrplens/phonometry`、`VilhoValittu/DecayCore` 等）只作为领域参考，未使用其代码。许可证为 Apache-2.0。

**验证与复现**

```bash
git clone https://github.com/AYHEY001/roomacoustics.git && cd roomacoustics
moon update
moon test --deny-warn        # 预期 81 passed
moon run cmd/main -- decay -f testdata/noisy_snr20.json
moon run cmd/main -- modes --length 5 --width 4 --height 2.6 \
  --from-ir testdata/room_5x4x2.6_image_source.wav
```

几处可以独立核对的地方：

- 噪声污染时拒绝给数字。`testdata/noisy_snr20.json` 会输出「评价区间落进噪声底，结果不可信」；跳过这条校验则会报出 `T20 = 8.92s`，而真值是 0.8 秒。
- 模态公式的 `1/2` 有测试钉住。公式曾漏掉这个因子，导致频率整体翻倍、只剩偶数阶模态。`decay_wbtest.mbt` 里有一条测试专门区分正确与错误的写法。
- 关键结论都有脚本可复现。`_probe/physics_probe.py` 做物理验证，`_probe/frequency_limit_probe.py` 用随机对照量出模态配对方法的判别力边界，`docs/check_ecosystem.py` 核验生态空位。
- CI 在每次提交运行 `moon check --deny-warn`、`moon fmt --check`、`moon test --deny-warn` 与 CLI 冒烟测试。

**项目状态**

| 项 | 值 |
|---|---|
| 提交数 | 23（截至 2026-10-15） |
| 测试 | 81，全部通过 |
| 代码规模 | 3195 行 MoonBit（库 + CLI + 测试） |
| 许可证 | Apache-2.0 |
| 目标平台 | wasm |
| CI | 全绿 |
| 开发记录 | 8 个 Issue，已关闭 5 个。其中两个是实质缺陷：非法参数曾静默按 0 处理并报出错误数字；模态配对的判别力边界曾被高估，现已量化并写入 README |
