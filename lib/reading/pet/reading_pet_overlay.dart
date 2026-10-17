import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'pet_center_page.dart';
import 'pet_service.dart';
import 'pet_view.dart';

/// 全局悬浮桌宠（挂在 app.dart 根 Stack，覆盖所有路由）。
///
/// 位置用 0~1 的相对坐标持久化；拖动只移动宠物本身，不挡页面其它区域。
class ReadingPetOverlay extends StatefulWidget {
  const ReadingPetOverlay({super.key});

  @override
  State<ReadingPetOverlay> createState() => _ReadingPetOverlayState();
}

class _ReadingPetOverlayState extends State<ReadingPetOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _pet = PetService.instance;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  Timer? _syncTimer;
  Timer? _bubbleTimer;
  String? _bubble;
  bool _dragging = false;

  /// 点一下弹一下（互动反馈）
  bool _bounce = false;

  static const _petSize = 112.0;
  static const _bubbleMaxWidth = 180.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pet.load().then((_) {
      if (!mounted) return;
      _pet.syncReading();
    });
    _syncTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      _pet.syncReading();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _bubbleTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pet.load();
      _pet.syncReading();
    }
  }

  void _say(String text) {
    if (!mounted) return;
    setState(() => _bubble = text);
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  Future<void> _onTap() async {
    // 互动反馈：先弹一下再说话
    setState(() => _bounce = true);
    Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _bounce = false);
    });
    final ok = await _pet.play();
    if (!ok) {
      _say('让我歇一会儿…');
      return;
    }
    const lines = [
      '陪你读书真开心！',
      '今天也要加油呀～',
      '这一页好好看！',
      '摸摸头，继续读～',
      '嘿嘿，书币又多了吗？',
    ];
    _say(lines[Random().nextInt(lines.length)]);
  }

  Future<void> _feed() async {
    final ok = await _pet.feed();
    _say(ok ? '好吃！谢谢投喂～' : '书币不够啦，多读一会儿书吧');
  }

  void _openMenu() {
    final s = _pet;
    Get.bottomSheet(
      Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E22),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      s.species.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Lv.${s.level} · ${s.coins} 书币',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s.statusLine,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Get.back();
                          _feed();
                        },
                        icon: const Icon(Icons.restaurant_rounded, size: 18),
                        label: const Text('喂食 10 币'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Get.back();
                          _onTap();
                        },
                        icon: const Icon(Icons.favorite_rounded, size: 18),
                        label: const Text('摸摸'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.menu_book_rounded,
                      color: Colors.white70),
                  title: const Text('宠物中心 / 图鉴 / 换装',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Get.back();
                    Get.to(() => const PetCenterPage());
                  },
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_off_rounded,
                      color: Colors.white70),
                  title: const Text('隐藏悬浮桌宠',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('可在「我的 → 桌宠」重新打开',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  onTap: () {
                    Get.back();
                    s.setEnabled(false);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      backgroundColor: Colors.transparent,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _pet,
      builder: (context, _) {
        if (!_pet.isLoaded || !_pet.enabled) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final maxX = constraints.maxWidth - _petSize;
            final maxY = constraints.maxHeight - _petSize;
            final left = (_pet.posX * maxX).clamp(0.0, maxX);
            final top = (_pet.posY * maxY).clamp(0.0, maxY);

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_bubble != null) _bubbleView(),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onTap,
                        onLongPress: _openMenu,
                        onPanStart: (_) => setState(() => _dragging = true),
                        onPanUpdate: (d) {
                          final nx = (left + d.delta.dx) / maxX;
                          final ny = (top + d.delta.dy) / maxY;
                          _pet.setPosition(nx, ny);
                        },
                        onPanEnd: (_) {
                          _pet.persistPosition();
                          setState(() => _dragging = false);
                        },
                        child: AnimatedBuilder(
                          animation: _anim,
                          builder: (context, _) => Opacity(
                            opacity: _dragging ? 0.85 : 1,
                            child: AnimatedScale(
                              scale: _bounce ? 1.12 : 1.0,
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutBack,
                              child: PetView(
                                species: _pet.species,
                                outfit: _pet.equippedOutfit,
                                t: _anim.value * 4,
                                size: _petSize,
                                mood: _pet.mood,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 等级小徽标
                      Transform.translate(
                        offset: const Offset(0, -6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Lv.${_pet.level}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _bubbleView() {
    return Container(
      constraints: const BoxConstraints(maxWidth: _bubbleMaxWidth),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        _bubble ?? '',
        style: const TextStyle(
          color: Color(0xFF2B2B2B),
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}
