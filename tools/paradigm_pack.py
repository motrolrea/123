#!/usr/bin/env python3
"""《范式：起源》4.13 曲包下载 / 解密 / 解包一体化工具

子命令：
  login     使用邮箱密码登录，打印 authToken 并保存到 config.json
  download  登录态下取远端 catalog -> 签名 -> 批量下载 postdownloadpack bundle -> 解密
  unpack    把 bundle 目录解包成 png / wav / txt / json
  export    直接对本地 app 的 Data/Raw/aa/iOS 做解密+解包

依赖：requests pycryptodome UnityPy pillow fmod_toolkit fsb5
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import json
import os
import secrets
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

import requests
import urllib3
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad, unpad

urllib3.disable_warnings()

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
# 国服 iOS 走 4399 的 tuner-api + fsqy CDN；国际服则是 api.paradigm.tunergames.com
API_BASE = "https://tuner-api.paradigmchina.tunergames.com"
ASSET_BASE = "https://fsqy-cdn.3839pic.com/cn-ios"

API_VERSION = "100"      # 4.13
GAME_VERSION = "4.13"
PLATFORM = "iOS"

BODY_KEY = b"Paradigm9537c1fa"
BUNDLE_KEY = bytes.fromhex("A73CC5F90BC321B251756A93B70A9338")
FWD_SEED = 0x05B48FC7
REV_SEED = 0x012936E5

CACHE_FILE = "config.json"

# ---------------------------------------------------------------------------
# 加解密
# ---------------------------------------------------------------------------
def bundle_iv(filename: str) -> bytes:
    a, b = FWD_SEED, REV_SEED
    for ch in filename:
        a = (a * 31 + ord(ch)) & ((1 << 64) - 1)
    for ch in reversed(filename):
        b = (b * 31 + ord(ch)) & ((1 << 64) - 1)
    return struct.pack("<QQ", a, b)


def decrypt_bundle(data: bytes, filename: str) -> bytes:
    if data[:7] == b"UnityFS":
        return data
    return unpad(AES.new(BUNDLE_KEY, AES.MODE_CBC, bundle_iv(filename)).decrypt(data), 16)


def body_encrypt(raw: bytes) -> bytes:
    iv = secrets.token_bytes(16)
    return iv + AES.new(BODY_KEY, AES.MODE_CBC, iv).encrypt(pad(raw, 16))


def body_decrypt(data: bytes) -> bytes:
    return unpad(AES.new(BODY_KEY, AES.MODE_CBC, data[:16]).decrypt(data[16:]), 16)


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
def load_config() -> dict:
    try:
        return json.loads(Path(CACHE_FILE).read_text("utf-8"))
    except Exception:
        return {}


def save_config(cfg: dict) -> None:
    Path(CACHE_FILE).write_text(json.dumps(cfg, ensure_ascii=False, indent=2), "utf-8")
    print(f"配置已保存: {Path(CACHE_FILE).resolve()}")


def api_headers(token: str | None = None, device: str | None = None, extra: dict | None = None) -> dict:
    cfg = load_config()
    h = {
        "User-Agent": "UnityPlayer/2022.3.62f2c1 (UnityWebRequest/1.0, libcurl/8.10.1-DEV)",
        "Accept": "*/*",
        "Content-Type": "application/json;charset=utf-8",
        "X-Device-Id": device or cfg.get("uuid") or "9f1b2f9b-4000-4000-8000-000000000001",
        "X-Language": "zh",
        "X-Unity-Version": "2022.3.62f2c1",
        "X-game-version": GAME_VERSION,
        "X-api-version": API_VERSION,
        "X-platform": PLATFORM,
    }
    if token:
        h["X-Session"] = token
    if extra:
        h.update(extra)
    return h


# ---------------------------------------------------------------------------
# 登录
# ---------------------------------------------------------------------------
def cmd_login(args) -> int:
    cfg = load_config()
    if not cfg.get("uuid"):
        cfg["uuid"] = "9f1b2f9b-4000-4000-8000-000000000001"
        save_config(cfg)

    # 国服：手机号 + 密码 -> /account/login
    if args.phone or cfg.get("phone"):
        phone = args.phone or cfg.get("phone")
        password = args.password or cfg.get("password")
        if not password:
            print("缺少密码")
            return 2
        r = requests.post(f"{API_BASE}/account/login", headers=api_headers(),
                          json={"phone": phone, "password": password}, verify=False, timeout=20)
        body = r.json()
        if body.get("code") != "OK":
            print("登录失败:", r.status_code, body)
            return 1
        token = body["data"]["authToken"]
        cfg.update({"phone": phone, "password": password, "token": token})
        save_config(cfg)
        print("登录成功(国服), token:", token[:16], "...")
        return 0

    email = args.email or cfg.get("email") or input("邮箱: ").strip()
    password = args.password or cfg.get("password") or input("密码: ").strip()

    if not args.no_status_check:
        r = requests.post(f"{API_BASE}/user/login/status",
                          headers=api_headers(), json={"email": email}, verify=False, timeout=20)
        print("status:", r.status_code, r.text[:200])

    r = requests.post(f"{API_BASE}/user/login/password",
                      headers=api_headers(), json={"email": email, "password": password},
                      verify=False, timeout=20)
    body = r.json()
    if body.get("code") != "OK":
        print("登录失败:", r.status_code, body)
        return 1
    token = body["data"]["authToken"]
    cfg.update({"email": email, "password": password, "token": token})
    save_config(cfg)
    print("登录成功, token:", token[:16], "...")
    return 0


# ---------------------------------------------------------------------------
# 远端 catalog / 签名 / 下载
# ---------------------------------------------------------------------------
def fetch_catalog(token: str) -> dict:
    r = requests.get(f"{API_BASE}/server/hotassets/catalog",
                     headers=api_headers(token), verify=False, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"catalog HTTP {r.status_code}: {r.text[:200]}")
    body = json.loads(body_decrypt(r.content))
    if str(body.get("status", "")).lower() != "ok":
        raise RuntimeError(f"catalog 返回异常: {body}")
    url = body["url"]["catalog"]
    print("catalog:", url)
    r = requests.get(url, verify=False, timeout=120,
                     headers={"User-Agent": "UnityPlayer/2022.3.62f2c1 (UnityWebRequest/1.0, libcurl/8.10.1-DEV)"})
    r.raise_for_status()
    return r.json()


def catalog_bundle_paths(catalog: dict) -> list[str]:
    out = []
    for iid in catalog.get("m_InternalIds", []):
        idx = iid.find("postdownloadpack_assets_")
        if idx < 0:
            continue
        path = iid[idx:]
        if not path.startswith("/"):
            path = "/" + path
        out.append(path)
    return sorted(set(out))


def sign_paths(token: str, paths: list[str]) -> dict:
    payload = json.dumps({"url_list": paths}).encode()
    r = requests.post(f"{API_BASE}/server/hotassets/sign",
                      headers=api_headers(token, extra={"Content-Type": "application/octet-stream"}),
                      data=body_encrypt(payload), verify=False, timeout=120)
    if r.status_code != 200:
        raise RuntimeError(f"sign HTTP {r.status_code}: {r.text[:200]}")
    body = json.loads(body_decrypt(r.content))
    if str(body.get("status", "")).lower() != "ok":
        raise RuntimeError(f"sign 返回异常: {str(body)[:300]}")
    return body["data"]


def download_one(url: str, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        return True
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with requests.get(url, stream=True, verify=False, timeout=(15, 30)) as r:
            r.raise_for_status()
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(1 << 20):
                    if chunk:
                        f.write(chunk)
        tmp.replace(dest)
        try:
            raw = dest.read_bytes()
            plain = decrypt_bundle(raw, dest.name)
            if plain[:7] == b"UnityFS" and plain != raw:
                dest.write_bytes(plain)
        except Exception:
            pass
        return True
    except Exception as e:
        print("下载失败", dest.name, e)
        tmp.unlink(missing_ok=True)
        return False


def cmd_download(args) -> int:
    cfg = load_config()
    token = args.token or cfg.get("token")
    if not token:
        print("缺少 token，请先运行 login")
        return 2
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    catalog = fetch_catalog(token)
    paths = catalog_bundle_paths(catalog)
    if args.filter and args.filter != "all":
        keep = [g.strip("/ ") for g in args.filter.split(",") if g.strip()]
        paths = [p for p in paths if p.split("postdownloadpack_assets_", 1)[-1].split("/")[0] in keep]
    print(f"远端 bundle: {len(paths)} 个")
    Path(out / "_catalog.json").write_text(json.dumps(catalog, ensure_ascii=False), "utf-8")

    signed_map: dict[str, str] = {}
    batch = args.batch
    for i in range(0, len(paths), batch):
        part = paths[i:i + batch]
        print(f"签名 {i + 1}-{i + len(part)}")
        data = sign_paths(token, part)
        for k, v in data.items():
            if isinstance(v, str):
                signed_map[k] = v
            elif isinstance(v, list):
                for item in v:
                    if isinstance(item, str):
                        signed_map[k] = item

    jobs = []
    for path in paths:
        signed = signed_map.get(path)
        if not signed:
            continue
        url = signed if signed.startswith("http") else ASSET_BASE + signed
        parts = [p for p in path.split("/") if p]
        rel = Path(*parts[1:]) if len(parts) >= 3 else Path(*parts)
        jobs.append((url, out / rel))
    print(f"待下载 {len(jobs)} 个")

    ok = 0
    with futures.ThreadPoolExecutor(max_workers=args.threads) as pool:
        futs = [pool.submit(download_one, u, d) for u, d in jobs]
        for f in futures.as_completed(futs):
            ok += 1 if f.result() else 0
            if ok % 20 == 0:
                print(f"  完成 {ok}/{len(jobs)}")
    print(f"下载完成 {ok}/{len(jobs)} -> {out}")
    return 0


# ---------------------------------------------------------------------------
# 解包
# ---------------------------------------------------------------------------
def sanitize(name: str) -> str:
    bad = '<>:"/\\|?*'
    return ("".join("_" if c in bad else c for c in (name or "unnamed")).strip() or "unnamed")[:120]


def cmd_unpack(args) -> int:
    import UnityPy
    src = Path(args.src)
    out = Path(args.out)
    bundles = [p for p in src.rglob("*.bundle")]
    print(f"bundle: {len(bundles)}")
    type_count: dict[str, int] = {}
    for n, p in enumerate(bundles, 1):
        tmp = p
        try:
            raw = p.read_bytes()
            plain = decrypt_bundle(raw, p.name)
            if plain is not raw:
                tmp = p.with_name(p.name + ".plain")
                tmp.write_bytes(plain)
            env = UnityPy.load(str(tmp))
            stem = sanitize(p.parent.name) + "__" + sanitize(p.stem)
            for obj in env.objects:
                t = obj.type.name
                type_count[t] = type_count.get(t, 0) + 1
                data = None
                try:
                    data = obj.read()
                except Exception:
                    continue
                name = sanitize(getattr(data, "m_Name", "unnamed"))
                d = out / stem / t
                d.mkdir(parents=True, exist_ok=True)
                if t == "TextAsset":
                    s = data.m_Script
                    if isinstance(s, bytes):
                        s = s.decode("utf-8", "replace")
                    (d / f"{name}.txt").write_text(s, "utf-8")
                elif t in ("Texture2D", "Sprite"):
                    try:
                        data.image.save(d / f"{name}.png")
                    except Exception:
                        pass
                elif t == "AudioClip":
                    export_audio(data, obj, d / f"{name}.wav")
                elif t == "Mesh":
                    (d / f"{name}.obj").write_text(data.export(), "utf-8")
        except Exception as e:
            print("失败", p.name, e)
        finally:
            if tmp != p:
                try:
                    tmp.unlink(missing_ok=True)
                except OSError:
                    pass
        if n % 25 == 0:
            print(f"  {n}/{len(bundles)}")
    print("类型统计:", type_count)
    print("输出:", out.resolve())
    return 0


def export_audio(clip, obj, dest: Path) -> None:
    """AudioClip -> WAV。优先用 UnityPy 的 samples（内部 fmod 解码），失败再导出 FSB 原始数据。"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        for _, wav in clip.samples.items():
            dest.write_bytes(wav)
            return
    except Exception:
        pass
    try:
        af = obj.assets_file
        par = af.parent
        res = next((k for k in par.files if k.endswith(".resource")), None)
        if not res:
            return
        reader = par.files[res]
        reader.Position = 0
        dest.with_suffix(".fsb").write_bytes(reader.read(reader.Length))
    except Exception:
        pass


