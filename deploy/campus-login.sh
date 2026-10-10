#!/bin/sh
# campus-login.sh - Dr.COM Portal auto-login for the router (校园网自动登录)
#
# This firmware has several utilities replaced by broken recursive stubs
# (curl, sed, openssl, od, uclient-fetch, and hexdump -e is crippled), so this
# script deliberately uses ONLY: printf, nc, grep, cut, tr, head, sleep, kill,
# ip, iwinfo, ubus. Account/password are ASCII-safe (alnum + @ + , + .) so the
# form body is pre-encoded at deploy time and needs no runtime encoder.
#
# Request mirrors the successful browser capture (1.1.1.1.har):
#   POST http://1.1.1.1:801/eportal/?c=ACSetting&a=Login&protocol=http:&hostname=1.1.1.1
#        &iTermType=1&wlanuserip=<ip>&wlanacip=<ac>&mac=00-00-00-00-00-00&ip=<ip>
#        &enAdvert=0&queryACIP=0&loginMethod=1
#   ok   : HTTP 302 Location .../3.htm
#   fail : HTTP 302 Location .../2.htm?ErrorMsg=<base64>
#
# Config : /etc/nettask/campus.conf (chmod 600)

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

CONF=/etc/nettask/campus.conf
LOG=/tmp/campus-login.log
TMP=/tmp/campus-ctx
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"

[ -f "$CONF" ] || exit 0
. "$CONF"

log() { echo "$(date '+%F %T') $1" >> "$LOG"; }

# req <host> <port> <request-text> <outfile> [secs]
# NB: keep stdin open for a while so busybox nc does not close the socket at
# stdin EOF before the server replies (this was the "no reply" cause).
req() {
    h=$1; p=$2; txt=$3; out=$4; s=${5:-6}
    ( printf '%b' "$txt"; sleep "$s" ) | nc "$h" "$p" > "$out" 2>&1 &
    rp=$!
    sleep $((s+1))
    kill "$rp" 2>/dev/null
    wait "$rp" 2>/dev/null
}

# field <file> <marker>   -> first quoted value after marker (grep/cut only)
field() {
    grep -o "$2=\"[^\"]*\"" "$1" 2>/dev/null | head -1 | cut -d'"' -f2
}

# ---------------- 0) STA link watchdog ----------------
if ! iwinfo "${WAN_IF:-phy0-sta0}" info 2>/dev/null | grep -q "ESSID: \"${WLAN_SSID:-campus}\""; then
    if [ -f /tmp/sta-down-marker ]; then
        log "STA ${WAN_IF:-phy0-sta0} down twice -> wifi reload"
        wifi reload >/dev/null 2>&1
        rm -f /tmp/sta-down-marker
        sleep 15
    else
        touch /tmp/sta-down-marker
        log "STA ${WAN_IF:-phy0-sta0} not associated (1/2)"
    fi
    exit 0
fi
rm -f /tmp/sta-down-marker

# ---------------- 1) online probe (no internet = portal intercepts) ----------------
# Primary check is IP-based (no DNS dependency); hostname probe is backup only.
online() {
    req 223.5.5.5 80 \
        "GET / HTTP/1.0\r\nHost: 223.5.5.5\r\nUser-Agent: $UA\r\n\r\n" \
        "$TMP.on" 6
    if grep -q 'HTTP/' "$TMP.on" 2>/dev/null; then
        grep -qi 'NetEngine\|DrcomServer' "$TMP.on" 2>/dev/null && return 1
        return 0
    fi
    req www.msftconnecttest.com 80 \
        "GET /connecttest.txt HTTP/1.0\r\nHost: www.msftconnecttest.com\r\nUser-Agent: $UA\r\n\r\n" \
        "$TMP.on2" 8
    grep -qi 'Microsoft Connect Test' "$TMP.on2" 2>/dev/null && return 0
    return 1
}
if online; then
    exit 0
fi

