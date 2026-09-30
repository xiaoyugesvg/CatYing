//
//  ExceptionGuard.m
//  见 ExceptionGuard.h 的说明。
//

#import "ExceptionGuard.h"

BOOL TvBoxTryCatch(void (^block)(void)) {
    if (block == nil) {
        return YES;
    }
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        // 只记录，不上抛：调用方（后台保活音频）允许这次失败，
        // 绝不能让异常冒泡成 SIGABRT 把整个 App 带走。
        NSLog(@"[ExceptionGuard] 捕获 Objective-C 异常: %@ — %@",
              exception.name, exception.reason);
        return NO;
    }
}
