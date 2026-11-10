# 本地编译全流程（Windows + WSL2 + Docker-OSX 的 macOS 客户机）

> **本文档记录的是作者本机的编译链路**，含本机回环地址、本地虚拟机账号与宿主代理地址。
> 这些值只在本机有意义（端口全部绑在 `127.0.0.1`），但如果你 fork 本项目并公开，请自行判断是否脱敏。
> 真正的「通用」构建步骤只有三步：`xcodegen generate` → `xcodebuild` → 把 `.app` 塞进 `Payload/` 打成 zip，见 §5。

---

## 1. 为什么用本机编译

本仓库**不使用 GitHub Actions**（仓库级 Actions 已关闭，workflow 状态为 `disabled_manually`）。
原因很直接：私有仓库的 macOS runner 按 10 倍速率消耗免费额度，公开仓库虽免费却会把构建细节全部公开；
更关键的是——**这台 PC 上已经有一台装好 Xcode 的 macOS 虚拟机**，本机出包比排队等 runner 更快、更可控。

> 历史产物仍可通过 `gh run download <run-id>` 取回（关闭 Actions 不影响已归档 artifacts 的下载）。
> 如需重新启用 CI：`gh workflow enable "iOS Build (unsigned)"` + 重新打开仓库级 Actions 权限。

## 2. 环境基线

```
Windows 11 宿主机（Intel i7-11700 / 31.7 GB）
│
├─ WSL2 Ubuntu-24.04（D:\Ubuntu2404\ext4.vhdx，Docker 29）
│   └─ ~/Docker-OSX/tahoe/                    ← QEMU/KVM 虚拟机定义与磁盘
│        └─ data/tahoe-x86/mac_hdd_ng.qcow2   ← 整台 Mac 就是这一个文件（54 GB）
│
└─ I:\APP\livecontainer_dev\                  ← 编译工装（脚本、缓存）
     ├─ build-seeingcalendar.sh               ← 本项目的一键脚本
     ├─ tools/cal-*.sh                        ← 客户机侧工装
     └─ cache/xcodegen-2.46.0.zip             ← 离线缓存

I:\APP\看见Calendar_dev\                       ← 本仓库（源码）
```

| 层 | 值 |
|---|---|
| 客户机系统 | macOS 26.7.2 (25G332) · x86_64 · 4 vCPU · 13.7 GB RAM · 剩 ~73 GB |
| Xcode | 26.6 (17F113) @ `/Applications/Xcode.app` |
| iOS SDK | 26.5（`iphoneos26.5`）；另装 iOS 26.5 模拟器运行时（actool 编译资源需要） |
| XcodeGen | 2.46.0 @ `/usr/local/bin/xcodegen`（**不用 Homebrew**，见 §6） |
| 工具链 | Apple clang 21 / swiftc 6（工程为 `SWIFT_VERSION 6.0` + `SWIFT_STRICT_CONCURRENCY complete`） |
| 连接 | `ssh -p 50922 admin@127.0.0.1`（免密钥 + 免密 sudo，只绑回环） |
| 出网 | 客户机经 `http://172.18.208.1:7890`（宿主 Clash）出网；**直连 github.com 会超时** |

> 环境搭建、VM 参数（`vm.conf`）、卡死恢复与看门狗等通用说明在 `I:\APP\livecontainer_dev\BUILD-LOCAL.md`。

## 3. 一条命令

```bash
wsl -d Ubuntu-24.04 -- bash /mnt/i/APP/livecontainer_dev/build-seeingcalendar.sh
```

七步全自动，实测 **60~70 秒**（增量编译；冷启动全量约 90 秒）：

| 阶段 | 动作 |
|---|---|
| 0 | **探活/起 VM** —— SSH 不通就重启容器并轮询恢复（VM 会周期性卡死，这一步是必需的） |
| 1 | **同步源码** —— 工作区快照（排除 `.git artifacts .worktrees UI_screenshot tmp build`）→ 客户机 `~/seeingcalendar`；保留 `build` 增量缓存；commit + 脏文件哈希未变则跳过 |
| 2 | **工装自愈** —— 客户机缺 `xcodegen` 就装（WSL 侧取件 → scp → 安装） |
| 3 | **门禁** —— 10 项，**不过就停在编译前** |
| 4 | **编译** —— `xcodegen generate` + `xcodebuild` Release/unsigned；中途 VM 卡死会自动恢复并续编 |
| 5 | **打包** —— `Payload/` + `zip` 成未签名 IPA，dSYM 单独打包，全部拉回 Windows |
| 6 | **摘要** —— commit / 工作树状态 / 版本号 / Xcode / SDK / IPA sha256 |

开关：

```bash
SKIP_SYNC=1     # 忽略 stamp，强制重新同步源码
SKIP_GATES=1    # 跳过 10 项门禁（只在明确知道门禁无关时用）
SKIP_BUILD=1    # 只重新打包（用客户机上一次的编译产物）
NO_PULL=1       # 不把产物拉回 Windows
BUILD_NUMBER=N  # 指定 CFBundleVersion（默认当天日期 YYYYMMDD）
```

