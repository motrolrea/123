//
//  ParadigmMod 入口：dylib 构造时启动，等 Unity/il2cpp 就绪后安装 Hook、悬浮球与周期任务
//

#import "PMCommon.h"

static dispatch_source_t gTimer = NULL;

__attribute__((constructor))
static void PMBootstrap(void) {
    PMLogInstallCrashHandler();
    NSBundle *bundle = [NSBundle mainBundle];
    PMLog(@"启动: %@ %@ (%@)", bundle.bundleIdentifier,
          [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
          [bundle objectForInfoDictionaryKey:@"CFBundleVersion"]);

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    PMAutoPlay    = [d objectForKey:@"pm.auto"]   ? [d boolForKey:@"pm.auto"]   : YES;
    PMAllPerfect  = [d boolForKey:@"pm.ap"];
    PMLockHP      = [d boolForKey:@"pm.hp"];
    PMUnlockAll   = [d boolForKey:@"pm.unlock"];
    PMPaidUnlock  = [d boolForKey:@"pm.paid"];
    PMUnlockCollection = [d boolForKey:@"pm.coll"];
    PMBlockUpload = [d boolForKey:@"pm.block"];
    PMSpeed       = [d objectForKey:@"pm.speed"]  ? [d floatForKey:@"pm.speed"] : 1.0f;

    PMLog(@"dylib 已加载（4.13 基线），autoplay=%d ap=%d hp=%d unlock=%d paid=%d block=%d speed=%.2f",
          PMAutoPlay, PMAllPerfect, PMLockHP, PMUnlockAll, PMPaidUnlock, PMBlockUpload, PMSpeed);

    dispatch_async(dispatch_get_main_queue(), ^{
        // 悬浮球独立于 hook 安装，先显示出来
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMShowOverlay();
        });
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 90; i++) {
            @autoreleasepool {
                if (PMUnityBase()) {
                    // il2cpp 的 class/domain API 必须在 Unity 主线程调用
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        PMInstallHooks();
                    });
                    if (PMHookReady) break;
                }
            }
            [NSThread sleepForTimeInterval:1.0];
        }
        PMLog(@"hook 安装结束: ready=%d cryptid=%d", PMHookReady, PMUnityCryptid());

        // 静态字段（全解锁 / 变速）需要周期性重写
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 1500ull * NSEC_PER_MSEC, 200ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            PMApplySettingsNow();
        });
        dispatch_resume(t);
        gTimer = t;
    });
}
