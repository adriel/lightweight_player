#!/usr/bin/env python3
"""Runs every engine against every clip and measures the *whole* cost of playback:
the app process plus the helper processes it spawns (VTDecoderXPCService holds decoded frames,
MKVReader/CMExtensionBroker for engine B). Memory = phys_footprint (what Activity Monitor shows).

usage: Bench/run_bench.py [--seconds 40] [--only C,D] [--media name,...]
Remote clip URL is read from $LP_REMOTE_URL or Bench/.remote_url (kept out of the repo).
"""
import os
import json, os, re, subprocess, sys, threading, time, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Release/LightBench.app/Contents/MacOS/LightBench")
MEDIA = os.path.join(ROOT, "Bench/media")
HELPERS = ("VTDecoderXPCService", "MKVReader", "com.apple.CMExtensionBroker", "QLVideo Formats", "QLVideo Codecs")

def remote_url():
    u = os.environ.get("LP_REMOTE_URL")
    p = os.path.join(ROOT, "Bench/.remote_url")
    if not u and os.path.exists(p):
        u = open(p).read().strip()
    return u

CASES = [
    # (name, path-or-url, engines)
    ("1080p H.264 MP4", os.path.join(MEDIA, "h264_1080p.mp4"), "ACD"),
    ("4K HDR HEVC MP4", os.path.join(MEDIA, "hevc4k_hdr.mp4"), "ACD"),
    ("4K HDR HEVC MKV", os.path.join(MEDIA, "hevc4k_hdr.mkv"), "BCD"),
    ("4K Remux MKV (DTS-HD, PGS) 9 GB", os.environ.get("BENCH_MKV", ""), "BCD"),
    ("1080p H.264 MP4 4.5 h 15 GB", os.environ.get("BENCH_MP4", ""), "ACD"),
    ("Remote HTTPS 1080p MKV", "REMOTE", "BCD"),
    ("VP9 WebM", os.path.join(MEDIA, "vp9_1080p.webm"), "BCD"),
    ("AV1 MKV (sw on M2)", os.path.join(MEDIA, "av1_1080p.mkv"), "BCD"),
    ("H.264 + DTS MKV", os.path.join(MEDIA, "h264_dts.mkv"), "BCD"),
]

def helper_pids():
    out = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    res = {}
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        pid, comm = line.split(None, 1)
        base = os.path.basename(comm)
        if base in HELPERS:
            res[int(pid)] = base
    return res

def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB|B)", out)
    if not m: return None
    v = float(m.group(1)); unit = m.group(2)
    return v / 1024 if unit == "KB" else v * 1024 if unit == "GB" else v / 1048576 if unit == "B" else v

def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out: return None
    parts = out.replace("-", ":").split(":")
    secs = 0.0
    for p in parts: secs = secs * 60 + float(p)
    return secs

def run_case(engine, media, seconds):
    before = set(helper_pids())
    proc = subprocess.Popen([APP, "--bench", "--engine", engine, "--media", media, "--seconds", str(seconds)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stdout), daemon=True)
    reader.start()
    samples = []  # (app_mb, helpers_mb)
    helper_cpu_start = {}
    helper_names = {}
    t0 = time.time()
    app_cpu_start = None
    while proc.poll() is None:
        el = time.time() - t0
        new = {p: n for p, n in helper_pids().items() if p not in before}
        for p, n in new.items():
            helper_names[p] = n
            if p not in helper_cpu_start:
                helper_cpu_start[p] = cpu_seconds(p) or 0.0
        if el >= 6 and el <= seconds - 1:
            if app_cpu_start is None:
                app_cpu_start = (time.time(), cpu_seconds(proc.pid) or 0.0, {p: cpu_seconds(p) or 0.0 for p in new})
            a = footprint_mb(proc.pid)
            h = sum(filter(None, (footprint_mb(p) for p in new)))
            if a is not None: samples.append((a, h))
            app_cpu_end = (time.time(), cpu_seconds(proc.pid), {p: cpu_seconds(p) for p in new})
        time.sleep(2)
    reader.join(timeout=2)
    summary = {}
    for l in lines:
        if l.startswith("BENCH ") and '"summary"' in l:
            summary = json.loads(l[6:])
    res = {"engine": engine, "summary": summary, "helpers": sorted(set(helper_names.values()))}
    if samples:
        apps = [s[0] for s in samples]; hel = [s[1] for s in samples]; tot = [s[0] + s[1] for s in samples]
        res.update(appAvg=sum(apps)/len(apps), appPeak=max(apps), helperAvg=sum(hel)/len(hel), helperPeak=max(hel),
                   totalAvg=sum(tot)/len(tot), totalPeak=max(tot))
    if app_cpu_start and 'app_cpu_end' in locals() and app_cpu_end[1] is not None:
        wall = app_cpu_end[0] - app_cpu_start[0]
        if wall > 0:
            res["appCpu"] = (app_cpu_end[1] - app_cpu_start[1]) / wall * 100
            hc = 0.0
            for p, v in app_cpu_end[2].items():
                if v is not None and p in app_cpu_start[2]: hc += v - app_cpu_start[2][p]
            res["helperCpu"] = hc / wall * 100
    return res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=40)
    ap.add_argument("--only", default="ABCD")
    ap.add_argument("--media", default="")
    a = ap.parse_args()
    results = []
    for name, path, engines in CASES:
        if a.media and not any(k.lower() in name.lower() for k in a.media.split(",")): continue
        if path == "REMOTE":
            path = remote_url()
            if not path: print("skip remote (no URL)"); continue
        elif not os.path.exists(path):
            print(f"skip {name} (missing)"); continue
        for e in engines:
            if e not in a.only.replace(",", ""): continue
            print(f"== {name} / {e}", flush=True)
            r = run_case(e, path, a.seconds)
            r["case"] = name
            s = r.get("summary", {})
            print(f"   total {r.get('totalAvg', 0):.0f} MB (app {r.get('appAvg', 0):.0f} + helpers {r.get('helperAvg', 0):.0f}), "
                  f"peak {r.get('totalPeak', 0):.0f} MB, cpu app {r.get('appCpu', 0):.1f}% + helpers {r.get('helperCpu', 0):.1f}%, "
                  f"first frame {s.get('firstFrameSec')}s, pos {s.get('finalPos')}/{s.get('duration')} "
                  f"{'FAIL ' + s['failure'][:120] if s.get('failure') else ''} {s.get('warnings') or ''} {s.get('diag', {})}", flush=True)
            results.append(r)
    out = os.path.join(ROOT, "Bench/results/results.json")
    with open(out, "w") as f: json.dump(results, f, indent=1)
    print("wrote", out)

if __name__ == "__main__":
    main()
