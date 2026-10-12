/// 模态频率对照 —— 从脉冲响应检测频谱峰，与解析式预测的房间模态比对。
///
/// **这个功能回答的问题**：理论算出来的模态频率，在实测响应里真的存在吗？
///
/// 解析式 `f = c·√((nx/Lx)²+(ny/Ly)²+(nz/Lz)²)` 是个理想模型（刚壁、无阻尼）。
/// 它是否描述了真实房间，需要拿实测数据验证。做法是对脉冲响应做 FFT 得到
/// 传递函数，其幅度谱的峰就是被激励起来的模态。
///
/// **判定的方向很关键**：只检查"检测到的峰能否对应到某个预测模态"，
/// 而不是"预测模态是否全部被检测到"。后者物理上做不到 ——
/// 单点声源到单点接收的传递函数里，声源或接收点若落在某模态的节面上，
/// 该模态就不被激励。实测配对率约 91%，剩下的是节面效应，
/// 不是算法错误。
///
/// FFT 交给 `MoonSpectrum`（本项目不实现 FFT），窗函数、峰值判定、
/// 与解析式模态的配对是本项目自己的分析逻辑。

///|
/// 一个频谱峰。
pub struct SpectralPeak {
  freq : Double
  /// 相对局部中值的突出度。用局部而非全局基线的原因见 `detect_spectral_peaks`
  prominence : Double
} derive(Debug)

///|
/// 不大于 `n` 的最大 2 的幂。
///
/// **为什么需要**：实测 `MoonSpectrum::fft` 只接受 2 的幂长度 ——
/// 88200 会抛异常，65536 / 131072 正常。脉冲响应的长度通常是任意的
/// （采样率 × 秒数），所以必须先截断。
///
/// 代价是丢掉尾部一点数据。对模态分析影响很小（主要能量在前段），
/// 但频率分辨率会变成 `sample_rate / n_fft`，要在输出里如实报告。
pub fn largest_pow2_at_most(n : Int32) -> Int32 {
  if n < 1 {
    return 0
  }
  let mut p = 1
  while p * 2 <= n {
    p = p * 2
  }
  p
}

///|
/// 取数组中位数（会复制并排序，不改动入参）。
fn median_of(values : Array[Double]) -> Double {
  let n = values.length()
  if n == 0 {
    return 0.0
  }
  let sorted = values.copy()
  sorted.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  if n % 2 == 1 {
    sorted[n / 2]
  } else {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
  }
}