# ---------------- 2) current uplink IP ----------------
WLANUSERIP=$(ip -4 addr show dev "${WAN_IF:-phy0-sta0}" 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | cut -d' ' -f2)
if [ -z "$WLANUSERIP" ]; then
    WLANUSERIP=$(ubus call network.interface.wan status 2>/dev/null | grep -o '"address": "[0-9.]*"' | head -1 | cut -d'"' -f4)
fi
if [ -z "$WLANUSERIP" ]; then
    log "uplink has no IP yet - waiting for campus DHCP"
    exit 0
fi

# ---------------- 3) portal page (best effort: real wlanuserip / AC) ----------------
req 1.1.1.1 80 "GET /a70.htm HTTP/1.0\r\nHost: 1.1.1.1\r\nUser-Agent: $UA\r\n\r\n" "$TMP.a70" 5
if grep -q 'Dr\.COMWebLoginID' "$TMP.a70" 2>/dev/null; then
    v=$(field "$TMP.a70" ss5)
    [ -n "$v" ] && WLANUSERIP=$v
    v=$(field "$TMP.a70" AC)
    [ -n "$v" ] && ACIP=$v
fi
[ -n "$ACIP" ] || ACIP="$WLANACIP"
log "ctx: wlanuserip=$WLANUSERIP ac=$ACIP"

# ---------------- 4) login ----------------
Q="c=ACSetting&a=Login&protocol=http:&hostname=${PORTAL_HOST:-1.1.1.1}&iTermType=1"
Q="$Q&wlanuserip=$WLANUSERIP&wlanacip=$ACIP&mac=00-00-00-00-00-00&ip=$WLANUSERIP"
Q="$Q&enAdvert=0&queryACIP=0&loginMethod=${LOGIN_METHOD:-1}"

# FORM_BODY is pre-encoded at deploy time (alnum password => no runtime encoder)
if [ -z "$FORM_BODY" ]; then
    log "FORM_BODY missing in $CONF"
    exit 0
fi

attempt=1
while [ "$attempt" -le 3 ]; do
    req "${PORTAL_HOST:-1.1.1.1}" "${PORT:-801}" \
        "POST /eportal/?$Q HTTP/1.1\r\nHost: ${PORTAL_HOST:-1.1.1.1}:${PORT:-801}\r\nUser-Agent: $UA\r\nContent-Type: application/x-www-form-urlencoded\r\nOrigin: http://${PORTAL_HOST:-1.1.1.1}/\r\nReferer: http://${PORTAL_HOST:-1.1.1.1}/\r\nContent-Length: ${#FORM_BODY}\r\nConnection: close\r\n\r\n$FORM_BODY" \
        "$TMP.resp" 7

    if grep -qi 'Location:.*3\.htm' "$TMP.resp" 2>/dev/null; then
        log "attempt $attempt -> /3.htm OK"
        sleep 2
        req www.msftconnecttest.com 80 \
            "GET /connecttest.txt HTTP/1.0\r\nHost: www.msftconnecttest.com\r\nUser-Agent: $UA\r\n\r\n" \
            "$TMP.on3" 5
        if grep -qi 'Microsoft Connect Test' "$TMP.on3" 2>/dev/null; then
            log "LOGIN OK (ip=$WLANUSERIP ac=$ACIP)"
        else
            log "portal accepted but internet still down"
        fi
        exit 0
    fi

    loc=$(grep -i '^Location:' "$TMP.resp" 2>/dev/null | head -1 | tr -d '\r')
    if [ -n "$loc" ]; then
        log "attempt $attempt rejected: $loc"
    else
        log "attempt $attempt no reply: $(head -c 160 "$TMP.resp" 2>/dev/null | tr -d '\r\n')"
    fi
    attempt=$((attempt+1))
    sleep 3
done
# all attempts rejected; do a final definitive check - "inuse" often just means
# the session is already alive (probe gave a false negative before)
if online; then
    log "already online (inuse) - session alive"
    exit 0
fi
log "login rejected after retries (ip=$WLANUSERIP ac=$ACIP)"
exit 0