# 统一入口：本地开发 / 构建 / 检查 / 容器发布
#
# 常用：
#   make install     安装（锁定版本，口径与容器一致）
#   make dev         本地开发（端口与容器同为 .env 中的 PORT）
#   make build       类型检查 + 生产构建 + 生成 version.json
#   make smoke       构建后起本地 preview 做冒烟（结束自动清理）
#   make image       构建容器镜像（带 commit 标签）
#   make deploy      构建 -> 临时容器冒烟 -> 正式上线
#   make clean       清理构建产物

SHELL := /bin/bash
ROOT  := $(CURDIR)
APP   := frontend-portal

# 读取根目录 .env（与 docker compose 同源）
ifneq (,$(wildcard .env))
include .env
endif
PORT ?= 8081
CONTAINER_PORT ?= 8081

export PORT CONTAINER_PORT
export VCS_REF     := $(shell git -c safe.directory='*' rev-parse --short HEAD 2>/dev/null || echo unknown)
export VCS_BRANCH  := $(shell git -c safe.directory='*' rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
export APP_VERSION := $(shell node -p "require('./frontend-portal/package.json').version" 2>/dev/null || echo 0.0.0)
export BUILD_DATE  := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

.DEFAULT_GOAL := help

.PHONY: help install dev build smoke image image-smoke deploy up down logs clean

help: ## 显示所有目标
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sed -E 's/^([a-zA-Z_-]+):[[:space:]]*##[[:space:]]*/\1|/' \
	  | awk -F'|' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## 按 lock 文件安装依赖（与容器构建同一口径 npm ci）
	cd $(APP) && npm ci

dev: ## 本地开发（http://localhost:$(PORT)，严格端口）
	cd $(APP) && npm run dev

build: ## 类型检查 + vite build + 生成 dist/version.json
	cd $(APP) && npm run build

smoke: ## 本地构建产物冒烟（vite preview，结束自动停服清理）
	./scripts/local-smoke.sh

image: ## 构建容器镜像 portal-frontend:$(VCS_REF)
	docker compose build

image-smoke: ## 对已构建镜像起一次性临时容器做冒烟（失败自动清理）
	./scripts/deploy.sh verify

deploy: ## 全流程：构建镜像 -> 临时容器冒烟 -> 正式上线
	./scripts/deploy.sh all

up: ## 直接启动/更新容器服务（保持原有 docker-compose up 用法可用）
	docker compose up -d --build

down: ## 停止并移除容器
	docker compose down

logs: ## 查看容器日志
	docker compose logs -f --tail=100

clean: ## 清理构建产物（vite build 本身也会先清空 dist）
	rm -rf $(APP)/dist
