# ZeroClaw for OpenWrt / 竞斗云 IPQ4019

独立打包仓库，不维护 ZeroClaw 源码分叉。目标为 P&W R619AC 128M、
IPQ4019 / Cortex-A7 / ARMv7、OpenWrt 25.12.4 `ipq40xx/generic`。
模型推理使用远程 API，不在路由器上部署大模型。

**当前状态：已打通 GitHub Actions 交叉编译、QEMU CLI 检查和 APK 打包，
尚未通过真实路由器运行验证。**
CI 的 QEMU 检查只覆盖 CLI 启动，不能证明路由器上的内存占用、
联网、数据库、渠道和长期稳定性。

## 构建

进入本仓库 **Actions → Build ZeroClaw for OpenWrt IPQ4019 → Run workflow**。
默认启用 `agent-runtime,gateway`，不加入浏览器、WASM 插件或额外渠道。
需要 Telegram 等渠道时，在 `extra_features` 填写 `channel-telegram`；
多个 Cargo feature 用英文逗号分隔。额外特性不保证支持 ARMv7。
此精简版不包含 Web 前端静态资源，也不保证包含上游完整发行版的所有工具。

`build.env` 固定上游 v0.9.0 的提交、Rust 1.96.0 和官方 OpenWrt SDK 校验值。
目标是 **`armv7-unknown-linux-musleabihf`，不是 glibc**。
SDK 文件名和 GCC 前缀虽然带 `eabi`，该 Cortex-A7 工具链实际使用硬浮点调用约定；
OpenWrt 的 Rust 映射也在启用 FPU 时选择 `musleabihf`，不能只按 SDK 名称判断。
编译前先用 SDK 链接并执行硬浮点小程序；使用同一 SDK 编译 C 依赖及链接，
生成静态 ELF，检查架构、浮点 ABI、动态加载器和共享库依赖，
再用 QEMU Cortex-A7 执行版本和帮助命令。
沿用上游尺寸优化，CI 将 LTO 改为 thin，并限制两个编译任务。
缓存 Cargo 下载和编译目录，失败后也保留可复用的编译结果。

同一固定上游提交同时编译 `zeroclaw` 和官方终端客户端 `zerocode`，
两者都检查静态 ARMv7 ELF 和 QEMU CLI 启动。尚未验证真实路由器上同时运行两者的 RAM 占用。

成功后下载 Actions artifact，其中包含：

| 文件 | 用途 |
| --- | --- |
| `zeroclaw-0.9.0-openwrt-ipq4019.tar.gz` | ARMv7 ZeroClaw、ZeroCode、安装器和启动脚本 |
| `zeroclaw-openwrt-*.apk` | 仅启动脚本、UCI 和 CLI 包装器的小型 OpenWrt 集成包 |
| `SHA256SUMS` | 归档和 APK 的校验值 |
| `*-info.txt` | 上游提交、特性、工具链和 ELF/CLI 检查记录 |

**APK 不包含大体积的 ZeroClaw / ZeroCode 程序**，以免占满内置 overlay。
首版推荐使用下面的归档安装器；APK 为需要包管理器管理集成文件的用户提供，
不要同时使用两种方式管理相同的 `/etc`、`/usr` 文件。
没有配置自动追踪上游、自动发布 Release 或自动安装到路由器。

## 安装到 MMC 内存卡

卡须已稳定挂载到 `/mnt/mmcblk0p1`，**推荐使用 ext4** 等支持 Linux 权限的文件系统，
且不是只读或 `noexec` 挂载。**不要直接格式化已有卡**，先确认并备份内容。
C10 只描述顺序写入等级；随机写入性能、健康和寿命仍需实际观察。
默认拒绝 FAT/exFAT；推荐使用下面的 `--fat-image` 模式，将 Unix 运行数据放入卡上的 ext4 镜像。
所有模式都拒绝 tmpfs、未挂载目录、只读和 `noexec` 挂载，不会自动重挂载或格式化。

确认固件的包管理器，安装 HTTPS 根证书，并校准系统时间。
OpenWrt 25.12 使用 APK；如果实际使用 opkg，请不要安装这里构建的 APK。

```sh
apk update
apk add ca-bundle
```

在电脑上解开下载的 artifact ZIP，将其中的 `.tar.gz` 和 `SHA256SUMS`
上传到卡上的 `/mnt/mmcblk0p1/zeroclaw-download`，不要占用 `/tmp` 内存盘。
如果 SCP 的 SFTP 模式不可用，可以使用客户端支持的传统 SCP 模式。
然后在路由器 SSH 终端运行：

