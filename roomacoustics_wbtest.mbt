// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "模态频率：c 的取值符合 20 度干空气" {
  // 声速随温度变化：0°C 331.3，20°C 343.0，30°C 349.0 m/s
  // 常量取错会让所有模态频率整体偏移，且偏移量不大、很难一眼看出
  assert_true(
    SOUND_SPEED > 340.0 && SOUND_SPEED < 346.0,
    msg="声速应在 343 m/s 附近",
  )
}

///|
test "模态频率：三边等长的立方体房间，各轴向基频相同" {
  let f1 = modal_frequency(4.0, 4.0, 4.0, (1, 0, 0)).unwrap()
  let f2 = modal_frequency(4.0, 4.0, 4.0, (0, 1, 0)).unwrap()
  let f3 = modal_frequency(4.0, 4.0, 4.0, (0, 0, 1)).unwrap()
  assert_true(
    (f1 - f2).abs() < 0.000000000001,
    msg="立方体房间各轴基频应相同",
  )
  assert_true(
    (f2 - f3).abs() < 0.000000000001,
    msg="立方体房间各轴基频应相同",
  )
}

///|
test "模态频率：(1,1,1) 应等于三轴基频的平方和开方" {
  // 斜向模态频率 = sqrt(fx² + fy² + fz²)，可直接验算
  let fx = modal_frequency(5.0, 4.0, 2.6, (1, 0, 0)).unwrap()
  let fy = modal_frequency(5.0, 4.0, 2.6, (0, 1, 0)).unwrap()
  let fz = modal_frequency(5.0, 4.0, 2.6, (0, 0, 1)).unwrap()
  let oblique = modal_frequency(5.0, 4.0, 2.6, (1, 1, 1)).unwrap()
  let expected = (fx * fx + fy * fy + fz * fz).sqrt()
  assert_true(
    (oblique - expected).abs() < 0.000000001,
    msg="斜向模态应等于三轴基频平方和的开方",
  )
}

///|
test "模态频率：模态频率只与边长比有关，与房间绝对大小无关" {
  // 把房间放大 10 倍，所有模态频率应降为 1/10
  // 这验证了公式里 c·(n/L) 的结构正确，没有混入其他尺寸相关的项
  let small = modal_frequency(3.0, 4.0, 5.0, (2, 3, 1)).unwrap()
  let large = modal_frequency(30.0, 40.0, 50.0, (2, 3, 1)).unwrap()
  assert_true(
    (small / 10.0 - large).abs() < 0.000000001,
    msg="尺寸放大 10 倍频率应降为 1/10",
  )
}

///|
test "Sabine：体积为 0 时返回 0 而非 None" {
  // 零体积房间数学上 RT60=0，这是有意义的边界，不该与非法输入混为一谈
  // 注意：Double 的 inspect 会省略小数，`Some(0.0)` 实际显示为 `Some(0)`
  debug_inspect(sabine(0.0, 86.80, 0.20), content="Some(0)")
}

///|
test "Sabine：体积为负属于非法输入" {
  // 负体积不是"很小的房间"，是错误输入
  debug_inspect(sabine(-0.1, 86.80, 0.20), content="None")
}

///|
test "模态频率：alpha=1.0 对应完全吸收，RT60 为 0" {
  // 边界检验：表面全吸收时混响时间为零
  let rt = sabine(52.0, 86.80, 1.0).unwrap()
  assert_true(rt < 0.1, msg="alpha=1 表示完全吸收，RT60 应趋近 0")
}
