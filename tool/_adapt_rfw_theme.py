"""把 PeekPro 生态的 .rfwtxt 主题适配到猫影的 RFW 引擎（一次性脚本）。

两个不兼容点：
  1. `Icon(icon: args.icon)` —— rfw 的 Icon 解码器要从 `icon` 里取 int 码点，
     塞整个 {icon, fontFamily} map 进去会回落 flutter_dash（豆腐块）。
     改成 `icon: X.icon, fontFamily: X.fontFamily`。
  2. `ListView(...)` —— rfw 把它实现成 `ListView.builder`，子项元素在 layout
     阶段才创建；而 `source.child()` 会在那时给**父** _WidgetState 建数据订阅，
     于是 setState 打在一个正在 build 的祖先上 → "setState during build"。
     改成 `SingleChildScrollView + Row/Column`（一次性构建，条目本来就不多）。
"""

import re
import sys

OPEN_TO_CLOSE = {'(': ')', '[': ']', '{': '}'}


def match_bracket(s, i):
    open_c = s[i]
    close_c = OPEN_TO_CLOSE[open_c]
    depth = 0
    j = i
    in_str = False
    while j < len(s):
        c = s[j]
        if in_str:
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise RuntimeError('unbalanced bracket at %d' % i)


def line_indent(text, idx):
    start = text.rfind('\n', 0, idx) + 1
    line = text[start:idx]
    return len(line) - len(line.lstrip(' '))


def fix_icons(text):
    pattern = re.compile(
        r'Icon\(\n([ \t]*)icon: (args\.icon|data\.home\.icons\.[A-Za-z0-9_]+),\n'
        r'[ \t]*fontFamily: "MaterialIcons",'
    )

    def repl(m):
        indent, expr = m.group(1), m.group(2)
        return 'Icon(\n%sicon: %s.icon,\n% sfontFamily: %s.fontFamily,' % (
            indent, expr, indent, expr)

    return pattern.sub(repl, text)


def convert_listviews(text):
    out = []
    pos = 0
    count = 0
    while True:
        idx = text.find('ListView(', pos)
        if idx < 0:
            out.append(text[pos:])
            break
        popen = idx + len('ListView')
        pclose = match_bracket(text, popen)
        inner = text[popen + 1:pclose]
        ci = inner.find('children:')
        if ci < 0:
            out.append(text[pos:pclose + 1])
            pos = pclose + 1
            continue
        bi = inner.index('[', ci)
        bclose = match_bracket(inner, bi)
        items = inner[bi + 1:bclose]
        horizontal = 'scrollDirection: "horizontal"' in inner
        ind = ' ' * line_indent(text, idx)
        body = 'children: [%s]' % items
        if horizontal:
            repl = (
                'SingleChildScrollView(\n'
                + ind + '  scrollDirection: "horizontal",\n'
                + ind + '  child: Row(\n'
                + ind + '    mainAxisSize: "min",\n'
                + ind + '    ' + body + ',\n'
                + ind + '  ),\n'
                + ind + ')'
            )
        else:
            repl = (
                'SingleChildScrollView(\n'
                + ind + '  child: Column(\n'
                + ind + '    ' + body + ',\n'
                + ind + '  ),\n'
                + ind + ')'
            )
        out.append(text[pos:idx])
        out.append(repl)
        pos = pclose + 1
        count += 1
    return ''.join(out), count


def main(paths):
    for path in paths:
        with open(path, 'r', encoding='utf-8') as f:
            text = f.read()
        original = text
        text, n_list = convert_listviews(text)
        text = fix_icons(text)
        if text == original:
            print('%s: 无需改动' % path)
            continue
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('%s: ListView→SingleChildScrollView %d 处，Icon 修正 %d 处' % (
            path,
            n_list,
            len(re.findall(r'\.icon,\n[ \t]*fontFamily: [A-Za-z.]+\.fontFamily', text)),
        ))


if __name__ == '__main__':
    main(sys.argv[1:])
