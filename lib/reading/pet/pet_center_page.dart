import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../common/theme.dart';
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
        builder: (context, _) => ListView(
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
            _sectionTitle('图鉴（${_pet.unlockedSpecies.length}/${PetSpecies.all.length}）'),
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
        ),
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
            builder: (context, _) => _pet.isCustomPet &&
                    _pet.customPetPath.isNotEmpty
                ? CustomPetImage(
                    path: _pet.customPetPath,
                    size: 118,
                    bob: 0,
                  )
                : PetView(
                    species: s,
                    outfit: _pet.equippedOutfit,
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
                        color:
                            _isDark ? Colors.white : JellyTheme.textPrimaryLight,
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
                _bar('经验', _pet.expRatio, JellyTheme.primary,
                    '${_pet.exp}/${_pet.expToNext}'),
                const SizedBox(height: 5),
                _bar('饱食', _pet.hunger / 100, const Color(0xFFFFB74D),
                    '${_pet.hunger.round()}'),
                const SizedBox(height: 5),
                _bar('心情', _pet.mood / 100, const Color(0xFFF06292),
                    '${_pet.mood.round()}'),
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
    final has = _pet.customPetPath.isNotEmpty &&
        File(_pet.customPetPath).existsSync();
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
                    : Icon(Icons.add_photo_alternate_outlined,
                        color: JellyTheme.primary),
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
                    has ? Icons.swap_horiz_rounded : Icons.photo_library_outlined,
                    size: 18,
                  ),
                  label: Text(has ? '更换图片' : '选择图片'),
                ),
              ),
              if (has) ...[
                if (!_pet.isCustomPet) ...[
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () =>
                        _pet.setCustomPet(_pet.customPetPath),
                    child: const Text('使用'),
                  ),
                ],
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _removeCustomPet,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  child: const Text('移除'),
                ),
              ],
            ],
          ),
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
      final srcPath =
          (r == null || r.isEmpty) ? null : r.first.path;
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
            onChanged: (v) => _pet.setEnabled(v),
          ),
        ],
      ),
    );
  }

  Widget _outfits() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final o in PetOutfits.all)
          GestureDetector(
            onTap: () async {
              final ok = await _pet.buyOutfit(o);
              if (!ok) {
                _toast('需要 Lv.${o.unlockLevel} / ${o.price} 书币');
              }
            },
            child: Container(
              width: 104,
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _pet.equippedOutfit == o.id
                      ? JellyTheme.primary
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _anim,
                    builder: (context, _) => PetView(
                      species: _pet.species,
                      outfit: o.id,
                      t: _anim.value * 4,
                      size: 68,
                      mood: _pet.mood,
                    ),
                  ),
                  Text(
                    o.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  Text(
                    _pet.ownsOutfit(o)
                        ? (_pet.equippedOutfit == o.id ? '已穿戴' : '点击穿戴')
                        : 'Lv.${o.unlockLevel} · ${o.price} 币',
                    style: TextStyle(
                      fontSize: 10,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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
      itemCount: PetSpecies.all.length,
      itemBuilder: (context, i) {
        final s = PetSpecies.all[i];
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
                      outfit: unlocked ? _pet.equippedOutfit : PetOutfits.none.id,
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
                        child: const Icon(Icons.lock_rounded,
                            color: Colors.white70, size: 22),
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
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }
}
