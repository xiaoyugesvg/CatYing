//
//  ExceptionGuard.h
//  在 Swift 里安全调用"可能抛 Objective-C 异常"的 API
//
//  ── 为什么需要这个文件 ──────────────────────────────────────────
//  AVFoundation 的部分 API（典型是 `-[AVAudioPlayerNode play]`、
//  `-[AVAudioEngine startAndReturnError:]` 之外的内部路径）在音频会话
//  状态不合法时，会 **抛出 Objective-C 异常**（`AVAE_RaiseException`）。
//
//  **Swift 无法 catch Objective-C 异常**：异常会沿调用栈冒泡到
//  `std::terminate` → `abort()`，进程直接 SIGABRT，没有任何补救机会。
//  实测崩溃日志（Runner-*.ips）：
//      exception  : EXC_CRASH (SIGABRT)
//      termination: Abort trap: 6
//      AVAE_RaiseException
//      AVAudioPlayerNodeImpl::StartImpl
//      -[AVAudioPlayerNode play]
//      BackgroundAudio.handleInterruption(_:)
//
//  因此"先检查 isRunning / setActive 成功"这类防御**都不够**：
//  会话被系统停用后，引擎仍可能报告 running，此时 play() 照样抛异常。
//  唯一可靠的办法就是在 Objective-C 里用 @try/@catch 把它兜住 ——
//  这个文件就是这层兜底。
//
//  ── 使用方式 ──────────────────────────────────────────────────
//      if (!TvBoxTryCatch(^{ [self.player play]; })) {
//          NSLog(@"play 抛异常了，忽略");
//      }
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行 block，捕获其中抛出的 NSException。
///
/// @param block 要执行的代码，不能为 nil
/// @return YES = 正常执行完；NO = 中途抛了 Objective-C 异常（已被吞掉）
///
/// 注意：只用于"失败可忽略"的路径（后台保活音频这类）。
/// 不要用它掩盖真正的逻辑错误。
///
/// ⚠️ 不加 NS_NOESCAPE：它在旧版 Xcode 上不存在，会直接编译失败。
/// 这个函数只在同步路径上用，escape 与否对行为没有影响。
FOUNDATION_EXPORT BOOL TvBoxTryCatch(void (^block)(void));

NS_ASSUME_NONNULL_END
