<template>
  <el-container class="app-shell">
    <el-header class="app-header">
      <div class="brand">
        <el-icon><Monitor /></el-icon>
        <span>股票爬虫监控</span>
      </div>
      <el-menu
        mode="horizontal"
        :router="true"
        class="app-menu"
        :default-active="activePath"
        background-color="transparent"
        text-color="#cfd8e3"
        active-text-color="#409eff"
      >
        <el-menu-item index="/dashboard">监控总览</el-menu-item>
        <el-menu-item index="/alerts">告警面板</el-menu-item>
      </el-menu>
    </el-header>
    <el-main class="app-main">
      <router-view />
    </el-main>
  </el-container>
</template>

<script setup>
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const route = useRoute()
const activePath = computed(() => route.path)
</script>

<style>
html,
body,
#app {
  margin: 0;
  height: 100%;
}
.app-shell {
  height: 100vh;
}
.app-header {
  display: flex;
  align-items: center;
  background: #001529;
  padding: 0 24px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 18px;
  font-weight: 600;
  color: #fff;
  margin-right: 40px;
  white-space: nowrap;
}
.app-menu {
  flex: 1;
  border-bottom: none;
}
.app-menu .el-menu-item {
  height: 60px;
  line-height: 60px;
}
.app-main {
  background: #f0f2f5;
  padding: 16px;
}
</style>
