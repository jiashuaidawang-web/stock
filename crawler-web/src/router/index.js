import { createRouter, createWebHistory } from 'vue-router'
import MonitorDashboard from '../views/MonitorDashboard.vue'
import AlertPanel from '../views/AlertPanel.vue'

// 监控总览（M5）为默认落地页；告警面板（M4）为子页。
const routes = [
  { path: '/', redirect: '/dashboard' },
  { path: '/dashboard', name: 'dashboard', component: MonitorDashboard, meta: { title: '监控总览' } },
  { path: '/alerts', name: 'alerts', component: AlertPanel, meta: { title: '告警面板' } }
]

export default createRouter({
  history: createWebHistory(),
  routes
})
