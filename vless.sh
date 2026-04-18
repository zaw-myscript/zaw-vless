#!/bin/bash
# ZAW-VLESS Auto Installer

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

# GitHub မှ vmenu ဖိုင်ကို ဆွဲယူခြင်း
echo -e "${Y}📋 VLESS CLI Menu ထည့်သွင်းနေပါသည်...${Z}"
wget -qO /usr/bin/vmenu "https://raw.githubusercontent.com/zaw-myscript/-my-zivpn/main/vmenu"
chmod +x /usr/bin/vmenu

systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray

ufw allow 80/tcp >/dev/null 2>&1 || true

echo -e "\n${G}✅ VLESS (WebSocket) Server နှင့် Menu တပ်ဆင်ပြီးပါပြီ!${Z}"
echo -e "${C}အကောင့်စီမံရန် Terminal တွင်${Z} ${Y}vmenu${Z} ${C}ဟု ရိုက်ထည့်ပါ။${Z}"
