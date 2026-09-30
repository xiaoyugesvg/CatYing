#import "GeneratedPluginRegistrant.h"

// NodeMobile 框架（来自 nodejs-mobile 项目）
// iOS 端 Node.js 嵌入方案的核心 API
// - node_start(int argc, char** argv) - 启动 Node.js 主循环（阻塞）
// pbxproj 必须 link NodeMobile.xcframework（由 ruby 脚本自动改）
#import <NodeMobile/NodeMobile.h>

// Objective-C 异常保护：Swift catch 不到 ObjC 异常，
// 后台保活音频调 AVAudioPlayerNode.play() 抛异常时会直接 SIGABRT。
// 通过这个桥接头把 TvBoxTryCatch() 暴露给 Swift。
#import "ExceptionGuard.h"
