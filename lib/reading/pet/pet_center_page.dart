import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../common/theme.dart';
import '../source/global_proxy.dart';
import '../theme/jelly_theme.dart';
import 'pet_models.dart';
import 'pet_service.dart';
import 'pet_view.dart';

/// 桌宠中心：状态 / 喂食 / 换装 / 图鉴。
class PetCenterPage extends StatefulWidget {
  const PetCenterPage({super.key});

  @override
  State<PetCenterPage> createState() => _PetCenterPageState();
}

class _PetCenterPageState extends State<PetCenterPage>
    with SingleTickerProviderStateMixin {
  final _pet = PetService.instance;
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  /// AI 生成中（按钮转圈 / 防重复点击）
  bool _aiBusy = false;

  @override
  void initState() {
    super.initState();
    _pet.load();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '桌宠',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: _pet,
        builder: (context, _) {
          // 图鉴只统计 QQ 秀宠物；旧存档里的生肖解锁记录不计入
          final ownedPets = _pet.unlockedSpecies
              .where((id) => PetSpecies.pets.any((p) => p.id == id))
              .length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              _headerCard(),
              const SizedBox(height: 14),
              _customPetCard(),
              const SizedBox(height: 14),
              _actionsCard(),
              const SizedBox(height: 18),
              _sectionTitle('换装'),
              _outfits(),
              const SizedBox(height: 18),
              _sectionTitle('图鉴（$ownedPets/${PetSpecies.pets.length}）'),
              _collection(),
              const SizedBox(height: 16),
              Text(
                '阅读时长会自动转化为经验：每读 1 分钟 +2 经验、每 10 分钟 +1 书币；'
                '每日打卡额外 +20 书币。',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  height: 1.5,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _headerCard() {
    final s = _pet.species;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) => _pet.hasCustomPet
                ? CustomPetImage(
                    path: _pet.customPetPath,
                    size: 118,
                    bob: 0,
                    outfits: _pet.equippedSlots,
                  )
                : PetView(
                    species: s,
                    outfit: _pet.equippedOutfit,
                    outfits: _pet.equippedOutfitsByName,
                    t: _anim.value * 4,
                    size: 118,
                    mood: _pet.mood,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      s.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _badge('${s.element} · ${s.rarity}'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Lv.${_pet.level} · ${_pet.coins} 书币',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                _bar(
                  '经验',
                  _pet.expRatio,
                  JellyTheme.primary,
                  '${_pet.exp}/${_pet.expToNext}',
                ),
                const SizedBox(height: 5),
                _bar(
                  '饱食',
                  _pet.hunger / 100,
                  const Color(0xFFFFB74D),
                  '${_pet.hunger.round()}',
                ),
                const SizedBox(height: 5),
                _bar(
                  '心情',
                  _pet.mood / 100,
                  const Color(0xFFF06292),
                  '${_pet.mood.round()}',
                ),
                const SizedBox(height: 6),
                Text(
                  _pet.statusLine,
                  style: TextStyle(
                    fontSize: 11,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 自定义桌宠（PNG / GIF）—— 用户 2026-10-18
  Widget _customPetCard() {
    final has =
        _pet.customPetPath.isNotEmpty && File(_pet.customPetPath).existsSync();
    final label = _isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _pet.isCustomPet
              ? JellyTheme.primary.withValues(alpha: 0.45)
              : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: has
                    ? Image.file(File(_pet.customPetPath), fit: BoxFit.cover)
                    : Icon(
                        Icons.add_photo_alternate_outlined,
                        color: JellyTheme.primary,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '自定义桌宠',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: label,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '支持 PNG / GIF，选好后悬浮桌宠立刻换成它',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickCustomPet,
                  icon: Icon(
                    has
                        ? Icons.swap_horiz_rounded
                        : Icons.photo_library_outlined,
                    size: 18,
                  ),
                  label: Text(has ? '更换图片' : '选择图片'),
                ),
              ),
              const SizedBox(width: 10),
              // AI 生成：描述 → 出图 → 自动切为自定义桌宠
              OutlinedButton.icon(
                onPressed: _aiBusy ? null : _aiGeneratePet,
                icon: _aiBusy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 17),
                label: Text(_aiBusy ? '生成中' : 'AI 生成'),
              ),
            ],
          ),
          if (has) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (!_pet.isCustomPet) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pet.setCustomPet(_pet.customPetPath),
                      child: const Text('使用这张'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                OutlinedButton(
                  onPressed: _removeCustomPet,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  child: const Text('移除'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickCustomPet() async {
    try {
      final r = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'gif', 'jpg', 'jpeg', 'webp'],
      );
      final srcPath = r.isEmpty ? null : r.first.path;
      if (srcPath == null) return;
      final src = File(srcPath);
      final ext = srcPath.contains('.')
          ? srcPath.split('.').last.toLowerCase()
          : 'png';
      final dir = await getApplicationSupportDirectory();
      final dst = File(
        '${dir.path}/pet_custom_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await dst.writeAsBytes(await src.readAsBytes());
      final old = _pet.customPetPath;
      await _pet.setCustomPet(dst.path);
      // 换图后删掉旧文件，避免每次换图都留一份垃圾
      if (old.isNotEmpty && old != dst.path) {
        try {
          final f = File(old);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      _toast('已切换为自定义桌宠');
    } catch (e) {
      _toast('选择图片失败：$e');
    }
  }

  Future<void> _removeCustomPet() async {
    await _pet.clearCustomPet();
    _toast('已移除自定义桌宠');
  }

  /// AI 生成可选的画风（用户 2026-10-18：想要更多风格提示词）。
  ///
  /// 全部以「白色背景 + 全身」为约束 —— 生成图会走自动抠图，
  /// 白底最好抠；深色/复杂背景会把整块背景当成宠物保留下来。
  static const List<({String label, String prompt})> _aiStyles = [
    (label: '水墨国风', prompt: '水墨国风插画，粗黑描边，宣纸质感'),
    (label: 'Q版贴纸', prompt: 'Q版贴纸风，圆润可爱，粗描边，扁平矢量'),
    (label: '毛绒玩偶', prompt: '毛绒玩具质感，柔软绒毛，圆滚滚'),
    (label: '黏土手办', prompt: '黏土手办质感，3D 渲染，柔和光影'),
    (label: '像素风', prompt: '16-bit 像素画风，清晰像素颗粒'),
    (label: '日系动漫', prompt: '日系动漫赛璐璐上色，大眼睛，干净线条'),
    (label: '水彩手绘', prompt: '水彩手绘，柔和晕染，纸面质感'),
    (label: '扁平插画', prompt: '扁平化矢量插画，简洁色块，无渐变'),
    (label: '简笔线稿', prompt: '黑白简笔线稿，干净流畅的线条'),
  ];

  String _composeAiPrompt(int styleIndex, String extra) {
    final style = _aiStyles[styleIndex.clamp(0, _aiStyles.length - 1)];
    final tail = extra.trim().isEmpty ? '' : '，${extra.trim()}';
    return '一只${_pet.species.name}，${style.prompt}$tail，'
        '白色背景，全身，居中构图，无文字，无边框';
  }

  /// AI 生成桌宠：选画风 + 补充描述 → 调生成接口 → 保存并切换为自定义皮肤。
  ///
  /// 生成图通常是白底 —— 自定义静态图会走 [CustomPetImage] 的
  /// 「去白底 + 裁到本体」处理，所以生成出来就是一只干净的贴纸宠物。
  Future<void> _aiGeneratePet() async {
    final extraCtrl = TextEditingController(text: '圆滚滚，表情傲娇');
    var styleIndex = 0;
    final label = _isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final prompt = _composeAiPrompt(styleIndex, extraCtrl.text);
          return AlertDialog(
            backgroundColor: _card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: Text(
              'AI 生成桌宠',
              style: TextStyle(
                color: label,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '画风',
                    style: TextStyle(
                      color: JellyTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _aiStyles.length; i++)
                        ChoiceChip(
                          label: Text(_aiStyles[i].label),
                          selected: styleIndex == i,
                          onSelected: (_) => setLocal(() => styleIndex = i),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            color: styleIndex == i
                                ? (_isDark
                                      ? Colors.white
                                      : JellyTheme.primaryDark)
                                : JellyTheme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '补充描述（可选）',
                    style: TextStyle(
                      color: JellyTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: extraCtrl,
                    onChanged: (_) => setLocal(() {}),
                    maxLines: 2,
                    minLines: 1,
                    style: TextStyle(color: label, fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: '如：圆滚滚、躺着、戴围巾、粉色调',
                      hintStyle: TextStyle(
                        color: JellyTheme.textSecondary,
                        fontSize: 12.5,
                      ),
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '生成提示词：$prompt',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 10.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('生成'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    final prompt = _composeAiPrompt(styleIndex, extraCtrl.text);
    setState(() => _aiBusy = true);
    try {
      final url =
          'https://trae-api-cn.mchost.guru/api/ide/v1/text_to_image'
          '?prompt=${Uri.encodeComponent(prompt)}&image_size=square_hd';
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 120),
          responseType: ResponseType.bytes,
          validateStatus: (c) => c != null && c < 400,
        ),
      );
      applyGlobalProxy(dio);
      final res = await dio.get<List<int>>(url);
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('生成接口返回为空');
      }
      final dir = await getApplicationSupportDirectory();
      final dst = File(
        '${dir.path}/pet_ai_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await dst.writeAsBytes(bytes, flush: true);
      final old = _pet.customPetPath;
      await _pet.setCustomPet(dst.path);
      if (old.isNotEmpty && old != dst.path) {
        try {
          final f = File(old);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      _toast('已用 AI 生成并切换桌宠');
    } catch (e) {
      _toast('AI 生成失败：$e');
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Widget _actionsCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await _pet.feed();
                _toast(ok ? '喂食成功：饱食 +30、经验 +20' : '书币不够（需要 10）');
              },
              icon: const Icon(Icons.restaurant_rounded, size: 18),
              label: const Text('喂食 10 币'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await _pet.play();
                _toast(ok ? '摸摸头：心情 +12' : '它刚玩过，歇一会儿吧');
              },
              icon: const Icon(Icons.favorite_rounded, size: 18),
              label: const Text('摸摸'),
            ),
          ),
          const SizedBox(width: 6),
          Switch(
            value: _pet.enabled,
            onChanged: _pet.setEnabled,
          ),
        ],
      ),
    );
  }

  /// QQ秀式衣橱：按部位分组（头饰 / 面部 / 颈部 / 上衣 / 手持 / 背景），
  /// 每个部位横向排「不戴 + 该部位的所有单品」。
  Widget _outfits() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final slot in PetOutfitSlot.values) _outfitSlotRow(slot),
      ],
    );
  }

  Widget _outfitSlotRow(PetOutfitSlot slot) {
    final current = _pet.equippedSlots[slot];
    final items = PetOutfits.forSlot(slot);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                slot.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                current == null
                    ? '未穿戴'
                    : (PetOutfits.byId(current)?.name ?? ''),
                style: TextStyle(
                  fontSize: 10.5,
                  color: JellyTheme.textSecondary,
                ),
              ),
              const Spacer(),
              if (current != null)
                GestureDetector(
                  onTap: () => _pet.clearOutfitSlot(slot),
                  child: Text(
                    '摘下',
                    style: TextStyle(
                      fontSize: 11,
                      color: JellyTheme.textSecondary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return _outfitChip(slot: slot, item: null);
                }
                return _outfitChip(slot: slot, item: items[i - 1]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _outfitChip({required PetOutfitSlot slot, PetOutfitInfo? item}) {
    final current = _pet.equippedSlots[slot];
    final selected = item == null ? current == null : current == item.id;
    final owned = item == null || _pet.ownsOutfit(item);
    final label = item?.name ?? '不戴';
    // 自定义图片没有矢量头/身体坐标 ⇒ 用 QQ 小人做换装预览，
    // 否则会拿「自定义」这个非 QQ 物种去画，落回旧的动物团子。
    final previewSpecies = _pet.isCustomPet ? PetSpecies.qqBoy : _pet.species;
    return GestureDetector(
      onTap: () async {
        if (item == null) {
          await _pet.clearOutfitSlot(slot);
          return;
        }
        final ok = await _pet.buyOutfit(item);
        if (!ok) {
          _toast('需要 Lv.${item.unlockLevel} / ${item.price} 书币');
        }
      },
      child: Container(
        width: 78,
        padding: const EdgeInsets.fromLTRB(5, 6, 5, 6),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? JellyTheme.primary : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 46,
              child: item == null
                  ? Center(
                      child: Icon(
                        Icons.block_rounded,
                        size: 22,
                        color: JellyTheme.textSecondary,
                      ),
                    )
                  : PetView(
                      species: previewSpecies,
                      outfit: PetOutfits.none.id,
                      // 只预览这一件，方便看清单品本身
                      outfits: {slot.name: item.id},
                      t: 0.6,
                      size: 46,
                      mood: 80,
                      // 图片宠物没有矢量头，直接显示全身（能看到配饰戴上的效果）
                      headOnly:
                          previewSpecies.imageAsset == null &&
                          (slot == PetOutfitSlot.hat ||
                              slot == PetOutfitSlot.face),
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
            Text(
              owned ? (selected ? '已穿戴' : '点击穿戴') : '${item.price} 币',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                color: JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _collection() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: PetSpecies.pets.length,
      itemBuilder: (context, i) {
        final s = PetSpecies.pets[i];
        final unlocked = _pet.unlockedSpecies.contains(s.id);
        final current = _pet.speciesId == s.id;
        return GestureDetector(
          onTap: () => _onSpeciesTap(s, unlocked),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: current ? JellyTheme.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    PetView(
                      species: s,
                      outfit: unlocked
                          ? _pet.equippedOutfit
                          : PetOutfits.none.id,
                      outfits: unlocked ? _pet.equippedOutfitsByName : const {},
                      t: 0.8,
                      size: 74,
                      mood: unlocked ? 80 : 20,
                    ),
                    if (!unlocked)
                      Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.lock_rounded,
                          color: Colors.white70,
                          size: 22,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                Text(
                  unlocked
                      ? (current ? '使用中' : s.rarity)
                      : 'Lv.${s.unlockLevel} · ${s.price} 币',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: unlocked && current
                        ? JellyTheme.primary
                        : JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onSpeciesTap(PetSpeciesInfo s, bool unlocked) async {
    if (unlocked) {
      await _pet.setSpecies(s);
      _toast('已切换为「${s.name}」');
      return;
    }
    if (_pet.level < s.unlockLevel) {
      _toast('需要 Lv.${s.unlockLevel} 才能解锁');
      return;
    }
    if (_pet.coins < s.price) {
      _toast('书币不足：需要 ${s.price}，当前 ${_pet.coins}');
      return;
    }
    // 免费宠物（小Q / 小秀）直接解锁，不用弹「消耗 0 书币」的框
    if (s.price > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('解锁「${s.name}」？'),
          content: Text('${s.description}\n\n将消耗 ${s.price} 书币。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('解锁'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final done = await _pet.unlockSpecies(s);
    if (!done) {
      _toast('解锁失败');
      return;
    }
    await _pet.setSpecies(s);
    _toast('已解锁并切换为「${s.name}」');
  }

  Widget _bar(String label, double ratio, Color color, String value) {
    return Row(
      children: [
        SizedBox(
          width: 26,
          child: Text(
            label,
            style: TextStyle(fontSize: 10, color: JellyTheme.textSecondary),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: JellyTheme.textSecondary.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 9.5, color: JellyTheme.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: JellyTheme.primary,
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: JellyTheme.textSecondary,
      ),
    ),
  );

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}
