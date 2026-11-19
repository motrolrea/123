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
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <ctype.h>

// ---------------------------------------------------------------------------
// 全局状态（悬浮球 / 设置页修改）
// ---------------------------------------------------------------------------
bool PMAutoPlay = true;
bool PMAllPerfect = false;
bool PMLockHP = false;
bool PMShowLifeBar = true;
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
bool PMBallHidden = false;
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
static const size_t kOff_PI_SavedRating = 0x20;

// JudgeSystem / JudgeSlot / List 字段偏移
static const size_t kOff_JS_Slots = 0x10;
static const size_t kOff_JS_Time = 0x60;
static const size_t kOff_Slot_Result = 0x10;
static const size_t kOff_Slot_PerfectTime = 0x18;
// List<T> 内部：_items 在 0x10（指向 T[] 数组对象），_size 在 0x18；
// 数组元素区在数组对象的 +0x20。
static const size_t kOff_List_Items = 0x10;
static const size_t kOff_List_Size = 0x18;
static const size_t kOff_Array_Elements = 0x20;

// 返回 List 的元素起始指针与元素个数；非法时返回 NULL
static void **pm_list_items(void *list, int *outSize) {
    if (!list) return NULL;
    void *arr = *(void **)((char *)list + kOff_List_Items);
    int size = *(int *)((char *)list + kOff_List_Size);
    if (!arr || size <= 0 || size > 200000) return NULL;
    if (outSize) *outSize = size;
    return (void **)((char *)arr + kOff_Array_Elements);
}

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
    Dl_info dli;
    if (dladdr((void *)&pm_signal_handler, &dli) && dli.dli_fbase) {
        PMLog(@"本模块 base=%p, main base=%p", dli.dli_fbase, _dyld_get_image_header(0));
    }
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
static const char *(*il2cpp_class_get_namespace)(Il2CppClass *);
static Il2CppObject *(*il2cpp_array_new)(Il2CppClass *, size_t);
static Il2CppObject *(*il2cpp_object_new)(Il2CppClass *);
static Il2CppClass *(*il2cpp_array_class_get)(Il2CppClass *, uint32_t);
static const MethodInfo *(*il2cpp_class_get_methods)(Il2CppClass *, void **);
static const char *(*il2cpp_method_get_name)(const MethodInfo *);
static int (*il2cpp_method_get_param_count)(const MethodInfo *);
static bool (*il2cpp_method_is_generic)(const MethodInfo *);
static const Il2CppType *(*il2cpp_method_get_param)(const MethodInfo *, uint32_t);
static Il2CppClass *(*il2cpp_class_from_il2cpp_type)(const Il2CppType *);

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
    il2cpp_class_get_namespace = (__typeof__(il2cpp_class_get_namespace))dlsym(h, "il2cpp_class_get_namespace");
    il2cpp_array_new = (__typeof__(il2cpp_array_new))dlsym(h, "il2cpp_array_new");
    il2cpp_object_new = (__typeof__(il2cpp_object_new))dlsym(h, "il2cpp_object_new");
    il2cpp_array_class_get = (__typeof__(il2cpp_array_class_get))dlsym(h, "il2cpp_array_class_get");
    il2cpp_class_get_methods = (__typeof__(il2cpp_class_get_methods))dlsym(h, "il2cpp_class_get_methods");
    il2cpp_method_get_name = (__typeof__(il2cpp_method_get_name))dlsym(h, "il2cpp_method_get_name");
    il2cpp_method_get_param_count = (__typeof__(il2cpp_method_get_param_count))dlsym(h, "il2cpp_method_get_param_count");
    il2cpp_method_is_generic = (__typeof__(il2cpp_method_is_generic))dlsym(h, "il2cpp_method_is_generic");
    il2cpp_method_get_param = (__typeof__(il2cpp_method_get_param))dlsym(h, "il2cpp_method_get_param");
    il2cpp_class_from_il2cpp_type = (__typeof__(il2cpp_class_from_il2cpp_type))dlsym(h, "il2cpp_class_from_il2cpp_type");
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

static void pm_call_static_void(const char *klassName, const char *methodName) {
    Il2CppClass *k = pm_find_class(klassName);
    if (!k || !il2cpp_class_get_method_from_name) return;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, methodName, 0);
    if (m) il2cpp_runtime_invoke(m, NULL, NULL, NULL);
}