```sh
cd /mnt/mmcblk0p1/zeroclaw-download
# 校验本次要安装的归档；外层 SHA256SUMS 也列出了 APK。
grep 'zeroclaw-0.9.0-openwrt-ipq4019.tar.gz$' SHA256SUMS | sha256sum -c -
mkdir -p unpack
tar -xzf zeroclaw-0.9.0-openwrt-ipq4019.tar.gz -C unpack
sh unpack/install.sh
zeroclaw --version
zeroclaw quickstart
```

安装器检查卡内剩余空间、归档内文件校验和及程序能否执行，然后才替换程序。
首次和升级安装后都保持 UCI 的 `enabled=0`，不会自动运行智能体。
已有 UCI 配置除挂载路径、存储模式、FAT 兼容开关及启用状态外保留；已有模型密钥和运行数据不会覆盖。
如需变更挂载点，传入 `sh unpack/install.sh /你的/挂载点`（允许末尾 `/`）；
需同时自行保证 OpenWrt 的持久挂载配置正确。

### vfat/exFAT + ext4 镜像（推荐兼容模式）

保留卡的 vfat/exFAT 格式，不格式化整张卡。安装器只在卡上新建一个 **256 MiB**
普通文件 `zeroclaw/state.ext4`，将它格式化为 ext4 并通过 loop 挂载到 `zeroclaw/state`。
主程序仍放在外层卡的 `zeroclaw/bin`；HOME、配置、加密密钥、数据库、内部工作区和缓存
都使用镜像内的路径。内置可写 overlay 只放小型启动脚本及 UCI，不放大程序或运行数据；
OpenWrt 的 `/rom` 通常只读。

先确认固件提供 vfat/exFAT、loop 和 ext4 支持。APK 固件可安装：

```sh
apk add kmod-loop kmod-fs-ext4 e2fsprogs coreutils-stat
```

opkg 固件使用对应的 `opkg install`，不要混用包管理器。首次创建需要 `mkfs.ext4`，
运行时需要支持 `-o loop` 的 `mount`、可用 loop 设备、`/sys/block` 和 `stat`
（部分 OpenWrt BusyBox 不包含它，须安装 `coreutils-stat`）；
内核模块须与当前固件版本匹配，不能强装不匹配的 kmod。安装依赖仍占内置空间，
先用 `df -h / /overlay /mnt/mmcblk0p1` 检查余量。

外层卡须已经可写、允许执行并持久挂载，但镜像模式不要求 FAT 的 `fmask/dmask=0077`。
如需电脑直接读写资料，可继续存放在外层卡上；不要给不可信本地用户写入程序或镜像的权限。
将包含此模式的新归档解开后运行：

```sh
sh unpack/install.sh --fat-image /mnt/mmcblk0p1/
zeroclaw quickstart
zerocode
```

首次创建需要卡内额外 256 MiB、两个程序的更新空间和 16 MiB 余量。加入 ZeroCode 后，
程序及压缩包均比旧版更大，以产物内的检查记录和实际文件为准；磁盘大小不是运行 RAM 占用。
镜像占用卡空间，不会整块载入 RAM。
该大小为初始固定容量，不会自动扩容；数据库等仍可能填满镜像。
重复安装复用现有镜像，绝不重新格式化或覆盖它；已有裸 FAT 配置及 `zeroclaw-test`
测试数据也不会自动迁移或删除。首次切换后重新 quickstart，或自行审核并迁移配置。

安装器保存 `storage_mode=image`，并保持服务关闭。后续 CLI/procd 启动只挂载**已有**镜像，
不自动创建或格式化。检查外层精确挂载点、镜像为普通文件、内层为可写可执行的 ext4、
`nosuid,nodev`、root 所有权与 `0700` 权限，还通过 sysfs 验证 loop 的 backing file。
镜像缺失、损坏、错误挂载、只读、无卡或依赖缺失时拒绝运行，不回退写入 flash 或裸 FAT。
后续仍用常规安装命令升级，会沿用已保存的存储模式。

**风险与运维：** 镜像不是加密磁盘；拥有外层 FAT 卡访问权的人仍可复制、读取或修改镜像，
加密密钥与配置在同一镜像里，也不能保证拔卡后的保密性。外层 FAT 无日志，
断电、热拔卡、卡故障仍会影响镜像及数据库；ext4 的日志并不能消除这些风险。
电脑可直接访问外层资料，但普通 Windows 不能直接打开镜像内文件。
先在真实路由器验证，定期备份；不要承诺所有工具均可正常运行。

