part of '../book_source_reader_page.dart';

mixin _ReaderPart07 on _BookSourceReaderPageState {
@override
  /// 阅读设置面板（截图 IMG_71a10）。
  ///
  /// ── 与旧面板的区别 ────────────────────────────────────────────
  /// 旧面板只有"字号 + 行距"两根滑杆。截图里这一整页是**8 组设置**：
  ///   阅读模式 / 翻页反转 / 单手模式 / 点击区域 / 双页模式 /
  ///   信息栏（6 项可逐项开关）/ 音量键翻页 / 屏幕休眠
  /// 底部：取消 · 排版 · 确认
  ///
  /// 其中"阅读模式"是真的会影响渲染的（见 _contentArea）：
  /// 上下 = 不分页改滚动；其余 4 种 = 分页。
  Widget _settingsPanel(Color fg, {double extraBottom = 0}) {
    return Positioned(
      // 面板已在 SafeArea 之外（见 build 末尾）⇒ 这里 bottom:0 就是屏幕最底部 ✓
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
        decoration: BoxDecoration(
          color: _sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          // 兜底：padding 报 0 时也要给 Home 指示条留出位置（见 build 里的说明）
          minimum: EdgeInsets.only(bottom: extraBottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(),
              // 标题：阅读设置 + 独立设置
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 16, 10),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '阅读设置',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: _fg,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '翻页 · 信息栏 · 文本',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.2,
                            color: _fg.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '独立设置',
                      style: TextStyle(
                        fontSize: 12,
                        color: _fgMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // ✅ 三处「独立设置 / 独立排版」共用同一个 `_independent` ✓，均已接线：
                    //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录，`_restorePrefs` 读回 ✓。
                    SizedBox(
                      width: 46,
                      height: 30,
                      child: FittedBox(
                        child: Switch(
                          value: _independent,
                          activeThumbColor: _bgTop,
                          activeTrackColor: _fg.withValues(alpha: 0.85),
                          inactiveThumbColor: _bgTop,
                          inactiveTrackColor: _fg.withValues(alpha: 0.16),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (v) => _setIndependent(v),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 标题与内容之间的分隔线（滚动时不会和标题糊在一起）
              Divider(
                height: 1,
                thickness: 0.5,
                color: _fg.withValues(alpha: 0.08),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  children: [
                    // ── 阅读模式（5 种）────────────────────────
                    _sectionLabel('翻页'),
                    // 阅读模式：标签在左、5 个模式块在右（同一行，截图如此）。
                    // 用户 2026-10-15：纯文字 chip 辨识度差 ⇒ 换成
                    // 「图标 + 名称」的等宽小块（JellyModePicker）。
                    _setRowRight(
                      '阅读模式',
                      JellyModePicker(
                        fg: _fg,
                        // 用户 2026-10-21：模式按钮上不要那个符号/图标，只留文字
                        showSymbol: false,
                        items: [
                          for (final m in PageMode.values)
                            JellyModeItem(
                              label: m.label,
                              symbol: pageModeSymbol(m),
                              selected: _rs.pageMode == m,
                              onTap: () {
                                setState(() => _rs = _rs.copyWith(pageMode: m));
                                _scheduleSavePrefs();
                                // 模式变了要重新分页（上下模式不分页）
                                _paginate();
                              },
                            ),
                        ],
                      ),
                    ),
                    // ── 自动阅读（对齐 Legado：按间隔自动翻页/滚屏）────
                    _setRowRight(
                      '自动阅读',
                      _chip(
                        _autoReadOn ? '停止' : '开始',
                        _autoReadOn,
                        () {
                          _toggleAutoRead();
                        },
                        compact: true,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 82,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '翻页间隔',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _fg,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final s in const [3, 5, 8, 12, 20, 30])
                                  _chip(
                                    '$s 秒',
                                    _rs.autoReadIntervalSec == s,
                                    () {
                                      setState(
                                        () => _rs = _rs.copyWith(
                                          autoReadIntervalSec: s,
                                        ),
                                      );
                                      _scheduleSavePrefs();
                                      if (_autoReadOn) {
                                        _scheduleAutoRead();
                                      }
                                    },
                                    compact: true,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── 预取与缓存（对齐 Legado：预下载 N 章 + 仅 WiFi）──
                    _setRowRight(
                      '预取章节',
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final n in const [0, 1, 2, 3, 5])
                            _chip(
                              '$n 章',
                              _rs.preloadChapters == n,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(preloadChapters: n),
                                );
                                _scheduleSavePrefs();
                                // 立刻按新设置补预取，不用等翻章
                                if (n > 0) _prefetchAhead(_index);
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                    _setRowRight(
                      '仅 WiFi 预取',
                      Switch.adaptive(
                        value: _rs.preloadWifiOnly,
                        onChanged: (v) {
                          setState(
                            () => _rs = _rs.copyWith(preloadWifiOnly: v),
                          );
                          _scheduleSavePrefs();
                        },
                      ),
                    ),
                    _setRowRight(
                      '章节缓存',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_cache.length} 章',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _fg.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _chip('清空', false, _clearChapterCache, compact: true),
                        ],
                      ),
                    ),
                    // ── 正文替换（对齐参考图：已启用 N 条规则 + 管理）──
                    _setRowRight(
                      '正文替换',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '已启用 '
                            '${_rs.purifyRules.where((r) => r.enabled).length}'
                            ' 条规则',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _fg.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _chip('管理', false, _showPurifySheet, compact: true),
                        ],
                      ),
                    ),
                    // 点击区域：进入 3×3 编辑页（截图 IMG_8117）
                    InkWell(
                      onTap: _showTapZoneEditor,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Text(
                              '点击区域',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: _fg,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '自定义各区域触发上一页/菜单/下一页',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: _fg.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.grid_view_rounded,
                              size: 20,
                              color: _fgMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── 简繁转换（位置对齐参考图：紧跟在点击区域之后）──
                    _setRowRight(
                      '简繁转换',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final cm in ChineseConvertMode.values)
                            _chip(_convertLabel(cm), _rs.convertMode == cm, () {
                              setState(
                                () => _rs = _rs.copyWith(convertMode: cm),
                              );
                              _scheduleSavePrefs();
                              _invalidateTtsSegs();
                              // 从**原文缓存**重转（不改缓存），保留锚点重排 ✓
                              if (_cache.containsKey(_index)) {
                                _paragraphs = _applyConvert(_cache[_index]!);
                              }
                              _repaginateLayout();
                            }, compact: true),
                        ],
                      ),
                    ),
                    // ── 屏幕休眠（对齐参考图：简繁转换之后）────────
                    _setRowRight(
                      '屏幕休眠',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final s in SleepMode.values)
                            _chip(s.label, _rs.sleepMode == s, () {
                              setState(() => _rs = _rs.copyWith(sleepMode: s));
                              _scheduleSavePrefs();
                              _applySleepMode();
                            }, compact: true),
                        ],
                      ),
                    ),
                    _setSwitch('翻页反转', '左点下一页、右点上一页', _rs.flipReverse, (v) {
                      setState(() => _rs = _rs.copyWith(flipReverse: v));
                      _scheduleSavePrefs();
                    }),
                    _setSwitch('单手模式', '屏幕左右点击都是下一页', _rs.oneHand, (v) {
                      setState(() => _rs = _rs.copyWith(oneHand: v));
                      _scheduleSavePrefs();
                    }),
                    // 查看插图（对齐参考图）：正文末展示本章插图，点开可放大
                    _setSwitch(
                      '查看插图',
                      '在正文末尾展示本章插图，点击放大查看',
                      _rs.showIllustrations,
                      (v) {
                        setState(
                          () => _rs = _rs.copyWith(showIllustrations: v),
                        );
                        _scheduleSavePrefs();
                        _repaginateLayout();
                      },
                    ),
                    _setSwitch('双页模式', '横屏左右并排（上下模式除外）', _rs.dualPage, (v) {
                      setState(() => _rs = _rs.copyWith(dualPage: v));
                      _scheduleSavePrefs();
                    }),
                    // ── 信息栏（6 项逐项开关）──────────────────
                    _sectionLabel('信息栏'),
                    // 说明当前信息栏由谁驱动：样式套用时会带上它自己的页眉页脚
                    // 格式串（渲染优先），不说明的话用户会以为这里的开关坏了。
                    if (_hasHeaderFormat || _hasFooterFormat)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '当前页眉页脚用的是「样式自带」的格式；'
                          '动一下下面的开关就切回你在这里的选择。',
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: _fgMuted,
                            height: 1.5,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 6),
                      child: Row(
                        children: [
                          Text(
                            '信息栏',
                            style: TextStyle(
                              fontSize: AppTheme.fontHeadline,
                              color: _fg,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '页眉页脚显示的信息，可逐项开关',
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: _fgMuted,
                              ),
                            ),
                          ),
                          // 总开关：一键显示/隐藏整条信息栏（全不选 = 隐藏）
                          Switch(
                            value: _rs.statusItems.isNotEmpty,
                            onChanged: (v) {
                              setState(() {
                                _rs = _rs.copyWith(
                                  statusItems: v
                                      ? const {'章节', '页码', '进度'}
                                      : <String>{},
                                );
                                // 用户的开关要能覆盖样式自带的那套格式串
                                _clearHeaderFooterFormats();
                              });
                              _scheduleSavePrefs();
                              _repaginateLayout();
                            },
                          ),
                        ],
                      ),
                    ),
                    // 信息栏选项：**横向滑动**（用户 2026-10-21 参考图）
                    // 一行放不下时左右滑，而不是换行把面板撑高 ✓
                    SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: _BookSourceReaderPageState._statusItemKeys.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (c, i) {
                          final k = _BookSourceReaderPageState._statusItemKeys[i];
                          return Center(
                            child: _chip(k, _rs.statusItems.contains(k), () {
                              final next = Set<String>.of(_rs.statusItems);
                              if (!next.remove(k)) next.add(k);
                              setState(() {
                                _rs = _rs.copyWith(statusItems: next);
                                _clearHeaderFooterFormats();
                              });
                              _scheduleSavePrefs();
                            }),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 信息栏字号/图标缩放（用户 2026-10-21）
                    _setRowRight(
                      '信息栏字号',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final e in const [
                            ('小', 0.85),
                            ('标准', 1.0),
                            ('大', 1.15),
                            ('超大', 1.3),
                          ])
                            _chip(
                              e.$1,
                              (_rs.statusTextScale - e.$2).abs() < 0.01,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(
                                    statusTextScale: e.$2,
                                  ),
                                );
                                _scheduleSavePrefs();
                                // 页脚高了/矮了 ⇒ 正文可用高度变了，要重排
                                _repaginateLayout();
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                    // 隐藏系统状态栏（沉浸全屏，用户 2026-10-21）
                    _setSwitch(
                      '隐藏状态栏',
                      '阅读时全屏，不显示手机顶部状态栏',
                      _rs.hideStatusBar,
                      (v) {
                        setState(() => _rs = _rs.copyWith(hideStatusBar: v));
                        _scheduleSavePrefs();
                        _applyReaderSystemUi();
                      },
                    ),
                    const SizedBox(height: 8),
                    _sectionLabel('其他'),
                    _setSwitch('音量键翻页', '按音量上/下键翻页（会接管音量键）', _rs.volumeKeys, (
                      v,
                    ) {
                      setState(() => _rs = _rs.copyWith(volumeKeys: v));
                      _scheduleSavePrefs();
                    }),
                    // ── A1 对话气泡（Cmbok 差距文档）────────────
                    _setRowRight(
                      '对话气泡',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final bm in BubbleMode.values)
                            _chip(bm.label, _rs.bubbleMode == bm, () {
                              setState(
                                () => _rs = _rs.copyWith(bubbleMode: bm),
                              );
                              _scheduleSavePrefs();
                              // 🔴 必须重排：气泡把对话段落**变窄 ⇒ 折行更多、更高** ✗
                              //    ⇒ 沿用旧分页会立刻溢出屏幕 ✗（用户实测的
                              //    "弄成对话气泡后容易出整个屏幕" 一半来自这里 ✓）
                              _repaginateLayout();
                            }, compact: true),
                        ],
                      ),
                    ),
                    if (_rs.bubbleMode != BubbleMode.none)
                      _setRowRight(
                        '气泡配色',
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final bp in BubblePalette.values)
                              _chip(bp.label, _rs.bubblePalette == bp, () {
                                setState(
                                  () => _rs = _rs.copyWith(bubblePalette: bp),
                                );
                                _scheduleSavePrefs();
                              }, compact: true),
                          ],
                        ),
                      ),
                    // 选了「自定义」→ 给两个取色入口（底色 / 文字色）。
                    // 颜色**不改变布局** ⇒ 不需要重排 ✓
                    if (_rs.bubbleMode != BubbleMode.none &&
                        _rs.bubblePalette == BubblePalette.custom)
                      _setRowRight(
                        '气泡颜色',
                        Wrap(
                          spacing: 8,
                          children: [
                            _bubbleColorChip('底色', _customBubbleBg, (c) {
                              setState(
                                () => _rs = _rs.copyWith(
                                  bubbleBgColor: c.toARGB32(),
                                ),
                              );
                              _scheduleSavePrefs();
                            }),
                            _bubbleColorChip('文字', _customBubbleText, (c) {
                              setState(
                                () => _rs = _rs.copyWith(
                                  bubbleTextColor: c.toARGB32(),
                                ),
                              );
                              _scheduleSavePrefs();
                            }),
                          ],
                        ),
                      ),
                    // ── A3 背景壁纸（点开 14 张内置壁纸 + 无壁纸）──
                    InkWell(
                      onTap: _showBgImageSheet,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _bgImageAsset == null ? '背景壁纸' : '背景壁纸',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: _fg,
                                ),
                              ),
                            ),
                            Text(
                              _bgImageAsset == null
                                  ? '纯色底'
                                  : (_bgImageDark ?? false
                                        ? '壁纸 · 浅字'
                                        : '壁纸 · 深字'),
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: _fgMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.image_outlined,
                              size: 18,
                              color: _fgMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── C7 护眼休息提醒（关 / 30 / 45 / 60 分钟）──
                    _setRowRight(
                      '护眼提醒',
                      Wrap(
                        spacing: 6,
                        children: [
                          _chip('关', !_rs.eyeBreakEnabled, () {
                            setState(
                              () => _rs = _rs.copyWith(eyeBreakEnabled: false),
                            );
                            _scheduleSavePrefs();
                            _eyeBreakStart = DateTime.now();
                            _eyeBreakShown = false;
                          }, compact: true),
                          for (final m in [30, 45, 60])
                            _chip(
                              '${m}分钟',
                              _rs.eyeBreakEnabled && _rs.eyeBreakMinutes == m,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(
                                    eyeBreakEnabled: true,
                                    eyeBreakMinutes: m,
                                  ),
                                );
                                _scheduleSavePrefs();
                                _eyeBreakStart = DateTime.now();
                                _eyeBreakShown = false;
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // ⚠️ 底栏（取消 / 排版 / 确认）已按用户要求**整条去掉** ——
              //   面板里的选项点了就即时生效，不需要再确认 ✓
            ],
          ),
        ),
      ),
    );
  }

