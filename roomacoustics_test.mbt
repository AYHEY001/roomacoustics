// Blackbox tests run against the package's public API. Use `@roomacoustics` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "Sabine：教科书算例手算一致" {
  // 5.0 × 4.0 × 2.6 m 房间，V=52.0 m³，S=2×(20+13+10.4)=86.8 m²，α=0.20
  // 手算 0.161 × 52.0 / (86.8 × 0.20) = 0.482258...
  debug_inspect(
    @roomacoustics.sabine(52.0, 86.80, 0.20),
    content="Some(0.482258064516129)",
  )
}

///|
test "Sabine：RT60 随吸声系数单调下降" {
  let rt_low = @roomacoustics.sabine(52.0, 86.80, 0.10).unwrap()
  let rt_mid = @roomacoustics.sabine(52.0, 86.80, 0.20).unwrap()
  let rt_high = @roomacoustics.sabine(52.0, 86.80, 0.40).unwrap()
  assert_true(rt_low > rt_mid, msg="alpha 越大 RT60 应越短")
  assert_true(rt_mid > rt_high, msg="alpha 越大 RT60 应越短")
}

///|
test "Sabine：alpha 加倍则 RT60 减半" {
  let a = @roomacoustics.sabine(52.0, 86.80, 0.20).unwrap()
  let b = @roomacoustics.sabine(52.0, 86.80, 0.40).unwrap()
  // b 应当恰好是 a 的一半
  assert_true(
    (a / 2.0 - b).abs() < 0.000000000001,
    msg="alpha 加倍 RT60 应恰好减半",
  )
}

///|
test "Sabine：无效输入返回 None 而不是 inf" {
  debug_inspect(@roomacoustics.sabine(52.0, 86.80, 0.0), content="None")
  debug_inspect(@roomacoustics.sabine(52.0, 0.0, 0.20), content="None")
  debug_inspect(@roomacoustics.sabine(-1.0, 86.80, 0.20), content="None")
}

///|
test "模态频率：轴向基频等于 c / L" {
  let c = @roomacoustics.SOUND_SPEED
  let f = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 0, 0)).unwrap()
  assert_true(
    (f - c / 5.0).abs() < 0.000000001,
    msg="5.0 m 边的一阶轴向模态应为 c/5",
  )
  let g = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (0, 1, 0)).unwrap()
  assert_true(
    (g - c / 4.0).abs() < 0.000000001,
    msg="4.0 m 边的一阶轴向模态应为 c/4",
  )
  let h = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (0, 0, 1)).unwrap()
  assert_true(
    (h - c / 2.6).abs() < 0.000000001,
    msg="2.6 m 边的一阶轴向模态应为 c/2.6",
  )
}

///|
test "模态频率：数值与探针一致" {
  // 这些值来自 _probe/physics_probe.py 的 [4] 节输出
  // 探针打印两位小数（109.81），这里用 Python math 核算的精确值作为断言
  let f = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 0, 0)).unwrap()
  debug_inspect(f, content="68.60000000000001")
  let g = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 1, 0)).unwrap()
  debug_inspect(g, content="109.81358067197336")
}

///|
test "模态频率：n 阶轴向模态是基频的整数倍" {
  let f1 = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 0, 0)).unwrap()
  let f2 = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (2, 0, 0)).unwrap()
  let f3 = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (3, 0, 0)).unwrap()
  assert_true(
    (f2 - 2.0 * f1).abs() < 0.000000001,
    msg="二阶轴向模态应为基频 2 倍",
  )
  assert_true(
    (f3 - 3.0 * f1).abs() < 0.000000001,
    msg="三阶轴向模态应为基频 3 倍",
  )
}

///|
test "模态频率：斜向模态高于同阶轴向模态" {
  // 房间尺度不一，斜向模态是三个分量平方和的平方根，必然大于任一分量
  let axial = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 0, 0)).unwrap()
  let oblique = @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (1, 1, 1)).unwrap()
  assert_true(
    oblique > axial,
    msg="斜向模态频率应高于同阶轴向模态",
  )
}

///|
test "模态频率：零阶与非法输入返回 None" {
  // (0,0,0) 是零频空气共振，不计入房间模态
  debug_inspect(
    @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (0, 0, 0)),
    content="None",
  )
  // 边长非正
  debug_inspect(
    @roomacoustics.modal_frequency(0.0, 4.0, 2.6, (1, 0, 0)),
    content="None",
  )
  debug_inspect(
    @roomacoustics.modal_frequency(5.0, -1.0, 2.6, (1, 0, 0)),
    content="None",
  )
  // 负阶次
  debug_inspect(
    @roomacoustics.modal_frequency(5.0, 4.0, 2.6, (-1, 0, 0)),
    content="None",
  )
}

///|
test "模态频率：频率随房间变大而降低" {
  let small = @roomacoustics.modal_frequency(3.0, 3.0, 3.0, (1, 0, 0)).unwrap()
  let large = @roomacoustics.modal_frequency(10.0, 10.0, 10.0, (1, 0, 0)).unwrap()
  assert_true(large < small, msg="房间越大，同阶模态频率越低")
}
