import 'package:flutter/material.dart';

import '../../../widgets/engine_load_panel.dart';
import 'settings_shared.dart';

/// 设置 → 引擎管理
///
/// 给用户一个**手动加载**的兜底入口：Node（js/jar spider 引擎）与
/// Python（CPython，.py 源引擎）各一个按钮。自动启动失败、或切源后
/// 想强制把引擎拉起来时，点一下即可，不用重启 App。
///
/// 实际的行 UI 与首页右上角齿轮弹窗共用 [EngineLoadPanel]。
class EngineSettingsPage extends StatelessWidget {
  const EngineSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '引擎管理',
      children: [
        SettingsGroup(
          title: '运行时引擎',
          hint: '自动加载失败、或切换源后想强制重载时，点右侧「加载」即可，无需重启 App。',
          children: const [EngineLoadPanel()],
        ),
      ],
    );
  }
}
