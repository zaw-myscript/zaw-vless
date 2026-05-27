#!/bin/bash
# ZAW-VLESS Auto Installer + AUTO-CLEAN + DATA QUOTA WEB DASHBOARD

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

# Xray Config (Web Data Tracker ပါဝင်သည်)
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

# === AUTO-CLEAN SYSTEM ===
echo -e "${Y}🧹 Auto-Delete (သက်တမ်းလွန် အကောင့်ဖျက်စနစ်) ထည့်သွင်းနေပါသည်...${Z}"
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

# === WEB DASHBOARD SYSTEM (PYTHON) ===
echo -e "${Y}🌐 Data Tracking & Website Dashboard တပ်ဆင်နေပါသည်...${Z}"
cat > /usr/local/bin/vweb_quota.py << 'EOF'
import os, json, subprocess, threading, time, datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

DB_FILE = "/usr/local/etc/xray/users.txt"
USAGE_FILE = "/usr/local/etc/xray/usage.json"
CFG_FILE = "/usr/local/etc/xray/config.json"
LOG_FILE = "/var/log/xray/access.log"

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

def get_online_users():
    online = set()
    now = datetime.datetime.now()
    min1 = now - datetime.timedelta(minutes=1)
    t0 = now.strftime("%Y/%m/%d %H:%M")
    t1 = min1.strftime("%Y/%m/%d %H:%M")
    try:
        cmd = f"grep -E '{t0}|{t1}' {LOG_FILE} | grep 'accepted'"
        out = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode('utf-8')
        for line in out.strip().split('\n'):
            if "email: " in line:
                email = line.split("email: ")[1].split()[0]
                online.add(email)
    except: pass
    return online

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
                                    subprocess.run(f"sed -i '/^{u} /d' {DB_FILE}", shell=True)
                                    subprocess.run(f"jq --arg em '{u}' 'del(.inbounds[0].settings.clients[] | select(.email == $em))' {CFG_FILE} > {CFG_FILE}.tmp", shell=True)
                                    os.rename(f"{CFG_FILE}.tmp", CFG_FILE)
                                    subprocess.run(["systemctl", "restart", "xray"])
                            except: pass
        except: pass
        time.sleep(60)

class ReqHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path
        user_filter = None
        
        if path.startswith("/user/"):
            user_filter = path.split("/user/")[1].strip()
        elif path != "/" and path != "/admin":
            self.send_response(404)
            self.end_headers()
            return
            
        self.send_response(200)
        self.send_header('Content-type', 'text/html; charset=utf-8')
        self.end_headers()
        
        usage_db = load_usage()
        users = get_users()
        online_users = get_online_users()
        
        html = f"""
        <html><head>
        <title>ZAW VPN - Data Usage</title>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <meta http-equiv='refresh' content='60'>
        <style>
            body{{font-family:Arial,sans-serif;background:#f4f4f9;text-align:center;padding:10px;}}
            .card{{max-width:600px;margin:auto;background:#fff;padding:20px;border-radius:10px;box-shadow:0 4px 8px rgba(0,0,0,0.1);}}
            h2{{color:#333;}}
            .user-box{{border:1px solid #ddd;border-radius:8px;padding:15px;margin-bottom:15px;text-align:left;background:#fafafa;}}
            .u-name{{font-size:18px;font-weight:bold;color:#007BFF;}}
            .status-on{{color:green;font-weight:bold;font-size:14px;float:right;}}
            .status-off{{color:gray;font-weight:bold;font-size:14px;float:right;}}
            .data-info{{margin:10px 0;font-size:15px;color:#555;}}
            .progress-container{{width:100%;background:#e0e0e0;border-radius:5px;overflow:hidden;height:22px;position:relative;}}
            .progress-bar{{height:100%;text-align:center;color:white;font-weight:bold;line-height:22px;font-size:13px;transition:width 0.5s;}}
            .bar-green{{background:#28a745;}}
            .bar-yellow{{background:#ffc107;color:black;}}
            .bar-red{{background:#dc3545;}}
            .bar-unlimited{{background:#17a2b8;}}
            .contact-btn{{display:inline-block;margin-top:20px;padding:10px 20px;background:#007BFF;color:white;text-decoration:none;border-radius:5px;font-weight:bold;}}
            .contact-btn:hover{{background:#0056b3;}}
        </style>
        </head><body><div class='card'><h2>📊 VPN Data Dashboard</h2>
        """
        
        count = 0
        for u, gb in users.items():
            if user_filter and u != user_filter:
                continue
                
            count += 1
            used = usage_db.get(u, 0)
            used_mb = used / (1024 * 1024)
            
            status_html = "<span class='status-on'>🟢 Online</span>" if u in online_users else "<span class='status-off'>🔴 Offline</span>"
            
            if gb == "Unlimited":
                pct = 0
                bar_class = "bar-unlimited"
                bar_text = "Unlimited Data"
                width = "100%"
                limit_str = "Unlimited"
                used_str = f"{used_mb/1024:.2f} GB" if used_mb > 1024 else f"{used_mb:.2f} MB"
            else:
                limit_mb = float(gb) * 1024
                pct = (used_mb / limit_mb) * 100
                if pct <= 50: bar_class = "bar-green"
                elif pct <= 80: bar_class = "bar-yellow"
                else: bar_class = "bar-red"
                
                width = f"{min(pct, 100)}%"
                bar_text = f"{pct:.1f}%"
                limit_str = f"{gb} GB"
                used_str = f"{used_mb/1024:.2f} GB" if used_mb > 1024 else f"{used_mb:.2f} MB"

            html += f"""
            <div class='user-box'>
                <div><span class='u-name'>👤 {u}</span> {status_html}</div>
                <div class='data-info'>💾 သုံးထားသည်: <b>{used_str}</b> / 🎯 ခွင့်ပြုချက်: <b>{limit_str}</b></div>
                <div class='progress-container'>
                    <div class='progress-bar {bar_class}' style='width:{width}'>{bar_text}</div>
                </div>
            </div>
            """
            
        if count == 0:
            html += "<p style='color:red;'>⚠️ အချက်အလက် မတွေ့ရှိပါ။ / User Not Found.</p>"
            
        html += """
        <a href='https://www.facebook.com/share/1CFG2UQzrD/' target='_blank' class='contact-btn'>💬 Admin သို့ ဆက်သွယ်ရန်</a>
        </div></body></html>
        """
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

# === MENU SCRIPT ဒေါင်းလုဒ်ဆွဲခြင်း (Bro ရဲ့ Github Link ကို အောက်မှာ ထည့်ထားပါတယ်) ===
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

echo -e "\n${G}✅ VLESS (WebSocket) Server, Menu နှင့် Web Dashboard တပ်ဆင်ပြီးပါပြီ!${Z}"
echo -e "${C}Terminal တွင်${Z} ${Y}vmenu${Z} ${C}ဟု ရိုက်ထည့်ပါ။${Z}"
