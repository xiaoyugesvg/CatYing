# -*- coding: utf-8 -*-
"""第二批 A2：三处空态 → AppEmptyView（保留各自图标/文案/按钮）。"""
import io

def process(path, old, new, imp=None):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        lines = f.readlines()
    text = ''.join(lines)
    assert text.count(old) == 1, (path, text.count(old))
    text = text.replace(old, new)
    if imp:
        lines = text.splitlines(keepends=True)
        last_import = -1
        for i, ln in enumerate(lines):
            if ln.startswith('import '):
                last_import = i
        assert last_import != -1, path
        eol = '\r\n' if lines[last_import].endswith('\r\n') else '\n'
        lines.insert(last_import + 1, imp + eol)
        text = ''.join(lines)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    print('patched', path)

# 1) 音乐：搜索无结果 → AppEmptyView
process(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\music\pages\discover_page.dart',
    """        if (!r.ok || r.list.isEmpty) {
          return Center(
            child: Text(r.message.isEmpty ? '没有找到结果' : r.message,
                style: TextStyle(color: MusicTheme.secondary, fontSize: 13)),
          );
        }""",
    """        if (!r.ok || r.list.isEmpty) {
          return AppEmptyView(
            icon: Icons.search_off_rounded,
            title: r.message.isEmpty ? '没有找到结果' : r.message,
          );
        }""",
    "import '../../widgets/app_empty_view.dart';",
)

# 2) 阅读：_buildEmpty 实现 → AppEmptyView
process(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\bookshelf_page.dart',
    """Widget _buildEmpty(BuildContext context, String text, IconData icon) {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        Text(text, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        const Text(
          '去详情页加入书架吧',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ],
    ),
  );
}""",
    """Widget _buildEmpty(BuildContext context, String text, IconData icon) {
  return AppEmptyView(
    title: text,
    subtitle: '去详情页加入书架吧',
    icon: icon,
    iconColor: JellyTheme.primary.withValues(alpha: 0.5),
  );
}""",
    "import '../../widgets/app_empty_view.dart';",
)

# 3) 影视直播：_EmptyLive → AppEmptyView（按钮作 action）
process(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\live\view.dart',
    """  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.live_tv, color: AppTheme.textTertiary, size: 48),
          SizedBox(height: 12),
          Text('暂无直播频道',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          SizedBox(height: 6),
          Text('在订阅 JSON 的 lives 配置，或导入 m3u',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
          SizedBox(height: 16),
          OutlinedButton(
            onPressed: onReload,
            child: Text('导入直播源',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }""",
    """  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: Icons.live_tv,
      title: '暂无直播频道',
      subtitle: '在订阅 JSON 的 lives 配置，或导入 m3u',
      iconColor: AppTheme.textTertiary,
      action: OutlinedButton(
        onPressed: onReload,
        child: Text('导入直播源',
            style: TextStyle(color: AppTheme.accentColor)),
      ),
    );
  }""",
    "import '../../widgets/app_empty_view.dart';",
)

print('ALL DONE')
