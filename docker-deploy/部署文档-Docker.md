# 顿悟股道 · 复盘系统 — Docker 部署文档

> 适用范围：单台 Docker 主机（当前 `124.223.220.245`，后续要整体切到另一套纯 Docker 环境）。
> 设计目标：**所有外部依赖（ClickHouse / openGauss）通过 `.env` 外部化，迁移到另一套环境只改 `.env`，不改 `docker-compose.yml` → 无痛迁移。**

---

## 0. 一句话流程

```
本地改 Java/前端源码
   → rsync 到服务器源码目录 /opt/stock/<工程>
   → 容器化 maven 重建 jar（宿主机无 JDK21）
   → docker compose build   （打运行镜像）
   → docker compose up -d    （起服务，不含 akshare-bridge）
   → 可选：docker compose --profile financial up -d  （起财报桥）
```

切环境（迁移）：**只改 `/opt/stock/docker-deploy/.env`**，把 `CK_*` / `OG_*` / `HOST_IP` 指向新环境的地址，重新 `docker compose up -d` 即可。源码、compose、Dockerfile 一律不动。

---

## 1. 组件与端口规划

| 服务 | 镜像 | 端口(host) | 作用 | 构建上下文 |
|---|---|---|---|---|
| `crawler-admin` | `crawler-admin:latest` | **8081** | 爬虫管理面 + seed 接口 + 调度执行 | `../crawler-backend/crawler-admin` |
| `crawler-worker` | `crawler-worker:latest` | **8082** | 实际爬取执行器（XXL-JOB 执行器） | `../crawler-backend/crawler-worker` |
| `replay-backend` | `replay-backend:latest` | **8090** | 复盘计算层（S2 情绪 / S4 主线龙头 …） | `../replay-backend` |
| `crawler-web` | `crawler-web:latest` | **8091** | 前端监控大屏（nginx，反代 `/api`→8081） | `../crawler-web` |
| `akshare-bridge` | `akshare-bridge:latest` | **8800** | 财报桥接（FastAPI，仅 financial profile 启动） | `../crawler-backend/akshare-bridge` |

端口均选用 host 网络下**当前空闲**的端口，规避既有容器：`xxl-job-admin`(8080)、`astock-mysql`(3306)、`astock-clickhouse`(8123/9000 映射但容器名独立)、`opengauss`(15432 远端)。

> **已存在的外部依赖（不要重建，直接集成）：**
> - `astock-clickhouse`（clickhouse:23.8，端口 8123 已映射到宿主机）→ 即爬虫的 ClickHouse 分析库 `crawler`。
> - `xxl-job-admin`（端口 8080）→ 调度中心，crawler 的 `XXL_JOB_ADMIN_ADDRESSES` 指向它。
> - openGauss 当前为**远端** `100.92.86.64:15432`（非本机容器）；目标纯 Docker 环境可改为容器服务，只改 `.env`。

---

## 2. 服务器前置条件（当前实测）

- 系统：CentOS 7；Docker 26.1.4 + Compose v2.27.1 已装。
- **JDK 仅 8**（`/opt/jdk/jdk1.8.0_491`、`/usr/lib/jvm/java-1.8.0`），**无 JDK 21** → 不能在宿主机 `mvn` 编译 Spring Boot 3.2.5（需 Java 21）。**必须用容器化 maven 构建 jar**（见 §4）。
- 磁盘紧张：59G 盘常驻 99%（仅剩 ~1.2G）。构建中间镜像用完即删，镜像用极简 `eclipse-temurin:21-jre` 运行层。
- 网络出口：本环境**无到 `registry-1.docker.io` 的公网**；但**腾讯云内网镜像可达**、**Maven Central 可达**、**腾讯 PyPI 镜像可达**。基础镜像与依赖均走这些可达源（已拉取缓存，迁移到新环境时由该环境各自镜像拉取）。

---

## 3. 目录约定（服务器 `/opt/stock`）

