# 门户网站前端项目

基于 Vue 3 + TypeScript + Vite + Pinia 构建的企业门户网站前端项目。

## How to Run

> 端口、依赖、检查已统一口径：
> - **端口单一来源**：仓库根目录 [.env](.env) 的 `PORT`（默认 `8081`），本地 `vite dev/preview` 与容器对外映射都读它，不会再出现两处端口不一致。
> - **依赖统一**：本地与容器都按 `package-lock.json` 执行 `npm ci`，镜像源由 [frontend-portal/.npmrc](frontend-portal/.npmrc) 统一控制。
> - **构建即检查**：构建产出 `dist/version.json`（含 git commit），发布前有分级冒烟检查（存活探针 / 首页 / SPA 回退 / 版本文件 / 静态资源 / 可选接口），每一步都会打印编号、目标、HTTP 状态码和失败原因。

### 本地开发（原有用法保持可用）

```bash
cd frontend-portal
npm ci          # 或 npm install；建议 ci，与容器构建同一口径
npm run dev     # 严格监听 http://localhost:8081，端口被占用会直接报错而不是静默换端口
```

### 一键串联流程（推荐，Make 封装）

```bash
make help        # 查看所有步骤
make install     # npm ci
make build       # vue-tsc 类型检查 + vite build + 生成 version.json
make smoke       # 构建后起本地 preview 跑冒烟，结束自动停服、不残留进程
make deploy      # 镜像构建 → 一次性临时容器冒烟 → 通过才正式上线
```

### Docker 部署（原有 docker compose 用法保持可用）

```bash
# 简单用法（与以前一致，版本标签退化为 local）
docker compose up --build -d

# 完整发布流程：构建带 commit 标签的镜像 → 临时容器冒烟 → 上线
./scripts/deploy.sh all
#   或分步执行（任一步失败后可单独重跑，不用从头来）
./scripts/deploy.sh build    # 仅构建
./scripts/deploy.sh verify   # 仅起临时容器冒烟（失败自动销毁，不留中间容器）
./scripts/deploy.sh up       # 仅上线
```

访问 http://localhost:8081

### 接口检查与失败定位

冒烟脚本 [scripts/smoke.mjs](scripts/smoke.mjs) 对每个检查项输出编号、URL、实际状态码和具体原因，例如：

- `连接被拒绝｜... 没有进程监听（容器未就绪 / 端口映射错误？）`
- `状态码期望 200，实际 502`（nginx 已明确区分"后端不可达"与页面问题）
- `HTTP 虽为 200，但业务 code=500`（接口通了但业务失败）

纯前端默认只检查页面与静态资源；接入后端后用 `API_CHECKS` 增加接口级检查：

```bash
# 本地 preview
API_CHECKS='GET /api/news/list?page=1&size=10' ./scripts/local-smoke.sh
# 容器临时实例
API_CHECKS='GET /api/news/list;POST /api/contact/submit' ./scripts/deploy.sh verify
```

容器内 `/api/` 代理到 `BACKEND_URL`（默认 `http://host.docker.internal:8080`，生产用环境变量覆盖），与 vite dev 的 proxy 行为一致（去掉 `/api` 前缀转发）。

### 版本核对（产物对应代码版本）

```bash
curl -s http://localhost:8081/version.json
# {"name":"frontend-portal","version":"1.0.0","commit":"26e6103","branch":"A",...}
docker inspect portal-frontend --format '{{json .Config.Labels}}'   # OCI 标签同样带 revision
```

### 失败重试与清理约定

- `make smoke` / `deploy.sh verify` 均在 `trap` 中回收临时进程/容器，**失败不留上次的中间产物**；直接重跑即可。
- `vite build` 每次构建先清空 `dist`，不会混入旧产物。
- CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）中每个 job 相互独立，可在 Actions 页面对失败的 job 单独 Re-run。

## Services

| 服务 | 端口 | 说明 |
|------|------|------|
| frontend-portal | 8081 | 门户网站前端（dev / preview / 容器对外一致） |

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
├── nginx.conf             # Nginx 配置
├── package.json           # 项目依赖
├── tsconfig.json          # TypeScript 配置
└── vite.config.ts         # Vite 配置
```

## 功能模块

- 首页 - Banner轮播、特色服务、新闻动态、产品展示
- 关于我们 - 公司简介、发展历程、团队介绍
- 新闻中心 - 新闻列表、分类筛选、详情页
- 产品服务 - 产品展示、分类筛选、详情弹窗
- 联系我们 - 联系信息、在线留言表单

## 开发命令

```bash
npm run dev      # 启动开发服务器
npm run build    # 构建生产版本
npm run preview  # 预览生产构建
npm run lint     # 代码检查
```
