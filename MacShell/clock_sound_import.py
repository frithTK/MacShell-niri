#!/usr/bin/env python3
"""Import one chosen local audio file in a separate bounded worker."""
import argparse
import json
from pathlib import Path
import signal
import sys

from clock_sound_library import SoundLibrary, SoundLibraryError


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('source', type=Path)
    args = parser.parse_args()
    # Unwind the staging directory and terminate a decoder if the owner exits.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(1))
    try:
        entry, created = SoundLibrary(args.library, protect_decoders=True).import_file(args.source)
        print(json.dumps({'success': True, 'sound': entry, 'created': created}, ensure_ascii=False), flush=True)
        return 0
    except SoundLibraryError as error:
        print(json.dumps({'success': False, 'error': str(error)}, ensure_ascii=False), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
