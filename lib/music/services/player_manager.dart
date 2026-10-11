import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:media_kit/media_kit.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import 'music_api.dart';
import 'download_service.dart';
import 'settings_store.dart';
import 'unblock_service.dart';
import '../../services/audio_focus.dart';
import '../../services/app_log.dart';
import 'library_store.dart';
import '../../widgets/app_toast.dart';
// ⚠️ `cross_platform_matcher.dart` **不再 import** ——
// 用户明确要求"不要搜索其他平台"，回退链已移除跨平台匹配。
// 实现代码仍保留在 services/cross_platform_matcher.dart（需要时加回 import 即可）。
import '../widgets/source_picker_sheet.dart';
import '../../widgets/video_player_pip.dart' show VideoPlayerPip;

/// 播放模式（对齐 Beans 的循环/随机语义）
enum PlayMode {
  list('列表循环'),
  single('单曲循环'),
  shuffle('随机播放');

  const PlayMode(this.label);
  final String label;
}

/// 音乐播放核心 —— 移植自 Beans-Music 的 `PlayerManager.swift`。
///
/// ── 与影视侧的关系 ────────────────────────────────────────────
/// **完全独立**：自己持有 media_kit Player、自己的队列、自己的进度。
/// 不碰 `BackgroundAudio` / `PipManager`，也不共用 `MusicPlayerController`
/// （那是早期按猫影风格做的，现在按 Beans 的结构重建）。
///
/// ── 为什么用 media_kit 而不是 AVPlayer ────────────────────────
/// media_kit 已在依赖里（影视侧在用），是**纯 Dart API + 已有原生库**，
/// 不需要为音乐再引原生插件；它对音频流的兼容性也好于系统播放器。
class MusicPlayerManager extends ChangeNotifier {
  MusicPlayerManager._();
  static final MusicPlayerManager instance = MusicPlayerManager._();

  late final Player _player;
  bool _inited = false;

  /// 当前歌曲
  Song? get currentSong => _currentSong;
  Song? _currentSong;

  /// **仅测试用**：直接指定"当前歌"与"是否在播"，不建原生播放器。
  ///
  /// ── 为什么需要它 ──────────────────────────────────────────────
  /// `_player` 是 `late final Player()`（media_kit），而**单元测试环境
  /// 没有那个原生库** —— `Player()` 一构造就抛
  /// `MediaKit.ensureInitialized must be called`。
  ///
  /// 于是"有歌在播时迷你条长什么样、两条栏会不会重叠"这类**纯布局**
  /// 问题在测试里根本测不到（我为此卡过一次，最后只能靠肉眼看截图）。
  ///
  /// 有了这个钩子，布局测试可以直接进入"正在播放"状态，
  /// 不需要碰原生播放器。
  @visibleForTesting
  void debugSetPlayingForTest(Song? song, {bool playing = true}) {
    _currentSong = song;
    if (song != null) {
      _queue
        ..clear()
        ..add(song);
      _index = 0;
    }
    isPlaying.value = song != null && playing;
    notifyListeners();
  }

  /// 播放队列
  final List<Song> _queue = [];
  List<Song> get queue => List.unmodifiable(_queue);

  int _index = -1;
  int get currentIndex => _index;

  /// 播放代次：每次 `_load` 自增；`await` 回来发现代次变了就**丢弃本次结果**。
  ///
  /// 没有它时：连点两首歌，先发的请求后回来 → 把界面/歌词/播放地址覆盖成
  /// 上一首（"界面显示 A、声音播 B"），歌词也会串到别的歌。
  int _loadEpoch = 0;

  /// 调用方传入的 `BuildContext`，**只用来弹"选音源"弹窗**。
  ///
  /// ── 为什么需要它（不能只用全局 navigatorKey）──────────────────
  /// 弹窗要挂在**用户当前所在的那个 Navigator** 上：如果用户在音乐 tab 里
  /// 点歌，却弹到影视页的 navigator 上，会出现"弹窗在后面/位置错乱"。
  /// 所以由调用方（点歌的那个页面）把 context 传进来；
  /// 拿不到时才回退到全局 key。
  ///
  /// ⚠️ **不能长期持有** —— 页面销毁后 context 就失效了。
  /// 所以每次 `playQueue/playSong` 时覆盖，用完不清（下一个调用会覆盖）。
  BuildContext? _pickerContext;

  /// 由 UI 层调用，把"当前页面 context"告诉播放器（用于弹选源弹窗）
  void attachContext(BuildContext context) => _pickerContext = context;

  /// 弹窗用的 context。
  ///
  /// ⚠️ 优先用调用方传进来的（挂在**用户当前那个 Navigator** 上）；
  /// 兜底才用全局 key —— 直接用全局 key 在"用户在音乐 tab 点歌"
  /// 之外的情况下可能弹错位置。
  ///
  /// ── 🔴 返回**可空**（修一个崩溃：原来这里是 `currentContext!`）────
  /// 原来写的是：
  /// ```dart
  /// BuildContext get _pickerCtx =>
  ///     _pickerContext ?? VideoPlayerPip.navigatorKey.currentContext!;   // ← 强制解包
  /// ```
  /// `navigatorKey.currentContext` 在**框架还没挂载 / 那一帧正好在重建**
  /// 时是 **null** → `!` 直接抛 `Null check operator used on a null value`。
  ///
  /// 触发路径是真实存在的：**冷启动恢复队列后自动播放**、
  /// 或从通知栏/耳机按键触发的播放 —— 那时没有任何页面调用过
  /// `attachContext`，而 `_pickerContext` 为 null。
  ///
  /// 现在返回 null，由调用方（`_load`）判断：拿不到 context 就
  /// **不弹选源弹窗**，改用「试全部源 → 取第一个能用的」+ 明确提示，
  /// 而不是崩掉（崩了用户连声音都没有，比"没得选"更糟）。
  BuildContext? get _pickerCtxOrNull {
    final mine = _pickerContext;
    if (mine != null && mine.mounted) return mine;
    return VideoPlayerPip.navigatorKey.currentContext;
  }