拔卡或复制一致的镜像备份前，停止服务，退出卡目录并依次卸载内层、外层：

```sh
/etc/init.d/zeroclaw stop
cd /
umount /mnt/mmcblk0p1/zeroclaw/state &&
    umount /mnt/mmcblk0p1
```

如果 busy，先停止其他卡访问，不使用强制或 lazy 卸载，不热拔卡。不要把正在使用的
镜像当作普通文件在线复制备份。失败后安装器可能留下已创建的镜像供重试，不会自动删除数据。
若锁目录在异常断电后残留，应先确认没有安装或挂载进程，再手动清理明确的锁目录。
如果旧安装包在创建镜像后报 `stat: not found`，安装 `coreutils-stat` 后重跑
`install.sh --fat-image` 即可复用镜像，不要删除镜像或重新格式化卡。

### 裸 vfat/exFAT 的旧式显式兼容模式（有限支持）

为了保留电脑直接读写能力，可以使用 vfat 或 exFAT，但**不保证 ZeroClaw 全功能正常**。
固定的上游版本首次保存加密密钥会使用硬链接，裸 FAT 不支持这一操作，
因此即使权限检查通过，quickstart 仍可能报 `Failed to encrypt providers.models.api_key`。
完整配置/运行请使用上面的镜像模式，不通过关闭加密来掩盖此限制。
先备份，并自行配置持久挂载选项，例如 `rw,exec,uid=0,gid=0,umask=0077`；
也可以使用 `fmask=0077,dmask=0077`。固件须有相应文件系统驱动。
`fmask` 和 `dmask` 分别覆盖 `umask`，两者的有效值都须为 `0077`，
使文件和目录仅 root 可读写执行；`umask=0077,fmask=0022` 等组合会被拒绝。
`fmask=0177` 会移除程序执行位，也不能使用。避免 `showexec`：
它可能阻止无 `.exe` 后缀的 ZeroClaw 和安装临时文件执行。
内核可能在 `/proc/mounts` 中省略默认的 `uid=0,gid=0`，脚本仍会验证实际 root 所有权。

完成挂载配置后运行（命令中的末尾 `/` 可以保留）：

```sh
sh unpack/install.sh --allow-fat /mnt/mmcblk0p1/
```

安装器将规范化路径，并保存 `zeroclaw.main.allow_fat=1`；
后续更新会沿用此显式 UCI 开关。CLI 包装器和服务使用同一检查，
每次启动都会检查挂载权限和实际程序执行能力。
安装器在 FAT 上不依赖逐文件 `chmod`，仍在替换旧程序前执行新程序检查。
关闭兼容模式使用 `uci set zeroclaw.main.allow_fat='0'; uci commit zeroclaw`。
对于 APK 替代安装，须自行设置此开关，且手动放入的程序也须通过同样检查。

**限制与风险：** FAT/exFAT 不支持真正的逐文件 Unix 权限、所有权和符号链接；
挂载掩码是整张卡的访问策略，不是文件级隔离，卡上其他文件也可能显示为可执行。
root-only 只限制当前路由器上的非 root 访问，拔卡接电脑后仍能读取配置和 API Key；
不能将此模式当作加密或密钥保护。依赖符号链接、权限语义的工具或工作区操作可能失败，
数据库、文件锁、断电恢复及长期可靠性也需真实验证；尤其 exFAT 缺少日志，
不要热拔卡。需要这些保证时，应迁移到 ext4。

### 不改挂载权限的临时前台测试

如果暂时不能修改卡的挂载权限，可以将 `run-test.sh` 放在卡上已解开的
归档目录中（与 `install.sh` 同级），绕过 FAT 掩码及实际 root-only 权限检查：

```sh
sh unpack/run-test.sh /mnt/mmcblk0p1/ --version
```

脚本直接运行归档里的程序，不执行安装器，不更改 UCI、服务或系统文件，也不重启、
重挂载路由器。它仍检查归档校验和、绝对挂载点、已挂载、可写及可执行，
要求归档本身位于该卡上。测试配置及 HOME 独立放在卡上的 `zeroclaw-test`，
不会覆盖正式安装的数据。不指定 ZeroClaw 参数时默认运行 `--version`。

