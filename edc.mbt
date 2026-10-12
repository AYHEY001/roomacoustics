/// 能量衰减曲线（Energy Decay Curve, EDC）的 Schroeder 反演。
///
/// 房间脉冲响应是一段指数衰减的声压记录。Schroeder 反演把这段"声音随时间变小"
/// 的过程转换成一条可拟合的曲线：对声压平方做**从后往前的累积和**。
///
/// ```
/// EDC[i] = Σ  p[n]²   (n = i .. 末尾)
/// ```
///
/// 之所以能这样反演，是因为在扩散声场中，某时刻的能量衰变量等于
/// "从该时刻起到声场结束为止释放出的总能量"。
///
/// 返回的数组与输入等长，单位为声压平方（相对量纲）。

///|
/// 对脉冲响应做 Schroeder 积分。
///
/// - `ir`：脉冲响应采样点，任意实数值
/// - 返回：EDC 序列，与 `ir` 等长
///
/// 空数组返回空数组。
pub fn energy_decay_curve(ir : Array[Double]) -> Array[Double] {
  let n = ir.length()
  let out = Array(capacity=n)
  let mut acc = 0.0
  // 先从后往前累积（此时 out 是逆序的），再翻回来
  let mut i = n - 1
  while i >= 0 {
    let s = ir[i]
    acc += s * s
    out.push(acc)
    i -= 1
  }
  reverse_in_place(out)
  out
}

///|
/// 原地反转数组。`Array` 没有 `reverse` 方法，这里手写。
fn reverse_in_place(arr : Array[Double]) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  let mut lo = 0
  let mut hi = n - 1
  while lo < hi {
    let tmp = arr[lo]
    arr[lo] = arr[hi]
    arr[hi] = tmp
    lo += 1
    hi -= 1
  }
}

///|
/// 把能量衰减曲线换算成相对 dB（0 = 曲线最大值）。
///
/// - `edc`：EDC 序列
/// - 返回：dB 序列。能量为 0 的点返回 `@double.neg_infinity`（曲线在底部趋于负无穷）
pub fn to_decibels(edc : Array[Double]) -> Array[Double] {
  let n = edc.length()
  let out = Array(capacity=n)
  if n == 0 {
    return out
  }
  // 归一化基准取曲线最大值（理论上就是第 0 点，但脉冲响应可能不从 0 开始）
  let mut peak = edc[0]
  let mut i = 1
  while i < n {
    if edc[i] > peak {
      peak = edc[i]
    }
    i += 1
  }
  let mut j = 0
  while j < n {
    let v = edc[j]
    if peak <= 0.0 || v <= 0.0 {
      out.push(@double.neg_infinity)
    } else {
      out.push(10.0 * @math.log10(v / peak))
    }
    j += 1
  }
  out
}

///|
/// 在脉冲响应尾部估计噪声底（dB，相对 EDC 峰值）。
///
/// 做法：取末尾若干比例的样本，算 RMS 后换算成 dB。房间声学测量中，
/// 这一段通常已经是纯噪声（直达声和早期反射早已衰减殆尽）。
///
/// - `ir`：脉冲响应
/// - `tail_fraction`：取末尾比例，取值需在 (0, 1]。默认 0.1
/// - 返回：噪声底的 dB 值；样本不足时返回 `None`
pub fn estimate_noise_floor(
  ir : Array[Double],
  tail_fraction? : Double,
) -> Double? {
  let frac = match tail_fraction {
    Some(f) => f
    None => 0.1
  }
  if frac <= 0.0 || frac > 1.0 {
    return None
  }
  let n = ir.length()
  let tail = (n.to_double() * frac).to_int()
  if tail < 16 {
    // 16 个样本是能算出一个稳定 RMS 的下限；更少的话统计噪声太大
    return None
  }
  let start = n - tail
  let mut sum = 0.0
  let mut i = start
  while i < n {
    let s = ir[i]
    sum += s * s
    i += 1
  }
  let rms = (sum / tail.to_double()).sqrt()
  // 基准必须是 **EDC 峰值（脉冲响应的总能量）**，不是整段 IR 的 RMS。
  //
  // 这点很要紧：整段 IR 的 RMS 包含了直达声和早期反射，
  // 数值远大于尾部噪声，用它做分母会把噪声底的 dB 值**系统性抬高**。
  // 实测（探针记录）：SNR 60dB 的信号上，用整段 RMS 做基准得到噪声底 -25.7dB，
  // 与 T20 区间下界 -25dB 只差 0.7dB，于是一个完全可用的测量被判为"被噪声污染"。
  // 换成总能量基准后，同一份数据的噪声底明显更低，判定恢复正常。
  //
  // 这也符合声学上的定义：噪声底是相对**脉冲响应峰值**而言的。
  let mut total = 0.0
  let mut k = 0
  while k < n {
    let s = ir[k]
    total += s * s
    k += 1
  }
  // EDC[0] = Σ p² = total_energy；噪声底能量的"等效"贡献是 rms² * tail
  let peak = total
  let tail_energy = rms * rms * tail.to_double()
  if peak <= 0.0 || tail_energy <= 0.0 {
    return None
  }
  Some(10.0 * @math.log10(tail_energy / peak))
}
