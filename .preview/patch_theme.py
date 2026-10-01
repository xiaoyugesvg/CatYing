# -*- coding: utf-8 -*-
"""冷启动修复 v2：自动检测行尾（LF/CRLF），替换后保留原行尾。"""
import io
import sys

def patch(path, old_lines, new_lines):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        s = f.read()
    # 检测文件行尾：取**多数派**（少量混入的 CRLF 不应改变整体判定）
    crlf = s.count('\r\n')
    bare = s.count('\n') - crlf
    eol = '\r\n' if crlf >= bare else '\n'
    old = eol.join(old_lines) + eol
    new = eol.join(new_lines) + eol
    if old not in s:
        print(f'NOT FOUND in {path}')
        sys.exit(1)
    if s.count(old) != 1:
        print(f'AMBIGUOUS ({s.count(old)} hits) in {path}')
        sys.exit(1)
    s = s.replace(old, new)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(s)
    print(f'patched: {path}')

# 1) app.dart: 删除冷启动覆盖
patch(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\app.dart',
    [
        '    // 冷启动：直接把持久化的外观模式应用上去',
        '    ThemeModeStore.set(bg.appearanceMode.value == AppearanceMode.light',
        '        ? ThemeMode.light',
        '        : ThemeMode.dark);',
    ],
    [
        '    // 主题模式（含「跟随系统」）在 main() 启动时已从 prefs 加载，',
        '    // 这里**不再**用 BackgroundService.appearanceMode（只有 light/dark 两值）',
        '    // 覆盖 —— 旧逻辑每次冷启动都会把 \'system\' 覆盖成 dark/light，',
        '    // 导致「跟随系统」重启后丢失。',
    ],
)

# 2) content_view.dart: 删除 load().then 覆盖
patch(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\pages\content_view.dart',
    [
        '    // ⚠️ load() 是异步的：它读 theme_mode 会改明暗。外观模式是唯一来源，',
        '    // 所以读完必须再用 BackgroundService 的外观模式断言一次，',
        '    // 否则冷启动的明暗会被历史 theme_mode 覆盖。',
        '    ThemeModeStore.load().then((_) {',
        '      final bg = Get.isRegistered<BackgroundService>()',
        '          ? BackgroundService.instance',
        '          : null;',
        '      if (bg == null) return;',
        '      ThemeModeStore.set(bg.appearanceMode.value == AppearanceMode.light',
        '          ? ThemeMode.light',
        '          : ThemeMode.dark);',
        '    });',
    ],
    [
        '    // 主题模式（含「跟随系统」）已在 main() 启动时从 prefs 加载，',
        '    // 这里不再用 BackgroundService.appearanceMode 覆盖 ——',
        '    // 旧逻辑每次冷启动都会把 \'system\' 覆盖成 dark/light（跟随系统丢失）。',
    ],
)

# 3) main.dart: “以阅读为基准” → “以全局 prefs 为基准”，保留 system
patch(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\main.dart',
    [
        '  // 启动后立刻同步一次：以阅读当前的明暗为基准，把音乐和全局拉齐',
        '  final readingMode = SettingsService().themeFollowSystem',
        '      ? ThemeMode.system',
        '      : (SettingsService().isDarkMode ? ThemeMode.dark : ThemeMode.light);',
        '  ThemeModeStore.set(readingMode);',
    ],
    [
        '  // 启动：从 prefs 加载全局主题模式（含 \'system\'，不再被覆盖丢失），',
        '  // 然后以全局为基准把音乐 / 阅读 / 壁纸那一套拉齐。',
        '  await ThemeModeStore.load();',
        '  final globalMode = ThemeModeStore.mode;',
        '  GlobalThemeSync.pushToModules(globalMode);',
        '  final wantLight = switch (globalMode) {',
        '    ThemeMode.light => true,',
        '    ThemeMode.dark => false,',
        '    ThemeMode.system =>',
        '      WidgetsBinding.instance.platformDispatcher.platformBrightness ==',
        '          Brightness.light,',
        '  };',
        '  await BackgroundService.instance.setAppearanceMode(',
        '      wantLight ? AppearanceMode.light : AppearanceMode.dark);',
    ],
)

print('ALL DONE')
