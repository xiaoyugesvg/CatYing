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
  BuildContext get _pickerCtx =>
      _pickerContext ?? VideoPlayerPip.navigatorKey.currentContext!;

  /// 失败摘要：告诉用户"试了 N 个源，M 个不行"。
  ///
  /// ⚠️ 只给**数量级**信息，不把 12 条错误全塞进弹窗
  ///（详情在 `UnblockService.lastAttempts`，失败时另有 toast/日志）。
  String _failedSummary(int okCount) {
    final failed = UnblockService.instance.lastAttempts.length;
    if (failed == 0) return '';
    return '另有 $failed 个音源试过但没拿到地址（详情见日志）';
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
      // "正在尝试音源 2/3：xxx" 这类是进度信息，用中性色；
      // 其余（无免费音源 / 播放失败）按错误显示。
      final isProgress = msg.startsWith('正在尝试音源');
      if (isProgress) {
        // 进度信息（"正在尝试音源 2/3：xxx"）用气泡就够了
        AppToast.show(msg, '', isError: false);
        return;
      }
      // 🔴 真错误 → **弹窗显示全文**：气泡是 `maxLines: 1`，会把
      // "内置接口没有免费音源；car_conv2: GD接口失败: …" 截断，
      // 而可排查的信息恰恰在后半段（用户反馈过"看不到完整的日志"）。
      AppToast.detail('播放失败', msg);
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
    // 顺序：**内置公开接口 → 用户导入的第三方音源**。
    // 内置接口能拿到绝大多数免费歌；拿不到时（VIP/独家/接口变动）
    // 才回退到音源，这样正常播放不会因为用户装了个坏源而变慢。
    var url = '';
    var quality = '';
    var fromSource = '';

    // ⚠️ 必须把用户在设置里选的音质传过去。
    // 之前是 `songUrl(song.id)` —— 它会退到默认 exhigh(320K)，
    // 于是"音质"设置能选能存却**从未生效**（典型的假设置）。
    final wantQuality = SettingsStore.instance.audioQuality.value;
    // ① **本地优先**：已下载的歌直接播沙盒里的文件 —— 不走网络解析。
    // 这样"下载"才真的有用（离线能听），也省掉一次接口往返。
    // 放在解析**之前**是关键：否则离线/取不到地址时会提前 return，本地文件永远播不到。
    final dl = MusicDownloadService.instance.bySong(song);
    final localPath =
        (dl != null && dl.status == MusicDownloadStatus.done && dl.path.isNotEmpty)
            ? dl.path
            : '';
    final r = localPath.isNotEmpty
        ? MusicUrlInfo(ok: true, url: localPath, type: '本地')
        : await MusicApi.instance
            .songUrl(song.id, quality: wantQuality, source: song.source);
    if (epoch != _loadEpoch) return; // 已被更新的点歌取代，丢弃本次结果
    // 第三方音源要用**它自己配的** headers（UA/Referer/Cookie）。
    // 在 if 分支里声明会出作用域，所以提到这里。
    Map<String, String> sourceHeaders = const {};
    if (r.ok && r.url.isNotEmpty) {
      url = r.url;
      quality = r.qualityText;
    } else {
      final builtinMsg = r.noFreeSource
          ? '内置接口没有免费音源'
          : (r.message.isNotEmpty ? r.message : '内置接口取地址失败');

      // ══════════════════════════════════════════════════════════
      // 回退：**试全部第三方音源 → 弹窗让用户选**
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
      if (SettingsStore.instance.useThirdPartySources.value &&
          ThirdPartySourceStore.instance.enabled.isNotEmpty) {
        switching.value = true;
        notifyListeners();
        final results = await UnblockService.instance.resolveAll(
          song,
          onProgress: (done, total) {
            // 全试要几秒，必须反馈进度，否则用户以为卡死了
            lastError.value = '正在试音源 $done/$total…';
          },
        );
        switching.value = false;
        if (epoch != _loadEpoch) return; // 期间用户又点了别的歌

        if (results.isNotEmpty) {
          // ── 弹窗让用户选 ────────────────────────────────────
          //
          // ⚠️ 只有一条时**照样弹** —— 让用户知道"这首歌是靠哪个源播的"，
          // 而不是莫名其妙开始播放（源出问题时这个信息很关键）。
          final picked = await SourcePickerSheet.show(
            _pickerCtx,
            song: song,
            results: results,
            failedNote: _failedSummary(results.length),
          );
          if (epoch != _loadEpoch) return;

          if (picked != null) {
            url = picked.url;
            fromSource = picked.source?.name ?? '';
            quality = picked.source?.quality ?? '';
            // 🔴 必须把源自己配的 headers 带上：很多源不带 UA/Referer/Cookie
            // 就只给空流（表现是"地址拿到了但播不了"）。
            // 优先用**解析时现返回的** headers（MusicFree 插件会按歌给签名）。
            sourceHeaders = picked.headers.isNotEmpty
                ? picked.headers
                : (picked.source?.headers ?? const {});
            AppLog.instance.log('[Music] 用户选择音源：${picked.source?.name}'
                '（${results.length} 个可用）');
          } else {
            // 用户主动取消 —— 这是**正常操作**，不该报错
            AppLog.instance.log('[Music] 用户取消了音源选择（${song.name}，'
                '${results.length} 个可用）');
            switching.value = false;
            notifyListeners();
            return;
          }
        } else {
          // 所有源都失败：把「内置为什么失败」+「每个源为什么失败」说清楚
          final detail = UnblockService.instance.describeFailure();
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
        // 没有可用音源时，明确告知 —— 这是正常业务结果（VIP/独家），不是异常
        final msg = r.noFreeSource ? '这首没有免费音源（可能需要会员）' : builtinMsg;
        AppLog.instance.log('[Music] 取播放地址失败（${song.name}）: $msg'
            '（导入的音乐源开关=${SettingsStore.instance.useThirdPartySources.value}，'
            '已启用 ${ThirdPartySourceStore.instance.enabled.length} 个）');
        // 同一条失败连续出现时也要能弹（见上面那段注释）
        lastError.value = msg == lastError.value ? '$msg ' : msg;
        await _silenceForFailure(song);
        notifyListeners();
        return;
      }
    }

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
      // 这里用 `r.headers`：第三方音源路径下 `r` 是内置接口的失败结果
      //（headers 为空），不会误传别人的头。
      await _player.open(
        // headers：内置接口带的（`r.headers`）优先；而第三方音源路径下 `r`
        // 是**失败的内置结果**（headers 为空）→ 这时用那个源自己配的 headers ✓
        Media(
          url,
          httpHeaders: r.headers.isNotEmpty ? r.headers : sourceHeaders,
        ),
        play: autoplay,
      );
    } catch (e, st) {
      // #15：**不要把异常 toString 直接给用户看** ——
      // 它可能包含堆栈、完整 URL、内部实现细节（用户看不懂，也不该看到）。
      // 技术细节只写日志（方便排查），界面给可读的提示。
      if (epoch != _loadEpoch) return;
      AppLog.instance.log('[Music] 播放失败 url=$url err=$e\n$st');
      lastError.value = _friendlyPlayError(e);
      await _silenceForFailure(song);
      return;
    }

    // 到这里音频已经换成这首歌了；若期间用户又点了别的歌，本次的收尾
    //（歌词 / 最近播放 / 队列落盘）就不该再执行
    if (epoch != _loadEpoch) return;

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
