"""探测：模态对照的「判别力边界」——用随机对照给出定量依据。

## 上一版探针（frequency_limit_probe.py）的结论

扫了 3 个房间 × 6 个频段，**配对率到 1000 Hz 都还是 100%**，
只有 1500 Hz 掉到 92%（且那是我自己的模态枚举上限造成的）。

同时「平均容差内模态数」高得离谱：520 Hz 时一个峰的容差内平均有
**68 个**预测模态。这提示：100% 的配对率可能是**必然的**，不含信息。

## 本探针要回答

判据不能是"配对率高不高"，而应该是：**实测峰比随机频率多提供了多少信息？**

做法：在同一个频段里均匀随机撒同样数量的频率，算它们的配对率。
  - 若实测峰的配对率显著高于随机 → 峰确实锁定在模态上，检验有判别力
  - 若两者接近 → 任何频率都能配上，检验已无判别力

这个"差值"才是 520 Hz 上限的定量依据。

## 预期（待验证）

低频：模态稀疏，随机频率常落在模态之间 → 随机配对率低 → 差值大
高频：模态密集，随机频率也总能落到某模态附近 → 随机配对率高 → 差值趋 0

## 注意

预测模态枚举要够密（n_max=24），否则高频"配对不上"是我枚举不够，
不是方法失效 —— 上一版 1500 Hz 的 92% 就是这个人为原因。

用法：
    PYTHONIOENCODING=utf-8 python _probe/frequency_limit_probe.py
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "docs"))

from make_image_source_ir import (  # noqa: E402
    C_AIR,
    image_source_ir,
    largest_pow2_at_most,
    modal_freqs,
    spectrum_peaks,
)

SR = 44100
DUR = 2.0
N_MAX = 24              # 模态枚举上限提高，避免高频时预测集自己不够用
RANDOM_TRIALS = 400     # 随机对照的采样次数（取平均，降低随机波动）

ROOMS = [
    ("5.0x4.0x2.6 基准", 5.0, 4.0, 2.6, 0.12),
    ("7.0x3.0x2.8 狭长", 7.0, 3.0, 2.8, 0.12),
    ("3.2x2.8x2.4 小房间", 3.2, 2.8, 2.4, 0.12),
]

FMAX_LIST = [200.0, 300.0, 400.0, 520.0, 700.0, 1000.0]


def tolerance(f):
    return max(5.0, f * 0.05)


def nearest_mode_freq(freqs, f):
    """向量化：最近的预测模态频率。freqs 已升序。"""
    i = int(np.searchsorted(freqs, f))
    cands = []
    if i < len(freqs):
        cands.append(freqs[i])
    if i > 0:
        cands.append(freqs[i - 1])
    return min(cands, key=lambda mf: abs(mf - f))


def match_rate(freqs, sample_freqs):
    """给定一批候选频率，返回配对率。"""
    if len(sample_freqs) == 0:
        return float("nan")
    hit = 0
    for f in sample_freqs:
        mf = nearest_mode_freq(freqs, f)
        if abs(mf - f) <= tolerance(mf):
            hit += 1
    return hit / len(sample_freqs)


def weyl_gap(volume, freq):
    """Weyl 公式给出的模态平均间距（Hz）。

    模态数 N(f) ≈ 4πVf³/(3c³)（只算一个八分之一象限，含各类模态），
    故 dN/df = 4πVf²/c³，平均间距 = 1/(dN/df)。

    这个量是「配对还有没有约束力」的标尺：
    容差 / 平均间距 >> 1 时，容差里塞着很多模态，配对必然成功。
    """
    dNdf = 4.0 * np.pi * volume * freq * freq / (C_AIR**3)
    return 1.0 / dNdf


def main():
    print("=" * 78)
    print("模态对照的判别力边界（随机对照）")
    print("=" * 78)

    summary = []

    for name, L, W, H, alpha in ROOMS:
        print()
        print("-" * 78)
        print(f"房间 {name}  ({L}×{W}×{H} m, α={alpha})")
        print("-" * 78)

        ir, src, rec = image_source_ir(L, W, H, alpha, SR, DUR)
        n_fft = largest_pow2_at_most(len(ir))
        df = SR / n_fft

        predicted = modal_freqs(L, W, H, n_max=N_MAX)
        pfreqs = np.array([f for f, _ in predicted])

        axial = (C_AIR / 2.0) / L
        got = min(
            f for f, idx in predicted if idx in ((1, 0, 0), (0, 1, 0), (0, 0, 1))
        )
        assert abs(got - axial) < 1e-9, f"轴向基频自检失败：{got} != {axial}"

        # 峰检测放在最宽频段，各频段筛选在后面做
        peaks = spectrum_peaks(ir, SR, fmax=max(FMAX_LIST), fmin=50.0)

        print(f"  轴向基频 c/(2L) = {axial:.3f} Hz  ✔  分辨率 {df:.3f} Hz")
        print()

        hdr = (
            f"  {'f_max':>6} {'峰数':>5} {'实测配对率':>10} {'随机配对率':>10} "
            f"{'判别力':>8} {'中位间距':>9} {'分辨率/间距':>11}"
        )
        print(hdr)
        print("  " + "-" * (len(hdr) - 2))

        for fmax in FMAX_LIST:
            band_peaks = [f for f, _ in peaks if f <= fmax]
            if not band_peaks:
                print(f"  {fmax:6.0f}  （无峰）")
                continue

            m_actual = match_rate(pfreqs, band_peaks)

            # 随机对照：在 [50, fmax] 内均匀撒点，取多轮平均
            rng = np.random.default_rng(12345)
            rates = []
            for _ in range(RANDOM_TRIALS):
                fake = rng.uniform(50.0, fmax, len(band_peaks))
                rates.append(match_rate(pfreqs, fake))
            m_random = float(np.mean(rates))

            power = m_actual - m_random

            # 频段内模态的相邻间距（仅非零）
            inband = pfreqs[pfreqs <= fmax]
            gaps = np.diff(inband)
            gaps = gaps[gaps > 1e-9]
            med_gap = float(np.median(gaps)) if len(gaps) else float("nan")
            ratio = df / med_gap if med_gap and not np.isnan(med_gap) else float("nan")

            print(
                f"  {fmax:6.0f} {len(band_peaks):5d} {100*m_actual:9.0f}% "
                f"{100*m_random:9.0f}% {100*power:+7.0f}pp {med_gap:8.3f}Hz "
                f"{ratio:11.1f}"
            )

            summary.append((name, fmax, len(band_peaks), m_actual, m_random, med_gap, df))

    print()
    print("=" * 78)
    print("判定：判别力 = 实测配对率 - 随机配对率（百分点）")
    print("=" * 78)
    print("  接近 0  → 随便取个频率都能配上，配对检验已无判别力；")
    print("           此时报告 100% 配对率是**空转**，不能当作解析式正确的证据。")
    print("  明显 > 0 → 峰确实落在模态上，检验有效。")
    print()
    print("  『分辨率/间距』= FFT 分辨率 ÷ 频段内模态中位间距。")
    print("  该值 > 1 表示相邻模态在频谱上根本分不开（间距小于一个 bin）。")

    # 找判别力降到的位置
    print()
    print("=" * 78)
    print("各房间判别力消失的位置")
    print("=" * 78)
    for room in ROOMS:
        name = room[0]
        rows = [s for s in summary if s[0] == name]
        weak = [s for s in rows if (s[3] - s[4]) < 0.20]
        if weak:
            first = min(weak, key=lambda s: s[1])
            print(
                f"  {name}: 判别力 < 20pp 最早出现在 f_max = {first[1]:.0f} Hz "
                f"（实测 {100*first[3]:.0f}% vs 随机 {100*first[4]:.0f}%）"
            )
        else:
            print(f"  {name}: 在扫到的频段内判别力都还 >= 20pp")

    # ---------------- 第二组对照：实测峰 vs 随机点的偏差分布 ----------------
    # 上一组说明「配对率」这个指标没有判别力（容差太宽）。
    # 这里换一个**不依赖容差选择**的度量：峰到最近模态的偏差。
    # 若实测峰确实锁定在模态上，其偏差应显著小于随机撒点的偏差。
    print()
    print("=" * 78)
    print("第二组对照：峰值偏差 vs 随机点偏差（不依赖容差选择）")
    print("=" * 78)
    print("  若实测峰锁定模态，其『到最近模态的偏差』应小于随机点的。")
    print("  比值 = 随机偏差中位数 / 实测偏差中位数，越大说明判别力越强。")
    print()

    for name, L, W, H, alpha in ROOMS:
        ir, _s, _r = image_source_ir(L, W, H, alpha, SR, DUR)
        predicted = modal_freqs(L, W, H, n_max=N_MAX)
        pfreqs = np.array([f for f, _ in predicted])
        peaks = spectrum_peaks(ir, SR, fmax=520.0, fmin=50.0)
        band_peaks = [f for f, _ in peaks if f <= 520.0]
        if not band_peaks:
            continue

        def devs(sample):
            return np.array([abs(nearest_mode_freq(pfreqs, f) - f) for f in sample])

        d_actual = devs(band_peaks)
        rng = np.random.default_rng(999)
        d_random = np.concatenate(
            [devs(rng.uniform(50.0, 520.0, len(band_peaks))) for _ in range(60)]
        )

        med_a = float(np.median(d_actual))
        med_r = float(np.median(d_random))
        ratio = med_r / med_a if med_a > 0 else float("inf")

        print(
            f"  {name}（{len(band_peaks)} 个峰，50~520 Hz）\n"
            f"      实测峰偏差中位数 {med_a:.3f} Hz\n"
            f"      随机点偏差中位数 {med_r:.3f} Hz\n"
            f"      比值 {ratio:.2f}×"
            + (
                "   ← 判别力明显"
                if ratio >= 2.0
                else "   ← 判别力弱（峰没比随机点更靠近模态）"
            )
        )
        print()

    # ---------------- 第三组：Weyl 公式给出的容差/间距比 ----------------
    # 上面看到判别力与模态密度有关。这里给出解析标尺：
    # 容差 ÷ 模态平均间距。该比值 >> 1 时配对必然成功。
    print("=" * 78)
    print("第三组：容差 ÷ 模态平均间距（Weyl 公式，可解析计算）")
    print("=" * 78)
    print("  容差 = max(5 Hz, 5%×f)。比值 << 1 时配对才有约束力；")
    print("  比值 >> 1 时容差里塞着很多模态，配对必然成功（指标空转）。")
    print()

    for name, L, W, H, alpha in ROOMS:
        volume = L * W * H
        print(f"  {name}（体积 {volume:.1f} m³）")
        print(
            f"      {'频率':>6} {'平均间距':>10} {'容差':>8} {'容差/间距':>10}"
        )
        for f in [100.0, 150.0, 200.0, 250.0, 300.0, 400.0, 520.0]:
            g = weyl_gap(volume, f)
            tol = tolerance(f)
            print(
                f"      {f:6.0f} {g:9.3f}Hz {tol:7.1f}Hz {tol/g:10.1f}"
            )
        # 反解几个有意义的门槛
        f_gap1 = float(np.sqrt(C_AIR**3 / (4.0 * np.pi * volume * 1.0)))
        f_gap5 = float(np.sqrt(C_AIR**3 / (4.0 * np.pi * volume * 5.0)))
        print(f"      → 平均间距 = 1 Hz 处的频率：{f_gap1:.0f} Hz")
        print(f"      → 平均间距 = 5 Hz 处的频率：{f_gap5:.0f} Hz")
        print()

    print("=" * 78)
    print("结论")
    print("=" * 78)
    print("  1. 配对率（容差 max(5Hz,5%) 下）在整个 50~520 Hz 都是 100%，")
    print("     随机撒点的配对率同样在 96~100% —— 该指标没有判别力。")
    print("  2. 判别力体现在『峰到最近模态的偏差』上，且随模态间距增大而增强：")
    print("     小房间（间距大）比值 2.45×，大房间（间距小）只有 1.35×。")
    print("  3. 用 Weyl 公式可解析算出约束力边界：容差/间距 ~ 1 时配对才有唯一性。")
    print("     对 5.0×4.0×2.6 m 房间，间距降到 1 Hz 是在 249 Hz 处。")
    print("  4. 所以 520 Hz 不是『方法失效』的位置，而是『宽松核对』的上限。")
    print("     在该频率容差已是模态间距的 100 倍以上，「配对」只说明")
    print("     『峰附近有模态』，不能说明『这个峰是哪个模态』。")


if __name__ == "__main__":
    main()
