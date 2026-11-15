# 《范式：起源》iOS 4.13 砸壳版 —— 代码逆向报告

> 样本：`com.tunergames.paradigmchina_4.13_cn_iphone_dumpipa.com.ipa`（1,300,885,360 字节）
> 分析环境：Windows + Python 3.12 + Il2CppDumper 6.7.46

## 1. 样本状态（关键：这次代码可读）

| 项 | 值 |
| --- | --- |
| Bundle ID / 版本 | `com.tunergames.paradigmchina` / 4.13（build 1） |
| 引擎 | Unity 2022.3，IL2CPP，arm64 |
| `global-metadata.dat` | v31，明文 |
| **UnityFramework `LC_ENCRYPTION_INFO_64`** | **cryptid = 0（已砸壳）** |
| UnityFramework UUID | `964f6391cd6c33788f84dd0aae540677`（版本门禁用） |
| 文件大小 | UnityFramework 78,434,560 字节 |

同一代码库的 4.13 版本；上一轮 4.12.1 的符号表与本版类名体系一致，只是方法与地址发生变化。

## 2. 转储结果

Il2CppDumper 6.7.46 直接成功（不需要任何降级或补丁）：

```
CodeRegistration   : 0x435ea80
MetadataRegistration: 0x449fa60
```

| 产物 | 说明 |
| --- | --- |
| `dump/dump.cs` | 30.3 MB，含字段偏移、方法 RVA、嵌套类型 |
| `dump/script.json` | 84.4 MB，**186,277 个方法的地址**（`Address` 即 RVA，等于文件偏移，因 `__TEXT` 从 0 开始） |
| `dump/stringliteral.json` | 2.4 MB，27,192 条字符串字面量 |
| `dump/DummyDll/` | 可用于 dnSpy / ILSpy 浏览的桩程序集 |

规模：`dump.cs` 公开类 **6,127**，有方法的类 **20,287**，方法 **186,277**。

## 3. 关键系统与真实地址（4.13）

### 判定链（改判定/自动打歌的入口）

| 方法 | 地址 | 说明 |
| --- | --- | --- |
| `JudgeSystem.UpdateTime` | `0x012eae08` | 每帧推进判定时间 |
| `JudgeSystem.UpdateJudges` | `0x012ea9cc` | 遍历判定器 |
| `JudgeSystem.MatchTouchTime` | `0x012f1878` | 触摸时间→判定时间 |
| `JudgeSystem.JudgeConcurrentNotesGroups` | `0x012eadc8` | 并发音符组判定 |
| `JudgeSystem.RegisterSlot` / `RegisterJudger` | `0x012f3d68` / `0x012e8724` | 注册判定槽/判定器 |
| `JudgeSystem.get_JudgeTimeVar` | `0x012ebec8` | 判定窗口的可调变量 |
| `ConcurrentNotesJudgeCoordinator.TryCoordinateConcurrentNotes` | `0x012ede44` | 多押同判协调 |

判定实现类：`TapJudgeTouching`、`SliderJudgeTouching`、`JudgeSlot`、`JudgeSlotCounter`、`ExtraConditionJudgeTiming`、`SimplePGMJudgeTiming`、`StaticListJudgeTiming`。

### 玩法主控与生命

| 方法 | 地址 |
| --- | --- |
| `GameControl.GameStart` | `0x01079774` |
| `GameControl.AddHP` | `0x01079dc8` |
| `GameControl.ExtraCallbackOnSuperPerfect` | `0x01079db8` |
| `GameControl.Awake` | `0x0107912c` |

`GameControl` 字段直接可读：`hit`、`all`、`_life`、`targetScore`、`trueScore`、`judgeSystemWrap`、`lifeBarDisplayManager`。

### 存档 / 账号 / 网络

| 系统 | 入口 |
| --- | --- |
| 存档 | `SaveWrite.Write(SaveWrite, V2.Chart)` @ `0x01255c74`；另有 `DictStorage`、LiteDB |
| 登录 | `GlobalLoginControl.Login` @ `0x01093684`、`TryFastLogin` @ `0x01093710`、`Migrate` @ `0x01095078` |
| 中间件 | `MiddlewareChinaIOS.*`、`MiddlewareGlobal.*` |
| 网络 | `BackendAPI`、`GameNetwork`、`BattleSession`、`COPWebSocket` |

## 4. 保护评估

- 没有二次加壳：metadata 明文、代码段 cryptid=0、`dump.cs`/`il2cpp.h` 完整导出。
- 未发现反调试 / 反注入 / 越狱检测字符串（全文只有 `startHooking`/`endHooking` 这类玩法命名）。
- 未发现自定义完整性校验逻辑；`signature` 类字符串 128 条均来自 BouncyCastle/TLS 等第三方库。
- 结论：**可以直接按 PhiMod 的方式做静态注入 + 入口网关**，不存在对抗性保护。

