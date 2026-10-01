import 'package:get/get.dart';

/// 标记"当前是否停在影视详情页"。
///
/// ── 为什么需要它 ──────────────────────────────────────────────
/// 悬浮导航栏是**在 `app.dart` 的 body Stack 里全局渲染的**
/// （不是每个页面自己画），所以"详情页不显示底栏"这件事
/// 必须在那个全局判断里能知道"现在在不在详情页"。
///
/// ── 为什么不用 `Get.routing.current` ──────────────────────────
/// 试过：`Get.routing.current` 是 **普通 String，不是 Rx**。
/// 在 `Obx` 里读它**不会建立依赖**，路由变化时底栏不重建 ——
/// 表现为"进了详情页底栏还挂着"（要等别的原因触发重建才消失）。
/// 所以必须用一个真正的响应式标志。
///
/// ── 生命周期怎么保证不漏 ──────────────────────────────────────
/// `DetailPage.initState` 置 true、`dispose` 置 false。
/// dispose 一定会被调用（包括返回、被替换、App 销毁），
/// 所以不会出现"退了详情页底栏还藏着"的残留。
/// 若改用路由回调（GetObserver）也能做，但要额外注册观察者，
/// 而详情页自己就是最准的"在不在"信号源。
///
/// 用引用计数而不是 bool：详情页可能出现"A 上叠 B"（从详情页里
/// 点另一个视频再进详情页）的情况。用 bool 时 B 的 dispose 会先把
/// 标志清掉，于是 A 还在前台、底栏却冒出来了。计数就不会。
class DetailPageController extends GetxController {
  static DetailPageController get instance => Get.find();

  /// 打开的详情页层数（>0 = 详情页在前台）
  final _depth = 0.obs;

  /// true = 有详情页在前台（app.dart 用它隐藏底栏）
  bool get isOpen => _depth.value > 0;

  /// 响应式入口，供 `Obx` 建立依赖
  int get depth => _depth.value;

  void enter() => _depth.value = _depth.value + 1;

  void exit() {
    // 防负：dispose 与 enter 不配对时（理论上不会）也不会把计数弄成负数，
    // 否则后续所有判断都会失效
    if (_depth.value > 0) _depth.value = _depth.value - 1;
  }
}
