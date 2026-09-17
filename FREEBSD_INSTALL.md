# 在 FreeBSD 下安装 opencode 手册（fb250 / 192.168.0.150 实战验证）

> 本文档基于 `workbuddy@192.168.0.150`（主机名 fb250，FreeBSD 15.1-RELEASE，amd64，i3-5010U / Broadwell 支持 AVX2）的真实调试过程整理，每一步均可复现。
> 仓库：`~/github/opencode-freebsd`，bun 路径：`/home/skywalk/.bun/bin/bun`。

---

## 0. 最关键的事实（先读，否则会踩所有坑）

1. **opencode 的 CLI 不是 TypeScript 源码直接跑，而是一个「薄包装 + 平台预编译二进制」结构。**
   `packages/opencode/bin/opencode` 只是个 5KB 的包装脚本，它根据你当前的 `platform/arch` 去 `node_modules/` 里找一个真正的预编译二进制包（如 `opencode-linux-x64-baseline`），然后 `spawn` 它。真正的 CLI 是那个 183MB 的二进制（`opencode-linux-x64-baseline/bin/opencode`，本身是一个 Bun standalone 可执行文件，`Bun v1.3.14 (Linux x64 baseline)`）。

2. **这台机器上的 bun 是 Linux x64 二进制，跑在 FreeBSD 的 Linuxulator（Linux 兼容层）下。**
   `bun -e 'console.log(process.platform, process.arch)'` 输出 `linux x64`，不是 `freebsd`。
   所以 opencode 整套都按「Linux x64」环境来解析依赖——所有 `linux-x64` 平台专属包（含从 GitHub 拉的二进制）都会被尝试下载。

3. **网络现状（山东家庭实验室）：**
   - `registry.npmjs.org`：**极慢**（实测 25 秒只下完 169MB 字体包的 1.8MB，约 70KB/s，实质不可用）。
   - 淘宝镜像 `registry.npmmirror.com`：**飞快**（0.45 秒响应 302）。✅ 用它。
   - `github.com`：返回 200 但耗时 >12 秒（被 Cloudflare/限速卡死），从 GitHub releases 拉预编译二进制（如 `@pagefind/linux-x64`、`app-builder-bin`）会**永久卡死**。

4. **FreeBSD 没有 `/proc`**，因此 opencode 的 `supportsAvx2()` 读 `/proc/cpuinfo` 会抛错返回 `false` → 自动选用 **`opencode-linux-x64-baseline`**（不需要 AVX2 的变体，兼容性最好，i3-5010U 也能跑）。

5. **Linuxulator 的 SSH 会话可能继承 Windows 风格的 `HOME`（如 `/c/Users/skywalk`）**，导致 opencode 建数据目录 `.local` 时报 `EACCES`。必须强制 `HOME=/home/workbuddy`。

---

## 1. 前置条件检查

```sh
# 1) 系统 / CPU
uname -m                                  # 期望 amd64
freebsd-version                           # 期望 15.x
sysctl -n hw.model                        # 期望含 AVX2 的 x86_64（baseline 二进制则无 AVX2 也能跑）

# 2) Linuxulator 必须已加载（bun 是 Linux 二进制，没它跑不起来）
kldstat | grep -E 'linux'                 # 应有 linux.ko / linux64.ko
ls /compat/ubuntu >/dev/null 2>&1 && echo "linuxulator OK" || echo "NEED linuxulator"

# 3) bun 已安装
/home/skywalk/.bun/bin/bun --version      # 实测 1.4.2（package.json 写的是 1.3.14，高版本也能用）

# 4) 构建工具（仅当需要从源码编译时才用，常规安装不需要）
clang --version; python3 --version; gmake --version
```

如果 Linuxulator 没加载：

```sh
sudo kldload linux64          # 加载 Linux 兼容层
# 并确保 /compat/ubuntu（或 /compat/linux）存在；通常来自 linux_base / ubuntu 基镜像
```

---

## 2. 你遇到的两个原始报错，根因是什么

| 现象 | 根因 |
|---|---|
| `error: install script from "tree-sitter-powershell" exited with 1` | `tree-sitter-powershell` 是 `trustedDependencies` 里的包，bun 会执行它的 install 脚本去**编译原生 tree-sitter 绑定**；在 FreeBSD/Linuxulator 下编译失败 → 硬报错退出。但它是**语法高亮用的可选语法分析器**，CLI 本体不依赖它。 |
| 第二次卡在 `@pagefind/linux-x64` / `app-builder-bin` | 这两个（及 electron 相关）是**平台专属预编译二进制**，从 **GitHub releases** 拉取；而本机 `github.com` 实质不可达 → 下载永久卡死。它们分别用于「文档站搜索」和「桌面版打包」，**跑 CLI 完全用不到**。 |

