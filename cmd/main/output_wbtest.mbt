// CLI 输出层的回归测试。
//
// `fmt` / `render` / `freq_line` 决定用户看到的每一行输出，
// 之前完全没有测试覆盖（`moon coverage analyze` 显示 main.mbt 116 行未覆盖）。
//
// 其中最要紧的是 `fmt` 对非有限值的处理 —— 见下面第一条测试。
//
// 断言用 `assert_eq` 而不是 `debug_inspect`：后者比的是带引号的 Debug 形式，
// 对字符串会多一层引号，读起来也绕。

///|
test "fmt：非有限值返回明确标记，不产生垃圾数字" {
  // 这是本文件的核心。`fmt` 内部走 `(v * 100 + 0.5).to_int()`，
  // `inf` 转换成整数会溢出成 i32 最大值 2147483647，
  // 于是 `fmt(inf, 2)` 曾输出 `21474836.47` —— 一个看起来正常的数字。
  // JSON 里 `sample_rate = 0` 时，界面上的时长就是这么来的。
  assert_eq(fmt(@double.infinity, 2), "inf")
  assert_eq(fmt(@double.neg_infinity, 2), "-inf")
  assert_eq(fmt(@double.not_a_number, 2), "nan")
  // digits = 0 时同样不能漏
  assert_eq(fmt(@double.infinity, 0), "inf")
  assert_eq(fmt(@double.neg_infinity, 0), "-inf")
  assert_eq(fmt(@double.not_a_number, 0), "nan")
}

///|
test "fmt：正负数与小数位" {
  assert_eq(fmt(3.14159, 2), "3.14")
  assert_eq(fmt(-2.5, 2), "-2.50")
  assert_eq(fmt(0.0, 2), "0.00")
  assert_eq(fmt(34.3, 2), "34.30")
  assert_eq(fmt(-0.04, 2), "-0.04")
}

///|
test "fmt：补零与进位" {
  // 小数部分不足 digits 位时要补零，否则 1.5 会显示成 "1.5" 而不是 "1.50"
  assert_eq(fmt(1.5, 2), "1.50")
  assert_eq(fmt(1.005, 3), "1.005")
  // 四舍五入进位
  assert_eq(fmt(1.999, 2), "2.00")
  assert_eq(fmt(0.005, 2), "0.01")
  // 整数部分为 0 时也不能漏掉前导 0
  assert_eq(fmt(0.5, 1), "0.5")
}

///|
test "fmt：digits = 0 不输出小数点" {
  assert_eq(fmt(23.0, 0), "23")
  assert_eq(fmt(-7.4, 0), "-7")
  assert_eq(fmt(0.6, 0), "1")
}

///|
/// 造一条斜率为 -10 dB/s、截距 -5 dB 的 EDC 直线。
///
/// 用 `fit_decay_time` 能直接吃 `Array[Double]` 这一点造出成功用例，
/// 不必绕合成信号 —— 而且跨包构造 `DecayResult` 是禁止的
/// （enum 构造器不对外，报 "read-only type"），所以只能靠公开 API 产出。
fn pass_edc() -> Array[Double] {
  let sr = 1000
  let n = 4000
  let out : Array[Double] = Array(capacity=n)
  let mut i = 0
  while i < n {
    let t = i.to_double() / sr.to_double()
    out.push(-10.0 * t - 5.0)
    i += 1
  }
  out
}

///|
test "render：成功结果含时间、斜率、区间与点数" {
  let res = @ra.fit_decay_time(pass_edc(), 1000, -5.0, -25.0)
  let line = render("T20", res)
  // 斜率 -10 dB/s → T20 = 60/10 = 6 s
  assert_true(line.contains("T20"), msg="应含标签，实际：" + line)
  assert_true(
    line.contains("6.000s"),
    msg="应含时间 6.000s，实际：" + line,
  )
  assert_true(line.contains("-10.0"), msg="应含斜率，实际：" + line)
  assert_true(line.contains("20"), msg="应含区间宽度，实际：" + line)
}

///|
test "render：四种失败原因各自给出可读说明" {
  // 每一种都要说清"为什么不可信"，而不是笼统一句失败。
  // 四类失败都由公开 API 产出，不构造枚举。
  let too_few : Array[Double] = [1.0, 2.0, 3.0]
  let line1 = render("EDT", @ra.fit_decay_time(too_few, 44100, -5.0, -25.0))
  assert_true(
    line1.contains("样本不足"),
    msg="TooFewSamples 应说明样本不足，实际：" + line1,
  )

  // 全零 EDC：dB 全是 -inf，区间内一个点都没有
  let n = 2000
  let zeros : Array[Double] = Array(capacity=n)
  let mut i = 0
  while i < n {
    zeros.push(0.0)
    i += 1
  }
  let full_zero = @ra.to_decibels(@ra.energy_decay_curve(zeros))
  let line2 = render("T20", @ra.fit_decay_time(full_zero, 44100, -5.0, -25.0))
  assert_true(
    line2.contains("区间内样本不足"),
    msg="InsufficientRangeInFit 应说明区间内样本不足，实际：" +
      line2,
  )

  // 区间内能量在增长 → 斜率为正
  let rising : Array[Double] = Array(capacity=n)
  let mut j = 0
  while j < n {
    rising.push(-25.0 + 20.0 * j.to_double() / (n - 1).to_double())
    j += 1
  }
  let line3 = render("T20", @ra.fit_decay_time(rising, 1000, -5.0, -25.0))
  assert_true(
    line3.contains("没有衰减"),
    msg="NonDecayingSlope 应说明能量没在衰减，实际：" + line3,
  )
  assert_true(
    line3.contains("脉冲响应"),
    msg="应提示输入可能不是脉冲响应，实际：" + line3,
  )

  // 噪声污染：评价区间下界 -25 dB，噪声底 -20 dB，余量 -5 dB < 20 dB
  let noisy = @ra.fit_decay_time(
    pass_edc(),
    1000,
    -5.0,
    -25.0,
    noise_floor_db=-20.0,
  )
  let line4 = render("T20", noisy)
  assert_true(
    line4.contains("不可用"),
    msg="噪声底不足时 T20 应判为不可用，实际：" + line4,
  )
  assert_true(
    line4.contains("噪声底"),
    msg="应提到噪声底，实际：" + line4,
  )
  assert_true(
    line4.contains("-5.0"),
    msg="应报告余量数值，实际：" + line4,
  )
}