**这不是安全安装模式：** 当前路由器上的其他用户及电脑可能读取测试 API Key，
普通用户也可能修改程序和配置；仅在可信、受控环境临时测试，结束后撤销测试密钥。
裸 FAT 的加密密钥保存仍可能失败，跳过脚本检查并不提供硬链接支持；
完整 quickstart/运行应改用镜像模式。正式安装和服务的权限检查不变。

使用引导配置远程模型提供商、模型及 API Key。不要将密钥放进仓库、
Actions 输入或日志。配置、HOME、默认工作数据应留在卡上；
如果引导或自定义配置要求选择工作区，也应明确指定卡内路径。
启动前检查配置中是否有指向 `/root`、内置 overlay 或其他位置的绝对路径。

### 默认 OpenWrt 运维提示词

软件包附带中文 OpenWrt 运维提示词。通过本包的 `zeroclaw quickstart` 成功创建 agent 后，
包装器会为新 agent 的默认工作区写入缺失的 `AGENTS.md`，由上游原生 personality 加载机制
加入后续系统提示词，无需在 `$EDITOR` 中粘贴。文件位于状态存储内的
`config/agents/<alias>/workspace/AGENTS.md`；镜像模式下也在 ext4 镜像里。

内容涵盖 BusyBox/ash、UCI/procd、包管理器识别、空间与挂载检查、敏感信息脱敏、
变更前确认、断连与回滚风险，以及不对挂载点递归删除等约定。
它**不是权限配置或安全沙箱**，不会自动切换 risk profile、开放目录、关闭审批或保证 YOLO 安全。
升级不改写已有 agent；quickstart 中已有的 `AGENTS.md` 也不会覆盖，其他自定义 personality
文件保持不变。自定义工作区不自动写入，会给出提示，需用户自行审核后放置文件。

已有 agent 可显式应用（以 `ops` 为例）：

```sh
zeroclaw openwrt-prompt ops
```

此命令仅在该 agent 没有 `AGENTS.md` 时创建，不覆盖已有文件。修改工作区的 `AGENTS.md`
即可自定义；删除它可移除这一默认提示词。模板位于
`/usr/share/zeroclaw/openwrt-prompt.txt`，只占少量内置空间。
重新启动 agent 后生效。直接运行卡上的原始二进制、旧式 `run-test.sh` 或 gateway quickstart
不会经过这一 CLI 包装器；需要默认提示词时使用上面的显式命令。
若提示词写入失败，quickstart 已创建的 agent 不会回滚，应修复文件/挂载问题后再显式应用。

### 官方终端聊天与自动保存

在 OpenWrt 的 SSH 终端运行：

```sh
zerocode
```

这是官方 ZeroCode 终端界面，不是另一个 `zeroclaw agent`。默认打开配置界面，
在 Chat 中选择已创建的任意 agent；也可用 `zerocode -a <agent名称>` 直接进入该 agent 的聊天。
agent 名称不固定，不假设存在 `ops`，也不自动替你创建或切换 risk profile。

包装器与 init 共用已验证的 MMC 状态存储、HOME 和 `--config-dir`，
因此通过官方本地 Unix socket 连接同一 daemon，无需手工填写端口或会话文件路径。
已有 daemon 就连接它；没有运行时，由官方客户端启动临时 daemon。
临时 daemon 不是 procd 常驻服务；退出界面后是否继续后台运行遵循上游生命周期，
需要持续运行的渠道/定时任务应显式启用下面的 init 服务。