```
/opt/stock/
├── docker-deploy/                 ← 编排文件 + .env（本仓库的部署入口）
│   ├── docker-compose.yml
│   ├── .env                       ← 真实环境配置（不入库/不公开）
│   └── .env.example              ← 模板
├── crawler-backend/              ← 爬虫工程（crawler-backend-new 同步而来）
│   ├── crawler-admin/   (Dockerfile + src + target/*.jar)
│   ├── crawler-worker/  (Dockerfile + src + target/*.jar)
│   └── akshare-bridge/  (Dockerfile + akshare_bridge.py + requirements.txt)
├── replay-backend/               ← 复盘计算层工程（Dockerfile + target/*.jar）
└── crawler-web/                  ← 前端监控大屏（Dockerfile + nginx.conf + dist/）
```

> 本地源码目录（Mac）：
> - 爬虫：`/Users/null/Myself/stock/dunwugudao/爬虫项目/github/crawler-backend-new/`
> - 复盘：`/Users/null/Myself/stock/dunwugudao/复盘系统/replay-backend/`
> - 前端：`/Users/null/Myself/stock/dunwugudao/爬虫项目/crawler-web/`

---

## 4. 构建 Java 21 jar（关键：容器化 maven）

宿主机无 JDK 21，用临时 `maven` 容器挂载源码与 `~/.m2` 在线编译（Maven Central 可达）：

```bash
# 在服务器执行。maven 镜像已缓存；新环境用该环境镜像源拉取 maven:3.9-eclipse-temurin-21
cd /opt/stock/crawler-backend

docker run --rm \
  -v /opt/stock/crawler-backend:/workspace \
  -v /root/.m2:/root/.m2 \
  -w /workspace \
  maven:3.9-eclipse-temurin-21 \
  mvn -pl crawler-admin -am package -DskipTests

docker run --rm \
  -v /opt/stock/crawler-backend:/workspace \
  -v /root/.m2:/root/.m2 \
  -w /workspace \
  maven:3.9-eclipse-temurin-21 \
  mvn -pl crawler-worker -am package -DskipTests

# 复盘计算层（独立工程，单模块）
cd /opt/stock/replay-backend
docker run --rm \
  -v /opt/stock/replay-backend:/workspace \
  -v /root/.m2:/root/.m2 \
  -w /workspace \
  maven:3.9-eclipse-temurin-21 \
  mvn package -DskipTests
```

产物：`crawler-admin/target/crawler-admin-*.jar`、`crawler-worker/target/crawler-worker-*.jar`、`replay-backend/target/replay-backend-*.jar`。

> **不要**在宿主机直接 `mvn`（会报 `Unsupported class file major version` / 需要 JDK21）。
> 构建完成后 `docker rmi maven:3.9-eclipse-temurin-21` 释放空间（约 0.6G）。

---

## 5. 构建镜像 & 启动

```bash
cd /opt/stock/docker-deploy

# 打全部运行镜像（基于上一步的 jar，极简运行层）
docker compose build

# 起核心 4 个服务（不含 akshare-bridge）
docker compose up -d

# 查看状态
docker ps --format "table {{.Names}}\t{{.Status}}"

# 仅需要回填 financial 财报表时，额外拉起财报桥
docker compose --profile financial up -d
```

前端 `crawler-web` 的 `dist/` 已随源码同步进镜像上下文（`nginx` 直接托管），无需在容器内再 build。

---

## 6. `.env` 说明（无痛迁移核心）

`/opt/stock/docker-deploy/.env`：

```dotenv
# 本机对外 IP（crawler 互访、前端跳转 xxl-job 用）
HOST_IP=124.223.220.245

# ClickHouse（分析型库；当前为本机容器 astock-clickhouse，8123 已映射到宿主机）
CK_HOST=124.223.220.245
CK_PORT=8123
CK_USER=default
CK_PASSWORD=pamirs@123

# openGauss（操作型库；当前为远端，目标环境可改为容器服务 HOST:PORT）
OG_HOST=100.92.86.64
OG_PORT=15432
OG_DB=postgres
OG_USER=dbuser
OG_PASSWORD=OpenGauss@2026
```

**迁移到另一套环境只改这一份文件：**
- `HOST_IP` → 新主机 IP。
- `CK_*` → 新环境的 ClickHouse 地址（若也容器化，则 `CK_HOST` 填容器服务名或宿主机 IP，`CK_PORT` 填映射端口）。
- `OG_*` → 新环境的 openGauss 地址（目标纯 Docker 环境建议把 OG 也跑成容器，此处填容器服务名/宿主机 IP）。
- `docker-compose.yml` 与所有 Dockerfile **无需改动**。