@override
  /// 一行"标签在左、控件在右"（截图里 阅读模式 / 屏幕休眠 就是这样）。
  ///
  /// ⚠️ 我一开始对这两行用错了 [_setRow]（上下布局）——
  /// 截图里标签和按钮是**同一行**的。
  Widget _setRowRight(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: _fg,
              ),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: child),
          ),
        ],
      ),
    );
  }

@override
  Widget _setSwitch(
    String label,
    String sub,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: _fg.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 统一开关的配色与紧凑度（原来默认蓝色 + 48dp 触控区，视觉太抢）
          SizedBox(
            width: 46,
            height: 30,
            child: FittedBox(
              child: Switch(
                value: value,
                activeThumbColor: _bgTop,
                activeTrackColor: _fg.withValues(alpha: 0.85),
                inactiveThumbColor: _bgTop,
                inactiveTrackColor: _fg.withValues(alpha: 0.16),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

@override
  /// 自定义气泡颜色入口：色块 + 名称，点开 HSV 取色器。
  /// （改色**不影响排版** ⇒ 不需要 `_repaginateLayout()` ✓）
  Widget _bubbleColorChip(
    String label,
    Color color,
    ValueChanged<Color> onPicked,
  ) {
    return GestureDetector(
      onTap: () async {
        final picked = await ColorPickerDialog.show(
          context,
          initial: color,
          title: '气泡$label',
        );
        if (picked == null || !mounted) return;
        onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: _fg.withValues(alpha: 0.25)),
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, color: _fg)),
          ],
        ),
      ),
    );
  }

