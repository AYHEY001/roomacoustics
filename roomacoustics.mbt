///|
/// Sabine 公式：由房间体积和总表面积估算混响时间 RT60。
///
/// 公式：`RT60 = 0.161 · V / (S · α)`
/// - `volume`：房间体积，单位 m³
/// - `surface`：房间六个面的总面积，单位 m²
/// - `alpha`：平均吸声系数，取值 0.0~1.0
///
/// 返回单位为秒。`surface` 或 `alpha` 为 0 时返回 `None`
/// （数学上无定义，避免静默产生 inf）。
///
/// 该公式假设声场完全扩散，实际值与实测总有偏差；
/// 需要实测结果时请用能量衰减曲线反演（EDC/T20/T30），而不是这里的估算值。
pub fn sabine(volume : Double, surface : Double, alpha : Double) -> Double? {
  if surface <= 0.0 || alpha <= 0.0 || volume < 0.0 {
    return None
  }
  Some(0.161 * volume / (surface * alpha))
}

///|
/// 矩形房间中 (nx, ny, nz) 阶模态的频率，单位 Hz。
///
/// 公式：`f = c · √((nx/Lx)² + (ny/Ly)² + (nz/Lz)²)`，
/// 声速 `c` 取 343 m/s（20 °C 干空气）。
///
/// 边界条件为刚壁，`(0, 0, 0)` 是零频的空气共振（不计入房间模态），返回 `None`。
/// 任一边长非正时同样返回 `None`。
pub fn modal_frequency(
  length : Double,
  width : Double,
  height : Double,
  mode : (Int, Int, Int),
) -> Double? {
  if length <= 0.0 || width <= 0.0 || height <= 0.0 {
    return None
  }
  let (nx, ny, nz) = mode
  if nx < 0 || ny < 0 || nz < 0 {
    return None
  }
  if nx == 0 && ny == 0 && nz == 0 {
    return None
  }
  let fx = nx.to_double() / length
  let fy = ny.to_double() / width
  let fz = nz.to_double() / height
  Some(SOUND_SPEED * (fx * fx + fy * fy + fz * fz).sqrt())
}

///|
/// 20 °C 干空气中的声速，单位 m/s。
pub const SOUND_SPEED : Double = 343.0