///|
test "render：失败时不给出任何数字结果" {
  // 这是项目的主张：结果不可信时宁可拒绝给数字。
  // 成功格式里的 "s   (" 片段不该出现在失败行。
  let res = @ra.fit_decay_time(
    pass_edc(),
    1000,
    -5.0,
    -25.0,
    noise_floor_db=-20.0,
  )
  let line = render("T20", res)
  assert_true(
    !line.contains("s   ("),
    msg="失败行不该带成功格式的时间片段，实际：" + line,
  )
}

///|
test "render：噪声余量刚好达标时不报失败" {
  // 反向检验：校验不是越严越好。
  // 噪声底 -50 dB，评价区间下界 -25 dB → 余量 25 dB > 20 dB，应当通过。
  let res = @ra.fit_decay_time(
    pass_edc(),
    1000,
    -5.0,
    -25.0,
    noise_floor_db=-50.0,
  )
  let line = render("T20", res)
  assert_true(
    !line.contains("不可用"),
    msg="余量充足时不该判为不可用，实际：" + line,
  )
  assert_true(line.contains("6.000s"), msg="应给出时间，实际：" + line)
}

///|
test "render：可配置的噪声余量阈值生效" {
  // `require_margin_db` 此前从未被任何测试用过。
  // 造一个余量只有 2 dB 的情形（噪声底 -27 dB，评价区间下界 -25 dB）：
  // 按 ISO 3382 的 20 dB 要求判失败，放宽到 1 dB 就应通过。
  let edc = pass_edc()
  let strict = @ra.fit_decay_time(edc, 1000, -5.0, -25.0, noise_floor_db=-27.0)
  let loose = @ra.fit_decay_time(
    edc,
    1000,
    -5.0,
    -25.0,
    noise_floor_db=-27.0,
    require_margin_db=1.0,
  )
  let s = render("T20", strict)
  let l = render("T20", loose)
  assert_true(
    s.contains("不可用"),
    msg="默认阈值下应判失败，实际：" + s,
  )
  assert_true(
    !l.contains("不可用"),
    msg="放宽阈值后应通过，实际：" + l,
  )
  assert_true(
    l.contains("6.000s"),
    msg="通过时应给出时间，实际：" + l,
  )
}

///|
test "freq_line：含频率、阶次与类型" {
  let modes = @ra.list_modes(5.0, 4.0, 2.6, 4)
  assert_true(modes.length() >= 4, msg="应至少列出 4 个模态")
  let line = freq_line(modes[0])
  // 第一个轴向模态：34.30 Hz (1,0,0) 轴向
  assert_true(line.contains("34.30"), msg="应含频率，实际：" + line)
  assert_true(line.contains("(1,0,0)"), msg="应含阶次，实际：" + line)
  assert_true(line.contains("轴向"), msg="应含类型，实际：" + line)
}

///|
test "freq_line：三种模态类型都能正确标注" {
  // 三种类型分别对应阶次里非零分量的个数：1 个是轴向，2 个切向，3 个斜向。
  // 取足够多的模态，保证三类都覆盖到（(1,1,1) 这种斜向在 85.82 Hz，
  // 排在第 7 位左右）。
  let modes = @ra.list_modes(5.0, 4.0, 2.6, 20)
  let mut axial = 0
  let mut tangential = 0
  let mut oblique = 0
  let mut i = 0
  while i < modes.length() {
    let line = freq_line(modes[i])
    if line.contains("轴向") {
      axial += 1
    } else if line.contains("切向") {
      tangential += 1
    } else if line.contains("斜向") {
      oblique += 1
    }
    i += 1
  }
  assert_true(axial > 0, msg="应出现轴向模态")
  assert_true(tangential > 0, msg="应出现切向模态")
  assert_true(oblique > 0, msg="应出现斜向模态")
  // 前 20 个里轴向有 5 个：(1,0,0) (0,1,0) (0,0,1) (2,0,0) (0,2,0)
  assert_true(
    axial >= 3,
    msg="轴向模态数偏少，实际 " + axial.to_string(),
  )
}