def cmd_songs(args) -> int:
    """把 downloads/<songid>/ 整理成 songs/<songid>/{charts,audio,cover} 的干净结构。

    默认只导出谱面 + 曲绘（快、体积小）；需要音频时加 --audio wav / --audio ogg。
    """
    import UnityPy
    src = Path(args.src)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    want_audio = args.audio != "none"
    song_dirs = [p for p in src.iterdir() if p.is_dir()]
    song_dirs.sort(key=lambda p: p.name)
    index = {}
    for n, song in enumerate(song_dirs, 1):
        rec = {}
        for bundle in sorted(song.glob("*.bundle")):
            kind = bundle.name.split("_", 1)[0]
            try:
                env = UnityPy.load(str(bundle))
                for obj in env.objects:
                    t = obj.type.name
                    if t == "TextAsset":
                        data = obj.read()
                        s = data.m_Script
                        if isinstance(s, bytes):
                            s = s.decode("utf-8", "replace")
                        d = out / song.name / "charts"
                        d.mkdir(parents=True, exist_ok=True)
                        name = sanitize(getattr(data, "m_Name", kind))
                        (d / f"{name}.txt").write_text(s, "utf-8")
                        rec.setdefault("charts", []).append(f"charts/{name}.txt")
                    elif t == "AudioClip" and want_audio:
                        data = obj.read()
                        d = out / song.name / "audio"
                        d.mkdir(parents=True, exist_ok=True)
                        wav_path = d / f"{kind}.wav"
                        try:
                            for _, wav in data.samples.items():
                                wav_path.write_bytes(wav)
                                break
                        except Exception:
                            pass
                        for junk in d.glob("*.dec.wav"):
                            try:
                                junk.unlink()
                            except OSError:
                                pass
                        if wav_path.exists():
                            if args.audio == "ogg":
                                ogg = d / f"{kind}.ogg"
                                if convert_ogg(wav_path, ogg):
                                    wav_path.unlink(missing_ok=True)
                                    rec.setdefault("audio", []).append(f"audio/{kind}.ogg")
                                else:
                                    rec.setdefault("audio", []).append(f"audio/{kind}.wav")
                            else:
                                rec.setdefault("audio", []).append(f"audio/{kind}.wav")
                    elif t == "Texture2D":
                        data = obj.read()
                        d = out / song.name
                        d.mkdir(parents=True, exist_ok=True)
                        if kind == "cover":
                            try:
                                data.image.save(d / "cover.png")
                                rec["cover"] = "cover.png"
                            except Exception:
                                pass
            except Exception as e:
                print("失败", bundle.name, e)
        if rec:
            index[song.name] = rec
        if n % 25 == 0:
            print(f"  {n}/{len(song_dirs)}  {song.name}", flush=True)
    (out / "_index.json").write_text(json.dumps(index, ensure_ascii=False, indent=1), "utf-8")
    print(f"完成 {len(index)} 首 -> {out.resolve()}")
    return 0


