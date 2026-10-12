#!/usr/bin/env python3
"""Herdr Menubar's aggregate status feed, schema v1. Python standard library only."""
import json
import math
import os
from pathlib import Path
import subprocess
import time

STATUS_FILE = Path.home() / 'Library/Application Support/Herdr Menubar/sketchybar-status.json'


def properties(state, now):
    color, label = '0xff6c7086', ''
    if isinstance(state, dict):
        timestamp = state.get('writtenAt')
        count = state.get('attentionCount')
        mode = state.get('mode')
        valid = (
            type(state.get('schemaVersion')) is int and state['schemaVersion'] == 1
            and state.get('isRunning') is True
            and type(timestamp) in (float, int) and 0 <= timestamp <= 1e12 and math.isfinite(timestamp)
            and -5 <= now - timestamp <= 90
            and type(count) is int and 0 <= count <= 1_000_000
            and mode in ('attention', 'clear', 'disconnected')
        )
        if valid and mode != 'disconnected':
            color = '0xfff9e2af' if mode == 'attention' else '0xff94e2d5'
            if mode == 'attention' and count:
                label = str(count)
    return [f'label={label}', f'label.drawing={"on" if label else "off"}',
            f'icon.padding_right={5 if label else 8}',
            f'icon.color={color}', f'label.color={color}']


def main():
    try:
        # Treat any partial, malformed or unreasonably large file as offline.
        with STATUS_FILE.open() as stream:
            state = json.loads(stream.read(16_384))
    except (OSError, ValueError, RecursionError):
        state = None
    subprocess.run(['sketchybar', '--set', os.environ.get('NAME', 'herdr'),
                    *properties(state, time.time())], check=False, timeout=5)


if __name__ == '__main__':
    main()