聊天由官方 daemon 默认启用的会话机制自动持久化；若用户已关闭持久化，本包不会强制开启。
使用 **Ctrl+S** 打开历史会话列表，
或在 Chat 中使用 **`/load-session`** 恢复已保存的聊天；**Ctrl+N** 新建会话。
自动保存不代表每次启动都自动选择上一次会话；新建会话也不会自动包含其他会话的内容。
已有 CLI `--session-state-file` JSON 不会自动导入 ZeroCode，会继续保留供原命令使用。
官方操作说明见固定版本的
[ZeroCode 文档](https://github.com/zeroclaw-labs/zeroclaw/blob/6c78ba59bce6a3d5079cf0c0310488770e264ad4/docs/book/src/zerocode/running.md)。

`zeroclaw agent -a <agent名称>` 仍保持官方独立 CLI 行为；包装器不偷偷添加会话文件参数。
直接运行卡上原始二进制或旧式 `run-test.sh` 不会得到本包的 ZeroCode 存储守卫。
裸 FAT 不适合 Unix socket 和持久化运行，请使用 ext4 或 `--fat-image`。
终端须支持交互式 TUI 和 UTF-8，中文显示依赖 SSH 客户端字体。
ZeroCode 和 daemon 是两个进程，128 MiB 路由器上应先观察内存、响应和网络稳定性，
不能仅凭 QEMU 通过就认定实际设备可用；不自动安装 swap 或放开网络访问。

### 可选的 init 常驻服务

仅希望在 SSH 中按需聊天时，无须先启用 init。需要常驻运行时再执行：

```sh
uci set zeroclaw.main.enabled='1'
uci commit zeroclaw
/etc/init.d/zeroclaw enable
/etc/init.d/zeroclaw start
logread -e zeroclaw
```

网关强制监听 `127.0.0.1:42617`，不添加 LAN/WAN 防火墙开放规则。
端口可通过 UCI 的 `zeroclaw.main.port` 修改。没有安装 systemd，
不要执行上游的 `zeroclaw service install`。
如需远程访问，应另行配置经过认证的隧道，不要直接开放公网端口。

## 目录和运维

| 路径 | 用途 |
| --- | --- |
| `/mnt/mmcblk0p1/zeroclaw/bin/zeroclaw` | 真正的 ARMv7 可执行程序 |
| `/mnt/mmcblk0p1/zeroclaw/bin/zerocode` | 官方 ARMv7 终端客户端 |
| `/mnt/mmcblk0p1/zeroclaw/config` | 上游配置目录，可能包含密钥 |
| `/mnt/mmcblk0p1/zeroclaw/home` | 隔离的 HOME / XDG 数据、缓存目录 |
| `/mnt/mmcblk0p1/zeroclaw/state.ext4` | 镜像模式：256 MiB ext4 普通文件 |
| `/mnt/mmcblk0p1/zeroclaw/state` | 镜像模式：loop 挂载点，内含 `config`、`home` |
| `/etc/config/zeroclaw` | 挂载路径、存储模式、FAT 兼容开关、服务开关、监听端口，不放 API Key |
| `/usr/bin/zeroclaw` | 挂载检查和路径设置包装器 |
| `/usr/bin/zerocode` | 共用存储检查、配置目录及 HOME 的终端入口 |
| `/etc/init.d/zeroclaw` | procd 开机启动、异常重启及日志接管 |

服务通过 `--verbose` 将事件同时输出到终端，由 procd 接管 stdout/stderr，
使用 `logread` 查看，不额外配置无限增长的卡内日志文件。
这不禁止上游的历史、数据库或诊断文件，仍需监控卡空间并定期备份。
挂载变化会触发服务重启；无卡时拒绝启动，不自动退回内置闪存。
拔卡前先 `/etc/init.d/zeroclaw stop`，不要依赖热拔卡保护数据库。
更新时复用安装步骤；回滚时安装保存的旧归档。内存卡不建议用作 swap。

首版服务与 SSH 引导一样以 **root** 身份运行，非沙箱；工具执行将拥有路由器权限。
不要给不可信用户访问，不要关闭上游配对及安全限制，不要配置无约束的命令执行。
在主路由上运行智能体仍有风险，备份固件配置及卡内数据，先小范围验证。

上机检查至少包括：`zeroclaw --version`、一次真实远程模型调用、
所选渠道收发、空闲及交互峰值内存、重启后挂载/自启、断网恢复，
并观察 Wi-Fi 和路由是否受影响。当前不承诺具体 RAM 或存储占用。

## APK 集成包（可选替代方式）

只适用于确认使用 APK 的目标固件。先把归档内的 `bin/zeroclaw`、`bin/zerocode` 放到
卡上 `zeroclaw/bin/` 并赋予执行权限，再安装**本仓库构建且已校验**的 APK。
该本地包未由 OpenWrt 官方密钥签名，仅对这次安装使用：

```sh
apk add --allow-untrusted ./zeroclaw-openwrt-*.apk
```

不要全局关闭签名检查。随后执行相同的 `zeroclaw quickstart` 和 UCI 启用步骤。
镜像模式须先用归档中的 `prepare-state-image.sh` 显式准备镜像，再设置
`uci set zeroclaw.main.storage_mode='image'; uci commit zeroclaw`；
不要直接创建配置在裸 FAT 上，不要指望 APK 自动创建或格式化镜像。
卸载集成包不会删除卡上的配置、密钥或数据库；这些数据需要自行安全管理。

本仓库脚本使用 MIT 许可；上游程序的许可文件随归档附带。
