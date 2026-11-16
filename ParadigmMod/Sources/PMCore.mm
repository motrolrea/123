#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE 1
//
//  ParadigmMod —— 《范式：起源》iOS 4.13 注入型 mod 核心
//  适用于已解密（cryptid=0）的 UnityFramework + 未签名 / TrollStore 安装环境
//
//  Hook 列表（RVA 来自 4.13 Il2CppDumper 转储，UUID 964f6391cd6c33788f84dd0aae540677）：
//    JudgeSystem.UpdateTime            0x12EAE08  AutoPlay
//    JudgeSlot.SetResult               0x12F37F0  全 Perfect（把 Received/Lost 改成 Decrypted）
//    GameControl.AddHP                 0x1079DC8  锁血（Lost 按 Decrypted 结算）
//    BackendAPI.Run(IEnumerator)       0x1331700  屏蔽成绩上传（拦截 ScoreUploadCoroutine）
//
//  静态字段：
//    TrackUnlockStorage.UnlockAll      全曲 / 全难度解锁
//    Chart.hiSpeedMultiplier           变速
//

#import "PMCommon.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <os/lock.h>
#include <math.h>
#include <ctype.h>
#include <libkern/OSCacheControl.h>
#include <signal.h>
#include <ucontext.h>
#include <fcntl.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 全局状态（悬浮球 / 设置页修改）
// ---------------------------------------------------------------------------
bool PMAutoPlay = true;
bool PMAllPerfect = false;
bool PMLockHP = false;
bool PMUnlockAll = false;
bool PMPaidUnlock = false;
bool PMUnlockCollection = false;
bool PMBlockUpload = false;
float PMSpeed = 1.0f;
float PMHitVolumeBoost = 1.0f;
bool PMAutoHideInGame = true;

bool PMUnlockCharacters = false;
bool PMUnlockSkins = false;
bool PMUnlockRelics = false;
bool PMUnlockStories = false;
bool PMUnlockTitles = false;
bool PMUnlockBackgrounds = false;
bool PMUnlockChallenges = false;

volatile double PMLastGameplayTick = 0;

bool PMProfileEnabled = false;
NSMutableDictionary<NSString *, NSString *> *PMProfileText = nil;

bool PMBallVisible = true;
float PMBallAlpha = 0.85f;
float PMBallSize = 56.0f;

NSString *PMProfileValue(NSString *key) {
    NSString *v = PMProfileText[key];
    if (!v.length) return nil;
    return v;
}

volatile int PMLastSlotCount = -1;
volatile int PMAutoJudged = 0;
volatile bool PMHookReady = false;
volatile bool PMHookFailed = false;
volatile bool PMIl2CppReady = false;
volatile bool PMUnlockAllApplied = false;
volatile int PMUploadBlocked = 0;

// 4.13 关键 RVA（文件偏移 == VM 地址，__TEXT vmaddr = 0）
static const uintptr_t kRVA_JudgeSystem_UpdateTime = 0x012EAE08;
static const uintptr_t kRVA_JudgeSlot_SetResult      = 0x012F37F0;
static const uintptr_t kRVA_GameControl_AddHP        = 0x01079DC8;
static const uintptr_t kRVA_BackendAPI_Run           = 0x01331700;
static const uintptr_t kRVA_Store_IsPurchasedStr     = 0x013644D0;
static const uintptr_t kRVA_Store_IsPurchasedEnum    = 0x01364574;
static const uintptr_t kRVA_PlayerHelper_IsRelic      = 0x0126263C;
static const uintptr_t kRVA_PlayerHelper_IsCharacter  = 0x012627C8;
static const uintptr_t kRVA_Challenge_IsUnlocked      = 0x0110FD9C;
static const uintptr_t kRVA_Achv_IsUnlockedEnum       = 0x0106BBF0;
static const uintptr_t kRVA_Achv_IsUnlockedStruct     = 0x0106BA48;
static const uintptr_t kRVA_Collection_RefreshData    = 0x01129D1C;
static const uintptr_t kRVA_Collection_RefreshDiff    = 0x0112AEDC;
static const uintptr_t kRVA_Collection_RefreshGrade   = 0x0112C938;
static const uintptr_t kRVA_PlayerInfo_UpdateOther    = 0x0116467C;
static const uintptr_t kRVA_PlayerInfo_UpdateRating   = 0x01163FC4;

// CollectionManager 文本字段偏移（4.13）
static const size_t kOff_CM_Id            = 0x20;
static const size_t kOff_CM_TotalPlayTime = 0x28;
static const size_t kOff_CM_TotalScore    = 0x30;
static const size_t kOff_CM_Story         = 0xC0;
static const size_t kOff_CM_Track         = 0xC8;
static const size_t kOff_CM_PlayCount     = 0xD0;
static const size_t kOff_CM_NoteDecrypted = 0xD8;
static const size_t kOff_CM_Chart         = 0xE0;
static const size_t kOff_CM_Character     = 0xE8;
static const size_t kOff_CM_Frame         = 0xF0;
static const size_t kOff_CM_Title         = 0xF8;
static const size_t kOff_CM_TitleScreen   = 0x100;
static const size_t kOff_CM_AllDecrypted  = 0x108;
static const size_t kOff_CM_FullCombo     = 0x110;
static const size_t kOff_CM_Clear         = 0x118;
static const size_t kOff_CM_Infinity      = 0x120;
static const size_t kOff_CM_AAA           = 0x128;
static const size_t kOff_CM_AA            = 0x130;
static const size_t kOff_CM_Rating        = 0x140;
static const size_t kOff_CM_Skin          = 0x170;

// PlayerInfoManager 文本字段偏移
static const size_t kOff_PI_Level      = 0x30;
static const size_t kOff_PI_Rating     = 0x40;
static const size_t kOff_PI_RatingSmall = 0x48;

// JudgeSystem / JudgeSlot / List 字段偏移
static const size_t kOff_JS_Slots = 0x10;
static const size_t kOff_JS_Time = 0x60;
static const size_t kOff_Slot_Result = 0x10;
static const size_t kOff_Slot_PerfectTime = 0x18;
static const size_t kOff_List_Items = 0x10;
static const size_t kOff_List_Size = 0x18;

static const int kJudgeUninitialized = 0;
static const int kJudgeUnjudge = 1;
static const int kJudgeDecrypted = 2;
static const int kJudgeReceived = 3;
static const int kJudgeLost = 4;

// ---------------------------------------------------------------------------
// 日志：NSLog + 文件（Documents/ParadigmMod.log，超过 2MB 自动清空）
// ---------------------------------------------------------------------------
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;
static NSString *gLogPath = nil;

static NSString *PMLogPath(void) {
    if (gLogPath) return gLogPath;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = dirs.count ? dirs[0] : NSTemporaryDirectory();
    gLogPath = [dir stringByAppendingPathComponent:@"ParadigmMod.log"];
    return gLogPath;
}

