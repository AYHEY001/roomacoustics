/// roomacoustics 命令行入口
///
/// 子命令：
///   decay   —— 从脉冲响应计算 EDT / T20 / T30，并报告噪声底
///   modes   —— 列出矩形房间的前 N 个模态频率
///   sabine  —— 用 Sabine 公式估算混响时间
///
/// **边界**：本工具不解析 WAV。脉冲响应用纯数值数组给出，
/// WAV 容器解析与解码由 moonwavkit 承担，不在本项目范围内。
///
/// 本文件里字符串插值的写法是 `\{表达式}`（反斜杠转义），
/// 直接写 `{x}` 会被当普通字符输出 —— 这个坑踩过两次。

///|
/// 读入的脉冲响应数据。
struct IrData {
  sample_rate : Int32
  ir : Array[Double]
}

///|
/// 从 JSON 文本解析脉冲响应。
fn parse_ir_json(text : String) -> Result[IrData, String] {
  let j = @json.parse(text) catch { _ => return Err("JSON 解析失败") }
  // Json 类型本身不是 pub，外部代码写不出它的类型标注，
  // 所以这里用 `is` 模式匹配就地取值，不抽辅助函数。
  let mut sr = 44100
  // Array[@json.Json] 这个标注写不出来 —— Json 类型不是 pub，
  // 外部包看不到。改成让类型从分支里的 `is Array(a)` 推断出来。
  let mut items = []
  let mut has_ir = false
  if j is Object(obj) {
    for kv in obj {
      let (k, v) = kv
      if k == "sample_rate" {
        if v is Number(n, ..) {
          sr = n.to_int()
        }
      } else if k == "ir" {
        if v is Array(a) {
          items = a
          has_ir = true
        } else {
          return Err("\"ir\" 不是数组")
        }
      }
    }
  }
  if !has_ir {
    return Err("JSON 缺少 \"ir\" 字段")
  }
  let ir = Array(capacity=items.length())
  let mut i = 0
  while i < items.length() {
    if items[i] is Number(x, ..) {
      ir.push(x)
    } else {
      return Err("\"ir\" 不是全部由数字组成的数组")
    }
    i += 1
  }
  Ok({ sample_rate: sr, ir, })
}

///|
/// 核心库没有字符串转浮点，自己按位累加解析。
///
/// 格式：可选负号 + 整数部分 + 可选小数部分。
/// 解析不出数字时返回 0.0，由调用方校验参数是否合理。
fn parse_double(s : StringView) -> Double {
  let cs = s.to_array()
  let mut i = 0
  let mut neg = false
  let mut seen_digit = false
  let mut int_part = 0.0
  let mut frac = 0.0
  let mut scale = 0.1
  if cs.length() > 0 && cs[0] == '-' {
    neg = true
    i = 1
  }
  while i < cs.length() {
    let c = cs[i]
    if c == '.' {
      i += 1
      break
    }
    if c >= '0' && c <= '9' {
      int_part = int_part * 10.0 + (c.to_int() - '0'.to_int()).to_double()
      seen_digit = true
    }
    i += 1
  }
  while i < cs.length() {
    let c = cs[i]
    if c >= '0' && c <= '9' {
      frac += (c.to_int() - '0'.to_int()).to_double() * scale
      scale *= 0.1
      seen_digit = true
    }
    i += 1
  }
  if !seen_digit {
    return 0.0
  }
  let v = int_part + frac
  if neg {
    -v
  } else {
    v
  }
}

///|
/// 从命令行取一个浮点选项。
fn opt_double(
  matches : @argparse.Matches,
  key : String,
  dflt : Double,
) -> Double {
  match matches.values.get(key) {
    Some(a) if a.length() > 0 => parse_double(a[0])
    _ => dflt
  }
}

///|
/// 从命令行取一个整数选项。
fn opt_int(matches : @argparse.Matches, key : String, dflt : Int32) -> Int32 {
  match matches.values.get(key) {
    Some(a) if a.length() > 0 => parse_double(a[0]).to_int()
    _ => dflt
  }
}

///|
/// 10^digits，整数循环。核心库的 `Double::pow` 已弃用，这里本也不需要浮点。
fn pow10(digits : Int32) -> Double {
  let mut s = 1.0
  let mut k = 0
  while k < digits {
    s = s * 10.0
    k += 1
  }
  s
}

