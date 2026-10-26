import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_state.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/services/python_manager.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/common_widgets.dart';

/// Node / Python 两个运行时引擎的「加载」面板。
///
/// 设置页（设置 → 通用设置 → 引擎管理）与首页右上角齿轮弹窗共用这一份，
/// 避免两处状态文案 / 按钮行为各写一套后走偏。
class EngineLoadPanel extends StatefulWidget {
  const EngineLoadPanel({super.key});

  @override
  State<EngineLoadPanel> createState() => _EngineLoadPanelState();
}

class _EngineLoadPanelState extends State<EngineLoadPanel> {
  AppState get _appState => Get.find<AppState>();

  bool _nodeBusy = false;
  bool _pyBusy = false;

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _engineRow(
          icon: Icons.hub_outlined,
          title: 'Node 引擎',
          status: _nodeStatus,
          busy: _nodeBusy,
          onLoad: _loadNode,
        ),
        Divider(
          color: AppTheme.borderLight,
          height: 1,
          thickness: 0.5,
          indent: 48,
          endIndent: 12,
        ),
        _engineRow(
          icon: Icons.terminal_outlined,
          title: 'Python 引擎',
          status: _pyStatus,
          busy: _pyBusy,
          onLoad: _loadPython,
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

/// 居中弹窗：内容是设置里的两个引擎加载行。
Future<void> showEngineLoadDialog(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final card = dark ? AppTheme.palette.cardDark : AppTheme.palette.cardLight;
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 36),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 6, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '引擎加载',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const EngineLoadPanel(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                child: Text(
                  '自动加载失败、或切换源后想强制重载时，点「加载」即可，无需重启 App。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