## 5. Hook 清单（可直接用于生成补丁）

- `analysis/hook_manifest.json`：182 个候选方法，字段为 `name / class / address / prologue(原始4字节) / prologue_kind / signature`。
- 其中 **119 个** 以 `stp x?,x?,[sp,#-..]!` 或 `sub sp,sp,#..` 开头，符合静态入口网关的可重定位要求；其余 63 个需要用指令级 trampoline。
- `analysis/key_classes_methods.tsv`：同上，TSV 便于筛选。
- `analysis/hook_candidates.tsv`：按 judge / score / save / net / life / chart 分组的方法全表（10,804 条）。
- `analysis/GameControl_methods.tsv`、`JudgeSystemWrap_methods.tsv`：单类方法地址表。

## 6. 现在能做什么 / 还差什么

能做：
1. 套用 PhiMod 的注入方案：给 `UnityFramework` 加 `LC_LOAD_DYLIB`、在 `__TEXT`/`__DATA` 尾部新增网关段与回调槽；
2. 回调里用 `il2cpp_*` API 反射读写上面这些类的字段（如 `GameControl._life`、`JudgeSystem.JudgeTimeVar`）；
3. 版本门禁用本包 UUID `964f6391cd6c33788f84dd0aae540677`，把 68 个（或本作任意数量）入口按 `hook_manifest.json` 的 RVA 打进补丁；
4. 打包未签名 IPA → 证书重签 / TrollStore 安装。

还差：
1. 具体功能设计（判定窗口、AutoPlay、练习模式、改分等）需要逐个确认对应方法与参数语义；
2. 编译 framework 需要 macOS + iOS SDK（可用 GitHub Actions `macos-15`）；
3. 真机测试（非越狱需要重签）。

## 7. 与 4.12.1 的关系

4.12.1（FairPlay 加密）只能拿到符号与资源；4.13（砸壳）拿到了完整代码。两者的类体系一致，可以用 4.13 的 `dump.cs` 理解逻辑，用 4.12.1 的 `types.tsv` 对照历史版本差异。

## 8. 曲目 / 谱面内容链路（本轮新增）

### 8.1 内容不在 IPA 里

```
启动 -> PostDownloadSecureAddressables.Initialize
     -> GET  /server/hotassets/catalog   (X-Session 登录态)
     -> GET  <catalog.json URL>          (远端 Addressables catalog)
     -> GET  /server/hotassets/songmeta  (曲目元数据 JSON)
     -> POST /server/hotassets/sign      (AES 加密 body: {"url_list":[...]})
     -> GET  https://assets.paradigm*.tunergames.com<签名路径>
     -> AES-128-CBC 解密 -> UnityFS bundle
```

- 远端 bundle 命名：`postdownloadpack_assets_<n>/...`，本地包为 `defaultlocalgroup_assets_*`。
- bundle 加密：key `A73CC5F90BC321B251756A93B70A9338`，IV 由**文件名**双种子（`0x05B48FC7` 正序 / `0x012936E5` 逆序，乘 31）生成，PKCS#7。
- API 请求体加密：key `Paradigm9537c1fa`，`[16B IV][AES-128-CBC]`。
- 4.13 的 `BackendAPI.API_VERSION = 100`（4.9 是 92）；请求头 `X-game-version: 4.13`、`X-platform: iOS`、`X-Session`。
- **所有 `/server/hotassets/*` 接口缺 `X-Session` 时返回 `400 Invalid request body`（误导性文案），空 session 返回 `401 INVALID_TOKEN`**，因此曲包必须登录后拿。

### 8.1.1 国服实际链路（已跑通）

- 登录：`POST https://tuner-api.paradigmchina.tunergames.com/account/login`，body `{"phone":"...","password":"..."}` → `data.authToken`（512 字节，国服账号是手机号，不是邮箱；`api.paradigm.tunergames.com` 是国际服，国服手机号在那里查不到）。
- 后续接口同 host：`/server/hotassets/catalog`、`/server/hotassets/songmeta`、`/server/hotassets/sign`，响应体均为 `[16B IV][AES-128-CBC]`。
- catalog 返回 `https://fsqy-cdn.3839pic.com/cn-ios/catalog_D176.json`（4399 CDN，5.7 MB，6906 个 m_InternalIds）。
- 远端包分组：`s` 2702、`bg` 290、`assets` 129、`illust` 52、`challenge` 15、`video` 11、`story` 4、`achievement` 1，共 3204 个。
- `sign` 直接返回绝对 URL：`https://fsqy-cdn.3839pic.com/cn-ios/postdownloadpack_assets_...bundle`。
- `songmeta` 是增量接口，默认只回最近几条（`{"status":"ok","data":{"s/xxx":{...}}}`），完整曲目信息需配合分页/版本参数或从 bundle 内 `SongMeta` 资源取。