> ⚠️ `docker-compose.yml` 顶部有 `version: '3.8'`，Compose v2 会打印 `version is obsolete` 警告，**无害**，可忽略。

---

## 7. 数据迁移（切到纯 Docker 环境）

代码/编排零改动，需迁移两份数据：

### 7.1 ClickHouse（`crawler` 库，25 张分析型表）
```bash
# 旧环境导出（按需选表，示例导出全部）
docker exec astock-clickhouse clickhouse-client --password pamirs@123 \
  --query "SELECT * FROM crawler.stock_daily FORMAT CSV" > stock_daily.csv

# 新环境导入（先在新 CK 建好同名库表，见 crawler-backend-new/clickhouse-schema.sql）
docker exec -i new-clickhouse clickhouse-client --password <新密码> \
  --query "INSERT INTO crawler.stock_daily FORMAT CSV" < stock_daily.csv
```
> 库表结构以 `crawler-backend-new/clickhouse-schema.sql` 为准（已修复 board_daily 语法、Nullable、allow_nullable_key）。

### 7.2 openGauss（操作型库，5 张：crawl_task / crawl_log / alert / node / trade_log + replay_calc_task）
```bash
# 旧环境导出
pg_dump -h 100.92.86.64 -p 15432 -U dbuser -d postgres -F c -f og.dump

# 新环境（容器化 OG）恢复
pg_restore -h <新OG_HOST> -p <新OG_PORT> -U <新用户> -d <新库> og.dump
```

### 7.3 已灌入的种子数据
P0 五表中的 `concept` / `trade_calendar` 由 admin 的 seeder 填充；`news_event` 由东财 7×24 实时端点填充（**不可历史回填**）；`northbound_flow` 由实时 kamt 端点填充；`financial` 经 akshare-bridge 填充（需启用 financial profile + `akshare.bridge.enabled=true`）。迁移后按 §8 的 seed 流程在新环境重新灌入即可。

---

## 8. 验证与冒烟

```bash
# 1) 端口监听
ss -ltnp | grep -E '8081|8082|8090|8091'        # 应全部 LISTEN

# 2) 前端大屏
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8091   # 期望 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8091/api/crawl/seed-concept  # 反代到 8081，405=路由通

# 3) 复盘计算层自动跑过（看启动日志）
docker logs replay-backend 2>&1 | grep -E "复盘计算结束|S4|主线"

# 4) 种子数据填充（POST，按需）
curl -X POST http://127.0.0.1:8081/api/crawl/seed-concept
curl -X POST http://127.0.0.1:8081/api/crawl/seed-trade-calendar
curl -X POST http://127.0.0.1:8081/api/crawl/seed-news-event   # 期望 inserted>0
curl -X POST http://127.0.0.1:8081/api/crawl/seed-northbound
# financial 需先起 akshare-bridge 且 application.yml 设 akshare.bridge.enabled=true：
curl -X POST http://127.0.0.1:8081/api/crawl/seed-financial

# 5) CK 计数核对
docker exec astock-clickhouse clickhouse-client --password pamirs@123 \
  --query "SELECT count() FROM crawler.news_event"
```

---

## 9. 常见排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `Required String parameter 'sortEnd' is not present` | `NewsEventSeeder` 东财 7×24 端点缺必填 `sortEnd=` | 已在源码修复（URL 加 `&sortEnd=`）；重编 crawler-admin 并重启 |
| `Container name conflict` / `is already in use` | 旧 stale 容器（如 `crawler-worker`）占名 | `docker rm -f crawler-admin crawler-worker replay-backend crawler-web` 再 `up -d` |
| 宿主机 `mvn` 报 `major version` / 需 JDK21 | 宿主机只有 JDK8 | 用 §4 的容器化 maven 构建 |
| 前端 `/api` 返回 404 | `proxy_pass` 误加结尾斜杠吞掉 `/api` 前缀 | nginx.conf 中 `proxy_pass http://127.0.0.1:8081;`（无斜杠） |
| CK 连接失败 | `CK_HOST`/`CK_PORT` 指向错误，或 CK 容器未起 | 核对 `.env` 与 `docker ps`；CK 用 `astock-clickhouse` 容器 |
| 磁盘 99% 构建失败 | 空间不足 | 删临时 maven 镜像、旧 `<none>` 镜像：`docker image prune -f` |
| `version is obsolete` 警告 | compose 文件声明了 `version` | 无害，忽略；或删掉该行 |

