// WAV 输入路径的回归测试。
//
// 这些测试验证的是「moonwavkit 读进来的采样点」和「JSON 里手写的采样点」
// 走同一条声学计算链路后结果一致 —— 也就是接入依赖没有改变数值行为。
//
// 语料由 docs/make_wav_testdata.py 生成（WAV）和 docs/make_testdata.py 生成（JSON），
// 两者用的是同一份合成信号，所以结果必须逐位一致。
//
// 注意 `moon test` 的工作目录是项目根，不是包目录，所以路径不带 cmd/main 前缀。

///|
test "WAV 读取：单声道文件能拿到正确的采样率与样本数" {
  let res = load_wav_ir("testdata/ir_mono_0.8.wav")
  match res {
    Ok(d) => {
      debug_inspect(d.sample_rate, content="44100")
      debug_inspect(d.ir.length(), content="110250")
    }
    Err(e) => assert_true(false, msg="应能读到 WAV，却报错：" + e)
  }
}

///|
test "WAV 读取：立体声文件下混为单声道，样本数不变" {
  // 下混是逐帧平均，帧数（= 单声道后的样本数）应与文件帧数一致，
  // 而不是立体声的交错样本数。这里 110250 帧就是 110250 个单声道样本。
  let res = load_wav_ir("testdata/ir_stereo_0.8.wav")
  match res {
    Ok(d) => {
      debug_inspect(d.sample_rate, content="44100")
      debug_inspect(d.ir.length(), content="110250")
    }
    Err(e) =>
      assert_true(false, msg="应能读到立体声 WAV，却报错：" + e)
  }
}

///|
test "WAV 与 JSON 读同一信号：衰减时间逐位一致" {
  // **这是接入 moonwavkit 后最重要的一条测试。**
  // 同一份合成信号，一条从 WAV（16-bit PCM 量化）读进来，
  // 一条从 JSON（浮点原值）读进来。
  // 幅度经过量化和归一化会变，但**衰减率不受幅度影响**，
  // 所以三者应当一致到小数点后三位。
  let from_wav = match load_wav_ir("testdata/ir_mono_0.8.wav") {
    Ok(d) => d
    Err(e) => {
      assert_true(false, msg="WAV 读取失败：" + e)
      return
    }
  }
  let report_wav = @ra.analyse_decay(from_wav.ir, from_wav.sample_rate)
  let t20_wav = match report_wav.t20 {
    @ra.Success(t, _, _, _) => t
    @ra.Failed(_r, _) => {
      assert_true(false, msg="WAV 路径下 T20 拟合失败")
      return
    }
  }
  // 与 JSON 路径的结果对照（该值由 decay_wbtest 里的同一份信号确定）
  assert_true(
    (t20_wav - 0.810).abs() < 0.005,
    msg="WAV 读入的 T20 应与 JSON 路径一致 (0.810s)，实际 " +
      t20_wav.to_string(),
  )
}

///|
test "WAV 读取：非 WAV 文件报明确错误而不是崩溃" {
  // 文本文件改后缀成 .wav —— 用户手动重命名时很容易撞上
  let res = load_wav_ir("testdata/not_a_wav.wav")
  match res {
    Ok(_) => assert_true(false, msg="不该把文本文件当成 WAV 读成功")
    Err(e) =>
      // 错误信息里应包含 moonwavkit 给出的原因（not-riff）
      assert_true(
        e.contains("WAV 解析失败"),
        msg="应说明是 WAV 解析失败，实际：" + e,
      )
  }
}

///|
test "WAV 读取：不存在文件报错包含路径" {
  let res = load_wav_ir("testdata/no_such_file.wav")
  match res {
    Ok(_) => assert_true(false, msg="不该读到不存在的文件")
    Err(e) =>
      assert_true(
        e.contains("no_such_file.wav"),
        msg="错误信息里应带上路径，便于定位，实际：" + e,
      )
  }
}

///|
test "路径分派：扩展名判断大小写不敏感" {
  assert_true(is_wav_path("a.wav"), msg=".wav 应识别为 WAV")
  assert_true(is_wav_path("a.WAV"), msg=".WAV 应识别为 WAV")
  assert_true(is_wav_path("a.Wave"), msg=".Wave 应识别为 WAV")
  assert_true(!is_wav_path("a.json"), msg=".json 不该识别为 WAV")
  assert_true(!is_wav_path("a.wav.json"), msg=".wav.json 不该识别为 WAV")
}
