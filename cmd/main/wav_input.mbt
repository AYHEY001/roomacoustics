/// WAV 输入 —— 用 `moonwavkit` 把 WAV 文件读成脉冲响应采样点。
///
/// **为什么这一层独立存在**：核心库（`haiou/roomacoustics`）只处理"给定采样点，
/// 算出声学参数"，不依赖任何音频 I/O。WAV 容器的解析与 PCM 解码交给
/// `Ridge-Lab/moonwavkit`，这是本项目的边界，也是它能被复用的前提。
///
/// 换句话说：本项目**基于** moonwavkit 读到的采样点做声学计算，
/// 而**不提供** WAV 解析能力本身。这两句话的差别，是边界是否成立的关键。

///|
/// 读一个 WAV 文件，得到单声道的脉冲响应采样点。
///
/// 处理链路：
///   文件路径 -> 字节流（@fs）-> RIFF/WAVE 解析与 PCM 解码（@mwav）
///   -> 立体声下混为单声道 -> 采样点数组 + 采样率
///
/// 之所以要下混：房间声学测量关心的是空间响应，单只传声器就够。
/// 立体声录音在实践里很常见（手机、录音笔默认就是），所以必须支持。
///
/// 返回 `Err` 而不是抛异常，让调用方决定怎么报告。
pub fn load_wav_ir(path : String) -> Result[IrData, String] {
  // 读原始字节，不用 read_file_to_string —— 后者对非法 UTF-8 不报错，
  // 字节会在读取阶段被改写。WAV 本来就是二进制，必须走 bytes。
  let raw : Result[Bytes, String] = Ok(@fs.read_file_to_bytes(path)) catch {
    @fs.IOError(msg) => Err("读不了 " + path + "：" + msg)
  }
  let bytes = match raw {
    Ok(b) => b
    Err(msg) => return Err(msg)
  }
  if bytes.length() == 0 {
    return Err("文件为空：" + path)
  }
  // moonwavkit 接受 Array[Int]（每个元素一个字节，0~255）
  let byte_arr = bytes.to_array()
  let raw = Array(capacity=byte_arr.length())
  let mut i = 0
  while i < byte_arr.length() {
    raw.push(byte_arr[i].to_int())
    i += 1
  }
  let decoded = @mwav.parse_and_decode(raw)
  if !decoded.ok {
    return Err(
      "WAV 解析失败：" +
      decoded.error.code() +
      "（" +
      decoded.error.message +
      "）",
    )
  }
  let fb = decoded.float_buffer
  if fb.samples.length() == 0 {
    return Err("WAV 里没有任何采样点：" + path)
  }
  // 立体声（或更多声道）下混为单声道
  let mono = if fb.channels > 1 { @mwav.downmix_to_mono(fb) } else { fb }
  if mono.sample_rate <= 0 {
    return Err("WAV 的采样率非法：" + mono.sample_rate.to_string())
  }
  Ok({ sample_rate: mono.sample_rate, ir: mono.samples, })
}

///|
/// 判断路径是否是 WAV 文件（按扩展名，大小写不敏感）。
fn is_wav_path(path : String) -> Bool {
  let lower = path.to_lower()
  lower.has_suffix(".wav") || lower.has_suffix(".wave")
}
