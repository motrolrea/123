#pragma once
#import <Foundation/Foundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 全局开关（由设置页修改，hook 中原子读取）
extern bool PMAutoPlay;
extern bool PMAllPerfect;
extern bool PMLockHP;
extern bool PMUnlockAll;
extern bool PMPaidUnlock;
extern bool PMUnlockCollection;
extern bool PMBlockUpload;
extern float PMSpeed;

// 诊断
extern volatile int PMLastSlotCount;
extern volatile int PMAutoJudged;
extern volatile bool PMHookReady;
extern volatile bool PMIl2CppReady;
extern volatile bool PMUnlockAllApplied;
extern volatile int PMUploadBlocked;

void PMLog(NSString *fmt, ...);
void PMLogInstallCrashHandler(void);
NSString *PMLogTail(NSUInteger maxLines);
void PMLogClear(void);
int PMUnityCryptid(void);
void *PMUnityBase(void);
void PMInstallHooks(void);
void PMApplySettingsNow(void);

void PMShowOverlay(void);
void PMUpdateOverlay(void);

#ifdef __cplusplus
}
#endif
