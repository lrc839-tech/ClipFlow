#!/usr/bin/env python3
"""Package an already-built App without rebuilding, signing, or changing it.

Uses only the supplied .app, docs/INSTALL.md, and generated public metadata.
No clipboard storage, user defaults, logs, or source workspace is copied.
"""
import argparse
import hashlib
import html
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    if app.name != 'ClipFlow.app' or not app.is_dir():
        parser.error('--app must point to an existing ClipFlow.app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'local.lrc.clipflow':
        parser.error('unexpected bundle identifier')
    version = info['CFBundleShortVersionString']
    if version != '0.5.0':
        parser.error('update the installation guide and release version before packaging')
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if run('/usr/bin/lipo', '-archs', str(binary)).strip() != 'arm64':
        parser.error('this release guide and filename require a thin arm64 app')
    run('/usr/bin/codesign', '--verify', '--strict', str(app))
    before = digest(binary)
    guide = (ROOT / 'docs/INSTALL.md').read_text()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir.resolve() / f'ClipFlow-{version}-macOS-arm64.dmg'
    if output.exists():
        parser.error(f'output already exists: {output}')
    cache = Path.home() / 'Library/Caches/ClipFlowPackaging'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='dmg-', dir=cache) as temporary:
        stage = Path(temporary) / 'ClipFlow'
        stage.mkdir()
        run('/usr/bin/ditto', '--norsrc', '--noextattr', str(app), str(stage / app.name))
        run('/usr/bin/codesign', '--verify', '--strict', str(stage / app.name))
        assert digest(stage / 'ClipFlow.app/Contents/MacOS/ClipFlowApp') == before
        (stage / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (stage / '安装与首次打开说明.txt').write_text(guide)
        (stage / '安装与首次打开说明.html').write_text('''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'">
<title>ClipFlow 安装与首次打开说明</title>
<style>body{max-width:880px;margin:36px auto;padding:0 24px;font:16px/1.8 -apple-system,BlinkMacSystemFont,sans-serif;color:#243047;background:#f6f8fc}header,main{padding:24px 30px;background:white;border:1px solid #dbe3ef;border-radius:14px;margin-bottom:20px}h1{margin:0;font-size:30px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}a{color:#2356b8}.lead{color:#53647c}</style>
<header><h1>ClipFlow · 安装说明</h1><p class="lead">把 ClipFlow.app 拖到 Applications，然后从应用程序文件夹打开。</p>
<p>未公证应用：先尝试打开 → 隐私与安全性 → 仍要打开 → 打开。随后单独启用辅助功能权限。</p>
<a href="https://github.com/lrc839-tech/ClipFlow/blob/main/docs/INSTALL.md">在线安装说明</a> · <a href="https://support.apple.com/zh-cn/102445">Apple 官方说明</a></header>
<main><pre>''' + html.escape(guide) + '</pre></main></html>\n')
        (stage / 'release-info.json').write_text(json.dumps({
            'version': version, 'architecture': 'arm64', 'status': 'development-preview',
            'signing': 'ad-hoc', 'notarized': False,
            'bundleIdentifier': info['CFBundleIdentifier'],
            'executableSHA256': before,
            'installationGuideSHA256': hashlib.sha256(guide.encode()).hexdigest(),
            'repository': 'https://github.com/lrc839-tech/ClipFlow',
        }, ensure_ascii=False, indent=2) + '\n')
        run('/usr/bin/hdiutil', 'create', '-volname', f'ClipFlow {version}',
            '-srcfolder', str(stage), '-format', 'UDZO', '-ov', str(output))
    run('/usr/bin/hdiutil', 'verify', str(output))
    assert digest(binary) == before, 'source executable changed during packaging'
    checksum = output.parent / 'SHA256SUMS.txt'
    checksum.write_text(f'{digest(output)}  {output.name}\n')
    print(json.dumps({'dmg': str(output), 'sha256': digest(output),
                      'bytes': output.stat().st_size,
                      'sourceExecutableUnchanged': True}, indent=2))


if __name__ == '__main__':
    main()