static void pm_log_write(NSString *line) {
    os_unfair_lock_lock(&gLogLock);
    @autoreleasepool {
        NSString *path = PMLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        NSUInteger limit = 2 * 1024 * 1024;
        if ([fm fileExistsAtPath:path]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            if ([attrs[NSFileSize] unsignedLongLongValue] > limit) {
                [fm removeItemAtPath:path error:NULL];
            }
        }
        if (![fm fileExistsAtPath:path]) {
            [[line stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {
            }
        }
    }
    os_unfair_lock_unlock(&gLogLock);
}

static NSString *pm_timestamp(void) {
    struct tm t;
    time_t now = time(NULL);
    localtime_r(&now, &t);
    char buf[32];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d", t.tm_hour, t.tm_min, t.tm_sec);
    return [NSString stringWithUTF8String:buf];
}

void PMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ParadigmMod] %@", msg);
    pm_log_write([NSString stringWithFormat:@"%@ [%@] %@", pm_timestamp(), NSThread.currentThread.name ?: @"?", msg]);
}

NSString *PMLogTail(NSUInteger maxLines) {
    os_unfair_lock_lock(&gLogLock);
    NSString *content = [NSString stringWithContentsOfFile:PMLogPath() encoding:NSUTF8StringEncoding error:NULL];
    os_unfair_lock_unlock(&gLogLock);
    if (!content.length) return @"(还没有日志)";
    if (maxLines == 0) return content;
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    if (lines.count <= maxLines) return content;
    return [[lines subarrayWithRange:NSMakeRange(lines.count - maxLines, maxLines)] componentsJoinedByString:@"\n"];
}

void PMLogClear(void) {
    os_unfair_lock_lock(&gLogLock);
    [NSFileManager.defaultManager removeItemAtPath:PMLogPath() error:NULL];
    os_unfair_lock_unlock(&gLogLock);
}

// 每次启动重新生成日志文件
void PMLogReset(void) { PMLogClear(); }

static void pm_uncaught_handler(NSException *e) {
    PMLog(@"💥 未捕获异常 %@: %@\n%@", e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

// 信号崩溃也写日志（异步信号安全：只用 open/write/close）
static char gLogPathC[1024] = {0};

static void pm_signal_handler(int sig, siginfo_t *info, void *uctx) {
    uintptr_t pc = 0, lr = 0, far = 0;
    ucontext_t *uc = (ucontext_t *)uctx;
    if (uc) {
        pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
        far = (uintptr_t)uc->uc_mcontext->__es.__far;
    }
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "\n[CRASH] sig=%d pc=%p lr=%p far=%p\n",
                     sig, (void *)pc, (void *)lr, (void *)far);
    if (n > 0 && gLogPathC[0]) {
        int fd = open(gLogPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            write(fd, buf, (size_t)n);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void PMLogInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&pm_uncaught_handler);
    strncpy(gLogPathC, [PMLogPath() fileSystemRepresentation], sizeof(gLogPathC) - 1);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = pm_signal_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    PMLog(@"日志文件: %@", PMLogPath());
}

// ---------------------------------------------------------------------------
// UnityFramework 基址
// ---------------------------------------------------------------------------
static uintptr_t gUnityBase = 0;

void *PMUnityBase(void) {
    if (gUnityBase) return (void *)gUnityBase;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            // _dyld_get_image_header 返回的就是已加 slide 的实际地址，
            // 再叠加 _dyld_get_image_vmaddr_slide 会导致所有 RVA 偏移错误
            gUnityBase = (uintptr_t)_dyld_get_image_header(i);
            PMLog(@"UnityFramework base = %p (%s)", (void *)gUnityBase, name);
            return (void *)gUnityBase;
        }
    }
    return NULL;
}

// 读取自身 Mach-O 的 cryptid（1 = 未砸壳 / FairPlay 加密）
static int pm_macho_cryptid(void *base) {
    uint32_t *p = (uint32_t *)base;
    if (!p || p[0] != 0xFEEDFACF) return -1;
    uint32_t ncmds = p[4];
    uintptr_t off = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = *(uint32_t *)((char *)base + off);
        uint32_t cmdsize = *(uint32_t *)((char *)base + off + 4);
        if (cmdsize < 8) break;
        if (cmd == 0x2C) return *(int *)((char *)base + off + 16);
        off += cmdsize;
    }
    return -1;
}

int PMUnityCryptid(void) {
    void *b = PMUnityBase();
    return b ? pm_macho_cryptid(b) : -2;
}

// 读取 LC_UUID，便于确认基础包版本（4.13 = 964f6391cd6c33788f84dd0aae540677）
static void pm_macho_uuid(void *base, char *out, size_t cap) {
    if (cap) out[0] = 0;
    uint32_t *p = (uint32_t *)base;
    if (!p || p[0] != 0xFEEDFACF || cap < 33) return;
    uint32_t ncmds = p[4];
    uintptr_t off = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = *(uint32_t *)((char *)base + off);
        uint32_t cmdsize = *(uint32_t *)((char *)base + off + 4);
        if (cmdsize < 8) break;
        if (cmd == 0x1B) {
            const unsigned char *u = (const unsigned char *)base + off + 8;
            snprintf(out, cap,
                     "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                     u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                     u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
            return;
        }
        off += cmdsize;
    }
}

NSString *PMUnityUUIDString(void) {
    void *b = PMUnityBase();
    if (!b) return @"(no base)";
    char uuid[40];
    pm_macho_uuid(b, uuid, sizeof(uuid));
    return [NSString stringWithUTF8String:uuid];
}

// ---------------------------------------------------------------------------
// 极简 arm64 inline hook（入口 16 字节 + trampoline）
// ---------------------------------------------------------------------------
// iOS 14+ 强制 W^X：用 VM_PROT_COPY 让内核复制一份代码页再写（等价 fishhook 的做法）
static bool pm_make_writable(void *addr, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + size) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, span, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE);
    }
    if (kr != KERN_SUCCESS) {
        PMLog(@"vm_protect(RW) 失败: %d（运行时改代码被系统拦截）", kr);
        PMHookFailed = true;
        return false;
    }
    return true;
}

static void pm_restore_executable(void *addr, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + size) - page;
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
}

// ldr x16, #8 ; br x16 ; .quad target
static void pm_emit_branch(uint32_t *code, uintptr_t target) {
    code[0] = 0x58000050;
    code[1] = 0xD61F0200;
    memcpy(&code[2], &target, sizeof(target));
}

static void *pm_alloc_trampoline(void) {
    // 先拿 RW 页（写完后由调用方改成 RX；iOS 不允许 RWX）
    void *p = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return NULL;
    return p;
}