## 4. 脚本清单

| 文件 | 位置 | 用途 |
|---|---|---|
| `build-seeingcalendar.sh` | `livecontainer_dev/` | 一键：上面那七步 |
| `cal-gates.sh` | `livecontainer_dev/tools/` | 客户机侧跑 10 项门禁 |
| `cal-package.sh` | 同上 | 客户机侧打未签名 IPA + dSYM |
| `cal-install-xcodegen.sh` | 同上 | 把 `/tmp/xcodegen.zip` 装进 `/usr/local` |
| `gvm.sh` | 同上 | 在客户机执行一条命令：`bash gvm.sh 'sw_vers'` |
| `grun.sh` | 同上 | 把本地脚本管道送进客户机执行（免引号地狱） |

## 5. 分步手动流程（等价于脚本做的事）

```bash
# ---------- 在 WSL 里 ----------
cd ~/Docker-OSX/tahoe && ./tahoe.sh            # 起 VM（已装好 macOS，开机直进系统）
ssh -p 50922 admin@127.0.0.1                   # 连进客户机（也可用 gvm.sh 单条执行）

# 同步源码
cd /mnt/i/APP/看见Calendar_dev
tar cf /tmp/cal.tar --exclude=./.git --exclude=./artifacts --exclude=./.worktrees \
  --exclude=./UI_screenshot --exclude=./build --exclude=./tmp .
scp -P 50922 /tmp/cal.tar admin@127.0.0.1:/tmp/
ssh -p 50922 admin@127.0.0.1 'mkdir -p ~/seeingcalendar && cd ~/seeingcalendar && \
  find . -maxdepth 1 -mindepth 1 ! -name build -exec rm -rf {} + && tar xf /tmp/cal.tar'
```

```bash
# ---------- 在客户机里 ----------
cd ~/seeingcalendar

# ① 门禁（10 项）—— 从 WSL 侧管道送入
ssh -p 50922 admin@127.0.0.1 'bash -s' < /mnt/i/APP/livecontainer_dev/tools/cal-gates.sh

# ② 生成工程（仓库里没有 .xcodeproj，它由 project.yml 生成）
rm -rf SeeingCalendar.xcodeproj
/usr/local/bin/xcodegen generate --spec project.yml

# ③ 编译（Release · 未签名 · 真机 arm64）
xcodebuild -project SeeingCalendar.xcodeproj -scheme SeeingCalendar \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CURRENT_PROJECT_VERSION=1 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" build

# ④ 打包成未签名 IPA
rm -rf Payload && mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/SeeingCalendar.app Payload/
zip -qry SeeingCalendar-unsigned.ipa Payload
```

```bash
# ---------- 回 Windows 取件 ----------
scp -P 50922 admin@127.0.0.1:~/seeingcalendar/SeeingCalendar-unsigned.ipa \
  /mnt/i/APP/看见Calendar_dev/artifacts/local-v1.0.36/
```

**通用三步**（换成任何一台装了 Xcode 的 Mac，只要先把 `xcodegen` 装上）：
`xcodegen generate` → `xcodebuild` → 把 `SeeingCalendar.app` 塞进 `Payload/` 打成 zip、改名 `.ipa`。

## 6. 关于 XcodeGen（客户机上没有 Homebrew）

工程文件是**生成**的：仓库里只有 `project.yml`，`.xcodeproj` 在 `.gitignore` 里。

```bash
# WSL 侧取件（能走宿主代理）
export http_proxy=http://172.18.208.1:7890 https_proxy=$http_proxy
curl -sL -o cache/xcodegen-2.46.0.zip \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip

# 送进客户机并安装（zip 自带 install.sh，装到 /usr/local，与 Homebrew 无关）
scp -P 50922 cache/xcodegen-2.46.0.zip admin@127.0.0.1:/tmp/xcodegen.zip
ssh -p 50922 admin@127.0.0.1 'bash -s' < tools/cal-install-xcodegen.sh
```

装在 macOS 系统盘的 `/usr/local`，**重启 VM 容器不会丢**（丢的只有 `/tmp`）。

## 7. 门禁（10 项）

编译前全部跑一遍，任何一项不通过就停在编译前。这些脚本是**文本 / 数学 / 状态机级断言**，
负责把「已在真机上验证过的行为约定」钉死在源码里 —— 没有它们，任何一次改动都可能悄悄推倒旧结论。

