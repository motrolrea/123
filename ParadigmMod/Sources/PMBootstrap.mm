//
//  ParadigmMod 入口：dylib 构造时启动，等 Unity/il2cpp 就绪后安装 Hook、悬浮球与周期任务
//

#import "PMCommon.h"

static dispatch_source_t gTimer = NULL;

__attribute__((constructor))
static void PMBootstrap(void) {
    PMLogReset();              // 每次启动重新生成日志
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
    PMUnlockCharacters = [d boolForKey:@"pm.coll.char"];
    PMUnlockSkins = [d boolForKey:@"pm.coll.skin"];
    PMUnlockRelics = [d boolForKey:@"pm.coll.relic"];
    PMUnlockStories = [d boolForKey:@"pm.coll.story"];
    PMUnlockTitles = [d boolForKey:@"pm.coll.title"];
    PMUnlockBackgrounds = [d boolForKey:@"pm.coll.bg"];
    PMUnlockChallenges = [d boolForKey:@"pm.coll.challenge"];
    PMBlockUpload = [d boolForKey:@"pm.block"];
    PMSpeed       = 1.0f;   // 变速功能已移除
    PMHitVolumeBoost = [d objectForKey:@"pm.hitvol"] ? [d floatForKey:@"pm.hitvol"] : 1.0f;
    PMAutoHideInGame = [d objectForKey:@"pm.ball.auto"] ? [d boolForKey:@"pm.ball.auto"] : YES;
    PMBallVisible = [d objectForKey:@"pm.ball.show"] ? [d boolForKey:@"pm.ball.show"] : YES;
    PMBallAlpha   = [d objectForKey:@"pm.ball.alpha"] ? [d floatForKey:@"pm.ball.alpha"] : 0.85f;
    PMBallSize    = [d objectForKey:@"pm.ball.size"] ? [d floatForKey:@"pm.ball.size"] : 56.0f;
    if (PMBallSize < 40.0f || PMBallSize > 96.0f) PMBallSize = 56.0f;
    PMProfileEnabled = [d boolForKey:@"pm.profile.on"];

    // 个人资料本地覆盖值
    NSMutableDictionary<NSString *, NSString *> *profile = [NSMutableDictionary dictionary];
    NSArray<NSString *> *keys = @[@"id", @"level", @"rating", @"tracks", @"charts",
                                  @"playcount", @"playtime", @"totalscore", @"note", @"grades",
                                  @"alldecrypted", @"fullcombo", @"clear", @"infinity", @"aaa", @"aa"];
    for (NSString *k in keys) {
        NSString *v = [d stringForKey:[@"pm.profile." stringByAppendingString:k]];
        if (v.length) profile[k] = v;
    }
    PMProfileText = profile;

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
        // 等游戏完成启动再装 hook：避免开局阶段就调用到被改写的函数
        [NSThread sleepForTimeInterval:12.0];
        PMLog(@"延迟结束，开始安装 hook");
        for (int i = 0; i < 6; i++) {
            @autoreleasepool {
                if (PMUnityBase()) {
                    // il2cpp 的 class/domain API 必须在 Unity 主线程调用
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        PMInstallHooks();
                    });
                    if (PMHookReady || PMHookFailed) break;
                }
            }
            [NSThread sleepForTimeInterval:2.0];
        }
        PMLog(@"hook 安装结束: ready=%d failed=%d cryptid=%d uuid=%@",
              PMHookReady, PMHookFailed, PMUnityCryptid(), PMUnityUUIDString());

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
