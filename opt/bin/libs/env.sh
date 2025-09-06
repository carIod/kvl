#!/bin/sh
# shellcheck disable=SC2034
[ -n "$_ENV_INCLUDED" ] && return
_ENV_INCLUDED=1

APP_VERSION=1.0.0
APP_NAME_DESC=КВАС-ЛАЙТ

IPSET_TABLE_NAME=KVAS_UNBLOCK
IPSET_ULOG_NAME=ULOG_VPN
KVL_CONF_FILE=/opt/etc/kvl/kvl.conf
KVL_LIST_WHITE=/opt/etc/kvl/kvl.list
INFACE_NAMES_FILE=/opt/etc/kvl/inface_equals

DNSMASQ_DEMON=/opt/etc/init.d/S56dnsmasq
DNSCRYPT_DEMON=/opt/etc/init.d/S09dnscrypt-proxy2
DNSMASQ_IPSET_HOSTS=/opt/etc/kvl/dnsmasq.ipset

ADGUARDHOME_DEMON=/opt/etc/init.d/S99adguardhome
ADGUARDHOME_CONF="/opt/etc/AdGuardHome/adguardhome.conf"
ADGUARDHOME_YAML=/opt/etc/AdGuardHome/AdGuardHome.yaml
ADGUARD_IPSET_FILE=/opt/etc/AdGuardHome/kvl.ipset

PLUGIN_DIR="/opt/apps/kvl/bin/plugins"

FWMARK_NUM=0xd2000

if [ -t 1 ]; then
    WHITE="\033[1;37m";
    RED="\033[1;31m";
    GREEN="\033[1;32m";
    BLUE="\033[36m";
    CYAN="\033[36m";
    YELLOW="\033[33m";
    NOCL="\033[m";
    QST="${RED}?${NOCL}"
else
    WHITE=''; RED=''; GREEN=''; BLUE=''; CYAN=''; YELLOW=''; NOCL=''; QST='?'
fi