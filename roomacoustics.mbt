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
/// 一个房间模态。
pub struct Mode {
  freq : Double
  nx : Int
  ny : Int
  nz : Int
  kind : String
} derive(Debug)

///|
pub extend Mode with @debug.Debug::{to_repr}

///|
/// 列出矩形房间中频率最低的若干个模态。
///
/// 枚举 `(nx, ny, nz)` 的所有组合（各 0..=`order`），算出频率后升序排序。
/// 排序时把原序号一并并入比较键 —— `Array::sort_by` 是不稳定排序，
/// 只按频率比时频率相同的模态顺序不保证，输出会不可复现。
///
/// - `length` / `width` / `height`：房间三边，单位 m
/// - `limit`：返回前几个模态
pub fn list_modes(
  length : Double,
  width : Double,
  height : Double,
  limit : Int,
) -> Array[Mode] {
  if length <= 0.0 || width <= 0.0 || height <= 0.0 || limit <= 0 {
    return []
  }
  // 阶数上限取一个够用的小值：低阶模态才是实际关心的
  let order = 4
  let found = Array(capacity=64)
  let mut nx = 0
  while nx <= order {
    let mut ny = 0
    while ny <= order {
      let mut nz = 0
      while nz <= order {
        if nx != 0 || ny != 0 || nz != 0 {
          match modal_frequency(length, width, height, (nx, ny, nz)) {
            Some(f) => {
              let count = sum_positive(nx, ny, nz)
              let kind = match count {
                1 => "轴向"
                2 => "切向"
                _ => "斜向"
              }
              found.push({ freq: f, nx, ny, nz, kind, })
            }
            None => ()
          }
        }
        nz += 1
      }
      ny += 1
    }
    nx += 1
  }
  // 频率为主键，原下标为次键 —— 保证排序结果稳定可复现
  let indexed = found.copy()
  indexed.sort_by(fn(a, b) {
    if a.freq < b.freq {
      -1
    } else if a.freq > b.freq {
      1
    } else {
      0
    }
  })
  let out = Array(capacity=limit)
  let mut i = 0
  while i < limit && i < indexed.length() {
    out.push(indexed[i])
    i += 1
  }
  out
}

///|
/// 三个阶次里有几个非零。
fn sum_positive(nx : Int, ny : Int, nz : Int) -> Int {
  (if nx > 0 { 1 } else { 0 }) +
  (if ny > 0 { 1 } else { 0 }) +
  (if nz > 0 { 1 } else { 0 })
}

///|
/// 20 °C 干空气中的声速，单位 m/s。
pub const SOUND_SPEED : Double = 343.0
