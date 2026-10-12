# haiou/roomacoustics

用 MoonBit 从一段脉冲响应计算房间的混响时间、衰减曲线和模态频率。

## 边界

本项目不提供 WAV 解析能力，也不实现 FFT —— 读取与频谱分别由
`moonwavkit` 和 `MoonSpectrum` 承担。本项目做的是它们之上的声学计算：
Schroeder 能量衰减曲线反演、EDT / T20 / T30 拟合、Sabine 解析估算、
矩形房间模态频率闭式解。

## Sabine 公式

`RT60 = 0.161 · V / (S · α)`，其中 V 是房间体积（m³），S 是总表面积（m²），
α 是平均吸声系数。

```mbt check
///|
test "Sabine 公式：5.0×4.0×2.6 m 房间，α=0.20" {
  // 体积 52.0 m³，总表面积 2×(5×4 + 5×2.6 + 4×2.6) = 86.8 m²
  let rt60 = @roomacoustics.sabine(52.0, 86.80, 0.20)
  debug_inspect(rt60, content="Some(0.482258064516129)")
}
```

吸声系数为 0 时公式无定义，此时返回 `None` 而不是 `inf`：

```mbt check
///|
test "Sabine：非法输入返回 None" {
  debug_inspect(@roomacoustics.sabine(52.0, 86.80, 0.0), content="None")
  debug_inspect(@roomacoustics.sabine(52.0, 0.0, 0.20), content="None")
}
```

## 矩形房间模态频率

`f = (c/2) · √((nx/Lx)² + (ny/Ly)² + (nz/Lz)²)`，其中 c = 343 m/s。

那个 **1/2** 来自边界条件：刚壁下法向速度为零，声压沿各轴呈 `cos(k·x)`，
极值条件 `k·L = n·π` 给出 `k = nπ/L`；代入 `k = 2πf/c` 约掉 π 即得。

轴向模态的基频是 `c / (2L)`，例如 5.0 m 边的第一个轴向模态：

```mbt check
///|
test "轴向模态基频 = c / (2L)" {
  let f = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 0, 0))
  debug_inspect(f, content="Some(34.300000000000004)")
  // 4.0 m 边的第一个轴向模态
  let g = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (0, 1, 0))
  debug_inspect(g, content="Some(42.875)")
}
```

`(0, 0, 0)` 不是房间模态（它是零频的空气共振），返回 `None`：

```mbt check
///|
test "零阶模态与非法边长" {
  debug_inspect(
    @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (0, 0, 0)),
    content="None",
  )
  debug_inspect(
    @roomacoustics.modal_frequency(0.0, 4.0, 2.6, (1, 0, 0)),
    content="None",
  )
}
```