> 本质：bun 自认 Linux → 拉全量 `linux-x64` 平台包；其中 GitHub 源的那些卡死，tree-sitter 那个编译失败。

---

## 3. 经过验证的可复现安装步骤

> 核心三板斧：① 用 npmmirror 镜像加速 ② `--omit=optional` 跳过所有 GitHub 源平台包 ③ `--ignore-scripts` 跳过 tree-sitter 编译失败。

```sh
cd ~/github/opencode-freebsd

# 步骤 A：安装主依赖（跳过 optional / 跳过 install 脚本 / 走镜像）
/home/skywalk/.bun/bin/bun install \
  --registry https://registry.npmmirror.com \
  --ignore-scripts \
  --omit=optional
#   → 实测 2278 个包，42.87 秒装完

# 步骤 B：单独补装 opencode 的平台 CLI 二进制
#   （它正是被 --omit=optional 跳过的那一类平台包，但 CLI 必需）
#   版本号必须与仓库一致，查看：grep '"version"' packages/opencode/package.json
/home/skywalk/.bun/bin/bun add opencode-linux-x64-baseline@1.18.18 \
  --registry https://registry.npmmirror.com \
  --omit=optional \
  --ignore-scripts
#   → 会在 node_modules/opencode-linux-x64-baseline/bin/opencode 落下 183MB 二进制
```

### 为什么是 `opencode-linux-x64-baseline` 而不是 `opencode-linux-x64`

包装脚本 `packages/opencode/bin/opencode` 的解析逻辑（`platform=linux, arch=x64`）：

- 先检测 AVX2：`supportsAvx2()` 读 `/proc/cpuinfo` → FreeBSD 无 `/proc` → 返回 `false` → 选 **baseline** 变体。
- 再检测 libc：`ldd --version` 含 `musl` 才选 musl；本机是 glibc → 非 musl。

所以查找顺序第一候选就是 `opencode-linux-x64-baseline`。如果你机器的 `bun` 二进制本身需要 AVX2 而 CPU 不支持，请用 baseline（本机 i3-5010U 有 AVX2，两种都能跑，baseline 更稳）。

### （可选）node-pty 的真相——**不用管**

`fix-node-pty` 这个 postinstall 脚本只是给 `node-pty/prebuilds/*/spawn-helper` 加可执行位，而 `@lydell/node-pty` 是给 **Node 运行时**用的。opencode 的 Bun 二进制走的是 `packages/core/src/pty/pty.bun.ts` → 导入 **`bun-pty`**（Bun 原生 pty，被打包进 standalone 二进制里）。所以：

- `--ignore-scripts` 跳过 `fix-node-pty` **不影响终端功能**；
- `@lydell/node-pty` 缺预编译二进制也**不影响**，因为根本不用它。

---

## 4. HOME 路径坑（否则一启动就 EACCES）

现象：`opencode --help` 报 `EACCES: permission denied, mkdir '/home/workbuddy/.local'`（或 `mkdir '/c'`）。

原因：Linuxulator/SSH 会话的 `HOME` 可能是 Windows 路径（`/c/Users/skywalk`），opencode 按这个路径建数据目录失败。

**解法**：用下面的包装脚本启动（已放在仓库根目录 `opencode.sh`，会无条件把 `HOME` 钉到 `/home/workbuddy` 并预建 `.local` 目录树）。

```sh
cat > ~/github/opencode-freebsd/opencode.sh <<'WRAP'
#!/bin/sh
# opencode launcher for FreeBSD (runs under Linuxulator)
# 强制真实 Unix HOME，避免 Linuxulator 继承 Windows HOME 导致 EACCES
export HOME=/home/workbuddy
[ -d "$HOME/.local" ] || mkdir -p "$HOME/.local/share" "$HOME/.local/state" "$HOME/.local/cache" "$HOME/.config" 2>/dev/null
exec /home/workbuddy/github/opencode-freebsd/node_modules/opencode-linux-x64-baseline/bin/opencode "$@"
WRAP
chmod +x ~/github/opencode-freebsd/opencode.sh
```

另外建议把下面这行加进 `~/.bashrc`（修复交互式 SSH 会话的 HOME）：

```sh
echo 'export HOME=/home/workbuddy' >> ~/.bashrc
```

---

## 5. 验证安装

```sh
cd ~/github/opencode-freebsd

# 方式一：直接用包装脚本（推荐）
./opencode.sh --version          # 期望 1.18.18
./opencode.sh --help             # 应看到 opencode ASCII logo + 命令列表
./opencode.sh mcp --help         # 子命令路由正常

# 方式二：手动设 HOME 后跑（等价）
export HOME=/home/workbuddy
/home/skywalk/.bun/bin/bun packages/opencode/bin/opencode --version
```

看到 logo 和命令列表即表示安装成功。