///|
/// 定点小数格式化，保留 `digits` 位小数。
///
/// 直接用 `@double.to_string` 会输出 `68.60000000000001` 这种浮点噪声，
/// 命令行输出给人看，必须先收拾干净。
fn fmt(x : Double, digits : Int32) -> String {
  let neg = x < 0.0
  let v = if neg { -x } else { x }
  let scaled = (v * pow10(digits) + 0.5).to_int()
  let mut scale_int = 1
  let mut j = 0
  while j < digits {
    scale_int = scale_int * 10
    j += 1
  }
  let int_part = scaled / scale_int
  let frac_part = scaled % scale_int
  let frac_str = frac_part.to_string()
  let mut out = int_part.to_string()
  if digits > 0 {
    let mut pad = ""
    let mut k = 0
    while k < digits - frac_str.length() {
      pad = pad + "0"
      k += 1
    }
    out = out + "." + pad + frac_str
  }
  if neg {
    "-" + out
  } else {
    out
  }
}

///|
/// 把拟合结果渲染成人读的一行。
fn render(label : String, res : @ra.DecayResult) -> String {
  match res {
    Success(time, slope, range_db, samples) =>
      label +
      "  " +
      fmt(time, 3) +
      "s   (斜率 " +
      fmt(slope, 1) +
      " dB/s, 区间 " +
      fmt(range_db, 0) +
      " dB, " +
      samples.to_string() +
      " 点)"
    Failed(reason, _margin) => {
      let why = match reason {
        @ra.TooFewSamples(n) => "样本不足 (" + n.to_string() + " 点)"
        @ra.InsufficientRangeInFit(w, c) =>
          "区间内样本不足 (" +
          c.to_string() +
          " 点, 区间 " +
          fmt(w, 0) +
          " dB)"
        @ra.NonDecayingSlope(s) =>
          "能量没有衰减 (斜率 " +
          fmt(s, 1) +
          " dB/s)，输入可能不是脉冲响应"
        @ra.ContaminatedByNoise(m) =>
          "评价区间落进噪声底 (余量 " +
          fmt(m, 1) +
          " dB)，结果不可信 —— 建议延长测量或降噪"
      }
      label + "  不可用：" + why
    }
  }
}

///|
/// 模态频率的一行输出。
fn freq_line(m : @ra.Mode) -> String {
  fmt(m.freq, 2) +
  "    (" +
  m.nx.to_string() +
  "," +
  m.ny.to_string() +
  "," +
  m.nz.to_string() +
  ")     " +
  m.kind
}

///|
/// 子命令：decay
fn cmd_decay(matches : @argparse.Matches) -> Unit {
  let file = match matches.values.get("file") {
    Some(a) if a.length() > 0 => Some(a[0])
    _ => None
  }
  let inline = match matches.values.get("ir") {
    Some(a) if a.length() > 0 => Some(a[0])
    _ => None
  }
  // 显式标注结果类型：catch 块里的 return 需要它能确定 Err 的类型参数
  let loaded : Result[IrData, String] = match (file, inline) {
    // 按扩展名分派：.wav 走 moonwavkit，其余当 JSON 处理。
    // 之所以要分派而不是各开一个子命令：用户手里有什么文件就用什么，
    // 不该为了格式去记两个命令名。
    (Some(path), _) =>
      if is_wav_path(path) {
        load_wav_ir(path)
      } else {
        let raw : Result[String, String] = Ok(
          @fs.read_file_to_string(path, encoding="utf8"),
        ) catch {
          @fs.IOError(msg) => Err("读不了 " + path + "：" + msg)
        }
        match raw {
          Ok(text) => parse_ir_json(text)
          Err(msg) => Err(msg)
        }
      }
    (None, Some(s)) => parse_ir_json(s)
    (None, None) =>
      Err(
        "请用 --file <path.wav|path.json> 或 --ir <json> 提供脉冲响应",
      )
  }
  let data = match loaded {
    Ok(d) => d
    Err(e) => {
      println("错误: " + e)
      return
    }
  }
  if data.ir.is_empty() {
    println("错误: \"ir\" 是空数组")
    return
  }
  let dur = data.ir.length().to_double() / data.sample_rate.to_double()
  println("=== 衰减时间测量 ===")
  println("采样率    " + data.sample_rate.to_string() + " Hz")
  println(
    "样本数    " + data.ir.length().to_string() + "  (" + fmt(dur, 2) + "s)",
  )
  let report = @ra.analyse_decay(data.ir, data.sample_rate)
  println("")
  match report.noise_floor_db {
    Some(nf) => println("噪声底    " + fmt(nf, 1) + " dB")
    None =>
      // 估不出来通常是好事，不是错误：信号尾部已衰减到量化精度以下
      // （干净的合成脉冲响应经 16-bit 量化后，尾部就是一片 0）。
      // 真实录音极少出现这种情况 —— 总有环境噪声。
      println("噪声底    低于仪器分辨率（尾部已衰减到 0）")
  }
  println("")
  println("参数      值        备注")
  println("-------   ------    ----------------")
  println(render("EDT", report.edt))
  println(render("T20", report.t20))
  println(render("T30", report.t30))
}

