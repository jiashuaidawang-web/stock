import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 开发期：把 /api 代理到 crawler-admin（端口 8081），避免跨域。
// 生产部署时可将前端静态产物由 admin 或 nginx 托管，并将 /api 反向代理到 admin。
export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:8081',
        changeOrigin: true
      }
    }
  }
})