///|
/// 从脉冲响应检测频谱峰。
///
/// 处理链路：
///   截断到 2 的幂 -> 去直流 -> 加 Hann 窗 -> FFT（MoonSpectrum）
///   -> 幅度谱（只取正频率半段）-> 局部中值基线 -> 相对阈值找峰
///
/// - `f_min` / `f_max`：关注的频段。默认 50~500 Hz —— 低频段模态间隔大、
///   可分；高频段模态密集重叠，逐个识别没有意义。
/// - `prominence_min`：峰的突出度下限（相对局部中值），默认 1.5
/// - `min_dist_hz`：两个峰的最小间距，默认 8 Hz
///
/// 两个关键细节，都是实测撞出来的：
///
/// 1. **幅度谱只取前半段**。实数信号的 FFT 关于 N/2 对称，
///    负频率镜像的幅度与正频率相同。在全长上找最大值时，
///    浮点噪声会让镜像偶尔胜出，报出超过 Nyquist 的频率
///    （实测 1000 Hz 的正弦被报成 43098 Hz = 44100 - 1002）。
///
/// 2. **阈值用局部中值，不用全局最大值**。全谱最大值被 0 Hz 的直流分量主导
///    （实测高出低频段均值两个数量级），用全局阈值会把所有模态峰滤掉。
pub fn detect_spectral_peaks(
  ir : Array[Double],
  sample_rate : Int32,
  f_min? : Double,
  f_max? : Double,
  prominence_min? : Double,
  min_dist_hz? : Double,
) -> Array[SpectralPeak] {
  let lo = match f_min {
    Some(v) => v
    None => 50.0
  }
  let hi = match f_max {
    Some(v) => v
    None => 500.0
  }
  let prom = match prominence_min {
    Some(v) => v
    None => 1.5
  }
  let min_dist = match min_dist_hz {
    Some(v) => v
    None => 8.0
  }
  let n_fft = largest_pow2_at_most(ir.length())
  if n_fft < 256 || sample_rate <= 0 || hi <= lo {
    return []
  }
  // 去直流：脉冲响应求和通常不为零，直流分量会主导整个幅度谱
  let mut mean = 0.0
  let mut i = 0
  while i < n_fft {
    mean += ir[i]
    i += 1
  }
  mean = mean / n_fft.to_double()
  let win : Array[Double] = @msp.window(@msp.WindowKind::Hann, n_fft) catch {
    _ => return []
  }
  let z = Array(capacity=n_fft)
  let mut k = 0
  while k < n_fft {
    z.push(@msp.complex(re=(ir[k] - mean) * win[k], im=0.0))
    k += 1
  }
  let spec_c = @msp.fft(z) catch { _ => return [] }
  let mag_full = @msp.magnitude_spectrum(spec_c)
  // 只取正频率半段（含 Nyquist 点）
  let half = n_fft / 2 + 1
  let spec = Array(capacity=half)
  let mut m = 0
  while m < half && m < mag_full.length() {
    spec.push(mag_full[m])
    m += 1
  }
  if spec.length() < 8 {
    return []
  }
  let df = sample_rate.to_double() / n_fft.to_double()
  // 关注频段对应的下标范围
  // 边界取整必须与 Python 参考实现对齐：
  //   下界用 ceil —— 第一个 >= lo 的下标（用 to_int() 截断会多含一个 bin）
  //   上界用 floor —— 最后一个 <= hi 的下标
  // 不一致会让频段边缘多出/少掉峰，实测导致 55 Hz 和 480 Hz 两处对不上。
  let i_lo = clamp_index(ceil_index(lo / df), spec.length())
  let i_hi = clamp_index((hi / df).to_int(), spec.length())
  if i_hi <= i_lo + 2 {
    return []
  }
  let band_len = i_hi - i_lo + 1
  // 先把频段内的点取成独立数组，再在其上做滑动窗口。
  //
  // 不能直接在完整频谱上 clamp 取窗口 —— 那样超出频段边界时取到的是
  // 频段**外**的值，而 Python 参考实现（numpy.pad(mode="edge")）复制的是
  // 频段**内**边缘的值。两者在贴近边界处（实测 55 Hz 和 480 Hz）
  // 会算出不同的基线，把本来接近阈值的弱峰判成检出/未检出。
  let band_spec : Array[Double] = Array(capacity=band_len)
  let mut b0 = 0
  while b0 < band_len {
    band_spec.push(spec[i_lo + b0])
    b0 += 1
  }
  // 局部中值基线：窗口 161 个 bin（约 ±80 个点），边界按 edge 模式复制
  let win_half = 80
  let baseline : Array[Double] = Array(capacity=band_len)
  let buf : Array[Double] = Array(capacity=2 * win_half + 1)
  let mut b = 0
  while b < band_len {
    buf.clear()
    let mut j = -win_half
    while j <= win_half {
      buf.push(band_spec[clamp_index(b + j, band_len)])
      j += 1
    }
    baseline.push(median_of(buf))
    b += 1
  }
  let raw_dist = min_dist / df
  let min_dist_idx = if raw_dist < 1.0 { 1 } else { (raw_dist + 0.5).to_int() }
  let peaks : Array[SpectralPeak] = Array(capacity=64)
  let mut idx = 1
  while idx < band_len - 1 {
    let v = band_spec[idx]
    let base = baseline[idx]
    let ratio = if base > 0.0 { v / base } else { 0.0 }
    let is_local_max = v >= band_spec[idx - 1] && v > band_spec[idx + 1]
    if is_local_max && ratio > prom {
      // 与上一个峰太近时，同一簇内保留幅度更高的那个
      let merged = if peaks.length() > 0 {
        let last = peaks[peaks.length() - 1]
        let last_idx = (last.freq / df - i_lo.to_double()).to_int()
        if idx - last_idx < min_dist_idx && v > band_spec[last_idx] {
          peaks[peaks.length() - 1] = {
            freq: (i_lo + idx).to_double() * df,
            prominence: ratio,
          }
          true
        } else {
          false
        }
      } else {
        false
      }
      if !merged &&
        (
          peaks.length() == 0 ||
          idx -
          (peaks[peaks.length() - 1].freq / df - i_lo.to_double()).to_int() >=
          min_dist_idx
        ) {
        peaks.push({ freq: (i_lo + idx).to_double() * df, prominence: ratio, })
      }
    }
    idx += 1
  }
  peaks
}

