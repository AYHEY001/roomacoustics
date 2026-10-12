// 模态对照功能的回归测试。
//
// 语料 `testdata/room_5x4x2.6_image_source.wav` 由
// docs/make_image_source_ir.py 用**镜像声源法**生成 ——
// 它不是"白噪声 × 指数包络"那种人造信号，而是 5.0×4.0×2.6 m 房间
// 的真实脉冲响应模型，频谱里带真实的房间模态结构。
//
// 用它的原因是：要验证「解析式预测的模态频率是否真的出现在实测响应里」，
// 输入信号本身必须含有模态信息。平坦频谱的信号做不到这件事。
//
// Python 参考实现（同一份语料、同一套算法）给出 21/23 = 91% 配对率，
// 且 23 个峰的频率逐位一致。这里的断言以此为准。

///|
test "2 的幂截断：边界与常规值" {
  // FFT 只接受 2 的幂长度，所以截断函数必须准确
  debug_inspect(largest_pow2_at_most(88200), content="65536")
  debug_inspect(largest_pow2_at_most(65536), content="65536")
  debug_inspect(largest_pow2_at_most(65535), content="32768")
  debug_inspect(largest_pow2_at_most(1), content="1")
  debug_inspect(largest_pow2_at_most(0), content="0")
}

///|
test "频谱峰检测：纯音能检出正确频率" {
  // 自检：给一个已知频率的正弦，检测结果必须落在它附近。
  // 检测算法本身要先证明是准的，再拿去看房间数据。
  let sr = 44100
  let n = 65536
  let target = 222.95
  let sig = Array(capacity=n)
  let mut i = 0
  while i < n {
    let t = i.to_double() / sr.to_double()
    sig.push(@math.sin(2.0 * 3.14159265358979 * target * t))
    i += 1
  }
  let peaks = detect_spectral_peaks(sig, sr)
  // 应该检出至少一个峰，且最近的峰在 target 附近
  assert_true(peaks.length() > 0, msg="纯音应能检出峰")
  let mut best = peaks[0]
  let mut j = 1
  while j < peaks.length() {
    if (peaks[j].freq - target).abs() < (best.freq - target).abs() {
      best = peaks[j]
    }
    j += 1
  }
  let dev = (best.freq - target).abs()
  // 分辨率 44100/65536 = 0.673 Hz，取 1 Hz 容差
  assert_true(
    dev < 1.0,
    msg="纯音 " +
      target.to_string() +
      " Hz 检出的最近峰是 " +
      best.freq.to_string() +
      "（偏差 " +
      dev.to_string() +
      "）",
  )
}

///|
test "频谱峰检测：空数组与过短输入不崩溃" {
  let empty : Array[Double] = []
  debug_inspect(detect_spectral_peaks(empty, 44100).length(), content="0")
  // 只有 100 个点，远少于最小要求
  let tiny = Array(capacity=100)
  let mut i = 0
  while i < 100 {
    tiny.push(1.0)
    i += 1
  }
  debug_inspect(detect_spectral_peaks(tiny, 44100).length(), content="0")
}