### 8.2 曲目元数据

`ShikaData.txt`（本地 TextAsset，10 KB）只是曲目的“配色/BPM”表：

```
address,shikaCore,shikaSoothing,shikaMystery,BPM,SpecialTrack
s/awakeninruins,2,4,0,125,0
```

真正的曲目列表来自 `/server/hotassets/songmeta`，反序列化成 `SongMeta.Item[]`：

| 字段 | 说明 |
| --- | --- |
| `title / musician / illustrator / genre / bpm` | 显示信息 |
| `address` | 资源地址前缀，形如 `s/<trackid>` |
| `charts[]` | `SongMeta.Chart`：`difficulty`、`level`、`isPlus`、`noter`、`override*`（标题/曲绘/音乐地址覆盖）、`levelSprite` |
| `trackType` / `typeParams` | 曲目分类（活动、联动、挑战等） |
| `fromProductType` / `differenceLockList` | 解锁与售卖信息 |

难度枚举 `ParadigmHelper.EDifficulty`：`Detected=0, Invaded=1, Massive=2, Reboot=3, Chaotic=4`（短名 `DET/IVD/MSV/RBT/CHA`）。

### 8.2.1 曲目资源地址约定（实测）

远端 `s` 组每个曲目一个目录，文件名与地址一一对应：

```
s/<trackid>/detected_<hash>.bundle   -> TextAsset  <Track>_DET
s/<trackid>/invaded_<hash>.bundle    -> TextAsset  <Track>_IVD
s/<trackid>/massive_<hash>.bundle    -> TextAsset  <Track>_MSV
s/<trackid>/reboot_<hash>.bundle     -> TextAsset  <Track>_RBT（部分曲目）
s/<trackid>/chaotic_<hash>.bundle    -> TextAsset  <Track>_CHA（部分曲目）
s/<trackid>/music_<hash>.bundle      -> AudioClip  <Track>
s/<trackid>/preview_<hash>.bundle    -> AudioClip  <Track>（试听片段）
s/<trackid>/cover_<hash>.bundle      -> Texture2D/Sprite <Track>
```

即 Addressables 地址就是 `s/<trackid>/<difficulty小写>`、`s/<trackid>/music|preview|cover`。
谱面 TextAsset 名 = 曲名 + `_DET/_IVD/_MSV/_RBT/_CHA`，可直接还原曲名。

### 8.3 谱面格式（本作自定义 DSL，非 RPE/PEC）

谱面是 TextAsset 文本，由 `ParsaPara.Execute(string)` 解释，4.13 地址 `0x125552C`；实例构造 `0x1254844` 里注册了全部指令（含别名）。指令基类 `Parsa` / `Parsa<T...>`，`Name` 取自字符串字面量：

| 类 | 注册名（含别名） | 泛型签名 | 实测参数个数 |
| --- | --- | --- | --- |
| `Offset` | `Offset` | `double` | 1 |
| `InitBeat` | `InitBeat` | `double bpm, int div` | 2 |
| `InitBeatEx` | `InitBeatEx` | `double, int, int` | 3 |
| `StartAt` | `StartAt` | `double, double` | 2 |
| `CreateBeatShift` | `CreateBeatShift`, `BeatShift` | `double, double, int, int` | 3 |
| `CreateBeatShiftEx` | `CreateBeatShiftEx`, `BeatShiftEx` | +1 参数 | 4 |
| `ActivateBeatShift` | `ActivateBeatShift` | `int` | 1 |
| `EdgeNote` | `EdgeNote`, `E`, `ECV`, `EFAKE`, `ETSL_S/L/T` | `int, int, float, int, string` | 4 |
| `SpaceNote` | `SpaceNote`, `S`, `SCV`, `SFAKE`, `STSL_S/L/T` | `int, float, float, int, string` | 4 |
| `SnakeSubQ` | `SnakeSubQ`, `SQ`, `SQCV`, `SQFAKE`, `SQTSL_S/L/T` | `float, float, float, int, string` | 4 |
| `BeginSnake` / `EndSnake` | `BeginSnake` / `EndSnake` | `string` / 无参 | 0 |
| `SpeedChangeQ` | `SpeedChangeQ` | `double, double, float, float, float` | 5 |

