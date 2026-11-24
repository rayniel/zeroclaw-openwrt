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

成功后下载 Actions artifact，其中包含：

| 文件 | 用途 |
| --- | --- |
| `zeroclaw-0.9.0-openwrt-ipq4019.tar.gz` | ARMv7 程序、安装器和启动脚本 |
| `zeroclaw-openwrt-*.apk` | 仅启动脚本、UCI 和 CLI 包装器的小型 OpenWrt 集成包 |
| `SHA256SUMS` | 归档和 APK 的校验值 |
| `*-info.txt` | 上游提交、特性、工具链和 ELF/CLI 检查记录 |

**APK 不包含大体积的 ZeroClaw 程序**，以免占满内置 overlay。
首版推荐使用下面的归档安装器；APK 为需要包管理器管理集成文件的用户提供，
不要同时使用两种方式管理相同的 `/etc`、`/usr` 文件。
没有配置自动追踪上游、自动发布 Release 或自动安装到路由器。

## 安装到 MMC 内存卡

卡须已稳定挂载到 `/mnt/mmcblk0p1`，**推荐使用 ext4** 等支持 Linux 权限的文件系统，
且不是只读或 `noexec` 挂载。**不要直接格式化已有卡**，先确认并备份内容。
C10 只描述顺序写入等级；随机写入性能、健康和寿命仍需实际观察。
默认拒绝 FAT/exFAT；只有下面的显式兼容模式允许 vfat/exFAT。
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
已有 UCI 配置除挂载路径、FAT 兼容开关及启用状态外保留；已有模型密钥和运行数据不会覆盖。
如需变更挂载点，传入 `sh unpack/install.sh /你的/挂载点`（允许末尾 `/`）；
需同时自行保证 OpenWrt 的持久挂载配置正确。

### vfat/exFAT 显式兼容模式

为了保留电脑直接读写能力，可以使用 vfat 或 exFAT，但**不保证 ZeroClaw 全功能正常**。
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

使用引导配置远程模型提供商、模型及 API Key。不要将密钥放进仓库、
Actions 输入或日志。配置、HOME、默认工作数据应留在卡上；
如果引导或自定义配置要求选择工作区，也应明确指定卡内路径。
启动前检查配置中是否有指向 `/root`、内置 overlay 或其他位置的绝对路径。

确认前台命令可用后，启用常驻服务：

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
| `/mnt/mmcblk0p1/zeroclaw/config` | 上游配置目录，可能包含密钥 |
| `/mnt/mmcblk0p1/zeroclaw/home` | 隔离的 HOME / XDG 数据、缓存目录 |
| `/etc/config/zeroclaw` | 挂载路径、FAT 兼容开关、服务开关、监听端口，不放 API Key |
| `/usr/bin/zeroclaw` | 挂载检查和路径设置包装器 |
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

只适用于确认使用 APK 的目标固件。先把归档内的 `bin/zeroclaw` 放到
卡上 `zeroclaw/bin/zeroclaw` 并赋予执行权限，再安装**本仓库构建且已校验**的 APK。
该本地包未由 OpenWrt 官方密钥签名，仅对这次安装使用：

```sh
apk add --allow-untrusted ./zeroclaw-openwrt-*.apk
```

不要全局关闭签名检查。随后执行相同的 `zeroclaw quickstart` 和 UCI 启用步骤。
卸载集成包不会删除卡上的配置、密钥或数据库；这些数据需要自行安全管理。

本仓库脚本使用 MIT 许可；上游程序的许可文件随归档附带。
