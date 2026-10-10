# 校园网 Dr.COM Portal 自动登录脚本（路由器/嵌入式适用）

针对「路由器以 WiFi STA / 有线方式接入校园网，需通过 Dr.COM Portal
（163 风格 eportal，华为 ME60 BRAS 常见）认证后才能上网」的场景。

## 特性

- **零外部依赖**：只用 POSIX shell + `nc`/`grep`/`cut`/`tr`/`printf`。
  不依赖 curl/wget/sed/openssl —— 因为部分 OpenWrt/LibWrt/ImmortalWrt
  固件上这些工具可能缺失或被替换为无法工作的占位文件（见随 PR 附带的 issue）。
- **判据正确**：门户只在客户端"没有外网"时拦截。脚本的行为是：
  对外网探测失败（未联网）→ 才发起认证；已有外网 → 直接退出。
- **参数动态**：wlanuserip / AC 优先取门户页 `/a70.htm` 实时返回的
  `ss5` / `AC` 字段；请求严格对照浏览器真实成功的请求（`/3.htm` 为成功
  信号，`/2.htm?ErrorMsg=<base64>` 为失败，`inuse, login again` 自动重试）。
- **可选自愈**：检测 STA 与校园 WiFi 失联会自动 `wifi reload` 重连（限频）。

## 用法

1. 配置 `/etc/nettask/campus.conf`（参考 `campus.conf.template`，`chmod 600`）：

   ```sh
   USERNAME='学号'
   SUFFIX='@telecom'          # 不填则留空 ''；用户名已含 @ 时自动不再加后缀
   PREFIX=',0,'               # Dr.COM 前缀，部分部署路由器场景需置空 ''
   WAN_IF='phy0-sta0'         # 校园网上联接口名（有线则填对应 eth/br 口）
   WLAN_SSID='campus'         # 校园 WiFi SSID（用于 STA 失联自检；有线场景可留空）
   PORTAL_HOST='1.1.1.1'      # 门户 VIP（被拦截时 HTTP 被劫持到它）
   PORT='801'
   WLANACIP=''                # AC 地址备用值（a70 页有实时值优先；留空则依赖页面/默认）
   LOGIN_METHOD='1'
   # 表单在部署时预编码（application/x-www-form-urlencoded）：
   #   账号规则：<PREFIX><用户名><后缀>，逗号需为 %2C，@ 为 %40。
   #   例：用户名 2025xxxx, 后缀 @telecom, 前缀 ,0, =>
   #       DDDDD=%2C0%2C2025xxxx%40telecom
   #   密码要求 ASCII 字母数字（否则请同样转义后填入）：
   FORM_BODY='DDDDD=%2C0%2C2025xxxx%40telecom&upass=<密码>&R1=0&R2=0&R3=0&R6=0&para=00&0MKKey=123456&buttonClicked=&redirect_url=&err_flag=&username=&password=<密码>&user=&cmd=&Login='
   ```

2. 手动执行一次：

   ```sh
   chmod +x /etc/nettask/campus-login.sh
   /etc/nettask/campus-login.sh
   tail /tmp/campus-login.log
   ```

   日志出现 `LOGIN OK` 且外网可达即成功。

3. 定时自愈（可选，OpenWrt）：

   ```sh
   echo '*/3 * * * * /etc/nettask/campus-login.sh >/dev/null 2>&1' >> /etc/crontabs/root
   /etc/init.d/cron enable && /etc/init.d/cron start
   ```

   开机自启（可选）：

   ```sh
   # /etc/rc.local 中 exit 0 之前追加：
   ( sleep 90; /etc/nettask/campus-login.sh ) >/dev/null 2>&1 &
   ```

## 成功/失败判定

- 302 → `Location: .../3.htm`：认证成功（页面标题「认证成功页」）。
- 302 → `Location: .../2.htm?ErrorMsg=<base64>`：失败，解码可见原因，
  常见 `inuse, login again`（账号在别处在线，脚本会自动重试）。

## 创新点 / 设计亮点

1. **判据即规则**：门户只在客户端"没有外网"时拦截，因此把"外网探测失败"当作
   唯一触发条件，不做页面特征匹配 —— 杜绝"认不出门户页就放弃"的漏判。
2. **零依赖实现**：仅 POSIX sh + `nc`/`grep`/`cut`/`tr`/`printf`。规避部分
   固件上 curl/sed/openssl 等被替换成占位文件（见 issue #8）导致的静默失败。
3. **参数不写死**：`wlanuserip`/`wlanacip` 从门户页 `/a70.htm` 实时解析
   （`ss5`/`AC` 字段），换 IP、多 AC 场景免维护。
4. **会话冲突自愈**：`inuse, login again` 自动重试；STA 失联自动 `wifi reload`
   重连（限频防抖）。
5. **全配置化**：SSID / 账号前缀 / 运营商后缀 / AC / 接口 全部走 `campus.conf`。

## 与 luci-app-nettask 的集成

本模板天然适配本项目的执行方式，可在 LuCI 里直接编排：

| luci-app-nettask 功能 | 用法 |
|---|---|
| 断网触发 | 把本脚本作为"断网时执行"的任务：检测到断网即自动重登，恢复免手动 |
| 定时任务 | 每 3 分钟巡检一次（等价于 cron `*/3`），低成本保活 |
| 开机运行 | 开机 90 秒后执行一次，抢在校园网会话到期前完成认证 |