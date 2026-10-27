import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/pet/pet_center_page.dart';
import 'package:tvbox/reading/pet/pet_chat_sheet.dart';
import 'package:tvbox/reading/pet/pet_service.dart';
import 'package:tvbox/reading/pet/pet_view.dart';

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

  /// 待机动画（呼吸/眨眼）。
  ///
  /// 🔴 2026-10-27 重构：原来这里是 `..repeat()` —— **构造即无限循环**。
  ///   而这个组件挂在 `app.dart` 的根 Stack 上（覆盖所有路由），于是：
  ///     · 桌宠被关掉时（build 返回 `SizedBox.shrink()`）**ticker 还在跑**，
  ///       每帧调度一次、什么都不画 ⇒ 白耗电；
  ///     · App 切到后台也照跑（`_resumed` 只用来算猫币，没管动画）。
  ///   现在改成**按需启停**（见 [_syncTicker]）：不可见/后台/未加载时 `stop()`。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  Timer? _syncTimer;
  Timer? _usageTimer;
  Timer? _bubbleTimer;

  /// 点击弹一下的复位定时器（原来是个裸 Timer，页面销毁时没取消）
  Timer? _bounceTimer;

  String? _bubble;
  bool _dragging = false;

  /// App 是否在前台（前台才累计使用时长发猫币，也才跑待机动画）
  bool _resumed = true;

  /// 点一下弹一下（互动反馈）
  bool _bounce = false;

  static const _bubbleMaxWidth = 180.0;

  /// 按当前状态启停待机动画。
  ///
  /// 只在「已加载 + 已开启 + App 在前台」时才转 —— 这三个条件任何一个不满足，
  /// 桌宠都是看不见的，继续跑 ticker 纯属白烧 GPU/电量。
  void _syncTicker() {
    final shouldRun = _pet.isLoaded && _pet.enabled && _resumed;
    if (shouldRun == _anim.isAnimating) return;
    if (shouldRun) {
      _anim.repeat();
    } else {
      _anim.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 开关/换装/加载完成都会 notify ⇒ 顺带校正动画启停
    _pet.addListener(_syncTicker);
    _syncTicker();
    _pet.load().then((_) {
      if (!mounted) return;
      _pet.syncReading();
      _syncTicker();
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
    _pet.removeListener(_syncTicker);
    _syncTimer?.cancel();
    _usageTimer?.cancel();
    _bubbleTimer?.cancel();
    _bounceTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    // 后台不跑待机动画
    _syncTicker();
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

  /// 点宠物弹出对话：**贴着宠物**弹（用户 2026-10-25：
  /// 「点击弹出的对话，能不能挨着宠物一些」）——
  /// 原来用 showDialog 固定居中，宠物在角落时卡片离它很远。
  /// 这里把宠物当前的屏幕矩形一起带过去，由 [PetChatSheet] 决定放哪一侧。
  Rect? _petRect;

  Future<void> _onTap() async {
    // 互动反馈：先弹一下
    setState(() => _bounce = true);
    _bounceTimer?.cancel();
    _bounceTimer = Timer(const Duration(milliseconds: 180), () {
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
      builder: (_) => PetChatSheet(anchor: _petRect),
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
                // 长按菜单只要文字（用户 2026-10-27）—— 原来三个按钮/条目
                // 都带图标，去掉后整块只剩文字，视线不再被图标打断。
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Get.back();
                          _feed();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textPrimary,
                        ),
                        child: const Text('喂食 10 币'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Get.back();
                          _onTap();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textPrimary,
                        ),
                        child: const Text('摸摸'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
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
            // 内置矢量宠物贴边时走「门后探头」（画笔里画细白门框 + 只露脑袋）；
            // 自定义 PNG/GIF 没法画门框，还是老样子整体推出屏幕 + 斜 45°。
            final peek = !_pet.hasCustomPet && (dockLeft || dockRight)
                ? (dockLeft ? -1 : 1)
                : 0;
            // 记录宠物**实际可见**的屏幕矩形（贴边姿态有位移）——
            // 点开对话时用它算"贴着宠物"的位置
            final dockDx = peek != 0
                ? 0.0
                : (dockLeft ? -petSize * 0.62 : (dockRight ? petSize * 0.62 : 0.0));
            _petRect = peek != 0
                ? Rect.fromLTWH(
                    dockLeft ? left : left + petSize * 0.16,
                    top + petSize * 0.10,
                    petSize * 0.84,
                    petSize * 0.86,
                  )
                : Rect.fromLTWH(left + dockDx, top, petSize, petSize);

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
                                peek: peek,
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

            if ((dockLeft || dockRight) && peek == 0) {
              // 贴边姿态（用户 2026-10-25：斜着 45°）——
              //   一半身子推到屏幕外，同时整体朝屏幕内侧倾 45°，
              //   像从边缘斜插进来的贴纸。
              // ⚠️ 探出量（2026-10-25 第二轮）：原来只推 0.45，旋转 45° 之后
              //   实际露出屏幕的部分接近 2/3，用户反馈「贴边的时候出来太多了」
              //   ⇒ 推到 0.62，只露一小截。
              // 2026-10-27：内置矢量宠物改成「门后探头」（peek != 0），
              //   不再整体推出去 —— 门框和爪子都是画笔在组件内侧画的。
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
