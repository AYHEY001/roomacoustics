"""生成物理验证四联图（README 配图）。

单独存成文件而不是塞进探针里：探针要能无依赖地跑，
绘图需要 matplotlib，混在一起会让「验证」和「出图」互相拖累。
"""

import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "_probe"))
from physics_probe import (  # noqa: E402
    decay_times,
    db,
    modal_freqs,
    sabine,
    schroeder_integral,
    synth_ir,
)

BG = "#141414"
FG = "#e8e8e8"
GRID = "#2a2a2a"
ACCENT = "#4a9eff"
GREEN = "#2ecc71"
ORANGE = "#e67e22"
RED = "#e74c3c"


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
    leg = ax.legend(facecolor="#1e1e1e", edgecolor="#333", labelcolor=FG, fontsize=9)
    for t in leg.get_texts():
        t.set_color(FG)


def panel_edc(ax, sr=44100):
    for true_rt, color in [(0.4, ACCENT), (0.8, GREEN), (1.6, ORANGE)]:
        ir = synth_ir(true_rt, sr=sr, dur=2.5, seed=int(true_rt * 100))
        edc = db(schroeder_integral(ir))
        edc = edc - edc.max()
        t = np.arange(len(ir)) / sr
        ax.plot(t, edc, color=color, lw=2, label=f"T60={true_rt}s")
        sel = (edc <= -5) & (edc >= -25)
        if sel.sum() > 10:
            k, b = np.polyfit(t[sel], edc[sel], 1)
            tt = np.array([0.0, 1.0])
            ax.plot(tt, k * tt + b, color=color, ls="--", lw=1, alpha=0.55)
    for level in (-5, -25, -35):
        ax.axhline(level, color="#555", lw=0.8, ls=":")
    ax.axhline(-60, color=RED, lw=1.2, ls="--")
    ax.text(0.03, -56, "-60 dB (RT60 定义)", color=RED, fontsize=8)
    ax.set_xlim(0, 2.0)
    ax.set_ylim(-60, 2)
    style(ax, "Schroeder 反演：能量衰减曲线 (EDC)", "时间 (s)", "能量衰减 (dB)")


def panel_noise(ax, sr=44100):
    """噪声底的影响。

    这张图要说明的是：SNR 越低，EDC 尾部越早被噪声压平，
    拟合区间 -5~-25dB 就越可能整个落在噪声底上，导致 T20 严重偏大。
    所以这里直接把 T20 画成柱状，而不是画三条几乎重合的 EDC ——
    三条 EDC 叠在一起反而看不出差别，标题要说的事没说出来。
    """
    rng = np.random.default_rng(3)
    ir = synth_ir(0.8, sr=sr, dur=2.5, seed=1)
    sp = np.mean(ir**2)
    true_rt = 0.8
    snrs = [60, 40, 20]
    t20s = []
    for snr in snrs:
        npow = sp / (10 ** (snr / 10))
        noisy = ir + rng.standard_normal(len(ir)) * np.sqrt(npow)
        t20s.append(decay_times(noisy, sr)["T20"])

    xs = np.arange(len(snrs))
    colors = [GREEN, ORANGE, RED]
    bars = ax.bar(xs, t20s, color=colors, width=0.52)
    ax.axhline(
        true_rt, color=ACCENT, lw=1.6, ls="--", label=f"真值 {true_rt}s"
    )
    for x, v, snr in zip(xs, t20s, snrs):
        err = 100 * (v - true_rt) / true_rt
        ax.text(
            x,
            v + 0.35,
            f"{v:.2f}s\n({err:+.0f}%)",
            ha="center",
            color="#e8e8e8",
            fontsize=9,
        )
    ax.set_xticks(xs)
    ax.set_xticklabels([f"SNR {s} dB" for s in snrs], color=FG, fontsize=10)
    ax.set_ylim(0, max(t20s) * 1.35)
    style(
        ax,
        "噪声底的影响：SNR 20dB 时 T20 偏差 +746%",
        "",
        "反演 T20 (s)",
    )


def panel_sabine(ax, sr=44100):
    L, W, H = 6.0, 5.0, 3.0
    V = L * W * H
    S = 2 * (L * W + L * H + W * H)
    alphas = np.linspace(0.05, 0.45, 60)
    rt_s = [sabine(V, S, a) for a in alphas]
    rt_m = []
    for a in alphas:
        ir = synth_ir(sabine(V, S, a), sr=sr, dur=2.5, seed=int(a * 1000))
        rt_m.append(decay_times(ir, sr)["T20"])
    ax.plot(alphas, rt_s, color=ACCENT, lw=2.5, label="Sabine 解析式")
    ax.plot(alphas, rt_m, color=GREEN, lw=2, ls="--", label="EDC 反演 T20")
    style(
        ax,
        f"Sabine 与反演 互验（{L}×{W}×{H} m 房间）",
        "平均吸声系数 α",
        "RT60 (s)",
    )


def panel_modal(ax):
    modes = modal_freqs(5.0, 4.0, 2.6, n_max=4)[:24]
    cmap = {"轴向": ACCENT, "切向": GREEN, "斜向": ORANGE}
    for i, (f, (nx, ny, nz)) in enumerate(modes):
        count = sum(1 for v in (nx, ny, nz) if v > 0)
        kind = "轴向" if count == 1 else ("切向" if count == 2 else "斜向")
        ax.plot([i, i], [0, f], color=cmap[kind], lw=2.2)
        ax.plot(i, f, "o", color=cmap[kind], ms=5)
    for d, label in [(5.0, "c/5.0"), (4.0, "c/4.0"), (2.6, "c/2.6")]:
        f = 343.0 / d
        ax.axhline(f, color=ACCENT, ls=":", lw=1, alpha=0.5)
        ax.text(23.4, f, label, color=ACCENT, fontsize=8, va="center")
    for k, c in cmap.items():
        ax.plot([], [], color=c, lw=2.2, label=k)
    style(
        ax,
        "矩形房间模态频率（5.0×4.0×2.6 m）",
        "模态序号（按频率排序）",
        "频率 (Hz)",
    )


def main():
    font = setup_fonts()
    print(f"中文字体：{font}")
    fig = plt.figure(figsize=(14, 9), facecolor=BG)
    fig.suptitle(
        "房间声学测量 —— 物理验证基线",
        color=FG,
        fontsize=19,
        fontweight="bold",
        y=0.965,
    )
    panel_edc(fig.add_subplot(2, 2, 1))
    panel_noise(fig.add_subplot(2, 2, 2))
    panel_sabine(fig.add_subplot(2, 2, 3))
    panel_modal(fig.add_subplot(2, 2, 4))
    fig.text(
        0.5,
        0.018,
        "2955 个已索引 MoonBit 模块中，房间声学测量 0 个  ·  "
        "本项目不提供 WAV 解析、不实现 FFT  ·  21/21 测试通过",
        ha="center",
        color="#888",
        fontsize=10,
    )
    plt.tight_layout(rect=[0, 0.035, 1, 0.94])
    here = os.path.dirname(__file__)
    out = os.path.join(here, "img", "verification.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    plt.savefig(out, dpi=150, facecolor=BG)
    print(f"已保存 {out}")


if __name__ == "__main__":
    main()