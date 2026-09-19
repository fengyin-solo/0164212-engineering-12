# 门户网站前端项目

基于 Vue 3 + TypeScript + Vite + Pinia 构建的企业门户网站前端项目。

## How to Run

### 本地开发

```bash
cd frontend-portal
npm ci        # 与容器构建同口径，严格按 lock 文件安装
npm run dev
```

访问 http://localhost:8081

### Docker 部署

```bash
docker-compose up --build -d
```

访问 http://localhost:8081

### 端口说明

本地开发服务器与容器对外端口**统一为 8081**，由根目录 `.env` 中的
`PORTAL_PORT` 单点控制（改一处，两处同时生效）：

- `npm run dev` / `npm run preview` 读取 `PORTAL_PORT`（默认 8081）
- `docker-compose.yml` 映射 `${PORTAL_PORT}:80`

## 构建与上线前检查流水线

`scripts/ci.sh` 把依赖安装、类型检查、构建、镜像打包、接口冒烟串成一条流程，
改完代码先跑一遍再上线，避免到线上才发现问题：

```bash
scripts/ci.sh              # 完整流程: clean → deps → typecheck → build → docker → smoke
scripts/ci.sh smoke        # 只重跑某一步（失败重试）
scripts/ci.sh --from build # 从某一步继续跑
scripts/ci.sh --local      # 无 Docker 环境：跳过镜像构建，冒烟改用本地 preview
scripts/ci.sh --list       # 查看所有步骤
```

| 步骤 | 内容 | 失败时可定位 |
|------|------|--------------|
| clean | 清理上次失败的中间产物（dist、临时文件、残留冒烟容器） | - |
| deps | `npm ci`，registry 与缓存口径见 `frontend-portal/.npmrc`（本地与容器共用） | 网络/lock 问题 |
| typecheck | `vue-tsc --noEmit` 类型检查 | 具体文件与行号 |
| build | `vite build`，产物写入版本元数据并校验与当前代码一致 | 构建错误 |
| docker | 构建镜像 `portal-frontend:<版本>-<commit>`，版本写入 OCI label | 镜像构建错误 |
| smoke | 启动产物（优先 Docker 容器，否则本地 preview），逐项校验接口响应 | 具体 URL、期望与实际 |

特性：

- **失败可定位**：每步日志写入 `.ci/logs/`，失败时打印步骤名、退出码、日志末尾与重跑命令
- **接口可确认**：冒烟逐项检查 `/healthz`（容器模式）、首页响应、`build-meta.json` 版本对应
- **版本可追溯**：产物 `dist/build-meta.json`、浏览器控制台、镜像 label 三处均可查到
  `版本号 + git commit`，与代码一一对应
- **可重试重跑**：任一步骤可单独重跑或从该步续跑；每步幂等
- **不留残留**：退出时自动清理冒烟容器/进程与临时文件，`clean` 步骤清理历史中间产物

## Services

| 服务 | 端口 | 说明 |
|------|------|------|
| frontend-portal | 8081 | 门户网站前端 |

## 测试账号

本项目为纯前端项目，无需登录账号。

## 题目内容

帮我初始化一个门户网站的前端项目，使用的技术栈是 Vue 3, TypeScript, Vite, Pinia。

---

## 技术栈

- Vue 3.4 - 渐进式 JavaScript 框架
- TypeScript 5.4 - 类型安全
- Vite 5.2 - 下一代前端构建工具
- Pinia 2.1 - Vue 状态管理
- Vue Router 4.3 - 官方路由
- Element Plus 2.6 - UI 组件库
- Axios 1.6 - HTTP 客户端
- Sass - CSS 预处理器

## 项目结构

```
frontend-portal/
├── public/                 # 静态资源
├── src/
│   ├── api/               # API 接口
│   ├── components/        # 公共组件
│   │   ├── common/        # 通用组件
│   │   └── layout/        # 布局组件
│   ├── router/            # 路由配置
│   ├── stores/            # Pinia 状态管理
│   ├── styles/            # 全局样式
│   ├── types/             # TypeScript 类型
│   ├── views/             # 页面视图
│   ├── App.vue            # 根组件
│   └── main.ts            # 入口文件
├── Dockerfile             # Docker 构建文件
├── nginx.conf             # Nginx 配置（含 /healthz 健康检查端点）
├── .npmrc                 # 依赖安装口径（本地与容器共用）
├── package.json           # 项目依赖
├── tsconfig.json          # TypeScript 配置
└── vite.config.ts         # Vite 配置（端口/版本注入）
```

## 功能模块

- 首页 - Banner轮播、特色服务、新闻动态、产品展示
- 关于我们 - 公司简介、发展历程、团队介绍
- 新闻中心 - 新闻列表、分类筛选、详情页
- 产品服务 - 产品展示、分类筛选、详情弹窗
- 联系我们 - 联系信息、在线留言表单

## 开发命令

```bash
npm run dev        # 启动开发服务器 (端口同容器对外口径: 8081)
npm run build      # 构建生产版本（含类型检查与版本元数据）
npm run preview    # 预览生产构建
npm run typecheck  # 仅类型检查
npm run clean      # 清理构建产物
```
