#!/usr/bin/env node
/**
 * 生成构建版本信息 dist/version.json
 *
 * 产物用于线上核对"这份产物对应哪次代码提交"：
 * - 本地构建：从 git 读取 commit / branch / 是否有未提交改动
 * - 容器构建：优先使用 Docker build-arg 注入的 VCS_REF / VCS_BRANCH
 *   （多阶段构建里没有 .git 目录，无法在镜像内执行 git）
 *
 * 该文件只写入 dist/，不污染源码目录；vite 每次构建会清空 dist，
 * 因此重跑构建不会残留上一次的版本文件。
 */
import { writeFileSync, mkdirSync, readFileSync, existsSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const outDir = resolve(projectRoot, 'dist')

function git(args) {
  try {
    // -c safe.directory 兼容容器中"仓库属主与执行用户不一致"的环境
    return execSync(
      `git -c safe.directory='*' ${args}`,
      { cwd: projectRoot, stdio: ['ignore', 'pipe', 'ignore'] }
    )
      .toString()
      .trim()
  } catch {
    return ''
  }
}

let pkgVersion = '0.0.0'
try {
  pkgVersion = JSON.parse(readFileSync(resolve(projectRoot, 'package.json'), 'utf-8')).version
} catch {
  /* ignore */
}

const commit = process.env.VCS_REF || git('rev-parse --short HEAD') || 'unknown'
const branch = process.env.VCS_BRANCH || git('rev-parse --abbrev-ref HEAD') || 'unknown'
const dirty = process.env.VCS_DIRTY !== undefined
  ? process.env.VCS_DIRTY === 'true'
  : Boolean(git('status --porcelain'))
const versionInfo = {
  name: 'frontend-portal',
  version: process.env.APP_VERSION || pkgVersion,
  commit,
  branch,
  dirty,
  builtAt: new Date().toISOString()
}

mkdirSync(outDir, { recursive: true })
writeFileSync(resolve(outDir, 'version.json'), JSON.stringify(versionInfo, null, 2) + '\n')
console.log(
  `[version] ${versionInfo.name}@${versionInfo.version} ` +
    `commit=${commit} branch=${branch} dirty=${dirty} builtAt=${versionInfo.builtAt}`
)

// 供 smoke 脚本做产物校验
if (!existsSync(resolve(outDir, 'index.html'))) {
  console.warn('[version] 注意：dist/index.html 不存在，请确认 vite build 已执行')
}
