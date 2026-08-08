# 顿悟股道 · 复盘系统 — Windows Docker Desktop 部署 Runbook（照做版）

> 面向：用户在本机 Windows（Docker Desktop，桥接网络，DMZ）按步骤执行。  
> 配套：`docker-compose.windows.yml` + `部署文档-Docker.md §12`。本文件是**精简执行版**。

---

## 0. 前置 & 目录布局（必须对齐，否则 build 找不到上下文）

1. 安装 Docker Desktop（WSL2 后端），启动。
2. 把项目源码按下面结构放到 Windows 某盘（例如 `D:\stock\`）：

```
D:\stock\
├─ docker-deploy\          ← 含 docker-compose.windows.yml / .env.example / 部署文档*
├─ crawler-backend\        ← crawler-backend-new 的内容（注意改名 crawler-backend）
│  ├─ crawler-admin\
│  ├─ crawler-worker\
│  ├─ crawler-strategy\
│  ├─ crawler-persistence\
│  ├─ akshare-bridge\
│  └─ clickhouse-schema.sql
├─ replay-backend\         ← 复盘计算层工程（含 src/main/resources/sql/replay-calc-task-og.sql）
└─ crawler-web\            ← 前端（含 nginx.windows.conf / Dockerfile.windows / dist\）
```

> ⚠️ compose 的 build 上下文是 `../crawler-backend/crawler-admin` 等，所以**爬虫工程目录必须叫 `crawler-backend`**（不是 `crawler-backend-new`）。  
> ⚠️ `crawler-web\dist\` 必须存在（前端构建产物）。若没有：进 `crawler-web` 跑 `npm install && npm run build`；或直接从旧 Linux 服务器 `docker save crawler-web:latest` 后 `docker load`（见 §5 备注）。

---

## 1. 准备 .env

```powershell
cd D:\stock\docker-deploy
Copy-Item .env.example .env
```

编辑 `.env`（记事本或 VS Code），按实际填：

```
HOST_IP=host.docker.internal
# CK：你实测 dbeaver 经此连接可达（100.97.74.45 即本机/DMZ 的 CK）。
#     若容器内访问不到该 LAN IP，把 CK_HOST 改为 host.docker.internal。
CK_HOST=100.97.74.45
CK_PORT=8123
CK_DB=crawler
CK_USER=default
CK_PASSWORD=pamirs@123
# openGauss：已预装在宿主机 / DMZ，不通过 compose 起容器，直接填实际连接。
#   OG_HOST 同机用 100.97.74.45（或 host.docker.internal）；OG_PORT 你给的是 5432。
OG_HOST=100.97.74.45
OG_PORT=5432
OG_DB=postgres
OG_USER=dbuser
OG_PASSWORD=OpenGauss@2026
```

---

## 2. 构建 3 个 Java 镜像（容器化 maven，无需本机 JDK21）

```powershell
# --- crawler-admin + crawler-worker（同一多模块工程）---
cd D:\stock\crawler-backend
docker run --rm -v ${PWD}:/workspace -v maven-repo:/root/.m2 -w /workspace maven:3.9-eclipse-temurin-21 mvn -pl crawler-admin -am package -DskipTests
docker run --rm -v ${PWD}:/workspace -v maven-repo:/root/.m2 -w /workspace maven:3.9-eclipse-temurin-21 mvn -pl crawler-worker -am package -DskipTests

# --- replay-backend（独立工程）---
cd D:\stock\replay-backend
docker run --rm -v ${PWD}:/workspace -v maven-repo:/root/.m2 -w /workspace maven:3.9-eclipse-temurin-21 mvn package -DskipTests
```



> `maven-repo` 是 Docker 命名卷，首次会下载依赖（需联网），之后复用。  
> 若 `crawler-web\dist` 已就绪，下面 build 会自动打前端镜像。

```powershell
cd D:\stock\docker-deploy
docker compose -f docker-compose.windows.yml build
```

---

## 3. 在 crawler 库建 ClickHouse 表（直接 exec 进已运行的 CK 容器）

> CK 服务器已在跑（容器名 `astock-clickhouse-win`，绑定 `0.0.0.0:8123` + `0.0.0.0:9000`）。  
> 直接 `docker exec` 进该容器执行，**无需再拉 `clickhouse/clickhouse-client` 镜像、也不走网络**。

```powershell
# ① 建 crawler 库：引擎用 Atomic（CK 21+ 默认，原生支持 MergeTree / ReplacingMergeTree 表家族，
#    且支持原子 DROP/RENAME）。不要用已废弃的 Ordinary。COMMENT 可选。
#    ★ 若该容器启动时未给 default 设密码，去掉 --password 这一段即可。
docker exec -it astock-clickhouse-win clickhouse-client --password pamirs@123 `
  --query "CREATE DATABASE IF NOT EXISTS crawler ENGINE = Atomic COMMENT 'stock crawler & replay data warehouse'"

# ② 灌 25 张分析型表：把宿主机上的 schema 文件通过管道喂给容器内 client；-d crawler 指定当前库
Get-Content D:\stock\crawler-backend\clickhouse-schema.sql | docker exec -i astock-clickhouse-win clickhouse-client --password pamirs@123 -d crawler
```

