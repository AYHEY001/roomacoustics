// Schroeder EDC 反演的性质测试。
//
// 这些测试不需要外部语料：用确定性伪随机生成已知 T60 的合成 IR，
// 断言的是**物理性质**（EDC 单调、量级正确、噪声底被检出），
// 而不是某个具体小数值 —— 那些数值由 Python 侧交叉验证，见 docs/。

///|
/// 线性同余伪随机（Numerical Recipes 参数），保证可复现。
///
/// 用固定 LCG 而不是 @random：LCG 无依赖、跨平台结果一致，
/// 同一份代码在任何机器上生成同样的 IR，测试才可复现。
fn lcg_next(s : Int32) -> Int32 {
  (s * 1103515 + 12345) % 2147483647
}

///|
fn make_rng(_seed : Int32) -> (Int32) -> Int32 {
  lcg_next
}

///|
/// 生成已知 T60 的合成脉冲响应：白噪声乘指数包络。
///
/// 幅值包络 `10^(-3t/T60)`，即 t=T60 时衰减 60 dB。
fn synth_ir(
  rt60 : Double,
  sample_rate : Int32,
  seconds : Double,
  seed : Int32,
) -> Array[Double] {
  let n = (sample_rate.to_double() * seconds).to_int()
  let out = Array(capacity=n)
  let next = make_rng(seed)
  let mut state = seed
  let ramp_len = (sample_rate.to_double() * 0.005).to_int()
  let mut i = 0
  while i < n {
    state = next(state)
    // 把 [0, 2^31) 映射到 [-1, 1)
    let noise = state.to_double() / 1073741824.0 - 1.0
    let t = i.to_double() / sample_rate.to_double()
    let env = @math.pow(10.0, -3.0 * t / rt60)
    // 前 5ms 斜坡上升，避免起始直接满幅
    let ramp = if i < ramp_len {
      i.to_double() / ramp_len.to_double()
    } else {
      1.0
    }
    out.push(noise * env * ramp)
    i += 1
  }
  out
}

///|
/// 给合成 IR 叠加指定 SNR 的加性噪声。
fn synth_noisy_ir(
  rt60 : Double,
  sample_rate : Int32,
  seconds : Double,
  seed : Int32,
  snr_db : Double,
) -> Array[Double] {
  let ir = synth_ir(rt60, sample_rate, seconds, seed)
  let n = ir.length()
  let mut sum_sq = 0.0
  let mut i = 0
  while i < n {
    sum_sq += ir[i] * ir[i]
    i += 1
  }
  let signal_power = sum_sq / n.to_double()
  let noise_power = signal_power / @math.pow(10.0, snr_db / 10.0)
  let noise_amp = noise_power.sqrt()
  let next = make_rng(seed + 7777)
  let mut state = seed + 7777
  let mut j = 0
  while j < n {
    state = next(state)
    let noise = state.to_double() / 1073741824.0 - 1.0
    ir[j] = ir[j] + noise * noise_amp * 1.7320508
    j += 1
  }
  ir
}

///|
/// 构造 IR：默认 0.8s T60、44.1kHz、2.5 秒。
///
/// 签名写成多行：新版 `moon fmt` 对超过 ~75 字符的参数列表会拆行，
/// 单行写法在 CI 上会被判定为"需要格式化"。这里直接按新版格式写，
/// 两个工具链版本的结果就一致了。
fn synth_fixture(
  rt60 : Double,
  sample_rate : Int32,
  seed : Int32,
) -> Array[Double] {
  synth_ir(rt60, sample_rate, 2.5, seed)
}

///|
/// 构造带噪 IR，默认 SNR 20dB。
fn synth_noisy_fixture(
  rt60 : Double,
  sample_rate : Int32,
  snr_db : Double,
) -> Array[Double] {
  synth_noisy_ir(rt60, sample_rate, 2.5, 1, snr_db)
}

///|
test "EDC：逐点等于 sum(ir[i:]^2)" {
  // 这是 Schroeder 反演的定义式。用手算小数组核对，比对大数组更直观。
  let ir = [1.0, 2.0, 3.0, 4.0]
  let edc = energy_decay_curve(ir)
  debug_inspect(edc.length(), content="4")
  // sum = 1+4+9+16 = 30
  debug_inspect(edc[0], content="30")
  // sum from 1 = 4+9+16 = 29
  debug_inspect(edc[1], content="29")
  // sum from 2 = 9+16 = 25
  debug_inspect(edc[2], content="25")
  // sum from 3 = 16
  debug_inspect(edc[3], content="16")
}

///|
test "EDC：单调不增" {
  let ir = synth_fixture(0.8, 44100, 100)
  let edc = energy_decay_curve(ir)
  let n = edc.length()
  let mut violations = 0
  let mut i = 1
  while i < n {
    if edc[i] > edc[i - 1] {
      violations += 1
    }
    i += 1
  }
  debug_inspect(violations, content="0")
}