static void *pm_install_hook(void *target, void *replacement) {
    if (!target || !replacement) return NULL;
    uint32_t *entry = (uint32_t *)target;
    for (int i = 0; i < 4; i++) {
        uint32_t insn = entry[i];
        uint32_t top6 = insn >> 26;
        if (top6 == 0x05 || top6 == 0x25) {          // B / BL
            PMLog(@"入口含分支，拒绝 hook: %p", target);
            return NULL;
        }
        if ((insn & 0x3B000000) == 0x18000000 && ((insn >> 24) & 0x3) != 0) {
            PMLog(@"入口含 literal load，拒绝 hook: %p", target);
            return NULL;
        }
    }
    void *tramp = pm_alloc_trampoline();
    if (!tramp) return NULL;
    uint32_t *tc = (uint32_t *)tramp;
    memcpy(tc, entry, 16);
    pm_emit_branch(tc + 4, (uintptr_t)entry + 16);
    if (mprotect(tramp, vm_page_size, PROT_READ | PROT_EXEC) != 0) {
        PMLog(@"trampoline mprotect(RX) 失败");
        munmap(tramp, vm_page_size);
        return NULL;
    }
    sys_icache_invalidate(tramp, 32);

    if (!pm_make_writable(target, 16)) {
        munmap(tramp, vm_page_size);
        return NULL;
    }
    uint32_t patch[4];
    pm_emit_branch(patch, (uintptr_t)replacement);
    memcpy(entry, patch, 16);
    sys_icache_invalidate(target, 16);
    pm_restore_executable(target, 16);
    PMLog(@"hook %p -> %p (tramp %p)", target, replacement, tramp);
    return tramp;
}

// ---------------------------------------------------------------------------
// il2cpp 运行时 API
// ---------------------------------------------------------------------------
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppString Il2CppString;
typedef struct Il2CppType Il2CppType;
typedef struct Il2CppException Il2CppException;
typedef struct FieldInfo FieldInfo;
typedef struct MethodInfo MethodInfo;

static Il2CppDomain *(*il2cpp_domain_get)(void);
static const Il2CppAssembly **(*il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
static Il2CppImage *(*il2cpp_assembly_get_image)(const Il2CppAssembly *);
static Il2CppClass *(*il2cpp_class_from_name)(const Il2CppImage *, const char *, const char *);
static const MethodInfo *(*il2cpp_class_get_method_from_name)(Il2CppClass *, const char *, int);
static Il2CppObject *(*il2cpp_runtime_invoke)(const MethodInfo *, void *, void **, Il2CppException **);
static Il2CppClass *(*il2cpp_object_get_class)(Il2CppObject *);
static const char *(*il2cpp_class_get_name)(Il2CppClass *);
static FieldInfo *(*il2cpp_class_get_field_from_name)(Il2CppClass *, const char *);
static void (*il2cpp_field_static_set_value)(FieldInfo *, void *);
static void (*il2cpp_field_static_get_value)(FieldInfo *, void *);
static Il2CppDomain *(*il2cpp_thread_attach)(Il2CppDomain *);
static Il2CppString *(*il2cpp_string_new)(const char *);
static Il2CppType *(*il2cpp_class_get_type)(Il2CppClass *);
static Il2CppObject *(*il2cpp_type_get_object)(const Il2CppType *);
static void *(*il2cpp_gchandle_new)(Il2CppObject *, bool);
static void (*il2cpp_gchandle_free)(void *);
static size_t (*il2cpp_image_get_class_count)(const Il2CppImage *);
static Il2CppClass *(*il2cpp_image_get_class)(const Il2CppImage *, size_t);

static MethodInfo *gSetResultMethod = NULL;

static bool pm_resolve_il2cpp(void) {
    if (PMIl2CppReady) return true;
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) return false;
#define RESOLVE(var, name)                                   \
    var = (__typeof__(var))dlsym(h, name);                    \
    if (!var) { PMLog(@"缺少符号 %s", name); return false; }
    RESOLVE(il2cpp_domain_get, "il2cpp_domain_get");
    RESOLVE(il2cpp_domain_get_assemblies, "il2cpp_domain_get_assemblies");
    RESOLVE(il2cpp_assembly_get_image, "il2cpp_assembly_get_image");
    RESOLVE(il2cpp_class_from_name, "il2cpp_class_from_name");
    RESOLVE(il2cpp_class_get_method_from_name, "il2cpp_class_get_method_from_name");
    RESOLVE(il2cpp_runtime_invoke, "il2cpp_runtime_invoke");
    RESOLVE(il2cpp_object_get_class, "il2cpp_object_get_class");
    RESOLVE(il2cpp_class_get_name, "il2cpp_class_get_name");
    RESOLVE(il2cpp_class_get_field_from_name, "il2cpp_class_get_field_from_name");
    RESOLVE(il2cpp_field_static_set_value, "il2cpp_field_static_set_value");
    RESOLVE(il2cpp_field_static_get_value, "il2cpp_field_static_get_value");
    RESOLVE(il2cpp_thread_attach, "il2cpp_thread_attach");
    RESOLVE(il2cpp_string_new, "il2cpp_string_new");
    il2cpp_class_get_type = (__typeof__(il2cpp_class_get_type))dlsym(h, "il2cpp_class_get_type");
    il2cpp_type_get_object = (__typeof__(il2cpp_type_get_object))dlsym(h, "il2cpp_type_get_object");
    il2cpp_gchandle_new = (__typeof__(il2cpp_gchandle_new))dlsym(h, "il2cpp_gchandle_new");
    il2cpp_gchandle_free = (__typeof__(il2cpp_gchandle_free))dlsym(h, "il2cpp_gchandle_free");
    il2cpp_image_get_class_count = (__typeof__(il2cpp_image_get_class_count))dlsym(h, "il2cpp_image_get_class_count");
    il2cpp_image_get_class = (__typeof__(il2cpp_image_get_class))dlsym(h, "il2cpp_image_get_class");
#undef RESOLVE
    PMIl2CppReady = true;
    return true;
}

static Il2CppClass *pm_find_class(const char *name) {
    if (!il2cpp_domain_get) return NULL;
    Il2CppDomain *domain = il2cpp_domain_get();
    if (!domain) return NULL;
    if (il2cpp_thread_attach) il2cpp_thread_attach(domain);   // 非 Unity 线程必须 attach
    size_t count = 0;
    const Il2CppAssembly **asms = il2cpp_domain_get_assemblies(domain, &count);
    if (!asms || count == 0 || count > 4096) return NULL;
    for (size_t i = 0; i < count; i++) {
        Il2CppImage *img = il2cpp_assembly_get_image(asms[i]);
        if (!img) continue;
        Il2CppClass *k = il2cpp_class_from_name(img, "", name);
        if (k) return k;
    }
    return NULL;
}

static bool pm_set_static_bool(const char *klassName, const char *fieldName, bool value) {
    Il2CppClass *k = pm_find_class(klassName);
    if (!k) return false;
    FieldInfo *f = il2cpp_class_get_field_from_name(k, fieldName);
    if (!f) return false;
    uint8_t v = value ? 1 : 0;
    il2cpp_field_static_set_value(f, &v);
    return true;
}

static bool pm_set_static_float(const char *klassName, const char *fieldName, float value) {
    Il2CppClass *k = pm_find_class(klassName);
    if (!k) return false;
    FieldInfo *f = il2cpp_class_get_field_from_name(k, fieldName);
    if (!f) return false;
    il2cpp_field_static_set_value(f, &value);
    return true;
}

