"""分层守卫 —— 断言核心库的依赖集合等于白名单。

## 为什么需要这个

项目承诺了一条分层约定：

    核心库 haiou/roomacoustics 只做数值计算，不碰 I/O，
    接口只接受 Array[Double] + 采样率，不绑定数据源。

这条约定今天成立（`moon.pkg` 里确实只有标准库），但**只靠自律**。
`moon check` 检查的是"能不能编译"，不是"依赖有没有变多"——
有人（或某个 AI 改动）往核心库里 import 一个 moonwavkit，
`moon check` 照样绿，约定就悄悄破了。

这个脚本把约定变成可执行的断言：依赖集合必须**恰好等于**白名单。
多一个报错，少一个也报错（少了说明白名单该更新）。

## 为什么要自检

尺子本身可能写错。所以脚本先跑一组探针：
合法依赖必须通过、越界依赖必须被拒。
自检不过，后面的判定不可信 —— 这是从 `check_ecosystem.py`
学来的做法（那边靠自检发现过子串误报）。

用法：
    PYTHONIOENCODING=utf-8 python docs/check_layering.py
"""

import io
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")

# 核心库允许的依赖。**恰好等于**这个集合，多一个少一个都不行。
ALLOWED_CORE = {
    "moonbitlang/core/math",
    "moonbitlang/core/double",
    "moonbitlang/core/debug",
}

# 明确不允许出现在核心库里的依赖 —— 它们是"生态库"，
# 属于 CLI 层。列出来是为了让报错信息具体，而不是只说"多了个东西"。
FORBIDDEN_HINTS = {
    "moonwavkit": "WAV 读取属 I/O，应在 CLI 层",
    "MoonSpectrum": "FFT 属频谱处理，应在 CLI 层",
    "moonbitlang/x/fs": "文件系统属 I/O，应在 CLI 层",
    "moonbitlang/core/json": "JSON 解析属数据格式，核心库只收 Array[Double]",
}


def strip_comments(text):
    """去掉 // 行注释。

    moon.pkg 里注释会提到依赖名（例如解释"为什么不用 X"），
    不去掉的话注释里的词会被当成真实 import，产生假阳性。
    """
    out = []
    for line in text.splitlines():
        # 行内 // 之后全部丢掉
        idx = line.find("//")
        if idx >= 0:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)


def parse_imports(pkg_text):
    """从 moon.pkg 文本里抽出依赖模块名。

    只处理顶层 `import { ... }` 块。
    `import { ... } for "wbtest"` 这类**按目标限定**的块也要算进来 ——
    它同样是这个包的依赖声明，只是作用域不同。
    """
    text = strip_comments(pkg_text)
    names = []
    # 抓所有 import { ... } 块（含 for "xxx" 后缀）
    for m in re.finditer(r"import\s*\{(.*?)\}", text, re.S):
        block = m.group(1)
        for raw in block.splitlines():
            line = raw.strip().strip(",").strip()
            if not line:
                continue
            # 形如 "path/to/pkg" @alias —— 取引号里的路径
            q = re.match(r'"([^"]+)"', line)
            if q:
                names.append(q.group(1))
    return names


def check_package(rel_path, allowed):
    """返回 (ok, missing, extra, got)。"""
    path = os.path.join(ROOT, rel_path)
    if not os.path.exists(path):
        print(f"找不到 {path}")
        sys.exit(1)
    with io.open(path, encoding="utf-8") as f:
        text = f.read()
    got = set(parse_imports(text))
    missing = allowed - got
    extra = got - allowed
    return (not missing and not extra), missing, extra, got


def self_check():
    """尺子自检：喂几个必须通过 / 必须被拒的样本。"""
    probes = [
        (
            "合法：只有白名单三个",
            'import {\n  "moonbitlang/core/math",\n  "moonbitlang/core/double",\n}',
            {"moonbitlang/core/math", "moonbitlang/core/double"},
            True,
        ),
        (
            "越界：偷偷加了 moonwavkit",
            'import {\n  "moonbitlang/core/math",\n  "Ridge-Lab/moonwavkit",\n}',
            {"moonbitlang/core/math"},
            False,
        ),
        (
            "越界：加了文件系统",
            'import {\n  "moonbitlang/core/math",\n  "moonbitlang/x/fs",\n}',
            {"moonbitlang/core/math"},
            False,
        ),
        (
            "注释里的依赖名不算 import（假阳性防护）",
            'import {\n  "moonbitlang/core/math",\n}\n// 这里故意提一下 moonwavkit 和 MoonSpectrum',
            {"moonbitlang/core/math"},
            True,
        ),
        (
            "漏了白名单里的一个也要报（白名单该更新了）",
            'import {\n  "moonbitlang/core/math",\n}',
            {"moonbitlang/core/math", "moonbitlang/core/double"},
            False,
        ),
        (
            'for "wbtest" 限定块也要算进来',
            'import {\n  "moonbitlang/core/math",\n} for "wbtest"',
            {"moonbitlang/core/math"},
            True,
        ),
    ]
    ok = True
    for name, text, allowed, should_pass in probes:
        got = set(parse_imports(text))
        passed = got == allowed
        mark = "OK " if passed == should_pass else "BAD"
        if passed != should_pass:
            ok = False
        print(f"  [{mark}] {name}: 得到={sorted(got)} 期望通过={should_pass}")
    return ok


def main():
    print("=" * 68)
    print("分层守卫 —— 核心库依赖白名单")
    print("=" * 68)
    print()

    print("[自检] 先验证解析与判定逻辑本身有效")
    if not self_check():
        print("  自检未通过，下面的判定不可信")
        sys.exit(1)
    print("  自检通过")
    print()

    ok, missing, extra, got = check_package("moon.pkg", ALLOWED_CORE)
    print(f"核心库 moon.pkg 实际依赖（{len(got)} 个）：")
    for n in sorted(got):
        print(f"    {n}")
    print()

    if ok:
        print("判定：核心库依赖恰好等于白名单。分层约定成立。")
        print()
        print("说明：核心库不依赖任何 I/O 与频谱库，")
        print("      接口只接受 Array[Double] + 采样率。")
        print("      这条断言在 CI 里每次提交都会跑，不靠自律。")
        return

    print("判定：分层约定被打破。")
    if extra:
        print()
        print("  多出来的依赖：")
        for n in sorted(extra):
            hint = ""
            for key, why in FORBIDDEN_HINTS.items():
                if key in n:
                    hint = f"  <- {why}"
                    break
            print(f"    {n}{hint}")
    if missing:
        print()
        print("  白名单里有、但实际没用的依赖（若确实不再需要，请更新白名单）：")
        for n in sorted(missing):
            print(f"    {n}")
    sys.exit(1)


if __name__ == "__main__":
    main()
