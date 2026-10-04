#!/usr/bin/env python3
"""Build the published Swift source using resources from the app release."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True,
                        help='Path to the unzipped release LumaPaw.app')
    parser.add_argument('--identity', default='-',
                        help='Your code signing identity; default is ad-hoc')
    args = parser.parse_args()
    original = args.app.expanduser().resolve()
    resources = original / 'Contents/Resources'
    info_file = original / 'Contents/Info.plist'
    if not resources.is_dir() or not info_file.is_file():
        parser.error('--app must point to the downloaded LumaPaw.app bundle')
    root = Path(__file__).resolve().parent.parent
    target = root / 'build/LumaPaw.app'
    if target.resolve() == original:
        parser.error('Use the downloaded release as input, not the build output')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lumapaw-build-') as tmp:
        staging = Path(tmp) / 'LumaPaw.app'
        contents = staging / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        subprocess.run(['ditto', '--norsrc', '--noextattr', str(resources),
                        str(contents / 'Resources')], check=True)
        info = plistlib.loads(info_file.read_bytes())
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        for shader in (root / 'Sources').glob('*.metal'):
            shutil.copyfile(shader, contents / 'Resources' / shader.name)
        cmd = ['xcrun', 'swiftc', '-O', '-swift-version', '5',
               '-module-cache-path', str(Path(tmp) / 'swift-cache'),
               '-target', 'arm64-apple-macos14.0']
        for framework in ['Cocoa', 'MetalKit', 'MetalPerformanceShaders',
                          'Vision', 'AVFoundation', 'CoreImage', 'Speech']:
            cmd += ['-framework', framework]
        cmd += [str(p) for p in sorted((root / 'Sources').glob('*.swift'))]
        cmd += ['-o', str(contents / 'MacOS' / info['CFBundleExecutable'])]
        subprocess.run(cmd, check=True)
        entitlement_path = Path(tmp) / 'camera.entitlements'
        entitlement_path.write_bytes(plistlib.dumps({
            'com.apple.security.device.camera': True,
            'com.apple.security.device.audio-input': True,
            'com.apple.security.personal-information.speech-recognition': True,
        }))
        subprocess.run(['codesign', '--force', '--deep', '--sign', args.identity,
                        '--entitlements', str(entitlement_path), str(staging)],
                       check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staging)],
                       check=True)
        if target.exists():
            shutil.rmtree(target)
        subprocess.run(['ditto', '--norsrc', '--noextattr', str(staging),
                        str(target)], check=True)
    print(target)


if __name__ == '__main__':
    main()