static bool pm_get_static_float(const char *klassName, const char *fieldName, float *out) {
    Il2CppClass *k = pm_find_class(klassName);
    if (!k) return false;
    FieldInfo *f = il2cpp_class_get_field_from_name(k, fieldName);
    if (!f) return false;
    il2cpp_field_static_get_value(f, out);
    return true;
}

static bool pm_prepare_judge_api(void) {
    if (gSetResultMethod) return true;
    if (!pm_resolve_il2cpp()) return false;
    Il2CppClass *slot = pm_find_class("JudgeSlot");
    if (!slot) {
        PMLog(@"找不到 JudgeSlot");
        return false;
    }
    gSetResultMethod = (MethodInfo *)il2cpp_class_get_method_from_name(slot, "SetResult", 2);
    PMLog(@"JudgeSlot.SetResult = %p", gSetResultMethod);
    return gSetResultMethod != NULL;
}

static void pm_call_SetResult(void *slot, int value, bool precise) {
    if (!gSetResultMethod) return;
    int32_t v = value;
    uint8_t p = precise ? 1 : 0;
    void *args[2] = {&v, &p};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(gSetResultMethod, slot, args, &exc);
}

// ---------------------------------------------------------------------------
// Hook: JudgeSystem.UpdateTime -> AutoPlay
// ---------------------------------------------------------------------------
static void (*orig_UpdateTime)(void *self) = NULL;

static void pm_UpdateTime_hook(void *self) {
    if (orig_UpdateTime) orig_UpdateTime(self);
    if (!self) return;

    PMLastGameplayTick = CFAbsoluteTimeGetCurrent();

    if (PMLastSlotCount < 0) {
        void *slots = *(void **)((char *)self + kOff_JS_Slots);
        if (slots) {
            int n = *(int *)((char *)slots + kOff_List_Size);
            if (n >= 0 && n < 100000) PMLastSlotCount = n;
        }
    }
    if (!__atomic_load_n(&PMAutoPlay, __ATOMIC_RELAXED) || !gSetResultMethod) return;

    void *slots = *(void **)((char *)self + kOff_JS_Slots);
    if (!slots) return;
    void **items = *(void ***)((char *)slots + kOff_List_Items);
    int size = *(int *)((char *)slots + kOff_List_Size);
    float now = *(float *)((char *)self + kOff_JS_Time);
    if (!items || size <= 0 || size > 100000) return;

    for (int i = 0; i < size; i++) {
        void *slot = items[i];
        if (!slot) continue;
        int result = *(int *)((char *)slot + kOff_Slot_Result);
        if (result > 1) continue;
        float perfect = *(float *)((char *)slot + kOff_Slot_PerfectTime);
        if (now + 0.002f < perfect) continue;
        if (now - 0.25f > perfect) continue;
        pm_call_SetResult(slot, kJudgeDecrypted, true);
        __atomic_add_fetch(&PMAutoJudged, 1, __ATOMIC_RELAXED);
    }
}

// ---------------------------------------------------------------------------
// Hook: JudgeSlot.SetResult -> 全 Perfect
// ---------------------------------------------------------------------------
static void (*orig_SetResult)(void *self, int value, uint8_t precise, void *method) = NULL;

static void pm_SetResult_hook(void *self, int value, uint8_t precise, void *method) {
    if (__atomic_load_n(&PMAllPerfect, __ATOMIC_RELAXED) &&
        (value == kJudgeReceived || value == kJudgeLost)) {
        value = kJudgeDecrypted;
        precise = 1;
    }
    if (orig_SetResult) orig_SetResult(self, value, precise, method);
}

// ---------------------------------------------------------------------------
// Hook: GameControl.AddHP -> 锁血
// ---------------------------------------------------------------------------
static void (*orig_AddHP)(void *self, int result, float mult, uint8_t precise, void *method) = NULL;

static void pm_AddHP_hook(void *self, int result, float mult, uint8_t precise, void *method) {
    if (__atomic_load_n(&PMLockHP, __ATOMIC_RELAXED) && result == kJudgeLost) {
        result = kJudgeDecrypted;
        precise = 1;
    }
    if (orig_AddHP) orig_AddHP(self, result, mult, precise, method);
}

// ---------------------------------------------------------------------------
// Hook: BackendAPI.Run(IEnumerator) -> 屏蔽成绩上传
// ---------------------------------------------------------------------------
static void *(*orig_Run)(void *enumerator, void *method) = NULL;

static void *pm_Run_hook(void *enumerator, void *method) {
    if (enumerator && __atomic_load_n(&PMBlockUpload, __ATOMIC_RELAXED) && il2cpp_object_get_class && il2cpp_class_get_name) {
        Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)enumerator);
        if (k) {
            const char *name = il2cpp_class_get_name(k);
            if (name && strstr(name, "ScoreUploadCoroutine")) {
                __atomic_add_fetch(&PMUploadBlocked, 1, __ATOMIC_RELAXED);
                PMLog(@"已拦截一次成绩上传");
                return NULL;
            }
        }
    }
    return orig_Run ? orig_Run(enumerator, method) : NULL;
}

// ---------------------------------------------------------------------------
// Hook: GameNetwork.Store.IsPurchased -> 本地放行付费曲包
// ---------------------------------------------------------------------------
static void pm_il2cpp_string_ascii(void *s, char *out, size_t cap) {
    if (!cap) return;
    if (!s) { out[0] = 0; return; }
    int len = *(int *)((char *)s + 0x10);              // Il2CppString.length
    const uint16_t *chars = (const uint16_t *)((char *)s + 0x14);
    if (len < 0) len = 0;
    size_t n = 0;
    for (int i = 0; i < len && n + 1 < cap; i++) {
        uint16_t c = chars[i];
        out[n++] = (c < 0x80) ? (char)c : '?';
    }
    out[n] = 0;
}

static bool pm_contains_ci(const char *hay, const char *needle) {
    size_t n = strlen(needle);
    if (!n) return true;
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < n && p[i] && tolower((unsigned char)p[i]) == (unsigned char)needle[i]) i++;
        if (i == n) return true;
    }
    return false;
}

static bool (*orig_IsPurchasedStr)(void *productId, void *method) = NULL;
static bool (*orig_IsPurchasedEnum)(int product, void *method) = NULL;

static bool pm_IsPurchasedStr_hook(void *productId, void *method) {
    if (__atomic_load_n(&PMPaidUnlock, __ATOMIC_RELAXED)) {
        char buf[192];
        pm_il2cpp_string_ascii(productId, buf, sizeof(buf));
        // 水晶包 / 皮肤不冒充已购买，避免商店入口异常
        if (!pm_contains_ci(buf, "crystal") && !pm_contains_ci(buf, "skin")) return true;
    }
    return orig_IsPurchasedStr ? orig_IsPurchasedStr(productId, method) : false;
}