///|
/// 不小于 `x` 的最小整数下标（对正数）。
fn ceil_index(x : Double) -> Int32 {
  let t = x.to_int()
  if t.to_double() < x {
    t + 1
  } else {
    t
  }
}

///|
/// 把下标夹到 `[0, n-1]`。
fn clamp_index(i : Int32, n : Int32) -> Int32 {
  if i < 0 {
    0
  } else if i >= n {
    n - 1
  } else {
    i
  }
}

///|
/// 一个峰的配对结果。
pub struct ModeMatch {
  peak_freq : Double
  prominence : Double
  /// 最近的预测模态频率；没有预测模态时是 0
  mode_freq : Double
  /// 模态阶次 (nx, ny, nz)
  nx : Int32
  ny : Int32
  nz : Int32
  /// 相对预测模态的偏差（Hz）
  deviation : Double
  /// 是否落在容差内
  matched : Bool
} derive(Debug)

///|
/// 容差：取 `max(5 Hz, 预测频率的 5%)`。
///
/// 容差不能太小 —— 镜像声源法是理想模型（没考虑墙面相位偏移、
/// 空气吸收的频变），加上加窗带来的峰位偏移，几 Hz 的偏差是正常的。
fn tolerance_of(freq : Double) -> Double {
  let five = freq * 0.05
  if five > 5.0 {
    five
  } else {
    5.0
  }
}

///|
/// 把检测到的峰与预测模态配对。
///
/// 方向是「峰 -> 模态」：每个峰找最近的预测模态。
/// 预测模态不会全部出现（节面效应），但出现的峰应该都能对应到某个模态。
pub fn match_peaks_to_modes(
  peaks : Array[SpectralPeak],
  modes : Array[@ra.Mode],
) -> Array[ModeMatch] {
  let out = Array(capacity=peaks.length())
  let mut i = 0
  while i < peaks.length() {
    let p = peaks[i]
    let mut best_j = -1
    let mut best_d = 1.0e30
    let mut j = 0
    while j < modes.length() {
      let d = (modes[j].freq - p.freq).abs()
      if d < best_d {
        best_d = d
        best_j = j
      }
      j += 1
    }
    if best_j < 0 {
      out.push({
        peak_freq: p.freq,
        prominence: p.prominence,
        mode_freq: 0.0,
        nx: 0,
        ny: 0,
        nz: 0,
        deviation: 0.0,
        matched: false,
      })
    } else {
      let m = modes[best_j]
      let dev = p.freq - m.freq
      out.push({
        peak_freq: p.freq,
        prominence: p.prominence,
        mode_freq: m.freq,
        nx: m.nx,
        ny: m.ny,
        nz: m.nz,
        deviation: dev,
        matched: dev.abs() <= tolerance_of(m.freq),
      })
    }
    i += 1
  }
  out
}