///|
test "EDC：末值远小于初值（能量确实泄掉）" {
  let ir = synth_fixture(0.8, 44100, 100)
  let edc = energy_decay_curve(ir)
  let ratio = edc[edc.length() - 1] / edc[0]
  assert_true(ratio < 0.0001, msg="末值应比初值小 4 个数量级以上")
}

///|
test "EDC：空数组不崩溃" {
  let empty : Array[Double] = []
  let edc = energy_decay_curve(empty)
  debug_inspect(edc.length(), content="0")
  let db = to_decibels(edc)
  debug_inspect(db.length(), content="0")
}

///|
test "EDC：全零信号返回 None 噪声底而非 NaN" {
  let n = 1000
  let zeros = Array(capacity=n) // 全 0 的 Double 数组
  let mut i = 0
  while i < n {
    zeros.push(0.0)
    i += 1
  }
  let nf = estimate_noise_floor(zeros)
  debug_inspect(nf, content="None")
}

///|
test "衰减时间：干净 IR 的 T20 接近真值" {
  // 理想指数衰减的 IR 上，反演出的 T20 应回到真值附近。
  // 允许 10% 误差：LCG 白噪声不是理想高斯，EDC 会有波动。
  let ir = synth_fixture(0.8, 44100, 100)
  let report = analyse_decay(ir, 44100)
  match report.t20 {
    Success(t, _, _, _) => {
      let rel = (t - 0.8).abs() / 0.8
      assert_true(rel < 0.10, msg="T20 应在真值 10% 以内，实际 {t}s")
    }
    Failed(_r, _) => assert_true(false, msg="干净 IR 不该拟合失败: {r}")
  }
}

///|
test "衰减时间：不同真值都能正确反演" {
  for rt in [0.4, 0.8, 1.2] {
    let ir = synth_fixture(rt, 44100, 100)
    let edc = energy_decay_curve(ir)
    let edc_db = to_decibels(edc)
    let res = fit_decay_time(edc_db, 44100, -5.0, -25.0)
    match res {
      Success(t, _, _, _) => {
        let rel = (t - rt).abs() / rt
        assert_true(rel < 0.10, msg="真值 {rt}s 时反演出 {t}s")
      }
      Failed(_r, _) =>
        assert_true(false, msg="真值 {rt}s 时拟合失败: {r}")
    }
  }
}

///|
test "衰减时间：EDT / T20 / T30 在真值附近聚拢" {
  let ir = synth_fixture(0.8, 44100, 100)
  let report = analyse_decay(ir, 44100)
  match report.edt {
    Success(t, _, _, _) =>
      assert_true((t - 0.8).abs() < 0.08, msg="EDT 应接近真值")
    Failed(_r, _) => assert_true(false, msg="EDT 不该失败: {r}")
  }
  match report.t20 {
    Success(t, _, _, _) =>
      assert_true((t - 0.8).abs() < 0.08, msg="T20 应接近真值")
    Failed(_r, _) => assert_true(false, msg="T20 不该失败: {r}")
  }
}

///|
test "噪声底：干净 IR 的噪声底远低于评价区间" {
  let ir = synth_fixture(0.8, 44100, 100)
  match estimate_noise_floor(ir) {
    Some(nf) =>
      assert_true(
        nf < -40.0,
        msg="干净 IR 的噪声底应很低（LCG 尾部趋于 0）",
      )
    None => fail("干净 IR 应能算出噪声底")
  }
}

///|
test "噪声底：加噪后噪声底显著抬高" {
  let clean = synth_fixture(0.8, 44100, 100)
  let noisy = synth_noisy_fixture(0.8, 44100, 20)
  let nf_clean = estimate_noise_floor(clean).unwrap()
  let nf_noisy = estimate_noise_floor(noisy).unwrap()
  assert_true(
    nf_noisy > nf_clean + 20.0,
    msg="加噪后噪声底应显著抬高",
  )
}

///|
test "噪声污染：SNR 20dB 时 T20 必须被检出为不可信" {
  // **本项目最核心的行为**：Python 不做校验会照报 T20=6.69s（真值 0.8s）。
  // 本项目必须在评价区间落进噪声底时返回 ContaminatedByNoise，
  // 而不是给出一个看起来正常、实际错了近 8 倍的数字。
  let ir = synth_noisy_fixture(0.8, 44100, 20)
  let report = analyse_decay(ir, 44100)
  match report.t20 {
    Success(_t, _, _, _) =>
      assert_true(
        false,
        msg="T20 落在噪声底里应报 ContaminatedByNoise，却给出了数值",
      )
    Failed(ContaminatedByNoise(margin), _) =>
      assert_true(
        margin < 0.0,
        msg="余量应为负，说明评价区间确实低于噪声底",
      )
    Failed(_r, _) =>
      assert_true(false, msg="失败原因应是 ContaminatedByNoise")
  }
}