static bool pm_IsPurchasedEnum_hook(int product, void *method) {
    if (__atomic_load_n(&PMPaidUnlock, __ATOMIC_RELAXED)) {
        // ProductEnum 15..18 = ActiveCrystal20/110/450/1200
        if (!(product >= 15 && product <= 18)) return true;
    }
    return orig_IsPurchasedEnum ? orig_IsPurchasedEnum(product, method) : false;
}

// ---------------------------------------------------------------------------
// Hook: 收藏品 / 角色 / 挑战 本地解锁
// ---------------------------------------------------------------------------
static bool (*orig_IsRelicUnlocked)(void *arg, void *method) = NULL;
static bool (*orig_IsCharacterUnlocked)(void *arg, void *method) = NULL;
static bool (*orig_IsChallengeUnlocked)(void *arg, void *method) = NULL;

static bool pm_IsRelicUnlocked_hook(void *arg, void *method) {
    if (__atomic_load_n(&PMUnlockRelics, __ATOMIC_RELAXED)) return true;
    return orig_IsRelicUnlocked ? orig_IsRelicUnlocked(arg, method) : false;
}

static bool pm_IsCharacterUnlocked_hook(void *arg, void *method) {
    if (__atomic_load_n(&PMUnlockCharacters, __ATOMIC_RELAXED)) return true;
    return orig_IsCharacterUnlocked ? orig_IsCharacterUnlocked(arg, method) : false;
}

static bool pm_IsChallengeUnlocked_hook(void *arg, void *method) {
    if (__atomic_load_n(&PMUnlockChallenges, __ATOMIC_RELAXED)) return true;
    return orig_IsChallengeUnlocked ? orig_IsChallengeUnlocked(arg, method) : false;
}

// ---------------------------------------------------------------------------
// 称号 / 背景（EAchievement）本地解锁
// ---------------------------------------------------------------------------
static bool (*orig_IsAchvEnum)(int achv, void *method) = NULL;
static bool (*orig_IsAchvStruct)(uint64_t achv, void *track) = NULL;

static bool pm_IsAchvEnum_hook(int achv, void *method) {
    if (PMUnlockTitles || PMUnlockBackgrounds) return true;
    return orig_IsAchvEnum ? orig_IsAchvEnum(achv, method) : false;
}

static bool pm_IsAchvStruct_hook(uint64_t achv, void *track) {
    if (PMUnlockTitles || PMUnlockBackgrounds) return true;
    return orig_IsAchvStruct ? orig_IsAchvStruct(achv, track) : false;
}

// ---------------------------------------------------------------------------
// 个人资料：只改本地显示（不写存档、不上传）
// ---------------------------------------------------------------------------
static void pm_set_component_text(void *comp, NSString *value) {
    if (!comp || !value.length) return;
    if (!il2cpp_object_get_class || !il2cpp_class_get_method_from_name ||
        !il2cpp_runtime_invoke || !il2cpp_string_new) return;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)comp);
    if (!k) return;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, "set_text", 1);
    if (!m) m = il2cpp_class_get_method_from_name(k, "SetText", 1);
    if (!m) return;
    Il2CppString *s = il2cpp_string_new(value.UTF8String);
    if (!s) return;
    void *args[1] = {s};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, comp, args, &exc);
}

static void pm_set_text_at(void *self, size_t off, NSString *key) {
    if (!self) return;
    NSString *v = PMProfileValue(key);
    if (!v) return;
    void *comp = *(void **)((char *)self + off);
    pm_set_component_text(comp, v);
}

// 资料页文本：优先用自定义值；没填但对应解锁开关打开时显示「全解锁」
static void pm_set_text_at_ex(void *self, size_t off, NSString *key, BOOL unlocked) {
    if (!self) return;
    NSString *v = PMProfileValue(key);
    if (!v && unlocked) v = @"全解锁";
    if (!v) return;
    void *comp = *(void **)((char *)self + off);
    pm_set_component_text(comp, v);
}

static void pm_apply_collection_overrides(void *self) {
    if (!self) return;
    BOOL anyUnlock = PMUnlockCharacters || PMUnlockSkins || PMUnlockStories ||
                     PMUnlockTitles || PMUnlockBackgrounds;
    if (!PMProfileEnabled && !anyUnlock) return;
    pm_set_text_at(self, kOff_CM_Id, @"id");
    pm_set_text_at(self, kOff_CM_TotalPlayTime, @"playtime");
    pm_set_text_at(self, kOff_CM_TotalScore, @"totalscore");
    pm_set_text_at_ex(self, kOff_CM_Story, @"stories", PMUnlockStories);
    pm_set_text_at(self, kOff_CM_Track, @"tracks");
    pm_set_text_at(self, kOff_CM_PlayCount, @"playcount");
    pm_set_text_at(self, kOff_CM_NoteDecrypted, @"note");
    pm_set_text_at(self, kOff_CM_Chart, @"charts");
    pm_set_text_at_ex(self, kOff_CM_Character, @"characters", PMUnlockCharacters);
    pm_set_text_at_ex(self, kOff_CM_Frame, @"backgrounds", PMUnlockBackgrounds);
    pm_set_text_at_ex(self, kOff_CM_Title, @"titles", PMUnlockTitles);
    pm_set_text_at_ex(self, kOff_CM_TitleScreen, @"titlescreens", PMUnlockTitles || PMUnlockBackgrounds);
    pm_set_text_at(self, kOff_CM_AllDecrypted, @"alldecrypted");
    pm_set_text_at(self, kOff_CM_FullCombo, @"fullcombo");
    pm_set_text_at(self, kOff_CM_Clear, @"clear");
    pm_set_text_at(self, kOff_CM_Infinity, @"infinity");
    pm_set_text_at(self, kOff_CM_AAA, @"aaa");
    pm_set_text_at(self, kOff_CM_AA, @"aa");
    pm_set_text_at(self, kOff_CM_Rating, @"rating");
    pm_set_text_at_ex(self, kOff_CM_Skin, @"skins", PMUnlockSkins);
}

static void pm_apply_playerinfo_overrides(void *self) {
    if (!PMProfileEnabled || !self) return;
    pm_set_text_at(self, kOff_PI_Level, @"level");
    pm_set_text_at(self, kOff_PI_Rating, @"rating");
    pm_set_text_at(self, kOff_PI_RatingSmall, @"rating");
}

static void (*orig_CM_RefreshData)(void *) = NULL;
static void (*orig_CM_RefreshDiff)(void *) = NULL;
static void (*orig_CM_RefreshGrade)(void *, void *) = NULL;
static void (*orig_PI_UpdateOther)(void *) = NULL;
static void (*orig_PI_UpdateRating)(void *) = NULL;

static void pm_CM_RefreshData_hook(void *self) {
    if (orig_CM_RefreshData) orig_CM_RefreshData(self);
    pm_apply_collection_overrides(self);
}

static void pm_CM_RefreshDiff_hook(void *self) {
    if (orig_CM_RefreshDiff) orig_CM_RefreshDiff(self);
    pm_apply_collection_overrides(self);
}

