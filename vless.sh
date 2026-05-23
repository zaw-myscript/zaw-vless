#!/bin/bash
# ZAW-VLESS Auto Installer + AUTO-CLEAN EXPIRED USERS FIXED

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

cat > $CFG <<EOF
{
  "log": {
    "loglevel": "warning"
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
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

# === 🔴 AUTO-CLEAN (ည ၁၂ နာရီတိုင်း အလိုလို အကောင့်ဖျက်မည့် စနစ်) ထည့်သွင်းခြင်း 🔴 ===
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

while read -r user uuid exp limit; do
    exp_sec=$(date -d "$exp" +%s 2>/dev/null)
    if [[ -n "$exp_sec" && $exp_sec -lt $today_sec ]]; then
        echo "$user" >> "$EXP_DB"
        changed=1
    else
        echo "$user $uuid $exp $limit" >> "$TMP_DB"
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

echo -e "${Y}📋 VLESS CLI Menu ထည့်သွင်းနေပါသည်...${Z}"
wget -qO /usr/bin/vmenu "https://raw.githubusercontent.com/zaw-myscript/zaw-vless/main/vmenu"
chmod +x /usr/bin/vmenu

systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray

ufw allow 80/tcp >/dev/null 2>&1 || true

echo -e "\n${G}✅ VLESS (WebSocket) Server, Menu နှင့် Auto-Clean စနစ် တပ်ဆင်ပြီးပါပြီ!${Z}"
echo -e "${C}အကောင့်စီမံရန် Terminal တွင်${Z} ${Y}vmenu${Z} ${C}ဟု ရိုက်ထည့်ပါ။${Z}"