@override
  Widget _chip(
    String label,
    bool on,
    VoidCallback onTap, {
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 8 : 9,
        ),
        decoration: BoxDecoration(
          // 选中：实底；未选中：淡底 + 细描边（原来只有淡底，跟背景糊在一起 ✗）
          color: on ? _fg.withValues(alpha: 0.88) : _fg.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: on ? Colors.transparent : _fg.withValues(alpha: 0.10),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 13 : 13.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
            color: on ? _bgTop : _fg.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }

@override
  /// 设置面板里的小节标题（把一长串行分组，便于扫读）
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: _fg.withValues(alpha: 0.45),
        ),
      ),
    );
  }

@override
  /// 点击区域编辑器（截图 IMG_8117）：
  ///   顶部黑条提示「点击屏幕上的区域，在弹层中选择该区域的动作」
  ///   中间 3×3 网格，白色分界线
  ///   底部：恢复默认 · 完成
  Future<void> _showTapZoneEditor() async {
    var zones = Map<int, TapAction>.of(
      _rs.tapZones.isEmpty ? ReadingSettings.defaultZones() : _rs.tapZones,
    );
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              // 3×3 网格（带白色分界线）
              Positioned.fill(
                child: Column(
                  children: [
                    for (var row = 0; row < 3; row++)
                      Expanded(
                        child: Row(
                          children: [
                            for (var col = 0; col < 3; col++)
                              Expanded(
                                child: GestureDetector(
                                  onTap: () async {
                                    final z = row * 3 + col;
                                    final a =
                                        await showModalBottomSheet<TapAction>(
                                          context: ctx,
                                          backgroundColor: Colors.transparent,
                                          builder: (c) => Container(
                                            decoration: BoxDecoration(
                                              color: _bgTop,
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    top: Radius.circular(22),
                                                  ),
                                            ),
                                            child: SafeArea(
                                              top: false,
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  for (final a
                                                      in TapAction.values)
                                                    ListTile(
                                                      title: Text(
                                                        a.label,
                                                        style: TextStyle(
                                                          fontSize: AppTheme
                                                              .fontHeadline,
                                                          color: _fg,
                                                        ),
                                                      ),
                                                      trailing: zones[z] == a
                                                          ? Icon(
                                                              Icons
                                                                  .check_rounded,
                                                              size: 20,
                                                              color: _fg,
                                                            )
                                                          : null,
                                                      onTap: () =>
                                                          Navigator.pop(c, a),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                    if (a != null) {
                                      setDlg(() => zones[z] = a);
                                    }
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.5,
                                        ),
                                        width: 1,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      (zones[row * 3 + col] ?? TapAction.none)
                                          .label,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontHeadline,
                                        color: _fg,
                                        shadows: const [
                                          Shadow(
                                            color: Colors.black26,
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // 顶部黑条提示
              Positioned(
                top: MediaQuery.of(ctx).padding.top + 8,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '点击屏幕上的区域，在弹层中选择该区域的动作',
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 底部：恢复默认 · 完成
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _zoneBtn('恢复默认', () {
                      setDlg(() => zones = ReadingSettings.defaultZones());
                    }),
                    _zoneBtn('完成', () {
                      setState(
                        () => _rs = _rs.copyWith(tapZones: Map.of(zones)),
                      );
                      _scheduleSavePrefs();
                      Navigator.pop(ctx);
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

@override
  Widget _zoneBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: AppTheme.fontHeadline,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

@override
  /// 目录右侧「到顶 / 到底」竖条里的一个按钮
  Widget _tocJumpBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 32,
          height: 34,
          child: Icon(
            icon,
            size: 20,
            color: _fg.withValues(alpha: 0.72),
          ),
        ),
      ),
    );
  }

@override
  /// 目录抽屉（截图 IMG_8077）。
  ///
  /// ── 三个 tab ──────────────────────────────────────────────────
  ///   目录  ：章数 + 搜索章节 + 排序 + 章节列表（已缓存的显示 ☁ 标记）
  ///   书签  ：本书的书签（按颜色）
  ///   笔记  ：划线/批注（入口，交互未做）
  /// 右侧还有 ↑↓ 快速拖动条。
  Future<void> _showToc({int initialTab = 0}) async {
    var tab = initialTab;
    // 三个 tab 各自的搜索词/controller 独立，避免切 tab 时词残留
    final ctrlToc = TextEditingController();
    final ctrlBm = TextEditingController();
    final ctrlNote = TextEditingController();
    var kwToc = '';
    var kwBm = '';
    var kwNote = '';
    var asc = true;
    Color? filterColor; // 书签/笔记颜色筛选（null = 全部）
    const tabNames = ['目录', '书签', '笔记'];
    // 目录 tab 右缘快速拖动定位（Cmbok 同款）：拖动只滚动列表不跳转 ✓，
    // 拖动时浮现章节标题提示 ✓，搜索状态不可用 ✓。
    // 定位/滚动改用漫画阅读器同款 ScrollablePositionedList ✓：
    // jumpTo(index:) 按条目下标精确跳，不再估行高 ✓。
    final itemScrollController = ItemScrollController();
    final itemPositionsListener = ItemPositionsListener.create();
    var showDragTip = false;
    var dragTipName = '';
    var dragTipY = 0.0;
    var didAutoScrollToc = false;
    // 滚动时浮现「到顶 / 到底」竖条：滚动开始显示、静止 900ms 后淡出
    var tocScrolling = false;
    Timer? tocHideTimer;

    // 和漫画阅读器一致：目录 / 书签 / 笔记从**右侧滑入**（不是底部弹层）。
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.78;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, anim, secondary) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: drawerWidth,
            height: double.infinity,
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(22),
                bottomLeft: Radius.circular(22),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 26,
                  offset: const Offset(-4, 0),
                ),
              ],
            ),
            child: SafeArea(
              child: StatefulBuilder(
                builder: (ctx, setSheet) {
          final chapters = <int>[
            for (var i = 0; i < widget.chapters.length; i++)
              if (kwToc.isEmpty || widget.chapters[i].name.contains(kwToc)) i,
          ];
          if (!asc) {
            final rev = chapters.reversed.toList();
            chapters
              ..clear()
              ..addAll(rev);
          }
          // 首次打开：定位到「当前章」（漫画阅读器同款 ✓）。
          //   · jumpTo(index:) 按条目下标精确跳，100% 命中 ✓；
          //   · ⚠️ 只跳一次（didAutoScrollToc）—— 搜索/切排序重建列表时
          //     不重新定位，否则会边打字边乱滚 ✓；
          //   · 必须等首帧（列表 attach 后）再跳 ✓。
          if (!didAutoScrollToc) {
            didAutoScrollToc = true;
            final cur = chapters.indexOf(_index);
            if (cur > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (itemScrollController.isAttached) {
                  itemScrollController.jumpTo(index: cur);
                }
              });
            }
          }
          // 右缘拖动 → 按比例换算成章节下标精确跳 ✓
          //（比旧版按偏移比例滚动更准：目标章一定贴在列表顶部），并记录提示章节名
          void dragTocTo(double localY, double stripH) {
            if (chapters.isEmpty) return;
            final ratio = (localY / stripH).clamp(0.0, 1.0);
            final idx = (ratio * (chapters.length - 1)).round();
            if (itemScrollController.isAttached) {
              itemScrollController.jumpTo(index: idx);
            }
            dragTipName = widget.chapters[chapters[idx]].name;
            dragTipY = localY;
          }

          return Column(
            mainAxisSize: MainAxisSize.max,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final e in [
                        ('目录', '${widget.chapters.length} 章'),
                        ('书签', '${_bookmarks.length} 条'),
                        (
                          '笔记',
                          '${ReaderNotesService.instance.forBook(widget.source.id, widget.bookName).length} 条',
                        ),
                      ])
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setSheet(() => tab = tabNames.indexOf(e.$1)),
                            child: Column(
                              children: [
                                Text(
                                  e.$1,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontHeadline,
                                    fontWeight: tab == tabNames.indexOf(e.$1)
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                    color: tab == tabNames.indexOf(e.$1)
                                        ? _fg
                                        : _fgMuted,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  e.$2,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  height: 2,
                                  width: 26,
                                  color: tab == tabNames.indexOf(e.$1)
                                      ? _fg
                                      : Colors.transparent,
                                ),
                              ],
                            ),
                          ),
                        ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 22,
                          color: _fgMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (tab == 0) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              // ✅ **统一成 B 规格** ✓ —— 本页最后 1 处 ✓。
                              //   ⚠️ 原本同一页里有 **三套规格** ✗：
                              //     40/prefixIcon19/约束38 · **38/prefixIcon18/约束36（这里）** · 34/前置Icon16 ✓
                              //   → 统一后**四框一致** ✓（底色本来就相同 ✓，只改尺寸与图标位置 ✓）
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: _fgMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrlToc,
                                      // ⚠️ **`setSheet` 必须照抄** ✗ —— 这是弹层自己的刷新函数 ✓，
                                      //   误写成 `setState` 会导致**输入不生效** ✗✗
                                      onChanged: (v) =>
                                          setSheet(() => kwToc = v.trim()),
                                      // ⚠️ **不要加 `autofocus`** ✗ —— 章节列表弹层
                                      //   一打开就弹键盘会很难用 ✓（现状没有 ✓，保持 ✓）
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fg,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '搜索章节',
                                        hintStyle: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fgMuted,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 排序：改成上下双箭头（参考 Cmbok 的 t↓ 样式），
                          // 不再用单向上/下箭头 —— 单箭头看着像"跳到顶/底" ✗
                          IconButton(
                            tooltip: asc ? '正序（点击切倒序）' : '倒序（点击切正序）',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              size: 20,
                              color: _fg.withValues(alpha: asc ? 0.9 : 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: Stack(
                        children: [
                          NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              // 一滚动就让「到顶/到底」竖条浮现，静止后淡出
                              if (!tocScrolling) {
                                setSheet(() => tocScrolling = true);
                              }
                              tocHideTimer?.cancel();
                              tocHideTimer = Timer(
                                const Duration(milliseconds: 900),
                                () {
                                  if (ctx.mounted) {
                                    setSheet(() => tocScrolling = false);
                                  }
                                },
                              );
                              return false;
                            },
                            child: ScrollConfiguration(
                            // 关掉系统滚动条：目录动辄上千章，原生 thumb 会拉成
                            // 一条很长的灰条压在云朵图标上（用户反馈"太长"）✗
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: ScrollablePositionedList.builder(
                            itemScrollController: itemScrollController,
                            itemPositionsListener: itemPositionsListener,
                            itemCount: chapters.length,
                            itemBuilder: (c, i) {
                              final ci = chapters[i];
                              final current = ci == _index;
                              // 已缓存 = 已下载（截图里的 ☁ 标记）
                              final downloaded = _cache.containsKey(ci);
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  if (ci != _index) _jumpTo(ci);
                                },
                                child: Container(
                                  color: current
                                      ? _fg.withValues(alpha: 0.06)
                                      : null,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.chapters[ci].name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppTheme.fontHeadline,
                                            color: _fg,
                                            fontWeight: current
                                                ? FontWeight.w700
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        downloaded
                                            ? Icons.cloud_done_rounded
                                            : Icons.cloud_outlined,
                                        size: 18,
                                        color: downloaded
                                            ? _fg.withValues(alpha: 0.7)
                                            : _fgMuted.withValues(alpha: 0.5),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          ),
                          ),
                          // 滚动时浮现的「到顶 / 到底」竖条
                          Positioned(
                            right: 2,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: IgnorePointer(
                                ignoring: !tocScrolling,
                                child: AnimatedOpacity(
                                  opacity: tocScrolling ? 1 : 0,
                                  duration: const Duration(milliseconds: 160),
                                  child: Container(
                                    width: 32,
                                    decoration: BoxDecoration(
                                      color: _fg.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _tocJumpBtn(
                                          Icons.keyboard_arrow_up_rounded,
                                          '回到顶部',
                                          () {
                                            if (itemScrollController
                                                .isAttached) {
                                              itemScrollController.jumpTo(
                                                index: 0,
                                              );
                                            }
                                          },
                                        ),
                                        Container(
                                          width: 14,
                                          height: 0.5,
                                          color: _fg.withValues(alpha: 0.22),
                                        ),
                                        _tocJumpBtn(
                                          Icons.keyboard_arrow_down_rounded,
                                          '跳到底部',
                                          () {
                                            if (itemScrollController
                                                    .isAttached &&
                                                chapters.isNotEmpty) {
                                              itemScrollController.jumpTo(
                                                index: chapters.length - 1,
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 右缘快速拖动定位条（Cmbok 同款）：按住上下拖动 →
                          // 列表按比例滚动，浮现章节标题提示；搜索状态隐藏 ✓
                          if (kwToc.isEmpty)
                            Positioned(
                              right: 2,
                              top: 40,
                              bottom: 40,
                              // 滚动时「到顶/到底」竖条浮现 → 右缘拖动条让位，
                              // 否则它的透明热区会吃掉竖条上的点击 ✗
                              child: IgnorePointer(
                                ignoring: tocScrolling,
                                child: LayoutBuilder(
                                builder: (c, cons) {
                                  final h = cons.maxHeight;
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onVerticalDragStart: (d) {
                                      setSheet(() {
                                        showDragTip = true;
                                        dragTocTo(d.localPosition.dy, h);
                                      });
                                    },
                                    onVerticalDragUpdate: (d) {
                                      setSheet(
                                        () => dragTocTo(d.localPosition.dy, h),
                                      );
                                    },
                                    onVerticalDragEnd: (_) {
                                      Future.delayed(
                                        const Duration(milliseconds: 700),
                                        () {
                                          if (ctx.mounted) {
                                            setSheet(() => showDragTip = false);
                                          }
                                        },
                                      );
                                    },
                                    // 只留一个细短指示块，**不再画整条灰底 + ⌃⌄ 图标** ——
                                    // 用户反馈"这么长的滑动样式"太碍眼 ✗。
                                    // 热区仍是整条（24 宽，透明），拖动功能不受影响 ✓。
                                    child: SizedBox(
                                      width: 24,
                                      child: Stack(
                                        children: [
                                          // 拖动指示块（按当前可见章下标比例定位；
                                          // 监听 ItemPositions，滚动时自动刷新 ✓）
                                          Positioned(
                                            top: 0,
                                            left: 10,
                                            child: ValueListenableBuilder<
                                                Iterable<ItemPosition>>(
                                              valueListenable:
                                                  itemPositionsListener
                                                      .itemPositions,
                                              builder: (c, positions, _) {
                                                final ratio =
                                                    positions.isEmpty ||
                                                            chapters.length <= 1
                                                        ? 0.0
                                                        : (positions
                                                              .reduce((a, b) =>
                                                                  a.index <
                                                                          b.index
                                                                      ? a
                                                                      : b)
                                                              .index /
                                                          (chapters.length -
                                                              1));
                                                return Transform.translate(
                                                  offset: Offset(
                                                    0,
                                                    (ratio.clamp(0.0, 1.0) *
                                                            (h - 44))
                                                        .clamp(0.0, h - 44),
                                                  ),
                                                  child: Container(
                                                    width: 4,
                                                    height: 44,
                                                    decoration: BoxDecoration(
                                                      color: _fg.withValues(
                                                        alpha: 0.22,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              2),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                              ),
                            ),
                          // 拖动时浮现的章节标题提示（只读 ✓）
                          if (showDragTip && dragTipName.isNotEmpty)
                            Positioned(
                              right: 40,
                              top: (40 + dragTipY - 20).clamp(
                                0.0,
                                double.infinity,
                              ),
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(ctx).size.width * 0.62,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _fg.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  dragTipName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _bgTop,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ] else if (tab == 1) ...[
                    // ── 书签 tab（参考图 IMG_8504：搜索书签 + 全部 + 空态）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: _fgMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrlBm,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fg,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '搜索书签',
                                        hintStyle: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fgMuted,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                      onChanged: (v) =>
                                          setSheet(() => kwBm = v.trim()),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: asc ? '正序（点击切倒序）' : '倒序（点击切正序）',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              size: 20,
                              color: _fg.withValues(alpha: asc ? 0.9 : 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 全部 + 6 色筛选
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => setSheet(() => filterColor = null),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '全部',
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  fontWeight: FontWeight.w600,
                                  color: filterColor == null ? _bgTop : _fg,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _BookSourceReaderPageState._bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(
                                () => filterColor = filterColor == c ? null : c,
                              ),
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: filterColor == c
                                      ? Border.all(color: _fg, width: 2.5)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: () {
                        final kw2 = kwBm.toLowerCase();
                        final entries = _bookmarks.entries.where((e) {
                          if (filterColor != null && e.value != filterColor) {
                            return false;
                          }
                          if (kw2.isEmpty) return true;
                          final t = _paragraphs.length > e.key
                              ? _paragraphs[e.key]
                              : '';
                          final note = _bookmarkNotes[e.key] ?? '';
                          return t.toLowerCase().contains(kw2) ||
                              note.toLowerCase().contains(kw2);
                        }).toList();
                        if (entries.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(30),
                              child: Text(
                                '还没有书签',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  height: 1.7,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          itemBuilder: (c, i) {
                            final e = entries[i];
                            return ListTile(
                              leading: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: e.value,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              title: Text(
                                _paragraphs.length > e.key
                                    ? _paragraphs[e.key]
                                    : '第 ${e.key + 1} 段',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: _fg,
                                ),
                              ),
                              // 有备注就显示出来（默认备注 = 章节名 + 正文片段）
                              subtitle: (_bookmarkNotes[e.key] ?? '').isEmpty
                                  ? null
                                  : Text(
                                      _bookmarkNotes[e.key]!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fgMuted,
                                      ),
                                    ),
                              trailing: IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: _fgMuted,
                                ),
                                onPressed: () => setSheet(() {
                                  setState(() {
                                    _bookmarks.remove(e.key);
                                    _bookmarkNotes.remove(e.key);
                                  });
                                  _scheduleSavePrefs();
                                }),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                final p = _pageOfParagraph(e.key);
                                if (p != null && _pageCtrl.hasClients) {
                                  _pageCtrl.jumpToPage(p);
                                }
                              },
                            );
                          },
                        );
                      }(),
                    ),
                  ] else ...[
                    // ── 笔记 tab（参考图 IMG_8505：搜索摘录或批注 + 全部 + 空态）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: _fg.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: _fgMuted,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: ctrlNote,
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: _fg,
                                ),
                                decoration: InputDecoration(
                                  hintText: '搜索摘录或批注',
                                  hintStyle: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onChanged: (v) =>
                                    setSheet(() => kwNote = v.trim()),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 全部 + 6 色筛选
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => setSheet(() => filterColor = null),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '全部',
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  fontWeight: FontWeight.w600,
                                  color: filterColor == null ? _bgTop : _fg,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _BookSourceReaderPageState._bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(
                                () => filterColor = filterColor == c ? null : c,
                              ),
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: filterColor == c
                                      ? Border.all(color: _fg, width: 2.5)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: () {
                        final all = ReaderNotesService.instance.forBook(
                          widget.source.id,
                          widget.bookName,
                        );
                        final kw2 = kwNote.toLowerCase();
                        final notes = all.where((n) {
                          if (filterColor != null &&
                              Color(n.color) != filterColor) {
                            return false;
                          }
                          if (kw2.isEmpty) return true;
                          return n.text.toLowerCase().contains(kw2) ||
                              n.note.toLowerCase().contains(kw2);
                        }).toList();
                        if (notes.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(30),
                              child: Text(
                                all.isEmpty ? '还没有划线，长按正文试试' : '没有匹配的笔记',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  height: 1.7,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: notes.length,
                          itemBuilder: (c, i) {
                            final n = notes[i];
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(14),
                                border: Border(
                                  left: BorderSide(
                                    color: Color(n.color),
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        n.hasNote
                                            ? Icons.edit_note_rounded
                                            : Icons.border_color_rounded,
                                        size: 16,
                                        color: Color(n.color),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '${n.chapterName.isEmpty ? '第${n.chapterIndex + 1}章' : n.chapterName}'
                                          '${n.chapterIndex == _index ? '（当前）' : ''}',
                                          style: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () async {
                                          await ReaderNotesService.instance
                                              .remove(n.id);
                                          if (ctx.mounted) {
                                            Navigator.pop(ctx);
                                            setState(() {});
                                          }
                                        },
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                          color: _fgMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    n.text,
                                    style: TextStyle(
                                      fontSize: AppTheme.fontSubhead,
                                      color: _fg,
                                      height: 1.5,
                                    ),
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (n.hasNote) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Color(
                                          n.color,
                                        ).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        '批注：${n.note}',
                                        style: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fg,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (n.chapterIndex != _index)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: GestureDetector(
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _jumpToChapter(n.chapterIndex);
                                        },
                                        child: Text(
                                          '跳到本章 →',
                                          style: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: JellyTheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      }(),
                    ),
                  ],
                ],
          );
                },
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, secondary, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        );
        return SlideTransition(position: offset, child: child);
      },
    );
    // 抽屉关闭 → 收掉「到顶/到底」竖条的淡出定时器
    tocHideTimer?.cancel();
    // ItemScrollController / ItemPositionsListener 是普通对象（非 ChangeNotifier），
    // 不需要 dispose ✓。
    // ⚠️ 三个 TextEditingController 不能在这里立刻 dispose ✗：
    //   `await showGeneralDialog` 在**退场动画开始**时就返回了 ✓，
    //   接下来 260ms 内 TextField 还挂在 Overlay 上 ⇒ 提前 dispose 会让
    //   TextField 在重建/销毁时用到已销毁的 controller（"used after being
    //   disposed" ✗）。等退场动画走完再回收 ✓。
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      ctrlToc.dispose();
      ctrlBm.dispose();
      ctrlNote.dispose();
    });
  }

@override
  /// 段落 → 所在页下标（书签跳转用）
  int? _pageOfParagraph(int pi) {
    if (pi >= _paragraphs.length) return null;
    // 优先用「块下标」定位：`_pages` 是由 `[章标题?, 段0, 段1, …]` 分页来的
    // ⇒ 段落 pi 对应块 pi + [_blockOffset]（见 `_paginate` 里构造 blocks 的地方）。
    // 原来按「段落文本相等」匹配 ✗ —— 同一章出现重复句子（"……"、"他说"）时
    // 会命中第一处 ⇒ 书签跳到错误页。
    final offset = _blockOffset;
    for (var i = 0; i < _pages.length; i++) {
      // ⚠️ 只看**本章**的页：无缝拼接后 `_pages` 末尾混有下一章的页，
      //   而下一章的 blockIndex 是从 0 重新数的 ⇒ 不筛章会跳到别的章里。
      if (i < _pageChapterOf.length && _pageChapterOf[i] != _index) continue;
      for (final e in _pages[i].entries) {
        if (e.blockIndex >= 0 && e.blockIndex - offset == pi) return i;
      }
    }
    // 兜底：极少数旧分页数据没有 blockIndex，仍按文本匹配
    final text = _paragraphs[pi];
    for (var i = 0; i < _pages.length; i++) {
      if (i < _pageChapterOf.length && _pageChapterOf[i] != _index) continue;
      for (final e in _pages[i].entries) {
        final b = e.block;
        if (b is ParagraphBlock && b.text == text) return i;
      }
    }
    return null;
  }
}
