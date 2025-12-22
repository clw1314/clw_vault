#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PROTECTED_PORTS=(80 443 8443 18443 62103)
ASN_WHITELIST=("AS4134" "AS4837" "AS56040" "AS56041" "AS56042" "AS56044" "AS56046" "AS56047" "AS56048")
ASN_API_BASE="https://asnip.heisemaoyi789.workers.dev"
IPSET_NAME_V4="whitelist_v4"
IPSET_NAME_V6="whitelist_v6"
TMP_V4_FILE="/tmp/whitelist_v4.txt"
TMP_V6_FILE="/tmp/whitelist_v6.txt"
UPDATE_SCRIPT="/usr/local/bin/update_firewall_ipsets.sh"
CRON_JOB="0 4 * * * $UPDATE_SCRIPT >/dev/null 2>&1"

PORTS_DISPLAY=$(IFS=/; echo "${PROTECTED_PORTS[*]}")

echo -e "${GREEN}========== 防火墙配置脚本（ASN白名单） ==========${NC}"
echo -e "${YELLOW}[INFO] 受保护端口: ${PORTS_DISPLAY} (TCP+UDP)${NC}"
echo -e "${YELLOW}[INFO] ASN白名单: ${ASN_WHITELIST[*]}${NC}"

check_install() {
    if ! command -v $1 &>/dev/null; then
        echo -e "${YELLOW}[INFO] 安装 $1...${NC}"
        apt-get update -y && apt-get install -y $1
    fi
}
check_install ufw
check_install ipset
check_install curl
check_install cron

ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
[ "$ufw_status" != "active" ] && ufw --force enable