> 若 CK 在本机但应用容器（`stock-net` 桥接）访问不到 `100.97.74.45`，把 `.env` 的 `CK_HOST` 改为 `host.docker.internal`（Windows Docker Desktop 指向宿主的可靠别名）。  
> 若你已用 dbeaver / 本机 clickhouse-client 建好 `crawler`，只要把 `clickhouse-schema.sql` 在 `crawler` 库内执行一遍即可（DDL 不带库名前缀，靠当前库解析）。

---

## 4. 初始化已安装的 openGauss（不再新起容器）

> openGauss 已预装，本步只把应用需要的表建到**现成的 OG 实例**里，不拉起任何数据库容器。

```powershell
cd D:\stock
# 用临时 postgres 客户端容器连到宿主机上已安装的 OG（你给的：100.97.74.45:5432 / dbuser / OpenGauss@2026 / postgres）。
# ① 操作型表（crawl_task / crawl_log / alert / node / trade_log 等）
docker run --rm -v ${PWD}/schema-opengauss.sql:/tmp/og.sql postgres:16 `
  psql "postgresql://dbuser:OpenGauss@2026@100.97.74.45:5432/postgres?sslmode=disable" -f /tmp/og.sql
# ② 复盘分布式任务表 replay_calc_task
docker run --rm -v ${PWD}/replay-backend/src/main/resources/sql/replay-calc-task-og.sql:/tmp/rt.sql postgres:16 `
  psql "postgresql://dbuser:OpenGauss@2026@100.97.74.45:5432/postgres?sslmode=disable" -f /tmp/rt.sql
```

> - 若你的 OG 不是装在 Docker 同机、或端口/账号不同，把上面 `100.97.74.45:5432` 和
>   账号密码换成实际值即可（与 `.env` 的 OG_* 保持一致）。
> - 也可直接用 dbeaver / 本机 psql 打开 OG 连接，分别执行这两个 `.sql` 文件，效果一样。
> - 仅首次部署需要执行本步；之后重跑 compose 不会重建这些表。

---

## 5. 起全部服务

```powershell
cd D:\stock\docker-deploy
docker compose -f docker-compose.windows.yml up -d
# 可选：财报桥（financial 表回填）
docker compose -f docker-compose.windows.yml --profile financial up -d
```

> 若 `crawler-web\dist` 没构建且不想本地 npm 构建：从旧 Linux 服务器搬运镜像更快——  
> 旧机 `docker save crawler-web:latest -o crawler-web.tar`，拷到 Windows 后 `docker load -i crawler-web.tar`，再 `up -d`（compose 会复用已存在的 crawler-web:latest 镜像）。

---

## 6. 验证

```powershell
# 前端大屏
curl.exe http://localhost:8091/
# 反代链路（应 405=路由通）
curl.exe -X POST http://localhost:8091/api/crawl/seed-concept
# CK 连的是 crawler？看 crawler-admin 日志
docker logs crawler-admin | Select-String "ClickHouse|crawler"
# 触发种子（可选）
curl.exe -X POST http://localhost:8081/api/crawl/seed-news-event
# CK 计数 / 看表（exec 进已运行的 astock-clickhouse-win）
docker exec -it astock-clickhouse-win clickhouse-client --password pamirs@123 --query "SHOW TABLES FROM crawler"
docker exec -it astock-clickhouse-win clickhouse-client --password pamirs@123 --query "SELECT count() FROM crawler.news_event"
```

---

## 7. 常见坑

| 现象                           | 处理                                                                                      |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| `network_mode: host` 报错      | 必须用 `docker-compose.windows.yml`（已去 host 模式）                                            |
| 应用连不上 OG（connection refused） | OG 是预装实例，不是容器服务名；确认 `.env` 的 `OG_HOST/OG_PORT` 指向真实可达地址（同机用 `host.docker.internal` 或 `100.97.74.45`） |
| OG 报 SSL / 认证失败              | JDBC URL 已加 `?sslmode=disable`；确认 `.env` 的 `OG_USER/OG_PASSWORD` 与已装 OG 一致              |
| 前端 `/api` 404                | 用的是 `nginx.windows.conf`（`Dockerfile.windows`），反代 `crawler-admin:8081`；不要混用旧 nginx.conf |
| 容器访问不到 CK（100.97.74.45）      | 若 CK 在本机，改用 `CK_HOST=host.docker.internal`；若独立服务器，确认 Windows 防火墙放行且 Docker NAT 可达       |
| maven 构建慢/失败                 | 首次需联网下依赖；用 `maven-repo` 卷缓存；或改走旧服务器 `docker save/load`                                  |