> ⚠️ **rsync 铁律**：从**本地 Mac** 侧执行 `rsync` 把源码推到服务器（见下）。**不要**把 rsync 嵌套进远程 `ssh` heredoc——服务器侧默认无 `sshpass`/`rsync` 到上游，会导致推送静默失败、仍用旧源码构建（镜像 hash 不变、`up -d` 不重启、bug 不修）。

本地 → 服务器源码同步（正确写法，从 Mac 终端执行）：
```bash
SSHOPTS="-o StrictHostKeyChecking=no"
SVR=root@124.223.220.245
sshpass -p 'pamirs@123' rsync -avz -e "ssh $SSHOPTS" \
  /Users/null/Myself/stock/dunwugudao/爬虫项目/github/crawler-backend-new/ \
  $SVR:/opt/stock/crawler-backend/
sshpass -p 'pamirs@123' rsync -avz -e "ssh $SSHOPTS" \
  /Users/null/Myself/stock/dunwugudao/复盘系统/replay-backend/ \
  $SVR:/opt/stock/replay-backend/
sshpass -p 'pamirs@123' rsync -avz -e "ssh $SSHOPTS" \
  /Users/null/Myself/stock/dunwugudao/爬虫项目/crawler-web/ \
  $SVR:/opt/stock/crawler-web/
```

---

## 10. 服务器已落地状态（截至 2026-08-08）

- 4 个核心容器全 `Up`：`crawler-admin`(8081) / `crawler-worker`(8082) / `replay-backend`(8090) / `crawler-web`(8091)。
- `seed-news-event` 已验证 `inserted=200`，`crawler.news_event` 计数 200。
- `replay-backend` 启动自动跑 S4 计算并写入 CK（mainline_daily 20 条 / leader_pool_daily 100 只）。
- `akshare-bridge` 已随 financial profile 常驻运行（财务表已灌 1280 行/160 只）。
- `concept` 已灌 504 行；`financial` 已灌 1280 行（160 只）；`news_event` 200 行。
- 龙虎榜 9501 已根治（见 §11），但爬虫任务表所在 openGauss 为远端且当前不可达 → 过渡环境无法端到端跑龙虎榜；待切纯 Docker 目标环境（OG 本机容器可达）验证。
- 磁盘 99%（1.5G 余），临时 maven 镜像已删。

---

## 11. 龙虎榜 9501 修复与端到端验证

### 11.1 根因
`EastmoneyEndpoints` 的 `DATACENTER` 分支原用**旧版** `https://datacenter-web.eastmoney.com/api/data/get?type=RPT_DAILYBILLBOARD_DETAILS`，东财已废弃并强制要求返回字段参数，且整体切到**新版** `/api/data/v1/get` + `reportName=RPT_DAILYBILLBOARD_DETAILSNEW` + `columns=列名`（日期还要带横线 `2026-08-07`）。旧式无论加什么 `columns` 变体都固定返回 `code:9501 返回字段参数不能为空`。

### 11.2 代码修复（已落源码，未重建镜像）
1. `crawler-strategy/.../EastmoneyEndpoints.java`：`DATACENTER` 分支重写——
   - DRAGON_TIGER 切新版：`reportName=RPT_DAILYBILLBOARD_DETAILSNEW` + `columns` 全 31 列 + `sortColumns/sortTypes` + `source=WEB&client=WEB` + `filter` 由 `tradeDate` 转 `yyyy-MM-dd` 并经 `URLEncoder` 编码。
   - DRAGON_TIGER_DETAIL 也切新版（`reportName=RPT_BILLBOARD_DETAIL`，列名 `SEAT_NAME/SEAT_TYPE/BUY/SELL`，待单独验证 M6）。