SSH_PORT=$(grep -E "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
[ -z "$SSH_PORT" ] && SSH_PORT=$(ss -tnlp | grep sshd | awk -F: '{print $2}' | awk '{print $1}' | head -n1)
[ -z "$SSH_PORT" ] && SSH_PORT=22
echo -e "${GREEN}[INFO] SSH端口：$SSH_PORT${NC}"
ufw status numbered | grep -q "$SSH_PORT/tcp" || ufw allow $SSH_PORT/tcp comment 'Allow SSH'

echo -e "${YELLOW}[INFO] 下载ASN白名单IP...${NC}"
rm -f "$TMP_V4_FILE" "$TMP_V6_FILE"
touch "$TMP_V4_FILE" "$TMP_V6_FILE"

for asn in "${ASN_WHITELIST[@]}"; do
    echo "  -> 下载 ${asn}..."
    curl -sfL "${ASN_API_BASE}/${asn}" >> "$TMP_V4_FILE"
    echo "" >> "$TMP_V4_FILE"
    curl -sfL "${ASN_API_BASE}/${asn}?6" >> "$TMP_V6_FILE"
    echo "" >> "$TMP_V6_FILE"
done

ipset list $IPSET_NAME_V4 &>/dev/null && ipset flush $IPSET_NAME_V4 || ipset create $IPSET_NAME_V4 hash:net family inet maxelem 500000
ipset list $IPSET_NAME_V6 &>/dev/null && ipset flush $IPSET_NAME_V6 || ipset create $IPSET_NAME_V6 hash:net family inet6 maxelem 100000

if [ -s "$TMP_V4_FILE" ]; then
    sed -i 's/\r$//' "$TMP_V4_FILE"
    grep -v '^\s*$' "$TMP_V4_FILE" | sort -u | while IFS= read -r ip; do
        ipset add $IPSET_NAME_V4 "$ip" 2>/dev/null
    done
    echo -e "${GREEN}[OK] IPv4白名单加载完成${NC}"
fi

if [ -s "$TMP_V6_FILE" ]; then
    sed -i 's/\r$//' "$TMP_V6_FILE"
    grep -v '^\s*$' "$TMP_V6_FILE" | sort -u | while IFS= read -r ip; do
        ipset add $IPSET_NAME_V6 "$ip" 2>/dev/null
    done
    echo -e "${GREEN}[OK] IPv6白名单加载完成${NC}"
fi

echo -e "${YELLOW}[INFO] 清理旧规则...${NC}"
for chain_cmd in "iptables ufw-user-input" "ip6tables ufw6-user-input"; do
    cmd=$(echo $chain_cmd | awk '{print $1}')
    chain=$(echo $chain_cmd | awk '{print $2}')
    while true; do
        line=$($cmd -L $chain -n --line-numbers 2>/dev/null | grep -E "(whitelist_|dpt:(80|443|8443|18443|62103))" | head -1 | awk '{print $1}')
        [ -z "$line" ] && break
        $cmd -D $chain $line 2>/dev/null
    done
done

echo -e "${YELLOW}[INFO] 添加防火墙规则 (TCP+UDP)...${NC}"
for port in "${PROTECTED_PORTS[@]}"; do
    # TCP规则
    iptables -I ufw-user-input 1 -p tcp -m set --match-set $IPSET_NAME_V4 src --dport "$port" -j ACCEPT
    iptables -A ufw-user-input -p tcp --dport "$port" -j DROP
    ip6tables -I ufw6-user-input 1 -p tcp -m set --match-set $IPSET_NAME_V6 src --dport "$port" -j ACCEPT
    ip6tables -A ufw6-user-input -p tcp --dport "$port" -j DROP
    # UDP规则
    iptables -I ufw-user-input 1 -p udp -m set --match-set $IPSET_NAME_V4 src --dport "$port" -j ACCEPT
    iptables -A ufw-user-input -p udp --dport "$port" -j DROP
    ip6tables -I ufw6-user-input 1 -p udp -m set --match-set $IPSET_NAME_V6 src --dport "$port" -j ACCEPT
    ip6tables -A ufw6-user-input -p udp --dport "$port" -j DROP
done
echo -e "${GREEN}[OK] 规则添加完成${NC}"

mkdir -p /etc/iptables
ipset save > /etc/iptables/ipset.rules

cat >/etc/systemd/system/ipset-restore.service <<'EOF'
[Unit]
Description=Restore IP sets
Before=ufw.service
[Service]
Type=oneshot
ExecStartPre=/sbin/ipset destroy
ExecStart=/sbin/ipset restore -f /etc/iptables/ipset.rules
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ipset-restore.service >/dev/null 2>&1

cat >"$UPDATE_SCRIPT" <<'UPDATEEOF'
#!/bin/bash
ASN_WHITELIST=("AS4134" "AS4837" "AS56040" "AS56041" "AS56042" "AS56044" "AS56046" "AS56047" "AS56048")
ASN_API_BASE="https://asnip.heisemaoyi789.workers.dev"
TMP_V4="/tmp/whitelist_v4.txt"
TMP_V6="/tmp/whitelist_v6.txt"
IPSET_V4="whitelist_v4"
IPSET_V6="whitelist_v6"

rm -f "$TMP_V4" "$TMP_V6"
for asn in "${ASN_WHITELIST[@]}"; do
    curl -sfL "${ASN_API_BASE}/${asn}" >> "$TMP_V4"
    echo "" >> "$TMP_V4"
    curl -sfL "${ASN_API_BASE}/${asn}?6" >> "$TMP_V6"
    echo "" >> "$TMP_V6"
done

ipset flush $IPSET_V4
sed -i 's/\r$//' "$TMP_V4"
grep -v '^\s*$' "$TMP_V4" | sort -u | while read ip; do ipset add $IPSET_V4 "$ip" 2>/dev/null; done

ipset flush $IPSET_V6
sed -i 's/\r$//' "$TMP_V6"
grep -v '^\s*$' "$TMP_V6" | sort -u | while read ip; do ipset add $IPSET_V6 "$ip" 2>/dev/null; done

ipset save > /etc/iptables/ipset.rules
UPDATEEOF
chmod +x "$UPDATE_SCRIPT"

crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT" || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo -e "\n${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ ASN白名单防火墙配置完成              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo -e "${GREEN}[✓] SSH端口：${NC}$SSH_PORT"
echo -e "${GREEN}[✓] IPv4白名单：${NC}$(ipset list $IPSET_NAME_V4 2>/dev/null | grep -c '^[0-9]') 条"
echo -e "${GREEN}[✓] IPv6白名单：${NC}$(ipset list $IPSET_NAME_V6 2>/dev/null | grep -c '^[0-9a-f]') 条"
echo -e "${GREEN}[✓] 受保护端口：${NC}${PORTS_DISPLAY} (TCP+UDP)"
echo -e "${GREEN}[✓] ASN列表：${NC}${ASN_WHITELIST[*]}"
echo ""
echo -e "${YELLOW}[查看IPv4白名单]${NC} ipset list $IPSET_NAME_V4"
echo -e "${YELLOW}[查看IPv6白名单]${NC} ipset list $IPSET_NAME_V6"
echo -e "${YELLOW}[查看规则]${NC} iptables -L ufw-user-input -n -v --line-numbers"
