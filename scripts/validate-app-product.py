#!/usr/bin/env python3
"""Reject incomplete app products before an installer changes the live app."""
import plistlib
import sys
from pathlib import Path


def validate(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    version = info.get('CFBundleVersion')
    if not isinstance(version, str) or not version or '$(' in version:
        raise ValueError(f'Missing or unresolved CFBundleVersion in {app}')
    if info.get('CFBundleIdentifier') != 'dev.herdr.menubar':
        raise ValueError(f'Unexpected CFBundleIdentifier in {app}')
    if info.get('CFBundleExecutable') != 'HerdrMenubar' or not (app / 'Contents/MacOS/HerdrMenubar').is_file():
        raise ValueError(f'Missing app executable in {app}')
    if any((app / 'Contents/PlugIns').glob('*.appex')):
        raise ValueError(f'Unexpected embedded extension in {app}')


def registration_candidates(repo, product):
    # Only this checkout's build tree is inspected; never enumerate the global
    # LaunchServices catalog. Resolve containment to exclude linked external apps.
    yield product
    build = repo / '.build'
    for bundle in sorted(build.rglob('HerdrMenubar.app')):
        if bundle == product or not bundle.resolve().is_relative_to(build.resolve()):
            continue
        try:
            with (bundle / 'Contents/Info.plist').open('rb') as source:
                identifier = plistlib.load(source).get('CFBundleIdentifier')
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if identifier == 'dev.herdr.menubar':
            yield bundle


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--registration-candidates':
            for candidate in registration_candidates(Path(sys.argv[2]), Path(sys.argv[3])):
                sys.stdout.buffer.write(bytes(candidate) + b'\0')
        else:
            validate(Path(sys.argv[1]))
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
        print(f'Error: invalid app product: {error}', file=sys.stderr)
        sys.exit(1)