2. `crawler-admin/.../SeedGenerator.java` + `SeedController.java`：新增 `seedDragonTiger(source,date)` 与 `POST /seed-dragon-tiger`（市场级每日一条）。**此前根本没有主表触发入口**，只有明细串联 `chainDragonTigerDetails`，故龙虎榜主表从未能触发。

> 验证依据：服务器 raw 直连 akshare 同款新格式返回 **HTTP 200 + 真实龙虎榜数据**（000603 盛达资源 2026-08-07），返回列名正是 `parseDatacenter` 用的 `DATACENTER_COL_MAP` key → 解析器无需改。worker 的 `EastmoneyApiStrategy.fetch()` 路由也已有 `case ZT_POOL, DATACENTER`，故补 URL + 补触发入口后即闭环。

### 11.3 端到端验证步骤（需在 openGauss 可达环境执行）
> 前提：`.env` 的 `OG_*` 指向**可达**的 openGauss（新 Windows 环境 OG 已预装，填好其真实 HOST:PORT 即可；旧 Linux 过渡环境 OG 为远端 `100.92.86.64:15432` 当前不可达），否则 worker 拉不到 `crawl_task`、seed 写不了 OG。

```bash
# 1) 重建 crawler-worker 镜像（含 9501 修复 + seedDragonTiger 入口）
cd /opt/stock/crawler-backend
docker run --rm -v /opt/stock/crawler-backend:/workspace -v /root/.m2:/root/.m2 -w /workspace \
  maven:3.9-eclipse-temurin-21 mvn -pl crawler-worker -am package -DskipTests
cd /opt/stock/docker-deploy
docker compose build crawler-worker && docker compose up -d crawler-worker
docker rmi maven:3.9-eclipse-temurin-21   # 释放空间

# 2) 触发龙虎榜主表任务（市场级每日一条；date 用交易日，如 2026-08-07）
curl -X POST http://127.0.0.1:8081/api/crawl/seed-dragon-tiger \
  -H "Content-Type: application/json" -d '{"tradeDate":"2026-08-07"}'
# → 返回 {"taskType":"DRAGON_TIGER","date":"2026-08-07","inserted":1}

# 3) worker 认领并执行（看 crawler-worker 日志）
docker logs -f crawler-worker 2>&1 | grep -iE "DRAGON_TIGER|datacenter|dragon"

# 4) 验证落库
docker exec astock-clickhouse clickhouse-client --password pamirs@123 \
  --query "SELECT count() FROM crawler.dragon_tiger"
# → 应 >0（上榜股票数）

# 5) 可选：串联龙虎榜席位明细（需主表先落库）
curl -X POST http://127.0.0.1:8081/api/crawl/chain-dragon-tiger-details \
  -H "Content-Type: application/json" -d '{"tradeDate":"2026-08-07"}'
```

### 11.4 过渡服务器当前限制
- 爬虫任务表所在 openGauss 为**远端** `100.92.86.64:15432`，**当前不可达**（bash/tcp 实测超时）→ worker 拉不到任务、seed 写不了 OG。
- 本机 `opengauss` 容器属 astock 项目、无端口映射，与 crawler 无关。
- 因此 §11.3 的端到端验证**必须在切到纯 Docker 目标环境（OG 本机容器可达）后执行**；本过渡环境仅完成代码修复与 URL 正确性验证。

---

## 12. 迁移到 Windows Docker Desktop（桥接 / 纯 Docker 环境）

> 用户第二套环境：**Windows 主机 + Docker Desktop + 桥接网络（DMZ）**。
> 该机 ClickHouse：`100.97.74.45:8123 / database=crawler / default / pamirs@123`（wushi 已存在，不占用）。

### 12.1 为什么需要单独一套 compose
Windows Docker Desktop **不支持 `network_mode: host`**（host 网络是 Linux 专属）。原 `docker-compose.yml` 全量 `network_mode: host`，在 Windows 上无法启动。
因此新增 **`docker-compose.windows.yml`**，改用：
- 自定义桥接网络 `stock-net`（`driver: bridge`）；
- 每个服务加 `ports:` 映射（8081/8082/8090/8091/8800/9999）；
- 容器互访用**服务名 DNS**，不再用 `127.0.0.1`：
  - `crawler-web` 的 nginx 反代 → `http://crawler-admin:8081`（见 `crawler-web/nginx.windows.conf` + `Dockerfile.windows`）；
  - `crawler-admin` 调 akshare-bridge → `http://akshare-bridge:8800`；
  - xxl-job 控制面 → `http://host.docker.internal:8080`。

