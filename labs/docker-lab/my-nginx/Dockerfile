# 基础镜像
FROM nginx:1.25

# 作者信息（可选，类似注释）
LABEL maintainer="xia@local"

# 复制自定义首页
COPY index.html /usr/share/nginx/html/index.html

# 复制自定义 Nginx 配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

# 暴露 80 端口（文档声明，不是真的映射）
EXPOSE 80

# 容器启动时执行的命令（基础镜像已有 CMD，这里可以不写）
# CMD ["nginx", "-g", "daemon off;"]
