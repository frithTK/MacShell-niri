#!/usr/bin/env python3
"""Publish one shared Linux boot-clock sample for MacLock surfaces."""

import argparse
import json
from pathlib import Path
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    boot_id = Path('/proc/sys/kernel/random/boot_id').read_text(encoding='ascii').strip()
    if str(uuid.UUID(boot_id)) != boot_id:
        raise ValueError('Invalid boot ID')
    try:
        while True:
            now_ms = time.clock_gettime_ns(time.CLOCK_BOOTTIME) // 1_000_000
            print(json.dumps({'bootId': boot_id, 'bootMs': now_ms}), flush=True)
            if args.once:
                return
            time.sleep(.25)
    except BrokenPipeError:
        pass


if __name__ == '__main__':
    main()