static bool pm_set_static_float(const char *klassName, const char *fieldName, float value) {    Il2CppClass *k = pm_find_class(klassName);
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
    int size = 0;
    void **items = pm_list_items(slots, &size);
    if (!items) return;
    float now = *(float *)((char *)self + kOff_JS_Time);

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

static void *pm_call_obj(void *obj, const char *name, int argc, void **args);
static Il2CppClass *pm_class_any_ns(const char *name, const char *ns);
static void pm_call_static_void(const char *klassName, const char *methodName);

static void pm_apply_collection_overrides(void *self) {
    if (!self) return;
    BOOL anyUnlock = PMUnlockCharacters || PMUnlockSkins || PMUnlockStories ||
                     PMUnlockTitles || PMUnlockBackgrounds;
    if (!PMProfileEnabled && !anyUnlock) return;
    pm_set_text_at(self, kOff_CM_Id, @"id");
    pm_set_text_at(self, kOff_CM_TotalPlayTime, @"playtime");
    pm_set_text_at(self, kOff_CM_TotalScore, @"totalscore");
    pm_set_text_at_ex(self, kOff_CM_Story, @"stories", PMUnlockStories);
    pm_set_text_at(self, kOff_CM_PlayCount, @"playcount");
    pm_set_text_at(self, kOff_CM_NoteDecrypted, @"note");
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

// 等级文本：官方主页是「Lv.34」，这里补上前缀
static void pm_set_level_at(void *self, size_t off) {
    if (!self) return;
    NSString *v = PMProfileValue(@"level");
    if (!v.length) return;
    NSString *s = [v.lowercaseString hasPrefix:@"lv"] ? v : [NSString stringWithFormat:@"Lv.%@", v];
    pm_set_component_text(*(void **)((char *)self + off), s);
}

static void pm_apply_playerinfo_overrides(void *self) {
    if (!self) return;
    static BOOL loggedOnce = NO;
    if (!loggedOnce) {
        loggedOnce = YES;
        PMLog(@"资料覆盖: rating=%@ level=%@ (共 %lu 项)",
              PMProfileValue(@"rating") ?: @"(空)",
              PMProfileValue(@"level") ?: @"(空)",
              (unsigned long)PMProfileText.count);
    }
    pm_set_level_at(self, kOff_PI_Level);
    NSString *rv = PMProfileValue(@"rating");
    if (rv.length) {
        // 左上角的「8.51」来自 savedRating / 100，评分图标也按同一阈值分级，
        // 所以直接改内部值再调官方刷新，数字和图标才会一起变。
        // 左上角的评分内部单位是 1/10000（反推：999900 显示为 99.9900），
        // 所以这里按 ×10000 写入，数字和图标才会和自定义值一致
        double r = rv.doubleValue;
        if (r < 0) r = 0;
        if (r > 9999.99) r = 9999.99;
        int32_t rating100 = (int32_t)llround(r * 10000.0);
        if (*(int32_t *)((char *)self + kOff_PI_SavedRating) != rating100) {
            *(int32_t *)((char *)self + kOff_PI_SavedRating) = rating100;
            pm_call_obj(self, "UpdateRatingDisplayOnSceneLoad", 0, NULL);
            PMLog(@"评分写入 savedRating=%d (=%.4f)", rating100, rating100 / 10000.0);
        }
    } else {
        pm_set_text_at(self, kOff_PI_Rating, @"rating");
        pm_set_text_at(self, kOff_PI_RatingSmall, @"rating");
    }
}

// 主界面左上角「欢迎回来 / 摇光」那一块是 CommonUserInfo（不是 PlayerInfoManager）。
// 它的评分同样是 savedRating / 100，图标按同一阈值取 sprite。
static void pm_apply_commonuserinfo_overrides(void *self) {
    if (!self) return;
    pm_set_level_at(self, 0x28);                   // levelText
    NSString *rv = PMProfileValue(@"rating");
    if (!rv.length) {
        pm_set_text_at(self, 0x78, @"rating");     // ratingText (TMP)
        pm_set_text_at(self, 0x80, @"rating");     // ratingSmallText (TMP)
        return;
    }
    double r = rv.doubleValue;
    if (r < 0) r = 0;
    if (r > 9999.99) r = 9999.99;
    int32_t r100 = (int32_t)llround(r * 10000.0);
    if (*(int32_t *)((char *)self + 0xE4) != r100) {
        *(int32_t *)((char *)self + 0xE4) = r100;
        pm_call_obj(self, "UpdateRatingDisplayOnSceneLoad", 0, NULL);
        PMLog(@"主界面左上角评分已设为 %.2f（图标同步）", r100 / 10000.0);
    }
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
static bool gSkinRecordsDone = false;

// 往游戏本地 KVDB 写一条记录（Upsert(string, object)）
static void pm_kvdb_upsert_int(const char *key, int val) {
    static Il2CppClass *kvdb = NULL;
    static Il2CppClass *i32 = NULL;
    static const MethodInfo *mUp = NULL;
    if (!kvdb) kvdb = pm_find_class("KVDB");
    if (!i32) i32 = pm_class_any_ns("Int32", "System");
    if (!kvdb || !i32 || !il2cpp_object_new || !il2cpp_runtime_invoke) return;
    if (!mUp) mUp = il2cpp_class_get_method_from_name(kvdb, "Upsert", 2);
    if (!mUp) return;
    Il2CppObject *boxed = il2cpp_object_new(i32);
    Il2CppString *k = il2cpp_string_new(key);
    if (!boxed || !k) return;
    *(int *)((char *)boxed + 0x10) = val;      // 装箱的 int 值在 +0x10
    void *args[2] = {k, boxed};
    il2cpp_runtime_invoke(mUp, NULL, args, NULL);
}

// 角色解锁判定走 SkinUnlockStorage.GetAll()（KVDB 键 /skinunlock/<皮肤名>），
// 只设 UnlockAll 不写记录的话角色列表仍然只有几个，所以这里把每条皮肤记录写进去。
static void pm_write_all_skin_records(void) {
    if (gSkinRecordsDone) return;
    Il2CppClass *smCls = pm_find_class("SkinManager");
    if (!smCls) return;
    FieldInfo *fInst = il2cpp_class_get_field_from_name(smCls, "instance");
    if (!fInst) return;
    void *inst = NULL;
    il2cpp_field_static_get_value(fInst, &inst);
    if ((uintptr_t)inst < 0x100000000ULL) return;
    void *skins = *(void **)((char *)inst + 0x20);
    int n = 0;
    void **items = pm_list_items(skins, &n);
    if (!items || n <= 0) return;

    char key[256];
    int written = 0;
    for (int i = 0; i < n; i++) {
        void *skin = items[i];
        if ((uintptr_t)skin < 0x100000000ULL) continue;
        void *nameObj = *(void **)((char *)skin + 0x10);
        char name[192] = {0};
        pm_il2cpp_string_ascii(nameObj, name, sizeof(name));
        if (!name[0] || strlen(name) > 150) continue;
        snprintf(key, sizeof(key), "/skinunlock/%s", name);
        pm_kvdb_upsert_int(key, 1);
        written++;
    }
    if (written > 0) {
        pm_call_static_void("KVDB", "Bump");
        pm_call_static_void("KVDB", "FlushStash");
        pm_call_static_void("PlayerHelper", "AutoSkinUnlockInvariance");
        pm_call_static_void("PlayerHelper", "RefreshInfo");
        gSkinRecordsDone = true;
        PMLog(@"已写入 %d 条皮肤解锁记录（本地 KVDB）", written);

        // 用游戏自己的接口读回来确认记录真的生效了
        Il2CppClass *stCls = pm_find_class("SkinUnlockStorage");
        const MethodInfo *mGetAll = stCls ? il2cpp_class_get_method_from_name(stCls, "GetAll", 0) : NULL;
        if (stCls && mGetAll && il2cpp_object_new) {
            void *boxed = il2cpp_object_new(stCls);
            Il2CppObject *list = boxed ? il2cpp_runtime_invoke(mGetAll, boxed, NULL, NULL) : NULL;
            PMLog(@"皮肤存储回读: GetAll() = %d 条", list ? *(int *)((char *)list + 0x18) : -1);
        }
    }
}

static void pm_apply_static_settings(void) {
    if (!PMIl2CppReady) return;

    bool unlock = __atomic_load_n(&PMUnlockAll, __ATOMIC_RELAXED);
    if (unlock != gUnlockAllWritten) {
        if (pm_set_static_bool("TrackUnlockStorage", "UnlockAll", unlock)) {
            gUnlockAllWritten = unlock;
            PMUnlockAllApplied = unlock;
        }
    }

    // 皮肤 / 故事 / 词典（背景等）本地全解锁；"收藏品全解锁"总开关也会带上
    static bool gSkinFailLogged = false, gStoryFailLogged = false, gDictFailLogged = false;
    bool skins = PMUnlockSkins || PMUnlockCollection;
    if (skins != gSkinUnlockWritten) {
        if (pm_set_static_bool("SkinUnlockStorage", "UnlockAll", skins)) {
            gSkinUnlockWritten = skins;
            gSkinFailLogged = false;
            PMLog(@"皮肤全解锁 = %d", skins);
            if (skins) {
                pm_call_static_void("PlayerHelper", "AutoSkinUnlockInvariance");
                pm_write_all_skin_records();
            }
        } else if (!gSkinFailLogged) {
            PMLog(@"写入 SkinUnlockStorage.UnlockAll 失败");
            gSkinFailLogged = true;
        }
    }
    if (skins) pm_write_all_skin_records();   // 失败会在下次重试
    bool stories = PMUnlockStories || PMUnlockCollection;
    if (stories != gStoryUnlockWritten) {
        if (pm_set_static_bool("StoryUnlockStorage", "UnlockAll", stories)) {
            gStoryUnlockWritten = stories;
            gStoryFailLogged = false;
        } else if (!gStoryFailLogged) {
            PMLog(@"写入 StoryUnlockStorage.UnlockAll 失败");
            gStoryFailLogged = true;
        }
    }
    bool dict = PMUnlockBackgrounds || PMUnlockCollection;
    if (dict != gDictUnlockWritten) {
        if (pm_set_static_bool("DictStorage", "UnlockAll", dict)) {
            gDictUnlockWritten = dict;
            gDictFailLogged = false;
        } else if (!gDictFailLogged) {
            PMLog(@"写入 DictStorage.UnlockAll 失败");
            gDictFailLogged = true;
        }
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
static Il2CppClass *gCUIClass = NULL;      // 主界面左上角「欢迎回来 / 评分」控件
static void *gCUI_Obj = NULL;
static void *gCUI_Handle = NULL;
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
    uint8_t includeInactive = 1;   // 有些不活跃的 UI（主菜单资料栏）也要能找到
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

static Il2CppClass *pm_class_in_namespace(const char *name, const char *ns, const char *method, int argc) {
    Il2CppDomain *domain = il2cpp_domain_get();
    if (!domain) return NULL;
    if (il2cpp_thread_attach) il2cpp_thread_attach(domain);
    size_t count = 0;
    const Il2CppAssembly **asms = il2cpp_domain_get_assemblies(domain, &count);
    if (!asms || count == 0) return NULL;
    if (!il2cpp_image_get_class_count || !il2cpp_image_get_class) return NULL;
    for (size_t i = 0; i < count; i++) {
        Il2CppImage *img = il2cpp_assembly_get_image(asms[i]);
        if (!img) continue;
        size_t n = il2cpp_image_get_class_count(img);
        if (n > 40000) n = 40000;
        for (size_t j = 0; j < n; j++) {
            Il2CppClass *c = il2cpp_image_get_class(img, j);
            if (!c) continue;
            const char *cn = il2cpp_class_get_name(c);
            if (!cn || strcmp(cn, name)) continue;
            const char *cns = il2cpp_class_get_namespace ? il2cpp_class_get_namespace(c) : "";
            if (ns && (!cns || strcmp(cns, ns))) continue;
            if (method && !il2cpp_class_get_method_from_name(c, method, argc)) continue;
            return c;
        }
    }
    return NULL;
}

static void *pm_call_obj(void *obj, const char *name, int argc, void **args) {
    if (!obj || !il2cpp_object_get_class) return NULL;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)obj);
    if (!k) return NULL;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, name, argc);
    if (!m) return NULL;
    Il2CppException *exc = NULL;
    return il2cpp_runtime_invoke(m, obj, args, &exc);
}

static void *gModPageGO = NULL;
static BOOL gEntryInjected = NO;
static CFTimeInterval gSettingsSeenAt = 0;
static Il2CppClass *gTabClass = NULL;
static Il2CppClass *gTitleCellClass = NULL;
static Il2CppClass *gChoiceCellClass = NULL;
static Il2CppClass *gNumIntClass = NULL;   // GenericSettingsPanel.NumericCellInt
static void *gNumIntFmt = NULL;            // 它的 Func<int,string>（官方实例上借来用）
static Il2CppClass *gNumFloatClass = NULL; // GenericSettingsPanel.NumericCellFloat
static void *gNumFloatFmt = NULL;          // 它的 Func<float,string>
static const MethodInfo *gPrefGetIntM = NULL;

// ---- 在官方设置里注册一个真正的「Mod设置」页（复用官方 Tab / Cell 控件） ----

static Il2CppClass *pm_class_any_ns(const char *name, const char *ns) {
    return pm_class_in_namespace(name, ns, NULL, 0);
}

static Il2CppClass *pm_string_class(void) {
    static Il2CppClass *k = NULL;
    if (!k) {
        Il2CppString *s = il2cpp_string_new("");
        if (s) k = *(Il2CppClass **)s;
    }
    return k;
}

static Il2CppClass *pm_int_class(void) {
    static Il2CppClass *k = NULL;
    if (!k) k = pm_class_any_ns("Int32", "System");
    return k;
}

static Il2CppObject *pm_make_string_array(const char **vals, int n) {
    Il2CppClass *s = pm_string_class();
    if (!s || !il2cpp_array_new) return NULL;
    Il2CppObject *a = il2cpp_array_new(s, (size_t)n);
    if (!a) return NULL;
    void **p = (void **)((char *)a + 0x20);
    for (int i = 0; i < n; i++) p[i] = il2cpp_string_new(vals[i]);
    return a;
}

static Il2CppObject *pm_make_int_array(const int *vals, int n) {
    Il2CppClass *s = pm_int_class();
    if (!s || !il2cpp_array_new) return NULL;
    Il2CppObject *a = il2cpp_array_new(s, (size_t)n);
    if (!a) return NULL;
    int *p = (int *)((char *)a + 0x20);
    for (int i = 0; i < n; i++) p[i] = vals[i];
    return a;
}

static void *pm_new_title_cell(const char *label) {
    if (!gTitleCellClass || !il2cpp_object_new) return NULL;
    void *obj = il2cpp_object_new(gTitleCellClass);
    const MethodInfo *m = il2cpp_class_get_method_from_name(gTitleCellClass, ".ctor", 2);
    if (!obj || !m) return NULL;
    Il2CppString *l = il2cpp_string_new(label);
    Il2CppString *t = il2cpp_string_new("");
    void *args[2] = {l, t};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, obj, args, &exc);
    return exc ? NULL : obj;
}

// 官方 ChoiceCell<int>：两个选项，结果直接写进 PlayerPrefs
static void *pm_new_choice_cell2(const char *label, const char *prefKey, int def,
                                 const char *l0, const char *l1) {
    if (!gChoiceCellClass || !il2cpp_object_new) return NULL;
    void *obj = il2cpp_object_new(gChoiceCellClass);
    const MethodInfo *m = il2cpp_class_get_method_from_name(gChoiceCellClass, ".ctor", 6);
    if (!obj || !m) return NULL;
    Il2CppString *l = il2cpp_string_new(label);
    Il2CppString *t = il2cpp_string_new("");
    Il2CppString *k = il2cpp_string_new(prefKey);
    int32_t d = def;
    const char *labels[2] = {l0, l1};
    int vals[2] = {0, 1};
    Il2CppObject *la = pm_make_string_array(labels, 2);
    Il2CppObject *va = pm_make_int_array(vals, 2);
    if (!l || !k || !la || !va) return NULL;
    void *args[6] = {l, t, k, &d, la, va};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, obj, args, &exc);
    return exc ? NULL : obj;
}

static void *pm_new_choice_cell(const char *label, const char *prefKey, int def) {
    return pm_new_choice_cell2(label, prefKey, def, "关闭", "开启");
}

static void pm_log_exc(const char *tag, void *exc);

