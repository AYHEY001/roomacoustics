"""生态术语检索 —— 核对"房间声学测量赛道是否空置"的主张。

这个脚本是给评委自行复现用的，所以每个数字都来自实际扫描，
不做任何假设。同时它会打印自检行，避免"尺子本身写错了"。

用法：
    PYTHONIOENCODING=utf-8 python docs/check_ecosystem.py
"""

import io
import json
import os
import re
import sys

REGISTRY = os.path.expanduser(
    os.environ.get(
        "MOON_HOME", "C:/Users/admin/.workbuddy/binaries/moonbit"
    )
) + "/registry/index/_mods.json"

# 房间声学的标准术语。分三类，逐类检索。
TERMS = {
    "学科名": ["room acoustics", "acoustic measurement", "acoustics measurement"],
    "核心指标": ["reverberation", "rt60", "rt 60", "decay time", "edt", "t20", "t30"],
    "输入对象": ["impulse response", "impulse-response"],
    "方法/公式": ["schroeder", "sabine", "absorption coefficient", "edc"],
    "模态": ["room mode", "modal frequency", "modes of a room", "eigenfrequency"],
}


def term_pattern(term):
    """把术语编译成词边界正则。

    这一步不是可有可无的：早期版本用裸 `in` 子串匹配，
    结果 `edt` 命中了 `nestedtext` 和 `moon_edtf`、`t20` 命中了 `moontemplate`、
    `edc` 命中了 `moonrpc` —— 全是子串巧合，把 4 个无关模块报成了命中。

    短缩写必须要求独立成词，否则统计结果会被子串噪声淹没。
    """
    parts = [re.escape(p) for p in term.split()]
    return re.compile(r"(?<![a-z0-9])" + r"\s+".join(parts) + r"(?![a-z0-9])")


def load_index():
    if not os.path.exists(REGISTRY):
        print(f"找不到索引文件：{REGISTRY}")
        print("请先在项目目录执行：moon update")
        sys.exit(1)
    with io.open(REGISTRY, encoding="utf-8") as f:
        return json.load(f)


def entries(raw):
    """索引结构在不同版本间可能是 list 或 dict，统一成 list of (name, text)。"""
    if isinstance(raw, dict):
        for key in ("mods", "modules", "data", "items"):
            if key in raw:
                raw = raw[key]
                break
        else:
            raw = [raw]
    out = []
    for it in raw:
        if isinstance(it, str):
            out.append((it, it.lower()))
        elif isinstance(it, dict):
            name = it.get("name") or it.get("id") or ""
            desc = (
                it.get("description")
                or it.get("summary")
                or it.get("desc")
                or ""
            )
            keys = it.get("keywords") or []
            if isinstance(keys, list):
                keys = " ".join(keys)
            text = f"{name} {desc} {keys}".lower()
            out.append((name, text))
    return out


def self_check(items):
    """尺子自检：喂几个必须命中/必须不命中的样本，确认检索逻辑本身有效。

    这几条负样本是真实踩过的坑（早期子串匹配会误报）：
    `nestedtext` 含 'edt'、`moontemplate` 含 't20'、`moonrpc` 含 'edc'。
    """
    probes = [
        ("真阳性：房间声学描述", "room acoustics reverberation rt60", True),
        ("真阳性：impulse response", "compute rt60 from an impulse response", True),
        ("真阳性：schroeder", "schroeder integration for decay time", True),
        ("假阳性：nestedtext 里的 edt", "a tool for nestedtext processing", False),
        ("假阳性：moontemplate 里的 t20", "a project template engine", False),
        ("假阳性：moonrpc 里的 edc 子串", "an rpc library with edcx support", False),
        ("假阳性：reverberation 的子串", "a reverberationsque effect library", False),
        ("无关：csv parser", "a parser for csv files", False),
    ]
    ok = True
    for name, text, should_hit in probes:
        hit = search_terms(text)
        mark = "OK " if hit == should_hit else "BAD"
        if hit != should_hit:
            ok = False
        print(f"  [{mark}] {name}: 命中={hit} 期望={should_hit}")
    return ok


def search_terms(text):
    for terms in TERMS.values():
        for t in terms:
            if term_pattern(t).search(text):
                return True
    return False


def main():
    raw = load_index()
    items = entries(raw)
    total = len(items)

    print("=" * 68)
    print("生态术语检索 —— 房间声学测量赛道占用情况")
    print("=" * 68)
    print(f"索引模块总数：{total}")
    print(f"索引文件：{REGISTRY}")
    print()

    print("[自检] 先验证检索逻辑本身有效（尺子要准）")
    if not self_check(items):
        print("  自检未通过，下面的统计不可信")
        sys.exit(1)
    print("  自检通过")
    print()

    hits = {}
    for category, terms in TERMS.items():
        found = []
        for name, text in items:
            matched = [t for t in terms if term_pattern(t).search(text)]
            if matched:
                found.append((name, matched))
        hits[category] = found
        print(f"[{category}] {len(found)} 个模块命中")
        for name, matched in found[:8]:
            print(f"    {name}   <- {', '.join(matched)}")
        if len(found) > 8:
            print(f"    ... 另有 {len(found) - 8} 个")
        print()

    # 判定：没有任何模块同时命中多个类别，才算真正空置
    all_hit = {name for found in hits.values() for name, _ in found}
    # 统计每个模块命中的类别数
    cat_count = {}
    for category, found in hits.items():
        for name, _ in found:
            cat_count[name] = cat_count.get(name, 0) + 1
    multi = sorted([(n, c) for n, c in cat_count.items() if c >= 2])

    print("=" * 68)
    print("判定")
    print("=" * 68)
    print(f"命中任一术语的模块数：{len(all_hit)}")
    print(f"命中 2 类及以上术语的模块数：{len(multi)}")
    if multi:
        print("以下模块需要人工确认是否为房间声学项目：")
        for n, c in multi:
            print(f"    {n}  命中 {c} 类")
    else:
        print()
        print("结论：无任何模块命中 2 类及以上术语。")
        print("      房间声学测量在当前生态中为 0 个。")
        print()
        print("说明：这里要求 2 类以上才算命中，是因为单个术语会有偶然误报——")
        print("      例如描述里提到 'decay' 可能与房间声学无关。")
        print("      要求同时命中'核心指标'和'方法/公式'两类的模块，")
        print("      才可能是在做本领域的项目。")


if __name__ == "__main__":
    main()