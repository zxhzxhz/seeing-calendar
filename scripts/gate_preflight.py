#!/usr/bin/env python3
"""门禁脚本预检：在烧掉一次 CI 之前，先把「门禁自己写错」的那类问题拦住。

背景：`verify_*.swift` 里成百上千条 `check(<变量>.contains("字面量"), ...)` 是纯文本断言。
它们有两个只会让门禁自己出问题的失败模式：

  ① **接收变量不在作用域里** —— 例如把 `eventCode.contains(...)` 写成 `code.contains(...)`。
     Swift 直接编译失败：`error: cannot find 'code' in scope`，
     整条门禁（乃至整个 CI run）为一行笔误陪葬。
  ② **字面量在生产源码里根本不存在** —— 断言写错了目标，或生产代码改了措辞而门禁没跟着改。

本脚本用最朴素的扫描复现这两条判定（不编译、不执行 Swift），
所以它自己必须保持「宁可少报，不可误报」：解析不出接收变量或目标文件时一律跳过。

    python3 scripts/gate_preflight.py
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
BACKSLASH = chr(92)
QUOTE = chr(34)
ASSIGN = re.compile(r"let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(productionSource|normalizeWhitespace)\s*\(")
DECLARED = re.compile(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)")


def normalize(text: str) -> str:
    """镜像门禁脚本里的 normalizeWhitespace。"""
    return " ".join(text.split())


def read(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def literal_after(source: str, index: int) -> str | None:
    """从 index 开始找出下一个字符串字面量（跳过转义）。

    带插值的字面量（`\(name)`）直接返回 None：它的运行期取值依赖上下文，
    拿来和源码做文本比较必然误报 —— 预检宁可跳过，不可乱报。
    """
    cursor = source.find(QUOTE, index)
    if cursor < 0:
        return None
    cursor += 1
    out: list[str] = []
    while cursor < len(source):
        char = source[cursor]
        if char == BACKSLASH:
            if source[cursor + 1] == "(":
                return None
            out.append(source[cursor + 1])
            cursor += 2
            continue
        if char == QUOTE:
            return "".join(out)
        out.append(char)
        cursor += 1
    return None


def receiver_chain(source: str, index: int) -> tuple[str, str]:
    """取 `.contains(` 之前的成员链：返回 (整条链, 链根)。

    `store.diskPNGs.contains(` 的链是 `store.diskPNGs`、根是 `store` ——
    作用域要查链根，目标文件要查整条链（也可能就是简单名）。
    """
    cursor = index
    while cursor > 0 and (source[cursor - 1].isalnum() or source[cursor - 1] in "_."):
        cursor -= 1
    chain = source[cursor:index]
    return chain, chain.split(".")[0]


def identifier_after(source: str, index: int) -> str | None:
    """取 index 之后第一个标识符（跳过空白）—— 用于 `normalizeWhitespace(<名>)` 的实参。"""
    cursor = index
    while cursor < len(source) and source[cursor] in " \t\n":
        cursor += 1
    end = cursor
    while end < len(source) and (source[end].isalnum() or source[end] == "_"):
        end += 1
    return source[cursor:end] or None


def targets(source: str) -> dict[str, str]:
    """`let x = productionSource("路径")` / `let y = normalizeWhitespace(x)` → 变量到路径。"""
    mapping: dict[str, str] = {}
    for match in ASSIGN.finditer(source):
        name, kind = match.group(1), match.group(2)
        if kind == "productionSource":
            literal = literal_after(source, match.end() - 1)
            if literal:
                mapping[name] = literal
        else:
            inner = identifier_after(source, match.end())
            if inner and inner in mapping:
                mapping[name] = mapping[inner]
    return mapping


def function_blocks(source: str) -> list[tuple[str, str]]:
    """按行切出顶层函数（断言都写在 `func …` 里；这些脚本的函数都顶格写）。"""
    lines = source.split("\n")
    starts = [index for index, line in enumerate(lines) if line.startswith("func ")]
    blocks: list[tuple[str, str]] = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        name = lines[start][len("func "):].split("(")[0]
        blocks.append((name, "\n".join(lines[start:end])))
    return blocks


def declared_names(block: str) -> set[str]:
    names = set(DECLARED.findall(block))
    names.update(re.findall(r"for\s+\(([^)]*)\)\s+in",
                            block))
    for match in re.finditer(r"for\s+\(([^)]*)\)\s+in", block):
        names.update(part.strip() for part in match.group(1).split(","))
    for match in re.finditer(r"for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in", block):
        names.add(match.group(1))
    return names


def main() -> int:
    gates = sorted((ROOT / "scripts").glob("verify_*.swift"))
    problems: list[str] = []
    pinned = 0
    cache: dict[pathlib.Path, str] = {}

    for gate in gates:
        source = read(gate)
        for _, block in function_blocks(source):
            # 变量映射必须**按函数**取：不同函数里的 `store` 是不同东西
            # （一个是 `FakeStore()`，一个是 `productionSource(...)`），
            # 跨函数合并映射会把断言指到不相干的生产文件上。
            mapping = targets(block)
            names = declared_names(block)
            cursor = 0
            while True:
                found = block.find(".contains(", cursor)
                if found < 0:
                    break
                cursor = found + len(".contains(")
                chain, root = receiver_chain(block, found)
                literal = literal_after(block, cursor)
                if not chain or literal is None:
                    continue
                window = block[max(0, found - len(chain) - 12):found]
                if "check" not in window:
                    continue
                pinned += 1
                if root not in names and root != "self":
                    problems.append(f"{gate.name}: 接收变量 `{root}` 不在作用域里 → Swift 编译失败"
                                    f"（断言：{literal[:60]}）")
                    continue
                if "check(!" in window:      # 否定断言：字面量本来就该不存在
                    continue
                target = mapping.get(chain) or mapping.get(root)
                if not target:
                    continue
                path = ROOT / target
                if path not in cache:
                    cache[path] = normalize(read(path))
                if literal not in cache[path]:
                    problems.append(f"{gate.name}: 断言字面量在 {target} 里不存在 → 「{literal[:70]}」")

    print(f"门禁预检：{len(gates)} 个脚本 / {pinned} 条文本断言")
    if problems:
        print(f"发现 {len(problems)} 处问题：")
        for problem in problems:
            print(f"  • {problem}")
        return 1
    print("PASS  接收变量全部在作用域内，且正向断言的字面量都能在生产源码里找到")
    return 0


if __name__ == "__main__":
    sys.exit(main())
