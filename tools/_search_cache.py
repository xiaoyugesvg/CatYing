# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\search\controller.dart")
s = p.read_text(encoding="utf-8")

if "_lastSearchKeyword" not in s:
    s = s.replace(
        "  Future<void> search() async {\n    final trimmed = keyword.value.trim();\n    if (trimmed.isEmpty) return;",
        """  String _lastSearchKeyword = '';
  DateTime _lastSearchAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> search() async {
    final trimmed = keyword.value.trim();
    if (trimmed.isEmpty) return;

    // 5 分钟内相同关键词且已有结果：直接复用，不重复请求
    if (trimmed == _lastSearchKeyword &&
        resultsBySite.isNotEmpty &&
        DateTime.now().difference(_lastSearchAt).inMinutes < 5) {
      AppLog.instance.log('[SearchController] 命中搜索缓存: "$trimmed"');
      return;
    }
    _lastSearchKeyword = trimmed;
    _lastSearchAt = DateTime.now();""",
        1,
    )
    p.write_text(s, encoding="utf-8")
    print("search short cache ok")

# settings: font scale + cache clear description
p = root / "lib/pages/settings/view.dart" if False else Path(r"C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\settings\view.dart")
s = p.read_text(encoding="utf-8")
if "字号缩放" not in s:
    s = s.replace(
        """          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.bug_report_outlined,
            title: '调试日志',""",
        """          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.format_size,
            title: '字号缩放',
            value: 'x${AppTheme.fontScale.value.toStringAsFixed(1)}',
            onTap: () async {
              const opts = [0.9, 1.0, 1.15, 1.3];
              await _showEnumSelector<double>(
                title: '字号缩放',
                options: opts,
                selected: AppTheme.fontScale.value,
                labelBuilder: (v) => 'x${v.toStringAsFixed(2)}',
                onSelect: (v) async {
                  AppTheme.fontScale.value = v;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setDouble('font_scale', v);
                  setState(() {});
                },
              );
            },
          ),
          Divider(color: AppTheme.borderLight, height: 1),
          SettingsRow(
            icon: Icons.bug_report_outlined,
            title: '调试日志',""",
        1,
    )
    p.write_text(s, encoding="utf-8")
    print("font scale UI ok")

# cache clear subtitle
p = Path(r"C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\settings\view.dart")
s = p.read_text(encoding="utf-8")
s = s.replace(
    "title: '清除应用缓存',",
    "title: '清除应用缓存',\n            // 说明：图片/临时文件；不含历史、收藏、播放器设置\n",
    1,
)
p.write_text(s, encoding="utf-8")
print("done")
