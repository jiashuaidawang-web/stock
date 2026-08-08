import axios from 'axios'

// 所有请求走 /api，由 vite dev proxy（或生产 nginx）转发到 crawler-admin:8081
const http = axios.create({
  baseURL: '/api',
  timeout: 10000
})

// 采集告警列表。resolved: 0=未处理 1=已处理（不传/其他=按传入值查，前端用 0/1/2 表示「全部」时单独处理）
export function getAlerts(resolved) {
  return http.get('/crawl/alerts', { params: { resolved } })
}

// 标记告警已处理
export function resolveAlert(alertId) {
  return http.post(`/crawl/alerts/${alertId}/resolve`)
}

// 任务总体统计（状态计数 + 成功率）
export function getStats() {
  return http.get('/crawl/stats')
}

// 按数据源分布：[{ source, cnt }]
export function getStatsBySource() {
  return http.get('/crawl/stats', { params: { groupBy: 'source' } })
}

// 按节点分布：[{ node, cnt }]
export function getStatsByNode() {
  return http.get('/crawl/stats', { params: { groupBy: 'node' } })
}

// 节点列表与心跳
export function getNodes() {
  return http.get('/crawl/nodes')
}

export default http
