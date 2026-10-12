import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../common/theme.dart';

/// 书源仓库「二维码导入」扫码页。
///
/// 扫到第一个有效的书源二维码后 `Navigator.pop` 返回其原始文本，
/// 由仓库页走与「口令导入」相同的解析链路（_parseSources → addAll）。
/// 纯相机页：黑底 + 扫描框 + 底部提示，不引入额外样式依赖。
class BookSourceQrScanPage extends StatefulWidget {
  const BookSourceQrScanPage({super.key});

  @override
  State<BookSourceQrScanPage> createState() => _BookSourceQrScanPageState();
}

class _BookSourceQrScanPageState extends State<BookSourceQrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      _handled = true;
      Navigator.pop(context, raw.trim());
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('二维码导入'),
        actions: [
          IconButton(
            tooltip: _torchOn ? '关闭手电筒' : '打开手电筒',
            icon: Icon(
              _torchOn ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
            ),
            onPressed: () async {
              // mobile_scanner 7.x 的 toggleTorch() 返回 void（无开关结果），
              // 不能用返回值判断 ⇒ 本地状态自翻转
              await _controller.toggleTorch();
              if (mounted) setState(() => _torchOn = !_torchOn);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          // 相机预览（占满，onDetect 扫到即返回文本）
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              fit: BoxFit.cover,
              onDetect: _onDetect,
            ),
          ),
          // 扫描框角标 + 半透明遮罩（中间留出取景区）
          Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  // 四角
                  for (final c in _corners) c,
                ],
              ),
            ),
          ),
          // 底部提示
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '将书源二维码对准扫描框，自动识别导入',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '也支持扫描分享口令生成的二维码',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      // 顶部状态栏图标在深色背景上可见
      extendBodyBehindAppBar: false,
    );
  }

  /// 四个扫描框角标（纯白边角，不依赖主题色）
  List<Widget> get _corners {
    const color = Colors.white;
    const len = 26.0;
    const thick = 4.0;
    const pad = 16.0;
    // 四个角各自只亮两条边 ⇒ 未传的边默认不画（原来写成 required 但调用方
    // 只给两条 ⇒ 9 处 missing_required_argument 编译错误）
    Widget c({
      bool top = false,
      bool bottom = false,
      bool left = false,
      bool right = false,
    }) =>
        Container(
          width: len,
          height: len,
          decoration: BoxDecoration(
            border: Border(
              top: top ? BorderSide(color: color, width: thick) : BorderSide.none,
              bottom: bottom ? BorderSide(color: color, width: thick) : BorderSide.none,
              left: left ? BorderSide(color: color, width: thick) : BorderSide.none,
              right: right ? BorderSide(color: color, width: thick) : BorderSide.none,
            ),
          ),
        );
    return [
      Positioned(top: pad, left: pad, child: c(top: true, left: true)),
      Positioned(top: pad, right: pad, child: c(top: true, right: true)),
      Positioned(bottom: pad, left: pad, child: c(bottom: true, left: true)),
      Positioned(bottom: pad, right: pad, child: c(bottom: true, right: true)),
    ];
  }
}
