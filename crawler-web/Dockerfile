# 前端监控大屏：nginx 托管 vite build 产物（dist/），并把 /api 反代到 crawler-admin。
# 构建期已用托管 node 跑过 `npm run build`，dist 随源码一起同步进镜像上下文。
FROM nginx:1.27-alpine

# SPA + /api 反代配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

# vite 构建产物
COPY dist /usr/share/nginx/html

EXPOSE 8091

CMD ["nginx", "-g", "daemon off;"]