> 代码层**零改动**：建表 DDL 与所有 MyBatis Mapper 均不带库名前缀（`CREATE TABLE stock_daily`、`FROM news_event`），靠 JDBC URL 默认库名决定。所以只要 JDBC URL 指向 `crawler`，表就建在 `crawler` 里。

### 12.2 新环境 .env（关键差异）
```
HOST_IP=host.docker.internal        # Windows 上用 Docker Desktop 访问宿主机的专用名
# ClickHouse（新环境 CK 在 100.97.74.45:8123，database=crawler）
#   ★ 实测 dbeaver 经此连接可达；若容器内访问不到该 LAN IP，把 CK_HOST 改为 host.docker.internal
CK_HOST=100.97.74.45
CK_PORT=8123
CK_DB=crawler                         # ★ 新环境与旧环境一致（wushi 已存在，不占用）
CK_USER=default
CK_PASSWORD=pamirs@123                # ★ 实测口令（非 default）
# openGauss（★ 已预装在宿主机 / DMZ，docker-compose.windows.yml 不再起 OG 容器）
#   OG_HOST：同机用 host.docker.internal（或 100.97.74.45）；独立机填其 IP
#   OG_PORT：以你安装 OG 时的监听/映射端口为准（例 15432 或 5432）
OG_HOST=host.docker.internal
OG_PORT=15432
OG_DB=postgres
OG_USER=dbuser
OG_PASSWORD=OpenGauss@2026
```
> 端口说明：ClickHouse 与 openGauss **都不再由我们的 compose 管理**——两者均已预装在宿主机 / DMZ，应用通过 `.env` 的 `CK_*` / `OG_*` 直连其真实 HOST:PORT。应用连 OG 用你填的 `OG_HOST:OG_PORT`（同机即用 `host.docker.internal:映射端口`）；你在 Windows 本机用 DBeaver 连同一个 HOST:PORT 即可。
> （模板见 `.env.example`，已含 `CK_DB`。）

### 12.3 构建镜像（两种方式）
**方式 A — 本机容器化 maven 构建（需可拉取镜像 / Maven Central 可达）** ✅ 本次选定
与 Linux 同思路，用 `maven:3.9-eclipse-temurin-21` 容器挂载源码编译 jar，再 `docker compose -f docker-compose.windows.yml build`。
（Windows 上 `maven:3.9-eclipse-temurin-21` 同样可用，镜像托管在 Docker Hub / 腾讯云镜像。）

**方式 B — 从旧 Linux 服务器搬运镜像（新环境外网受限时）**
旧服务器上导出，拷到 Windows 后导入，省去重新构建：
```
# 旧 Linux 服务器
docker save crawler-admin:latest crawler-worker:latest replay-backend:latest crawler-web:latest akshare-bridge:latest \
  -o /tmp/stock-images.tar
# 把 /tmp/stock-images.tar 拷到 Windows 后
docker load -i stock-images.tar
```
> 前提：旧服务器镜像必须已含最新代码修复（9501 龙虎榜、seedDragonTiger 入口、financial 东财源）。若源码有更新，先按方式 A 重建。

### 12.4 在 crawler 库部署 ClickHouse 表结构
> CK 服务器已在跑（容器名 `astock-clickhouse-win`，绑定 `0.0.0.0:8123` + `0.0.0.0:9000`）。  
> **直接 `docker exec` 进该容器执行，无需另装/另拉客户端、也不走网络。**

```powershell
# 1) 先建库（如不存在）。★ 若容器启动时未给 default 设密码，去掉 --password 这一段。
docker exec -it astock-clickhouse-win clickhouse-client --password pamirs@123 `
  --query "CREATE DATABASE IF NOT EXISTS crawler ENGINE = Atomic COMMENT 'stock crawler & replay data warehouse'"

