#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 全局开关（由设置页修改，hook 中原子读取）
extern bool PMAutoPlay;
extern bool PMAllPerfect;
extern bool PMLockHP;
extern bool PMShowLifeBar;
extern bool PMUnlockAll;
extern bool PMPaidUnlock;
extern bool PMUnlockCollection;
extern bool PMUnlockCharacters;
extern bool PMUnlockSkins;
extern bool PMUnlockRelics;
extern bool PMUnlockStories;
extern bool PMUnlockTitles;
extern bool PMUnlockBackgrounds;
extern bool PMUnlockChallenges;
extern bool PMBlockUpload;
extern float PMSpeed;
extern float PMHitVolumeBoost;
extern bool PMAutoHideInGame;

// 最近一次判定帧（用于判断是否在游玩中）
extern volatile double PMLastGameplayTick;

// 个人资料：仅本地显示覆盖（不写存档、不上传）
extern bool PMProfileEnabled;
extern NSMutableDictionary<NSString *, NSString *> *PMProfileText;
// 取覆盖值，未配置返回 nil
NSString *PMProfileValue(NSString *key);

// 悬浮球
extern bool PMBallVisible;
extern bool PMBallHidden;   // 完全隐藏（连边缘小点也不显示）
extern float PMBallAlpha;
extern float PMBallSize;

// 诊断
extern volatile int PMLastSlotCount;
extern volatile int PMAutoJudged;
extern volatile bool PMHookReady;
extern volatile bool PMHookFailed;
extern volatile bool PMIl2CppReady;
extern volatile bool PMUnlockAllApplied;
extern volatile int PMUploadBlocked;

void PMLog(NSString *fmt, ...);
void PMLogInstallCrashHandler(void);
void PMLogReset(void);
NSString *PMLogTail(NSUInteger maxLines);
void PMLogClear(void);
int PMUnityCryptid(void);
NSString *PMUnityUUIDString(void);
void *PMUnityBase(void);
void PMInstallHooks(void);
void PMApplySettingsNow(void);
void PMStartRuntimeFeatures(void);

void PMShowOverlay(void);
void PMUpdateOverlay(void);
void PMUpdateBall(void);
// 官方「Mod设置」里的「修改」行：弹出系统输入框改资料 / 悬浮球参数
void PMPromptForModValue(NSString *key);
void PMSetModEntryVisible(bool visible);
// screenRect 为 Unity 屏幕坐标（左下原点），由 Overlay 转成 UIKit 坐标
void PMSetModEntryRect(CGRect screenRect);

#ifdef __cplusplus
}
#endif
