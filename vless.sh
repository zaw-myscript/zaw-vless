#!/bin/bash
# ZAW-VLESS Auto Installer + AUTO-CLEAN EXPIRED + DATA QUOTA WEB DASHBOARD

B="\e[1;34m"; G="\e[1;32m"; Y="\e[1;33m"; R="\e[1;31m"; C="\e[1;36m"; Z="\e[0m"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${R}ဤ script ကို root အဖြစ် run ရပါမယ် (sudo -i)${Z}"; exit 1
fi

echo -e "${Y}📦 လိုအပ်သော Packages များ တင်သွင်းနေပါသည်...${Z}"
apt-get update -y >/dev/null 2>&1
apt-get install -y curl ufw jq uuid-runtime python3 >/dev/null 2>&1

echo -e "${Y}⬇️ Xray-core (VLESS Engine) ကို ဒေါင်းလုဒ်ဆွဲနေပါသည်...${Z}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root >/dev/null 2>&1

mkdir -p /usr/local/etc/xray
CFG="/usr/local/etc/xray/config.json"
DB="/usr/local/etc/xray/users.txt"
touch $DB

# Data Quota အတွက် Xray API, Stats နှင့် Policy များကိုပါ ထည့်သွင်းထားသော Config အသစ်
cat > $CFG <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log"
  },
  "stats": {},
  "api": {
    "services": ["StatsService"],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": { "statsUserUplink": true, "statsUserDownlink": true }
    }
  },
  "inbounds": [
    {
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/zawvless"
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
EOF

# === 🔴 AUTO-CLEAN (ည ၁၂ နာရီတိုင်း အလိုလို အကောင့်ဖျက်မည့် စနစ်) 🔴 ===
echo -e "${Y}🧹 Auto-Delete (သက်တမ်းလွန် VLESS အကောင့်ဖျက်စနစ်) ထည့်သွင်းနေပါသည်...${Z}"
cat > /usr/local/bin/vless_cleaner << 'EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"
DB="/usr/local/etc/xray/users.txt"

if [ ! -s "$DB" ]; then exit 0; fi

today_date=$(date +"%Y-%m-%d")
today_sec=$(date -d "$today_date" +%s)
changed=0

TMP_DB="/tmp/vless_users_cron.tmp"
EXP_DB="/tmp/vless_exp_cron.tmp"
> "$TMP_DB"; > "$EXP_DB"

while read -r user uuid exp limit gb; do
    exp_sec=$(date -d "$exp" +%s 2>/dev/null)
    if [[ -n "$exp_sec" && $exp_sec -lt $today_sec ]]; then
        echo "$user" >> "$EXP_DB"
        changed=1
    else
        echo "$user $uuid $exp $limit ${gb:-Unlimited}" >> "$TMP_DB"
    fi
done < "$DB"

if [ "$changed" -eq 1 ]; then
    cat "$TMP_DB" > "$DB"
    while read -r ex_user; do
        if jq --arg em "$ex_user" 'del(.inbounds[0].settings.clients[] | select(.email == $em))' "$CFG" > "$CFG.tmp" 2>/dev/null; then
            if [ -s "$CFG.tmp" ]; then mv "$CFG.tmp" "$CFG"; fi
        fi
    done < "$EXP_DB"
    systemctl restart xray
fi
rm -f "$TMP_DB" "$EXP_DB" "$CFG.tmp" 2>/dev/null
EOF

chmod +x /usr/local/bin/vless_cleaner
crontab -l 2>/dev/null | grep -v "vless_cleaner" | crontab - || true
(crontab -l 2>/dev/null; echo "1 0 * * * /usr/local/bin/vless_cleaner >/dev/null 2>&1") | crontab -

# === 📊 DATA QUOTA & WEB DASHBOARD SYSTEM (PYTHON) 📊 ===
echo -e "${Y}🌐 Data Tracking & Website Dashboard တပ်ဆင်နေပါသည်...${Z}"
cat > /usr/local/bin/vweb_quota.py << 'EOF'
import os, json, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

DB_FILE = "/usr/local/etc/xray/users.txt"
USAGE_FILE = "/usr/local/etc/xray/usage.json"
CFG_FILE = "/usr/local/etc/xray/config.json"

def load_usage():
    if os.path.exists(USAGE_FILE):
        try:
            with open(USAGE_FILE, 'r') as f: return json.load(f)
        except: return {}
    return {}

def save_usage(db):
    with open(USAGE_FILE, 'w') as f: json.dump(db, f)

def get_users():
    users = {}
    if os.path.exists(DB_FILE):
        with open(DB_FILE, 'r') as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 5: users[parts[0]] = parts[4]
                elif len(parts) == 4: users[parts[0]] = "Unlimited"
    return users

def update_stats():
    while True:
        try:
            out = subprocess.check_output(["/usr/local/bin/xray", "api", "statsquery", "-server=127.0.0.1:10085", "-reset=true"], stderr=subprocess.DEVNULL).decode('utf-8')
            if out.strip():
                data = json.loads(out)
                usage_db = load_usage()
                users = get_users()
                changed = False
                if "stat" in data:
                    for stat in data["stat"]:
                        parts = stat.get("name", "").split(">>>")
                        if len(parts) == 4 and parts[0] == "user":
                            email = parts[1]
                            val = int(stat.get("value", 0))
                            if email not in usage_db: usage_db[email] = 0
                            usage_db[email] += val
                            changed = True
                if changed:
                    save_usage(usage_db)
                    for u, gb in users.items():
                        if gb != "Unlimited" and u in usage_db:
                            try:
                                limit_bytes = float(gb) * 1024 * 1024 * 1024
                                if usage_db[u] > limit_bytes:
                                    # Data ပြည့်သွားပါက အကောင့်ကို ဖျက်ပစ်မည်
                                    subprocess.run(f"sed -i '/^{u} /d' {DB_FILE}", shell=True)
                                    subprocess.run(f"jq --arg em '{u}' 'del(.inbounds[0].settings.clients[] | select(.email == $em))' {CFG_FILE} > {CFG_FILE}.tmp", shell=True)
                                    os.rename(f"{CFG_FILE}.tmp", CFG_FILE)
                                    subprocess.run(["systemctl", "restart", "xray"])
                            except: pass
        except: pass
        time.sleep(60)

class ReqHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()
        usage_db = load_usage()
        users = get_users()
        html = "<html><head><title>ZAW VPN - Data Usage</title><meta name='viewport' content='width=device-width, initial-scale=1'><meta http-equiv='refresh' content='60'><style>body{font-family:Arial;background:#f4f4f9;text-align:center;padding:20px;}table{width:100%;max-width:600px;margin:auto;border-collapse:collapse;background:#fff;box-shadow:0 0 10px rgba(0,0,0,0.1);}th,td{padding:12px;border:1px solid #ddd;}th{background:#007BFF;color:white;}tr:nth-child(even){background:#f2f2f2;}.warning{color:red;font-weight:bold;}</style></head><body><h2>📊 V2Ray Data Usage Dashboard</h2><table><tr><th>👤 Username</th><th>💾 Used Data</th><th>🎯 Data Limit</th></tr>"
        for u, gb in users.items():
            used = usage_db.get(u, 0)
            used_mb = used / (1024 * 1024)
            used_str = f"{used_mb/1024:.2f} GB" if used_mb > 1024 else f"{used_mb:.2f} MB"
            limit_str = f"{gb} GB" if gb != "Unlimited" else "Unlimited"
            if gb != "Unlimited" and (used / (1024*1024*1024)) >= float(gb) * 0.9:
                used_str = f"<span class='warning'>{used_str}</span>"
            html += f"<tr><td>{u}</td><td>{used_str}</td><td>{limit_str}</td></tr>"
        html += "</table><br><p>ZAW Script Manager</p></body></html>"
        self.wfile.write(html.encode('utf-8'))

if __name__ == '__main__':
    threading.Thread(target=update_stats, daemon=True).start()
    HTTPServer(('0.0.0.0', 8181), ReqHandler).serve_forever()
EOF

chmod +x /usr/local/bin/vweb_quota.py

cat > /etc/systemd/system/vweb.service << 'EOF'
[Unit]
Description=ZAW V2Ray Web & Quota Dashboard
After=network.target xray.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vweb_quota.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo -e "${Y}📋 VLESS CLI Menu ထည့်သွင်းနေပါသည်...${Z}"
wget -qO /usr/bin/vmenu "https://raw.githubusercontent.com/zaw-myscript/zaw-vless/main/vmenu"
chmod +x /usr/bin/vmenu

systemctl daemon-reload
systemctl enable --now xray
systemctl enable --now vweb
systemctl restart xray
systemctl restart vweb

ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 8181/tcp >/dev/null 2>&1 || true

echo -e "\n${G}✅ VLESS (WebSocket) Server, Menu, Data Web Dashboard နှင့် Auto-Clean စနစ် တပ်ဆင်ပြီးပါပြီ!${Z}"
echo -e "${C}အကောင့်စီမံရန် Terminal တွင်${Z} ${Y}vmenu${Z} ${C}ဟု ရိုက်ထည့်ပါ။${Z}"
echo -e "${C}ဝယ်ယူသူများ Data စစ်ဆေးရန် Link: http://$(cat /etc/IP 2>/dev/null || curl -s ipv4.icanhazip.com):8181${Z}"
