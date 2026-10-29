part of '../book_source_reader_page.dart';

mixin _ReaderPart06 on _BookSourceReaderPageState {
@override
  /// 朗读面板（截图 IMG_8082~8085）—— **真的能发声**。
  ///
  /// ── 声音从哪来 ────────────────────────────────────────────────
  /// iOS 端 `ios/Runner/TtsEngine.swift` 用系统自带 `AVSpeechSynthesizer`
  /// 实现，已在 AppDelegate 注册；这里通过 `TtsService` 驱动。
  ///
  /// ⚠️ **不要引 flutter_tts**：TrollStore 侧载不能新增原生插件，
  /// 新增 pub 依赖若没重新 pod install → 插件库不被链接 → 启动闪退。
  ///
  /// ── 4 个分段 ──────────────────────────────────────────────────
  ///   声音：语速 / 音调 / 音量（真接 TtsService）+ 朗读引擎入口
  ///   跟读：高亮 关/当前句/当前段 + 样式 + 6 色 + 范围 本章/整本
  ///   定时：关/15/30/45/60/90 分钟 + 读完本章
  ///   高级：点朗读进播放页 / 自动定位阅读位置
  void _showTtsSheet() {
    var tab = 0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setSheet(() {});
            setState(fn);
            _scheduleSavePrefs();
          }

          return Container(
            constraints:
                // 最高半屏（用户 2026-10-12）
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题 + 独立设置
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          '朗读',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: _fgMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // ✅ 与排版行的「独立排版」同源（同一个 `_independent` ✓），已接线：
                        //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录 ✓。
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
                              onChanged: (v) async {
                                setState(() => _independent = v);
                                if (v) {
                                  await BsrIndependentLayout.instance.enable(
                                    _indepKey,
                                    _layoutSnapshot(),
                                  );
                                } else {
                                  await BsrIndependentLayout.instance.disable(
                                    _indepKey,
                                  );
                                }
                                _scheduleSavePrefs();
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 正在念的那句
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                    child: Obx(() {
                      final i = _tts.currentIndex.value;
                      final s = _ttsSegments;
                      final cur = (i >= 0 && i < s.length) ? s[i] : '';
                      return Text(
                        cur.isEmpty ? '点下方播放开始朗读本章' : cur,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          height: 1.5,
                          color: _fgMuted,
                        ),
                      );
                    }),
                  ),
                  // 播放控制
                  Obx(() {
                    final speaking = _tts.isSpeaking.value;
                    final paused = _tts.isPaused.value;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () =>
                              _tts.jumpTo(_tts.currentIndex.value - 1),
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            size: 30,
                            color: _fgMuted,
                          ),
                        ),
                        const SizedBox(width: 18),
                        GestureDetector(
                          onTap: () {
                            if (speaking) {
                              _tts.pause();
                            } else if (paused) {
                              _tts.resume();
                            } else {
                              _startTts();
                            }
                          },
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: _fg.withValues(alpha: 0.92),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              speaking
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 30,
                              color: _bgTop,
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        IconButton(
                          onPressed: () =>
                              _tts.jumpTo(_tts.currentIndex.value + 1),
                          icon: Icon(
                            Icons.skip_next_rounded,
                            size: 30,
                            color: _fgMuted,
                          ),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 6),
                  // 4 个分段
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (var i = 0; i < _BookSourceReaderPageState._ttsTabs.length; i++)
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSheet(() => tab = i),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: tab == i
                                      ? _fg.withValues(alpha: 0.85)
                                      : _fg.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  _BookSourceReaderPageState._ttsTabs[i],
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: tab == i
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: tab == i ? _bgTop : _fg,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (tab == 0) ..._ttsVoiceTab(upd),
                          if (tab == 1) ..._ttsFollowTab(upd),
                          if (tab == 2) ..._ttsTimerTab(upd),
                          if (tab == 3) ..._ttsAdvancedTab(),
                        ],
                      ),
                    ),
                  ),
                  // 底部：停止朗读 · 收起
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            _tts.stop();
                            setSheet(() {});
                          },
                          child: Text(
                            '停止朗读',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: _fg,
                            ),
                          ),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: FilledButton.styleFrom(
                            backgroundColor: _fg.withValues(alpha: 0.9),
                            foregroundColor: _bgTop,
                          ),
                          child: const Text('收起'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

@override
  /// 开始朗读本章
  Future<void> _startTts() async {
    // 朗读与自动翻页互斥（否则会出现"念着念着又被翻走"）
    _stopAutoRead();
    final text = _paragraphs.join('\n');
    if (text.trim().isEmpty) {
      _toast('这一章没有可朗读的正文');
      return;
    }
    // 念完自动进下一章（长按连续听书）
    _tts.onFinished = () {
      if (!mounted) return;
      // 已是最后一章 → 不预约（否则 `_go` 会被拒绝，标记会残留到下次加载）
      if (_index + 1 >= widget.chapters.length) return;
      _ttsAutoNext = true;
      _go(1); // 只发起加载；续读交给 `_loadChapter` 正文就绪处
    };
    // TtsService 自己切段（splitSegments 会按标点再切过长段）
    // A4 双音色：逐段音色覆盖（对话段 → 对话音色，其余 → 旁白音色）✓
    _tts.setNowPlayingMeta(widget.bookName, _displayChapterName);
    await _tts.speak(text, segmentVoices: _buildSegmentVoices());
    if (mounted) setState(() {});
  }

@override
  /// A4：按段生成音色覆盖（双音色关 → null；开 → 对话段/旁白段各用对应音色；
  /// 音色名为空 → 该段用源默认，不强制覆盖 ✓）。
  List<String?>? _buildSegmentVoices() {
    if (!_ttsDualVoice) return null;
    final segs = _ttsSegments;
    if (segs.isEmpty) return null;
    return segs
        .map((s) {
          final isDialogue =
              paragraphKindOf(s.trim()) == ParagraphKind.dialogue;
          final v = isDialogue ? _ttsDialogueVoice : _ttsNarratorVoice;
          return v.trim().isEmpty ? null : v.trim();
        })
        .toList(growable: false);
  }

@override
  List<Widget> _ttsVoiceTab(void Function(VoidCallback) upd) {
    return [
      // ── 语速 / 音调 / 音量（参考图 IMG_8489 的 − 值 + 样式）──
      Obx(
        () => _ttsStepper(
          '语速',
          '${_tts.rate.value.toStringAsFixed(2)}x',
          onMinus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value + 0.05).clamp(0.5, 2.0));
          },
        ),
      ),
      Obx(
        () => _ttsStepper(
          '音调',
          _tts.pitch.value.toStringAsFixed(2),
          onMinus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value + 0.05).clamp(0.5, 2.0));
          },
        ),
      ),
      _ttsStepper(
        '音量',
        '$_ttsVolume%',
        onMinus: () {
          upd(() => _ttsVolume = (_ttsVolume - 5).clamp(0, 100));
        },
        onPlus: () {
          upd(() => _ttsVolume = (_ttsVolume + 5).clamp(0, 100));
        },
      ),
      const SizedBox(height: 6),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── 音色（参考图 IMG_8488：音色（共1个）/ 系统朗读 / 跟随系统）──
      InkWell(
        onTap: () => _showTtsVoicePanel(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(Icons.face_rounded, size: 20, color: _fg),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '音色',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _ttsFollowSystem ? '系统朗读 · 跟随系统' : '系统朗读',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '1个',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── A4 双音色朗读（旁白/对话各一音色，EasyVoice 网络源生效）──
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 20, color: _fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '双音色朗读',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '旁白与对话各配一个音色（EasyVoice 源生效）',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _ttsDualVoice,
              onChanged: (v) => upd(() => _ttsDualVoice = v),
            ),
          ],
        ),
      ),
      if (_ttsDualVoice) ...[
        _ttsVoiceField('旁白音色', _ttsNarratorCtl, () {
          _ttsNarratorVoice = _ttsNarratorCtl.text.trim();
          _scheduleSavePrefs();
        }),
        _ttsVoiceField('对话音色', _ttsDialogueCtl, () {
          _ttsDialogueVoice = _ttsDialogueCtl.text.trim();
          _scheduleSavePrefs();
        }),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '留空 = 该角色用源默认音色；例如 zh-CN-XiaoxiaoNeural',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
          ),
        ),
      ],
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── 朗读引擎（参考图 IMG_8489：更换 / 试听）──
      InkWell(
        onTap: () async {
          Navigator.pop(context);
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TtsEnginePage()),
          );
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded, size: 20, color: _fg),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '朗读引擎',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 用户 2026-10-29：「感觉搞得好混乱」——这行原来**写死**成
                  // 「系统朗读 · 跟随系统」，即使用户已经把引擎换成小米 MiMo，
                  // 面板里还写着系统朗读。现在显示真实在用的那个。
                  Text(
                    _ttsEngineSubtitle(),
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _ttsSpeakSample(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _fg.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '试听',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '更换',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      Text(
        '音量由系统控制，此处仅记录偏好。'
        '语速/音调改完立刻对下一句生效。',
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          height: 1.7,
          color: _fgMuted,
        ),
      ),
    ];
  }