static void pm_CM_RefreshGrade_hook(void *self, void *arr) {
    if (PMProfileEnabled && arr) {
        NSString *v = PMProfileValue(@"grades");
        if (v.length) {
            int32_t n = v.intValue;
            int len = *(int *)((char *)arr + 0x18);
            int32_t *items = (int32_t *)((char *)arr + 0x20);
            if (len >= 0 && len <= 16) {
                for (int i = 0; i < len; i++) items[i] = n;
            }
        }
    }
    if (orig_CM_RefreshGrade) orig_CM_RefreshGrade(self, arr);
}

static void pm_PI_UpdateOther_hook(void *self) {
    if (orig_PI_UpdateOther) orig_PI_UpdateOther(self);
    pm_apply_playerinfo_overrides(self);
}

static void pm_PI_UpdateRating_hook(void *self) {
    if (orig_PI_UpdateRating) orig_PI_UpdateRating(self);
    pm_apply_playerinfo_overrides(self);
}

// ---------------------------------------------------------------------------
// 周期任务：全解锁 / 打击音量
// ---------------------------------------------------------------------------
static bool gUnlockAllWritten = false;
static bool gSkinUnlockWritten = false;
static bool gStoryUnlockWritten = false;
static bool gDictUnlockWritten = false;
static float gHitBase = -1;
static float gHitWritten = -1;

static void pm_apply_static_settings(void) {
    if (!PMIl2CppReady) return;

    bool unlock = __atomic_load_n(&PMUnlockAll, __ATOMIC_RELAXED);
    if (unlock != gUnlockAllWritten) {
        if (pm_set_static_bool("TrackUnlockStorage", "UnlockAll", unlock)) {
            gUnlockAllWritten = unlock;
            PMUnlockAllApplied = unlock;
        }
    }

    // 皮肤 / 故事 / 词典（背景等）本地全解锁
    bool skins = PMUnlockSkins;
    if (skins != gSkinUnlockWritten) {
        if (pm_set_static_bool("SkinUnlockStorage", "UnlockAll", skins)) gSkinUnlockWritten = skins;
    }
    bool stories = PMUnlockStories;
    if (stories != gStoryUnlockWritten) {
        if (pm_set_static_bool("StoryUnlockStorage", "UnlockAll", stories)) gStoryUnlockWritten = stories;
    }
    bool dict = PMUnlockBackgrounds;
    if (dict != gDictUnlockWritten) {
        if (pm_set_static_bool("DictStorage", "UnlockAll", dict)) gDictUnlockWritten = dict;
    }

    // 打击音量：最大 150%
    if (PMHitVolumeBoost > 1.005f) {
        float cur = 0;
        if (pm_get_static_float("SEPlayer", "hitSoundVolume", &cur)) {
            if (fabsf(cur - gHitWritten) > 0.0005f) gHitBase = cur;   // 游戏刚写过设置
            if (gHitBase < 0) gHitBase = cur;
            float target = gHitBase * PMHitVolumeBoost;
            if (target > 1.5f) target = 1.5f;
            if (fabsf(cur - target) > 0.0005f) {
                if (pm_set_static_float("SEPlayer", "hitSoundVolume", target)) gHitWritten = target;
            }
        }
    } else if (gHitWritten > 0) {
        if (gHitBase >= 0) pm_set_static_float("SEPlayer", "hitSoundVolume", gHitBase);
        gHitWritten = -1;
    }
}

void PMApplySettingsNow(void) { pm_apply_static_settings(); }

// ---------------------------------------------------------------------------
// 无代码补丁运行时：il2cpp 反射 + CADisplayLink 轮询
// （这个签名环境下改代码页会被系统直接杀进程，所以完全不做 inline hook）
// ---------------------------------------------------------------------------
static Il2CppClass *gWrapClass = NULL;
static Il2CppClass *gCollectionClass = NULL;
static Il2CppClass *gPIClass = NULL;
static Il2CppClass *gFindTypesHost = NULL;
static const MethodInfo *gFindTypeMethod = NULL;
static void *gWrapObj = NULL;
static void *gCollectionObj = NULL;
static void *gPI_Obj = NULL;
static void *gWrapHandle = NULL;
static void *gCollectionHandle = NULL;
static void *gPI_Handle = NULL;
static CFTimeInterval gLastFindTime = 0;
static CFTimeInterval gLastSlowTime = 0;
static int gLastLifeValue = -1;
static void *gLastGCObj = NULL;
static Il2CppClass *gGCClass = NULL;
static const MethodInfo *gGetLifeTypeM = NULL;
static const MethodInfo *gSetLifeTypeM = NULL;
static void *gLifeJs = NULL;
static int gSavedLifeType = 0;
static bool gLifeTypeSaved = false;
static Il2CppClass *gSettingsClass = NULL;
static void *gSettingsObj = NULL;
static void *gSettingsHandle = NULL;
static BOOL gEntryVisible = NO;

static Il2CppClass *pm_find_class_any(const char *name, const char *method, int argc) {
    Il2CppDomain *domain = il2cpp_domain_get();
    if (!domain) return NULL;
    if (il2cpp_thread_attach) il2cpp_thread_attach(domain);
    size_t count = 0;
    const Il2CppAssembly **asms = il2cpp_domain_get_assemblies(domain, &count);
    if (!asms || count == 0 || count > 4096) return NULL;
    for (size_t i = 0; i < count; i++) {
        Il2CppImage *img = il2cpp_assembly_get_image(asms[i]);
        if (!img) continue;
        Il2CppClass *k = il2cpp_class_from_name(img, "", name);
        if (k && (!method || il2cpp_class_get_method_from_name(k, method, argc))) return k;
        if (il2cpp_image_get_class_count && il2cpp_image_get_class) {
            size_t n = il2cpp_image_get_class_count(img);
            if (n > 40000) n = 40000;
            for (size_t j = 0; j < n; j++) {
                Il2CppClass *c = il2cpp_image_get_class(img, j);
                if (!c) continue;
                const char *cn = il2cpp_class_get_name(c);
                if (!cn || strcmp(cn, name)) continue;
                if (method && !il2cpp_class_get_method_from_name(c, method, argc)) continue;
                return c;
            }
        }
    }
    return NULL;
}

static Il2CppClass *pm_class_with_static_method(const char *cls, const char *m, int argc) {
    return pm_find_class_any(cls, m, argc);
}

// 用 Object.FindObjectOfType 找场景里唯一实例，并用 GCHandle 保活
static void pm_refresh_object(Il2CppClass *k, void **slot, void **handle) {
    if (!k || !gFindTypeMethod || !il2cpp_class_get_type || !il2cpp_type_get_object) return;
    Il2CppType *t = il2cpp_class_get_type(k);
    if (!t) return;
    void *typeObj = il2cpp_type_get_object(t);
    if (!typeObj) return;
    uint8_t includeInactive = 0;
    void *args[2] = {typeObj, &includeInactive};
    Il2CppException *exc = NULL;
    Il2CppObject *o = il2cpp_runtime_invoke(gFindTypeMethod, NULL, args, &exc);
    if (!o) { *slot = NULL; return; }
    if (*handle && il2cpp_gchandle_free) {
        il2cpp_gchandle_free(*handle);
        *handle = NULL;
    }
    if (il2cpp_gchandle_new) *handle = il2cpp_gchandle_new(o, false);
    *slot = o;
}