// 官方 NumericCellInt：带 -/+ 的整数行（formatter 借用官方实例上的委托）
static void *pm_new_numeric_int_cell(const char *label, const char *prefKey,
                                     int lower, int upper, int step, int def) {
    if (!gNumIntClass || !gNumIntFmt || !il2cpp_object_new) return NULL;
    const MethodInfo *m = il2cpp_class_get_method_from_name(gNumIntClass, ".ctor", 8);
    void *obj = m ? il2cpp_object_new(gNumIntClass) : NULL;
    if (!obj) return NULL;
    Il2CppString *l = il2cpp_string_new(label);
    Il2CppString *t = il2cpp_string_new("");
    Il2CppString *k = il2cpp_string_new(prefKey);
    int a = lower, b = upper, c = step, d = def;
    void *args[8] = {l, t, k, &a, &b, &c, &d, gNumIntFmt};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, obj, args, &exc);
    if (exc) { pm_log_exc("NumericCellInt", exc); return NULL; }
    return obj;
}

// 官方 NumericCellFloat：带滑条的浮点行
static void *pm_new_numeric_float_cell(const char *label, const char *prefKey,
                                       float lower, float upper, float step, float def) {
    if (!gNumFloatClass || !gNumFloatFmt || !il2cpp_object_new) return NULL;
    const MethodInfo *m = il2cpp_class_get_method_from_name(gNumFloatClass, ".ctor", 11);
    void *obj = m ? il2cpp_object_new(gNumFloatClass) : NULL;
    if (!obj) return NULL;
    Il2CppString *l = il2cpp_string_new(label);
    Il2CppString *t = il2cpp_string_new("");
    Il2CppString *k = il2cpp_string_new(prefKey);
    float a = lower, b = upper, c = step, d = def, sens = 1.0f;
    Il2CppString *lh = il2cpp_string_new("-");
    Il2CppString *uh = il2cpp_string_new("+");
    void *args[11] = {l, t, k, &a, &b, &c, &d, gNumFloatFmt, lh, uh, &sens};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, obj, args, &exc);
    if (exc) { pm_log_exc("NumericCellFloat", exc); return NULL; }
    return obj;
}

// 把页面大标题文本改成「Mod设置」
static void pm_set_page_title(void *pageGO, void *oldTitle) {
    if (!oldTitle) return;
    Il2CppClass *textCls = pm_class_any_ns("Text", "UnityEngine.UI");
    if (!textCls || !il2cpp_class_get_type || !il2cpp_type_get_object) return;
    char oldBuf[128] = {0};
    pm_il2cpp_string_ascii(oldTitle, oldBuf, sizeof(oldBuf));
    if (!oldBuf[0]) return;
    void *typeObj = il2cpp_type_get_object(il2cpp_class_get_type(textCls));
    if (!typeObj) return;
    void *args[1] = {typeObj};
    Il2CppObject *comps = (Il2CppObject *)pm_call_obj(pageGO, "GetComponentsInChildren", 1, args);
    if (!comps) return;
    int n = *(int *)((char *)comps + 0x18);
    void **items = (void **)((char *)comps + 0x20);
    if (n <= 0 || n > 20000 || !items) return;
    Il2CppString *newTitle = il2cpp_string_new("Mod设置");
    for (int i = 0; i < n; i++) {
        void *txt = items[i];
        if (!txt) continue;
        void *cur = pm_call_obj(txt, "get_text", 0, NULL);
        if (!cur) continue;
        char buf[128] = {0};
        pm_il2cpp_string_ascii(cur, buf, sizeof(buf));
        if (strcmp(buf, oldBuf)) continue;
        void *targs[1] = {newTitle};
        pm_call_obj(txt, "set_text", 1, targs);
    }
}

// 扫描现有设置项，拿到官方 TitleCell / ChoiceCell<int> 的具体类
static BOOL pm_ptr_ok(const void *p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x100000000ULL && (v & 7) == 0;
}

static const char *pm_obj_class_name(void *obj) {
    if (!pm_ptr_ok(obj)) return "null";
    Il2CppClass *k = *(Il2CppClass **)obj;
    return pm_ptr_ok(k) ? il2cpp_class_get_name(k) : "?";
}

// 安全读取 Tab.cells，返回数量；-1 表示这个 Tab 指针不可信
static int pm_tab_cells(void *tab, void ***outItems) {
    if (!pm_ptr_ok(tab)) return -1;
    void *cells = *(void **)((char *)tab + 0x28);
    if (!cells) return 0;
    if (!pm_ptr_ok(cells)) return -1;
    int cn = 0;
    void **items = pm_list_items(cells, &cn);
    if (!items) return 0;
    if (outItems) *outItems = items;
    return cn;
}

static BOOL gNumIntFmtPlain = NO, gNumFloatFmtPlain = NO;

// 试调用 formatter(42)，只由数字/小数点组成的才拿来显示（避免出现「1 UNIT」）
static BOOL pm_fmt_plain(void *del, BOOL isFloat) {
    if (!pm_ptr_ok(del)) return NO;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)del);
    if (!k) return NO;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, "Invoke", 1);
    if (!m) return NO;
    void *out = NULL;
    if (isFloat) {
        float v = 42.5f;
        void *a[1] = {&v};
        out = il2cpp_runtime_invoke(m, del, a, NULL);
    } else {
        int32_t v = 42;
        void *a[1] = {&v};
        out = il2cpp_runtime_invoke(m, del, a, NULL);
    }
    if (!out) return NO;
    char buf[64] = {0};
    pm_il2cpp_string_ascii(out, buf, sizeof(buf));
    if (!buf[0]) return NO;
    for (const char *p = buf; *p; p++) {
        if (!isdigit((unsigned char)*p) && *p != '.' && *p != '-' && *p != ' ') return NO;
    }
    return YES;
}

static void pm_scan_cell_classes(void *tabs, int tn, void **titems) {
    int bad = 0;
    for (int i = 0; i < tn; i++) {
        void **citems = NULL;
        int cn = pm_tab_cells(titems[i], &citems);
        if (cn < 0) {
            if (bad++ < 3) PMLog(@"Mod页: tab[%d]=%p 指针异常", i, titems[i]);
            continue;
        }
        if (cn == 0) continue;
        for (int j = 0; j < cn; j++) {
            void *cell = citems[j];
            if (!pm_ptr_ok(cell)) continue;
            Il2CppClass *k = *(Il2CppClass **)cell;
            if (!pm_ptr_ok(k)) continue;
            const char *name = il2cpp_class_get_name(k);
            if (!name) continue;
            if (!gTitleCellClass && strcmp(name, "TitleCell") == 0) gTitleCellClass = k;
            if (!gChoiceCellClass && strncmp(name, "ChoiceCell", 10) == 0) gChoiceCellClass = k;
            if (strcmp(name, "NumericCellInt") == 0) {
                void *fmt = *(void **)((char *)cell + 0x68);
                if (pm_ptr_ok(fmt)) {
                    BOOL plain = pm_fmt_plain(fmt, NO);
                    if (!gNumIntClass || (plain && !gNumIntFmtPlain)) {
                        gNumIntClass = k; gNumIntFmt = fmt; gNumIntFmtPlain = plain;
                    }
                }
            }
            if (strcmp(name, "NumericCellFloat") == 0) {
                void *fmt = *(void **)((char *)cell + 0x60);
                if (pm_ptr_ok(fmt)) {
                    BOOL plain = pm_fmt_plain(fmt, YES);
                    if (!gNumFloatClass || (plain && !gNumFloatFmtPlain)) {
                        gNumFloatClass = k; gNumFloatFmt = fmt; gNumFloatFmtPlain = plain;
                    }
                }
            }
            if (gTitleCellClass && gChoiceCellClass && gNumIntFmtPlain && gNumFloatFmtPlain) return;
        }
    }
}

// 官方「打击音量」那一行的上限改成 150（用 prefKey 里的 hit 来认，label 是中文没法匹配）
static void pm_raise_hit_volume_cap(void *tabs, int tn, void **titems) {
    for (int i = 0; i < tn; i++) {
        void **citems = NULL;
        int cn = pm_tab_cells(titems[i], &citems);
        if (cn <= 0) continue;
        for (int j = 0; j < cn; j++) {
            void *cell = citems[j];
            if (!pm_ptr_ok(cell)) continue;
            Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)cell);
            const char *name = k ? il2cpp_class_get_name(k) : NULL;
            if (!name || strncmp(name, "NumericCell", 11) != 0) continue;
            void *pk = *(void **)((char *)cell + 0x38);
            char buf[160] = {0};
            if (!pk) continue;
            pm_il2cpp_string_ascii(pk, buf, sizeof(buf));
            if (!buf[0]) continue;
            if (!pm_contains_ci(buf, "hit")) {
                PMLog(@"Mod页: 数值行 %s (%s)", name, buf);
                continue;
            }
            if (strstr(name, "Float") || strstr(name, "Slide")) {
                float *up = (float *)((char *)cell + 0x48);
                if (*up < 1.5f) {
                    *up = 1.5f;
                    PMLog(@"Mod页: %s 上限 -> 150%% (%s)", name, buf);
                }
            } else {
                int32_t *up = (int32_t *)((char *)cell + 0x48);
                if (*up < 150) {
                    *up = 150;
                    PMLog(@"Mod页: %s 上限 -> 150 (%s)", name, buf);
                }
            }
        }
    }
}

static BOOL pm_tab_has_choice(void *tab) {
    void **citems = NULL;
    int cn = pm_tab_cells(tab, &citems);
    if (cn <= 0) return NO;
    for (int j = 0; j < cn; j++) {
        void *cell = citems[j];
        if (!pm_ptr_ok(cell)) continue;
        Il2CppClass *k = *(Il2CppClass **)cell;
        const char *name = pm_ptr_ok(k) ? il2cpp_class_get_name(k) : NULL;
        if (name && strncmp(name, "ChoiceCell", 10) == 0) return YES;
    }
    return NO;
}

// 模板页里是否有标题分区原型（同页必须已经用过 TitleCell，原型才存在）
static BOOL pm_tab_has_title(void *tab) {
    void **citems = NULL;
    int cn = pm_tab_cells(tab, &citems);
    if (cn <= 0) return NO;
    for (int j = 0; j < cn; j++) {
        void *cell = citems[j];
        if (!pm_ptr_ok(cell)) continue;
        Il2CppClass *k = *(Il2CppClass **)cell;
        const char *name = pm_ptr_ok(k) ? il2cpp_class_get_name(k) : NULL;
        if (name && strcmp(name, "TitleCell") == 0) return YES;
    }
    return NO;
}

