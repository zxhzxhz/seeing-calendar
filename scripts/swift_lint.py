#!/usr/bin/env python3
"""Lightweight Swift sanity linter: brace/paren balance + duplicate type declarations.

Not a compiler — just catches mechanical mistakes before spending a CI cycle.
Run: python scripts/swift_lint.py
"""
from __future__ import annotations

import collections
import pathlib
import re
import sys

BACKSLASH = chr(92)
QUOTE = chr(34)


def strip_noise(src: str) -> str:
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
        elif c == QUOTE:
            i += 1
            while i < n and src[i] != QUOTE:
                if src[i] == BACKSLASH:
                    i += 1
                i += 1
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


DECL_RE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:public\s+|private\s+|internal\s+|final\s+|open\s+)*"
    r"(struct|class|enum|actor|protocol|extension)\s+(\w+)",
    re.M,
)


#: 已知陷阱检查（纯字符串匹配，避免多层转义问题）。
#: 每条 = (触发前缀, 触发关键字, 说明)。
#: 判定方式：在同一文件里，关键字出现在前缀之后（且距离不超过窗口）即命中。
PITFALLS: list[tuple[str, str, int, str]] = [
    (
        "override func hitTest",
        "allTouches",
        2000,
        "UIEvent.allTouches 在 hitTest(_:with:) 阶段不可靠（初次落笔常常取不到该触摸），"
        "据此分流会导致「关闭手指开关后无法套索」。触摸类型请在 touchesBegan 内用 UITouch.type 判定。",
    ),
]


#: 声明形状门禁：v1.0.17 的 `static var calendar` 被全局文本替换误伤成
#: `static func calendar`，烧了一整轮 CI（10 分钟）才发现：swiftc 的报错是
#: `expected '(' in argument list`，指向第 7 行，与真正被改坏的那一行毫无关系，
#: 光看报错极难定位。属性写成函数这个形状必须机器拦。
SHAPE_RE = re.compile(
    r"^[ 	]*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|static\s+|final\s+|class\s+)*"
    r"func\s+(\w+)\s*:\s*[A-Z]",
    re.M,
)


#: property wrapper 不能用调用式构造。`EquatableView { Content }` 会被解析成
#: 「把闭包本身当作内容」，报 `type '() -> X' cannot conform to 'Equatable'`。
#: 正确写法是属性形式：`@EquatableView var grid: MonthGridView`。
WRAPPER_CALL_RE = re.compile(r"(?<!@)(?<!\w)\b(EquatableView)\s*\(?\s*\{")


def check_wrapper_calls(rel, stripped, problems):
    for match in WRAPPER_CALL_RE.finditer(stripped):
        problems.append(
            f"{rel}: {match.group(1)} 以调用式构造 —— 会被解析成「把闭包当内容」。"
            "property wrapper 只能用属性形式：`@EquatableView var grid: MonthGridView`"
            "（必要时用薄壳 View 包一层）。"
        )


def check_shapes(rel, stripped, problems):
    for match in SHAPE_RE.finditer(stripped):
        problems.append(
            f"{rel}: 属性疑似被写成了函数 —— `func {match.group(1)}: T {{`。"
            "计算属性必须写 `var x: T {`；若是函数则需写 `func x() -> T {`。"
        )


def check_pitfalls(rel: str, stripped: str, problems: list[str]) -> None:
    for prefix, keyword, window, reason in PITFALLS:
        cursor = 0
        while True:
            found = stripped.find(prefix, cursor)
            if found < 0:
                break
            segment = stripped[found:found + window]
            if keyword in segment:
                problems.append(f"{rel}: 命中已知陷阱 —— {reason}")
                break
            cursor = found + len(prefix)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    files = sorted((root / "SeeingCalendar").rglob("*.swift"))
    declarations: dict[str, list[str]] = collections.defaultdict(list)
    problems: list[str] = []

    for path in files:
        source = path.read_text(encoding="utf-8")
        stripped = strip_noise(source)
        for label, delta in (
            ("braces", stripped.count("{") - stripped.count("}")),
            ("parens", stripped.count("(") - stripped.count(")")),
            ("brackets", stripped.count("[") - stripped.count("]")),
        ):
            if delta:
                problems.append(f"{path.relative_to(root)}: unbalanced {label} ({delta:+d})")
        for match in DECL_RE.finditer(source):
            declarations[match.group(2)].append(path.name)
        check_pitfalls(str(path.relative_to(root)), stripped, problems)
        check_shapes(str(path.relative_to(root)), stripped, problems)
        check_wrapper_calls(str(path.relative_to(root)), stripped, problems)

    duplicates = {name: where for name, where in declarations.items() if len(where) > 1}

    print(f"files: {len(files)}  |  declared types: {len(declarations)}")
    if duplicates:
        print("duplicate declarations:")
        for name, where in duplicates.items():
            print(f"  - {name}: {where}")
    if problems:
        print("balance problems:")
        for item in problems:
            print(f"  - {item}")
    if not problems and not duplicates:
        print("OK: no mechanical problems detected")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
