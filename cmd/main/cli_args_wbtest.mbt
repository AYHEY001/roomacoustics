// CLI 参数解析与校验的回归测试。
//
// **为什么需要这个文件**：`moon coverage analyze` 显示 `main.mbt` 有 116 行
// 未覆盖 —— 输入解析（`parse_ir_json`）、数字解析（`parse_double`）、
// 参数读取（`opt_double` / `opt_int`）三层全空。
//
// 后果是实打实的：`sabine --length abc` 会因为 `parse_double` 静默返回 0.0，
// 报出 `RT60 = 0.000 s` 这种看起来合法的错数字 ——
// 恰好是项目最想避免的行为。
//
// 这里先钉住「非法输入必须能报错」这个契约。

///|
test "数字解析：合法输入" {
  debug_inspect(parse_double_opt("5"), content="Some(5)")
  debug_inspect(parse_double_opt("5.0"), content="Some(5)")
  debug_inspect(parse_double_opt("2.6"), content="Some(2.6)")
  debug_inspect(parse_double_opt("0.2"), content="Some(0.2)")
  debug_inspect(parse_double_opt("-5"), content="Some(-5)")
  debug_inspect(parse_double_opt("-2.6"), content="Some(-2.6)")
  debug_inspect(parse_double_opt("100"), content="Some(100)")
  debug_inspect(parse_double_opt("0"), content="Some(0)")
}

///|
test "数字解析：非法输入返回 None，而不是 0.0" {
  // 这是本文件的核心契约。返回 Some(0.0) 就等于"静默降级"，
  // 调用方无法区分"用户写了 0"和"用户写错了"。
  debug_inspect(parse_double_opt("abc"), content="None")
  debug_inspect(parse_double_opt(""), content="None")
  debug_inspect(parse_double_opt("--"), content="None")
  debug_inspect(parse_double_opt("."), content="None")
  debug_inspect(parse_double_opt("1e5"), content="None")
  debug_inspect(parse_double_opt("nan"), content="None")
  debug_inspect(parse_double_opt("xyz123"), content="None")
  debug_inspect(parse_double_opt("5abc"), content="None")
}

///|
test "数字解析：负号与小数点组合的边界" {
  debug_inspect(parse_double_opt("-0.5"), content="Some(-0.5)")
  debug_inspect(parse_double_opt("-"), content="None")
  debug_inspect(parse_double_opt("-."), content="None")
}

///|
test "参数读取：未提供时用默认值，提供了非法值时返回 Err" {
  // opt_double 必须先能区分「没给这个选项」和「给了但写错」。
  // 前者用默认值（正常），后者要让调用方报错。
  //
  // 这里直接测 parse_double_opt 的契约：默认值的处理在 opt_double 里，
  // 而那需要构造 @argparse.Matches，不便在单测里做。
  // 关键是「非法值不能静默变成 0」这条 —— 见上面那条测试。
  debug_inspect(parse_double_opt("5.0"), content="Some(5)")
  debug_inspect(parse_double_opt("abc"), content="None")
}

///|
test "JSON 解析：合法输入" {
  let res = parse_ir_json("{\"sample_rate\":44100,\"ir\":[1,2,3]}")
  match res {
    Ok(d) => {
      debug_inspect(d.sample_rate, content="44100")
      debug_inspect(d.ir.length(), content="3")
    }
    Err(e) => assert_true(false, msg="应能解析，却报错：" + e)
  }
}

///|
test "JSON 解析：sample_rate 缺失时用默认 44100" {
  let res = parse_ir_json("{\"ir\":[1,2,3]}")
  match res {
    Ok(d) => debug_inspect(d.sample_rate, content="44100")
    Err(e) =>
      assert_true(false, msg="缺 sample_rate 应能解析，却报错：" + e)
  }
}

///|
test "JSON 解析：缺 ir 字段报明确错误" {
  let res = parse_ir_json("{\"sample_rate\":44100}")
  match res {
    Ok(_) => assert_true(false, msg="缺 ir 不该解析成功")
    Err(e) =>
      assert_true(e.contains("ir"), msg="错误应提到 ir，实际：" + e)
  }
}

///|
test "JSON 解析：ir 不是数组报明确错误" {
  let res = parse_ir_json("{\"ir\":123}")
  match res {
    Ok(_) => assert_true(false, msg="ir 非数组不该解析成功")
    Err(e) =>
      assert_true(
        e.contains("数组"),
        msg="错误应说明不是数组，实际：" + e,
      )
  }
}

///|
test "JSON 解析：ir 含非数字元素报明确错误" {
  let res = parse_ir_json("{\"ir\":[1,\"x\",3]}")
  match res {
    Ok(_) => assert_true(false, msg="ir 含非数字不该解析成功")
    Err(e) =>
      assert_true(
        e.contains("数字"),
        msg="错误应说明含非数字，实际：" + e,
      )
  }
}

///|
test "JSON 解析：非法 JSON 报明确错误" {
  let res = parse_ir_json("not json at all")
  match res {
    Ok(_) => assert_true(false, msg="非法 JSON 不该解析成功")
    Err(e) =>
      assert_true(
        e.contains("JSON"),
        msg="错误应说明是 JSON 问题，实际：" + e,
      )
  }
}

///|
test "JSON 解析：sample_rate 为 0 应被拒绝" {
  // WAV 路径校验了 sample_rate <= 0，JSON 路径也必须校验，
  // 否则后续 样本数/采样率 会得到 inf，fmt 里溢出成荒谬的时长。
  let res = parse_ir_json("{\"sample_rate\":0,\"ir\":[1,2,3]}")
  match res {
    Ok(_) => assert_true(false, msg="sample_rate=0 不该解析成功")
    Err(e) =>
      assert_true(
        e.contains("采样率"),
        msg="错误应说明采样率非法，实际：" + e,
      )
  }
}

///|
test "JSON 解析：sample_rate 为负应被拒绝" {
  let res = parse_ir_json("{\"sample_rate\":-1,\"ir\":[1,2,3]}")
  match res {
    Ok(_) => assert_true(false, msg="负采样率不该解析成功")
    Err(_) => ()
  }
}

///|
test "房间尺寸校验：非法值必须能被检出" {
  // 各子命令共用的校验：三边必须为正，alpha 必须在 (0, 1]
  debug_inspect(check_room_dims(5.0, 4.0, 2.6), content="Ok(())")
  assert_true(
    check_room_dims(0.0, 4.0, 2.6) is Err(_),
    msg="长度 0 应被拒",
  )
  assert_true(
    check_room_dims(-5.0, 4.0, 2.6) is Err(_),
    msg="负长度应被拒",
  )
  assert_true(
    check_room_dims(5.0, 0.0, 2.6) is Err(_),
    msg="宽度 0 应被拒",
  )
  assert_true(
    check_room_dims(5.0, 4.0, 0.0) is Err(_),
    msg="高度 0 应被拒",
  )
}

///|
test "吸声系数校验：必须在 (0, 1]" {
  debug_inspect(check_alpha(0.2), content="Ok(())")
  debug_inspect(check_alpha(1.0), content="Ok(())")
  assert_true(check_alpha(0.0) is Err(_), msg="alpha=0 应被拒")
  assert_true(check_alpha(-0.1) is Err(_), msg="负 alpha 应被拒")
  assert_true(check_alpha(1.5) is Err(_), msg="alpha>1 应被拒")
}