// 评估一个设置面板实例是否已经建好 Tab（多实例时可挑最完整的）
static int pm_panel_score(void *gsp) {
    if (!pm_ptr_ok(gsp)) return -1;
    void *tabs = *(void **)((char *)gsp + 0x40);
    void *pages = *(void **)((char *)gsp + 0x58);
    if (!pm_ptr_ok(tabs) || !pm_ptr_ok(pages)) return -1;
    int tn = *(int *)((char *)tabs + 0x18);
    void **items = *(void ***)((char *)tabs + 0x10);
    if (tn <= 0 || tn > 200 || !pm_ptr_ok(items)) return -1;
    int score = 0;
    for (int i = 0; i < tn; i++) {
        if (pm_tab_cells(items[i], NULL) > 0) score++;
    }
    int pn = *(int *)((char *)pages + 0x18);
    if (pn > 0 && pn < 64) score += pn;
    return score;
}

// 当前实例 Tab 不可信时，在所有设置面板里挑一个建好的
static void *pm_find_better_panel(void *cur) {
    if (!gFindTypesHost || !il2cpp_class_get_type || !il2cpp_type_get_object) return NULL;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)cur);
    if (!k) return NULL;
    void *typeObj = il2cpp_type_get_object(il2cpp_class_get_type(k));
    const MethodInfo *m = il2cpp_class_get_method_from_name(gFindTypesHost, "FindObjectsOfType", 1);
    if (!typeObj || !m) return NULL;
    void *args[1] = {typeObj};
    Il2CppObject *arr = il2cpp_runtime_invoke(m, NULL, args, NULL);
    if (!arr) return NULL;
    int n = *(int *)((char *)arr + 0x18);
    void **items = *(void ***)((char *)arr + 0x20);
    if (n <= 0 || n > 64 || !pm_ptr_ok(items)) return NULL;
    int bestScore = pm_panel_score(cur);
    void *best = NULL;
    for (int i = 0; i < n; i++) {
        int s = pm_panel_score(items[i]);
        if (s > bestScore) { bestScore = s; best = items[i]; }
    }
    return best;
}

static void pm_tab_add_cell(void *tab, void *cell) {    if (!tab || !cell) return;
    void *a[1] = {cell};
    pm_call_obj(tab, "Add", 1, a);
}

static int pm_child_count(void *tr) {
    if (!pm_ptr_ok(tr)) return -1;
    Il2CppObject *boxed = (Il2CppObject *)pm_call_obj(tr, "get_childCount", 0, NULL);
    return boxed ? *(int *)((char *)boxed + 0x10) : -1;
}

// il2cpp_class_get_method_from_name 会返回泛型版本（如 Instantiate<T>），
// 泛型定义无法直接用 runtime_invoke 调，这里按名字/参数个数挑非泛型的那个。
static const MethodInfo *pm_method_nongeneric(Il2CppClass *k, const char *name, int argc) {
    if (!k || !il2cpp_class_get_methods) return NULL;
    void *iter = NULL;
    const MethodInfo *m = NULL;
    while ((m = il2cpp_class_get_methods(k, &iter)) != NULL) {
        const char *n = il2cpp_method_get_name ? il2cpp_method_get_name(m) : NULL;
        if (!n || strcmp(n, name) != 0) continue;
        int pc = il2cpp_method_get_param_count ? il2cpp_method_get_param_count(m) : -1;
        if (pc != argc) continue;
        if (il2cpp_method_is_generic && il2cpp_method_is_generic(m)) continue;
        return m;
    }
    return NULL;
}

// 按「名字 + 参数个数 + 参数类型名」精确挑方法：
// Instantiate 有多个 3 参数重载（Vector3/Quaternion 版 与 Transform/bool 版），
// 只按个数匹配会选错，导致克隆静默失败。
static const MethodInfo *pm_method_exact(Il2CppClass *k, const char *name, int argc, const char *const *want) {
    if (!k || !il2cpp_class_get_methods || !il2cpp_method_get_param) return NULL;
    void *iter = NULL;
    const MethodInfo *m = NULL;
    while ((m = il2cpp_class_get_methods(k, &iter)) != NULL) {
        const char *n = il2cpp_method_get_name ? il2cpp_method_get_name(m) : NULL;
        if (!n || strcmp(n, name) != 0) continue;
        if (il2cpp_method_get_param_count && il2cpp_method_get_param_count(m) != argc) continue;
        if (il2cpp_method_is_generic && il2cpp_method_is_generic(m)) continue;
        BOOL ok = YES;
        for (int i = 0; i < argc && ok; i++) {
            const Il2CppType *pt = il2cpp_method_get_param(m, (uint32_t)i);
            Il2CppClass *pc = (pt && il2cpp_class_from_il2cpp_type) ? il2cpp_class_from_il2cpp_type(pt) : NULL;
            const char *pn = pc ? il2cpp_class_get_name(pc) : NULL;
            if (!pn || strcmp(pn, want[i]) != 0) ok = NO;
        }
        if (ok) return m;
    }
    return NULL;
}

static void *pm_get_child(void *tr, int idx) {
    if (!pm_ptr_ok(tr)) return NULL;
    int32_t i = idx;
    void *a[1] = {&i};
    return pm_call_obj(tr, "GetChild", 1, a);
}

static void pm_go_set_active(void *go, bool active) {
    if (!go) return;
    uint8_t v = active ? 1 : 0;
    void *a[1] = {&v};
    pm_call_obj(go, "SetActive", 1, a);
}

static void pm_log_exc(const char *tag, void *exc) {
    if (!exc) return;
    char msg[512] = {0};
    void *m = pm_call_obj(exc, "get_Message", 0, NULL);
    if (m) pm_il2cpp_string_ascii(m, msg, sizeof(msg));
    PMLog(@"%s: 托管异常 %s: %s", tag, pm_obj_class_name(exc), msg);
}

// 侧栏新按钮位置：预制体克隆会叠在第一个按钮上，这里按官方最后两个按钮的间距推算
static BOOL pm_get_local_pos(void *tr, float out[3]) {
    if (!pm_ptr_ok(tr)) return NO;
    void *v = pm_call_obj(tr, "get_localPosition", 0, NULL);
    if (!v) return NO;
    out[0] = *(float *)((char *)v + 0x10);
    out[1] = *(float *)((char *)v + 0x14);
    out[2] = *(float *)((char *)v + 0x18);
    return YES;
}

static void pm_set_local_pos(void *tr, float v[3]) {
    if (!pm_ptr_ok(tr) || !il2cpp_object_get_class) return;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)tr);
    const MethodInfo *m = k ? il2cpp_class_get_method_from_name(k, "set_localPosition", 1) : NULL;
    if (!m) return;
    void *a[1] = {v};
    Il2CppException *ex = NULL;
    il2cpp_runtime_invoke(m, tr, a, &ex);
    if (ex) pm_log_exc("Mod页: 设置按钮位置", ex);
}

static void pm_list_remove_last(void *list) {
    if (!pm_ptr_ok(list)) return;
    int n = *(int *)((char *)list + 0x18);
    if (n <= 0) return;
    int32_t i = n - 1;
    void *a[1] = {&i};
    pm_call_obj(list, "RemoveAt", 1, a);
}

static BOOL pm_name_is_clone(const char *nb) {
    size_t len = strlen(nb);
    return len >= 7 && strcmp(nb + len - 7, "(Clone)") == 0;
}

// 克隆一个官方页后，把页里已经生成的行「隐藏」掉（不要 Destroy：
// 销毁后组件数组里还留着野指针，继续访问会直接把进程打崩）
static int pm_hide_cloned_rows(void *tr, int depth) {
    if (!pm_ptr_ok(tr) || depth > 8) return 0;
    int n = pm_child_count(tr);
    if (n <= 0 || n > 500) return 0;
    int hidden = 0;
    for (int i = 0; i < n; i++) {
        void *c = pm_get_child(tr, i);
        if (!pm_ptr_ok(c)) continue;
        void *go = pm_call_obj(c, "get_gameObject", 0, NULL);
        void *nm = go ? pm_call_obj(go, "get_name", 0, NULL) : NULL;
        char nb[192] = {0};
        if (nm) pm_il2cpp_string_ascii(nm, nb, sizeof(nb));
        if (pm_name_is_clone(nb)) {
            pm_go_set_active(go, false);
            hidden++;
            continue;   // 整行隐藏即可，不用再往下走
        }
        hidden += pm_hide_cloned_rows(c, depth + 1);
    }
    return hidden;
}

// 官方设置面板上的 Mod 注册状态（按实例记录，便于面板重建后重新注入）
static void *gPatchedGsp = NULL;
static void *gTriedGsp = NULL;
static int gTriedCount = 0;
static void *gModTabObj = NULL;
static void *gModTabGO = NULL;   // 侧栏 Mod设置 按钮的 GameObject

static void *pm_tab_animator(void *go) {
    if (!pm_ptr_ok(go)) return NULL;
    Il2CppClass *animCls = pm_class_any_ns("Animator", "UnityEngine");
    if (!animCls || !il2cpp_class_get_type || !il2cpp_type_get_object) return NULL;
    void *t = il2cpp_type_get_object(il2cpp_class_get_type(animCls));
    if (!t) return NULL;
    void *a[1] = {t};
    return pm_call_obj(go, "GetComponent", 1, a);
}

static int pm_tab_active(void *go) {
    void *anim = pm_tab_animator(go);
    if (!anim) return -1;
    Il2CppString *k = il2cpp_string_new("TabActive");
    void *a[1] = {k};
    void *boxed = pm_call_obj(anim, "GetBool", 1, a);
    return boxed ? *(uint8_t *)((char *)boxed + 0x10) : -1;
}

static void pm_set_tab_active(void *go, BOOL on) {
    void *anim = pm_tab_animator(go);
    if (!anim) return;
    Il2CppString *k = il2cpp_string_new("TabActive");
    uint8_t b = on ? 1 : 0;
    void *a[2] = {k, &b};
    pm_call_obj(anim, "SetBool", 2, a);
}

// 面板可能把某个侧栏按钮留在 EventSystem 的「已选中」状态，这里清一次
static void pm_clear_event_selection(void) {
    Il2CppClass *es = pm_class_any_ns("EventSystem", "UnityEngine.EventSystems");
    if (!es) return;
    const MethodInfo *mc = il2cpp_class_get_method_from_name(es, "get_current", 0);
    if (!mc) return;
    Il2CppObject *cur = il2cpp_runtime_invoke(mc, NULL, NULL, NULL);
    if (!cur) return;
    const MethodInfo *ms = il2cpp_class_get_method_from_name(es, "SetSelectedGameObject", 1);
    if (!ms) return;
    void *a[1] = {NULL};
    il2cpp_runtime_invoke(ms, cur, a, NULL);
}

