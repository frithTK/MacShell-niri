#!/usr/bin/env python3
"""Measure the installed shell process tree; optionally open Activity temporarily."""
import argparse
import atexit
import json
import math
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=30)
parser.add_argument('--warmup', type=float, default=5)
parser.add_argument('--phase', choices=('current','idle','activity'), default='current')
parser.add_argument('--output', required=True)
args = parser.parse_args()
if not math.isfinite(args.seconds) or args.seconds <= 0 or not math.isfinite(args.warmup) or args.warmup < 0:
    parser.error('seconds must be positive and warmup non-negative')
launcher = str(Path.home()/'.local/bin/macshell-niri')

def ipc(target, method, *values):
    text = subprocess.check_output([launcher, 'ipc', 'call', target, method, *values], text=True, timeout=8)
    return json.loads(text) if method=='state' else None

instances = json.loads(subprocess.check_output([launcher, 'list', '-j'], text=True))
assert len(instances)==1
pid = instances[0]['pid']
if args.phase=='activity':
    ipc('monitoring','open')
    atexit.register(lambda: subprocess.run([launcher, 'ipc', 'call', 'monitoring', 'close'], capture_output=True, timeout=8))
elif args.phase=='idle':
    ipc('controlcenter','close')
time.sleep(args.warmup)
status = ipc('status','state')
condition_before = ipc('monitoring','state')
expected_open = True if args.phase=='activity' else False if args.phase=='idle' else None
if expected_open is not None and condition_before['open'] != expected_open:
    raise SystemExit('The requested menu state changed during warmup; measurement was not started.')
hz = os.sysconf('SC_CLK_TCK')
page = os.sysconf('SC_PAGE_SIZE')


def table():
    data={}
    for p in Path('/proc').iterdir():
        if not p.name.isdigit(): continue
        try:
            f=(p/'stat').read_text().rsplit(') ',1)[1].split()
            data[int(p.name)]={'ppid':int(f[1]),'ticks':sum(int(f[n]) for n in (11,12,13,14)),
                              'own':int(f[11])+int(f[12]),'start':int(f[19]),'rss':int(f[21])*page}
        except (OSError,ValueError,IndexError): pass
    assert pid in data, 'Shell restarted during measurement'
    live={pid}
    while True:
        more={p for p,d in data.items() if d['ppid'] in live}
        if more<=live: break
        live|=more
    return {p:data[p] for p in live}

def memory(p):
    try:
        values={line.split(':')[0]:int(line.split()[1])*1024 for line in Path(f'/proc/{p}/smaps_rollup').read_text().splitlines() if line.startswith(('Pss:', 'Private_Clean:', 'Private_Dirty:'))}
        return values.get('Pss'),values.get('Private_Clean',0)+values.get('Private_Dirty',0)
    except (OSError,ValueError): return None,None

def gpu(p):
    result={}
    try: files=list(Path(f'/proc/{p}/fd').iterdir())
    except OSError: return result
    for f in files:
        try:
            if not os.readlink(f).startswith('/dev/dri/'): continue
            values=dict(line.split(':',1) for line in Path(f'/proc/{p}/fdinfo/{f.name}').read_text().splitlines() if ':' in line)
            values={k:v.strip() for k,v in values.items()}
            client=values.get('drm-client-id')
            if not client: continue
            key=values.get('drm-pdev','')+'/'+client
            engines={k.removeprefix('drm-engine-'):int(v.split()[0]) for k,v in values.items() if k.startswith('drm-engine-') and not k.startswith('drm-engine-capacity-')}
            capacities={k.removeprefix('drm-engine-capacity-'):int(v.split()[0]) for k,v in values.items() if k.startswith('drm-engine-capacity-')}
            result[key]={'engine':engines,'capacity':capacities}
        except (OSError,ValueError): pass
    return result

def label(p):
    try:
        cmd=Path(f'/proc/{p}/cmdline').read_bytes().split(b'\0')
        for token in cmd:
            if token.endswith(b'.py'): return 'python3 / '+Path(token.decode()).name
        return Path(cmd[0].decode()).name
    except (OSError,IndexError): return 'exited'

def snapshot():
    rows=table(); clients={}
    for p,d in rows.items():
        d['pss'],d['private']=memory(p)
        for key,info in gpu(p).items():
            old=clients.get(key)
            if old:
                for eng,v in info['engine'].items(): old['engine'][eng]=max(v,old['engine'].get(eng,0))
            else: clients[key]=info
    return time.monotonic(),rows,clients

start,first,gfirst=snapshot(); names={p:label(p) for p in first}
peaks={'rss':sum(d['rss'] for d in first.values()),'pss':sum(d['pss'] or 0 for d in first.values()),'processes':len(first)}
while time.monotonic()-start < args.seconds:
    time.sleep(min(1,max(.01,args.seconds-(time.monotonic()-start))))
    end,last,glast=snapshot()
    for p in last:
        if p not in names: names[p]=label(p)
    peaks['rss']=max(peaks['rss'],sum(d['rss'] for d in last.values()))
    peaks['pss']=max(peaks['pss'],sum(d['pss'] or 0 for d in last.values()))
    peaks['processes']=max(peaks['processes'],len(last))
assert first[pid]['start']==last[pid]['start']
elapsed=end-start
cpu=(sum(d['ticks'] for d in last.values())-sum(d['ticks'] for d in first.values()))/hz/elapsed*100
per=[]
for p,d in last.items():
    initial=first.get(p)
    own=(d['own']-initial['own'])/hz/elapsed*100 if initial and initial['start']==d['start'] else None
    per.append(dict(name=names[p],cpu_one_core=None if own is None else round(own,3),rss_mib=round(d['rss']/1048576,2),pss_mib=None if d['pss'] is None else round(d['pss']/1048576,2)))
engines={}
for client,v in glast.items():
    if client not in gfirst: continue
    for eng,ns in v['engine'].items():
        delta=max(0,ns-gfirst[client]['engine'].get(eng,ns))
        key=client.split('/')[0]+'/'+eng
        engines[key]=engines.get(key,0)+delta/(elapsed*1e9)*100/max(1,v['capacity'].get(eng,1))
result=dict(phase=args.phase,seconds=round(elapsed,2),cpu_one_core=round(cpu,3),cpu_machine=round(cpu/(os.cpu_count() or 1),3),logical_cpus=os.cpu_count(),
            peak_rss_mib=round(peaks['rss']/1048576,2),peak_pss_mib=round(peaks['pss']/1048576,2),peak_processes=peaks['processes'],pss_complete=all(d['pss'] is not None for d in last.values()),
            processes=sorted(per,key=lambda v:-(v['cpu_one_core'] or 0)),gpu_engine_percent={k:round(v,3) for k,v in engines.items()},status=status)
result['monitoring_open_start'] = condition_before['open']
result['monitoring_open_end'] = ipc('monitoring','state')['open']
result['scenario_valid'] = expected_open is None or result['monitoring_open_end'] == expected_open
Path(args.output).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False))
if args.phase=='activity': ipc('monitoring','close')
if not result['scenario_valid']:
    raise SystemExit('The menu state changed during measurement; do not use this result for the requested scenario.')
