#!/usr/bin/env python3
"""Swift ↔ ObjC 桥接的静态检查。

## 为什么需要它

2026-10-31 的 CI 失败：

    Invalid conversion from throwing function of type '() throws -> Void'
    to non-throwing function type '() -> Void'
    ios/Runner/BackgroundAudio.swift:223

`TvBoxTryCatch` 是 ObjC 函数（`ExceptionGuard.h`）：

    FOUNDATION_EXPORT BOOL TvBoxTryCatch(void (^block)(void));

参数是**非 throwing** 的 `void (^)(void)`。只要闭包里出现一个裸 `try`，
Swift 就把整个闭包推断成 `() throws -> Void`，与参数类型不匹配 → 编译失败。

这类错误在 Windows 上**永远发现不了**（编不了 iOS），只能等 macOS runner
跑到 Xcode 构建那一步才炸，一次浪费 4~5 分钟构建 + 10 倍 macOS 额度。
所以在这里用纯文本扫描提前拦住。

## 规则

R1  `TvBoxTryCatch({ ... })` 闭包内存在**未被 `do/catch` 接住**的 `try`
    （`try?` / `try!` 不算 —— 它们不传播错误，闭包仍是非 throwing）。

## 用法

    python3 tool/check_swift_objc_bridge.py            # 扫 ios/ 下所有 .swift
    python3 tool/check_swift_objc_bridge.py --file x.swift   # 只扫一个文件

退出码：0 = 通过；1 = 发现问题。
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# 接受「非 throwing 闭包」的 ObjC 桥接函数。
# 以后新增同类桥接函数，往这里加即可。
NON_THROWING_BLOCK_FUNCS = ("TvBoxTryCatch",)

# 裸 try：排除 try? / try!（这两个不传播错误）
_BARE_TRY = re.compile(r"(?<![A-Za-z0-9_])try(?!\s*[?!])")


def strip_comment(line: str) -> str:
    """去掉行内 `//` 注释（够用即可：Swift 字符串里出现 // 的场景在本仓库没有）。"""
    idx = line.find("//")
    return line[:idx] if idx >= 0 else line


def match_brace(src: str, open_idx: int) -> int:
    """从 `{` 的下标开始做括号匹配，返回配对的 `}` 下标；找不到返回 -1。"""
    depth = 0
    i = open_idx
    n = len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def unprotected_try_lines(body: str) -> list[tuple[int, str]]:
    """返回闭包体内**没有被 do/catch 接住**的 try 行：[(闭包内相对行号, 行内容)]。

    判定方式：跟踪 `do {` 块。在 `do {` 与它的 `}` 之间的 try 是安全的
    （错误被随后的 `catch` 接住）；其余位置的 try 会传播给闭包本身。
    `catch` 块里的 try 同样不安全（它会继续往外传播）。
    """
    out: list[tuple[int, str]] = []
    do_depth_stack: list[int] = []  # 记录进入 do 块时的花括号深度
    brace_depth = 0
    in_catch = False

    for lineno, raw in enumerate(body.splitlines(), start=1):
        code = strip_comment(raw)

        # 先看这一行是否以 } 开始 —— 可能关掉 do 块或 catch 块
        stripped = code.strip()
        if stripped.startswith("}"):
            # 关掉一个块：如果栈顶深度 == 当前深度，说明退出 do
            if do_depth_stack and brace_depth == do_depth_stack[-1]:
                do_depth_stack.pop()
                in_catch = False
            elif in_catch and brace_depth == 0:
                in_catch = False

        # 进入 do 块
        if re.search(r"(?<![A-Za-z0-9_])do\s*\{", code):
            do_depth_stack.append(brace_depth + 1)
            in_catch = False

        # catch 块开始（`} catch {` 或 `catch {`）
        if re.search(r"(?<![A-Za-z0-9_])catch\b", code):
            if do_depth_stack:
                do_depth_stack.pop()
            in_catch = True

        # 判断这一行的 try 是否受保护
        if _BARE_TRY.search(code) and not do_depth_stack:
            out.append((lineno, raw.strip()))

        brace_depth += code.count("{") - code.count("}")

    return out


def check_file(path: pathlib.Path) -> list[str]:
    src = path.read_text(encoding="utf-8", errors="replace")
    problems: list[str] = []

    for func in NON_THROWING_BLOCK_FUNCS:
        for m in re.finditer(rf"(?<![A-Za-z0-9_]){re.escape(func)}\s*\(\s*\{{", src):
            brace = src.index("{", m.end() - 1)
            end = match_brace(src, brace)
            if end < 0:
                problems.append(
                    f"{path}:{src[:m.start()].count(chr(10)) + 1} "
                    f"{func} 的闭包括号不匹配，无法检查"
                )
                continue
            body = src[brace : end + 1]
            base_line = src[:brace].count("\n") + 1
            for rel, text in unprotected_try_lines(body):
                problems.append(
                    f"{path}:{base_line + rel - 1} "
                    f"{func} 的闭包里有裸 try（闭包会被推断成 throws，"
                    f"与 void (^)(void) 不匹配）→ {text}"
                )
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", action="append", help="只检查指定文件（可重复）")
    ap.add_argument(
        "--root",
        default="ios",
        help="默认扫描目录（默认 ios）",
    )
    args = ap.parse_args()

    if args.file:
        files = [pathlib.Path(f) for f in args.file]
    else:
        files = sorted(pathlib.Path(args.root).rglob("*.swift"))

    if not files:
        print(f"⚠️  没找到任何 .swift 文件（root={args.root}）")
        return 1

    problems: list[str] = []
    for f in files:
        if not f.exists():
            problems.append(f"{f}: 文件不存在")
            continue
        problems.extend(check_file(f))

    if problems:
        print("❌ Swift/ObjC 桥接检查未通过：\n")
        for p in problems:
            print(f"  {p}")
        print(
            "\n修法：把 throwing 调用包进 do/catch，让闭包本身不再是 throwing。\n"
            "      do/catch 接 Swift Error；TvBoxTryCatch 接 ObjC NSException，两者并存。"
        )
        return 1

    print(f"✅ Swift/ObjC 桥接检查通过（{len(files)} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
