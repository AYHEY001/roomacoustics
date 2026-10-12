"""用镜像声源法（image source method）生成有真实模态结构的房间脉冲响应。

为什么需要这个：之前 testdata 里的合成 IR 是「白噪声 × 指数包络」，
频谱是平坦的 —— 它能验证衰减时间算法，但**不含任何房间模态信息**，
拿它去验证模态频率毫无意义。

模态验证需要 IR 来自一个真实的房间模型。镜像声源法把墙面反射展开成
无穷多个镜像声源，叠加起来就是该房间的真实脉冲响应，
其传递函数 |H(f)| 的峰就是房间模态。

**先自检再生成**：脚本会先用 Python 的 FFT 检查「检测到的峰」与
「解析式预测的模态频率」是否吻合。如果 Python 侧都看不出模态峰，
说明这条路本身不通，就不该让 MoonBit 侧去实现它。
"""

import json
import os
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "_probe"))

C_AIR = 343.0
OUT = os.path.join(os.path.dirname(__file__), "..", "testdata")


def image_source_ir(L, W, H, alpha, sr, duration, order=12, seed=0):
    """按镜像声源法生成房间脉冲响应。

    - `alpha`：墙面平均吸声系数，声压反射系数 R = sqrt(1-alpha)
    - `order`：镜像阶数上限（每方向 ±order）

    位置：声源与接收点都取房间中心偏一点，避免落在对称面上
    （对称布置会让大量模态不被激励，频谱上少掉一半峰）。
    """
    n = int(sr * duration)
    ir = np.zeros(n)
    R = np.sqrt(max(1.0 - alpha, 0.0))
    # 声源与接收点：稍微偏离中心，也彼此错开
    src = np.array([L * 0.32, W * 0.41, H * 0.37])
    rec = np.array([L * 0.68, W * 0.57, H * 0.62])
    dims = np.array([L, W, H])

    for mx in range(-order, order + 1):
        for my in range(-order, order + 1):
            for mz in range(-order, order + 1):
                m = np.array([mx, my, mz])
                # 一维镜像位置：2*m*L ± src
                for sx in (1, -1):
                    for sy in (1, -1):
                        for sz in (1, -1):
                            s = np.array([sx, sy, sz])
                            img = 2.0 * m * dims + s * src
                            r = float(np.linalg.norm(img - rec))
                            if r < 1e-9:
                                continue
                            t = r / C_AIR
                            idx = int(round(t * sr))
                            if idx >= n:
                                continue
                            # 每反射一次乘 R，反射次数按经过的墙面数估计
                            reflections = abs(mx) + abs(my) + abs(mz)
                            amp = R**reflections / (4.0 * np.pi * r)
                            ir[idx] += amp
    return ir, src, rec


def modal_freqs(L, W, H, n_max=5):
    """解析式模态频率，与 MoonBit 侧 modal_frequency 同式。"""
    out = []
    for nx in range(n_max):
        for ny in range(n_max):
            for nz in range(n_max):
                if nx == 0 and ny == 0 and nz == 0:
                    continue
                f = C_AIR * np.sqrt(
                    (nx / L) ** 2 + (ny / W) ** 2 + (nz / H) ** 2
                )
                out.append((f, (nx, ny, nz)))
    out.sort()
    return out


def largest_pow2_at_most(n):
    """不超过 n 的最大 2 的幂。

    为什么必须这样：MoonSpectrum 的 `fft` 实测**只支持 2 的幂长度**
    （88200 抛异常，65536 / 131072 正常）。为了让 Python 参考实现和
    MoonBit 实现能逐点对账，两边必须用同一个 FFT 长度。
    """
    p = 1
    while p * 2 <= n:
        p *= 2
    return p