static int pm_get_lifetype(void) {
    if (!gGetLifeTypeM || !il2cpp_runtime_invoke) return 0;
    Il2CppObject *boxed = il2cpp_runtime_invoke(gGetLifeTypeM, NULL, NULL, NULL);
    if (!boxed) return 0;
    return *(int *)((char *)boxed + 0x10);
}

static void pm_set_lifetype(int v) {
    if (!gSetLifeTypeM || !il2cpp_runtime_invoke) return;
    int32_t val = v;
    void *args[1] = {&val};
    il2cpp_runtime_invoke(gSetLifeTypeM, NULL, args, NULL);
}

static void pm_runtime_tick(void) {
    if (!PMIl2CppReady) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();

    if (now - gLastFindTime > 0.6) {
        gLastFindTime = now;
        if (!gWrapClass) {
            gWrapClass = pm_find_class("JudgeSystemWrap");
            gCollectionClass = pm_find_class("CollectionManager");
            gPIClass = pm_find_class("PlayerInfoManager");
            gSettingsClass = pm_find_class_any("GenericSettingsPanel", NULL, 0);
            gGCClass = pm_find_class("GameControl");
            if (gGCClass) {
                gGetLifeTypeM = il2cpp_class_get_method_from_name(gGCClass, "get_LifeType", 0);
                gSetLifeTypeM = il2cpp_class_get_method_from_name(gGCClass, "set_LifeType", 1);
            }
            gFindTypesHost = pm_class_with_static_method("Object", "FindObjectOfType", 2);
            if (gFindTypesHost) {
                gFindTypeMethod = il2cpp_class_get_method_from_name(gFindTypesHost, "FindObjectOfType", 2);
            }
            PMLog(@"轮询模式: wrap=%p collection=%p playerInfo=%p settings=%p findType=%p",
                  gWrapClass, gCollectionClass, gPIClass, gSettingsClass, gFindTypeMethod);
        }
        pm_refresh_object(gWrapClass, &gWrapObj, &gWrapHandle);
        pm_refresh_object(gCollectionClass, &gCollectionObj, &gCollectionHandle);
        pm_refresh_object(gPIClass, &gPI_Obj, &gPI_Handle);
        pm_refresh_object(gSettingsClass, &gSettingsObj, &gSettingsHandle);

        BOOL visible = (gSettingsObj != NULL);
        if (visible != gEntryVisible) {
            gEntryVisible = visible;
            PMSetModEntryVisible(visible);
        }

        if (gCollectionObj) pm_apply_collection_overrides(gCollectionObj);
        if (gPI_Obj) pm_apply_playerinfo_overrides(gPI_Obj);
    }

    if (now - gLastSlowTime > 1.5) {
        gLastSlowTime = now;
        pm_apply_static_settings();
    }

    void *wrap = gWrapObj;
    if (!wrap) return;
    if (il2cpp_object_get_class && il2cpp_object_get_class((Il2CppObject *)wrap) != gWrapClass) {
        gWrapObj = NULL;
        return;
    }
    void *js = *(void **)((char *)wrap + 0xE0);
    if (!js) {
        if (gLifeTypeSaved) {
            pm_set_lifetype(gSavedLifeType);
            gLifeTypeSaved = false;
            gLifeJs = NULL;
        }
        return;
    }
    PMLastGameplayTick = now;

    // 锁血第一步：把 LifeType 设成 None(6)，AddHP 里直接不扣血
    if (PMLockHP) {
        if (js != gLifeJs) {
            if (gLifeTypeSaved) pm_set_lifetype(gSavedLifeType);
            gSavedLifeType = pm_get_lifetype();
            gLifeTypeSaved = true;
            gLifeJs = js;
            pm_set_lifetype(6);
            PMLog(@"锁血: LifeType %d -> 6(None)", gSavedLifeType);
        } else if (pm_get_lifetype() != 6) {
            pm_set_lifetype(6);
        }
    } else if (gLifeTypeSaved) {
        pm_set_lifetype(gSavedLifeType);
        gLifeTypeSaved = false;
        gLifeJs = NULL;
    }

    // 自动打歌 / 全 Perfect
    if (PMAutoPlay || PMAllPerfect) {
        if (!gSetResultMethod) pm_prepare_judge_api();
        void *slots = *(void **)((char *)js + kOff_JS_Slots);
        if (slots && gSetResultMethod) {
            void **items = *(void ***)((char *)slots + kOff_List_Items);
            int size = *(int *)((char *)slots + kOff_List_Size);
            float t = *(float *)((char *)js + kOff_JS_Time);
            if (items && size > 0 && size < 100000) {
                PMLastSlotCount = size;
                for (int i = 0; i < size; i++) {
                    void *slot = items[i];
                    if (!slot) continue;
                    int result = *(int *)((char *)slot + kOff_Slot_Result);
                    if (PMAutoPlay && result <= 1) {
                        float perfect = *(float *)((char *)slot + kOff_Slot_PerfectTime);
                        if (t + 0.002f < perfect) continue;
                        if (t - 0.25f > perfect) continue;
                        pm_call_SetResult(slot, kJudgeDecrypted, true);
                        __atomic_add_fetch(&PMAutoJudged, 1, __ATOMIC_RELAXED);
                    } else if (PMAllPerfect && (result == kJudgeReceived || result == kJudgeLost)) {
                        pm_call_SetResult(slot, kJudgeDecrypted, true);
                    }
                }
            }
        }
    }

    // 锁血：保持血量在本局最大值，Miss 也掉不下去
    if (PMLockHP) {
        void *gc = *(void **)((char *)wrap + 0xD8);
        if (gc && gc == gLastGCObj) {
            int life = *(int *)((char *)gc + 0x58);
            if (gLastLifeValue < 0) {
                gLastLifeValue = life;
            } else {
                if (life > gLastLifeValue) gLastLifeValue = life;
                if (life != gLastLifeValue) *(int *)((char *)gc + 0x58) = gLastLifeValue;
            }
        } else {
            gLastGCObj = gc;
            gLastLifeValue = gc ? *(int *)((char *)gc + 0x58) : -1;
        }
    } else {
        gLastGCObj = NULL;
        gLastLifeValue = -1;
    }
}

@interface PMRuntimeTicker : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@end

@implementation PMRuntimeTicker
- (void)tick:(CADisplayLink *)link { pm_runtime_tick(); }
@end

static PMRuntimeTicker *gRuntimeTicker = nil;

