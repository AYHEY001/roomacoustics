"""文档数字守卫 —— 断言文档里的测试数与实际跑出来的一致。

## 为什么需要这个

README 和 `docs/ONE_PAGER.md` 里写着测试数（"51 个测试"、"预期 51 passed"）。
这个数字会随每次加测试而变，手工同步必然漂 —— 已经漂过一次
（实际 51、文档写 50）。

漂了不会报错，只会让"可核对"这个卖点变成一句空话。
所以把文档里的数字和 `moon test` 的真实输出比一遍。

## 怎么找文档里的数字

文档里数字的写法有几种（"51 个测试"、"预期 51 passed"），
用正则把**所有**形如 `NNN 个测试` / `预期 NNN passed` 的地方抓出来，
任何一个和实际不符就报错。

这样比"检查某个固定句子"更耐用：文档改写了措辞，
只要还写着"N 个测试"就仍然被覆盖。

## 自检

尺子要先验。探针里放几种典型写法（中文/英文/N passed），
确认正则都能抓到；再放一个不应该被匹配的干扰样本。

用法：
    PYTHONIOENCODING=utf-8 python docs/check_doc_numbers.py --actual 51
    PYTHONIOENCODING=utf-8 python docs/check_doc_numbers.py            # 自动跑 moon test
"""

import io
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..")

DOCS = ["README.md", "docs/ONE_PAGER.md", "DEMO.md"]

# 只抓**明确的测试数语境**。capture group 1 是数字。
#
# 这里的关键教训：不能写成"任何 `N 个`"，因为文档里有大量
# "23 个峰"、"23 个形成峰"这类非测试数量，会被误报。
# 所以要求数字后面紧跟"个测试"，或者出现在 passed 语境里。
#
# 相应地，文档里的写法要统一成 `NN 个测试`，别写 `NN 个，含…`——
# 后者抓不到，守卫就成了摆设（这个坑踩过一次）。
PATTERNS = [
    re.compile(r"(\d+)\s*个测试"),
    re.compile(r"预期\s*(\d+)\s*passed"),
    re.compile(r"passed:\s*(\d+)", re.I),
]


def find_numbers(text):
    """返回 [(行号, 原文片段, 数字)]。"""
    out = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for pat in PATTERNS:
            for m in pat.finditer(line):
                out.append((lineno, m.group(0), int(m.group(1))))
    return out


def self_check():
    probes = [
        ("中文写法", "| **规模** | 2.5k 行，51 个测试，CI 全绿 |", [51]),
        ("英文写法", "Total tests: 51, passed: 51", [51]),
        ("预期写法", "moon test --deny-warn  # 预期 51 passed", [51]),
        ("列表写法", "- [x] 回归测试（51 个测试，含有效性验证）", [51]),
        ("多个数字都要抓", "50 个测试 ... 预期 51 passed", [50, 51]),
        # 这条是真实误报防护：文档里有大量"N 个峰"，不是测试数。
        # 早期版本写"任何 N 个"会把 23 个峰也抓进来。
        ("干扰项：N 个峰不是测试数", "频谱里只有 23 个形成峰；23 个峰的频率一致", []),
        ("干扰项：版本号不该被当测试数", "moon 0.1.20261012", []),
        ("干扰项：无数字关键词", "回归测试（含测试有效性验证）", []),
        # 这条提醒文档措辞：写成"NN 个，含…"抓不到，等于守卫失效。
        ("干扰项：'NN 个，含'抓不到（文档该避免这种写法）",
         "回归测试（51 个，含测试有效性验证）", []),
    ]
    ok = True
    for name, text, expected in probes:
        got = sorted({n for _, _, n in find_numbers(text)})
        passed = got == sorted(expected)
        mark = "OK " if passed else "BAD"
        if not passed:
            ok = False
        print(f"  [{mark}] {name}: 抓到={got} 期望={sorted(expected)}")
    return ok


def run_moon_test():
    """跑 moon test 拿真实通过数。

    moon test 的输出末行形如：
        Total tests: 51, passed: 51, failed: 0.
    """
    try:
        p = subprocess.run(
            ["moon", "test"],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
            errors="replace", shell=(os.name == "nt"),
        )
    except FileNotFoundError:
        print("找不到 moon 命令，请先把它加进 PATH")
        sys.exit(1)
    text = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"Total tests:\s*(\d+),\s*passed:\s*(\d+)", text)
    if not m:
        print("无法从 moon test 输出里解析结果，末尾几行：")
        print("\n".join(text.strip().splitlines()[-5:]))
        sys.exit(1)
    return int(m.group(2))


def main():
    print("=" * 68)
    print("文档数字守卫 —— 文档里的测试数 vs 实际")
    print("=" * 68)
    print()

    print("[自检] 先验证数字抽取逻辑本身有效")
    if not self_check():
        print("  自检未通过，下面的判定不可信")
        sys.exit(1)
    print("  自检通过")
    print()

    if "--actual" in sys.argv:
        actual = int(sys.argv[sys.argv.index("--actual") + 1])
        print(f"实际测试数（命令行给定）：{actual}")
    else:
        print("正在跑 moon test 取真实通过数...")
        actual = run_moon_test()
        print(f"实际测试数（moon test）：{actual}")
    print()

    bad = []
    checked = 0
    for rel in DOCS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        with io.open(path, encoding="utf-8") as f:
            text = f.read()
        for lineno, snippet, num in find_numbers(text):
            checked += 1
            if num != actual:
                bad.append((rel, lineno, snippet, num))

    print(f"文档里找到 {checked} 处测试数声明")
    print()

    if not bad:
        print(f"判定：文档里的测试数与实际一致（都是 {actual}）。")
        return

    print("判定：文档数字与实际不符。")
    print()
    for rel, lineno, snippet, num in bad:
        print(f"  {rel}:{lineno}  写的是 {num}，实际 {actual}")
        print(f"      {snippet}")
    print()
    print("修正方法：把上面几处改成实际值，重新提交。")
    sys.exit(1)


if __name__ == "__main__":
    main()