### 启动 TUI / 实际使用

```sh
./opencode.sh                      # 启动 TUI（需要终端 + 配置了 AI provider key）
./opencode.sh run "把当前目录里最大的文件列出来"   # 非交互跑一条任务
./opencode.sh serve                # 启动无头 server（--hostname 默认 127.0.0.1）
```

> 终端功能由 Bun 内置 `bun-pty` 提供，在正常 Linuxulator 下可用。首次使用需在 `~/.config/opencode/` 配置 provider（如 DeepSeek / OpenAI 兼容接口）的 API key。

---

## 6. 排错速查表

| 症状 | 原因 | 修复 |
|---|---|---|
| `install script from "tree-sitter-powershell" exited with 1` | FreeBSD 下编译 tree-sitter 原生绑定失败 | 加 `--ignore-scripts`（CLI 不需要它） |
| 卡在 `@pagefind/linux-x64` / `app-builder-bin` | 这两个包从 GitHub releases 下载，github 本机不可达 | 加 `--omit=optional` 跳过；CLI 用不到 |
| 整体下载极慢 / 几十分钟不动 | 默认走 `registry.npmjs.org`（~70KB/s） | 加 `--registry https://registry.npmmirror.com` |
| `bun install` 卡在 `[17]` 长时间无进展 | 某个大包（如 `@ibm/plex` 169MB）在慢链路上慢慢下 | 换 npmmirror 后几十秒完成 |
| `EACCES: mkdir '/home/workbuddy/.local'` 或 `mkdir '/c'` | `HOME` 是 Windows 路径 | 用 `opencode.sh` 包装脚本（强制 `HOME=/home/workbuddy`） |
| `failed to install the right version ... opencode-linux-x64 ...` | 平台 CLI 二进制被 `--omit=optional` 跳过了 | 单独 `bun add opencode-linux-x64-baseline@<版本>` |
| `command not found: bun` | 用 `bun run` 包脚本时 bun 不在 PATH | 用绝对路径 `/home/skywalk/.bun/bin/bun`，或 `export PATH=/home/skywalk/.bun/bin:$PATH` |
| 启动 TUI 后终端/ shell 异常 | `bun-pty` 在 Linuxulator 下的问题（罕见） | 确认 linuxulator 正常；用 `opencode.sh run "..."` 走无头模式验证 |

---

## 7. 一键复现（完整流程）

```sh
ssh workbuddy@192.168.0.150
cd ~/github/opencode-freebsd

# 1. 主依赖
/home/skywalk/.bun/bin/bun install --registry https://registry.npmmirror.com --ignore-scripts --omit=optional

# 2. 平台 CLI 二进制（版本号以 packages/opencode/package.json 的 version 为准）
/home/skywalk/.bun/bin/bun add opencode-linux-x64-baseline@1.18.18 --registry https://registry.npmmirror.com --omit=optional --ignore-scripts

# 3. 启动（脚本会自动修 HOME）
./opencode.sh --version
./opencode.sh            # 进 TUI
```

---

## 8. 与之前 0.88 机器「CPU 太老」的对照

- **0.88**：CPU 不满足 bun/opencode 运行条件（大概率是 bun 的 Linux x64 二进制需要 AVX2，而老 CPU 不支持）→ 放弃。
- **fb250（192.168.0.150）**：i3-5010U（Broadwell）支持 AVX2，bun + opencode 均能运行；且 opencode 自动选用 `baseline` 变体，即使无 AVX2 也可启动。

---

## 9. 运行期坑：能启动、能回第一句，之后界面卡死无法输入

### 症状

启动 TUI，输入第一句话，**能看到模型回应**，然后整个界面冻结，敲第二句话毫无反应。

### 根因

现场把卡死的进程打出来就一目了然：

```sh
pgrep -fl opencode ; pgrep -fl git
```

```
22208 git clone --depth 100 -- https://github.com/Effect-TS/effect-smol.git \
        /home/workbuddy/.local/share/opencode/repos/github.com/Effect-TS/effect-smol
22209 git remote-https origin https://github.com/Effect-TS/effect-smol.git
22225 git index-pack --stdin --fix-thin --keep=fetch-pack 22208
22183 .../node_modules/opencode-linux-x64-baseline/bin/opencode
```

**因为你在 opencode 自己的源码仓库里跑 opencode。** 该仓库自带 `.opencode/opencode.jsonc`，里面定义了一个 Git 型 reference：

```jsonc
"references": {
  "effect": {
    "repository": "github.com/Effect-TS/effect-smol",   // ← 会自动 git clone
    "description": "Use for Effect v4 and effect-smol implementation details",
  },
  ...
}
```

