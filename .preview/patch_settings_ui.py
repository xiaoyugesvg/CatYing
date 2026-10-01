# -*- coding: utf-8 -*-
"""设置页：①"设置"标题居中；②删除外观/数据源/播放/内容增强/存储与信息 5 个小节标题。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\settings\view.dart'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()
text = ''.join(lines)
eol = '\r\n' if '\r\n' in text else '\n'

def rep(old, new):
    global text
    assert text.count(old) == 1, (old[:40], text.count(old))
    text = text.replace(old, new)

# 1) 设置标题居中
rep(
    '              Text(\n                \'设置\',\n                style: TextStyle(\n                  color: AppTheme.textPrimary,\n                  fontSize: AppTheme.fontTitle3,\n                  fontWeight: FontWeight.bold,\n                ),\n              ),',
    '              Center(\n                child: Text(\n                  \'设置\',\n                  style: TextStyle(\n                    color: AppTheme.textPrimary,\n                    fontSize: AppTheme.fontTitle3,\n                    fontWeight: FontWeight.bold,\n                  ),\n                ),\n              ),',
)

# 2) 删 5 个小节标题（SectionHeader + 紧随 SizedBox）
for title in ['外观', '数据源', '播放', '内容增强', '存储与信息']:
    rep(
        f'const SectionHeader(title: \'{title}\'),' + eol +
        '              const SizedBox(height: AppTheme.spacingSM),' + eol,
        '',
    )

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)
print('DONE')
