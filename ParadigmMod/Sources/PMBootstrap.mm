//
//  ParadigmMod 入口：dylib 构造时启动，等 Unity/il2cpp 就绪后安装 Hook、悬浮球与周期任务
//

#import "PMCommon.h"

static dispatch_source_t gTimer = NULL;

__attribute__((constructor))
static void PMBootstrap(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    PMAutoPlay    = [d objectForKey:@"pm.auto"]   ? [d boolForKey:@"pm.auto"]   : YES;
    PMAllPerfect  = [d boolForKey:@"pm.ap"];
    PMLockHP      = [d boolForKey:@"pm.hp"];
    PMUnlockAll   = [d boolForKey:@"pm.unlock"];
    PMBlockUpload = [d boolForKey:@"pm.block"];
    PMSpeed       = [d objectForKey:@"pm.speed"]  ? [d floatForKey:@"pm.speed"] : 1.0f;

    PMLog(@"dylib 已加载（4.13 基线），autoplay=%d ap=%d hp=%d unlock=%d block=%d speed=%.2f",
          PMAutoPlay, PMAllPerfect, PMLockHP, PMUnlockAll, PMBlockUpload, PMSpeed);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 90; i++) {
            @autoreleasepool {
                if (PMUnityBase()) {
                    PMInstallHooks();
                    if (PMHookReady) break;
                }
            }
            [NSThread sleepForTimeInterval:1.0];
        }

        // 静态字段（全解锁 / 变速）需要周期性重写
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 1500ull * NSEC_PER_MSEC, 200ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            PMApplySettingsNow();
        });
        dispatch_resume(t);
        gTimer = t;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMShowOverlay();
        });
    });
}
