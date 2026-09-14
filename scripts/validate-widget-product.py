#!/usr/bin/env python3
"""Reject incomplete widget products before an installer changes the live app."""
import json
import plistlib
import sys
from pathlib import Path


def validate(app):
    bundles = (app, app / 'Contents/PlugIns/HerdrWidgets.appex')
    versions = []
    for bundle in bundles:
        with (bundle / 'Contents/Info.plist').open('rb') as source:
            version = plistlib.load(source).get('CFBundleVersion')
        if not isinstance(version, str) or not version or '$(' in version:
            raise ValueError(f'Missing or unresolved CFBundleVersion in {bundle}')
        versions.append(version)
        metadata = bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
        with metadata.open() as source:
            actions = json.load(source).get('actions', {})
        action = actions.get('AgentWidgetConfiguration')
        if not isinstance(action, dict) or action.get('identifier') != 'AgentWidgetConfiguration':
            raise ValueError(f'Missing AgentWidgetConfiguration metadata in {bundle}')
    if versions[0] != versions[1]:
        raise ValueError(f'Host/widget CFBundleVersion mismatch: {versions[0]} != {versions[1]}')


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
        print(f'Error: invalid widget product: {error}', file=sys.stderr)
        sys.exit(1)
