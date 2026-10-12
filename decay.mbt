/// 衰减时间拟合：从能量衰减曲线（EDC）上读出 EDT / T20 / T30。
///
/// 定义（ISO 3382）：
/// - **EDT**（Early Decay Time）：0 dB → -10 dB 区间的拟合直线外推到 -60 dB
/// - **T20**：-5 dB → -25 dB 区间外推到 -60 dB
/// - **T30**：-5 dB → -35 dB 区间外推到 -60 dB
///
/// T30 区间最长、统计上最稳，但要求 EDC 底部有足够动态范围 ——
/// 一旦区间落进噪声底，算出来的时间会严重偏大（实测 SNR 20dB 时偏差 +746%）。
/// 因此本模块在校验区间有效性后才返回结果，无效时给 `None` 而非编造数字。

///|
/// 一次衰减时间拟合的结果。
pub enum DecayResult {
  /// 拟合成功。字段依次为：
  /// 时间（秒）、衰减斜率（dB/s，负值）、拟合区间宽度（dB）、参与拟合的样本点数
  Success(Double, Double, Double, Int32)
  /// 拟合失败。字段依次为：失败原因、评价区间到噪声底的余量（dB）
  Failed(DecayFailReason, Double?)
} derive(Debug, Eq)

///|
pub extend DecayResult with Eq::{not_equal, equal}

///|
pub extend DecayResult with @debug.Debug::{to_repr}

///|
/// 拟合失败的原因。
pub enum DecayFailReason {
  /// EDC 上的样本点太少，不足以拟合
  TooFewSamples(Int32)
  /// 在指定区间内没有足够的样本点（区间宽度，参与点数）
  InsufficientRangeInFit(Double, Int32)
  /// 拟合出的斜率非负，说明能量没有在衰减 —— 输入可能不是脉冲响应
  NonDecayingSlope(Double)
  /// 评价区间落进了噪声底，结果不可信（余量 dB）
  ContaminatedByNoise(Double)
} derive(Debug, Eq)

///|
pub extend DecayFailReason with Eq::{not_equal, equal}

///|
pub extend DecayFailReason with @debug.Debug::{to_repr}

///|
/// 从 dB 序列上做区间最小二乘拟合，外推到 -60 dB。
///
/// - `edc_db`：EDC 的 dB 序列
/// - `sample_rate`：采样率（Hz）
/// - `from_db`：拟合区间上界（dB，接近 0 的负值）
/// - `to_db`：拟合区间下界（dB，更负）
/// - `noise_floor_db`：噪声底（dB）。若给定且区间下界落入噪声底，返回失败
/// - `require_margin_db`：评价区间下界须低于噪声底至少这么多 dB 才算有效。
///   ISO 3382 的要求是 20 dB。
pub fn fit_decay_time(
  edc_db : Array[Double],
  sample_rate : Int32,
  from_db : Double,
  to_db : Double,
  noise_floor_db? : Double,
  require_margin_db? : Double,
) -> DecayResult {
  let need_margin = match require_margin_db {
    Some(m) => m
    None => 20.0
  }
  let n = edc_db.length()
  if sample_rate <= 0 {
    return Failed(TooFewSamples(n), None)
  }
  if n < 16 {
    return Failed(TooFewSamples(n), None)
  }
  // 噪声底未知时不校验 —— 但这不代表信号干净，只是"查不出来"
  match noise_floor_db {
    Some(nf) => {
      // ISO 3382：评价区间下界须比噪声底再低 need_margin_db
      let margin = to_db - nf
      if margin < need_margin {
        return Failed(ContaminatedByNoise(margin), Some(margin))
      }
      collect_fit(edc_db, sample_rate, from_db, to_db, Some(margin))
    }
    None => collect_fit(edc_db, sample_rate, from_db, to_db, None)
  }
}

