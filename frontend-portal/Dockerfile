# syntax=docker/dockerfile:1

# 构建阶段
FROM --platform=$BUILDPLATFORM node:20-alpine AS builder

WORKDIR /app

# 构建参数
#   NPM_REGISTRY  镜像源，默认走 .npmrc 中的配置，可按需覆盖
#   APP_VERSION   语义化版本（package.json version）
#   VCS_REF       git 短 commit
#   VCS_BRANCH    git 分支
#   BUILD_DATE    构建时间（RFC3339）
ARG NPM_REGISTRY
ARG APP_VERSION=0.0.0
ARG VCS_REF=unknown
ARG VCS_BRANCH=unknown
ARG BUILD_DATE=unknown

# 先复制依赖描述文件并安装依赖，单独分层以利用构建缓存
# （.dockerignore 已排除宿主 node_modules，不会覆盖镜像内的 Linux 依赖）
COPY package.json package-lock.json .npmrc ./
RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi \
    && npm ci

# 复制源代码后构建；版本信息通过环境变量注入 version.json
COPY . .
RUN APP_VERSION="$APP_VERSION" VCS_REF="$VCS_REF" VCS_BRANCH="$VCS_BRANCH" \
    npm run build

# 运行阶段
FROM --platform=$TARGETPLATFORM nginx:alpine

ARG APP_VERSION=0.0.0
ARG VCS_REF=unknown
ARG VCS_BRANCH=unknown
ARG BUILD_DATE=unknown

# 标准 OCI 标签：镜像可直接对应到代码版本
LABEL org.opencontainers.image.title="frontend-portal" \
      org.opencontainers.image.version="$APP_VERSION" \
      org.opencontainers.image.revision="$VCS_REF" \
      org.opencontainers.image.ref.name="$VCS_BRANCH" \
      org.opencontainers.image.created="$BUILD_DATE" \
      org.opencontainers.image.source="frontend-portal"

# 复制构建产物
COPY --from=builder /app/dist /usr/share/nginx/html

# nginx 配置以模板方式提供，容器启动时用环境变量替换 ${CONTAINER_PORT}/${BACKEND_URL}
COPY nginx.conf /etc/nginx/templates/default.conf.template

ENV CONTAINER_PORT=8081 \
    BACKEND_URL=http://host.docker.internal:8080

EXPOSE 8081

# 健康检查：验证 nginx 自身可用（/api 后端状态由冒烟脚本另行确认）
# 使用 shell form 以便展开 $CONTAINER_PORT（exec form 不做变量替换）
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${CONTAINER_PORT}/healthz" || exit 1

CMD ["nginx", "-g", "daemon off;"]
