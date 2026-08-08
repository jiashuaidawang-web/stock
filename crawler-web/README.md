# crawler-web · 股票爬虫监控大屏（前端）

> 配套后端：`crawler-backend`（Spring Boot，admin 模块端口 `8081`）。
> 技术栈：**Vue3 + Vite + Element-Plus + ECharts**（见 `01-项目计划.md`）。
> 当前进度：**M4 告警面板** + **M5 监控总览** 均已落地（合计两个页面）。

## 目录结构

```
crawler-web/
├── package.json          依赖与脚本
├── vite.config.js        开发服务器 + /api 代理到 :8081
├── index.html
└── src/
    ├── main.js           入口（挂载 Element-Plus / 路由 / 图标）
    ├── App.vue           整体布局（顶栏 + 侧边菜单 + 路由出口）
    ├── router/index.js   路由（/dashboard 监控总览 / /alerts 告警面板）
    ├── api/crawler.js    axios 封装：告警 / 标记已处理 / 总体统计 / 按源·按节点分布 / 节点
    └── views/
        ├── MonitorDashboard.vue  【M5 核心】监控总览仪表盘
        └── AlertPanel.vue  【M4 核心】告警面板
```

## 运行

```bash
# 1. 安装依赖（首次）
npm install

# 2. 开发模式（热更新），默认 http://localhost:5173
npm run dev

# 3. 生产构建（产物在 dist/）
npm run build

# 4. 预览生产构建
npm run preview
```

### 与后端联调
开发期 `vite.config.js` 已配置代理：`/api` → `http://localhost:8081`（即 crawler-admin）。
启动前端前请先启动后端 admin（`mvn -pl crawler-admin -am spring-boot:run` 或打 jar 跑）。
前端访问 `http://localhost:5173` 即可，无需处理跨域。

> 生产部署建议：用 nginx 托管 `dist/` 静态产物，并把 `/api` 反向代理到 `crawler-admin:8081`（与 dev 代理同理）。

## 告警面板（AlertPanel）功能

- **汇总卡片**：未处理总数 + 按级别（ERROR/WARN/INFO）拆分，随筛选实时计算。
- **筛选**：处理状态（未处理/已处理/全部）、级别、类型、数据源。
- **列表**：类型 / 级别（红=ERROR、橙=WARN、蓝=INFO）/ 任务ID / 任务类型 / 数据源 / 信息 / 实际·期望 / 创建时间。
- **标记已处理**：调用 `POST /api/crawl/alerts/{alertId}/resolve`，二次确认后前端即时置位（无需整表重拉）。
- **自动刷新**：默认开启，每 15s 拉取一次（仅未处理视图也会随筛选刷新），可手动开关。

## 监控总览（MonitorDashboard）功能

默认落地页（`/` → `/dashboard`），基于后端 `GET /api/crawl/stats`、`/stats?groupBy=*`、`/nodes` 渲染。

- **汇总卡片**：任务总数 / 成功率（≥95% 绿、≥80% 橙、否则红）/ 失败(Dead)与重试数 / 节点数（含在线数）。
- **成功率仪表盘**：ECharts gauge，阈值色带 80% 红、95% 橙、100% 绿。
- **任务状态分布**：环形饼图（PENDING/CLAIMED/SUCCESS/RETRY/DEAD 带语义配色）。
- **按数据源分布**：环形饼图（0 同花顺 / 1 东财 / 2 其他）。
- **按节点分布**：横向柱状图（node = last_node 或 unknown）。
- **节点心跳表**：节点ID/名称/IP/角色/状态/运行任务数/心跳时间+相对年龄；心跳超 60s 或状态非 ONLINE 标红，「健康」列给出 正常/异常。
- **自动刷新**：默认 15s 轮询（统计与节点分开拉取，节点失败不影响统计），可手动开关 + 手动刷新 + 显示最后更新时间。

## 后端接口（admin 模块，前缀 /api/crawl）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/alerts?resolved=0` | 查告警；resolved: 0 未处理 / 1 已处理 |
| POST | `/alerts/{alertId}/resolve` | 标记已处理（M4 新增） |
| GET | `/stats` | 任务状态计数 + 成功率（M5 总览用） |
| GET | `/stats?groupBy=source` | 按数据源分布 |
| GET | `/stats?groupBy=node` | 按节点分布 |
| GET | `/nodes` | 节点列表与心跳 |

## 已知 TODO（接 M6 / 后续）
- **Webhook 告警通道**：`crawl_alert` 落库 + 企业微信/钉钉推送（`01-项目计划.md` 备注 M4 再接，本期未做）。
- **告警类型枚举**：面板「类型」下拉取自数据动态去重；如需固定枚举可在此处硬编码（VOLUME_DEVIATION/CRAWL_FAIL/ANTI_CRAWL/NODE_DOWN）。
- **M6 端到端实测校准**：后端 `crawler-backend/README.md` 的 TODO M6 字段（board_daily.amount/limit_up_count、limit_style 一字判定、dt_detail.is_famous、龙虎榜 ts_code 后缀、northbound 端点、同花顺 DOM 选择器、周线列裁剪）待真实跑一轮确认。
