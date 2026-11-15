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
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <string.h>
#include <math.h>
#include <libkern/OSCacheControl.h>

// ---------------------------------------------------------------------------
// 全局状态（悬浮球 / 设置页修改）
// ---------------------------------------------------------------------------
bool PMAutoPlay = true;
bool PMAllPerfect = false;
bool PMLockHP = false;
bool PMUnlockAll = false;
bool PMBlockUpload = false;
float PMSpeed = 1.0f;

volatile int PMLastSlotCount = -1;
volatile int PMAutoJudged = 0;
volatile bool PMHookReady = false;
volatile bool PMIl2CppReady = false;
volatile bool PMUnlockAllApplied = false;
volatile int PMUploadBlocked = 0;

// 4.13 关键 RVA（文件偏移 == VM 地址，__TEXT vmaddr = 0）
static const uintptr_t kRVA_JudgeSystem_UpdateTime = 0x012EAE08;
static const uintptr_t kRVA_JudgeSlot_SetResult      = 0x012F37F0;
static const uintptr_t kRVA_GameControl_AddHP        = 0x01079DC8;
static const uintptr_t kRVA_BackendAPI_Run           = 0x01331700;

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
// 日志
// ---------------------------------------------------------------------------
void PMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ParadigmMod] %@", msg);
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
            gUnityBase = (uintptr_t)_dyld_get_image_header(i) + (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            PMLog(@"UnityFramework base = %p", (void *)gUnityBase);
            return (void *)gUnityBase;
        }
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// 极简 arm64 inline hook（入口 16 字节 + trampoline）
// ---------------------------------------------------------------------------
static bool pm_make_writable(void *addr, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    size_t span = ((vm_address_t)addr + size) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        PMLog(@"vm_protect 失败: %d", kr);
        return false;
    }
    return true;
}

// ldr x16, #8 ; br x16 ; .quad target
static void pm_emit_branch(uint32_t *code, uintptr_t target) {
    code[0] = 0x58000050;
    code[1] = 0xD61F0200;
    memcpy(&code[2], &target, sizeof(target));
}

static void *pm_alloc_trampoline(void) {
    void *p = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        p = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) return NULL;
        mprotect(p, vm_page_size, PROT_READ | PROT_WRITE | PROT_EXEC);
    }
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
    sys_icache_invalidate(tramp, 32);

    if (!pm_make_writable(target, 16)) {
        munmap(tramp, vm_page_size);
        return NULL;
    }
    uint32_t patch[4];
    pm_emit_branch(patch, (uintptr_t)replacement);
    memcpy(entry, patch, 16);
    sys_icache_invalidate(target, 16);
    vm_protect(mach_task_self(), (vm_address_t)target & ~(vm_page_size - 1), vm_page_size,
               FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
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
#undef RESOLVE
    PMIl2CppReady = true;
    return true;
}

static Il2CppClass *pm_find_class(const char *name) {
    Il2CppDomain *domain = il2cpp_domain_get();
    if (!domain) return NULL;
    size_t count = 0;
    const Il2CppAssembly **asms = il2cpp_domain_get_assemblies(domain, &count);
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
// 周期任务：全解锁 / 变速
// ---------------------------------------------------------------------------
static float gOrigHiSpeed = 1.0f;
static bool gHiSpeedCaptured = false;
static bool gHiSpeedOverridden = false;
static bool gUnlockAllWritten = false;

static void pm_apply_static_settings(void) {
    if (!PMIl2CppReady) return;

    bool unlock = __atomic_load_n(&PMUnlockAll, __ATOMIC_RELAXED);
    if (unlock != gUnlockAllWritten) {
        if (pm_set_static_bool("TrackUnlockStorage", "UnlockAll", unlock)) {
            gUnlockAllWritten = unlock;
            PMUnlockAllApplied = unlock;
        }
    }

    float speed = PMSpeed;
    if (speed < 0.5f) speed = 0.5f;
    if (speed > 2.5f) speed = 2.5f;
    bool overridden = fabsf(speed - 1.0f) > 0.01f;
    if (overridden) {
        if (!gHiSpeedCaptured) {
            Il2CppClass *k = pm_find_class("Chart");
            if (k) {
                FieldInfo *f = il2cpp_class_get_field_from_name(k, "hiSpeedMultiplier");
                if (f) {
                    float cur = 0;
                    il2cpp_field_static_get_value(f, &cur);
                    if (cur > 0.05f && cur < 20.0f) gOrigHiSpeed = cur;
                    gHiSpeedCaptured = true;
                }
            }
        }
        if (pm_set_static_float("Chart", "hiSpeedMultiplier", speed)) {
            gHiSpeedOverridden = true;
        }
    } else if (gHiSpeedOverridden) {
        pm_set_static_float("Chart", "hiSpeedMultiplier", gOrigHiSpeed);
        gHiSpeedOverridden = false;
    }
}

void PMApplySettingsNow(void) { pm_apply_static_settings(); }

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------
void PMInstallHooks(void) {
    if (PMHookReady) return;
    if (!PMUnityBase()) return;
    bool api = pm_resolve_il2cpp() && pm_prepare_judge_api();

    void *base = (void *)gUnityBase;

    orig_UpdateTime = (void (*)(void *))pm_install_hook((void *)((char *)base + kRVA_JudgeSystem_UpdateTime),
                                                        (void *)pm_UpdateTime_hook);
    orig_SetResult = (void (*)(void *, int, uint8_t, void *))pm_install_hook(
        (void *)((char *)base + kRVA_JudgeSlot_SetResult), (void *)pm_SetResult_hook);
    orig_AddHP = (void (*)(void *, int, float, uint8_t, void *))pm_install_hook(
        (void *)((char *)base + kRVA_GameControl_AddHP), (void *)pm_AddHP_hook);
    orig_Run = (void *(*)(void *, void *))pm_install_hook(
        (void *)((char *)base + kRVA_BackendAPI_Run), (void *)pm_Run_hook);

    PMHookReady = (orig_UpdateTime != NULL);
    PMLog(@"hooks: updateTime=%d setResult=%d addHP=%d run=%d il2cpp=%d",
          orig_UpdateTime != NULL, orig_SetResult != NULL, orig_AddHP != NULL,
          orig_Run != NULL, api);
    pm_apply_static_settings();
}