// 官方点击时只批量关一次 TabActive，面板重建/动画残留会漏；
// 只要我们的页处于选中态，就把其它侧栏项逐个关掉，再把自己点亮
static void pm_keep_mod_tab_selected(void *gsp) {
    if (!pm_ptr_ok(gsp) || !pm_ptr_ok(gModTabGO)) return;
    BOOL mine = NO;
    if (pm_ptr_ok(gModPageGO)) {
        void *a = pm_call_obj(gModPageGO, "get_activeSelf", 0, NULL);
        if (a && *(uint8_t *)((char *)a + 0x10)) mine = YES;
    }
    if (!mine) return;
    void *tabs = *(void **)((char *)gsp + 0x40);
    int n = 0;
    void **items = pm_list_items(tabs, &n);
    for (int i = 0; i < n && items; i++) {
        if (!pm_ptr_ok(items[i]) || items[i] == gModTabObj) continue;
        uint8_t f = 0;
        void *a[1] = {&f};
        pm_call_obj(items[i], "SetActive", 1, a);
    }
    pm_set_tab_active(gModTabGO, YES);
    pm_clear_event_selection();
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        for (int i = 0; i < n && items; i++) {
            void *t = items[i];
            if (!pm_ptr_ok(t)) continue;
            void *go = *(void **)((char *)t + 0x10);
            void *nm = go ? pm_call_obj(go, "get_name", 0, NULL) : NULL;
            char nb[96] = {0};
            if (nm) pm_il2cpp_string_ascii(nm, nb, sizeof(nb));
            PMLog(@"Mod页: 清理后 tab[%d]=%s tabActive=%d", i, nb, pm_tab_active(go));
        }
    }
}

static BOOL pm_panel_has_mod_tab(void *gsp) {
    if (!pm_ptr_ok(gsp) || !pm_ptr_ok(gModTabObj)) return NO;
    void *tabs = *(void **)((char *)gsp + 0x40);
    int n = 0;
    void **items = pm_list_items(tabs, &n);
    if (!items) return NO;
    for (int i = 0; i < n; i++) {
        if (items[i] == gModTabObj) return YES;
    }
    return NO;
}

// 官方 Tab.Layout 处理第一行时会取 gsp.unboundedMenus[viewPageIndex]，
// 我们的页索引是新增的，必须把列表补齐，否则 List.get_Item 直接下标越界。
// 补进去的菜单是「只存在于托管堆的空壳」：不在场景里、Update 不会跑，
// 只带一个 animator 和我们按钮一致的 item，让官方的 First(...) 能命中。
static void pm_pad_unbounded_menus(void *gsp, int pageIndex, void *tabGO) {
    void *um = *(void **)((char *)gsp + 0x28);
    if (!pm_ptr_ok(um)) {
        PMLog(@"Mod页: unboundedMenus 不可用 %p", um);
        return;
    }
    int n0 = 0;
    void **uitems = pm_list_items(um, &n0);
    void *menu0 = (uitems && n0 > 0 && pm_ptr_ok(uitems[0])) ? uitems[0] : NULL;
    Il2CppClass *menuCls = NULL, *itemCls = NULL;
    void *it0 = NULL;
    if (pm_ptr_ok(menu0)) {
        menuCls = il2cpp_object_get_class((Il2CppObject *)menu0);
        void *it0Arr = *(void **)((char *)menu0 + 0x20);
        if (pm_ptr_ok(it0Arr) && *(int *)((char *)it0Arr + 0x18) > 0) {
            void *p = *(void **)((char *)it0Arr + 0x20);
            if (pm_ptr_ok(p)) { it0 = p; itemCls = il2cpp_object_get_class((Il2CppObject *)p); }
        }
    }
    if (!menuCls) menuCls = pm_class_any_ns("UnboundedMenu", NULL);
    if (!itemCls) itemCls = pm_class_any_ns("MenuItemWithSub", NULL);
    if (!menuCls || !itemCls) {
        PMLog(@"Mod页: 找不到 UnboundedMenu 类 menu=%p item=%p", menuCls, itemCls);
        return;
    }
    // 我们按钮上的 Animator（取不到也没关系：官方判定两边都为 null 时同样成立）
    void *anim = NULL;
    Il2CppClass *animCls = pm_class_any_ns("Animator", "UnityEngine");
    if (animCls && tabGO && il2cpp_class_get_type && il2cpp_type_get_object) {
        void *t = il2cpp_type_get_object(il2cpp_class_get_type(animCls));
        if (t) {
            void *a1[1] = {t};
            anim = pm_call_obj(tabGO, "GetComponent", 1, a1);
        }
    }
    int count = *(int *)((char *)um + 0x18);
    int guard = 0;
    while (count <= pageIndex && guard++ < 8) {
        Il2CppObject *arr = il2cpp_array_new(itemCls, 1);
        void *dup = il2cpp_object_new(menuCls);
        void *it = il2cpp_object_new(itemCls);
        if (!arr || !dup || !it) break;
        *(void **)((char *)it + 0x10) = anim;
        if (it0) {
            *(void **)((char *)it + 0x18) = *(void **)((char *)it0 + 0x18);
            *(void **)((char *)it + 0x20) = *(void **)((char *)it0 + 0x20);
        }
        if (menu0) *(void **)((char *)dup + 0x28) = *(void **)((char *)menu0 + 0x28);
        ((void **)((char *)arr + 0x20))[0] = it;
        *(void **)((char *)dup + 0x20) = arr;
        void *a[1] = {dup};
        pm_call_obj(um, "Add", 1, a);
        int nn = *(int *)((char *)um + 0x18);
        if (nn == count) break;
        count = nn;
    }
    PMLog(@"Mod页: unboundedMenus 补齐 -> %d (需要 > %d)", count, pageIndex);
}