  /// 失败摘要：告诉用户"试了 N 个源，M 个不行"。
  ///
  /// ⚠️ 只给**数量级**信息，不把每条错误都塞进弹窗。
  ///
  /// ⚠️ 必须传 [song]：`UnblockService` 的失败记录是**跨调用共享**的，
  /// 不按歌过滤就会把**别的歌**的失败条数算进来
  ///（快速连点两首歌时"摘要里说 12 个源失败"，而这首歌其实只试了 6 个）。
  ///
  /// ── 🔴 必须写清"日志在**哪**"（修用户实测反馈）──────────────────
  /// 用户原话：「那个源切换过程中源不能用的日志在哪看呢？…详情见日志在哪呢？」
  ///
  /// 原来只写「（详情见日志）」—— **用户根本不知道日志在哪** ✗。
  /// 这个 App 的日志入口藏得比较深（在设置里的一个子页），
  /// 所以这里直接把**路径**写出来。
  String _failedSummary(Song song, int okCount) {
    final failed = UnblockService.instance.failedCountFor(song);
    if (failed == 0) return '';
    // ⚠️ 文案控制在两行以内（弹窗里显示不下更多）
    // ⚠️ 这里指的入口是**音乐模块自己的**「我的 → 音乐运行日志」
    //    （`music/pages/music_log_page.dart`）。
    //    不要再指向阅读模块的「软件日志」—— 那条路用户找不到。
    return '另有 $failed 个音源试过但没拿到地址。'
        '完整原因在「我的 → 音乐运行日志」';
  }

  /// 播放状态
  final isPlaying = ValueNotifier<bool>(false);
  final isBuffering = ValueNotifier<bool>(false);

  /// 进度
  final position = ValueNotifier<Duration>(Duration.zero);
  final duration = ValueNotifier<Duration>(Duration.zero);

  /// 音量 0~100
  final volume = ValueNotifier<double>(100);

  /// 播放模式
  final mode = ValueNotifier<PlayMode>(PlayMode.list);

  /// 当前歌词
  final lyrics = ValueNotifier<List<LyricLine>>(const []);

  /// 当前高亮到第几行（-1 = 还没到）
  final lyricIndex = ValueNotifier<int>(-1);

  /// 歌词时间偏移（ms）。有些歌词文件整体偏早/偏晚，给用户手动校正。
  final lyricOffset = ValueNotifier<int>(0);

  /// 失败提示（不要静默失败 —— 用户会以为是卡了）
  final lastError = ValueNotifier<String>('');

  /// 正在回退到第三方音源（逐个试可能要几秒，UI 要显示进度）
  final switching = ValueNotifier<bool>(false);

  /// 播放地址解析结果里带的音质说明（如"320K"）
  final qualityText = ValueNotifier<String>('');

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _bufSub;
  StreamSubscription? _compSub;

  /// 歌曲自然播完（用于自动下一首）
  VoidCallback? onCompleted;

  Future<void> init() async {
    // 注册到全局音频焦点协调器：影视/直播要出声时会调这里的 pause()。
    // ⚠️ 不注册的话「看视频时音乐还在响」—— 音乐完全不在互斥体系里。
    // ⚠️ 包一层守卫：AudioFocus 调暂停时**不区分对方是否在播**，
    // 直接调 pause() 会走 init() 建播放器（还可能发网络请求）。
    // 只在真在播时才停，避免"音乐明明没在播却被初始化一遍"。
    AudioFocus.register('music', () async {
      if (!isPlaying.value) return;
      await pause();
    });
    if (_inited) return;
    _inited = true;

    // ── 🔴 把播放错误接到统一提示组件（原来完全静默）────────────────
    //
    // `lastError` 之前只有 6 处**赋值**（"正在尝试音源 i/n" / "无免费音源" /
    // 播放失败…），但**全项目没有任何 UI 读它** ——
    // 于是音乐播放失败时用户看不到任何提示，只听到"没声音"。
    //
    // 现在挂一个监听，任何非空错误都通过 `AppToast` 显示
    //（顶部气泡，浮在所有路由之上，不依赖 BuildContext）。
    // **数据流保留**：`lastError` 照样更新，只是多了一个展示出口。
    lastError.addListener(() {
      final msg = lastError.value;
      if (msg.isEmpty) return;

      // ── 🔴 进度信息**绝不能弹窗**（用户实测反馈截图）────────────────
      //
      // 「正在试音源 10/12…」是**进度**，不是错误。原来只认
      // `startsWith('正在尝试音源')` 一种前缀，而实际还存在两种写法：
      //   · `'正在试音源 $done/$total…'`（`resolveAll` 的 onProgress）
      //   · `'正在用「xxx」…'`（音源记忆命中时的提示）
      // 它们不匹配那个前缀 → 走进"真错误"分支 →
      // **弹出「播放失败 / 正在试音源 10/12…」的居中弹窗** ✗
      //（还必须手点"关闭"，而它只是进度 —— 用户截图里的就是它）
      //
      // 现在用一个**统一的判据**：所有进度类文案都带"正在"开头。
      // 真错误从来不是"正在…"（是"没有免费音源"/"播放出错"/"xxx：失败"）。
      final isProgress = msg.startsWith('正在');
      if (isProgress) {
        // 进度用**自动消失的顶部气泡**，不打断操作
        AppToast.show(msg, '', isError: false);
        return;
      }

      // ── 真错误：也**不弹居中弹窗**（用户要求"失败就弹一哈就消失"）──
      //
      // 原来这里用 `AppToast.detail(...)` —— 那是**必须手点关闭**的居中
      // 模态框（带「复制全文」），连续几首失败会叠窗、挡住整个界面 ✗
      // 用户原话：「那么多失败的弹窗，能不能失败就弹一哈就消失呢？」
      //
      // 改成 `AppToast.show(..., isError: true)`：顶部气泡、自动消失、
      // 点一下也能立刻关掉。**全文照样进日志**（下面这句），
      // 排查不受影响（可排查的信息本来就在日志里，不在弹窗里）。
      AppToast.show('播放失败', msg, isError: true);
      AppLog.instance.log('[Music] 播放失败（完整原因）: $msg');
    });

    _player = Player();

    // 🔴 **订阅播放错误流** —— 全项目原来**从未订阅** `stream.error` ✗
    // media_kit 的取流/解码/网络失败大多走这条流；不订阅的话：
    //   · 失败时**界面上什么都没有**（我做的错误弹窗也不会触发 ✗）
    //   · 日志里也查不到
    // 所以这条是"错误可见性"的地基。
    //
    // 这里刻意**不保存订阅引用**（`dispose()` 全仓无调用者、Player 与 App
    // 同生命周期），以保持最小改动；将来若要真正 dispose，记得在这里存引用。
    _player.stream.error.listen((e) {
      final msg = '$e';
      AppLog.instance.log('[Music] 播放流错误: $msg');
      // 走既有的错误出口（会弹"播放失败"全文弹窗）
      lastError.value = '播放出错：$msg';
    });

    _posSub = _player.stream.position.listen((p) {
      position.value = p;
      final idx = LyricParser.indexAt(
        lyrics.value,
        p + Duration(milliseconds: lyricOffset.value),
      );
      if (idx != lyricIndex.value) lyricIndex.value = idx;
    });
    _durSub = _player.stream.duration.listen((d) {
      duration.value = d;
      notifyListeners();
    });
    _playSub = _player.stream.playing.listen((v) {
      isPlaying.value = v;
      notifyListeners();
    });
    _bufSub = _player.stream.buffering.listen((v) {
      isBuffering.value = v;
      notifyListeners();
    });
    _compSub = _player.stream.completed.listen((done) {
      if (!done) return;
      final cb = onCompleted;
      if (cb != null) {
        cb();
      } else {
        next(auto: true);
      }
    });
    // #11：把上次的队列恢复回来（**不自动播放**）。
    // 原来 `loadQueue()` 全仓没有调用者 → "下次启动恢复队列"从未生效。
    unawaited(_restoreQueue());
    notifyListeners();
  }