///|
test "噪声污染：SNR 60dB 时 T20 仍可信" {
  // 反向检验：不是所有加噪信号都要报失败。
  // 校验过严会让工具在正常录音上不可用。
  let ir = synth_noisy_fixture(0.8, 44100, 60)
  let report = analyse_decay(ir, 44100)
  match report.t20 {
    Success(t, _, _, _) =>
      assert_true(
        (t - 0.8).abs() < 0.1,
        msg="SNR 60dB 时 T20 应仍接近真值",
      )
    Failed(_r, _) => assert_true(false, msg="SNR 60dB 不该报失败: {r}")
  }
}

///|
test "噪声污染：T30 比 T20 更容易被判定为污染" {
  // T30 区间下界 -35dB 比 T20 的 -25dB 更深，因此更容易落进噪声底。
  // 在同一个中等 SNR 的信号上，可能出现 T20 可信、T30 不可信。
  let ir = synth_noisy_fixture(0.8, 44100, 30)
  let report = analyse_decay(ir, 44100)
  let t20_ok = match report.t20 {
    Success(_, _, _, _) => true
    Failed(_, _) => false
  }
  let t30_ok = match report.t30 {
    Success(_, _, _, _) => true
    Failed(_, _) => false
  }
  // T30 的成功率不应高于 T20
  assert_true(
    !t30_ok || t20_ok,
    msg="T30 区间更深，不应比 T20 更容易成功",
  )
}

///|
test "拟合失败：样本太少时明确报错" {
  let tiny = synth_fixture(0.8, 44100, 100)
  // 截断到 5 个样本，远少于拟合所需
  let short = Array(capacity=5)
  let mut i = 0
  while i < 5 {
    short.push(tiny[i])
    i += 1
  }
  let edc = energy_decay_curve(short)
  let edc_db = to_decibels(edc)
  let res = fit_decay_time(edc_db, 44100, -5.0, -25.0)
  match res {
    Success(_, _, _, _) => fail("样本太少不该拟合成功")
    Failed(TooFewSamples(n), _) => debug_inspect(n, content="5")
    Failed(_r, _) =>
      assert_true(false, msg="应为 TooFewSamples，实际 {other}")
  }
}

///|
test "拟合失败：全零信号报 InsufficientRangeInFit" {
  // 探针实测：恒定信号的 EDC 是一条下降直线（dB 从 0 降到 -37），
  // 斜率为负，拟合"成功"但结果无意义 —— 所以不能用恒定信号做反例。
  //
  // 真正的反例是全零信号：EDC 全为 0，dB 全是 -inf，
  // 区间内一个点都没有，应当报 InsufficientRangeInFit。
  //
  // 这条测试记录的是一个曾经的错误断言：
  // 一开始我以为"恒定信号"能验证 NonDecayingSlope，
  // 实际它给出的是完全正常的衰减直线。先写探针才发现了这个错误。
  let n = 5000
  let zeros = Array(capacity=n)
  let mut i = 0
  while i < n {
    zeros.push(0.0)
    i += 1
  }
  let edc = energy_decay_curve(zeros)
  let edc_db = to_decibels(edc)
  let res = fit_decay_time(edc_db, 44100, -5.0, -25.0)
  match res {
    Success(_, _, _, _) =>
      assert_true(false, msg="全零信号不该拟合出衰减时间")
    Failed(InsufficientRangeInFit(width, count), _) => {
      debug_inspect(width, content="20")
      debug_inspect(count, content="0")
    }
    Failed(_r, _) =>
      assert_true(false, msg="应为 InsufficientRangeInFit，实际 {other}")
  }
}

///|
test "恒定信号：EDC 是下降直线，但这种输入没有物理意义" {
  // 记录探针实测到的行为，避免以后误以为 Constant 信号会触发
  // NonDecayingSlope。EDC[i] = (n - i)，线性下降，dB 也是直线。
  let n = 5000
  let flat = Array(capacity=n)
  let mut i = 0
  while i < n {
    flat.push(1.0)
    i += 1
  }
  let edc = energy_decay_curve(flat)
  debug_inspect(edc[0], content="5000")
  debug_inspect(edc[2500], content="2500")
  let edc_db = to_decibels(edc)
  // 末尾只剩 1 个样本，能量比 5000 低 36.99 dB
  debug_inspect(edc_db[4999], content="-36.98970004336019")
}

///|
test "拟合失败：非法采样率不崩溃" {
  let ir = synth_fixture(0.8, 44100, 100)
  let edc = energy_decay_curve(ir)
  let edc_db = to_decibels(edc)
  let res = fit_decay_time(edc_db, 0, -5.0, -25.0)
  match res {
    Success(_, _, _, _) => fail("采样率 0 不该拟合成功")
    Failed(_, _) => ()
  }
}
