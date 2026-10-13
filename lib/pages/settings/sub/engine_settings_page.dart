import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/app_state.dart';
import '../../../services/nodejs_manager.dart';
import '../../../services/python_manager.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 引擎管理
///
/// 给用户一个**手动加载**的兜底入口：Node（js/jar spider 引擎）与
/// Python（CPython，.py 源引擎）各一个按钮。自动启动失败、或切源后
/// 想强制把引擎拉起来时，点一下即可，不用重启 App。
class EngineSettingsPage extends StatefulWidget {
  const EngineSettingsPage({super.key});

  @override
  State<EngineSettingsPage> createState() => _EngineSettingsPageState();
}

class _EngineSettingsPageState extends State<EngineSettingsPage> {
  AppState get _appState => Get.find<AppState>();

  bool _nodeBusy = false;
  bool _pyBusy = false;

  // ── 状态文案 ──────────────────────────────────────────────

  String get _nodeStatus {
    final running = NodeJSManager.instance.isRunning;
    final port = NodeJSManager.instance.spiderPort;
    if (running && port > 0) return '运行中 · spider 端口 $port';
    if (running) return '运行中 · 端口未就绪';
    return '未启动';
  }

  String get _pyStatus {
    if (!PythonManager.instance.isIOS) return '当前平台不支持';
    return PythonManager.instance.ready.value ? '已就绪' : '未启动';
  }

  // ── 动作 ──────────────────────────────────────────────────

  Future<void> _loadNode() async {
    if (_nodeBusy) return;
    setState(() => _nodeBusy = true);
    final msg = await _appState.manualLoadNodeEngine();
    if (!mounted) return;
    setState(() => _nodeBusy = false);
    AppToast.message(msg);
  }

  Future<void> _loadPython() async {
    if (_pyBusy) return;
    setState(() => _pyBusy = true);
    final msg = await _appState.manualLoadPythonEngine();
    if (!mounted) return;
    setState(() => _pyBusy = false);
    AppToast.message(msg);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '引擎管理',
      children: [
        SettingsGroup(
          title: '运行时引擎',
          hint: '自动加载失败、或切换源后想强制重载时，点右侧「加载」即可，无需重启 App。',
          children: [
            _engineRow(
              icon: Icons.hub_outlined,
              title: 'Node 引擎',
              status: _nodeStatus,
              busy: _nodeBusy,
              onLoad: _loadNode,
            ),
            _engineRow(
              icon: Icons.terminal_outlined,
              title: 'Python 引擎',
              status: _pyStatus,
              busy: _pyBusy,
              onLoad: _loadPython,
            ),
          ],
        ),
      ],
    );
  }

  Widget _engineRow({
    required IconData icon,
    required String title,
    required String status,
    required bool busy,
    required VoidCallback onLoad,
  }) {
    return SettingsRow(
      icon: icon,
      title: title,
      subtitle: status,
      trailing: SizedBox(
        height: 30,
        child: FilledButton(
          onPressed: busy ? null : onLoad,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accentColor,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
          child: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  '加载',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
        ),
      ),
    );
  }
}
