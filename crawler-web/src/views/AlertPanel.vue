<template>
  <div class="alert-panel">
    <!-- 汇总卡片：未处理总数 + 按级别拆分（基于当前筛选后的数据计算） -->
    <el-row :gutter="16" class="summary-row">
      <el-col :span="6">
        <el-card shadow="hover" class="summary-card">
          <div class="summary-label">未处理告警</div>
          <div class="summary-value">{{ unresolvedCount }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="summary-card error">
          <div class="summary-label">ERROR</div>
          <div class="summary-value">{{ severityCount('ERROR') }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="summary-card warn">
          <div class="summary-label">WARN</div>
          <div class="summary-value">{{ severityCount('WARN') }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card shadow="hover" class="summary-card info">
          <div class="summary-label">INFO</div>
          <div class="summary-value">{{ severityCount('INFO') }}</div>
        </el-card>
      </el-col>
    </el-row>

    <!-- 筛选条 -->
    <el-card shadow="never" class="filter-card">
      <el-form :inline="true" :model="filters" class="filter-form">
        <el-form-item label="处理状态">
          <el-radio-group v-model="filters.resolved">
            <el-radio-button :value="0">未处理</el-radio-button>
            <el-radio-button :value="1">已处理</el-radio-button>
            <el-radio-button :value="2">全部</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="级别">
          <el-select v-model="filters.severity" placeholder="全部" clearable style="width: 120px">
            <el-option label="全部" value="" />
            <el-option label="ERROR" value="ERROR" />
            <el-option label="WARN" value="WARN" />
            <el-option label="INFO" value="INFO" />
          </el-select>
        </el-form-item>
        <el-form-item label="类型">
          <el-select v-model="filters.type" placeholder="全部" clearable style="width: 160px">
            <el-option label="全部" value="" />
            <el-option v-for="t in typeOptions" :key="t" :label="t" :value="t" />
          </el-select>
        </el-form-item>
        <el-form-item label="数据源">
          <el-select v-model="filters.source" placeholder="全部" clearable style="width: 120px">
            <el-option label="全部" value="" />
            <el-option label="同花顺" :value="0" />
            <el-option label="东财" :value="1" />
            <el-option label="其他" :value="2" />
          </el-select>
        </el-form-item>
        <el-form-item>
          <el-button type="primary" :icon="Search" @click="fetchAlerts">查询</el-button>
          <el-button :icon="Refresh" @click="resetFilters">重置</el-button>
        </el-form-item>
        <el-form-item class="auto-refresh">
          <el-switch v-model="autoRefresh" active-text="自动刷新" @change="onAutoRefreshChange" />
          <span v-if="autoRefresh" class="refresh-hint">每 {{ pollSeconds }}s</span>
        </el-form-item>
        <el-form-item>
          <el-button :icon="RefreshRight" :loading="loading" @click="fetchAlerts">刷新</el-button>
        </el-form-item>
      </el-form>
    </el-card>

    <!-- 告警表格 -->
    <el-card shadow="never" class="table-card">
      <el-table
        :data="pagedData"
        v-loading="loading"
        stripe
        style="width: 100%"
        empty-text="暂无告警"
      >
        <el-table-column prop="alertType" label="类型" width="160" />
        <el-table-column label="级别" width="100">
          <template #default="{ row }">
            <el-tag :type="severityTag(row.severity)" effect="dark">{{ row.severity || '-' }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="taskId" label="任务ID" width="120" />
        <el-table-column prop="taskType" label="任务类型" width="150" />
        <el-table-column label="数据源" width="100">
          <template #default="{ row }">{{ sourceLabel(row.source) }}</template>
        </el-table-column>
        <el-table-column prop="message" label="信息" min-width="280" show-overflow-tooltip />
        <el-table-column label="实际/期望" width="160">
          <template #default="{ row }">
            <span v-if="row.valueActual != null || row.valueExpected != null">
              {{ fmt(row.valueActual) }} / {{ fmt(row.valueExpected) }}
            </span>
            <span v-else>-</span>
          </template>
        </el-table-column>
        <el-table-column prop="createdAt" label="创建时间" width="180" />
        <el-table-column label="操作" width="120" fixed="right">
          <template #default="{ row }">
            <el-button
              v-if="row.resolved === 0 || row.resolved === '0'"
              type="success"
              size="small"
              :icon="Check"
              @click="onResolve(row)"
            >标记已处理</el-button>
            <el-tag v-else type="info" size="small">已处理</el-tag>
          </template>
        </el-table-column>
      </el-table>

      <el-pagination
        class="table-pager"
        layout="total, sizes, prev, pager, next"
        :total="filteredData.length"
        :page-size="pageSize"
        :current-page="currentPage"
        :page-sizes="[10, 20, 50, 100]"
        @size-change="onSizeChange"
        @current-change="onPageChange"
      />
    </el-card>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { Search, Refresh, RefreshRight, Check } from '@element-plus/icons-vue'
import { getAlerts, resolveAlert } from '../api/crawler.js'

const loading = ref(false)
const rawList = ref([]) // 后端原始数据（按 resolved 维度一次取回）
const typeOptions = ref([]) // 动态从数据里提取类型去重

const filters = reactive({
  resolved: 0, // 0 未处理 / 1 已处理 / 2 全部
  severity: '',
  type: '',
  source: ''
})

const autoRefresh = ref(true)
const pollSeconds = 15
let timer = null

// 分页
const currentPage = ref(1)
const pageSize = ref(20)

// 数据源枚举
const SOURCE_MAP = { 0: '同花顺', 1: '东财', 2: '其他' }
function sourceLabel(s) {
  if (s === null || s === undefined || s === '') return '-'
  return SOURCE_MAP[s] || String(s)
}

// 级别 → el-tag 类型
function severityTag(sev) {
  if (sev === 'ERROR') return 'danger'
  if (sev === 'WARN') return 'warning'
  if (sev === 'INFO') return 'info'
  return 'info'
}

function fmt(v) {
  if (v === null || v === undefined) return '-'
  return v
}

// 兼容后端 resolved 可能是数字或字符串
function isResolved(row) {
  return row.resolved === 1 || row.resolved === '1'
}

// 根据筛选条件过滤（前端侧，避免多次打后端）
const filteredData = computed(() => {
  return rawList.value.filter((row) => {
    // resolved 维度：2=全部，0/1=精确
    if (filters.resolved !== 2 && (isResolved(row) ? 1 : 0) !== filters.resolved) {
      return false
    }
    if (filters.severity && row.severity !== filters.severity) return false
    if (filters.type && row.alertType !== filters.type) return false
    if (filters.source !== '' && String(row.source) !== String(filters.source)) return false
    return true
  })
})

const pagedData = computed(() => {
  const start = (currentPage.value - 1) * pageSize.value
  return filteredData.value.slice(start, start + pageSize.value)
})

// 汇总：未处理总数（只看未处理维度里筛后的条数）
const unresolvedCount = computed(() => {
  return rawList.value.filter((row) => !isResolved(row)).length
})
function severityCount(sev) {
  return filteredData.value.filter((row) => row.severity === sev).length
}

async function fetchAlerts() {
  loading.value = true
  try {
    // 取「全部」一次，前端按需筛选；resolved=2 后端按原值返回，这里分开取更稳：
    // 未处理视图取 resolved=0，已处理/全部视图取 resolved=1 再合并。
    // 简化：分两次取 0 与 1 合并成全集，保证筛选「全部」可用。
    const [un, done] = await Promise.all([
      getAlerts(0),
      getAlerts(1)
    ])
    const list = [...(un.data || []), ...(done.data || [])]
    rawList.value = list
    // 动态类型选项
    const set = new Set(list.map((r) => r.alertType).filter(Boolean))
    typeOptions.value = Array.from(set)
    // 重置到第一页，避免筛选后越界
    currentPage.value = 1
  } catch (e) {
    ElMessage.error('加载告警失败：' + (e.message || e))
  } finally {
    loading.value = false
  }
}

function resetFilters() {
  filters.resolved = 0
  filters.severity = ''
  filters.type = ''
  filters.source = ''
  fetchAlerts()
}

async function onResolve(row) {
  try {
    await ElMessageBox.confirm(`确认标记告警 #${row.alertId} 为已处理？`, '提示', {
      type: 'warning',
      confirmButtonText: '标记',
      cancelButtonText: '取消'
    })
  } catch {
    return // 取消
  }
  try {
    const r = await resolveAlert(row.alertId)
    if (r.data && r.data.resolved > 0) {
      ElMessage.success('已标记为已处理')
      // 直接在前端把该行置为已处理，避免整表重拉
      row.resolved = 1
    } else {
      ElMessage.warning('未找到该告警或已处理')
    }
  } catch (e) {
    ElMessage.error('操作失败：' + (e.message || e))
  }
}

function onAutoRefreshChange(val) {
  if (val) {
    startTimer()
  } else {
    stopTimer()
  }
}
function startTimer() {
  stopTimer()
  timer = setInterval(() => {
    // 自动刷新时若停留在「已处理」或「全部」也照常拉，保证数据新鲜
    fetchAlerts()
  }, pollSeconds * 1000)
}
function stopTimer() {
  if (timer) {
    clearInterval(timer)
    timer = null
  }
}

function onSizeChange(s) {
  pageSize.value = s
  currentPage.value = 1
}
function onPageChange(p) {
  currentPage.value = p
}

onMounted(() => {
  fetchAlerts()
  if (autoRefresh.value) startTimer()
})
onBeforeUnmount(() => stopTimer())
</script>

<style scoped>
.alert-panel {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.summary-row .summary-card {
  text-align: center;
}
.summary-label {
  color: #909399;
  font-size: 13px;
  margin-bottom: 8px;
}
.summary-value {
  font-size: 28px;
  font-weight: 700;
  color: #303133;
}
.summary-card.error .summary-value {
  color: #f56c6c;
}
.summary-card.warn .summary-value {
  color: #e6a23c;
}
.summary-card.info .summary-value {
  color: #409eff;
}
.filter-form {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
}
.filter-form .el-form-item {
  margin-bottom: 0;
  margin-right: 16px;
}
.auto-refresh {
  display: flex;
  align-items: center;
}
.refresh-hint {
  margin-left: 8px;
  color: #909399;
  font-size: 12px;
}
.table-card {
  margin-top: 4px;
}
.table-pager {
  margin-top: 16px;
  justify-content: flex-end;
}
</style>
