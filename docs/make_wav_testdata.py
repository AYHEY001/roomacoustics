"""生成 WAV 格式的脉冲响应语料。

与 make_testdata.py 的区别：那份出的是 JSON（纯数值），这份出的是真 WAV
（RIFF/WAVE 容器 + 16-bit PCM），用于验证 CLI 走 moonwavkit 读文件的路径。

两个路径必须对同一份信号给出同样的衰减时间 —— 这是接入依赖后的交叉验证。

用标准库 `wave` 写，不引第三方依赖；numpy 只用来算信号。
"""

import os
import struct
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "_probe"))
from physics_probe import synth_ir  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "testdata")
SR = 44100


def write_pcm16_mono(path, signal):
    """写 16-bit 单声道 WAV。

    注意量化的取舍：PCM16 的动态范围约 96 dB，够放 T60 到 -60 dB 的衰减。
    但浮点信号乘 32767 后取整会引入量化噪声 —— 对本项目影响很小
    （Schroeder 积分是全段累积，量化误差随机抵消），但值得知道。
    """
    peak = float(np.max(np.abs(signal)))
    if peak <= 0:
        raise ValueError("信号全零，无法归一化")
    # 留 1% 余量，避免正负不对称导致的削顶
    scaled = signal / peak * 0.99
    ints = np.clip(np.round(scaled * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(ints.tobytes())


def write_pcm16_stereo(path, signal):
    """写 16-bit 立体声 WAV，左右声道相同。

    用于验证 downmix_to_mono 这条路 —— 真实测量里经常是立体声录音。
    """
    peak = float(np.max(np.abs(signal)))
    scaled = signal / peak * 0.99
    mono = np.clip(np.round(scaled * 32767), -32768, 32767).astype("<i2")
    stereo = np.repeat(mono, 2)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(stereo.tobytes())


def main():
    os.makedirs(OUT, exist_ok=True)
    print(f"采样率 {SR} Hz，写入 {os.path.abspath(OUT)}")

    cases = [
        ("ir_mono_0.8.wav", 0.8, write_pcm16_mono),
        ("ir_mono_1.6.wav", 1.6, write_pcm16_mono),
        ("ir_stereo_0.8.wav", 0.8, write_pcm16_stereo),
    ]
    for name, rt, writer in cases:
        ir = synth_ir(rt, sr=SR, dur=2.5, seed=int(rt * 100))
        path = os.path.join(OUT, name)
        writer(path, ir)
        size = os.path.getsize(path)
        with wave.open(path, "rb") as w:
            info = (
                f"{w.getnchannels()}ch "
                f"{w.getsampwidth()*8}bit "
                f"{w.getframerate()}Hz "
                f"{w.getnframes()} 帧"
            )
        print(f"  {name:22s} 真值 T60={rt}s  {size/1024:.0f} KB  [{info}]")

    print()
    print("这些文件用标准库 wave 写出，可直接用任意播放器打开确认真是合法 WAV。")

    # 坏输入固件：文本文件改名成 .wav。
    # 用户手动重命名或下载中断时很容易撞上，必须能明确报错而不是崩溃。
    bad = os.path.join(OUT, "not_a_wav.wav")
    with open(bad, "wb") as f:
        f.write(b"this is definitely not a wav file, just plain text")
    print(f"  not_a_wav.wav          坏输入固件（文本改后缀）  {os.path.getsize(bad)} B")


if __name__ == "__main__":
    main()