///|
test "模态对照：镜像声源 IR 的配对率达到 Python 参考水平" {
  // **这是本功能最核心的一条测试。**
  //
  // Python 参考实现（同一份语料、同一套算法、numpy FFT）给出
  // 23/23 = 100%，全部 23 个峰都能对应到预测模态。
  // MoonBit 侧用自己的 FFT（MoonSpectrum）实现，必须达到同一水平。
  //
  // 断言留出余量：配对率 >= 90%（允许 2 个峰的浮动），
  // 峰数在 21~25 之间。不写死 23/23 是因为两个 FFT 实现存在极微小的
  // 浮点差异，贴近阈值的弱峰可能翻转 —— 强行卡死会让测试变得脆弱。
  //
  // 这个数字曾经是 91%（21/23），当时有两个峰被判"未配对"。
  // 排查后发现**问题不在检测算法，而在预测端**：
  // modal_frequency 的公式少了 1/2，导致频率整体翻倍、
  // 只保留偶数阶模态，(1,1,0) 和 (3,0,0) 这类模态根本没进候选集。
  // 修正公式后升到 100%。
  let loaded = load_wav_ir("testdata/room_5x4x2.6_image_source.wav")
  let data = match loaded {
    Ok(d) => d
    Err(e) => {
      assert_true(false, msg="读取语料失败：" + e)
      return
    }
  }
  let peaks = detect_spectral_peaks(data.ir, data.sample_rate)
  assert_true(
    peaks.length() >= 21 && peaks.length() <= 25,
    msg="峰数应在 21~25 之间，实际 " + peaks.length().to_string(),
  )
  // 取全部范围内的模态再按频率截断 —— 不能用"前 N 个"。
  // 模态密度随频率平方增长（Weyl），5×4×2.6 m 房间在 500 Hz 以下
  // 有几百个模态；取前 120 个只覆盖到约 280 Hz，
  // 300~500 Hz 的峰会因"附近没有预测模态"而成片误判。
  let all_modes = @ra.list_modes(5.0, 4.0, 2.6, 4000)
  let modes : Array[@ra.Mode] = Array(capacity=1024)
  let mut mi = 0
  while mi < all_modes.length() {
    if all_modes[mi].freq <= 520.0 {
      modes.push(all_modes[mi])
    }
    mi += 1
  }
  let matches = match_peaks_to_modes(peaks, modes)
  let mut matched = 0
  let mut i = 0
  while i < matches.length() {
    if matches[i].matched {
      matched += 1
    }
    i += 1
  }
  let rate = matched.to_double() / matches.length().to_double()
  assert_true(
    rate >= 0.90,
    msg="配对率应 >= 90%（Python 参考 100%），实际 " +
      matched.to_string() +
      "/" +
      matches.length().to_string(),
  )
}

///|
test "模态对照：几个强模态的频率必须落在容差内" {
  // 上面测的是整体配对率；这条盯住几个具体的强模态。
  // 它们来自 Python 参考实现里偏差最小的那几个（0.04 / 0.09 / 0.22 Hz），
  // 是「解析式预测 == 实测出现」最硬的证据。
  let loaded = load_wav_ir("testdata/room_5x4x2.6_image_source.wav")
  let data = match loaded {
    Ok(d) => d
    Err(_) => {
      assert_true(false, msg="读取语料失败")
      return
    }
  }
  let peaks = detect_spectral_peaks(data.ir, data.sample_rate)
  // (预测模态频率, 容差 Hz)
  let expected = [(68.60, 2.0), (85.75, 2.0), (131.92, 2.5), (297.39, 2.0)]
  let mut k = 0
  while k < expected.length() {
    let (freq, tol) = expected[k]
    let mut best_d = 1.0e30
    let mut j = 0
    while j < peaks.length() {
      let d = (peaks[j].freq - freq).abs()
      if d < best_d {
        best_d = d
      }
      j += 1
    }
    assert_true(
      best_d <= tol,
      msg="预测模态 " +
        freq.to_string() +
        " Hz 附近应有检测峰（容差 " +
        tol.to_string() +
        "），最近峰距 " +
        best_d.to_string(),
    )
    k += 1
  }
}

///|
test "模态对照：容差随频率放宽（低频按绝对量，高频按比例）" {
  // 容差 = max(5 Hz, 5%)。低频段模态间隔小，用绝对容差；
  // 高频段 5 Hz 相对太严，用比例。
  assert_true(tolerance_of(68.6) == 5.0, msg="低频用绝对容差 5 Hz")
  assert_true(tolerance_of(500.0) == 25.0, msg="500 Hz 的 5% 是 25 Hz")
  assert_true(tolerance_of(1000.0) == 50.0, msg="高频用比例容差")
}