// ---------------------------------------------------------------------------
// 成绩上传拦截：改写 NSURLSession 请求，把 /play/upload* 指向本机黑洞
// ---------------------------------------------------------------------------
static BOOL gUploadSwizzled = NO;
static id (*orig_dt_req)(id, SEL, NSURLRequest *);
static id (*orig_dt_req_cb)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLRequest *pm_filter_upload(NSURLRequest *req) {
    if (!req || !PMBlockUpload) return req;
    NSString *u = req.URL.absoluteString;
    if (!u) return req;
    if ([u containsString:@"/play/upload"]) {
        static int logged = 0;
        if (__atomic_fetch_add(&logged, 1, __ATOMIC_RELAXED) < 3) {
            PMLog(@"已拦截成绩上传请求: %@", u);
        }
        NSMutableURLRequest *m = [req mutableCopy];
        m.URL = [NSURL URLWithString:@"http://127.0.0.1:1/__pm_blocked__"];
        return m;
    }
    return req;
}

static id pm_dt_req(id self, SEL _cmd, NSURLRequest *req) {
    return orig_dt_req(self, _cmd, pm_filter_upload(req));
}

static id pm_dt_req_cb(id self, SEL _cmd, NSURLRequest *req,
                       void (^cb)(NSData *, NSURLResponse *, NSError *)) {
    return orig_dt_req_cb(self, _cmd, pm_filter_upload(req), cb);
}

static void pm_install_upload_block(void) {
    if (gUploadSwizzled) return;
    gUploadSwizzled = YES;
    Class c = NSClassFromString(@"NSURLSession");
    if (!c) return;
    Method m1 = class_getInstanceMethod(c, @selector(dataTaskWithRequest:));
    if (m1) {
        orig_dt_req = (__typeof__(orig_dt_req))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)pm_dt_req);
    }
    Method m2 = class_getInstanceMethod(c, @selector(dataTaskWithRequest:completionHandler:));
    if (m2) {
        orig_dt_req_cb = (__typeof__(orig_dt_req_cb))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)pm_dt_req_cb);
    }
    PMLog(@"上传拦截已安装: %d/%d", m1 != NULL, m2 != NULL);
}

void PMStartRuntimeFeatures(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!pm_resolve_il2cpp()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ PMStartRuntimeFeatures(); });
            return;
        }
        pm_prepare_judge_api();
        pm_install_upload_block();
        if (!gRuntimeTicker) {
            gRuntimeTicker = [PMRuntimeTicker new];
            gRuntimeTicker.link = [CADisplayLink displayLinkWithTarget:gRuntimeTicker
                                                              selector:@selector(tick:)];
            [gRuntimeTicker.link addToRunLoop:[NSRunLoop mainRunLoop]
                                      forMode:NSRunLoopCommonModes];
        }
        PMLog(@"运行时轮询已启动（不做 inline hook）");
    });
}

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------
void PMInstallHooks(void) {
    if (PMHookReady) return;
    if (PMHookFailed) return;          // 代码页不可写，重试没有意义
    if (!PMUnityBase()) return;
    void *base = (void *)gUnityBase;
    PMLog(@"开始安装 hook: base=%p cryptid=%d uuid=%@", base, PMUnityCryptid(), PMUnityUUIDString());

    bool api = pm_resolve_il2cpp();
    PMLog(@"il2cpp 符号解析: %d", api);
    if (api) pm_prepare_judge_api();
    PMLog(@"JudgeSlot.SetResult 就绪: %d", gSetResultMethod != NULL);

    orig_UpdateTime = (void (*)(void *))pm_install_hook((void *)((char *)base + kRVA_JudgeSystem_UpdateTime),
                                                        (void *)pm_UpdateTime_hook);
    orig_SetResult = (void (*)(void *, int, uint8_t, void *))pm_install_hook(
        (void *)((char *)base + kRVA_JudgeSlot_SetResult), (void *)pm_SetResult_hook);
    orig_AddHP = (void (*)(void *, int, float, uint8_t, void *))pm_install_hook(
        (void *)((char *)base + kRVA_GameControl_AddHP), (void *)pm_AddHP_hook);
    orig_Run = (void *(*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_BackendAPI_Run), (void *)pm_Run_hook);
    orig_IsPurchasedStr = (bool (*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Store_IsPurchasedStr), (void *)pm_IsPurchasedStr_hook);
    orig_IsPurchasedEnum = (bool (*)(int, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Store_IsPurchasedEnum), (void *)pm_IsPurchasedEnum_hook);
    orig_IsRelicUnlocked = (bool (*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_PlayerHelper_IsRelic), (void *)pm_IsRelicUnlocked_hook);
    orig_IsCharacterUnlocked = (bool (*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_PlayerHelper_IsCharacter), (void *)pm_IsCharacterUnlocked_hook);
    orig_IsChallengeUnlocked = (bool (*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Challenge_IsUnlocked), (void *)pm_IsChallengeUnlocked_hook);

    orig_IsAchvEnum = (bool (*)(int, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Achv_IsUnlockedEnum), (void *)pm_IsAchvEnum_hook);
    orig_IsAchvStruct = (bool (*)(uint64_t, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Achv_IsUnlockedStruct), (void *)pm_IsAchvStruct_hook);

    orig_CM_RefreshData = (void (*)(void *))pm_install_hook(
        (void *)((char *)base + kRVA_Collection_RefreshData), (void *)pm_CM_RefreshData_hook);
    orig_CM_RefreshDiff = (void (*)(void *))pm_install_hook(
        (void *)((char *)base + kRVA_Collection_RefreshDiff), (void *)pm_CM_RefreshDiff_hook);
    orig_CM_RefreshGrade = (void (*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_Collection_RefreshGrade), (void *)pm_CM_RefreshGrade_hook);
    orig_PI_UpdateOther = (void (*)(void *))pm_install_hook(
        (void *)((char *)base + kRVA_PlayerInfo_UpdateOther), (void *)pm_PI_UpdateOther_hook);
    orig_PI_UpdateRating = (void (*)(void *))pm_install_hook(
        (void *)((char *)base + kRVA_PlayerInfo_UpdateRating), (void *)pm_PI_UpdateRating_hook);

    PMHookReady = (orig_UpdateTime != NULL);
    PMLog(@"hooks: updateTime=%d setResult=%d addHP=%d run=%d purchased=%d/%d collection=%d/%d/%d achv=%d/%d profile=%d/%d/%d/%d/%d cryptid=%d",
          orig_UpdateTime != NULL, orig_SetResult != NULL, orig_AddHP != NULL,
          orig_Run != NULL, orig_IsPurchasedStr != NULL, orig_IsPurchasedEnum != NULL,
          orig_IsRelicUnlocked != NULL, orig_IsCharacterUnlocked != NULL, orig_IsChallengeUnlocked != NULL,
          orig_IsAchvEnum != NULL, orig_IsAchvStruct != NULL,
          orig_CM_RefreshData != NULL, orig_CM_RefreshDiff != NULL, orig_CM_RefreshGrade != NULL,
          orig_PI_UpdateOther != NULL, orig_PI_UpdateRating != NULL,
          PMUnityCryptid());
    if (PMUnityCryptid() == 1) {
        PMLog(@"⚠️ UnityFramework cryptid=1，应用未砸壳：内存补丁会被系统拦截，hook 很可能全部失效");
    }
    pm_apply_static_settings();
}
