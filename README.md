# ParadigmMod — 《范式：起源》iOS 4.13 注入式 mod

面向已砸壳（`cryptid = 0`）的 `UnityFramework`，通过 `LC_LOAD_DYLIB` 注入。
只做本地玩法与界面，不修改服务端内容。

## 功能

| 功能 | 落点 | 说明 |
| --- | --- | --- |
| AutoPlay | `JudgeSystem.UpdateTime` `0x12EAE08` | 每帧遍历 `JudgeSystem.Slots`，到点未判定的槽位调用 `JudgeSlot.SetResult(Decrypted)` |
| 全 Perfect | `JudgeSlot.SetResult` `0x12F37F0` | `Received` / `Lost` 强制改成 `Decrypted` |
| 锁血 | `GameControl.AddHP` `0x1079DC8` | `Lost` 按 `Decrypted` 结算 |
| 屏蔽成绩上传 | `BackendAPI.Run(IEnumerator)` `0x1331700` | 拦截类名含 `ScoreUploadCoroutine` 的协程，本地最高分照常写入 |
| 全曲 / 全难度解锁 | `TrackUnlockStorage.UnlockAll` 静态字段 | 官方自带的总解锁开关 |
| 变速 0.5–2.0x | `Chart.hiSpeedMultiplier` 静态字段 | 关闭时还原进入前原值 |

设置页是原生 UIKit：点屏幕上的悬浮球打开，开关持久化在 `NSUserDefaults`（键 `pm.*`）。

## 构建

macOS（或在 GitHub Actions 上跑 `.github/workflows/build.yml`）：

```bash
bash ParadigmMod/build_unsigned.sh
```

产物：

- `ParadigmMod/build/ParadigmMod.dylib` —— 独立 dylib，`install_name = @executable_path/Frameworks/ParadigmMod.dylib`
- `ParadigmMod/build/ParadigmMod.framework` —— framework 形式

两个产物都只做了 ad-hoc 签名（`codesign -s -`），装真机前需要你自己的证书重签。

## 注入

### 方式 A：dylib（你自签用这个）

1. 解包你的 IPA，把 `ParadigmMod.dylib` 放到 `Payload/ProductName.app/Frameworks/`
2. 给 `Frameworks/UnityFramework.framework/UnityFramework` 添加加载命令：

   ```bash
   python3 ParadigmMod/tools/inject_load_dylib.py \
     Payload/ProductName.app/Frameworks/UnityFramework.framework/UnityFramework \
     @executable_path/Frameworks/ParadigmMod.dylib
   ```
3. 重签（`ParadigmMod.dylib`、`UnityFramework.framework`、App 本体）

> 如果 App 二进制本身不会加载 `Frameworks/` 下的 dylib，也可以把加载命令指向
> `@loader_path/../ParadigmMod.dylib`（相对 UnityFramework 所在目录）。

### 方式 B：framework + 一键打包

```bash
python3 ParadigmMod/tools/package_unsigned_ipa.py \
  --source <解包目录，含 Payload> \
  --framework ParadigmMod/build/ParadigmMod.framework \
  --output ParadigmMod_4.13_unsigned.ipa
```

脚本带版本门禁：`UnityFramework` UUID 必须是 `964f6391cd6c33788f84dd0aae540677`（4.13）。

## 目录

```
ParadigmMod/
  Sources/PMCore.mm        hook、il2cpp 反射、AutoPlay/判定/HP/上传拦截
  Sources/PMOverlay.mm     悬浮球 + 设置页
  Sources/PMBootstrap.mm   入口与周期任务
  tools/                   LC_LOAD_DYLIB 注入、未签名 IPA 打包
  build_unsigned.sh        构建脚本
tools/paradigm_pack.py     曲包下载 / 解密 / 解包（国服手机号登录）
docs/REVERSE_4.13.md       4.13 逆向报告（曲目链路、谱面 DSL、关键地址）
```

## 曲包工具

```bash
python tools/paradigm_pack.py login --phone <手机号> --password <密码>
python tools/paradigm_pack.py download --filter s --out downloads
python tools/paradigm_pack.py songs --src downloads --out songs          # 谱面 + 曲绘
python tools/paradigm_pack.py audio --src downloads --out songs --format ogg
```

命令说明见 `python tools/paradigm_pack.py <cmd> -h`。

## 说明

- 未做：Unity 内嵌 MOD tab、自定义曲库注入。
- `UnlockAll` 只覆盖 `TrackUnlockStorage`，付费曲包若仍走商店所有权校验则不会解锁。
- 变速直接覆盖 `Chart.hiSpeedMultiplier`，与游戏内速度设置存在叠加关系。
- 本项目不含游戏资源、`dump.cs`、`global-metadata.dat` 或任何账号信息。