| 门禁 | 断言量 | 钉住什么 |
|---|---|---|
| `verify_observation_semantics` | — | `@Observable` 语义（基线探针） |
| `verify_pencilkit_stroke_semantics` | — | PencilKit 笔迹语义（基线探针） |
| `swift_lint.py` | — | 机械体检 + 已知陷阱：括号平衡 / 重复声明 / Swift 6 参数标签 / 静态属性隔离 |
| `gate_preflight.py` | — | **门禁自身**的笔误：断言接收变量是否在作用域内、字面量是否真能在目标文件里找到 |
| `verify_transform_math` | 225 | 画布变换不变量（位移比值 = 1、锚点不动、旋转中心不动、预览与世界一致） |
| `verify_holiday_table` | 25 | 真实内置 ICS 与时区不变量（班休样式错一天即失败） |
| `verify_thumbnail_lifecycle` | 85 | 缩略图并发合并 / 非破坏提交 / 代次纪律 |
| `verify_ui_regressions` | 101 | 月份选择器 / 锁角标 / 横屏键盘压缩 / 网格错行 |
| `verify_subscription_management` | 91 | 内置置底 / 不可删除 / 多选作用域真的生效 |
| `verify_undo_history` | 16（穷举 37448 条撤销序列） | 撤销的笔画不会复活 / 检查器有牙 / PencilKit 集成单一引擎 |

另外两个手动工具脚本：`verify_vcal_layout.py`（按 Swift 写入布局重建 `.vcal` 容器再交给标准 ZIP 读取器解析）、
`make_app_icon.py`（纯 numpy + zlib 生成 1024 图标，无需 Pillow）。

> 门禁以 `swift scripts/verify_*.swift` 直接运行（语言模式为 Swift 5 driver 默认），而 App target 是 Swift 6：
> **门禁拿不到数据竞争诊断**，所以凡是需要隔离担保的地方，门禁里都用显式断言写死
> （例：`verify_thumbnail_lifecycle` 的 `verifyStoreIsolation`）。

## 8. 产物

```
artifacts/local-v1.0.36/
├── SeeingCalendar-unsigned.ipa     # 未签名，交给 AltStore / SideStore / Sideloadly 重签
├── SeeingCalendar-dSYMs.zip
├── SeeingCalendar-build.log
└── SeeingCalendar-gates.log
```

* 目录名带 `local-` 前缀，是为了与 `artifacts/v<版本>/`（历史上 CI 的产物归档）区分，两套可并存做回归对照；
* `artifacts/` 不纳入版本控制（见 `.gitignore`）；
* 免费 Apple ID 自签有效期 7 天，到期用 AltStore / SideStore 刷新即可。

## 9. 故障处理

| 症状 | 含义 | 处理 |
|---|---|---|
| `ssh: banner exchange` 超时 / QMP 状态 `paused` | VM 内核 livelock（高负载下的已知问题） | 脚本会自动重启容器；手工：`docker rm -f $(docker ps -q -f ancestor=docker-osx:tahoe)` 后再 `./tahoe.sh`。**增量续编不丢进度** |
| 客户机里 `curl github.com` 超时 | SSH 会话没有代理变量 | 一律 WSL 侧经 `172.18.208.1:7890` 下载后 `scp` 进去（反直觉的是 `api.github.com` 反而通） |
| `xcodegen: command not found` | 客户机重装/新装后缺工装 | 跑一次一键脚本（第 2 阶段会自愈），或按 §6 手工装 |
| `No available simulator runtimes` | actool 需要 iOS 运行时组件 | 已装 iOS 26.5 runtime；注意它**不在** `CoreSimulator/Profiles/Runtimes`，而在 `CoreSimulator/Volumes`，用 `xcrun simctl list runtimes` 查 |
| 生成结果与 `project.yml` 不一致 | 客户机上有上一次的 `.xcodeproj` | 编译前 `rm -rf SeeingCalendar.xcodeproj`（脚本已内置） |
| 门禁失败但看不出原因 | 门禁脚本自己的笔误也会算失败 | 先跑 `python3 scripts/gate_preflight.py`，它专门拦「断言写错文件 / 变量越界」 |

### 脚本编写时的一个硬约束

给客户机写的 bash 脚本里，**变量后紧跟中文全角字符时必须写 `${VAR}`**：
macOS 的 bash 在非 UTF-8 locale 下会把多字节字节并入标识符，`$LOG）` 会被解析成变量名 `LOG）`，
直接报 `unbound variable`。自检（期望无输出）：

```bash
grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' tools/*.sh build-*.sh
```

## 10. 验收边界

| 环节 | 手段 | 状态 |
|---|---|---|
| 编译 / 链接 / 打包 | 本机 macOS VM + `xcodebuild`（Release, iOS SDK 26.5） | ✅ 0 error（3 warning） |
| 10 项行为门禁 | 6 个 `verify_*.swift --strict` + 2 个语义探针（swift）+ `swift_lint.py` / `gate_preflight.py` | ✅ 全过 |
| 产物结构 | 解包 IPA 校验 Bundle ID / UTI / 方向 / 权限文案 / 内置 ICS | ✅ 通过 |
| 手势延迟 / PencilKit 手感 / SwiftData 持久化 | **需真机** | ⚠️ 待上 iPad 验收 |