///|
/// 在指定区间收集样本并做最小二乘拟合。
fn collect_fit(
  edc_db : Array[Double],
  sample_rate : Int32,
  from_db : Double,
  to_db : Double,
  noise_margin : Double?,
) -> DecayResult {
  let n = edc_db.length()
  let times = Array(capacity=64)
  let values = Array(capacity=64)
  let mut i = 0
  while i < n {
    let v = edc_db[i]
    if v <= from_db && v >= to_db && !v.is_nan() {
      times.push(i.to_double() / sample_rate.to_double())
      values.push(v)
    }
    i += 1
  }
  let count = times.length()
  // 拟合直线至少要 10 个点才有意义
  if count < 10 {
    return Failed(InsufficientRangeInFit(from_db - to_db, count), noise_margin)
  }
  let (slope, intercept) = least_squares_line(times, values)
  if slope >= 0.0 || slope.is_nan() {
    return Failed(NonDecayingSlope(slope), noise_margin)
  }
  let time = (-60.0 - intercept) / slope
  Success(time, slope, from_db - to_db, count)
}

///|
/// 最小二乘直线拟合，返回 (斜率, 截距)。
///
/// 闭式解：斜率 = Cov(x,y) / Var(x)。样本少于 2 个返回 (0, 0)。
fn least_squares_line(
  xs : Array[Double],
  ys : Array[Double],
) -> (Double, Double) {
  let n = xs.length()
  if n < 2 {
    return (0.0, 0.0)
  }
  let mut sx = 0.0
  let mut sy = 0.0
  let mut i = 0
  while i < n {
    sx += xs[i]
    sy += ys[i]
    i += 1
  }
  let mx = sx / n.to_double()
  let my = sy / n.to_double()
  let mut sxy = 0.0
  let mut sxx = 0.0
  let mut k = 0
  while k < n {
    let dx = xs[k] - mx
    sxy += dx * (ys[k] - my)
    sxx += dx * dx
    k += 1
  }
  if sxx == 0.0 {
    return (0.0, 0.0)
  }
  let slope = sxy / sxx
  let intercept = my - slope * mx
  (slope, intercept)
}

///|
/// 从脉冲响应直接得到完整的衰减时间报告。
///
/// 依次计算 EDT / T20 / T30，任一区间被噪声污染时对应项为 `Failed`，
/// 而不是给一个看起来正常但实际错误的数字。
pub struct DecayReport {
  edt : DecayResult
  t20 : DecayResult
  t30 : DecayResult
  noise_floor_db : Double?
  sample_rate : Int32
}

///|
/// 一次性拟合 EDT / T20 / T30。噪声底已知时带校验，未知时不校验。
fn fit_all(
  edc_db : Array[Double],
  sample_rate : Int32,
  noise_floor : Double?,
) -> (DecayResult, DecayResult, DecayResult) {
  match noise_floor {
    Some(f) =>
      (
        fit_decay_time(edc_db, sample_rate, 0.0, -10.0, noise_floor_db=f),
        fit_decay_time(edc_db, sample_rate, -5.0, -25.0, noise_floor_db=f),
        fit_decay_time(edc_db, sample_rate, -5.0, -35.0, noise_floor_db=f),
      )
    None =>
      (
        fit_decay_time(edc_db, sample_rate, 0.0, -10.0),
        fit_decay_time(edc_db, sample_rate, -5.0, -25.0),
        fit_decay_time(edc_db, sample_rate, -5.0, -35.0),
      )
  }
}

///|
/// 对脉冲响应做完整分析：EDC、噪声底、三个衰减时间。
///
/// - `ir`：脉冲响应采样点
/// - `sample_rate`：采样率（Hz）
/// - `noise_tail_fraction`：估计噪声底所用的尾部比例，默认 0.1
pub fn analyse_decay(
  ir : Array[Double],
  sample_rate : Int32,
  noise_tail_fraction? : Double,
) -> DecayReport {
  let edc = energy_decay_curve(ir)
  let edc_db = to_decibels(edc)
  // 噪声底可能算不出来（样本太少 / 全零信号）。算不出来时不做污染校验，
  // 但这不代表信号干净 —— 调用方应从 noise_floor_db is None 看出这一点。
  let nf = match noise_tail_fraction {
    Some(frac) => estimate_noise_floor(ir, tail_fraction=frac)
    None => estimate_noise_floor(ir)
  }
  let (edt, t20, t30) = fit_all(edc_db, sample_rate, nf)
  { edt, t20, t30, noise_floor_db: nf, sample_rate, }
}