// 构建「Mod设置」页：克隆一个官方页做模板，再通过官方 Add() 注册 Tab
static BOOL pm_build_mod_tab(void *gsp) {
    if (!gsp || !gFindTypesHost || !il2cpp_object_new || !il2cpp_array_new) return NO;
    // 重试计数按「面板实例」算：退出设置再进来游戏会换/重建面板，得能重新注入
    if (gTriedGsp != gsp) { gTriedGsp = gsp; gTriedCount = 0; }
    if (gTriedCount >= 6) return YES;
    gTriedCount++;
    if (pm_panel_score(gsp) <= 0) {
        void *better = pm_find_better_panel(gsp);
        if (better) {
            PMLog(@"Mod页: 换用已建好的设置面板 %p -> %p", gsp, better);
            gsp = better;
        }
    }
    if (gPatchedGsp == gsp) return YES;   // 同一个设置面板只注册一次
    void *tabs = *(void **)((char *)gsp + 0x40);
    void *pages = *(void **)((char *)gsp + 0x58);
    if (!pm_ptr_ok(tabs) || !pm_ptr_ok(pages)) {
        PMLog(@"Mod页: 面板字段异常 gsp=%p tabs=%p pages=%p", gsp, tabs, pages);
        return NO;
    }
    int tn = 0;
    void **titems = pm_list_items(tabs, &tn);
    if (!titems || tn > 200) {
        PMLog(@"Mod页: tabs 数量异常 %d items=%p", tn, titems);
        return NO;
    }
    PMLog(@"Mod页: 开始注入 gsp=%p tabs=%d pages=%d", gsp, tn, *(int *)((char *)pages + 0x18));
    PMLog(@"Mod页: tabs类=%s t0=%p(%s) t1=%p t2=%p t3=%p", pm_obj_class_name(tabs),
          titems[0], pm_obj_class_name(titems[0]),
          tn > 1 ? titems[1] : NULL, tn > 2 ? titems[2] : NULL, tn > 3 ? titems[3] : NULL);
    if (tn > 0 && pm_ptr_ok(titems[0])) {
        void *t0 = titems[0];
        PMLog(@"Mod页: tab0 +10=%p(%s) +18=%p(%s) +20=%p +28=%p(%s)",
              *(void **)((char *)t0 + 0x10), pm_obj_class_name(*(void **)((char *)t0 + 0x10)),
              *(void **)((char *)t0 + 0x18), pm_obj_class_name(*(void **)((char *)t0 + 0x18)),
              *(void **)((char *)t0 + 0x20),
              *(void **)((char *)t0 + 0x28), pm_obj_class_name(*(void **)((char *)t0 + 0x28)));
    }

    if (!gTabClass && pm_ptr_ok(titems[0])) {
        Il2CppClass *k0 = *(Il2CppClass **)titems[0];
        if (pm_ptr_ok(k0)) gTabClass = k0;
    }
    if (!gTabClass) gTabClass = pm_class_in_namespace("Tab", "", "Layout", 5);
    if (!gTabClass) {
        PMLog(@"Mod页: 找不到官方 Tab 类");
        return NO;
    }
    if (!gTitleCellClass || !gChoiceCellClass || !gNumIntClass || !gNumFloatClass ||
        !gNumIntFmtPlain || !gNumFloatFmtPlain) {
        pm_scan_cell_classes(tabs, tn, titems);
    }
    PMLog(@"Mod页: 数值控件 int=%s(%d) float=%s(%d)", gNumIntClass ? "有" : "无", gNumIntFmtPlain,
          gNumFloatClass ? "有" : "无", gNumFloatFmtPlain);
    if (gTriedCount == 1) pm_raise_hit_volume_cap(tabs, tn, titems);
    if (!gChoiceCellClass) {
        PMLog(@"Mod页: 找不到官方 ChoiceCell 类");
        return NO;
    }

    void *srcTab = NULL;
    BOOL srcHasTitle = NO;
    for (int i = 0; i < tn; i++) {
        if (pm_tab_has_choice(titems[i]) && pm_tab_has_title(titems[i])) {
            srcTab = titems[i];
            srcHasTitle = YES;
            break;
        }
    }
    if (!srcTab) {
        for (int i = 0; i < tn; i++) {
            if (pm_tab_has_choice(titems[i])) { srcTab = titems[i]; break; }
        }
    }
    if (srcTab && !srcHasTitle) srcHasTitle = pm_tab_has_title(srcTab);
    if (!srcTab) {
        PMLog(@"Mod页: 没有可用的模板页");
        return NO;
    }
    void *srcView = *(void **)((char *)srcTab + 0x18);
    void *tabProto = *(void **)((char *)gsp + 0x48);
    void *viewProto = *(void **)((char *)gsp + 0x50);
    if (!pm_ptr_ok(srcView) || !pm_ptr_ok(tabProto) || !pm_ptr_ok(viewProto)) {
        PMLog(@"Mod页: 模板异常 view=%p tabProto=%p viewProto=%p", srcView, tabProto, viewProto);
        return NO;
    }
    void *tabParent = pm_call_obj(tabProto, "get_parent", 0, NULL);
    void *viewParent = pm_call_obj(viewProto, "get_parent", 0, NULL);
    // 这个 Unity 版本里 2 参数的 Instantiate 只有泛型版（<T>），
    // 无法用 runtime_invoke 调；3 参数里又有 (Vector3,Quaternion) 版本，
    // 所以必须按参数类型精确匹配 (Object, Transform, bool)。
    static const char *kInstParams[3] = {"Object", "Transform", "Boolean"};
    const MethodInfo *mInst = pm_method_exact(gFindTypesHost, "Instantiate", 3, kInstParams);
    if (!pm_ptr_ok(tabParent) || !pm_ptr_ok(viewParent) || !mInst) {
        PMLog(@"Mod页: 容器异常 tabParent=%p viewParent=%p inst=%p", tabParent, viewParent, mInst);
        return NO;
    }
    static bool gInstInWorld = false;

    int32_t nextTab = *(int32_t *)((char *)gsp + 0x20);
    // 官方 Add() 是用 tabs.Count 去 tabProto.parent 取侧栏按钮，不是用 nextTabIndex
    int needTabIdx = tn;
    int tabChildren = pm_child_count(tabParent);
    int viewChildren = pm_child_count(viewParent);
    int pn = *(int *)((char *)pages + 0x18);
    PMLog(@"Mod页: nextTab=%d needIdx=%d tabChild=%d viewChild=%d viewPages=%d",
          nextTab, needTabIdx, tabChildren, viewChildren, pn);

    int guard = 0;
    while (tabChildren <= needTabIdx && guard++ < 8) {
        void *protoGO = pm_call_obj(tabProto, "get_gameObject", 0, NULL);
        void *ia[3] = {protoGO, tabParent, &gInstInWorld};
        Il2CppException *ex = NULL;
        il2cpp_runtime_invoke(mInst, NULL, ia, &ex);
        if (ex) { pm_log_exc("Mod页: 克隆 Tab 按钮", ex); break; }
        tabChildren = pm_child_count(tabParent);
    }
    PMLog(@"Mod页: 补按钮后 tabChild=%d (需要 > %d)", tabChildren, needTabIdx);
    if (tabChildren <= needTabIdx) {
        PMLog(@"Mod页: 侧栏按钮补不齐，放弃本次注入");
        return NO;
    }
    void *newTabTr = pm_get_child(tabParent, needTabIdx);
    void *newTabGO = newTabTr ? pm_call_obj(newTabTr, "get_gameObject", 0, NULL) : NULL;
    // 预制体克隆会保留原按钮的坐标，导致新按钮叠在第一个按钮上，这里按间距移位
    if (tabChildren >= 3) {
        void *a1 = pm_get_child(tabParent, tabChildren - 3);
        void *a2 = pm_get_child(tabParent, tabChildren - 2);
        float p1[3], p2[3], np[3];
        if (pm_get_local_pos(a1, p1) && pm_get_local_pos(a2, p2)) {
            np[0] = p2[0] * 2 - p1[0];
            np[1] = p2[1] * 2 - p1[1];
            np[2] = p2[2] * 2 - p1[2];
            pm_set_local_pos(pm_get_child(tabParent, tabChildren - 1), np);
            PMLog(@"Mod页: 新按钮坐标 %.1f,%.1f,%.1f", np[0], np[1], np[2]);
        }
    }
    // Tab.Layout 用 GetComponentInChildren 找标题文本和按钮，必须先把按钮激活；
    // 克隆自「推荐」按钮会继承它的选中态，这里顺手清掉
    pm_go_set_active(newTabGO, true);
    pm_set_tab_active(newTabGO, NO);

    // 页面：必须克隆一个「已注册的真实页」，因为官方 Tab.Layout 是拿
    // cells 容器里的原型（下标 1=ChoiceCell、6=TitleCell…）来生成行的；
    // viewProto 是空模板页，容器里没有原型，会直接 ArgumentOutOfRange。
    // 克隆后把该页已生成的旧行删掉，只留原型。
    void *clonedPage = NULL;
    if (pm_ptr_ok(srcView)) {
        void *srcGO = pm_call_obj(srcView, "get_gameObject", 0, NULL);
        PMLog(@"Mod页: 开始克隆模板页 src=%p go=%p", srcView, srcGO);
        void *ia[3] = {srcGO, viewParent, &gInstInWorld};
        Il2CppException *ex = NULL;
        clonedPage = il2cpp_runtime_invoke(mInst, NULL, ia, &ex);
        if (ex || !clonedPage) {
            pm_log_exc("Mod页: 克隆模板页", ex);
            clonedPage = NULL;
        } else {
            PMLog(@"Mod页: 克隆模板页完成 page=%p", clonedPage);
        }
    }
    if (!clonedPage) {
        PMLog(@"Mod页: 模板页不可用 srcView=%p", srcView);
        return NO;
    }
    void *pageTr = pm_call_obj(clonedPage, "get_transform", 0, NULL);
    void *page = clonedPage;
    if (!pm_ptr_ok(pageTr)) {
        PMLog(@"Mod页: 取新页失败 page=%p", page);
        return NO;
    }
    int hiddenRows = pm_hide_cloned_rows(pageTr, 0);
    PMLog(@"Mod页: 隐藏模板页旧行 %d 个", hiddenRows);
    pm_go_set_active((void *)page, true);
    void *pargs[1] = {pageTr};
    pm_call_obj(pages, "Add", 1, pargs);
    int pageIndex = *(int *)((char *)pages + 0x18) - 1;

    pm_set_page_title((void *)page, *(void **)((char *)srcTab + 0x20));
    int pc = pm_child_count(pageTr);
    PMLog(@"Mod页: 新页子物体=%d", pc);
    for (int i = 0; i < pc && i < 8; i++) {
        void *c = pm_get_child(pageTr, i);
        void *g = c ? pm_call_obj(c, "get_gameObject", 0, NULL) : NULL;
        void *nm = g ? pm_call_obj(g, "get_name", 0, NULL) : NULL;
        char nb[96] = {0};
        if (nm) pm_il2cpp_string_ascii(nm, nb, sizeof(nb));
        PMLog(@"Mod页:   页子[%d]=%s 子数=%d", i, nb, pm_child_count(c));
    }

    // 建 Tab 并加入官方设置项
    void *tab = il2cpp_object_new(gTabClass);
    const MethodInfo *mTabCtor = il2cpp_class_get_method_from_name(gTabClass, ".ctor", 1);
    Il2CppString *tabTitle = il2cpp_string_new("Mod设置");
    if (!tab || !mTabCtor || !tabTitle) {
        PMLog(@"Mod页: Tab 创建失败 tab=%p ctor=%p", tab, mTabCtor);
        pm_list_remove_last(pages);
        pm_go_set_active((void *)page, false);
        pm_go_set_active(newTabGO, false);
        return NO;
    }
    void *targs[1] = {tabTitle};
    il2cpp_runtime_invoke(mTabCtor, tab, targs, NULL);

    struct { const char *section; const char *label; const char *key; int def; } rows[] = {
        {"玩法", "自动打歌",          "pm.auto",           1},
        {NULL,   "全 Perfect",        "pm.ap",             0},
        {NULL,   "锁血（Miss 不掉血）", "pm.hp",             0},
        {NULL,   "显示血条并保持满血",  "pm.hp.bar",         1},
        {"解锁", "全部歌曲解锁",       "pm.unlock",         0},
        {NULL,   "收藏品全解锁",       "pm.coll",           0},
        {NULL,   "角色解锁",          "pm.coll.char",      0},
        {NULL,   "皮肤解锁",          "pm.coll.skin",      0},
        {NULL,   "收藏品解锁",         "pm.coll.relic",     0},
        {NULL,   "故事解锁",          "pm.coll.story",     0},
        {NULL,   "称号解锁",          "pm.coll.title",     0},
        {NULL,   "背景解锁",          "pm.coll.bg",        0},
        {NULL,   "挑战解锁",          "pm.coll.challenge", 0},
        {"网络", "屏蔽成绩上传",        "pm.block",          0},
        {"悬浮球", "显示悬浮球",        "pm.ball.show",      1},
        {NULL,   "完全隐藏悬浮球",      "pm.ball.hide",      0},
        {NULL,   "游玩时自动隐藏",      "pm.ball.auto",      1},
    };
    int count = (int)(sizeof(rows) / sizeof(rows[0]));
    int made = 0;
    for (int i = 0; i < count; i++) {
        if (rows[i].section && gTitleCellClass && srcHasTitle) {
            pm_tab_add_cell(tab, pm_new_title_cell(rows[i].section));
        }
        void *cell = pm_new_choice_cell(rows[i].label, rows[i].key, rows[i].def);
        if (cell) { pm_tab_add_cell(tab, cell); made++; }
    }

    // 资料 / 悬浮球外观：官方 NumericCellFloat（滑条 + 加减按钮）
    int numMade = 0;
    if (gNumFloatClass && gNumFloatFmt) {
        if (srcHasTitle && gTitleCellClass) pm_tab_add_cell(tab, pm_new_title_cell("资料"));
        struct { const char *label; const char *key; float lo, hi, step, def; } frows[] = {
            {"等级（1-999）",        "pm.profile.level",      1, 999,        1,    100},
            {"Rating（0-9999）",     "pm.profile.rating",     0, 9999,       0.5f, 900},
            {"游玩次数（0-999999）",  "pm.profile.playcount",  0, 999999,     1,    1000},
            {"总游玩时间（小时）",     "pm.profile.playtime",   0, 9999,       1,    100},
            {"总分数（0-999999999）", "pm.profile.totalscore", 0.0f, 999999999.0f, 100.0f, 100000.0f},
        };
        for (int i = 0; i < 5; i++) {
            void *c = pm_new_numeric_float_cell(frows[i].label, frows[i].key,
                                                frows[i].lo, frows[i].hi,
                                                frows[i].step, frows[i].def);
            if (c) { pm_tab_add_cell(tab, c); numMade++; }
            else PMLog(@"Mod页: 浮点行创建失败 %s", frows[i].key);
        }
        if (srcHasTitle && gTitleCellClass) pm_tab_add_cell(tab, pm_new_title_cell("悬浮球外观"));
        struct { const char *label; const char *key; float lo, hi, step, def; } brows[] = {
            {"悬浮球大小（24-96）",   "pm.ball.size",  24.0f, 96.0f, 1.0f,  56.0f},
            {"悬浮球透明度（0.2-1）", "pm.ball.alpha", 0.2f,  1.0f,  0.05f, 0.85f},
        };
        for (int i = 0; i < 2; i++) {
            void *c = pm_new_numeric_float_cell(brows[i].label, brows[i].key,
                                                brows[i].lo, brows[i].hi,
                                                brows[i].step, brows[i].def);
            if (c) { pm_tab_add_cell(tab, c); numMade++; }
            else PMLog(@"Mod页: 浮点行创建失败 %s", brows[i].key);
        }
    }
    PMLog(@"Mod页: 数值行 %d 个", numMade);
    if (made == 0) {
        PMLog(@"Mod页: 设置项创建失败");
        pm_list_remove_last(pages);
        pm_go_set_active((void *)page, false);
        pm_go_set_active(newTabGO, false);
        return NO;
    }

    PMLog(@"Mod页: 准备注册 page=%d 行数=%d", pageIndex, pm_tab_cells(tab, NULL));
    pm_pad_unbounded_menus(gsp, pageIndex, newTabGO);

    int32_t pi = pageIndex;
    void *aargs[2] = {&pi, tab};
    Il2CppException *aexc = NULL;
    Il2CppClass *gspCls = il2cpp_object_get_class((Il2CppObject *)gsp);
    const MethodInfo *mGspAdd = gspCls ? il2cpp_class_get_method_from_name(gspCls, "Add", 2) : NULL;
    if (mGspAdd) il2cpp_runtime_invoke(mGspAdd, gsp, aargs, &aexc);
    if (aexc) {
        pm_log_exc("Mod页: 官方 Add", aexc);
        // Add 内部已经先 tabs.Add 再 Layout，Layout 失败会留下半成品，
        // 不回滚会让下一次重试的索引全部错位
        pm_list_remove_last(tabs);
        pm_list_remove_last(pages);
        pm_go_set_active((void *)page, false);
        pm_go_set_active(newTabGO, false);
        PMLog(@"Mod页: 官方 Add 失败，已回滚本次注入");
        return NO;
    }
    pm_go_set_active((void *)page, false);   // 保持原来的分页状态，等用户点侧栏

    gPatchedGsp = gsp;
    gModTabObj = tab;
    gModTabGO = newTabGO;
    gModPageGO = (void *)page;
    PMLog(@"Mod设置页已注册: page=%d, 行数=%d, 页内子物体=%d, 标题类=%s, 选项类=%s",
          pageIndex, made, pm_child_count(pageTr),
          gTitleCellClass ? "TitleCell" : "无", "ChoiceCell");
    return YES;
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

// 官方设置项把开关写进 PlayerPrefs，这里定期同步
static int pm_pref_int(const char *key, int def) {
    if (!gPrefGetIntM) return def;
    Il2CppString *s = il2cpp_string_new(key);
    int32_t d = def;
    void *args[2] = {s, &d};
    Il2CppObject *boxed = il2cpp_runtime_invoke(gPrefGetIntM, NULL, args, NULL);
    if (!boxed) return def;
    return *(int *)((char *)boxed + 0x10);
}

// 只有官方设置项真的写过这个键时才同步，避免用默认值把已保存的开关冲掉
static BOOL pm_pref_has_key(const char *key) {
    static const MethodInfo *mHas = NULL;
    if (!mHas) {
        Il2CppClass *pp = pm_class_in_namespace("PlayerPrefs", "UnityEngine", "HasKey", 1);
        if (pp) mHas = il2cpp_class_get_method_from_name(pp, "HasKey", 1);
        if (!mHas) return NO;
    }
    Il2CppString *s = il2cpp_string_new(key);
    void *args[1] = {s};
    Il2CppObject *boxed = il2cpp_runtime_invoke(mHas, NULL, args, NULL);
    if (!boxed) return NO;
    return *(uint8_t *)((char *)boxed + 0x10) != 0;
}

static float pm_pref_float(const char *key, float def) {
    static const MethodInfo *m = NULL;
    if (!m) {
        Il2CppClass *pp = pm_class_in_namespace("PlayerPrefs", "UnityEngine", "GetFloat", 2);
        if (pp) m = il2cpp_class_get_method_from_name(pp, "GetFloat", 2);
        if (!m) return def;
    }
    Il2CppString *s = il2cpp_string_new(key);
    float d = def;
    void *args[2] = {s, &d};
    Il2CppObject *boxed = il2cpp_runtime_invoke(m, NULL, args, NULL);
    if (!boxed) return def;
    return *(float *)((char *)boxed + 0x10);
}

static void pm_pref_set_int(const char *key, int v) {
    static const MethodInfo *m = NULL;
    if (!m) {
        Il2CppClass *pp = pm_class_in_namespace("PlayerPrefs", "UnityEngine", "SetInt", 2);
        if (pp) m = il2cpp_class_get_method_from_name(pp, "SetInt", 2);
        if (!m) return;
    }
    Il2CppString *s = il2cpp_string_new(key);
    int32_t val = v;
    void *args[2] = {s, &val};
    il2cpp_runtime_invoke(m, NULL, args, NULL);
}

// 「修改」行点开后由 Overlay 弹输入框，这里只负责把动作位复位，避免重复弹
static void pm_handle_mod_actions(void) {
    static const char *keys[] = {"level", "rating", "playcount", "playtime",
                                 "totalscore", "ballsize", "ballalpha"};
    for (int i = 0; i < 7; i++) {
        char k[64];
        snprintf(k, sizeof(k), "pm.action.%s", keys[i]);
        if (!pm_pref_has_key(k)) continue;
        if (pm_pref_int(k, 0) != 1) continue;
        pm_pref_set_int(k, 0);
        PMPromptForModValue([NSString stringWithUTF8String:keys[i]]);
    }
}

static void pm_set_profile_value(NSString *key, NSString *val) {
    if (!key || !val.length) return;
    if (!PMProfileText) PMProfileText = [NSMutableDictionary dictionary];
    NSString *old = PMProfileText[key];
    if (old && [old isEqualToString:val]) return;
    PMProfileText[key] = val;
    PMProfileEnabled = YES;
}

// 官方「Mod设置」里的资料数值行写在 PlayerPrefs，这里同步到资料覆盖表
static void pm_sync_profile_edits(void) {
    if (!pm_pref_has_key("pm.profile.level") && !pm_pref_has_key("pm.profile.rating")) return;
    static BOOL logged = NO;
    if (pm_pref_has_key("pm.profile.level")) {
        pm_set_profile_value(@"level", [NSString stringWithFormat:@"%.0f", pm_pref_float("pm.profile.level", 1.0f)]);
    }
    if (pm_pref_has_key("pm.profile.rating")) {
        pm_set_profile_value(@"rating", [NSString stringWithFormat:@"%.2f", pm_pref_float("pm.profile.rating", 900.0f)]);
    }
    if (pm_pref_has_key("pm.profile.playcount")) {
        pm_set_profile_value(@"playcount", [NSString stringWithFormat:@"%.0f", pm_pref_float("pm.profile.playcount", 0.0f)]);
    }
    if (pm_pref_has_key("pm.profile.playtime")) {
        pm_set_profile_value(@"playtime", [NSString stringWithFormat:@"%.0f", pm_pref_float("pm.profile.playtime", 0.0f)]);
    }
    if (pm_pref_has_key("pm.profile.totalscore")) {
        pm_set_profile_value(@"totalscore", [NSString stringWithFormat:@"%.0f", pm_pref_float("pm.profile.totalscore", 0.0f)]);
    }
    if (!logged) {
        logged = YES;
        PMLog(@"资料数值已从官方设置同步: level=%@ rating=%@",
              PMProfileValue(@"level") ?: @"-", PMProfileValue(@"rating") ?: @"-");
    }
}

static void pm_sync_prefs(void) {
    if (!gPrefGetIntM) {
        Il2CppClass *pp = pm_class_in_namespace("PlayerPrefs", "UnityEngine", "GetInt", 2);
        if (pp) gPrefGetIntM = il2cpp_class_get_method_from_name(pp, "GetInt", 2);
        if (!gPrefGetIntM) return;
    }
    struct PMPrefMap { const char *key; int def; int last; bool *target; };
    static struct PMPrefMap map[] = {
        {"pm.auto",            1, -99999, &PMAutoPlay},
        {"pm.ap",              0, -99999, &PMAllPerfect},
        {"pm.hp",              0, -99999, &PMLockHP},
        {"pm.hp.bar",          1, -99999, &PMShowLifeBar},
        {"pm.unlock",          0, -99999, &PMUnlockAll},
        {"pm.coll",            0, -99999, &PMUnlockCollection},
        {"pm.coll.char",       0, -99999, &PMUnlockCharacters},
        {"pm.coll.skin",       0, -99999, &PMUnlockSkins},
        {"pm.coll.relic",      0, -99999, &PMUnlockRelics},
        {"pm.coll.story",      0, -99999, &PMUnlockStories},
        {"pm.coll.title",      0, -99999, &PMUnlockTitles},
        {"pm.coll.bg",         0, -99999, &PMUnlockBackgrounds},
        {"pm.coll.challenge",  0, -99999, &PMUnlockChallenges},
        {"pm.block",           0, -99999, &PMBlockUpload},
        {"pm.ball.show",       1, -99999, &PMBallVisible},
        {"pm.ball.hide",       0, -99999, &PMBallHidden},
        {"pm.ball.auto",       1, -99999, &PMAutoHideInGame},
    };
    static BOOL inited = NO;
    static BOOL logged = NO;
    BOOL ballChanged = NO;
    int n = (int)(sizeof(map) / sizeof(map[0]));
    for (int i = 0; i < n; i++) {
        if (!pm_pref_has_key(map[i].key)) continue;   // 没被官方设置写过就保持原值
        int v = pm_pref_int(map[i].key, map[i].def);
        if (v == map[i].last) continue;
        map[i].last = v;
        if (map[i].target == &PMBallVisible || map[i].target == &PMBallHidden ||
            map[i].target == &PMAutoHideInGame) ballChanged = YES;
        *map[i].target = (v != 0);
    }
    // 悬浮球大小 / 透明度：官方 float 行写的是 PlayerPrefs 的 float
    if (pm_pref_has_key("pm.ball.size")) {
        float v = pm_pref_float("pm.ball.size", PMBallSize);
        v = MAX(24.0f, MIN(96.0f, v));
        if (fabsf(v - PMBallSize) > 0.01f) { PMBallSize = v; ballChanged = YES; }
    }
    if (pm_pref_has_key("pm.ball.alpha")) {
        float v = pm_pref_float("pm.ball.alpha", PMBallAlpha);
        v = MAX(0.2f, MIN(1.0f, v));
        if (fabsf(v - PMBallAlpha) > 0.005f) { PMBallAlpha = v; ballChanged = YES; }
    }
    pm_sync_profile_edits();
    pm_handle_mod_actions();
    if (!inited) {
        inited = YES;
        PMLog(@"设置已同步 (auto=%d ap=%d hp=%d bar=%d unlock=%d)",
              PMAutoPlay, PMAllPerfect, PMLockHP, PMShowLifeBar, PMUnlockAll);
    } else if (ballChanged || !logged) {
        PMUpdateBall();
    }
    logged = YES;
}

// ---------------------------------------------------------------------------
// 商店：把所有商品标成「已购买」并刷新显示（只读改状态，不触发购买流程）
// ---------------------------------------------------------------------------
static Il2CppClass *gStoreClass = NULL;
static void *gStoreObj = NULL, *gStoreHandle = NULL;
static Il2CppClass *gResultInfoClass = NULL;

static int pm_store_mark(void *mgr, size_t listOff, size_t purchasedOff) {
    void *lst = *(void **)((char *)mgr + listOff);
    int n = 0;
    void **items = pm_list_items(lst, &n);
    int changed = 0;
    for (int i = 0; i < n; i++) {
        void *c = items[i];
        if (!pm_ptr_ok(c)) continue;
        if (*(uint8_t *)((char *)c + purchasedOff) == 0) {
            *(uint8_t *)((char *)c + purchasedOff) = 1;
            changed++;
        }
        pm_call_obj(c, "RefreshPurchasedState", 0, NULL);
    }
    return changed;
}

static void pm_apply_store_unlock(void) {
    if (!gStoreClass) gStoreClass = pm_find_class("StoreManager");
    if (!gStoreClass) return;
    pm_refresh_object(gStoreClass, &gStoreObj, &gStoreHandle);
    void *mgr = gStoreObj;
    if (!mgr) return;
    int changed = 0;
    changed += pm_store_mark(mgr, 0x58, 0x30);   // 推荐 tab
    changed += pm_store_mark(mgr, 0x78, 0x48);   // 专辑 tab
    changed += pm_store_mark(mgr, 0x98, 0x38);   // 单曲 tab
    changed += pm_store_mark(mgr, 0xB8, 0x80);   // 皮肤 tab
    if (changed) {
        pm_call_obj(mgr, "UpdateStateDisplay", 0, NULL);
        PMLog(@"商店: 标记已购买 %d 个商品", changed);
    }
}

// 结算页的玩家信息卡（等级 / Rating）也用自定义值
static void pm_apply_result_playerinfo(void) {
    if (!gResultInfoClass) gResultInfoClass = pm_find_class("ResultPlayerInfoController");
    if (!gResultInfoClass || !gFindTypesHost || !il2cpp_class_get_type || !il2cpp_type_get_object) return;
    void *typeObj = il2cpp_type_get_object(il2cpp_class_get_type(gResultInfoClass));
    const MethodInfo *m = il2cpp_class_get_method_from_name(gFindTypesHost, "FindObjectsOfType", 1);
    if (!typeObj || !m) return;
    void *args[1] = {typeObj};
    Il2CppObject *arr = il2cpp_runtime_invoke(m, NULL, args, NULL);
    if (!arr) return;
    int n = *(int *)((char *)arr + 0x18);
    void **items = *(void ***)((char *)arr + 0x20);
    static BOOL logged = NO;
    if (!logged && n > 0) {
        logged = YES;
        PMLog(@"结算卡: 找到 %d 个 ResultPlayerInfoController", n);
    }
    if (n <= 0 || n > 32 || !items) return;
    NSString *lv = PMProfileValue(@"level");
    NSString *rt = PMProfileValue(@"rating");
    if (!lv.length && !rt.length) return;
    for (int i = 0; i < n; i++) {
        void *c = items[i];
        if (!pm_ptr_ok(c)) continue;
        if (lv.length) {
            NSString *s = [lv.lowercaseString hasPrefix:@"lv"] ? lv : [NSString stringWithFormat:@"Lv.%@", lv];
            pm_set_component_text(*(void **)((char *)c + 0x30), s);
        }
        if (rt.length) {
            pm_set_component_text(*(void **)((char *)c + 0x58), [NSString stringWithFormat:@"%.2f", rt.doubleValue]);
        }
        void *info = *(void **)((char *)c + 0x78);
        if (pm_ptr_ok(info)) {
            if (lv.length) *(int32_t *)((char *)info + 0x38) = lv.intValue;
            if (rt.length) *(int32_t *)((char *)info + 0x48) = (int32_t)lround(rt.doubleValue * 100.0);
        }
    }
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
        if (!gCUIClass) gCUIClass = pm_find_class("CommonUserInfo");
        pm_refresh_object(gCUIClass, &gCUI_Obj, &gCUI_Handle);

        pm_sync_prefs();

        static BOOL piLogged = NO;
        if (gPI_Obj && !piLogged) {
            piLogged = YES;
            PMLog(@"PlayerInfoManager 实例 = %p", gPI_Obj);
        }
        static BOOL cuiLogged = NO;
        if (gCUI_Obj && !cuiLogged) {
            cuiLogged = YES;
            PMLog(@"CommonUserInfo 实例 = %p", gCUI_Obj);
        }
        // 诊断：游戏角色页自己能列出多少个已解锁角色
        static BOOL charProbed = NO;
        if (!charProbed && gFindTypeMethod && il2cpp_class_get_type && il2cpp_type_get_object) {
            Il2CppClass *ct = pm_find_class("CharacterTabManager");
            if (ct) {
                void *tObj = il2cpp_type_get_object(il2cpp_class_get_type(ct));
                uint8_t inc = 1;
                void *cargs[2] = {tObj, &inc};
                Il2CppObject *inst = tObj ? il2cpp_runtime_invoke(gFindTypeMethod, NULL, cargs, NULL) : NULL;
                if (inst) {
                    const MethodInfo *mGet = il2cpp_class_get_method_from_name(ct, "GetUnlockedCharacters", 0);
                    Il2CppObject *list = mGet ? il2cpp_runtime_invoke(mGet, inst, NULL, NULL) : NULL;
                    PMLog(@"角色页诊断: 实例=%p 已解锁角色=%d", inst,
                          list ? *(int *)((char *)list + 0x18) : -1);
                    charProbed = YES;
                }
            }
        }

        if (gSettingsObj) {
            static CFTimeInterval lastAttempt = 0;
            static void *seenPanel = NULL;
            if (gSettingsObj != seenPanel) {
                // 游戏重建了设置面板，旧的注册信息全部作废
                seenPanel = gSettingsObj;
                gEntryInjected = NO;
                gSettingsSeenAt = now;
                gPatchedGsp = NULL;
                gTriedGsp = NULL;
                gTriedCount = 0;
                gModTabObj = NULL;
                gModTabGO = NULL;
                gModPageGO = NULL;
            }
            if (gEntryInjected && !pm_panel_has_mod_tab(gSettingsObj)) {
                PMLog(@"Mod页: 侧栏项已丢失，重新注入");
                gEntryInjected = NO;
                gSettingsSeenAt = 0;
                gPatchedGsp = NULL;
                gTriedGsp = NULL;
                gTriedCount = 0;
                gModTabObj = NULL;
                gModTabGO = NULL;
            }
            if (gEntryInjected) pm_keep_mod_tab_selected(gSettingsObj);
            if (!gSettingsSeenAt) gSettingsSeenAt = now;
            if (!gEntryInjected && now - lastAttempt > 2.0) {
                lastAttempt = now;
                gEntryVisible = YES;
                PMSetModEntryVisible(false);
                if (pm_build_mod_tab(gSettingsObj)) {
                    gEntryInjected = YES;
                } else {
                    PMLog(@"Mod设置页注册失败，稍后重试");
                }
            }
        } else if (gEntryVisible) {
            gEntryVisible = NO;
            gEntryInjected = NO;
            gSettingsSeenAt = 0;
            gModPageGO = NULL;   // 设置面板已销毁，页面随之销毁
        }

        if (gCollectionObj) pm_apply_collection_overrides(gCollectionObj);
        if (gPI_Obj) pm_apply_playerinfo_overrides(gPI_Obj);
        if (gCUI_Obj) pm_apply_commonuserinfo_overrides(gCUI_Obj);
        pm_apply_result_playerinfo();
    }

    if (now - gLastSlowTime > 1.5) {
        gLastSlowTime = now;
        pm_apply_static_settings();
        pm_apply_store_unlock();
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

    // 锁血：可选保留血条（一直满血）或彻底隐藏血条
    if (PMLockHP) {
        if (js != gLifeJs) {
            if (gLifeTypeSaved) pm_set_lifetype(gSavedLifeType);
            gSavedLifeType = pm_get_lifetype();
            gLifeTypeSaved = true;
            gLifeJs = js;
            if (!PMShowLifeBar) pm_set_lifetype(6);
            PMLog(@"锁血: 原 LifeType=%d, 显示血条=%d", gSavedLifeType, PMShowLifeBar);
        }
        if (PMShowLifeBar) {
            if (gSavedLifeType >= 0 && gSavedLifeType <= 5 && pm_get_lifetype() != gSavedLifeType) {
                pm_set_lifetype(gSavedLifeType);
            }
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
            int size = 0;
            void **items = pm_list_items(slots, &size);
            float t = *(float *)((char *)js + kOff_JS_Time);
            if (items) {
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
        m.URL = [NSURL URLWithString:@"http://127.0.0.1:18080/__pm_blocked__"];
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

// 本地假上传服务：把拦截到的上传请求返回 200 + 成功 JSON，
// 这样游戏认为上传成功，不会一直弹「重新上传」
static void *pm_block_server_thread(void *arg) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return NULL;
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(18080);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(lfd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(lfd, 8) < 0) {
        close(lfd);
        PMLog(@"假上传服务启动失败");
        return NULL;
    }
    PMLog(@"假上传服务已启动 127.0.0.1:18080");
    for (;;) {
        int c = accept(lfd, NULL, NULL);
        if (c < 0) break;
        char buf[2048];
        recv(c, buf, sizeof(buf), 0);
        const char *body = "{\"status\":\"ok\",\"code\":\"0\",\"reason\":0,\"message\":\"ok\","
                           "\"rating\":0,\"result_id\":\"\",\"single_rating\":0,"
                           "\"is_b15\":false,\"max_rating\":0,\"data\":{}}";
        char resp[512];
        int n = snprintf(resp, sizeof(resp),
                         "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         "Content-Length: %zu\r\nConnection: close\r\n\r\n%s",
                         strlen(body), body);
        send(c, resp, (size_t)n, 0);
        close(c);
    }
    return NULL;
}

static void pm_start_block_server(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    pthread_t th;
    if (pthread_create(&th, NULL, pm_block_server_thread, NULL) == 0) {
        pthread_detach(th);
    }
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
    pm_start_block_server();
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
