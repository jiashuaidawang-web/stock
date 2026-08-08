-- ============================================================================
-- 股票复盘系统 · openGaussDB 数据模型（前置原始层 + 计算层）
-- 来源方法论：《顿悟股道》无门问禅（8 个 skill）
-- 配套：复盘系统-前置数据需求清单.md（每张表要爬什么）、M1 计算层算法骨架.md
-- 约定：金额单位=元；幅度/涨跌=百分比数值(如 9.98 表示 9.98%)；成交量=手
-- 字符集：UTF8（建库时指定）；所有时间序列表按 (trade_date) 建索引便于按日批算
-- 幂等写入：爬虫与 M1 Job 均用 INSERT ... ON CONFLICT(自然键) DO UPDATE（重复跑不报错）
-- openGauss 基于 PostgreSQL，以下语法兼容；若某列名与保留字冲突可用双引号包裹
-- ============================================================================

-- ============================================================================
--  PART A · 前置原始层（你爬取灌入）
-- ============================================================================

-- 交易日历（M1 算"昨日/前一交易日"用，避免用自然日减一天踩到休市）
CREATE TABLE trade_calendar (
  trade_date   DATE PRIMARY KEY,
  is_trading   SMALLINT DEFAULT 1          -- 1=交易日 0=休市
);
COMMENT ON TABLE trade_calendar IS '交易日历；M1 计算昨日涨停今表现、前交易日依赖此表';

-- A1 指数日线（S1 技术面维度 + S4/S6 对比基准）
CREATE TABLE index_daily (
  trade_date   DATE      NOT NULL,
  index_code   VARCHAR(16) NOT NULL,       -- 指数代码(如 000001.SH 上证综指 / 000300.SH 沪深300 / 000852.SH 中证1000 / 932000.CSI 中证2000)
  index_name   VARCHAR(64),
  open         NUMERIC(12,4),
  high         NUMERIC(12,4),
  low          NUMERIC(12,4),
  close        NUMERIC(12,4),
  pre_close    NUMERIC(12,4),
  pct_chg      NUMERIC(10,4),              -- 涨跌幅%
  vol          NUMERIC(22,2),              -- 成交量(手)
  amount       NUMERIC(24,2),              -- 成交额(元)
  turnover     NUMERIC(10,4),              -- 换手率%
  ma5          NUMERIC(12,4),             -- 冗余：5日线
  ma20         NUMERIC(12,4),              -- 冗余：20日线
  macd         NUMERIC(12,4),              -- 冗余：MACD柱
  PRIMARY KEY (index_code, trade_date)
);
COMMENT ON TABLE index_daily IS '指数日线；覆盖上证/深证/创业板/沪深300/中证500/1000/2000，小盘指数决定游资情绪';
CREATE INDEX idx_index_daily_date ON index_daily(trade_date);