def convert_ogg(wav: Path, ogg: Path) -> bool:
    ffmpeg = Path(r"e:\Trae CN\Clock\_re\tools\ffmpeg.exe")
    if not ffmpeg.exists():
        ffmpeg = Path("ffmpeg")
    try:
        r = subprocess.run([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
                            "-i", str(wav), "-c:a", "libvorbis", "-q:a", "6", str(ogg)],
                           capture_output=True, timeout=300)
        return r.returncode == 0 and ogg.exists() and ogg.stat().st_size > 0
    except Exception:
        return False


def _audio_worker(job):
    import UnityPy
    bundle, target, fmt, ffmpeg = job
    try:
        env = UnityPy.load(str(bundle))
        for obj in env.objects:
            if obj.type.name != "AudioClip":
                continue
            clip = obj.read()
            wav = target.with_suffix(".wav")
            got = False
            try:
                for _, data in clip.samples.items():
                    wav.write_bytes(data)
                    got = True
                    break
            except Exception:
                pass
            for junk in target.parent.glob("*.dec.wav"):
                try:
                    junk.unlink()
                except OSError:
                    pass
            if not got:
                return None
            if fmt == "ogg":
                ogg = target.with_suffix(".ogg")
                try:
                    r = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                                        "-i", str(wav), "-c:a", "libvorbis", "-q:a", "6", str(ogg)],
                                       capture_output=True, timeout=600)
                    if r.returncode == 0 and ogg.exists() and ogg.stat().st_size > 0:
                        wav.unlink(missing_ok=True)
                        return str(ogg)
                except Exception:
                    pass
            return str(wav)
    except Exception:
        return None
    return None


