# syntax=docker/dockerfile:1

# 构建阶段
FROM --platform=$BUILDPLATFORM node:20-alpine AS builder

WORKDIR /app

# 复制依赖文件（.npmrc 统一本地与容器的安装口径）
COPY package.json package-lock.json* .npmrc ./

# 安装依赖（BuildKit 缓存挂载，与本地共用同一套 npm 缓存机制）
RUN --mount=type=cache,target=/root/.npm npm ci

# 复制源代码
COPY . .

# 版本信息：由 CI 通过 --build-arg 注入，缺省时回退到 package.json / git
ARG APP_VERSION=""
ARG GIT_COMMIT=""
ENV VITE_APP_VERSION=$APP_VERSION \
    VITE_GIT_COMMIT=$GIT_COMMIT

# 构建
RUN npm run build

# 运行阶段
FROM --platform=$TARGETPLATFORM nginx:alpine

ARG APP_VERSION=""
ARG GIT_COMMIT=""

# 镜像可追溯：版本与代码提交写入 OCI label
LABEL org.opencontainers.image.title="frontend-portal" \
      org.opencontainers.image.version="${APP_VERSION:-unknown}" \
      org.opencontainers.image.revision="${GIT_COMMIT:-unknown}"

# 复制构建产物
COPY --from=builder /app/dist /usr/share/nginx/html

# 复制 nginx 配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