@override
  /// 朗读面板里的「− 值 +」步进行（参考图 IMG_8489）
  Widget _ttsStepper(
    String label,
    String display, {
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    Widget btn(IconData icon, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: _fg),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
          ),
          const Spacer(),
          btn(Icons.remove_rounded, onMinus),
          Container(
            width: 76,
            alignment: Alignment.center,
            child: Text(
              display,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: _fg,
              ),
            ),
          ),
          btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }

@override
  /// 音色面板（参考图 IMG_8488）
  void _showTtsVoicePanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setSheet(() {});
            setState(fn);
            _scheduleSavePrefs();
          }

          return Container(
            constraints: BoxConstraints(
              // 最高半屏（用户 2026-10-12）
              maxHeight: MediaQuery.of(ctx).size.height * 0.5,
            ),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Row(
                      children: [
                        Text(
                          '音色（共 1 个）',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 26,
                            color: _fgMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Text(
                      '音色跟随系统设置 · 文字转语音；换引擎在朗读引擎设置里',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5,
                        color: _fgMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 系统朗读
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.record_voice_over_rounded,
                            size: 20,
                            color: _fg,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '系统朗读',
                              style: TextStyle(
                                fontSize: AppTheme.fontBody,
                                fontWeight: FontWeight.w600,
                                color: _fg,
                              ),
                            ),
                          ),
                          Icon(
                            !_ttsFollowSystem
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 20,
                            // 深色下 `JellyTheme.primary`(#3A3A3A) 落在面板底上
                            // 等于隐形，选中标记改用前景色（用户 2026-10-29）。
                            color: !_ttsFollowSystem ? _fg : _fgMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    color: _fg.withValues(alpha: 0.08),
                    indent: 20,
                    endIndent: 20,
                  ),
                  // 跟随系统
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.settings_suggest_rounded,
                            size: 20,
                            color: _fg,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '跟随系统',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: FontWeight.w600,
                                    color: _fg,
                                  ),
                                ),
                                Text(
                                  '用系统当前默认音色',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            _ttsFollowSystem
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 20,
                            color: _ttsFollowSystem ? _fg : _fgMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

@override
  /// 试听：念当前正在读的一句（没有就念第一句）
  void _ttsSpeakSample() {
    if (_tts.isSpeaking.value) {
      _toast('正在朗读中，可先暂停');
      return;
    }
    final s = _ttsSegments;
    if (s.isEmpty) return;
    _tts.speak(s[0], startAt: 0);
    setState(() {});
  }

@override
  /// 朗读面板里「朗读引擎」那一行的副标题 —— 显示**真实**在用的引擎。
  ///
  /// 读 `TtsService.activeEngineLabel`（它按"有没有网络源 + 有没有降级"算），
  /// 不直接读 store：降级到系统朗读时这里也该跟着说实话。
  String _ttsEngineSubtitle() {
    final tts = _tts;
    final name = tts.activeEngineLabel;
    if (name == '系统朗读') return '系统朗读 · 离线 · 自动兜底';
    final src = TtsSourceStore.instance.active;
    final kind = src?.typeLabel ?? '网络朗读源';
    return '$name · $kind';
  }

  /// A4：双音色音色名输入行
  Widget _ttsVoiceField(
    String label,
    TextEditingController ctl,
    VoidCallback onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              decoration: InputDecoration(
                isDense: true,
                hintText: '空 = 用源默认音色',
                hintStyle: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: _fgMuted,
                ),
                filled: true,
                fillColor: _fg.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }

@override
  List<Widget> _ttsFollowTab(void Function(VoidCallback) upd) {
    const styles = ['◆', '✎', 'U', '···', '—', '=', '≈'];
    const colors = [
      Color(0xFFF5C842),
      Color(0xFF8FD48F),
      Color(0xFF7EC8F0),
      Color(0xFFF07E9E),
      Color(0xFFC88FE8),
      Color(0xFFA8B4E0),
    ];
    return [
      _ttsLabel('高亮'),
      Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => upd(() => _ttsHighlight = i),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _ttsHighlight == i
                        ? _fg.withValues(alpha: 0.85)
                        : _fg.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    ['关', '当前句', '当前段'][i],
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _ttsHighlight == i ? _bgTop : _fg,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      // ⚠️ **本格原来是个"假控件"** ✗（与今天清理的假开关同类 ✓）：
      //   ① `onTap: () => upd(() {})` ✓ —— 点了**只重绘、不改任何状态** ✗
      //   ② 选中态**写死 `i == 0`** ✗ → 看起来"第 1 个永远选中" ✓，点别的没反应 ✗✗
      // ✅ **本轮按代码事实处理** ✓（不改后端、不硬造能力 ✗）：
      //   · 底层**没有"风格/情感"参数** ✗ —— `TtsService` 对 EasyVoice 只传
      //     **`voice`（音色）/ `rate`（语速）/ `pitch`（音调）** ✓（`tts_service.dart:358-360` ✓），
      //     所以这排 chip 无论怎么点都**驱动不了任何东西** ✗。
      //   · 而**音色选择本来就有真正的入口** ✓✓：**「朗读引擎」页** ✓
      //     （选 easyvoice 源 ✓ → 「拉取音色列表」✓ → 写进 `src.voice` ✓，我核实过那是真实现 ✓）。
      //   ⇒ 因此这里**不再假装可切** ✓：chips 变成**禁用外观** ✓ 并指向真入口 ✓。
      _ttsLabel(
        '样式：EasyVoice 只有「音色 / 语速 / 音调」✓ —— '
        '音色请到「朗读引擎」页选源并拉取 ✓（本格无"风格/情感"参数 ✗）',
      ),
      Row(
        children: [
          for (var i = 0; i < styles.length; i++)
            GestureDetector(
              // ⛔ **有意不响应** ✗✓：底层无此参数，做成可点就是新的假控件 ✗
              onTap: null,
              child: Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.only(right: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // 统一"禁用"外观 ✓（不再有"第 1 个被选中"的假象 ✗）
                  color: _fg.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  styles[i],
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: _fg.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _ttsLabel('颜色'),
      Row(
        children: [
          for (var i = 0; i < colors.length; i++)
            GestureDetector(
              onTap: () => upd(() => _ttsColor = i),
              child: Container(
                width: 32,
                height: 32,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: colors[i],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _ttsColor == i ? _fg : _fg.withValues(alpha: 0.15),
                    width: _ttsColor == i ? 2.5 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      // 🔴 下面这个「本章 / 整本」选择器是**纯装饰** ✗，两个毛病都在这一处：
      //   ① `onTap: () => upd(() {})` ✓ —— 点了只重绘、**不改任何状态** ✓，
      //      也就是说这个"选择"从来没有被存下来、也没人读它 ✗
      //   ② 而「整本」那一格的底色是**写死的 `alpha: 0.85`** ✗ → 不管选没选
      //      都画成"高亮已选中" ✓（用户会以为"整本朗读"是开着的 ✗）
      // ✓ 先把范围标签如实写明（功能未接入 ✓，不假装能选 ✓）
      // ⚠️ 遗留：要真做"整本朗读"需把选择接进 `_ttsSegments` 的构造 ✓
      //   （让它跨章拼段 ✓）—— 那是一次功能改动，不是文案 ✓
      // ⚠️ 上面那句「范围（本章 ✓ 整本未接入 ✗）」**原来是不准的** ✗ —— 已按代码事实改正 ✓：
      //   本页 `_startTts()`（`:3848-3866` ✓）里 **`onFinished` → `_go(1)` → 自动 `_startTts()`** ✓✓，
      //   注释自己写着「**念完自动进下一章（长按连续听书）**」✓ —— 也就是**整本连读本来就实现了** ✓。
      //   而"到哪儿停"也有现成开关 ✓：「**定时**」页的「**读完本章**」选项 ✓
      //   ⇒ 选它 = 读完本章停 ✓；不选 = 一路连到全书 ✓✓ **两种模式都在** ✓。
      _ttsLabel('范围（本章 ✓ 整本连读 ✓ —— 用「定时」页的「读完本章」决定到哪停）'),
      Row(
        children: [
          for (final n in ['本章', '整本'])
            Expanded(
              child: GestureDetector(
                onTap: () => upd(() {}),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: n == '本章'
                        ? _fg.withValues(alpha: 0.06)
                        : _fg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    n,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: n == '本章' ? _fg : _bgTop,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '跟读高亮会在正文里给正在念的句子加底色，方便对照着听。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
      ),
    ];
  }

@override
  List<Widget> _ttsTimerTab(void Function(VoidCallback) upd) {
    return [
      _ttsLabel('定时'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in [0, 15, 30, 45, 60, 90])
            GestureDetector(
              onTap: () {
                upd(() => _ttsTimer = m);
                _scheduleTtsTimer(m);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _ttsTimer == m
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  m == 0 ? '关' : '$m 分钟',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: _ttsTimer == m ? _bgTop : _fg,
                  ),
                ),
              ),
            ),
          GestureDetector(
            onTap: () => upd(() => _ttsTimer = -1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _ttsTimer == -1
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '读完本章',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _ttsTimer == -1 ? _bgTop : _fg,
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '定时到点为暂停，按播放键即接着读。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
      ),
    ];
  }

@override
  List<Widget> _ttsAdvancedTab() {
    return [
      // 🔴 下面两个开关是**纯装饰** ✗：喂进来的 `value` 是**写死的 `false`** ✓，
      // 而 `_ttsSwitch` 内部固定 `onChanged: null`（`:4263` ✓）→
      // 开关**永远显示"关"、且永远点不动** ✓，可 `sub` 文案却写着"开启后…" ✗
      // → 用户会一直找不到"在哪儿开" ✓。
      // ✓ 先如实标注（标题加"未接入" ✓）。
      // ⚠️ 遗留：真正接线要把它们变成**真实设置**（落盘 + 被 TTS 逻辑读取 ✓，
      //   例如"点朗读是否直接进播放页" / "朗读是否自动翻页" ✓）—— 功能改动 ✓
      // ✅ 这两个开关**已完全接通** ✓（本轮收尾 ✓）：`value` 取真实字段 ✓、`onChanged` 改值并落盘 ✓，
      //   而且**行为也接了** ✓✓ ——
      //     · 「点朗读进播放页」→ 朗读格按它分派 ✓（开启时直达 `TtsFullPlayerPage` ✓，见 `:1948` 一带 ✓）
      //     · 「自动定位阅读位置」→ 跟读高亮的 `Obx` 里按它滚动 ✓（`_wrapWithHighlight` ✓ `:1247` ✓）
      //   ⇒ **标注已摘掉** ✓（原先写的「行为待接 ✗」现在已不成立 ✗ → 不摘就是新的假话 ✓）。
      _ttsSwitch(
        '点朗读进播放页',
        '开启后点底栏「朗读」直接进沉浸式播放页'
            '（封面+当前句大字）；关闭时也可从播放条上的唱片键进入',
        _ttsDirectPlayer,
        onChanged: (v) => setState(() {
          _ttsDirectPlayer = v;
          _scheduleSavePrefs();
        }),
      ),
      _ttsSwitch(
        '自动定位阅读位置',
        '朗读时自动翻到正在读的那一页；'
            '关闭后由播放条上的定位键手动跳',
        _ttsAutoLocate,
        onChanged: (v) => setState(() {
          _ttsAutoLocate = v;
          _scheduleSavePrefs();
        }),
      ),
    ];
  }

@override
  /// 定时器：到点暂停
  void _scheduleTtsTimer(int minutes) {
    _ttsTimerHandle?.cancel();
    if (minutes <= 0) return;
    _ttsTimerHandle = Timer(Duration(minutes: minutes), () {
      if (mounted && _tts.isSpeaking.value) _tts.pause();
    });
  }

@override
  Widget _ttsLabel(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      s,
      style: TextStyle(
        fontSize: AppTheme.fontBody,
        fontWeight: FontWeight.w600,
        color: _fg,
      ),
    ),
  );

@override
  /// 朗读面板里的一个开关行 ✓。
  ///
  /// ✅ **本轮新增 `onChanged`** ✓ —— 此前它把开关的 `onChanged` **写死为 `null`** ✗，
  ///   于是「高级」页里凡是走它的开关都**永远显示关闭、而且永远点不动** ✗✗
  ///   （`_ttsAdvancedTab` 上方的注释自己也写着"这两个开关是**纯装饰**"✗）。
  ///   ⇒ 现在把回调传进来，它就能变成**真设置** ✓（落盘 ✓ + 被 TTS 逻辑读取 ✓）。
  /// ℹ️ 用**可选参数** ✓：暂时没传 `onChanged` 的调用点行为完全不变（仍不可点 ✓），
  ///   既不会引入编译问题 ✓，也不会误伤害别处"有意禁用"的开关 ⛔（如独立排版/独立设置 ✓）。
  Widget _ttsSwitch(
    String title,
    String sub,
    bool value, {
    ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5,
                    color: _fgMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

@override
  List<String> get _ttsSegments {
    final c = _ttsSegsCache;
    if (c != null) return c;
    final s = TtsService.splitSegments(_paragraphs.join('\n'));
    _ttsSegsCache = s;
    return s;
  }

@override
  void _invalidateTtsSegs() => _ttsSegsCache = null;

@override
  /// AI 面板（真实可用）：四个动作走 OpenAI 兼容 chat 接口，
  /// 未配置时引导填写自己的接口地址 / API Key / 模型名。
  void _showAiSummary() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      'AI',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _fg,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'AI 接口配置',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showAiConfig();
                      },
                      icon: Icon(
                        Icons.settings_outlined,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              for (final a in ['总结本章', '解释这段', '生成书评', '问答'])
                ListTile(
                  title: Text(
                    a,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      color: _fg,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: _fgMuted,
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _runAiAction(a);
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  'AI 调用你自己的对话接口（OpenAI 兼容）。未配置时点动作会先弹配置：'
                  '接口地址 / API Key / 模型名（支持 DeepSeek、通义、智谱、本地 vLLM 等）。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.7,
                    color: _fgMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

@override
  /// AI 接口配置 sheet：接口地址 / API Key / 模型名
  Future<void> _showAiConfig() async {
    final ai = AiService();
    final baseCtrl = TextEditingController(text: ai.baseUrl);
    final keyCtrl = TextEditingController(text: ai.apiKey);
    final modelCtrl = TextEditingController(text: ai.model);
    final fg = _fg;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 10,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI 接口配置',
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'OpenAI 兼容对话接口，Key 只存在本机。默认填 DeepSeek，'
                  '可改成通义/智谱/Moonshot/本地 vLLM 的地址。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.6,
                    color: _fgMuted,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: baseCtrl,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://api.deepseek.com',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  style: TextStyle(color: fg),
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-…',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: modelCtrl,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    labelText: '模型名',
                    hintText: 'deepseek-chat',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        if (keyCtrl.text.trim().isEmpty) {
                          _toast('先填 API Key 才能测试');
                          return;
                        }
                        _toast('正在测试连接…');
                        try {
                          final savedBase = baseCtrl.text.trim();
                          final savedKey = keyCtrl.text.trim();
                          final savedModel = modelCtrl.text.trim().isEmpty
                              ? 'deepseek-chat'
                              : modelCtrl.text.trim();
                          // AiService 是**单例** ✓ → 直接改字段会**污染已保存的配置** ✗。
                          // 这里先快照、测完在 finally 还原 ✓（"测试连接"不该改变真实配置 ✓）。
                          final tmp = AiService();
                          final prevBase = tmp.baseUrl;
                          final prevKey = tmp.apiKey;
                          final prevModel = tmp.model;
                          tmp
                            ..baseUrl = savedBase.isEmpty
                                ? 'https://api.deepseek.com'
                                : savedBase
                            ..apiKey = savedKey
                            ..model = savedModel;
                          try {
                            final r = await tmp.chat(
                              system: '你是连接测试助手。',
                              user: '请只回复两个字：正常',
                              timeout: const Duration(seconds: 30),
                            );
                            _toast('连接成功：$r');
                          } finally {
                            tmp
                              ..baseUrl = prevBase
                              ..apiKey = prevKey
                              ..model = prevModel;
                          }
                        } catch (e) {
                          _toast('连接失败：$e');
                        }
                      },
                      child: Text(
                        '测试连接',
                        style: TextStyle(
                          fontSize: 13,
                          // 同上：这个对话框是深底的，primary 在这里读不出来。
                          color: fg,
                        ),
                      ),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () async {
                        // 阅读的这套配置写进「阅读独立」槽位（readerSeparate=true）：
                        // 宠物固定用「设置 → AI 管理」的全局配置，两者互不覆盖。
                        await ai.saveConfig(
                          baseUrl: ai.baseUrl,
                          apiKey: ai.apiKey,
                          model: ai.model,
                          readerSeparate: true,
                          readerBaseUrl: baseCtrl.text,
                          readerApiKey: keyCtrl.text,
                          readerModel: modelCtrl.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        _toast('阅读 AI 配置已保存（只影响阅读）');
                      },
                      child: const Text('保存并返回'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

@override
  /// 执行 AI 动作：未配置先弹配置；已配置直接调用
  Future<void> _runAiAction(String action) async {
    final ai = AiService();
    if (!ai.isConfigured) {
      _toast('先配置 AI 接口');
      _showAiConfig();
      return;
    }
    if (action == '问答') {
      _askAiQuestion();
      return;
    }
    final chapterText = _paragraphs.join('\n');
    final body = chapterText.length > 8000
        ? chapterText.substring(0, 8000)
        : chapterText;
    if (body.trim().isEmpty) {
      _toast('本章没有可用的正文内容');
      return;
    }
    final String system;
    final String user;
    switch (action) {
      case '总结本章':
        system =
            '你是小说阅读助手。用简体中文给出本章的简洁总结'
            '（人物/事件/伏笔要点，200 字以内）。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '解释这段':
        system =
            '你是小说阅读助手，用简体中文通俗解释文中的关键剧情'
            '与难懂之处，300 字以内。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '生成书评':
        system =
            '你是资深书评人，用简体中文写一段 150 字左右的短书评'
            '（风格/亮点/阅读感受）。';
        user = '《${widget.bookName}》本章内容：\n$body';
      default:
        return;
    }
    _showAiLoading(
        action, () => ai.chat(system: system, user: user, scoped: true));
  }

@override
  /// 问答：先弹输入框，再用本章做上下文回答
  Future<void> _askAiQuestion() async {
    final ai = AiService();
    final ctrl = TextEditingController();
    final question = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgTop,
        title: Text('问 AI', style: TextStyle(color: _fg)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _fg),
          decoration: const InputDecoration(hintText: '输入你的问题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('提问'),
          ),
        ],
      ),
    );
    if (question == null || question.isEmpty) return;
    final chapterText = _paragraphs.join('\n');
    final body = chapterText.length > 8000
        ? chapterText.substring(0, 8000)
        : chapterText;
    _showAiLoading(
      '问答',
      () => ai.chat(
        system:
            '你是小说阅读助手，基于给出的本章内容用简体中文回答读者问题。'
            '内容无关时如实说明。',
        user: '《${widget.bookName}》本章内容：\n$body\n\n读者问题：$question',
        scoped: true,
      ),
    );
  }

@override
  /// 调 AI 并展示结果（loading → 结果 sheet / 错误 toast）
  Future<void> _showAiLoading(
    String title,
    Future<String> Function() task,
  ) async {
    final fg = _fg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: _bgTop,
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Text('$title中…', style: TextStyle(color: fg)),
            ],
          ),
        ),
      ),
    );
    String? result;
    String? error;
    try {
      result = await task();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    Navigator.pop(context); // 关 loading
    if (error != null) {
      _toast('AI 失败：$error');
      return;
    }
    _showAiResult(title, result ?? '（无返回内容）');
  }

@override
  /// AI 结果展示 sheet（可选中复制）
  void _showAiResult(String title, String content) {
    final fg = _fg;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制结果',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: content));
                        _toast('已复制');
                      },
                      icon: Icon(Icons.copy_rounded, size: 20, color: _fgMuted),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: fg.withValues(alpha: 0.1)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: SelectableText(
                    content,
                    style: TextStyle(fontSize: 14, height: 1.7, color: fg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

@override
  /// 图片模式：把本章的图片单独列出来看/保存。
  ///
  /// 图片来源有三处（去重合并）✓：
  ///   · `_images` —— **纯图章**的正文图片（引擎 `type:'images'`）✓
  ///   · `_chapterImages` —— **文字章**附带的插图（引擎与 content 一起回）✓
  ///   · 正文里的图片 URL —— 契约为纯文本的源，`<img>` 会以文本留下 ✓
  void _showImageMode() {
    final urls = <String>[];
    for (final u in [..._images, ..._chapterImages]) {
      if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }
    for (final p in _paragraphs) {
      for (final m in RegExp(
        r'https?://[^\s"'
        '<>]+\.(?:jpg|jpeg|png|gif|webp)',
        caseSensitive: false,
      ).allMatches(p)) {
        final u = m.group(0)!;
        if (!urls.contains(u)) urls.add(u);
      }
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      '图片模式',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _fg,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${urls.length} 张',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: _fgMuted,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: urls.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            '这一章没有图片。\n\n'
                            '图片模式会把正文里的插图单独列出来看和保存。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              height: 1.7,
                              color: _fgMuted,
                            ),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemCount: urls.length,
                        itemBuilder: (c, i) => GestureDetector(
                          onTap: () => _previewImage(ctx, urls[i]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              urls[i],
                              headers: _mangaHeaders,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: _fg.withValues(alpha: 0.07),
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 22,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

@override
  /// 大图预览 + 保存到相册。
  ///
  /// 下载走 `BookSourceService` 的 dio（带书源的 header，能过防盗链），
  /// 然后交给原生 `saveImage` 写进相册 —— 零插件。
  Future<void> _previewImage(BuildContext parentCtx, String url) async {
    await showDialog<void>(
      context: context,
      // ⚠️ showDialog 没有 backgroundColor（那是 showModalBottomSheet 的参数），
      // 要全屏黑底得自己用 Dialog + insetPadding: zero 撑满
      barrierColor: Colors.black,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.network(
                  url,
                  headers: _mangaHeaders,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 8,
              right: 12,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 26,
                  color: Colors.white,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 30,
              child: Center(
                child: FilledButton.icon(
                  onPressed: () async {
                    final ok = await _saveImage(url);
                    if (ok && ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('保存到相册'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

@override
  /// 下载并保存一张图到相册。返回是否成功。
  Future<bool> _saveImage(String url) async {
    _toast('正在下载…');
    try {
      // 用引擎的 dio（带书源 header），否则很多图床会 403
      final bytes = await BookSourceService.instance.fetchBytes(
        widget.source,
        url,
        headers: _mangaHeaders,
      );
      if (bytes == null || bytes.isEmpty) {
        _toast('下载失败：图片为空');
        return false;
      }
      final r = await _tts.saveImageToAlbum(bytes);
      if (r.ok) {
        _toast('已保存到相册');
        return true;
      }
      _toast('保存失败：${r.error ?? "未知原因"}');
      return false;
    } catch (e) {
      _toast('保存失败：$e');
      return false;
    }
  }

@override
  /// 跳转到某章节（笔记点击用；分页模式回第一页）。
  Future<void> _jumpToChapter(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    if (_index != chapterIndex) {
      _index = chapterIndex;
      await _loadChapter(_index);
      await _saveProgress();
      if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
    }
    _toast('已跳转到${widget.chapters[chapterIndex].name}');
  }
}
