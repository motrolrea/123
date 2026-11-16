# RizlineMod

《律动轨迹》iOS 2.7.1（`com.leiting.ldgj`，Unity 2022.3 + il2cpp metadata v31）注入型 Mod。

基准包：`com.leiting.ldgj_2.7.1_cn_iphone_dumpipa.com.ipa`
UnityFramework UUID：`41d3a6b76c0d3f01a6cb0ddd615f3156`

## 功能

- 自动打歌（全 Perfect）：直接开启官方 `NoteJudgeControl.AutoPlay`，挑战段为 MaxPerfect
- 无 Bad：官方 `NoBad`
- 自由 Hold：官方 `FreeHold`
- 锁血：每帧把 `_life` 钉回 1.0、`_damage` 清零
- 全曲解锁：把 `LevelControl.GetAllLevelId()` / `GetAllDiscOLevel()` 的 id 写入 `PaymentService.ownedTracks`（仅进程内，不写存档）
- 离线模式：拦截 `rizserver.pigeongames.net` 的 DNS 解析，阻止成绩上传
- 悬浮球 + 斜切风格设置页（玩法 / 解锁 / 界面 / 诊断），运行日志与崩溃日志

全程只做 il2cpp 反射与字段写入，不修改 `__TEXT` 代码页，适配无 JIT / 无代码页写权限的未签名与 TrollStore 环境。

## 构建

需要 macOS + Xcode（iOS 15+ SDK）：

```bash
cd RizlineMod
bash build_unsigned.sh
```

产物：`build/RizlineMod.framework` 与 `build/RizlineMod.dylib`。
也可以直接把仓库推到 GitHub，由 `.github/workflows/build-ios.yml` 在 `macos-15` 上编译。

## 打包未签名 IPA

```bash
python tools/package_unsigned_ipa.py \
  --source "路径/含 Payload 的解包目录" \
  --framework "RizlineMod/build/RizlineMod.framework" \
  --output "RizlineMod_2.7.1_unsigned.ipa"
```

脚本会校验 UnityFramework UUID，把 framework 拷到 `Payload/*.app/Frameworks/`，并向 UnityFramework 插入
`LC_LOAD_DYLIB = @loader_path/../RizlineMod.framework/RizlineMod`。

输出保持未签名；安装前需用证书 / 描述文件重签（TrollStore 可直接安装）。

## 关键偏移（2.7.1）

| 类 / 字段 | 偏移 |
| --- | --- |
| `InLevel.LevelInformation.noteJudgeControl` | `0x58` |
| `LevelInformation.levelBegan` / `levelOver` | `0xCF` / `0xD0` |
| `InLevel.NoteJudgeControl.FreeHold` / `AutoPlay` | `0x89` / `0x8A` |
| `NormalModeInLevelController._life` / `_damage` | `0x44` / `0x88` |
| `NormalModeInLevelController._noBad` / `_autoPlay` | `0x24C` / `0x258` |
| `ChallengeInLevelController._life` / `_noBad` | `0x40` / `0x161` |
| `WeeklyChallengeModeController.life` / `damage` | `0x23C` / `0x240` |
| `PaymentService.ownedTracks` / `vipTracks` | `0x18` / `0x20` |

## 注意

- 自动打歌会被游戏标记为 Mod 游玩，正常模式不计排行；周赛 / 挑战模式如需完全避免上传，请开启离线模式。
- 离线模式会让登录、同步、排行榜不可用，关闭后建议重启游戏恢复联网。
- 全曲解锁只影响当前进程，重启后需重新开启，不会修改服务器数据。
