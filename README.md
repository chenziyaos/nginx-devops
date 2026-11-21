# nginx-devops

一套基于 nginx 1.31.9 源码的中文教程，用来弄清 nginx 的配置在源码里实际怎么生效，分为运维篇（13 章）和开发篇（10 章）。每章的结论都配有一个可以在本机复现的实验，引用的源码片段逐行核对过 1.31.9 的源码。适合两类读者：一类要配置和排查线上 nginx，另一类要读 nginx 源码或者自己写模块。

这里不是 nginx 官方文档的翻译，也不覆盖全部指令。每章挑一个主题，讲清楚 nginx 在源码里实际怎么做，以及默认值和容易误解的行为。2018 年的旧版教程保留在 tag [`legacy-2018`](https://github.com/chenziyaos/nginx-devops/tree/legacy-2018)。

## 快速开始

需要 C 编译器、`make`、`git`、`curl`、Python 3，以及 OpenSSL 3 和 PCRE2 的开发文件。macOS 上用 Homebrew 装 `openssl@3` 和 `pcre2`，`tools/build.sh` 会自动找到它们。

```bash
git clone https://github.com/chenziyaos/nginx-devops.git
cd nginx-devops
tools/build.sh                     # 拉取 release-1.31.9，编译到 ./.nginx，不需要 root
tools/verify_labs.sh ops-09        # 运行运维篇 09 的实验，和章节里引用的输出逐行比对
```

`tools/build.sh` 把源码克隆到 `.nginx-src/release-1.31.9`，打开 debug 日志、stream、HTTP/2、HTTP/3 等模块，再把 `modules/` 下的 hello 模块编成动态模块，最后安装到 `.nginx/` 并打印 `nginx -V`；在一台 Apple Silicon 的 Mac 上全程约 4 分钟（含从 GitHub 克隆 nginx 源码）。实验通过时最后两行是：

```text
PASS ops-09
1/1 labs match
```

实验的完整输出在 `labs/ops-09/out/actual.txt`，章节里引用的是 `labs/ops-09/expected.txt` 的片段，例如：

```text
## no burst: 5 requests in a row
200 503 503 503 503
ok - without burst only the first request fits
```

每个实验都在自己的目录里启动一个私有的 nginx（prefix 就是实验目录），监听 127.0.0.1 上的固定端口，结束时自动停掉。

## 目录

### 运维篇（`ops/`）

| 章 | 主题与结论 |
|---|---|
| [01](ops/01-install.md) | 版本、安装与实验环境：先用 nginx -V 认清手里的二进制，再决定配置能写什么 |
| [02](ops/02-config.md) | 配置文件：指令上下文由类型标志位决定，数组指令在子级出现就整组覆盖 |
| [03](ops/03-processes-signals.md) | 进程模型、信号与平滑升级：reload 是“新 worker 接班、老 worker 做完再走” |
| [04](ops/04-routing.md) | 请求路由：先选 server，再选 location，书写顺序只对正则有意义 |
| [05](ops/05-static-transfer.md) | 静态资源与传输：304、206、gzip 和缓存头都由过滤器决定 |
| [06](ops/06-reverse-proxy.md) | 反向代理：后端收到的请求行、请求头和连接，都由 proxy 模块按规则重写 |
| [07](ops/07-load-balancing.md) | 负载均衡与上游容错：每种算法都只是 peer.get 的一种实现，失败判定靠的是被动计数 |
| [08](ops/08-tls-http2-http3.md) | HTTPS、HTTP/2 与 HTTP/3：证书在握手的哪一步选定，决定了大部分配置的行为 |
| [09](ops/09-rate-limiting.md) | 限流与限连：burst 是排队的容量，不是放宽的速率 |
| [10](ops/10-proxy-cache.md) | 代理缓存：一条缓存的寿命由响应头决定，过期之后怎么办由配置决定 |
| [11](ops/11-logging-monitoring.md) | 日志与监控：每个字段都要知道它在哪一刻取值、按什么规则写出 |
| [12](ops/12-stream.md) | 四层代理：stream 模块只看字节和连接，路由信息全靠 ClientHello 和 PROXY 协议头 |
| [13](ops/13-troubleshooting.md) | 排障手册：先看状态码，再到 error.log 找原文，客户端造成的错误默认看不到 |

### 开发篇（`dev/`）

| 章 | 主题与结论 |
|---|---|
| [01](dev/01-source-map.md) | 源码地图、构建与调试：模块在 ngx_modules[] 里的位置决定了它什么时候运行 |
| [02](dev/02-data-structures.md) | 基础数据结构：每一种都为“配置期建好、请求期只读”或“从内存池分配、整体释放”而设计 |
| [03](dev/03-memory.md) | 内存池、缓冲区与共享内存：请求内存随池一起释放，跨进程状态放进 slab 管理的共享内存 |
| [04](dev/04-startup-config.md) | 配置解析：一条指令先被切成词，再按上下文交给某个模块，写进 main、srv、loc 三级结构 |
| [05](dev/05-process-event-loop.md) | 进程与事件循环：master 只等信号，worker 在一个循环里处理网络事件、定时器和投递队列 |
| [06](dev/06-http-request.md) | HTTP 请求的一生：读处理函数换三次，阶段数组走一遍，引用计数归零才算结束 |
| [07](dev/07-rewrite-script.md) | 变量与脚本引擎：rewrite 模块把指令编成一段字节码，请求来了在一个栈上执行 |
| [08](dev/08-limit-req.md) | limit_req 源码：每个 key 只记一个 excess 和一个时间戳 |
| [09](dev/09-upstream.md) | upstream 机制与负载均衡：算法只负责选地址，连接缓存、粘性和重试是包在外面的几层函数指针 |
| [10](dev/10-write-a-module.md) | 动手写模块：一个 HTTP 模块就是几张交给框架的表，框架在固定的时机回调它 |

每章的开头是一句话结论、适用版本（含与 1.30.7 stable 的差异）和对应的实验目录；结尾是“已知局限与待核实”，列出只读了源码、没有用实验验证的说法。

## 能做什么

**运行和核对实验。** 23 个实验在 `labs/<篇>-<章>/`，每个目录有 `run.sh`（实验脚本）、`HYPOTHESES.md`（运行前按源码写下的预期）、`expected.txt`（章节引用的输出）。脚本里的每个 `expect` 把实际值和按源码算出的预期值比较，输出 `ok` 或 `NOT OK`。

```bash
tools/verify_labs.sh                # 全部实验
tools/verify_labs.sh dev            # 名字以 dev 开头的实验
tools/verify_labs.sh dev-09 ops-07  # 指定的几个
```

**直接调用 nginx 的内部函数。** 开发篇的部分实验用 `labs/ctest.sh` 把一个小 C 程序和本仓库编出的目标文件链接在一起，直接调用内存池、哈希表、平滑加权轮询这些函数。例如 `labs/dev-09/rr.c` 调用 `ngx_http_upstream_get_round_robin_peer`，打印每次选择后的权重：

```bash
tools/verify_labs.sh dev-09
sed -n '/^## smooth weighted/,/^ok/p' labs/dev-09/expected.txt
```

**查一个功能从哪个版本开始有。** `tools/since.py` 搜索 1.31.9 源码里的 `changes.xml`：

```text
$ python3 tools/since.py keepalive_min_timeout
1.27.4 (2025-02-05) feature: the "keepalive_min_timeout" directive.
```

**按行号摘录源码。** `tools/excerpt.py` 输出带文件名和行号的代码块，章节里的源码片段都是这样生成的：

````text
$ python3 tools/excerpt.py src/http/ngx_http_upstream_round_robin.c 884-889
```c
// src/http/ngx_http_upstream_round_robin.c:884-889
        peer->current_weight += peer->effective_weight;
        total += peer->effective_weight;

        if (peer->effective_weight < peer->weight) {
            peer->effective_weight++;
        }
```
````

**检查章节。** `tools/check_docs.py` 检查每章的源码片段与源码逐行一致、引用的实验输出与 `expected.txt` 一致、GitHub 源码链接指向 1.31.9 里存在的行，且链接文字里的标识符确实出现在那几行；`tools/check_mermaid.sh <章节文件...>` 用 mermaid-cli 渲染章节里的图，语法错误会失败。

**改写 hello 模块。** `modules/ngx_http_hello_module/` 是开发篇 10 讲解的模块。改完源码后用 `tools/build_modules.sh` 只重编动态模块，再跑 `tools/verify_labs.sh dev-10`。

## 配置

| 变量 / 约定 | 作用 | 默认 |
|---|---|---|
| `NGINX_REF` | `tools/build.sh` 拉取和编译的 tag | `release-1.31.9` |
| `UPDATE=1` | `tools/verify_labs.sh` 用本次输出覆盖 `expected.txt`（改实验后用，改完要检查 diff） | 不设 |
| `NGINX` | 实验使用的 nginx 可执行文件 | `./.nginx/sbin/nginx` |
| 端口 | 运维篇第 NN 章用 `18000 + NN×20` 起的 20 个端口，开发篇用 `19000 + NN×20` 起的 20 个，只监听 127.0.0.1 | — |

实验只在 1.31.9 上核对过。用 `NGINX_REF=release-1.30.7 tools/build.sh` 可以编出 stable 版本，但 `expected.txt` 不保证与它的输出一致。

## 限制与已知问题

- 所有实验只在 macOS（arm64，kqueue，16 KB 内存页）上运行过。Linux 上事件模块是 epoll，debug 日志里的事件行、页大小相关的数字（如开发篇 03 的 slab 分档）会不同，`verify_labs.sh` 在 Linux 上预计会报差异；`tools/build.sh` 在 Linux 上也没有测过。
- 有几个实验依赖时序：限流（运维篇 09、开发篇 08）按“至少等了多少秒”判断，开发篇 05 的 `accept_mutex` 比较的是空闲后的最终状态。机器很忙时仍可能偶发失败，重跑一次即可区分偶发和真实差异。
- HTTP/3 只验证到 QUIC 握手和 ALPN（运维篇 08），没有发出 HTTP/3 请求；各章“已知局限与待核实”列出了其余没有实验覆盖的说法。
- 第一次运行 `tools/check_mermaid.sh` 需要 Node.js，`npx` 会下载 mermaid-cli 和一个无头浏览器。
- 不支持 Windows。

## 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `tools/build.sh` 在 configure 阶段报找不到 OpenSSL 或 PCRE | 缺开发文件，或者它们不在默认搜索路径 | macOS：`brew install openssl@3 pcre2`；Debian/Ubuntu：`apt install libssl-dev libpcre2-dev zlib1g-dev` |
| 实验报 `nginx did not start`，error.log 里有 `bind() ... failed (48: Address already in use)` | 端口被占用，常见原因是之前中断的实验留下的 nginx | `pgrep -fl "labs/ops-09"` 找到那个实验目录的 nginx，只结束它的 master 进程；不要 `pkill nginx`，会误杀本机别的 nginx |
| `FAIL <实验>: output differs from expected.txt` 或 `a claim does not hold` | 实际输出与 `expected.txt` 不同，或某个 `expect` 输出了 `NOT OK` | 看 `labs/<实验>/out/actual.txt` 与 `expected.txt` 的 diff；`run.sh exited non-zero` 时看 `out/stderr.txt`；时序相关的实验先重跑一次 |

## 仓库结构

```text
ops/  dev/            章节
labs/<id>/            实验：run.sh、HYPOTHESES.md、conf/、expected.txt
labs/lib.sh           实验公共函数（start、stop、expect、fire 等）
labs/ctest.sh         把小 C 程序链接到 nginx 目标文件
modules/              本仓库自己的动态模块（hello）
tools/                构建、实验核对、源码摘录、文档检查
```

`.nginx/`、`.nginx-src/` 和各实验的 `logs/`、`out/` 由脚本生成，不进版本库。