///|
/// 子命令：modes
fn cmd_modes(matches : @argparse.Matches) -> Unit {
  let l = opt_double(matches, "length", 5.0)
  let w = opt_double(matches, "width", 4.0)
  let h = opt_double(matches, "height", 2.6)
  let n = opt_int(matches, "count", 12)
  println("=== 矩形房间模态频率 ===")
  println(
    "房间尺寸  " +
    fmt(l, 2) +
    " × " +
    fmt(w, 2) +
    " × " +
    fmt(h, 2) +
    " m",
  )
  println("声速      343 m/s (20 °C 干空气)")
  println("")
  println("频率 (Hz)  (nx,ny,nz)  类型")
  println("--------  ----------  ----")
  let modes = @ra.list_modes(l, w, h, n)
  let mut i = 0
  while i < modes.length() {
    println(freq_line(modes[i]))
    i += 1
  }
}

///|
/// 子命令：sabine
fn cmd_sabine(matches : @argparse.Matches) -> Unit {
  let l = opt_double(matches, "length", 5.0)
  let w = opt_double(matches, "width", 4.0)
  let h = opt_double(matches, "height", 2.6)
  let a = opt_double(matches, "alpha", 0.2)
  let v = l * w * h
  let s = 2.0 * (l * w + l * h + w * h)
  println("=== Sabine 估算 ===")
  println(
    "房间尺寸  " +
    fmt(l, 2) +
    " × " +
    fmt(w, 2) +
    " × " +
    fmt(h, 2) +
    " m",
  )
  println("体积      " + fmt(v, 2) + " m³")
  println("表面积    " + fmt(s, 2) + " m²")
  println("吸声系数  " + fmt(a, 3))
  match @ra.sabine(v, s, a) {
    Some(rt) => {
      println("RT60      " + fmt(rt, 3) + " s")
      println("")
      println(
        "注意：Sabine 假设声场完全扩散，与实测总有偏差。",
      )
      println("     需要实测结果请用 decay 子命令。")
    }
    None => println("RT60      无法计算（参数非法）")
  }
}

///|
fn main {
  let cmd = @argparse.Command(
    "roomacoustics",
    about="从脉冲响应计算房间混响时间、衰减曲线与模态频率",
    version="0.1.0",
    subcommands=[
      @argparse.Command(
        "decay",
        about="从脉冲响应计算 EDT / T20 / T30",
        options=[
          @argparse.OptionArg(
            "file",
            short='f',
            long="file",
            about="脉冲响应 JSON 文件",
          ),
          @argparse.OptionArg("ir", about="直接内联脉冲响应 JSON"),
        ],
      ),
      @argparse.Command("modes", about="列出矩形房间的模态频率", options=[
        @argparse.OptionArg("length", long="length", about="长度 (m)"),
        @argparse.OptionArg("width", long="width", about="宽度 (m)"),
        @argparse.OptionArg("height", long="height", about="高度 (m)"),
        @argparse.OptionArg("count", long="count", about="列出前 N 个"),
      ]),
      @argparse.Command("sabine", about="用 Sabine 公式估算 RT60", options=[
        @argparse.OptionArg("length", long="length", about="长度 (m)"),
        @argparse.OptionArg("width", long="width", about="宽度 (m)"),
        @argparse.OptionArg("height", long="height", about="高度 (m)"),
        @argparse.OptionArg("alpha", long="alpha", about="平均吸声系数"),
      ]),
    ],
  )
  let argv = @env.args()
  // @env.args() 第 0 位是 wasm 可执行文件自身路径，argparse 只认程序名之后的部分
  let real = if argv.length() > 1 { argv[1:] } else { argv[:] }
  let matches = cmd.parse(argv=real) catch {
    e => {
      println("参数错误: " + e.to_string())
      return
    }
  }
  match matches.subcommand {
    Some(("decay", m)) => cmd_decay(m)
    Some(("modes", m)) => cmd_modes(m)
    Some(("sabine", m)) => cmd_sabine(m)
    _ => println(cmd.render_help())
  }
}
