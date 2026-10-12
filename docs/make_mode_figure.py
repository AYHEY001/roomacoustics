"""生成模态对照图：解析式预测 vs 实测频谱。

读 `testdata/room_5x4x2.6_modes.json`（由 make_image_source_ir.py 写出），
不重新算 —— 保证图上数字与 CLI 输出、与测试断言是同一份数据。
"""

import json
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager

BG = "#141414"
FG = "#e8e8e8"
GRID = "#2a2a2a"
ACCENT = "#4a9eff"
GREEN = "#2ecc71"
RED = "#e74c3c"
ORANGE = "#e67e22"

HERE = os.path.dirname(__file__)
ROOT = os.path.join(HERE, "..")


def setup_fonts():
    candidates = ["Microsoft YaHei", "SimHei", "Microsoft JhengHei", "DengXian"]
    have = {f.name for f in font_manager.fontManager.ttflist}
    use = next((c for c in candidates if c in have), None)
    plt.rcParams["font.sans-serif"] = [use] if use else ["DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    return use


def style(ax, title, xlabel, ylabel):
    ax.set_facecolor(BG)
    ax.set_title(title, color=FG, fontsize=12, pad=10)
    ax.set_xlabel(xlabel, color=FG, fontsize=10)
    ax.set_ylabel(ylabel, color=FG, fontsize=10)
    ax.grid(alpha=0.25, color=GRID)
    ax.tick_params(colors=FG, labelsize=9)
    for s in ax.spines.values():
        s.set_color("#333")


def main():
    font = setup_fonts()
    print(f"中文字体：{font}")

    sys.path.insert(0, HERE)
    from make_image_source_ir import image_source_ir, largest_pow2_at_most

    with open(os.path.join(ROOT, "testdata", "room_5x4x2.6_modes.json"), encoding="utf-8") as f:
        meta = json.load(f)
    room = meta["room"]
    L, W, H = room["length"], room["width"], room["height"]
    sr = meta["sample_rate"]
    peaks_hz = meta["peaks_hz"]
    matches = meta["matches"]
    # 只画匹配到的模态位置。520 Hz 以下有 700 多个预测模态，
    # 全画成竖线会糊成一片；峰的对应模态只有 23 个，图上更清楚。
    pred = [m["mode_hz"] for m in matches]
    print(f"轴向基频（应为 c/(2L)）：{meta['axial_fundamental_hz']} Hz")

    # 重算频谱用于绘图（与生成语料时同一份 IR）
    ir, _, _ = image_source_ir(L, W, H, meta["alpha"], sr, 2.0)
    n_fft = largest_pow2_at_most(len(ir))
    seg = (ir[:n_fft] - ir[:n_fft].mean()) * np.hanning(n_fft)
    spec = np.abs(np.fft.rfft(seg))
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)

    band = (freqs >= 40) & (freqs <= 520)
    fb, sb = freqs[band], spec[band]
    # 归一化到最大值，方便阅读
    sb = sb / sb.max()

    fig = plt.figure(figsize=(14, 8.5), facecolor=BG)
    fig.suptitle(
        "房间模态：解析式预测 vs 实测频谱",
        color=FG,
        fontsize=18,
        fontweight="bold",
        y=0.965,
    )

    # ---- 上：频谱 + 峰 + 预测模态 ----
    ax1 = fig.add_subplot(2, 1, 1)
    ax1.plot(fb, sb, color="#7a7a7a", lw=0.9, label="幅度谱 |H(f)|")
    # 预测模态：竖直虚线
    for i, f in enumerate(pred):
        ax1.axvline(
            f, color=ACCENT, ls="--", lw=1.1, alpha=0.75,
            label="预测模态（峰对应的）" if i == 0 else None,
        )
    # 检测到的峰：红点
    for i, f in enumerate(peaks_hz):
        if fb[0] <= f <= fb[-1]:
            idx = int(np.argmin(np.abs(fb - f)))
            ax1.plot(
                f, sb[idx] * 1.06, "v", color=RED, ms=6,
                label="检测到的峰" if i == 0 else None,
            )
    ax1.set_xlim(fb[0], fb[-1])
    ax1.set_ylim(0, 1.35)
    style(
        ax1,
        f"5.0×4.0×2.6 m 房间的传递函数（镜像声源法生成，FFT {n_fft} 点，分辨率 {sr/n_fft:.2f} Hz）",
        "",
        "归一化幅度",
    )
    leg = ax1.legend(
        facecolor="#1e1e1e", edgecolor="#333", fontsize=9, loc="upper right"
    )
    for t in leg.get_texts():
        t.set_color(FG)

    # ---- 下：偏差 ----
    ax2 = fig.add_subplot(2, 1, 2)
    # 直接用 json 里已算好的配对结果，不在这里重算 ——
    # 保证图上数字与 CLI 输出、与测试断言出自同一份数据
    xs = [m["peak_hz"] for m in matches]
    ys = [m["deviation_hz"] for m in matches]
    tol_vals = [max(5.0, m["mode_hz"] * 0.05) for m in matches]
    colors = [GREEN if m["matched"] else RED for m in matches]
    ax2.bar(xs, ys, width=4.5, color=colors)
    ax2.axhline(0, color=FG, lw=1.0, alpha=0.5)
    ax2.fill_between(
        xs, [-t for t in tol_vals], tol_vals,
        color=GREEN, alpha=0.12, label="容差 max(5Hz, 5%)",
    )
    matched = sum(1 for c in colors if c == GREEN)
    style(
        ax2,
        f"检测峰相对最近预测模态的偏差　—　配对 {matched}/{len(matches)} = {100*matched/len(matches):.0f}%",
        "频率 (Hz)",
        "偏差 (Hz)",
    )
    leg2 = ax2.legend(facecolor="#1e1e1e", edgecolor="#333", fontsize=9)
    for t in leg2.get_texts():
        t.set_color(FG)

    fig.text(
        0.5,
        0.015,
        f"轴向基频 c/(2L) = {meta['axial_fundamental_hz']:.1f} Hz　·　"
        f"{matched}/{len(matches)} 个检测峰匹配到预测模态　·　"
        f"预测模态候选集取 f ≤ 520 Hz",
        ha="center",
        color="#888",
        fontsize=9.5,
    )

    plt.tight_layout(rect=[0, 0.03, 1, 0.94])
    out = os.path.join(HERE, "img", "mode_comparison.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    plt.savefig(out, dpi=150, facecolor=BG)
    print(f"已保存 {out}")
    print(f"配对 {matched}/{len(matches)} = {100*matched/len(matches):.0f}%")


if __name__ == "__main__":
    main()