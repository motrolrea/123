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
    PMShowLifeBar = [d objectForKey:@"pm.hp.bar"] ? [d boolForKey:@"pm.hp.bar"] : YES;
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

    dispatch_async(dispatch_get_main_queue(), ^{
        // 等 Unity 初始化完成一小会儿再启动轮询（不做任何 inline hook）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PMLog(@"启动运行时轮询 cryptid=%d uuid=%@", PMUnityCryptid(), PMUnityUUIDString());
            PMStartRuntimeFeatures();
        });
    });
}
