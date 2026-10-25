import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import 'pet_center_page.dart';
import 'pet_chat_sheet.dart';
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
  Timer? _usageTimer;
  Timer? _bubbleTimer;
  String? _bubble;
  bool _dragging = false;

  /// App 是否在前台（前台才累计使用时长发猫币）
  bool _resumed = true;

  /// 点一下弹一下（互动反馈）
  bool _bounce = false;

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
    // 全模块使用时长：只要 App 在前台，每分钟累计一次，10 分钟 +1 猫币
    _usageTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_resumed) _pet.addUsageMinute();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _usageTimer?.cancel();
    _bubbleTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
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
    // 互动反馈：先弹一下
    setState(() => _bounce = true);
    Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _bounce = false);
    });
    // 用户 2026-10-25：点宠物 → 直接开对话（文字 / 系统听写），
    // 不再只是随机说一句；"摸摸/喂食"收进长按菜单。
    final ok = await _pet.play();
    if (!mounted) return;
    if (!ok) {
      _say('让我歇一会儿…');
      return;
    }
    // 用户 2026-10-25：对话改成**中间弹窗**，不再从底部抽上来。
    final ctx = Get.context;
    if (ctx == null) return;
    showDialog(
      context: ctx,
      barrierDismissible: true,
      barrierColor: Colors.black26,
      builder: (_) => const PetChatSheet(),
    );
  }

  Future<void> _feed() async {
    final ok = await _pet.feed();
    _say(ok ? '好吃！谢谢投喂～' : '猫币不够啦，多读一会儿书吧');
  }

  void _openMenu() {
    final s = _pet;
    Get.bottomSheet(
      Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
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
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Lv.${s.level} · ${s.coins} 猫币',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s.statusLine,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
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
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textPrimary,
                        ),
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
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textPrimary,
                        ),
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
                  leading: Icon(
                    Icons.menu_book_rounded,
                    color: AppTheme.textSecondary,
                  ),
                  title: Text(
                    '宠物中心 / 图鉴 / 换装',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  onTap: () {
                    Get.back();
                    Get.to(() => const PetCenterPage());
                  },
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.visibility_off_rounded,
                    color: AppTheme.textSecondary,
                  ),
                  title: Text(
                    '隐藏悬浮桌宠',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: Text(
                    '可在「我的 → 桌宠」重新打开',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 11,
                    ),
                  ),
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
            // 尺寸可在「显示设置」里滑动/输入调整（72~160）
            final petSize = _pet.size;
            final maxX = (constraints.maxWidth - petSize).clamp(
              0.0,
              double.infinity,
            );
            final maxY = (constraints.maxHeight - petSize).clamp(
              0.0,
              double.infinity,
            );
            final left = (_pet.posX * maxX).clamp(0.0, maxX);
            final top = (_pet.posY * maxY).clamp(0.0, maxY);
            // 贴边状态：posX 吸附到 0 / 1 时，宠物「扒」在屏幕边缘
            //（身体探出屏幕一部分 + 朝屏幕内侧微倾），而不是贴平站在边上。
            final dockLeft = _pet.posX <= 0.001;
            final dockRight = _pet.posX >= 0.999;

            Widget petBody = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onTap,
                  onLongPress: _openMenu,
                  onPanStart: (_) => setState(() => _dragging = true),
                  onPanUpdate: (d) {
                    // maxX / maxY 在极窄屏（或分屏）可能为 0 ⇒ 别除零
                    final nx = maxX <= 0 ? 0.0 : (left + d.delta.dx) / maxX;
                    final ny = maxY <= 0 ? 0.0 : (top + d.delta.dy) / maxY;
                    _pet.setPosition(nx, ny);
                  },
                  onPanEnd: (_) {
                    // 用户 2026-10-18：「宠物贴边」——
                    // 松手时离左/右边缘 24px 以内就吸附到屏幕边缘，
                    // 不再和屏幕之间留一条缝。
                    final snapX = left <= 24
                        ? 0.0
                        : (left >= maxX - 24 ? 1.0 : _pet.posX);
                    if (snapX != _pet.posX) {
                      _pet.setPosition(snapX, _pet.posY);
                    }
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
                        // 自定义 PNG / GIF 皮肤优先；否则用内置插画 / 矢量
                        child: _pet.hasCustomPet
                            ? CustomPetImage(
                                path: _pet.customPetPath,
                                size: petSize,
                                bob: sin(_anim.value * 2 * pi) * 1.6,
                                outfits: _pet.equippedSlots,
                              )
                            : PetView(
                                species: _pet.species,
                                outfit: _pet.equippedOutfit,
                                outfits: _pet.equippedOutfitsByName,
                                t: _anim.value * 4,
                                size: petSize,
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
                      horizontal: 8,
                      vertical: 2,
                    ),
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
            );

            if (dockLeft || dockRight) {
              // 贴边姿态（用户 2026-10-25：斜着 45°）——
              //   一半身子推到屏幕外，同时整体朝屏幕内侧倾 45°，
              //   像从边缘斜插进来的贴纸。
              // ⚠️ 探出量（2026-10-25 第二轮）：原来只推 0.45，旋转 45° 之后
              //   实际露出屏幕的部分接近 2/3，用户反馈「贴边的时候出来太多了」
              //   ⇒ 推到 0.62，只露一小截。
              petBody = Transform.translate(
                offset: Offset(
                  dockLeft ? -petSize * 0.62 : petSize * 0.62,
                  0,
                ),
                child: Transform.rotate(
                  angle: dockLeft ? pi / 4 : -pi / 4,
                  alignment:
                      dockLeft ? Alignment.bottomLeft : Alignment.bottomRight,
                  child: petBody,
                ),
              );
            }

            // 气泡单独定位：永远留在屏幕内；顶部空间不够时改到宠物下方
            const bubbleW = _bubbleMaxWidth;
            final bubbleLeft = (left + petSize / 2 - bubbleW / 2).clamp(
              8.0,
              (constraints.maxWidth - bubbleW - 8).clamp(8.0, double.infinity),
            );
            final showBelow = top < 92;

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(left: left, top: top, child: petBody),
                if (_bubble != null)
                  Positioned(
                    left: bubbleLeft,
                    top: showBelow ? top + petSize + 28 : null,
                    bottom: showBelow
                        ? null
                        : (constraints.maxHeight - top + 4).clamp(
                            4.0,
                            double.infinity,
                          ),
                    child: _bubbleView(),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
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
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}
