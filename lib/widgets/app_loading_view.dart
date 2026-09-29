import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/app_state.dart';
import '../services/nodejs_manager.dart';
import 'circular_logo_progress.dart';

/// 启动加载页：Logo + 进度（静默下载阶段不显示技术文案）
class AppLoadingView extends StatelessWidget {
  const AppLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = Get.find<AppState>();

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.35),
          radius: 1.3,
          colors: [
            Color(0xFF2A2F33),
            Color(0xFF141618),
            Color(0xFF0C0D0F),
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Obx(() {
            final phase = appState.loadingPhase.value;
            final downloading = phase == LoadingPhase.downloadingNodeJS;
            if (downloading) {
              final mgr = NodeJSManager.instance;
              return ValueListenableBuilder<double?>(
                valueListenable: mgr.nodeDownloadProgress,
                builder: (ctx, p, _) {
                  final value = p ?? 0.0;
                  return ValueListenableBuilder<String?>(
                    valueListenable: mgr.nodeDownloadStatus,
                    builder: (ctx2, status, __) {
                      String label = phase.description;
                      if (status == 'downloading') {
                        label = '下载源运行时';
                      } else if (status == 'extracting') {
                        label = '解压中';
                      } else if (status == 'error') {
                        label = '下载失败';
                      }
                      return CircularLogoProgress(
                        progress: value > 0 ? value : null,
                        percentText: '${(value * 100).toStringAsFixed(0)}%',
                        caption: label,
                        failed: status == 'error',
                      );
                    },
                  );
                },
              );
            }
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
          }),
        ),
      ),
    );
  }
}