# 2) 跑 DDL（DDL 不含库名前缀，连 crawler 即建在 crawler 下；管道喂入宿主机上的 schema 文件）
Get-Content D:\stock\crawler-backend\clickhouse-schema.sql | docker exec -i astock-clickhouse-win clickhouse-client --password pamirs@123 -d crawler
```
> 引擎用 `Atomic`（CK 21+ 默认，原生支持 MergeTree / ReplacingMergeTree 表家族，且支持原子 DROP/RENAME）；不要用已废弃的 `Ordinary`。  
> DDL 已含全部 25 张分析型表，幂等（`IF NOT EXISTS`），可重复执行。

### 12.5 初始化已安装的 openGauss（不新起容器）
openGauss 已预装，**应用层不自动建表**（工程无 Flyway），需把表结构建到现成的 OG 实例里。用临时 postgres 客户端容器连宿主机 OG 即可（`host.docker.internal` 指向宿主机）：

```powershell
cd D:\stock
# ① 操作型表（crawl_task / crawl_log / alert / node / trade_log 等）
docker run --rm -v ${PWD}/schema-opengauss.sql:/tmp/og.sql postgres:16 `
  psql "postgresql://dbuser:OpenGauss@2026@100.97.74.45:5432/postgres?sslmode=disable" -f /tmp/og.sql
# ② 复盘分布式任务表 replay_calc_task
docker run --rm -v ${PWD}/replay-backend/src/main/resources/sql/replay-calc-task-og.sql:/tmp/rt.sql postgres:16 `
  psql "postgresql://dbuser:OpenGauss@2026@100.97.74.45:5432/postgres?sslmode=disable" -f /tmp/rt.sql
```
> 上面已用 `dbuser / OpenGauss@2026` 填实（opengauss-lite 容器绑 `0.0.0.0:5432`，端口是 5432 不是 15432）。  
> 也可直接用 DBeaver / 本机 psql 打开 OG 连接执行这两个 `.sql` 文件。仅首次部署需要；之后重跑 compose 不会重建这些表。
> `replay-backend` 已加 `hikari.initialization-fail-timeout=0`：即使 OG 短暂不可达，CK-only 计算（S2 情绪 / S4 主线龙头）仍可独立启动；`replay_calc_task` 需 OG 才落库。

### 12.6 完整启动顺序
```powershell
cd docker-deploy
cp .env.example .env          # 按 §12.2 填好（重点 CK_DB=crawler / OG_HOST / OG_PORT 指向已装 OG）

# 1) 初始化已安装的 openGauss（首次必须，建表到现成 OG 实例，见 §12.5）
#    → 执行 §12.5 的 psql 灌表命令

# 2) 起全部服务（crawler-admin / crawler-worker / replay-backend / crawler-web）
#    本编排不再含数据库容器，只起应用层
docker compose -f docker-compose.windows.yml up -d
# 可选：财报桥
docker compose -f docker-compose.windows.yml --profile financial up -d
```

### 12.7 数据策略：空库重爬（本次选定，不迁移旧数据）
新 CK(crawler) 仅建表，**不迁移**旧 `crawler` 库历史数据（用户在 08-08 确认空库重爬）。数据由爬虫/seed 重新灌：
- 启动后手动触发种子：`seed-concept` / `seed-trade-calendar` / `seed-news-event`（见 §8 验证清单）。
- 行情/池子等由 crawler-worker 按日爬取。
- 若日后想搬历史数据，仍可用 §12.7 旧版的 `remote()` 跨库搬运（需新 CK 能访问旧 CK `124.223.220.245:8123`）。

### 12.8 xxl-job 注意事项（已知坑）
- 未部署 xxl-job-admin 时，执行器启动会打连接错误日志，但**不影响 admin 应用启动**，仍可用 JobController 手动 REST 触发任务。
- Docker Desktop 下执行器回调地址较绕：若启用 xxl-job，建议 `XXL_JOB_ADMIN_ADDRESSES` 用 `http://host.docker.internal:8080/`，并确认 xxl-job 容器把 8080 映射到了宿主机。

### 12.9 验证清单
```
curl http://localhost:8091/                     # 前端大屏 200
curl http://localhost:8091/api/crawl/health     # 后端健康（如有）
docker exec -it astock-clickhouse-win clickhouse-client --password pamirs@123 --query "SELECT count() FROM crawler.news_event"
docker logs crawler-admin | grep -iE "CK|ClickHouse"   # 确认连的是 crawler
```