opencode 对每个 Git 型 reference 会调 `cache.ensure({ refresh: true })`（见 `packages/core/src/reference.ts`）去 `git clone`。
而本机 **github.com 实质不可达/极慢**（见第 6 节），于是 clone 永久挂起，把界面拖死。
历史上多次出现 `failed to materialize reference ... OpenSSL SSL_read: unexpected eof` 就是同一个坑。

### 修复

```sh
cd ~/github/opencode-freebsd

# 1) 备份
cp .opencode/opencode.jsonc /tmp/opencode.jsonc.bak

# 2) 删掉 "effect": { ... }, 这一段（BSD sed，-i 必须带后缀参数）
sed -i "" -e '/"effect": {/,/},/d' .opencode/opencode.jsonc

# 3) 清掉可能残留的半成品 clone
rm -rf ~/.local/share/opencode/repos/github.com/Effect-TS

# 4) 让 git 忽略这个本地改动，避免污染工作区
git update-index --assume-unchanged .opencode/opencode.jsonc
```

修复后该文件只剩无害的 local reference：

```jsonc
"references": {
  "opencode-local": { "path": "~/.local/share/opencode", ... },
}
```

### 验证

```sh
./opencode.sh run 'hi'
pgrep -fl 'git clone' || echo "NO_GIT_CLONE"   # ← 应当没有任何 git clone
```

实测输出：

```
NO_GIT_CLONE_GOOD
... Hi! What can I help you with?
... exiting loop / disposing instance    ← 正常退出，不再挂起
```

### 更省事的做法

**日常用请换一个空目录**，不要在 opencode 源码仓库里启动：

```sh
mkdir -p ~/work/my-project && cd ~/work/my-project
~/github/opencode-freebsd/opencode.sh
```

空目录没有自带的 agent / skills / references，不受 GitHub 阻塞影响。
确实要改 opencode 源码时，再回到 `~/github/opencode-freebsd` 并按上面步骤处理。

---

## 10. Free 模型到底哪些能用（本机实测，2026-09-18）

测试中一个关键事实：**不需要登录**。`packages/opencode/src/provider/provider.ts` 在未登录时会降级：

```ts
const ok = hasKey || auth(input.id) || config.provider?.["opencode"]?.options?.apiKey
if (!ok) { 只保留 cost.input === 0 的模型 }
return { autoload: ..., options: ok ? {} : { apiKey: "public" } }   // ← 免费走 "public" key
```

所以 `opencode auth list` 显示 `0 credentials` **不是**报错原因，别去折腾 OAuth（何况无 GUI 环境登录很困难）。

### 实测结果

| 模型 | 结果 |
|---|---|
| `nemotron-3-ultra-free` | ✅ 可用 |
| `ling-3.0-flash-fin-free` | ✅ 可用 |
| `mimo-v2.5-free` | ✅ 可用 |
| `big-pickle`（**默认**） | ✅ 可用（推荐直接用） |
| `deepseek-v4-flash-free` | ❌ `Model not found: opencode/deepseek-v4-flash-free` |
| `hy3-preview-free` / `hy3-free` | ❌ 服务端已下线：`Model hy3-preview-free is not supported` |

> **重要**：客户端可用模型取自本地缓存 `~/.cache/opencode/models.json`（来自 models.dev，本机拉取要 12～25s，很慢）。
> 这份缓存比服务端落后——里面列了 32 个 free 模型，而服务端 `https://opencode.ai/zen/v1/models` 实际只提供 7 个，
> 于是选到 `deepseek-v4-flash-free` / `hy3-*` 这类会直接失败，UI 上表现为 "interrupted"。
> 注意不要用裸 `curl` 去测这个词表——会得到误导性的
> `FreeTierError: OpenCode's free tier can only be used from within OpenCode`（403）。

### 指定模型

```sh
./opencode.sh run -m opencode/nemotron-3-ultra-free '你的问题'
```

TUI 里出现 interrupted 时，**换上面标 ✅ 的模型**即可，不必重新登录。

---

## 11. 其他环境细节

- **本机没有 IPv6 默认路由**，但 DNS 会返回 AAAA 记录，导致连接先撞 `No route to host` 再回退 IPv4，每个请求多花约 0.7s（`opencode.ai` 双栈 1.68s vs 纯 IPv4 0.94s）。它有 Happy Eyeballs 能自愈，一般不用管；若某台机器在 Linuxulator 下回退失效，可在 `/etc/hosts` 给相关域名钉死 IPv4。
- Zen 的 API 基址是 `https://opencode.ai/zen/v1`（OpenAI 兼容），可用它做连通性自查。

> 结论：在 FreeBSD 上跑 opencode 的硬性门槛 = **「能加载 Linuxulator」+「CPU 支持 AVX2（或坚持用 baseline 二进制）」+「能访问 npm 镜像（不要直连 npmjs/github）」**。满足这三点即可。
