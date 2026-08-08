<template>
  <div class="dash">
    <!-- 头部：标题 + 自动刷新 + 最后更新 -->
    <el-card shadow="never" class="dash-head">
      <div class="head-left">
        <el-icon class="head-icon"><DataLine /></el-icon>
        <span class="head-title">监控总览</span>
      </div>
      <div class="head-right">
        <span class="updated">最后更新：{{ lastUpdated }}</span>
        <el-switch
          v-model="autoRefresh"
          active-text="自动刷新"
          @change="onAutoChange"
        />
        <span v-if="autoRefresh" class="refresh-hint">每 {{ pollSeconds }}s</span>
        <el-button :icon="RefreshRight" :loading="loading" @click="refreshAll">刷新</el-button>
      </div>
    </el-card>

    <!-- 汇总卡片 -->
    <el-row :gutter="16" class="stat-row">
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-label">任务总数</div>
          <div class="stat-value">{{ overview.total }}</div>
          <div class="stat-sub">成功 {{ statusCount('SUCCESS') }} · 执行中 {{ statusCount('CLAIMED') + statusCount('PENDING') }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-label">任务成功率</div>
          <div class="stat-value" :style="{ color: rateColor(overview.successRate) }">
            {{ overview.successRate.toFixed(1) }}%
          </div>
          <div class="stat-sub">基于任务状态统计</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card danger">
          <div class="stat-label">失败 / 重试</div>
          <div class="stat-value">{{ statusCount('DEAD') }}</div>
          <div class="stat-sub">重试中 {{ statusCount('RETRY') }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="stat-card">
          <div class="stat-label">节点</div>
          <div class="stat-value">{{ nodes.length }}</div>
          <div class="stat-sub">在线 {{ healthyCount }}</div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 图表行 1：成功率仪表盘 + 状态分布 + 数据源分布 -->
    <el-row :gutter="16" class="chart-row">
      <el-col :span="8">
        <el-card shadow="hover" class="chart-card">
          <div class="chart-title">任务成功率</div>
          <div ref="gaugeRef" class="chart-box"></div>
        </el-card>
      </el-col>
      <el-col :span="8">
        <el-card shadow="hover" class="chart-card">
          <div class="chart-title">任务状态分布</div>
          <div ref="statusRef" class="chart-box"></div>
        </el-card>
      </el-col>
      <el-col :span="8">
        <el-card shadow="hover" class="chart-card">
          <div class="chart-title">按数据源分布</div>
          <div ref="sourceRef" class="chart-box"></div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 图表行 2：节点分布柱状 + 节点心跳表 -->
    <el-row :gutter="16" class="chart-row">
      <el-col :span="10">
        <el-card shadow="hover" class="chart-card">
          <div class="chart-title">按节点分布</div>
          <div ref="nodeRef" class="chart-box"></div>
        </el-card>
      </el-col>
      <el-col :span="14">
        <el-card shadow="hover" class="chart-card">
          <div class="chart-title">节点心跳</div>
          <el-table :data="nodes" v-loading="loadingNodes" max-height="320" stripe>
            <el-table-column prop="nodeId" label="节点ID" width="130" />
            <el-table-column prop="nodeName" label="名称" width="120" show-overflow-tooltip />
            <el-table-column prop="ip" label="IP" width="130" />
            <el-table-column prop="role" label="角色" width="90" />
            <el-table-column label="状态" width="90">
              <template #default="{ row }">
                <el-tag :type="nodeStatusTag(row)" effect="dark">{{ row.status || '未知' }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="runningTasks" label="运行任务" width="90" />
            <el-table-column label="心跳" min-width="170">
              <template #default="{ row }">
                <span :style="{ color: isStale(row.lastHeartbeat) ? '#f56c6c' : '#606266' }">
                  {{ fmtTime(row.lastHeartbeat) }}
                  <span v-if="row.lastHeartbeat != null" class="heart-age">
                    ({{ ageText(row.lastHeartbeat) }})
                  </span>
                </span>
              </template>
            </el-table-column>
            <el-table-column label="健康" width="80">
              <template #default="{ row }">
                <el-tag :type="row.healthy ? 'success' : 'danger'" effect="plain">
                  {{ row.healthy ? '正常' : '异常' }}
                </el-tag>
              </template>
            </el-table-column>
          </el-table>
        </el-card>
      </el-col>
    </el-row>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { ElMessage } from 'element-plus'
import { DataLine, RefreshRight } from '@element-plus/icons-vue'
import * as echarts from 'echarts'
import { getStats, getStatsBySource, getStatsByNode, getNodes } from '../api/crawler.js'

// ---------- 常量映射 ----------
const STATUS_COLOR = {
  PENDING: '#909399',
  CLAIMED: '#409eff',
  SUCCESS: '#67c23a',
  RETRY: '#e6a23c',
  DEAD: '#f56c6c'
}
const SOURCE_MAP = { 0: '同花顺', 1: '东财', 2: '其他' }
const SOURCE_COLOR = { 0: '#409eff', 1: '#67c23a', 2: '#e6a23c' }

// ---------- 状态 ----------
const loading = ref(false)
const loadingNodes = ref(false)
const lastUpdated = ref('-')

const overview = reactive({ total: 0, successRate: 0, byStatus: [] })
const sourceData = ref([]) // [{ source, cnt }]
const nodeData = ref([]) // [{ node, cnt }]
const nodes = ref([]) // [{ nodeId,..., healthy }]

const autoRefresh = ref(true)
const pollSeconds = 15
let timer = null

// 图表实例
const gaugeRef = ref(null)
const statusRef = ref(null)
const sourceRef = ref(null)
const nodeRef = ref(null)
let gaugeChart = null
let statusChart = null
let sourceChart = null
let nodeChart = null

// ---------- 计算 ----------
const statusMap = computed(() => {
  const m = {}
  for (const s of overview.byStatus || []) m[s.status] = s.cnt
  return m
})
function statusCount(st) {
  return statusMap.value[st] || 0
}
const healthyCount = computed(() => nodes.value.filter((n) => n.healthy).length)

function rateColor(r) {
  if (r >= 95) return '#67c23a'
  if (r >= 80) return '#e6a23c'
  return '#f56c6c'
}

// 节点心跳新鲜度：超过 60s 视为陈旧
function heartAgeMs(v) {
  if (v == null) return null
  let d
  if (Array.isArray(v)) {
    // [Y,M,D,H,m,s]（Spring 默认序列化 LocalDateTime 为数组）
    d = new Date(v[0], (v[1] || 1) - 1, v[2] || 1, v[3] || 0, v[4] || 0, v[5] || 0)
  } else {
    d = new Date(v)
  }
  if (isNaN(d.getTime())) return null
  return Date.now() - d.getTime()
}
function isStale(v) {
  const age = heartAgeMs(v)
  return age != null && age > 60 * 1000
}
function fmtTime(v) {
  if (v == null) return '-'
  if (Array.isArray(v)) {
    const p = (n) => String(n).padStart(2, '0')
    return `${v[0]}-${p(v[1])}-${p(v[2])} ${p(v[3] || 0)}:${p(v[4] || 0)}:${p(v[5] || 0)}`
  }
  return String(v)
}
function ageText(v) {
  const age = heartAgeMs(v)
  if (age == null) return ''
  const s = Math.floor(age / 1000)
  if (s < 60) return `${s}秒前`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}分前`
  return `${Math.floor(m / 60)}小时前`
}
function nodeStatusTag(row) {
  if (row.status === 'ONLINE' || row.status === 'RUNNING') return 'success'
  if (row.status === 'BUSY') return 'warning'
  return 'danger'
}

// ---------- 数据拉取 ----------
async function refreshAll() {
  loading.value = true
  try {
    const [statsRes, srcRes, nodeRes] = await Promise.all([
      getStats(),
      getStatsBySource(),
      getStatsByNode()
    ])
    const st = statsRes.data || {}
    overview.total = st.total || 0
    overview.successRate = st.successRate || 0
    overview.byStatus = st.byStatus || []
    sourceData.value = srcRes.data || []
    nodeData.value = nodeRes.data || []
    lastUpdated.value = new Date().toLocaleTimeString('zh-CN', { hour12: false })
  } catch (e) {
    ElMessage.error('加载统计失败：' + (e.message || e))
  } finally {
    loading.value = false
  }
  // 节点心跳单独拉，失败不影响统计
  loadingNodes.value = true
  try {
    const nRes = await getNodes()
    const list = (nRes.data || []).map((n) => ({
      ...n,
      healthy: (n.status === 'ONLINE' || n.status === 'RUNNING') && !isStale(n.lastHeartbeat)
    }))
    // 按心跳新鲜度排序：异常在前
    list.sort((a, b) => (a.healthy === b.healthy ? 0 : a.healthy ? 1 : -1))
    nodes.value = list
  } catch (e) {
    ElMessage.error('加载节点失败：' + (e.message || e))
  } finally {
    loadingNodes.value = false
  }
  renderCharts()
}

// ---------- 图表 ----------
function initCharts() {
  gaugeChart = echarts.init(gaugeRef.value)
  statusChart = echarts.init(statusRef.value)
  sourceChart = echarts.init(sourceRef.value)
  nodeChart = echarts.init(nodeRef.value)
  window.addEventListener('resize', onResize)
}
function onResize() {
  gaugeChart && gaugeChart.resize()
  statusChart && statusChart.resize()
  sourceChart && sourceChart.resize()
  nodeChart && nodeChart.resize()
}
function renderCharts() {
  if (!gaugeChart) return
  // 成功率仪表盘
  gaugeChart.setOption({
    series: [
      {
        type: 'gauge',
        min: 0,
        max: 100,
        progress: { show: true, width: 14 },
        axisLine: {
          lineStyle: {
            width: 14,
            color: [
              [0.8, '#f56c6c'],
              [0.95, '#e6a23c'],
              [1, '#67c23a']
            ]
          }
        },
        detail: { formatter: '{value}%', fontSize: 26, color: rateColor(overview.successRate) },
        data: [{ value: Number(overview.successRate.toFixed(1)), name: '成功率' }]
      }
    ]
  })
  // 状态分布环形
  statusChart.setOption({
    tooltip: { trigger: 'item' },
    legend: { bottom: 0, type: 'scroll' },
    series: [
      {
        type: 'pie',
        radius: ['40%', '70%'],
        avoidLabelOverlap: true,
        label: { show: false },
        data: (overview.byStatus || []).map((s) => ({
          name: s.status,
          value: s.cnt,
          itemStyle: { color: STATUS_COLOR[s.status] || '#909399' }
        }))
      }
    ]
  })
  // 数据源分布
  sourceChart.setOption({
    tooltip: { trigger: 'item' },
    legend: { bottom: 0 },
    series: [
      {
        type: 'pie',
        radius: ['40%', '70%'],
        label: { show: false },
        data: (sourceData.value || []).map((s) => ({
          name: SOURCE_MAP[s.source] || String(s.source),
          value: s.cnt,
          itemStyle: { color: SOURCE_COLOR[s.source] || '#909399' }
        }))
      }
    ]
  })
  // 节点分布柱状（横向）
  nodeChart.setOption({
    tooltip: { trigger: 'axis', axisPointer: { type: 'shadow' } },
    grid: { left: 12, right: 24, top: 16, bottom: 8, containLabel: true },
    xAxis: { type: 'value' },
    yAxis: {
      type: 'category',
      data: (nodeData.value || []).map((n) => n.node)
    },
    series: [
      {
        type: 'bar',
        data: (nodeData.value || []).map((n) => n.cnt),
        itemStyle: { color: '#409eff' },
        barWidth: '55%'
      }
    ]
  })
}

// ---------- 自动刷新 ----------
function onAutoChange(val) {
  if (val) startTimer()
  else stopTimer()
}
function startTimer() {
  stopTimer()
  timer = setInterval(refreshAll, pollSeconds * 1000)
}
function stopTimer() {
  if (timer) {
    clearInterval(timer)
    timer = null
  }
}

onMounted(() => {
  nextTick(() => {
    initCharts()
    refreshAll()
  })
  if (autoRefresh.value) startTimer()
})
onBeforeUnmount(() => {
  stopTimer()
  window.removeEventListener('resize', onResize)
  gaugeChart && gaugeChart.dispose()
  statusChart && statusChart.dispose()
  sourceChart && sourceChart.dispose()
  nodeChart && nodeChart.dispose()
})
</script>

<style scoped>
.dash {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.dash-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.head-left {
  display: flex;
  align-items: center;
  gap: 8px;
}
.head-icon {
  font-size: 20px;
  color: #409eff;
}
.head-title {
  font-size: 18px;
  font-weight: 600;
  color: #303133;
}
.head-right {
  display: flex;
  align-items: center;
  gap: 12px;
}
.updated {
  color: #909399;
  font-size: 13px;
}
.refresh-hint {
  color: #909399;
  font-size: 12px;
}
.stat-row .stat-card {
  text-align: center;
}
.stat-label {
  color: #909399;
  font-size: 13px;
  margin-bottom: 8px;
}
.stat-value {
  font-size: 30px;
  font-weight: 700;
  color: #303133;
}
.stat-card.danger .stat-value {
  color: #f56c6c;
}
.stat-sub {
  margin-top: 6px;
  color: #c0c4cc;
  font-size: 12px;
}
.chart-row .chart-card {
  display: flex;
  flex-direction: column;
}
.chart-title {
  font-size: 14px;
  font-weight: 600;
  color: #606266;
  margin-bottom: 8px;
}
.chart-box {
  width: 100%;
  height: 300px;
}
</style>
