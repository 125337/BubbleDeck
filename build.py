#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BubbleDeck 构建统一入口（独立仓库版，前台阻塞）：提交推送 → CI 等待 → 制品下载 → dylib 校验

用法（在本仓库根目录执行）：
  python -u build.py all    -m "提交说明"    全流程：提交推送 + 等 CI + 下载制品
  python -u build.py commit -m "提交说明"    仅提交推送（git add -A，无变更自动跳过）
  python -u build.py wait   [sha]            仅等 CI + 下载（不传 sha 用当前 HEAD）
  python -u build.py fail   [run_id]         拉取失败 job 的 error 日志（默认最新 run）
  python -u build.py verify [追加字符串...]   校验 dist dylib 功能字符串（无参=内置清单）
  无参数打印本说明。
"""
import subprocess, sys, time, json, os, zipfile, base64
import urllib.request

REPO      = r'c:\Users\20546\Desktop\ios_cc4BX\BubbleDeck'
DIST      = os.path.join(REPO, 'dist')
DYLIB     = os.path.join(DIST, 'BubbleDeck.dylib')
API       = 'https://api.github.com/repos/125337/BubbleDeck'
WORKFLOW  = 'Build BubbleDeck'

VERIFY_U8  = ['BubbleDeck', 'TDBubbleEntry', 'TDBubbleEngine', 'TDPackLoader',
              'TDConfig', 'MMThemeManager', 'ChatRoom_Bubble_', 'bubbleImageForName',
              'imageNamed:warnIfNotFound:', 'BubbleDeckEntryVC', 'WCPluginsMgr',
              '_Dark']
VERIFY_U16 = ['气泡包', '微信默认', '使用中', '日志记录', '重新加载', '本地图标引擎']

_CREDS = None


def cred():
    global _CREDS
    if _CREDS is None:
        out = subprocess.run([find_git(), 'credential', 'fill'],
                             input='protocol=https\nhost=github.com\n\n',
                             capture_output=True, text=True, cwd=REPO).stdout
        u = p = ''
        for line in out.splitlines():
            if line.startswith('username='): u = line.split('=', 1)[1]
            if line.startswith('password='): p = line.split('=', 1)[1]
        if not p:
            sys.exit('[X] git credential 无可用凭据')
        _CREDS = (u, p)
    return _CREDS


def find_git():
    for c in ('git', r'C:\Program Files\Git\bin\git.exe',
              os.path.expandvars(r'%USERPROFILE%\.local\share\MinGit\cmd\git.exe')):
        try:
            subprocess.run([c, '--version'], capture_output=True, check=True)
            return c
        except Exception:
            continue
    sys.exit('[X] 未找到 git')


def g(*args):
    r = subprocess.run([find_git(), *args], cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'[X] git {args[0]} 失败:\n{r.stderr.strip()}')
    return r.stdout


def api(url, payload=None):
    u, p = cred()
    headers = {
        'User-Agent': 'bubbledeck-build', 'Accept': 'application/vnd.github+json',
        'Authorization': 'Basic ' + base64.b64encode(f'{u}:{p}'.encode()).decode()}
    data = json.dumps(payload).encode() if payload else None
    if data: headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, headers=headers, data=data)
    return json.load(urllib.request.urlopen(req, timeout=30))


def full_sha(ref):
    sha = g('rev-parse', ref).strip() if ref else g('rev-parse', 'HEAD').strip()
    if len(sha) != 40:
        sys.exit(f'[X] sha 非完整 40 位: {sha}')
    return sha


def cmd_commit(msg):
    if not msg:
        msg = 'bubbledeck-build: ' + time.strftime('%Y%m%d_%H%M%S')
    g('add', '-A')
    if not g('diff', '--cached', '--name-only').strip():
        print('[1/2] 无变更，跳过提交')
    else:
        g('commit', '-m', msg)
        print('[1/2] 已提交:', msg)
    for i in range(3):
        r = subprocess.run([find_git(), 'push', 'origin', 'HEAD:master'],
                           cwd=REPO, capture_output=True, text=True)
        if r.returncode == 0:
            break
        print(f'    SSH push 失败（第 {i + 1} 次），重试...')
        time.sleep(5)
    else:
        u, p = cred()
        for i in range(2):
            r = subprocess.run([find_git(), 'push',
                                f'https://{u}:{p}@github.com/125337/BubbleDeck.git', 'HEAD:master'],
                               cwd=REPO, capture_output=True, text=True)
            if r.returncode == 0:
                break
            print(f'    HTTPS push 失败（第 {i + 1} 次），重试...')
            time.sleep(5)
        else:
            sys.exit('[X] push 均失败')
    sha = g('rev-parse', 'HEAD').strip()
    print('[2/2] 已推送:', sha[:7])
    return sha


def poll_run(sha):
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            runs = api(f'{API}/actions/runs?per_page=15')['workflow_runs']
            run = next((r for r in runs
                        if r['head_sha'] == sha and r.get('name') == WORKFLOW), None)
            if run:
                print(f'[{time.strftime("%H:%M:%S")}] {run["status"]} {run.get("conclusion")}', flush=True)
                if run['status'] == 'completed':
                    return run
            else:
                print(f'[{time.strftime("%H:%M:%S")}] queued...', flush=True)
        except Exception as e:
            print(f'api err: {e}', flush=True)
        time.sleep(3)
    sys.exit('[X] 等待超时 / 未找到该 sha 的构建')


def download(run_id):
    arts = api(f'{API}/actions/runs/{run_id}/artifacts')['artifacts']
    art = next((a for a in arts if a['name'] == 'BubbleDeck.dylib'), None)
    if not art:
        sys.exit(f'[X] run {run_id} 无 BubbleDeck.dylib 制品')
    zipp = os.path.join(os.environ.get('TEMP', '.'), 'bubbledeck_artifact.zip')
    u, p = cred()
    subprocess.run(['curl.exe', '-sL', '-u', f'{u}:{p}',
                    f'{API}/actions/artifacts/{art["id"]}/zip', '-o', zipp], check=True)
    os.makedirs(DIST, exist_ok=True)
    zipfile.ZipFile(zipp).extractall(DIST)
    print(f'OK -> {DYLIB} ({os.path.getsize(DYLIB)} bytes)')


def cmd_wait(sha):
    sha = full_sha(sha)
    run = poll_run(sha)
    if run.get('conclusion') != 'success':
        sys.exit(f'[X] CI FAILED: {run["html_url"]}（可用 fail 命令拉日志）')
    download(run['id'])


def cmd_fail(run_id):
    if not run_id:
        runs = api(f'{API}/actions/runs?per_page=15')['workflow_runs']
        run = next((r for r in runs if r.get('name') == WORKFLOW), None)
        if not run:
            print('no recent BubbleDeck run')
            return
        run_id = run['id']
    print('run:', run_id)
    job = next((j for j in api(f'{API}/actions/runs/{run_id}/jobs')['jobs']
                if j['conclusion'] == 'failure'), None)
    if not job:
        print('no failed job')
        return
    print('job:', job['name'])
    for s in job['steps']:
        if s['conclusion'] == 'failure':
            print('failed step:', s['name'])
    u, p = cred()
    logf = os.path.join(os.environ.get('TEMP', '.'), 'bd_job_log.txt')
    subprocess.run(['curl.exe', '-sL', '-u', f'{u}:{p}', job['url'] + '/logs', '-o', logf], check=True)
    logs = open(logf, encoding='utf-8', errors='replace').read()
    errs = [l for l in logs.splitlines() if 'error:' in l and 'warning' not in l]
    for l in errs[:20]:
        print(l)


def cmd_verify(extra):
    data = open(DYLIB, 'rb').read()
    print(f'{DYLIB}: {len(data)} bytes')
    miss = 0
    for s in VERIFY_U8 + list(extra):
        hit = s.encode('utf-8') in data
        miss += (not hit)
        print('U8 ', 'HIT ' if hit else 'MISS', s)
    for s in VERIFY_U16:
        hit = s.encode('utf-16-le') in data
        miss += (not hit)
        print('U16', 'HIT ' if hit else 'MISS', s)
    if miss:
        sys.exit(f'[X] {miss} 个字符串缺失')


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'all':
        sha = cmd_commit(' '.join(sys.argv[sys.argv.index('-m') + 1:]) if '-m' in sys.argv else '')
        cmd_wait(sha)
    elif cmd == 'commit':
        cmd_commit(' '.join(sys.argv[sys.argv.index('-m') + 1:]) if '-m' in sys.argv else '')
    elif cmd == 'wait':
        cmd_wait(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == 'fail':
        cmd_fail(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == 'verify':
        cmd_verify(sys.argv[2:])
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
