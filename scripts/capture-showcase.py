#!/usr/bin/env python3
"""Capture production QML in a private nested niri with fixture data and strong glass.

No installed settings or physical device services are used. Only the owned nested
window is resized on the host. Requires niri, Quickshell, grim and ffmpeg.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

project = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(project))
from scripts.install_niri import quickshell

ASSETS = project / 'docs/showcase'
WIDTH, HEIGHT = 1440, 900


def run(command, environment=None, timeout=10):
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(command[0] + ': ' + result.stderr.strip())
    return result.stdout


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait(timeout=5)


def replace(path, old, new):
    source = path.read_text()
    if old not in source:
        raise RuntimeError('Showcase injection no longer matches ' + path.name + ': ' + old[:60])
    path.write_text(source.replace(old, new, 1))


def player(path):
    source = path.read_text()
    start = source.index('    readonly property var player: {')
    end = source.index('\n    }', start) + len('\n    }')
    fixture = '''    QtObject {
        id: showcasePlayer
        property string trackTitle: "Night Walk"
        property string trackArtist: "Demo Artist"
        property string trackAlbum: "Evening Sessions"
        property string trackArtUrl: Quickshell.env("MACSHELL_SHOWCASE_ART")
        property bool isPlaying: true
        property bool shuffleSupported: true
        property bool shuffle: false
        property bool loopSupported: true
        property int loopState: 0
        property bool positionSupported: true
        property bool lengthSupported: true
        property bool canSeek: true
        property bool canTogglePlaying: true
        property bool canGoNext: true
        property bool canGoPrevious: true
        property real position: 74
        property real length: 216
        function togglePlaying() { isPlaying = !isPlaying; }
        function next() {}
        function previous() {}
    }
    readonly property var player: showcasePlayer'''
    path.write_text(source[:start] + fixture + source[end:])


def prepare(root):
    shell = root / 'shell'
    shutil.copytree(project / 'MacShell', shell, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for name in ('home', 'config', 'cache', 'data/applications', 'niri', 'settings/macbar', 'settings/macdock', 'settings/macwidgets'):
        (root / name).mkdir(parents=True)
    for kind in ('network_control', 'bluetooth_service', 'power_control', 'system_stats', 'widget_fetch'):
        shutil.copyfile(ASSETS / 'service.py', shell / (kind + '.py'))
    (shell / 'niri_capture.py').write_text('import sys\nfor line in sys.stdin:\n    pass\n')
    replace(shell / 'shell.qml', 'ShellRoot {', 'ShellRoot {\n' + (ASSETS / 'scene.qml').read_text())
    replace(shell / 'MacBar.qml', '    id: root\n', '    id: root\n    property var demoUi: null\n    property var demoSpot: null\n')
    replace(shell / 'MacBar.qml', '                id: ui\n', '                id: ui\n                Component.onCompleted: root.demoUi = ui\n')
    replace(shell / 'MacBar.qml', '                    id: spot\n', '                    id: spot\n                    Component.onCompleted: root.demoSpot = spot\n')
    replace(shell / 'MacBar.qml', '                function spSetMode(m) {', '                function spInputText(value) { spInput.text = value; }\n                function spSetMode(m) {')
    replace(shell / 'MacBar.qml', '    SystemClock { id: clock; precision: root.showSeconds ? SystemClock.Seconds : SystemClock.Minutes }',
            '    QtObject { id: clock; property date date: new Date(2026, 9, 25, 9, 41) }')
    replace(shell / 'MacBar.qml', 'readonly property real volume: (sink && sink.audio) ? sink.audio.volume : 0', 'readonly property real volume: .62')
    replace(shell / 'MacBar.qml', 'text: "Sound · " + Math.round(root.volume * 100) + "%" + (root.sink ? " · " + (root.sink.description || root.sink.name) : "")', 'text: "Sound · 62% · Speakers"')
    replace(shell / 'MacDock.qml', '    id: root\n', '    id: root\n    function demoSettings() { return prefsWindow; }\n')
    replace(shell / 'MacDock.qml', 'source: "file://" + Quickshell.env("HOME") + "/.face"', 'source: ""')
    replace(shell / 'MacDock.qml', 'property string userName: Quickshell.env("USER") || ""', 'property string userName: "Demo"')
    replace(shell / 'MacDock.qml', 'if (text.trim() !== "") root.userName = text.trim()', 'root.userName = "Demo"')
    replace(shell / 'ClockApp.qml', '    id: root\n', '    id: root\n    function demoWindow() { return win; }\n')
    for name in ('MacBar.qml', 'MacWidgets.qml'):
        player(shell / name)
    # PipeWire uses its own socket rather than D-Bus. Keep it private as well,
    # and feed the existing audio controls small, mutable demonstration nodes.
    audio = '''    QtObject {
        id: demoOutput
        property int id: 1
        property string name: "demo-speakers"
        property string description: "Desktop Speakers"
        property bool isSink: true
        property var audio: QtObject { property real volume: .62; property bool muted: false }
    }
    QtObject {
        id: demoHeadphones
        property int id: 2
        property string name: "demo-headphones"
        property string description: "Studio Headphones"
        property bool isSink: true
        property var audio: QtObject { property real volume: .48; property bool muted: false }
    }
    QtObject {
        id: demoMicrophone
        property int id: 3
        property string name: "demo-mic"
        property string description: "USB Microphone"
        property bool isSink: false
        property var audio: QtObject { property real volume: .7; property bool muted: false }
    }
    readonly property var sink: demoOutput'''
    replace(shell / 'MacBar.qml', '    readonly property var sink: Pipewire.defaultAudioSink', audio)
    replace(shell / 'MacBar.qml', '    PwObjectTracker { objects: [root.sink] }', '')
    replace(shell / 'MacBar.qml', 'readonly property var micSource: Pipewire.defaultAudioSource', 'readonly property var micSource: demoMicrophone')
    replace(shell / 'MacBar.qml', '    PwObjectTracker { objects: [root.micSource] }', '')
    replace(shell / 'MacBar.qml', 'readonly property var audioOutputs: audioDevices(true)', 'readonly property var audioOutputs: [demoOutput, demoHeadphones]')
    replace(shell / 'MacBar.qml', 'readonly property var audioInputs: audioDevices(false)', 'readonly property var audioInputs: [demoMicrophone]')
    replace(shell / 'MacBar.qml', 'readonly property var appAudioStreams: audioApps()', 'readonly property var appAudioStreams: [{key: "music", name: "Music", nodes: [demoOutput], volume: .78, muted: false}]')
    replace(shell / 'MacBar.qml', '    function chooseAudio(n) {', '    function chooseAudio(n) { return;')
    (shell / 'BatteryControl.qml').write_text('''import QtQuick
QtObject {
    readonly property bool present: true
    readonly property real percentage: 86
    readonly property bool charging: false
    readonly property bool full: false
    readonly property bool onBattery: true
    readonly property string remaining: "About 6 hr 24 min remaining"
    readonly property string source: "Power Source: Battery"
}
''')
    (shell / 'BrightnessControl.qml').write_text('''import QtQuick
QtObject {
    property bool active: true
    property real value: .72
    property bool available: true
    function refresh() {}
}
''')
    # Keep screen recording/capture and all hardware writes out of this presentation.
    replace(shell / 'MacBar.qml', 'onTriggered: Quickshell.execDetached(["brightnessctl", "-q", "set", Math.max(1, Math.round(root.brightness * 100)) + "%"])', 'onTriggered: {}')
    # Shared time remains live, with a fixed demonstration date and minute.
    path = shell / 'WidgetClock.qml'
    source = path.read_text().replace('    id: root\n', '    id: root\n    property double demoStart: Date.now()\n', 1)
    path.write_text(source.replace('new Date()', 'new Date(2026, 9, 25, 9, 41, 20 + Math.floor((Date.now() - demoStart) / 1000) % 40, Date.now() % 1000)'))
    wallpaper = str(ASSETS / 'wallpaper-dark.svg')
    glass = dict(darkMode=True, glassOpacity=.24, glassBlur=4, glassLiquid=2.4, glassRim=.9, glassGrain=.02, wallpaperPath=wallpaper, fontFamily='Inter Variable')
    (root / 'settings/macbar/settings.json').write_text(json.dumps(dict(glass, barStyle='liquid', barGlass=True, barBgOpacity=.12,
        barHeight=30, barLogoMode='apple', autoContrast=False, uiSounds=False, gamingAuto=False, clipHistory=False, showBatteryPercent=True,
        showTray=False, statsInterval=5, ccMirroringMigrated=True, ccAirDropMigrated=True, ccMigRec=True, ccMigGame=True,
        ccControls=['wifi', 'nowplaying', 'bluetooth', 'focus', 'mirroring', 'airdrop', 'nightshift', 'keepawake', 'display', 'sound'])))
    (root / 'settings/macdock/settings.json').write_text(json.dumps(dict(glass, dockEnabled=True, dockStyle='liquid', hideMode='never',
        iconSize=52, magnification=1.5, margin=12, showThumbs=False, showTrash=False, windowCapture=False)))
    icons = [
        ('Firefox', '/usr/share/icons/hicolor/256x256/apps/firefox.png'),
        ('Files', '/usr/share/icons/hicolor/scalable/apps/org.gnome.Nautilus.svg'),
        ('Terminal', '/usr/share/icons/hicolor/256x256/apps/kitty.png'),
        ('Music', str(project / 'MacShell/assets/music-app.svg')),
        ('Settings', '/usr/share/icons/breeze-dark/apps/48/systemsettings.svg'),
    ]
    pinned = []
    for index, (name, icon) in enumerate(icons):
        ident = 'org.quickshell' if name == 'Settings' else 'org.macshell.Demo' + name
        if not Path(icon).exists():
            raise RuntimeError('Missing demonstration icon: ' + icon)
        (root / 'data/applications' / (ident + '.desktop')).write_text('[Desktop Entry]\nType=Application\nName=' + name + '\nExec=true\nIcon=' + icon + '\nCategories=Utility;\n')
        pinned.append(ident)
    alias = (root / 'data/applications/org.quickshell.desktop').read_text() + 'NoDisplay=true\n'
    (root / 'data/applications/dev.noctalia.noctalia-qs.desktop').write_text(alias)
    (root / 'settings/macdock/pinned.json').write_text(json.dumps(pinned))
    values = dict(defaults=dict(tempUnit='C', locMode='city', cityName='Helsinki', mode='auto', styles={kind:'liquid' for kind in ('weather','calendar','clock','player')}),
        desktopOutput='studio', outputs=dict(studio=dict(identity=dict(connector='winit', make='Smithay', model='Winit', serial=''))), bindings=dict(winit='studio'),
        widgets=[dict(id=kind, type=kind, version=1, output='studio', position=dict(column=column,row=row), settings=dict(size=size, style='liquid'))
                 for kind, size, column, row in [('weather','medium',0,0),('clock','small',0,1),('calendar','small',1,1),('player','medium',0,2)]])
    (root / 'settings/macwidgets/settings.json').write_text(json.dumps(dict(version=1, revision=1, values=values)))
    (root / 'niri/config.kdl').write_text('''input { keyboard { xkb { layout "us"; }; }; }
layout { background-color "transparent"; border { off; }; focus-ring { off; }; }
hotkey-overlay { skip-at-startup; }
window-rule {
    match app-id=r#"^(org\\.quickshell|dev\\.noctalia\\.noctalia-qs)$"#
    open-floating true
}
layer-rule { match namespace="^macshell-wallpaper$"; place-within-backdrop true; }
layer-rule { match namespace="^mac(bar|barbg|dock|spot|switch|wall|osd)$"; background-effect { xray false; }; }
blur { passes 3; offset 1.2; }
binds { Alt+Q { quit skip-confirmation=true; }; }
''')
    (root / 'child.py').write_text("import json,os\nfrom pathlib import Path\nPath(" + repr(str(root / 'nested.json')) + ").write_text(json.dumps({key:os.environ.get(key) for key in ('WAYLAND_DISPLAY','NIRI_SOCKET')}))\n")
    return shell


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=project / 'docs/images')
    scenes = ['desktop', 'cc', 'spotlight', 'apps', 'stats', 'wifi', 'bt', 'vol', 'battery', 'widgets', 'appearance', 'barlayout', 'activity', 'clock', 'arrange']
    parser.add_argument('--scenes', nargs='+', choices=scenes, default=[name for name in scenes if name not in ('activity', 'arrange')])
    parser.add_argument('--themes', nargs='+', choices=('dark','light'), default=['dark','light'])
    parser.add_argument('--gif', action='store_true')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='macshell-showcase-') as temporary:
        root = Path(temporary)
        shell = prepare(root)
        environment = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
            XDG_DATA_HOME=str(root / 'data'), XDG_DATA_DIRS=str(root / 'data'), MACSHELL_SETTINGS_HOME=str(root / 'settings'),
            MACSHELL_NIRI_PROFILE=str(root / 'niri'), QT_QPA_PLATFORMTHEME='', QT_QUICK_CONTROLS_STYLE='Basic', QT_QPA_PLATFORM='wayland',
            DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(root / 'no-bus'),
            PIPEWIRE_REMOTE='macshell-showcase-no-pipewire', PULSE_SERVER='unix:' + str(root / 'no-pulse'),
            MACSHELL_SHOWCASE_DARK_WALL=str(ASSETS / 'wallpaper-dark.svg'), MACSHELL_SHOWCASE_LIGHT_WALL=str(ASSETS / 'wallpaper.svg'),
            MACSHELL_SHOWCASE_ART=(ASSETS / 'album.svg').as_uri())
        nested = client = recorder = None
        log_path = Path('/tmp/macshell-showcase.log')
        with log_path.open('w') as log:
            try:
                nested = subprocess.Popen(['niri','--config',str(root / 'niri/config.kdl'),'--',sys.executable,str(root / 'child.py')], env=environment, stdout=log, stderr=log)
                deadline = time.monotonic() + 10
                while not (root / 'nested.json').exists():
                    if nested.poll() is not None or time.monotonic() > deadline: raise RuntimeError('Nested niri did not start: ' + str(log_path))
                    time.sleep(.1)
                # Match only the compositor window created by this process.
                host_windows = json.loads(run(['niri','msg','--json','windows']))
                own = next((window for window in host_windows if window.get('pid') == nested.pid), None)
                if not own: raise RuntimeError('Cannot identify the owned nested compositor window')
                ident = str(own['id'])
                if not own['is_floating']: run(['niri','msg','action','toggle-window-floating','--id',ident])
                run(['niri','msg','action','set-window-width','--id',ident,str(WIDTH)])
                run(['niri','msg','action','set-window-height','--id',ident,str(HEIGHT)])
                run(['niri','msg','action','move-floating-window','--id',ident,'-x','100','-y','80'])
                environment.update(json.loads((root / 'nested.json').read_text()))
                time.sleep(.6)
                output = json.loads(run(['niri','msg','--json','outputs'],environment))['winit']
                if (output['logical']['width'],output['logical']['height']) != (WIDTH,HEIGHT): raise RuntimeError('Nested output size mismatch: ' + repr(output['logical']))
                client = subprocess.Popen([quickshell(),'-p',str(shell)],env=environment,stdout=log,stderr=log)
                def ipc(method,*values):
                    return run([quickshell(),'-p',str(shell),'ipc','call','showcase',method,*map(str,values)],environment)
                deadline = time.monotonic() + 25
                state = {}
                while time.monotonic() < deadline:
                    try:
                        state = json.loads(ipc('state'))
                        if state['ready']: break
                    except (subprocess.SubprocessError, ValueError, RuntimeError): pass
                    if client.poll() is not None: raise RuntimeError('Showcase shell exited: ' + str(log_path))
                    time.sleep(.25)
                else: raise RuntimeError('Showcase was not ready: ' + repr(state))
                time.sleep(1)
                for theme in args.themes:
                    ipc('theme',str(theme == 'dark').lower()); time.sleep(.8)
                    for scene in args.scenes:
                        ipc('scene',scene); time.sleep(1.1)
                        target = args.output_dir.resolve() / ('showcase-' + scene + '-' + theme + '.png')
                        run(['grim','-o','winit',str(target)],environment)
                        if scene in ('widgets', 'appearance', 'barlayout', 'activity', 'clock'):
                            windows = json.loads(run(['niri','msg','--json','windows'],environment))
                            title = 'Clock' if scene == 'clock' else 'macshell Settings'
                            window = next(window for window in windows if window['title'] == title and window.get('pid') == client.pid)
                            detail = args.output_dir.resolve() / ('showcase-detail-' + scene + '-' + theme + '.png')
                            run(['niri','msg','action','screenshot-window','--id',str(window['id']),'--path',str(detail)],environment)
                        elif scene != 'desktop':
                            region = json.loads(ipc('state'))['region']
                            x, y = max(0, int(region['x'])), max(0, int(region['y']))
                            width, height = min(WIDTH - x, int(region['width'])), min(HEIGHT - y, int(region['height']))
                            if width < 10 or height < 10: raise RuntimeError('Missing owned popup geometry: ' + scene)
                            detail = args.output_dir.resolve() / ('showcase-detail-' + scene + '-' + theme + '.png')
                            run(['grim','-g',f'{x},{y} {width}x{height}',str(detail)],environment)
                        print(target.name,flush=True)
                if args.gif:
                    ipc('theme','true'); ipc('scene','desktop'); time.sleep(.8)
                    video = root / 'demo.mkv'
                    recorder = subprocess.Popen(['wf-recorder','-o','winit','-r','30','-f',str(video),'-c','libx264','-p','preset=ultrafast','--no-damage','--no-cursor'],env=environment,stdout=log,stderr=log)
                    for scene, pause in [('desktop',1.2),('cc',2.2),('desktop',.6),('spotlight',2),('apps',2.2),('desktop',.6),('stats',2.2),('desktop',1)]:
                        ipc('scene',scene); time.sleep(pause)
                    recorder.send_signal(signal.SIGINT); recorder.wait(timeout=10); recorder = None
                    hd = args.output_dir.resolve() / 'showcase-demo.mp4'
                    run(['ffmpeg','-v','error','-i',str(video),'-vf','format=yuv420p','-c:v','libx264','-preset','medium','-crf','18','-movflags','+faststart','-an','-y',str(hd)],timeout=90)
                    target = args.output_dir.resolve() / 'showcase-demo.gif'
                    run(['ffmpeg','-v','error','-i',str(video),'-filter_complex','fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:reserve_transparent=0:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle','-loop','0','-y',str(target)],timeout=90)
                    print(target.name + ' ' + str(target.stat().st_size) + ' bytes',flush=True)
                ipc('shutDown'); client.wait(timeout=5)
                log.flush()
                errors = log_path.read_text()
                if re.search(r'TypeError|ReferenceError|Binding loop|Unable to assign|Failed to load configuration',errors): raise RuntimeError('QML errors in ' + str(log_path))
                print('MACSHELL_SHOWCASE_PASS: production QML, native glass, fixture data, isolated nested compositor',flush=True)
            finally:
                stop(recorder); stop(client); stop(nested)


if __name__ == '__main__':
    main()
