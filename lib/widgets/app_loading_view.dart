import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/pages/settings/sub/data_source_settings_page.dart';
import 'package:tvbox/services/app_state.dart';
import 'package:tvbox/widgets/app_splash_view.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/circular_logo_progress.dart';

/// 启动加载页：Logo + 进度（静默下载阶段不显示技术文案）。
///
/// ⚠️ 用户 2026-10-17：「如果源有错误，那你也不能进不去吧」——
/// 所以本页在**加载失败**或**加载超过 15 秒**时一定会给出可操作按钮：
///   · 重试加载
///   · 更换源（订阅管理）
///   · 先进入应用（影视模块显示空状态，不再卡死在启动页）
class AppLoadingView extends StatefulWidget {
  const AppLoadingView({super.key});

  @override
  State<AppLoadingView> createState() => _AppLoadingViewState();
}

class _AppLoadingViewState extends State<AppLoadingView> {
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    // 超过 15 秒仍未完成 → 允许"跳过"（避免卡死在启动页）
    _slowTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  void _enterApp() {
    final appState = Get.find<AppState>();
    appState.enterAppWithoutConfig();
    AppToast.show(
      '已进入应用',
      '当前源不可用，可在「设置 → 订阅管理」更换源后重新加载',
    );
  }

  Future<void> _retry() async {
    final appState = Get.find<AppState>();
    if ((appState.lastVodUrl ?? '').trim().isEmpty) {
      Get.to(() => const DataSourceSettingsPage());
      return;
    }
    await appState.retryLastConfig();
  }

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();

    // 画面只来自 [AppSplashView]（与启动首帧**同一份实现**）——
    // 以前这里自己又拼了一遍 backdrop + logo，改一处忘一处就会出现
    // "两个 logo / 底色跳变"（见 app_splash_view.dart 顶部的说明）。
    return Obx(() {
      final phase = appState.loadingPhase.value;
      final failed = phase.isFailed;
      final showActions = failed || _slow;
      return AppSplashView(
        progress: _buildProgress(appState),
        footer: showActions
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppSplashHint(
                    text: failed
                        ? '当前源加载失败，你仍可以先进入应用，\n稍后在「设置 → 订阅管理」更换源。'
                        : '加载时间有点久，可以先进入应用。',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton(
                        onPressed: _retry,
                        child: const Text('重试'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _enterApp,
                        child: const Text('先进入应用'),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () =>
                        Get.to(() => const DataSourceSettingsPage()),
                    child: const Text('更换源'),
                  ),
                ],
              )
            : null,
      );
    });
  }

  Widget _buildProgress(AppState appState) {
    final phase = appState.loadingPhase.value;
    final indeterminate = phase.isLoading;
    final failed = phase.isFailed;
    // 内部阶段不展示技术文案，只留 Logo + 转圈
    final hideCaption = switch (phase) {
      LoadingPhase.waitingSpiderPort ||
      LoadingPhase.fetchingSpiderConfig ||
      LoadingPhase.initializingSpider ||
      LoadingPhase.loadingSource ||
      LoadingPhase.verifyingMD5 ||
      LoadingPhase.downloadingSource ||
      LoadingPhase.startingNodeJS ||
      LoadingPhase.loadingConfig =>
        true,
      _ => false,
    };
    final statusText = phase.description;
    return CircularLogoProgress(
      progress: indeterminate ? null : (failed ? 0 : 1),
      percentText: indeterminate ? '' : (failed ? '!' : '100%'),
      caption: hideCaption ? '' : statusText,
      failed: failed,
      indeterminate: indeterminate,
    );
  }
}
