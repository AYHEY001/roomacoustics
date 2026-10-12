"""生成 IR 语料 + Python 参考值，供 MoonBit 实现交叉对账。

为什么要两份数据：
1. `testdata/*.json` —— 脉冲响应采样点，MoonBit 测试读它算结果
2. `testdata/reference.json` —— 同一份 IR 在 Python 里的计算结果

**关键**：MoonBit 不能自己测自己。回归测试只验证"MoonBit 和 Python 算出同一个数"，
两边用的是各自独立的实现（Python 用 numpy.polyfit，MoonBit 用自己写的最小二乘），
所以对上了才说明实现正确。

噪声底估计的公式必须与 MoonBit 侧 `estimate_noise_floor` 一致，
否则对账出来的差异分不清是"实现有 bug"还是"两边定义不同"。
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "_probe"))
from physics_probe import (  # noqa: E402
    db,
    decay_times,
    schroeder_integral,
    synth_ir,
)

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "testdata")


def noise_floor_db(ir, tail_fraction=0.1):
    """与 MoonBit estimate_noise_floor 同定义的噪声底估计。

    基准是 **EDC 峰值（IR 总能量）**，不是整段 IR 的 RMS。
    整段 RMS 包含直达声和早期反射，会把噪声底的 dB 值系统性抬高，
    导致正常的测量被误判为"被噪声污染"。详见 edc.mbt 中的说明。
    """
    n = len(ir)
    tail = int(n * tail_fraction)
    if tail < 16:
        return None
    rms_tail = np.sqrt(np.mean(ir[n - tail:] ** 2))
    peak = float(np.sum(ir**2))
    tail_energy = float(rms_tail**2 * tail)
    if peak <= 0 or tail_energy <= 0:
        return None
    return float(10 * np.log10(tail_energy / peak))


def build():
    os.makedirs(OUT, exist_ok=True)
    cases = {}

    # 三种已知 T60 的干净 IR
    for rt in (0.4, 0.8, 1.6):
        cases[f"clean_{rt}"] = synth_ir(rt, sr=SR, dur=2.5, seed=int(rt * 100))

    # 带噪 IR：SNR 20dB，用于验证"噪声污染要被检出而不是照报数字"
    base = synth_ir(0.8, sr=SR, dur=2.5, seed=1)
    rng = np.random.default_rng(3)
    sp = np.mean(base**2)
    cases["noisy_snr20"] = base + rng.standard_normal(len(base)) * np.sqrt(
        sp / 10 ** (20 / 10)
    )

    manifest = []
    reference = {}
    for name, ir in cases.items():
        path = os.path.join(OUT, f"{name}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "sample_rate": SR,
                    "ir": [round(float(x), 8) for x in ir],
                },
                f,
            )
        res = decay_times(ir, SR)
        reference[name] = {
            "edt": res["EDT"],
            "t20": res["T20"],
            "t30": res["T30"],
            "noise_floor_db": noise_floor_db(ir),
        }
        manifest.append({"name": name, "file": f"testdata/{name}.json"})
        print(
            f"  {name:14s} EDT={res['EDT']:.4f}  T20={res['T20']:.4f}  "
            f"T30={res['T30']:.4f}  nf={reference[name]['noise_floor_db']:.2f}dB  "
            f"({os.path.getsize(path) / 1024:.0f} KB)"
        )

    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    with open(os.path.join(OUT, "reference.json"), "w", encoding="utf-8") as f:
        json.dump(reference, f, indent=2)
    return reference


def main():
    print(f"采样率 {SR} Hz，语料写入 {os.path.abspath(OUT)}")
    print("Python 参考值（MoonBit 实现必须与这些数字一致）：")
    ref = build()
    print("\n注意 noisy_snr20 这个用例：Python 参考 T20 明显大于真值 0.8s，")
    print("因为它没做噪声底校验。MoonBit 侧应当返回 ContaminatedByNoise，")
    print("而不是照抄这个被污染的数字 —— 这正是本项目存在的理由。")


if __name__ == "__main__":
    main()