def spectrum_peaks(signal, sr, threshold_ratio=1.5, min_dist_hz=8.0, fmin=50.0, fmax=500.0):
    """对信号做 FFT，返回幅度谱上的峰（频率, 局部突出度）。

    **只取正频率部分（前半段）**。实数信号的 FFT 输出关于 N/2 对称，
    负频率镜像的幅度与正频率相同；若在全长上找最大值，
    浮点噪声会让镜像偶尔胜出，报出一个超过 Nyquist 的频率。
    实测在 16384/65536 点上就撞到过：1000 Hz 的正弦被报成 43098 Hz
    （= 44100 - 1002，正好是镜像位置）。

    加 Hann 窗抑制旁瓣 —— 不加窗的话强模态的旁瓣会被当成独立的峰。
    阈值用**局部中值**而不是全局最大值：全谱最大值被 0 Hz 的直流分量
    主导（实测高出低频段均值两个数量级），用全局阈值会把所有模态峰滤掉。
    """
    x = np.asarray(signal, dtype=float)
    n_fft = largest_pow2_at_most(len(x))
    seg = x[:n_fft]
    seg = (seg - seg.mean()) * np.hanning(n_fft)
    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)

    band = (freqs >= fmin) & (freqs <= fmax)
    idx = np.where(band)[0]
    if len(idx) == 0:
        return []
    s = spec[idx]

    # 局部中值作基线
    from numpy.lib.stride_tricks import sliding_window_view

    win = 161
    pad = np.pad(s, win // 2, mode="edge")
    base = np.median(sliding_window_view(pad, win), axis=1)
    ratio = s / np.maximum(base, 1e-30)

    df = freqs[1] - freqs[0]
    min_dist = max(1, int(round(min_dist_hz / df)))
    peaks = []
    for i in range(1, len(s) - 1):
        if s[i] >= s[i - 1] and s[i] > s[i + 1] and ratio[i] > threshold_ratio:
            if peaks and (i - peaks[-1][0]) < min_dist:
                if s[i] > s[peaks[-1][0]]:
                    peaks[-1] = (i, ratio[i])
                continue
            peaks.append((i, ratio[i]))
    return [(float(freqs[idx[i]]), float(r)) for i, r in peaks]


def main():
    L, W, H = 5.0, 4.0, 2.6
    alpha = 0.12
    sr = 44100
    dur = 2.0

    print(f"房间 {L}×{W}×{H} m，α={alpha}，采样率 {sr} Hz")
    ir, src, rec = image_source_ir(L, W, H, alpha, sr, dur)
    nonzero = int((ir != 0).sum())
    print(f"  镜像声源法生成：{len(ir)} 个采样点，其中 {nonzero} 个非零（脉冲串）")
    print(f"  声源 {src.round(2)}，接收 {rec.round(2)}")

    # ---- 自检：Python 侧能不能看出模态峰 ----
    print()
    print("=" * 64)
    print("自检：Python FFT 检测到的峰 vs 解析式预测的模态频率")
    print("=" * 64)
    peaks = spectrum_peaks(ir, sr)
    predicted = modal_freqs(L, W, H)
    n_fft = largest_pow2_at_most(len(ir))
    print(
        f"  FFT 长度 {n_fft}（2 的幂；原信号 {len(ir)} 点被截断），"
        f"频率分辨率 {sr / n_fft:.3f} Hz"
    )
    print(f"  检测到 {len(peaks)} 个峰")
    print()

    # 配对：每个检测到的峰找最近的预测模态。
    # 方向是「峰 -> 模态」而不是反过来：
    # 单点声源到单点接收的传递函数里，某些模态在测量位置不被激励
    # （声源或接收点落在该模态的节面上），所以预测模态不会全部出现；
    # 但**出现的峰应该都能对应到某个预测模态**。这是物理上正确的判定。
    def tolerance(f):
        return max(5.0, f * 0.05)

    print(f"  {'峰频率':>9} {'突出度':>7}  {'最近预测模态':>12} {'偏差':>8}")
    matched = 0
    unmatched = []
    for f, r in peaks:
        near = min(predicted, key=lambda pf: abs(pf[0] - f))
        dev = f - near[0]
        ok = abs(dev) <= tolerance(near[0])
        if ok:
            matched += 1
        else:
            unmatched.append((f, near[0], dev))
        print(
            f"  {f:9.2f} {r:7.2f}  {near[0]:12.2f} {dev:+8.2f}  "
            f"{'OK' if ok else '未配对'}"
        )
    print()
    if peaks:
        print(
            f"  配对率：{matched}/{len(peaks)} = "
            f"{100.0 * matched / len(peaks):.0f}%"
        )
    print()
    print("  说明：配对率不是 100% 是正常的 —— 单点测量的传递函数里，")
    print("  部分预测模态在声源或接收点位置不被激励（落在节面上）。")
    print("  这个判定的方向是「检测到的峰能否对应到预测模态」，")
    print("  而不是「预测模态是否全部被检测到」—— 后者物理上做不到。")

    # ---- 写出语料 ----
    os.makedirs(OUT, exist_ok=True)
    peak = float(np.max(np.abs(ir)))
    scaled = ir / peak * 0.95
    ints = np.clip(np.round(scaled * 32767), -32768, 32767).astype("<i2")
    wav_path = os.path.join(OUT, "room_5x4x2.6_image_source.wav")
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(ints.tobytes())
    print()
    print(f"  已写出 {wav_path}  ({os.path.getsize(wav_path)/1024:.0f} KB)")

    meta = {
        "room": {"length": L, "width": W, "height": H},
        "alpha": alpha,
        "sample_rate": sr,
        "method": "image source method",
        "order": 12,
        "source_pos": [float(v) for v in src],
        "receiver_pos": [float(v) for v in rec],
        "fft_length": n_fft,
        "peaks_hz": [round(f, 3) for f, _ in peaks],
        "predicted_modes_hz": [
            {"freq": round(f, 3), "mode": list(idx)}
            for f, idx in predicted
            if f <= 700
        ],
    }
    meta_path = os.path.join(OUT, "room_5x4x2.6_modes.json")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print(f"  已写出 {meta_path}（含解析式预测的模态列表，供交叉对照）")


if __name__ == "__main__":
    main()