-- A2 个股日线（S1/S2/S6 底层；昨日涨停今表现、八大特征、技术面）
CREATE TABLE stock_daily (
  trade_date     DATE      NOT NULL,
  ts_code        VARCHAR(16) NOT NULL,      -- 股票代码(如 600000.SH)
  stock_name     VARCHAR(64),
  open           NUMERIC(12,4),
  high           NUMERIC(12,4),
  low            NUMERIC(12,4),
  close          NUMERIC(12,4),
  pre_close      NUMERIC(12,4),
  pct_chg        NUMERIC(10,4),            -- 涨跌幅%
  vol            NUMERIC(22,2),            -- 成交量(手)
  amount         NUMERIC(24,2),            -- 成交额(元)
  turnover       NUMERIC(10,4),            -- 换手率%
  total_mv       NUMERIC(24,2),            -- 总市值(元)
  circ_mv        NUMERIC(24,2),            -- 流通市值(元)
  pe             NUMERIC(12,4),
  is_limit_up    SMALLINT DEFAULT 0,       -- 是否涨停 1/0
  is_limit_down  SMALLINT DEFAULT 0,       -- 是否跌停 1/0
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE stock_daily IS '全市场个股日线；S2 赚亏效应/昨日涨停今表现、S6 八大特征、S1 个股技术面';
CREATE INDEX idx_stock_daily_date ON stock_daily(trade_date);

-- A3 个股周线（S6 趋势战法：10/30周均线、RS、RSI）
CREATE TABLE stock_weekly (
  trade_date     DATE      NOT NULL,        -- 周末日期
  ts_code        VARCHAR(16) NOT NULL,
  open           NUMERIC(12,4),
  high           NUMERIC(12,4),
  low            NUMERIC(12,4),
  close          NUMERIC(12,4),
  vol            NUMERIC(22,2),
  amount         NUMERIC(24,2),
  ma10           NUMERIC(12,4),            -- 10周均线
  ma30           NUMERIC(12,4),            -- 30周均线
  rs             NUMERIC(10,4),            -- 相对强度 = 个股涨幅/指数涨幅
  rsi            NUMERIC(10,4),            -- 周线RSI
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE stock_weekly IS '个股周线；S6 八大特征(均线多头/RS强于指数/RSI)的底层；可由daily聚合，也可独立爬';
CREATE INDEX idx_stock_weekly_date ON stock_weekly(trade_date);

-- A4 涨跌停/炸板池（全书最关键输入：S2 情绪、S4 主线龙头、S5 分歧高低切换）
CREATE TABLE limit_pool (
  trade_date   DATE      NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  stock_name   VARCHAR(64),
  limit_type   VARCHAR(10) NOT NULL,       -- limit_up涨停 / limit_down跌停 / zhaban炸板
  board_pos    SMALLINT,                   -- 连板数(板位)：1=首板,2,3...（板位演化核心）
  is_first     SMALLINT DEFAULT 0,         -- 是否首板
  is_continuous SMALLINT DEFAULT 0,        -- 是否连板(>=2)
  limit_style  VARCHAR(10),               -- 一字 / T字 / 换手 / 自然 / 烂板（S5 可接力性）
  open_time    TIME,                      -- 首次封板时间
  last_time    TIME,                      -- 最后封板/炸板时间
  open_times   SMALLINT,                  -- 开板次数（炸板次数）
  bid_amount   NUMERIC(24,2),             -- 涨停封单金额(元)
  turnover     NUMERIC(10,4),
  pct_chg      NUMERIC(10,4),
  reason       VARCHAR(256),              -- 涨停原因/题材标签（S7 炒作因子输入，尽量填）
  board_code   VARCHAR(16),              -- 所属板块；NULL=独立行情→计算层判为妖/独狼
  board_name   VARCHAR(64),
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE limit_pool IS '涨跌停/炸板池；S2情绪温度、S4板位演化/龙妖独狼、S5分歧高低切换三处都依赖；board_code为NULL即独立行情';
CREATE INDEX idx_limit_pool_date ON limit_pool(trade_date);
CREATE INDEX idx_limit_pool_board ON limit_pool(board_code);

-- A5 强势股池（你提到的"强势"：未涨停但走强的票，S4/S6/S7 补充）
CREATE TABLE strong_pool (
  trade_date   DATE      NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  stock_name   VARCHAR(64),
  strong_type  VARCHAR(10),               -- 涨幅 / 新高 / 多头(多头排列)
  change_pct   NUMERIC(10,4),             -- 当日涨幅%
  high_days    INTEGER,                  -- 创N日新高(新高天数)
  ma_status    VARCHAR(16),              -- 多头排列描述
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE strong_pool IS '强势股池(涨幅>=7%/创N日新高/多头排列)；独立于涨停池，补趋势战法与龙头候选';
CREATE INDEX idx_strong_pool_date ON strong_pool(trade_date);

-- A6 板块日线（S4 主线强度排序核心）
CREATE TABLE board_daily (
  trade_date     DATE      NOT NULL,
  board_code     VARCHAR(16) NOT NULL,
  board_name     VARCHAR(64),
  pct_chg        NUMERIC(10,4),
  amount         NUMERIC(24,2),
  up_count       INTEGER,                 -- 上涨家数(M1 boardStrength公式直接读)
  down_count     INTEGER,                 -- 下跌家数
  limit_up_count INTEGER,                 -- 板块内涨停家数
  leading_code   VARCHAR(16),             -- 领涨股代码(S6 领涨股先行)
  leading_name   VARCHAR(64),
  PRIMARY KEY (board_code, trade_date)
);
COMMENT ON TABLE board_daily IS '板块(行业+概念)日线；S4主线识别、S3板块强弱、S6领涨股先行';
CREATE INDEX idx_board_daily_date ON board_daily(trade_date);

-- A7 股票-板块关联（S4 合力结构：一主线多分支、卡位/助攻/中军/后排）
CREATE TABLE stock_board_rel (
  ts_code        VARCHAR(16) NOT NULL,
  board_code     VARCHAR(16) NOT NULL,
  board_name     VARCHAR(64),
  is_leader      SMALLINT DEFAULT 0,        -- 是否板块龙头
  is_midarm      SMALLINT DEFAULT 0,        -- 是否中军（S4 合力结构中军标记）
  weight         NUMERIC(10,4),            -- 权重
  effective_date DATE,                     -- 生效日(静态行业/概念可填上市日)
  PRIMARY KEY (ts_code, board_code, effective_date)
);
COMMENT ON TABLE stock_board_rel IS '股票-板块关联；is_leader/is_midarm 是书要的合力结构标记，M1 role判定依赖其标注中军';
CREATE INDEX idx_sbr_board ON stock_board_rel(board_code);

-- A8 龙虎榜（S3 主力博弈）
CREATE TABLE dragon_tiger (
  trade_date   DATE      NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  stock_name   VARCHAR(64),
  reason       VARCHAR(128),              -- 上榜原因(日涨幅偏离/连续三日/振幅/换手)
  abnormal_type VARCHAR(16),
  net_buy      NUMERIC(24,2),             -- 龙虎榜净买额(元)
  total_buy    NUMERIC(24,2),
  total_sell   NUMERIC(24,2),
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE dragon_tiger IS '龙虎榜上榜个股；S3 抱团=合法做庄、合力识别、破除席位迷信';
CREATE INDEX idx_dt_date ON dragon_tiger(trade_date);

-- A9 龙虎榜席位明细（S3 破除主力迷信：知名游资≠必胜）
CREATE TABLE dt_detail (
  trade_date   DATE      NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  seat_name    VARCHAR(64) NOT NULL,       -- 席位名称(机构专用/知名游资/营业部)
  seat_type    VARCHAR(16),               -- 机构 / 游资 / 深股通 / 沪股通 / 营业部
  buy          NUMERIC(24,2),
  sell         NUMERIC(24,2),
  is_institution SMALLINT DEFAULT 0,       -- 是否机构
  is_famous    SMALLINT DEFAULT 0,         -- 是否知名游资(标记后系统提示看合力非迷信席位)
  PRIMARY KEY (ts_code, trade_date, seat_name)
);
COMMENT ON TABLE dt_detail IS '龙虎榜席位买卖明细；is_famous支撑S3破除主力迷信';
CREATE INDEX idx_dtd_date ON dt_detail(trade_date);

-- A10 主力资金流（S2/S3 资金供需、合力；个股/板块/指数级）
CREATE TABLE main_fund_flow (
  trade_date   DATE      NOT NULL,
  obj_type     VARCHAR(10) NOT NULL,       -- stock / board / index
  ts_code      VARCHAR(16),               -- 个股级(其他为NULL)
  board_code   VARCHAR(16),               -- 板块级(其他为NULL)
  index_code   VARCHAR(16),               -- 指数级(其他为NULL)
  main_net     NUMERIC(24,2),             -- 主力净流入(元)
  super_big    NUMERIC(24,2),             -- 超大单净流入
  big_net      NUMERIC(24,2),             -- 大单净流入
  mid_net      NUMERIC(24,2),             -- 中单
  small_net    NUMERIC(24,2),             -- 小单
  PRIMARY KEY (obj_type, ts_code, board_code, index_code, trade_date)
);
COMMENT ON TABLE main_fund_flow IS '主力资金流；S2两套钱资金供需、S3合力围猎识别；口径统一"净流入=超大单+大单"';
CREATE INDEX idx_mff_date ON main_fund_flow(trade_date);

-- A11 北向资金（S2/S3 外资供需）
CREATE TABLE northbound_flow (
  trade_date     DATE PRIMARY KEY,
  hk_hold_net    NUMERIC(24,2),            -- 北向净买入(元)
  sh_net         NUMERIC(24,2),            -- 沪股通净买入
  sz_net         NUMERIC(24,2)             -- 深股通净买入
);
COMMENT ON TABLE northbound_flow IS '北向资金日度；S2/S3 资金供需维度补充';

-- A12 新闻/政策/题材事件（S1 政策维 + S7 题材催化）
CREATE TABLE news_event (
  event_id      BIGINT      NOT NULL,
  event_time    TIMESTAMP,
  title         VARCHAR(256),
  content       TEXT,
  source        VARCHAR(64),
  category      VARCHAR(16),               -- 政策 / 行业 / 公司 / 题材
  related_board VARCHAR(256),            -- 关联板块代码(逗号分隔)
  related_ts_code VARCHAR(256),           -- 关联个股代码(逗号分隔)
  sentiment_score NUMERIC(6,4),           -- 情感分 -1~1(需NLP/规则打分)
  is_policy     SMALLINT DEFAULT 0,
  PRIMARY KEY (event_id)
);
COMMENT ON TABLE news_event IS '新闻/政策/题材事件；S1政策维度、S7最小阻力方向与题材催化输入';
CREATE INDEX idx_news_time ON news_event(event_time);

-- A13 题材静态属性（S7 炒作因子：稀缺/想象）
CREATE TABLE concept (
  theme_code     VARCHAR(16) NOT NULL,
  theme_name     VARCHAR(64),
  theme_type     VARCHAR(16),              -- 概念 / 行业 / 地域
  scarcity       NUMERIC(6,4),            -- 稀缺性 0~1(次新/重组/困境反转→高)
  imagination    NUMERIC(6,4),            -- 想象空间 0~1(容量大赛道→高)
  PRIMARY KEY (theme_code)
);
COMMENT ON TABLE concept IS '题材静态属性；S7炒作因子前二维(稀缺/想象)固定输入，可用规则启发式初填';

-- A14 财报（S2 两套钱之"企业利润之钱"）
CREATE TABLE financial (
  ts_code      VARCHAR(16) NOT NULL,
  end_date     DATE      NOT NULL,         -- 报告期
  report_type  VARCHAR(8),                 -- Q1 / Q2 / Q3 / 年报
  ann_date     DATE,
  revenue      NUMERIC(24,2),             -- 营收(元)
  net_profit   NUMERIC(24,2),             -- 净利润(元)
  net_profit_yoy NUMERIC(10,4),           -- 净利润同比%
  roe          NUMERIC(10,4),
  PRIMARY KEY (ts_code, end_date)
);
COMMENT ON TABLE financial IS '季/年度财报；S2论证两套钱分离(业绩增股价不涨)、S6小盘/业绩参考';
CREATE INDEX idx_fin_code ON financial(ts_code);

-- A15 交易日志（S8 用户自填，不爬）
CREATE TABLE trade_log (
  id           BIGINT      NOT NULL,
  trade_date   DATE,
  ts_code      VARCHAR(16),
  side         VARCHAR(4),                 -- buy / sell
  price        NUMERIC(12,4),
  qty          NUMERIC(20,2),
  reason       VARCHAR(256),               -- 买入逻辑(大势/热点/个股?)
  emotion_tag  VARCHAR(16),                -- 执行心态标签
  应对           VARCHAR(16),                -- 买对/买错/未明 三态处置
  PRIMARY KEY (id)
);
COMMENT ON TABLE trade_log IS '个人交易日志(S8)；用户手工录入或导入交割单，做心法量化复盘';
CREATE INDEX idx_trade_log_date ON trade_log(trade_date);

-- ============================================================================
--  PART B · 计算层结果表（系统每日批算写入，M1 算法产出；此处建表供落库）
--  说明：字段命名与 M1 文档 domain 类严格一致，Mapper 直接 upsert。
-- ============================================================================

-- B1 情绪温度（S2）
CREATE TABLE sentiment_daily (
  trade_date     DATE PRIMARY KEY,
  limit_up_cnt   INTEGER,                  -- 涨停家数
  limit_down_cnt INTEGER,                  -- 跌停家数
  max_board_pos  SMALLINT,                 -- 市场最高连板
  yest_limit_ret NUMERIC(10,4),            -- 昨日涨停今日平均收益(赚亏效应)
  thermal        NUMERIC(6,4),             -- 情绪温度 0~1(0冰点1高潮)
  regime         VARCHAR(8)                -- 冰点/复苏/高潮/退潮
);
COMMENT ON TABLE sentiment_daily IS '情绪温度(S2)；每日一条，M1 SentimentCalculator产出';

-- B2 主线识别（S4）
CREATE TABLE mainline_daily (
  trade_date   DATE NOT NULL,
  board_code   VARCHAR(16) NOT NULL,
  main_level   VARCHAR(8),                -- 主线/次主流/新题材/非主流（M1 MainlineDaily.level映射此列）
  strength     NUMERIC(8,4),               -- 板块强度分
  rank         INTEGER,
  PRIMARY KEY (board_code, trade_date)
);
COMMENT ON TABLE mainline_daily IS '主线识别(S4)；每日每板块一条，含等级与强度';

-- B3 龙头候选池（S4/S5）
CREATE TABLE leader_pool_daily (
  trade_date   DATE NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  board_code   VARCHAR(16),
  board_pos    SMALLINT,                   -- 板位
  role         VARCHAR(8),                -- 龙/妖/独狼/卡位/助攻/中军/后排
  score        NUMERIC(8,4),              -- 龙头相评分
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE leader_pool_daily IS '龙头候选池(S4/S5)；每日每股一条，含role与龙头相评分';

-- B4 趋势股候选（S6）
CREATE TABLE trend_candidate_daily (
  trade_date   DATE NOT NULL,
  ts_code      VARCHAR(16) NOT NULL,
  feature_hit  SMALLINT,                   -- 命中几大特征(0~8)
  rs_vs_index  NUMERIC(10,4),              -- 相对指数强度
  confirmed    SMALLINT DEFAULT 0,         -- 是否站上牛熊线且线上数周
  PRIMARY KEY (ts_code, trade_date)
);
COMMENT ON TABLE trend_candidate_daily IS '趋势股候选(S6)；feature_hit>=6且confirmed才入池';

-- B5 题材炒作因子（S7）
CREATE TABLE theme_factor_daily (
  trade_date   DATE NOT NULL,
  board_code   VARCHAR(16) NOT NULL,
  scarcity     NUMERIC(6,4),              -- 稀缺
  imagination  NUMERIC(6,4),              -- 想象空间
  sudden       NUMERIC(6,4),              -- 突发
  certainty    NUMERIC(6,4),              -- 肯定性
  min_resist   NUMERIC(6,4),              -- 最小阻力方向(势)
  total        NUMERIC(6,4),              -- 综合炒作因子分
  PRIMARY KEY (board_code, trade_date)
);
COMMENT ON TABLE theme_factor_daily IS '题材炒作因子(S7)；明牌已实(certainty过高+已大涨)反向预警';

-- B6 四维度评分（S1 大势择时）
CREATE TABLE four_dimension_daily (
  trade_date   DATE PRIMARY KEY,
  tech         NUMERIC(6,4),              -- 技术面维度分
  sentiment    NUMERIC(6,4),              -- 情绪维度分
  fund         NUMERIC(6,4),              -- 资金维度分
  policy       NUMERIC(6,4),              -- 政策维度分
  composite    NUMERIC(6,4),              -- 综合分(加权)
  worth_trade  SMALLINT DEFAULT 0,         -- 是否值得出手(composite>=0.4)
  note         VARCHAR(128)               -- 绝对性/相对性判定注记
);
COMMENT ON TABLE four_dimension_daily IS '四维度评分(S1)；综合<0.4判不值得出手(绝对性主导)';

-- ============================================================================
--  PART C · 幂等写入示例（爬虫/M1 Job 参考）
-- ============================================================================
-- 爬虫建议统一用 upsert，重复执行不报错：
-- INSERT INTO limit_pool(trade_date,ts_code,stock_name,limit_type,board_pos,...)
-- VALUES(...) ON CONFLICT(ts_code,trade_date)
-- DO UPDATE SET limit_type=EXCLUDED.limit_type, board_pos=EXCLUDED.board_pos, ...;
-- 计算层 M1 Mapper 已内置 ON CONFLICT ... DO UPDATE（见 M1 文档）。

-- ============================================================================
--  PART D · 爬虫底座支撑 + 数据溯源（M0：本项目爬虫工程对接用）
--  说明：
--   1) 每张 PART A 原始表加 data_source(0同花顺/1东财/2其他) + src_detail 溯源列。
--   2) 新增 crawl_task/crawl_log/crawl_alert/crawl_node 四张表支撑分布式爬虫底座。
--   3) 爬虫只写 PART A 原始层 + 这四个管理表；校验/清洗/计算(M1)在下游复盘后端做。
--   4) openGauss 基于 PostgreSQL，BIGSERIAL / SKIP LOCKED 均支持。
-- ============================================================================

-- ---------------------------------------------------------------------------
-- D0 · 给 PART A 所有原始表加溯源列
--    data_source: 0=同花顺 1=东财 2=其他；trade_log 为用户手工录入记 99
--    src_detail : 来源 URL / 接口 / 备注（全链路溯源用）
-- ---------------------------------------------------------------------------
ALTER TABLE index_daily       ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE index_daily       ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE stock_daily       ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE stock_daily       ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE stock_weekly      ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE stock_weekly      ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE limit_pool        ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE limit_pool        ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE strong_pool       ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE strong_pool       ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE board_daily       ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE board_daily       ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE stock_board_rel   ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE stock_board_rel   ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE dragon_tiger      ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE dragon_tiger      ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE dt_detail         ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE dt_detail         ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE main_fund_flow    ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE main_fund_flow    ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE northbound_flow   ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE northbound_flow   ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE news_event        ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE news_event        ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE concept           ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE concept           ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE financial         ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 1;
ALTER TABLE financial         ADD COLUMN src_detail  VARCHAR(256);
ALTER TABLE trade_log         ADD COLUMN data_source SMALLINT NOT NULL DEFAULT 99;  -- 99=用户手工
ALTER TABLE trade_log         ADD COLUMN src_detail  VARCHAR(256);

-- ---------------------------------------------------------------------------
-- D1 · 采集任务池（分布式真相源：认领 / 断点 / 去重 / 状态机）
-- ---------------------------------------------------------------------------
CREATE TABLE crawl_task (
  task_id       BIGSERIAL PRIMARY KEY,
  task_type     VARCHAR(32)  NOT NULL,        -- LIMIT_POOL/BOARD_DAILY/STOCK_DAILY/DRAGON_TIGER/MAIN_FUND...
  source        SMALLINT     NOT NULL,         -- 0同花顺 1东财 2其他（决定用哪个策略）
  url           TEXT,
  params_json   TEXT,                          -- 采集参数(股票/日期区间/分页大小等)
  status        VARCHAR(16)  NOT NULL DEFAULT 'PENDING',  -- PENDING/CLAIMED/SUCCESS/FAILED/RETRY/DEAD
  priority      INTEGER      DEFAULT 5,        -- 越大越先
  retry_count   INTEGER      DEFAULT 0,
  max_retry     INTEGER      DEFAULT 3,
  next_retry_at TIMESTAMP,                     -- RETRY 状态的下次执行时间
  last_node     VARCHAR(64),                   -- 最后认领节点(进度监控按节点聚合)
  started_at    TIMESTAMP,
  finished_at   TIMESTAMP,
  duration_ms   BIGINT,
  unique_key    VARCHAR(128) NOT NULL,         -- 去重键(如 LIMIT_POOL|2024-01-02|1) 防重复采集
  checkpoint    TEXT,                          -- 断点 JSON(已处理到的日期/页码) 续传用
  expected_count INTEGER,                      -- 数量校验预期(实际/预期偏差>阈值告警)
  actual_count  INTEGER,
  error_msg     TEXT,
  created_at    TIMESTAMP    DEFAULT now(),
  updated_at    TIMESTAMP    DEFAULT now(),
  UNIQUE (unique_key)                          -- 能力8：去重（同一 key 不会重复入队）
);
COMMENT ON TABLE crawl_task IS '采集任务池；节点用 SELECT...FOR UPDATE SKIP LOCKED 认领；checkpoint 支持断点续传；unique_key 去重';
CREATE INDEX idx_ct_status      ON crawl_task(status);
CREATE INDEX idx_ct_source      ON crawl_task(source);
CREATE INDEX idx_ct_type        ON crawl_task(task_type);
CREATE INDEX idx_ct_claim_order ON crawl_task(status, priority DESC, created_at);  -- 认领排序
CREATE INDEX idx_ct_started      ON crawl_task(started_at);  -- retryScan 僵尸回收按 started_at 扫
-- 若库已建，执行：ALTER TABLE crawl_task ADD INDEX idx_ct_started (started_at);
-- （openGauss 用 CREATE INDEX idx_ct_started ON crawl_task(started_at); 即可，ALTER 写法仅作兼容提示）

-- ---------------------------------------------------------------------------
-- D2 · 全链路采集日志（能力12：每个 URL 的采集轨迹）
-- ---------------------------------------------------------------------------
CREATE TABLE crawl_log (
  log_id       BIGSERIAL PRIMARY KEY,
  task_id      BIGINT,
  node         VARCHAR(64),
  url          TEXT,
  started_at   TIMESTAMP,
  finished_at  TIMESTAMP,
  duration_ms  BIGINT,
  http_status  INTEGER,
  result_status VARCHAR(16),                   -- SUCCESS/FAIL/RETRY
  bytes        BIGINT,
  error_msg    TEXT,
  created_at   TIMESTAMP    DEFAULT now()
);
COMMENT ON TABLE crawl_log IS '全链路采集日志；记录每个URL采集时间/结果/耗时/异常，便于排查';
CREATE INDEX idx_cl_task   ON crawl_log(task_id);
CREATE INDEX idx_cl_node   ON crawl_log(node);
CREATE INDEX idx_cl_result ON crawl_log(result_status);
CREATE INDEX idx_cl_time   ON crawl_log(created_at);

-- ---------------------------------------------------------------------------
-- D3 · 采集告警（能力7：数据量校验 / 异常 / 反爬 / 节点掉线）
-- ---------------------------------------------------------------------------
CREATE TABLE crawl_alert (
  alert_id     BIGSERIAL PRIMARY KEY,
  alert_type   VARCHAR(32)  NOT NULL,          -- VOLUME_DEVIATION/CRAWL_FAIL/ANTI_CRAWL/NODE_DOWN
  task_id      BIGINT,
  task_type    VARCHAR(32),
  trade_date   DATE,
  source       SMALLINT,
  severity     VARCHAR(8)   DEFAULT 'WARN',    -- INFO/WARN/ERROR
  message      TEXT,
  value_actual   NUMERIC(24,2),
  value_expected NUMERIC(24,2),
  resolved     SMALLINT     DEFAULT 0,
  created_at   TIMESTAMP    DEFAULT now()
);
COMMENT ON TABLE crawl_alert IS '采集告警；数量校验偏差超阈值/采集失败/反爬拦截/节点掉线均入此表，前端告警列表消费';
CREATE INDEX idx_ca_type     ON crawl_alert(alert_type);
CREATE INDEX idx_ca_resolved ON crawl_alert(resolved);
CREATE INDEX idx_ca_time     ON crawl_alert(created_at);

-- ---------------------------------------------------------------------------
-- D4 · 采集节点注册与心跳（能力6：按节点统计进度/成功率）
-- ---------------------------------------------------------------------------
CREATE TABLE crawl_node (
  node_id        VARCHAR(64) PRIMARY KEY,       -- 节点唯一标识(主机名+角色)
  node_name      VARCHAR(64),
  ip             VARCHAR(32),
  role           VARCHAR(16) DEFAULT 'MIXED',   -- API/BROWSER/MIXED
  status         VARCHAR(16) DEFAULT 'UP',       -- UP/DOWN
  last_heartbeat TIMESTAMP,
  running_tasks  INTEGER     DEFAULT 0,
  created_at     TIMESTAMP   DEFAULT now()
);
COMMENT ON TABLE crawl_node IS '采集节点注册表；Worker 定时心跳上报，监控按节点聚合进度与成功率';
CREATE INDEX idx_cn_status ON crawl_node(status);