def cmd_audio(args) -> int:
    """并行导出 downloads/<song>/{music,preview} 音频（wav 或 ogg）。"""
    src = Path(args.src)
    out = Path(args.out)
    fmt = args.format
    ffmpeg = r"e:\Trae CN\Clock\_re\tools\ffmpeg.exe"
    if not Path(ffmpeg).exists():
        ffmpeg = "ffmpeg"
    jobs = []
    for song in src.iterdir():
        if not song.is_dir():
            continue
        for bundle in song.glob("*.bundle"):
            kind = bundle.name.split("_", 1)[0]
            if kind not in ("music", "preview"):
                continue
            d = out / song.name / "audio"
            d.mkdir(parents=True, exist_ok=True)
            target = d / kind
            if target.with_suffix("." + fmt).exists() and target.with_suffix("." + fmt).stat().st_size > 0:
                continue  # 已转换过，支持断点续跑
            jobs.append((bundle, target, fmt, ffmpeg))
    print(f"音频任务 {len(jobs)} 个，{args.jobs} 进程")
    done = 0
    with futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for _ in pool.map(_audio_worker, jobs, chunksize=4):
            done += 1
            if done % 50 == 0:
                print(f"  {done}/{len(jobs)}", flush=True)
    print(f"音频完成 {done}/{len(jobs)} -> {out.resolve()}")
    return 0


