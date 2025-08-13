#!/bin/sh
# Universal embedded DDNS Shell Script
# Github: https://github.com/kkkgo/UE-DDNS
# Blog: https://blog.03k.org/post/ue-ddns.html
# func-Universal
# [!] Be careful not to change any "#" line in the script.

#-DDNSINIT-
# Customizable option area

# Customize the network proxy that connects to the DNS provider API
# example1: PROXY="http://192.168.1.100:7890"
# example2: PROXY="socks5h://192.168.1.100:7890" (curl only)
PROXY=""

# Specifies a network interface is used to connect to the network (curl only)
# example: OUT="eth0"
OUT=""

# Custom Web sites that check IP addresses
# example: CHECKURL="http://ipsu.03k.org"
CHECKURL=""

# ValidateCA=1, will verify the validity of the HTTPS certificate.
# You need to configure the CA certificate environment on the current system,
# such as installing the ca-certificates package.
ValidateCA=0

# ntfy is a simple HTTP-based pub-sub notification service.
# https://ntfy.sh/
# ddns_ntfy_url="http://ntfy.sh/yourtopic"
ddns_ntfy_url=""

# Bark is an iOS App which allows you to push customed notifications to your iPhone.
# https://github.com/Finb/bark-server
# ddns_bark_url="https://api.day.app/yourkey"
ddns_bark_url=""

# sct is a message push platform (wechat).
# https://sct.ftqq.com/
# ddns_sct_url="https://sctapi.ftqq.com/yourkey.send"
ddns_sct_url=""

# pushplus is a message push platform (wechat).
# https://www.pushplus.plus/
# ddns_pushplus_url="http://www.pushplus.plus/send?token=yourkey"
ddns_pushplus_url=""

# dingtalk group robot push.
# https://open.dingtalk.com/document/robots/custom-robot-access/
# ddns_dingtalk_url="https://oapi.dingtalk.com/robot/send?access_token=yourtoken"
ddns_dingtalk_url=""

# Customizable option end

versionUA="github.com/kkkgo/UE-DDNS"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin:$PATH"
IPREX4='([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
IPREX6="(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))"
PUBIPREX6="^2[0-9a-fA-F]{3}:[0-9a-fA-F:]+"
DOMAINREX="[0-9a-z-]+\.[\.0-9a-z-]+"
DEVREX="[-_0-9a-zA-Z@.]+"
date +"%Y-%m-%d %H:%M:%S %Z"
# func-DDNSINIT

export_func() {
    func_name=$1
    func_start=$(grep -n "$func_name" "$0" | head -1 | grep -Eo "^[0-9]+")
    func_end=$(grep -n "func-""$func_name" "$0" | head -1 | grep -Eo "^[0-9]+")
    sed -n "$func_start","$func_end"p "$0"
}

# strip IP
stripIP() {
    if [ "$2" = "6" ]; then
        echo "$1" | grep -Eo "$IPREX6" | grep -Eo "$PUBIPREX6"
    else
        echo "$1" | grep -Eo "$IPREX4"
    fi
    return