  // ============================================================
  // 播放
  // ============================================================

  /// 播放单首（替换队列）
  Future<void> playSong(Song song, {List<Song>? fromQueue}) async {
    await init();
    if (fromQueue != null && fromQueue.isNotEmpty) {
      _queue
        ..clear()
        ..addAll(fromQueue);
      _index = _queue.indexWhere((s) => s.identityKey == song.identityKey);
      if (_index < 0) {
        _queue.insert(0, song);
        _index = 0;
      }
    } else {
      _queue
        ..clear()
        ..add(song);
      _index = 0;
    }
    await _load(_index, autoplay: true);
  }

  /// 用整个队列替换并播放第 [index] 首
  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    await init();
    if (songs.isEmpty) return;
    _queue
      ..clear()
      ..addAll(songs);
    _index = index.clamp(0, _queue.length - 1);
    await _load(_index, autoplay: true);
  }

  /// 插入到下一首播放
  Future<void> playNext(Song song) async {
    await init();
    if (_queue.isEmpty) return playSong(song);
    var at = _index + 1;
    if (at > _queue.length) at = _queue.length;
    _queue.insert(at, song);
    notifyListeners();
  }

  /// 追加到队列尾部
  Future<void> addToQueue(Song song) async {
    await init();
    if (_queue.isEmpty) return playSong(song);
    _queue.add(song);
    notifyListeners();
  }

  // ============================================================
  // #11 队列管理（原来只有内部增删，用户看不到也改不了）
  // ============================================================

  /// 跳到队列里的第 [index] 首并播放
  Future<void> playAt(int index) async {
    await init();
    if (index < 0 || index >= _queue.length) return;
    await _load(index, autoplay: true);
  }

  /// 从队列移除第 [index] 首。
  ///
  /// ── ⚠️ 三种情况必须分清（很容易写错）──────────────────────
  ///   1. 移除的是**当前播放**那首 → 移除后原位置变成下一首：
  ///      后面还有歌就直接播新的第 index 首；否则退到最后一首；空了停止。
  ///   2. 移除的在**当前之前** → 当前下标要 **-1**（否则会跳歌）
  ///   3. 移除的在**当前之后** → 下标不变
  ///
  /// 写错第 2 条的表现就是"删了列表上面一首，结果当前歌莫名跳了"。
  Future<void> removeAt(int index) async {
    await init();
    if (index < 0 || index >= _queue.length) return;

    final removingCurrent = index == _index;
    _queue.removeAt(index);

    if (_queue.isEmpty) {
      _index = -1;
      _currentSong = null;
      await _player.stop();
      isPlaying.value = false;
      notifyListeners();
      return;
    }

    if (removingCurrent) {
      final next = index < _queue.length ? index : _queue.length - 1;
      await _load(next, autoplay: true);
    } else {
      if (index < _index) _index--; // 情况 2
      notifyListeners();
    }
    unawaited(MusicLibraryStore.instance.saveQueue(_queue, _index));
  }

  /// 把第 [from] 首移到第 [to] 首的位置（拖动排序）
  ///
  /// ⚠️ 关键点：**当前播放的下标要按"对象"重新定位**，
  /// 不能靠旧的数字推算 —— from/to 跨过 _index 时推算极易错，
  /// 表现是"拖一下列表，当前播放的歌跟丢了"。
  Future<void> moveInQueue(int from, int to) async {
    await init();
    if (from < 0 || from >= _queue.length) return;
    if (to < 0 || to >= _queue.length) return;
    if (from == to) return;

    final current = _currentSong; // 记住正在播的是哪一首（按对象）
    final song = _queue.removeAt(from);
    _queue.insert(to, song);

    if (current != null) {
      final i = _queue.indexWhere((s) => identical(s, current));
      if (i >= 0) _index = i;
    } else if (_index >= _queue.length) {
      _index = _queue.length - 1;
    }

    notifyListeners();
    unawaited(MusicLibraryStore.instance.saveQueue(_queue, _index));
  }

  /// 清空队列。**保留正在播的那首** ——
  /// 用户点"清空列表"不该把音乐也停掉。
  Future<void> clearQueue() async {
    await init();
    final current = _currentSong;
    if (current == null) {
      _queue.clear();
      _index = -1;
      notifyListeners();
      return;
    }
    _queue
      ..clear()
      ..add(current);
    _index = 0;
    notifyListeners();
    unawaited(MusicLibraryStore.instance.saveQueue(_queue, _index));
  }


  /// 取地址 / 播放失败时调用：**把音频停掉**，保证"界面显示的当前歌"与
  /// "实际在响的声音"一致。
  ///
  /// 原来失败分支只写 `isPlaying = false; return;` —— 但**旧歌还在播**，
  /// 于是界面是新歌、声音还是上一首（用户实测："点了新歌，响的还是上一首"）。
  /// 现在显式停掉旧音频，`isPlaying = false` 才是真的。
  Future<void> _silenceForFailure(Song song) async {
    try {
      await _player.stop();
    } catch (e) {
      AppLog.instance.log('[Music] 失败后停旧音频出错: $e');
    }
    isPlaying.value = false;
    isBuffering.value = false;
    position.value = Duration.zero;
    duration.value = Duration(seconds: song.duration.round());
  }

  /// 恢复上次的队列（**只恢复列表与当前项，不自动播放**）。
  ///
  /// `MusicLibraryStore.loadQueue()` 早就实现了，但**全仓没有调用者** →
  /// "下次启动恢复上次听到哪"从未生效。这里把它接上。
  /// 不自动播放：用户没要求时突然出声是很糟的体验。
  Future<void> _restoreQueue() async {
    try {
      if (_queue.isNotEmpty) return; // 用户已经点过歌了，别覆盖
      final saved = await MusicLibraryStore.instance.loadQueue();
      // 🔴 `await` 之后**必须复查一次**：`loadQueue()` 内部要 await 初始化，
      // 这个窗口里用户完全可能已经点了一首歌（`_load` 会换掉 `_queue`）。
      // 不复查的话，恢复流程会把队列换成"旧队 + 新歌"的混合体、
      // 把 `_currentSong` 指回旧歌，而**音频并不会换** → 界面 A、声音 B。
      if (_queue.isNotEmpty) return;
      if (saved.songs.isEmpty) return;
      _queue.addAll(saved.songs);
      _index = saved.index.clamp(0, _queue.length - 1);
      _currentSong = _queue[_index];
      duration.value = Duration(seconds: _currentSong!.duration.round());
      notifyListeners();
      AppLog.instance.log('[Music] 已恢复上次队列: ${_queue.length} 首，'
          '当前第 ${_index + 1} 首《${_currentSong!.name}》（未自动播放）');

      // 启动自动播放：用户在设置里打开了才自动播
      //（默认关，避免揣兜里误触解锁时突然出声）
      if (SettingsStore.instance.autoPlayOnLaunch.value) {
        AppLog.instance.log('[Music] 启动自动播放已开启，开始播放');
        await _load(_index, autoplay: true);
      }
    } catch (e) {
      AppLog.instance.log('[Music] 恢复队列失败: $e');
    }
  }

  Future<void> _load(int index, {required bool autoplay}) async {
    if (index < 0 || index >= _queue.length) return;
    // 本次加载的代次（见 `_loadEpoch`）：下面每个 await 之后都要校验
    final epoch = ++_loadEpoch;
    _index = index;
    final song = _queue[index];
    _currentSong = song;
    lastError.value = '';
    qualityText.value = '';
    switching.value = false;
    lyrics.value = const [];
    lyricIndex.value = -1;
    position.value = Duration.zero;
    // song.duration 是秒，Duration 要命名参数
    duration.value = Duration(seconds: song.duration.round());
    notifyListeners();

    // 1) 解析播放地址
    //
    // ── 顺序（2026-10-10：去掉歌曲粒度音源记忆，改为平台固定源）──
    //   ① **本地文件** —— 已下载的直接播沙盒文件，不走网络（离线可听）
    //   ② **平台固定第三方源** —— 音源管理页给该平台（酷狗/QQ/…）
    //      绑定的源，直接再问它一次（用户原话："自动直接用这个第三方源"）
    //   ③ **内置公开接口**
    //   ④ **试全部第三方源 → 弹窗让用户选**（最后兜底）
    //
    // ⚠️ 为什么"平台固定源"排在"内置"**前面**（原"记忆优先"同因）：
    //    内置接口经常返回"能用但很慢/被限速"的直链 —— `r.ok == true`
    //    时后面的兜底根本不会被查，绑定源形同虚设 ✗
    //    固定源失败会继续落到内置接口，**不会因为绑定而播不了**。
    var url = '';
    var quality = '';
    var fromSource = '';

    // ⚠️ 必须把用户在设置里选的音质传过去。
    // 之前是 `songUrl(song.id)` —— 它会退到默认 exhigh(320K)，
    // 于是"音质"设置能选能存却**从未生效**（典型的假设置）。
    final wantQuality = SettingsStore.instance.audioQuality.value;
    // **本地优先**：已下载的歌直接播沙盒里的文件 —— 不走网络解析。
    // 这样"下载"才真的有用（离线能听），也省掉一次接口往返。
    // 放在解析**之前**是关键：否则离线/取不到地址时会提前 return，本地文件永远播不到。
    final dl = MusicDownloadService.instance.bySong(song);
    final localPath =
        (dl != null && dl.status == MusicDownloadStatus.done && dl.path.isNotEmpty)
            ? dl.path
            : '';
    // 第三方音源要用**它自己配的** headers（UA/Referer/Cookie）。
    Map<String, String> sourceHeaders = const {};
    // 这次是不是靠"平台固定源"拿到了地址
    var fromBound = false;
    // 本轮试过的固定源 id（全源回退时排除，不重复试）
    var triedBoundIds = <String>{};

    // ── 直链优先（博看听书等纯 Dart 数据源）──────────────────────
    // `bookanAlbum()` 已经把单集 `file` 直链填进 `Song.directUrl`，
    // 本地文件之下、记忆/内置/第三方之上直接播 —— 不查任何取址链路。
    // UA 是博看服务端要求的，必须带（否则 403 / 空流）。
    // 一五听书的 `directUrl` 是**章节页 URL**（HTML），需先由
    // `ting15Resolve()` 解析出真实音频直链再播。
    final direct = localPath.isEmpty && song.directUrl.isNotEmpty;
    // 一五听书的 `directUrl` 是**章节页 URL**（HTML），先解析成真实音频直链
    MusicUrlInfo? directResolved;
    if (direct) {
      if (song.source == SongSource.ting15) {
        directResolved = await MusicApi.instance.ting15Resolve(song.directUrl);
        if (directResolved!.ok && directResolved.url.isNotEmpty) {
          sourceHeaders = directResolved.headers;
        }
      } else {
        sourceHeaders = song.directHeaders;
      }
    }


    // ══════════════════════════════════════════════════════════
    // ② 试**平台固定源**（设置页「音乐源」给平台绑定的第三方源，可多个）
    // ══════════════════════════════════════════════════════════
    //
    // 2026-10-10 用户需求："例如酷狗或 QQ 增加固定的第三方源设置，
    // 自动直接用这个第三方源"。绑定关系存 `SettingsStore`（平台 → 源 id 列表）。
    // 2026-10-11 升级：一个平台可绑多个源，按绑定顺序逐个先试。
    //
    // ── 为什么命中也要**当场验证**（原"记忆验证"同因）────────────
    // 第三方源给的地址是签名限时的，会过期成 403/404 —— 所以每次
    // 都要重新向它要新地址，"现在还能不能给"必须当场问一次。
    //
    // ⚠️ **本地文件优先于固定源**：已下载的歌直接播本地文件，
    //    不为固定源白跑一次网络请求（离线时那次请求还会失败）。
    if (localPath.isEmpty && SettingsStore.instance.useThirdPartySources.value) {
      final boundIds = SettingsStore.instance.boundSourceIdsFor(song.source);
      // 提到外层：全源回退 resolveAll 时要排除这批刚试过的固定源
      triedBoundIds = boundIds.toSet();
      if (boundIds.isNotEmpty) {
        final enabled = ThirdPartySourceStore.instance.enabled;
        // 按绑定顺序逐个试，第一个给出地址的直接用（不弹窗——这就是"固定"的意义）
        for (final boundId in boundIds) {
          ThirdPartySource? bound;
          for (final s in enabled) {
            if (s.id == boundId) {
              bound = s;
              break;
            }
          }
          if (bound == null) continue; // 源被删/被禁用，跳过
          lastError.value = '正在用「${bound.name}」…';
          final one = await UnblockService.instance.testOne(bound, song);
          switching.value = false;
          if (epoch != _loadEpoch) return;
          if (one.ok && one.url.isNotEmpty) {
            url = one.url;
            fromSource = one.source?.name ?? bound.name;
            quality = one.source?.quality ?? '';
            sourceHeaders =
                one.headers.isNotEmpty ? one.headers : (one.source?.headers ?? const {});
            fromBound = true;
            AppLog.instance.log(
                '[Music] 命中平台固定源（${song.source.displayName}）：'
                '《${song.name}》→「${bound.name}」');
            break;
          } else {
            // 这个绑定源这次给不出地址（后端变了/歌下架了）→ 试下一个绑定源，
            // 全失败则落回内置接口，不解绑（用户觉得不行会自己去设置页换）
            AppLog.instance.log('[Music] 平台固定源失败（${bound.name}：'
                '${one.error}），尝试下一个绑定源/内置接口');
          }
        }
      }
    }

    // 固定源已命中（fromBound）：url/headers/quality 已在上方就位。
    // 这里用失败占位**跳过内置接口请求**——绝不能真去请求内置，
    // 否则内置的慢直链/失败会把固定源的好地址盖掉。
    // 占位 ok=false 不会误进失败分支：下方回退块是 `else if (!fromBound)`，
    // fromBound 时整块跳过，直接落到底部 _startPlayback 播固定源的地址。
    // （🔴 之前回退块条件没排除 fromBound，固定源命中反而落进
    //    「内置接口取地址失败」报错分支 —— 这就是"固定了能播的源
    //    却完全没生效"的根因。）
    final r = fromBound
        ? MusicUrlInfo(ok: false, url: '', type: '')
        : (localPath.isNotEmpty
            ? MusicUrlInfo(ok: true, url: localPath, type: '本地')
            : (direct
                ? (directResolved ??
                    MusicUrlInfo(ok: true, url: song.directUrl, type: '博看'))
                : await MusicApi.instance
                    .songUrl(song.id, quality: wantQuality, source: song.source)));
    if (epoch != _loadEpoch) return; // 已被更新的点歌取代，丢弃本次结果
    if (r.ok && r.url.isNotEmpty) {
      url = r.url;
      quality = r.qualityText;
      // 直链命中时补源名（否则播放器下方"来源"是空的）
      if (direct) fromSource = song.source.displayName;
    } else if (!fromBound) {
      final builtinMsg = r.noFreeSource
          ? '内置接口没有免费音源'
          : (r.message.isNotEmpty ? r.message : '内置接口取地址失败');
      // ══════════════════════════════════════════════════════════
      // ② 没命中 → 回退：**试全部第三方音源 → 弹窗让用户选**
      // ══════════════════════════════════════════════════════════
      //
      // ── 为什么是"用户选"而不是"程序挑第一个"（用户 2026 决定）────
      // 实测：**同一个音源对不同歌的可用性差别很大**，而且多个源都能播时
      // 它们往往**不是同一个版本/音质**（一个 320K 一个 128K，一个原版
      // 一个 Live）。程序"挑第一个成功的"等于替用户做了他更清楚的选择。
      //
      // 所以：全试一遍 → 全列出来 → 用户点哪个放哪个。
      //
      // ⚠️ 跨平台匹配（CrossPlatformMatcher）已**移除出回退链**：
      //    用户明确说"不要搜索其他平台"。实现代码保留在
      //    `cross_platform_matcher.dart`，但这里不再调用。
      if (!fromBound &&
          SettingsStore.instance.useThirdPartySources.value &&
          ThirdPartySourceStore.instance.enabled.isNotEmpty) {
        switching.value = true;
        notifyListeners();
        final results = await UnblockService.instance.resolveAll(
          song,
          // 固定源刚试过的不再重复试（它们这一轮都给不出地址）
          excludeIds: triedBoundIds.isEmpty ? null : triedBoundIds,
          onProgress: (done, total) {
            // 全试要几秒，必须反馈进度，否则用户以为卡死了
            lastError.value = '正在试音源 $done/$total…';
          },
        );
        switching.value = false;
        if (epoch != _loadEpoch) return; // 期间用户又点了别的歌

        if (results.isNotEmpty) {
          // 2026-10-12 用户：固定源失败后其余源试完**弹窗让我选**，
          // 不要自动直出第一个（同一个源对不同歌可用性差别大，用户自己挑）。
          // 只有没有弹窗 context（冷启动/耳机线控）时才自动用第一个可用源。
          final ctx = _pickerCtxOrNull;
          if (ctx == null) {
            final first = results.first;
            AppLog.instance.log(
                '[Music] 无弹窗 context → 直接用第一个可用源：${first.source?.name}'
                '（${results.length} 个可用）');
            // 让用户知道这次没走固定源、实际用了谁；开播成功后会被清掉
            lastError.value = '固定源暂不可用，已改用「${first.source?.name ?? ''}」';
            // `playResolved` 内部会 remember + 开播（含歌词/最近播放/落盘）
            await playResolved(song, first);
            return;
          }

          // ── 弹窗让用户选 ────────────────────────────────────
          //
          // ⚠️ 只有一条时**照样弹** —— 让用户知道"这首歌是靠哪个源播的"，
          // 而不是莫名其妙开始播放（源出问题时这个信息很关键）。
          //
          // 🔴 **弹窗内部已经负责播放了**（点任意一行就立刻用那个源播，
          //    而且弹窗**不关**，可以接着换源试 —— 见 source_picker_sheet）。
          //    所以这里**拿到结果后不能再播一次**，否则会：
          //      · 白重开一次音频（听感上会闪一下/重头开始）
          //      · 用户"换源试听"时最后一首被覆盖成第一次选的
          //
          //    这里只负责**记录最终选定的源**（用于 qualityText 展示与日志），
          //    然后正常收尾（歌词已经在 `_startPlayback` 里取过了）。
          final picked = await SourcePickerSheet.show(
            ctx,
            song: song,
            results: results,
            failedNote: _failedSummary(song, results.length),
          );
          if (epoch != _loadEpoch) return;

          if (picked != null) {
            fromSource = picked.source?.name ?? '';
            quality = picked.source?.quality ?? '';
            // 2026-10-10：歌曲粒度源记忆已移除（改为平台固定源绑定）
            AppLog.instance.log('[Music] 用户选定音源：${picked.source?.name}'
                '（${results.length} 个可用）');
            // 展示用文案跟上（音频已由弹窗播好）
            qualityText.value = fromSource.isNotEmpty
                ? (quality.isEmpty ? fromSource : '$quality · $fromSource')
                : quality;
            switching.value = false;
            notifyListeners();
            return;
          }

          // 用户**一个源都没选**就关掉了弹窗 —— 这是正常操作，不该报错。
          // ⚠️ 但也可能是"**已经换源播过、最后点了取消**"（`_picked` 为 null
          //    只表示"最后一次点击没选中"，不代表没播过）——
          //    所以这里**不能停掉音频**，只安静收场。
          AppLog.instance.log('[Music] 用户关闭了音源选择（${song.name}，'
              '${results.length} 个可用）');
          switching.value = false;
          notifyListeners();
          return;
        } else {
          // 所有源都失败：把「内置为什么失败」+「每个源为什么失败」说清楚
          final detail = UnblockService.instance.describeFailureFor(song);
          final full = detail.isEmpty ? builtinMsg : '$builtinMsg；$detail';
          // ⚠️ 完整原因**必须**进日志：toast 会把长文本截断
          AppLog.instance.log('[Music] 取播放地址失败（${song.name}）: $full');
          // ⚠️ `ValueNotifier` **只在值变化时通知** → 连续两首同类失败时
          // 文案一模一样 → 监听器不被调用 → **用户什么都看不到** ✗
          // 用一个**不可见**后缀强制"值必变"（两次交替，永远不相等）。
          lastError.value = full == lastError.value ? '$full ' : full;
          await _silenceForFailure(song);
          notifyListeners();
          return;
        }
      } else {
        // 没有可用音源时，明确告知 —— 这是正常业务结果（VIP/独家），不是异常。
        // 🔴 按"为什么没走第三方源回退"区分原因（用户 2026-10-11：内置失败后
        //    只看到"内置接口取地址失败"，以为没有自动走第三方源的逻辑）：
        //    总开关关了 / 一个启用的源都没有，两种情况各给可操作提示。
        final thirdPartyOn =
            SettingsStore.instance.useThirdPartySources.value;
        final enabledCount = ThirdPartySourceStore.instance.enabled.length;
        final String msg;
        if (!thirdPartyOn) {
          msg = '内置接口取地址失败；「使用第三方音源」开关已关闭，'
              '去音乐「我的」页打开后会自动重试全部音源';
        } else if (enabledCount == 0) {
          msg = '内置接口取地址失败；还没有已启用的第三方音源，'
              '去音乐「我的 → 音乐源管理」添加/启用后会自动试播';
        } else {
          msg = r.noFreeSource ? '这首没有免费音源（可能需要会员）' : builtinMsg;
        }
        AppLog.instance.log('[Music] 取播放地址失败（${song.name}）: $msg'
            '（导入的音乐源开关=$thirdPartyOn，'
            '已启用 $enabledCount 个）');
        // 同一条失败连续出现时也要能弹（见上面那段注释）
        lastError.value = msg == lastError.value ? '$msg ' : msg;
        await _silenceForFailure(song);
        notifyListeners();
        return;
      }
    }

    // 上面两种失败分支都 `return` 了 → 到这里一定拿得到 url
    await _startPlayback(
      song: song,
      url: url,
      // ── ⚠️ 顺序：**源自己的 headers 优先** ──────────────────────
      //
      // 原来写的是 `r.headers.isNotEmpty ? r.headers : sourceHeaders` ——
      // 而 `r` 是**内置接口**的结果。记忆命中时 `r` 是个占位失败对象
      //（headers 为空）还看不出问题；但只要内置接口回了个非空 headers，
      // 就会把**源自己的签名头盖掉** → "地址拿到了但播不了"（403/空流）。
      //
      // 第三方源（尤其 MusicFree 插件）的地址**必须带它给的 headers**。
      headers: sourceHeaders.isNotEmpty ? sourceHeaders : r.headers,
      fromSource: fromSource,
      quality: quality,
      autoplay: autoplay,
      epoch: epoch,
    );
  }

  /// 用**选源弹窗里已经解析好的那个源**播放当前歌。
  ///
  /// ── 为什么需要这个公开方法 ────────────────────────────────────
  /// 选源弹窗现在是"点了就播、弹窗**不关**、可以接着换源试"。
  /// 每次换源都必须**立刻出声**，而且**不能再解析一遍**
  ///（地址已经在手上，重跑 `resolveAll` 要几秒）。
  ///
  /// 所以弹窗直接调这里 —— 它只做"把音频换成这个地址"。
  /// 注意：**不校验代次**（换源是用户当前意图，不是过期的旧请求）。
  Future<void> playResolved(Song song, SourceResolveResult r) async {
    await init();
    // 让 UI 的"当前歌"立刻跟上（万一用户是从别处点进来的）
    if (_queue.isEmpty ||
        _index >= _queue.length ||
        _queue[_index].identityKey != song.identityKey) {
      _queue
        ..clear()
        ..add(song);
      _index = 0;
      _currentSong = song;
      notifyListeners();
    }
    // 2026-10-10：歌曲粒度源记忆已移除（改为平台固定源绑定）
    await _startPlayback(
      song: song,
      url: r.url,
      // 🔴 必须把源自己配的 headers 带上：很多源不带 UA/Referer/Cookie
      // 就只给空流（表现是"地址拿到了但播不了"）。
      headers:
          r.headers.isNotEmpty ? r.headers : (r.source?.headers ?? const {}),
      fromSource: r.source?.name ?? '',
      quality: r.source?.quality ?? '',
      autoplay: true,
      epoch: null,
    );
  }

  /// 用**已经解析好的地址**开播（开播放器 → 取歌词 → 记最近播放）。
  ///
  /// ── 为什么抽出来单独一个方法（用户 2026 要求）──────────────────
  /// 选音源弹窗改成了"**点了就播、弹窗不关**、可以接着换源试"。
  /// 换源时若走 `_load()`，会把**整条解析链再跑一遍**
  ///（内置接口 + `resolveAll` 试全部源，要几秒），而我们**已经有地址了** ——
  /// 纯粹浪费，而且会让"换着试"很卡。
  ///
  /// 所以这里只做"把音频换成这个地址" + 配套收尾，**不做任何解析**。
  ///
  /// [epoch] 传 null = "不是某次 `_load` 的一部分"（弹窗换源就是这种），
  /// 此时不做代次校验 —— 换源本身就是用户当前的意图。
  Future<void> _startPlayback({
    required Song song,
    required String url,
    required Map<String, String> headers,
    required String fromSource,
    required String quality,
    required bool autoplay,
    required int? epoch,
  }) async {
    // 代次校验的封装：`epoch == null`（换源路径）时永远通过
    bool stale() => epoch != null && epoch != _loadEpoch;

    // 真正拿到地址开播 → 清掉沿途的进度/兜底提示
    //（"正在试音源 n/N"、"固定源暂不可用，已改用…" 都不该留在播放页）
    lastError.value = '';

    qualityText.value = fromSource.isNotEmpty
        ? (quality.isEmpty ? fromSource : '$quality · $fromSource')
        : quality;
    notifyListeners();

    // 2) 播放
    try {
      // 音乐要出声了 → 让影视/直播先闭嘴（互斥的核心：
      // 看视频时音乐还在响 / 听音乐时点视频两边一起响，都是缺这一步）
      if (autoplay) await AudioFocus.request('music');
      // ⚠️ **必须把 headers 透传给播放器**：喜马拉雅的直链没有 User-Agent
      // 会被服务端拒（表现是"地址拿到了但播不了"）。
      await _player.open(Media(url, httpHeaders: headers), play: autoplay);
    } catch (e, st) {
      // #15：**不要把异常 toString 直接给用户看** ——
      // 它可能包含堆栈、完整 URL、内部实现细节（用户看不懂，也不该看到）。
      // 技术细节只写日志（方便排查），界面给可读的提示。
      if (stale()) return;
      AppLog.instance.log('[Music] 播放失败 url=$url err=$e\n$st');
      lastError.value = _friendlyPlayError(e);
      await _silenceForFailure(song);
      return;
    }

    // 到这里音频已经换成这首歌了；若期间用户又点了别的歌，本次的收尾
    //（歌词 / 最近播放 / 队列落盘）就不该再执行
    if (stale()) return;

    // 3) 取歌词（失败不影响播放）。歌词也要按**这首歌自己的平台**取。
    unawaited(_loadLyric(song.id, song.source));

    // #4：记入最近播放（新的在前、按 identityKey 去重、上限 100）。
    // 放在"真正开始播"之后 —— 只是点开列表不算听过。
    // 不 await：本地写盘不该拖慢起播。
    unawaited(MusicLibraryStore.instance.addRecent(song));
    // #11：队列变化时持久化，下次启动恢复
    unawaited(MusicLibraryStore.instance.saveQueue(_queue, _index));
  }

  /// 取歌词。**必须带代次校验** —— `_load` 里别处都做了"await 后丢弃过期结果"，
  /// 只有这一处漏了：快速点 A→B 时，A 的歌词慢回来会把 B 的界面覆盖掉
  ///（表现就是"**歌词串到上一首**"，而且不会自愈）。
  ///
  /// 默认参数取**调用瞬间**的 `_loadEpoch`，所以调用点不用改。
  Future<void> _loadLyric(int id, SongSource source, [int? epoch]) async {
    final mine = epoch ?? _loadEpoch;
    try {
      final l = await MusicApi.instance.lyric(id, source: source);
      if (mine != _loadEpoch) return; // 已经切歌 → 丢弃这次结果
      if (l == null) return;
      // #9：**优先逐字歌词（YRC）**，拿不到再回落到标准 LRC。
      // 两条路的 `LyricLine.text` 都是一行原文，
      // 所以 UI 侧不用关心用的是哪种 —— 只看 `hasWords` 决定要不要逐字高亮。
      final yrc = LyricParser.parseYrc(l.yrc);
      lyrics.value = yrc.isNotEmpty
          ? yrc
          : LyricParser.parse(l.lyric, translation: l.translation);
      lyricIndex.value = LyricParser.indexAt(
        lyrics.value,
        position.value + Duration(milliseconds: lyricOffset.value),
      );
    } catch (e) {
      // 歌词拿不到不打扰用户（不弹窗），但**要能查**：
      // 否则"所有歌都没歌词"这种系统性故障完全不可排查。
      AppLog.instance.log('[Music] 歌词获取失败 id=$id: $e');
    }
  }

  // ============================================================
  // 控制
  // ============================================================

  Future<void> toggle() async {
    await init();
    if (_currentSong == null) return;
    await _player.playOrPause();
  }

  Future<void> pause() async {
    await init();
    await _player.pause();
  }

  Future<void> resume() async {
    await init();
    await AudioFocus.request('music');
    await _player.play();
  }

  /// 下一首。[auto] = 自动切歌（单曲循环时不切）
  Future<void> next({bool auto = false}) async {
    await init();
    if (_queue.isEmpty) return;
    if (auto && mode.value == PlayMode.single) {
      await _load(_index, autoplay: true);
      return;
    }
    if (mode.value == PlayMode.shuffle && _queue.length > 1) {
      var n = _index;
      while (n == _index) {
        n = DateTime.now().microsecondsSinceEpoch % _queue.length;
      }
      await _load(n, autoplay: true);
      return;
    }
    final n = _index + 1;
    if (n >= _queue.length) {
      if (auto && mode.value == PlayMode.list) {
        await _load(0, autoplay: true);
      }
      return;
    }
    await _load(n, autoplay: true);
  }

  Future<void> previous() async {
    await init();
    if (_queue.isEmpty) return;
    // 播放超过 3 秒 → 先回到本曲开头（和主流播放器一致）
    if (position.value.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final p = _index - 1;
    await _load(p < 0 ? _queue.length - 1 : p, autoplay: true);
  }

  Future<void> jumpTo(int index) async {
    await init();
    if (index < 0 || index >= _queue.length) return;
    await _load(index, autoplay: true);
  }

  Future<void> seek(Duration d) async {
    await init();
    await _player.seek(d);
  }

  /// 相对拖动（±15 秒）
  Future<void> seekBy(Duration delta) async {
    final target = position.value + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  /// 把异常翻译成用户能看懂的话（#15）。
  ///
  /// 异常对象**不进 UI** —— 只用于判断归类，原文写日志。
  String _friendlyPlayError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socket') ||
        s.contains('connection') ||
        s.contains('network') ||
        s.contains('timed out')) {
      return '网络连接失败，请检查网络后重试';
    }
    if (s.contains('404') || s.contains('403') || s.contains('not found')) {
      return '这首歌暂时无法播放（可能已下架或需要会员）';
    }
    if (s.contains('format') || s.contains('codec') || s.contains('decode')) {
      return '音频格式不支持，换一首试试';
    }
    return '播放失败，请重试或换一首';
  }

  Future<void> setVolume(double v) async {
    await init();
    volume.value = v.clamp(0, 100);
    await _player.setVolume(volume.value);
  }

  void setMode(PlayMode m) {
    mode.value = m;
    notifyListeners();
  }

  void cycleMode() {
    final all = PlayMode.values;
    setMode(all[(all.indexOf(mode.value) + 1) % all.length]);
  }
  /// 设置歌词偏移并立刻重算高亮
  void setLyricOffset(int ms) {
    lyricOffset.value = ms;
    lyricIndex.value = LyricParser.indexAt(
      lyrics.value,
      position.value + Duration(milliseconds: ms),
    );
  }

  bool isCurrent(Song s) => _currentSong?.identityKey == s.identityKey;

  @override
  void dispose() {
    AudioFocus.unregister('music');
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _bufSub?.cancel();
    _compSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