按 250 个谱面统计的实际出现次数：`SQ` 114k、`E` 106k、`BeginSnake`/`EndSnake` 各 40k、`S` 29k、`SpeedChangeQ` 2.3k、`ActivateBeatShift` 1.9k、`CreateBeatShift` 1.7k、`Offset`/`InitBeat` 各 250；`EFAKE/SFAKE/SQFAKE/ECV/SCV/SQCV` 是少量特殊标记。

实际谱面（`assets/TextAsset/charts/*.txt`）示例：

```
Offset,0
InitBeat,60,4
E,0,3,3,120960          # 地键：edge, x, size, pulse
S,0,3,1.5,362880        # 天空键
CreateBeatShift,0.001,90,3
```

`pulse` 为 480/拍（MIDI PPQ），后两个 float 是 0–9 的横向坐标/宽度，5 号字符串参数可省略（fake/CV 等标记）。

### 8.4 与 mod 直接相关的入口

| 用途 | 符号 | 4.13 RVA |
| --- | --- | --- |
| 谱面解析 | `ParsaPara.Execute(string)` | `0x125552C` |
| 谱面加载协程（取 TextAsset → Execute → 写入 `Messenger.ChartHandle`） | `Messenger.<_testLoad>d__21.MoveNext` | `0x125CF9C` |
| 曲目元数据刷新 | `SongMeta.UpdateMetaFromJSON(string)` | `0x125DF40` |
| 判定主循环 | `JudgeSystem.UpdateTime()` | `0x12EAE08` |
| 单槽判定写入 | `JudgeSlot.SetResult(EJudgeResult, bool)` | `0x12F37F0` |
| 开局 | `GameControl.GameStart()` | `0x01079774` |

判定结果枚举 `EJudgeResult`：`Uninitialized=0, Unjudge=1, Decrypted=2（Perfect）, Received=3, Lost=4, None=5, Pulling=6`。

`JudgeSystem` 内存布局：`Slots: List<JudgeSlot>` @0x10，`currentTimeSnapshot: float` @0x60；
`JudgeSlot`：`result` @0x10，`PerfectTime` @0x18；`List<T>`：`_items` @0x10，`_size` @0x18。

## 9. Mod 结论

- 4.13 无二次加壳、无完整性校验、无越狱/反调试检测，`UnityFramework` 已解密，可直接做静态注入 + 运行时 hook。
- AutoPlay 的最短路径：hook `JudgeSystem.UpdateTime`，在每帧原逻辑之后遍历 `Slots`，对未判定且已到 `PerfectTime` 的槽位调用 `SetResult(Decrypted, true)`。不改存档逻辑，天然 AP。
- 曲包/谱面替换的另一条路径：用 `tools/paradigm_pack.py` 下载官方 bundle → UnityPy 替换 TextAsset（谱面）/Texture2D（曲绘），即可在不动二进制的情况下改谱。
- 工具：
  - `tools/paradigm_pack.py`：`login`（国服手机号）/`download`/`unpack`/`songs`/`audio`/`export`
  - `ParadigmMod/`：dylib 工程（设置页 + 玩法开关 + 注入打包脚本）
- 本轮已下载：`downloads/` 2702 个 `s` 组 bundle（1.99 GB，全部已解密为明文 UnityFS），
  对应 **441 首曲目**（每首 cover / music / preview / detected / invaded / massive 齐备，24 首额外带 reboot、24 首带 chaotic）。
- `songs/` 为可读导出：441 首、**1371 个谱面**（约 371 万行）、441 张曲绘、**882 条 OGG 音频**（music + preview），总计约 2.06 GB；`songs/_songs.csv` 是曲目总表。

### 9.1 ParadigmMod v0.2 功能

| 功能 | 实现方式 | 4.13 地址 |
| --- | --- | --- |
| AutoPlay | hook `JudgeSystem.UpdateTime`，遍历 `Slots` 打 `Decrypted` | `0x12EAE08` |
| 全 Perfect | hook `JudgeSlot.SetResult`，`Received/Lost` → `Decrypted` | `0x12F37F0` |
| 锁血 | hook `GameControl.AddHP`，`Lost` 按 `Decrypted` 结算 | `0x1079DC8` |
| 屏蔽成绩上传 | hook `BackendAPI.Run(IEnumerator)`，拦截类名含 `ScoreUploadCoroutine` 的协程 | `0x1331700` |
| 全曲/全难度解锁 | 周期写 `TrackUnlockStorage.UnlockAll = true` | 静态字段 |
| 变速 0.5–2.0x | 周期写 `Chart.hiSpeedMultiplier`（关闭时还原原值） | 静态字段 |

设置页为原生 UIKit（悬浮球点开），开关持久化到 `NSUserDefaults`（键 `pm.*`）。
未做：Unity 内嵌 MOD tab（需要克隆原生按钮与导航）、自定义曲库注入。