def cmd_export(args) -> int:
    """对本地 app 的 Raw/aa/iOS 直接解包（bundle 加密、无需登录）。"""
    app = Path(args.app)
    aa = app / "Data/Raw/aa/iOS" if (app / "Data").is_dir() else app
    tmpdir = Path(args.tmp or ".bundle_plain")
    tmpdir.mkdir(parents=True, exist_ok=True)
    count = 0
    for p in aa.rglob("*.bundle"):
        plain = decrypt_bundle(p.read_bytes(), p.name)
        (tmpdir / p.name).write_bytes(plain)
        count += 1
    print(f"已解密 {count} 个 bundle -> {tmpdir}")
    return cmd_unpack(argparse.Namespace(src=str(tmpdir), out=args.out))


def main() -> int:
    ap = argparse.ArgumentParser(description="范式：起源 4.13 曲包工具")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("login", help="登录并缓存 token（国服用 phone）")
    p.add_argument("--email")
    p.add_argument("--phone")
    p.add_argument("--password")
    p.add_argument("--no-status-check", action="store_true")
    p.set_defaults(func=cmd_login)

    p = sub.add_parser("download", help="下载全部 postdownloadpack 曲包")
    p.add_argument("--token")
    p.add_argument("--out", default="downloads")
    p.add_argument("--threads", type=int, default=8)
    p.add_argument("--batch", type=int, default=200)
    p.add_argument("--filter", default="all", help="按分组过滤，如 s,bg,illust；默认 all")
    p.set_defaults(func=cmd_download)

    p = sub.add_parser("unpack", help="解包 bundle 目录")
    p.add_argument("--src", required=True)
    p.add_argument("--out", default="unpacked")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("songs", help="把 downloads 整理成 songs/<id>/{charts,audio,cover}")
    p.add_argument("--src", default="downloads")
    p.add_argument("--out", default="songs")
    p.add_argument("--audio", choices=("none", "wav", "ogg"), default="none",
                   help="音频导出格式；默认 none（只出谱面+曲绘）")
    p.set_defaults(func=cmd_songs)

    p = sub.add_parser("audio", help="并行导出 downloads 里的 music/preview 音频")
    p.add_argument("--src", default="downloads")
    p.add_argument("--out", default="songs")
    p.add_argument("--format", choices=("wav", "ogg"), default="ogg")
    p.add_argument("--jobs", type=int, default=max(2, (os.cpu_count() or 4) // 2))
    p.set_defaults(func=cmd_audio)

    p = sub.add_parser("export", help="解密并解包本地 IPA 的 Data/Raw/aa/iOS")
    p.add_argument("--app", required=True, help="ProductName.app 目录")
    p.add_argument("--out", default="unpacked_local")
    p.add_argument("--tmp", default=".bundle_plain")
    p.set_defaults(func=cmd_export)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
