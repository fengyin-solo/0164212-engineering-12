#!/usr/bin/env node
/**
 * 发布前冒烟检查（纯 Node 实现，无第三方依赖，本地 / CI / 容器三种场景通用）
 *
 * 用法：
 *   node scripts/smoke.mjs --base-url http://localhost:8081
 *   BASE_URL=http://localhost:8081 node scripts/smoke.mjs
 *
 * 检查项（任一失败立即以非 0 退出，便于 CI 卡点）：
 *   1) GET /healthz            存活探针，200
 *   2) GET /                   首页 HTML，200 且包含 <div id="app">
 *   3) GET /some/spa/route     SPA 回退到 index.html，200（验证 nginx try_files）
 *   4) GET /version.json       构建版本文件存在，且字段完整（产物可追溯到提交）
 *
 * 可选接口检查（有后端时开启，每个检查都会打印是哪一步、什么 HTTP 状态、什么原因）：
 *   API_CHECKS='GET /api/news/list?page=1&size=10' node scripts/smoke.mjs
 *   API_CHECKS='GET /api/news/list;POST /api/contact/submit' node scripts/smoke.mjs
 *
 * 可选静态资源检查：从首页 HTML 中解析 <script src> / <link href> 并逐一请求。
 *
 * 环境变量：
 *   BASE_URL       必填，被检查服务地址
 *   API_CHECKS     分号分隔的 "METHOD PATH" 列表
 *   SKIP_STATIC=1  跳过静态资源引用检查
 *   TIMEOUT_MS     单请求超时，默认 8000
 */

const args = process.argv.slice(2)
function argValue(name) {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? args[i + 1] : undefined
}

const BASE_URL = (argValue('base-url') || process.env.BASE_URL || '').replace(/\/+$/, '')
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 8000)

if (!BASE_URL) {
  console.error('用法: node scripts/smoke.mjs --base-url http://host:port')
  process.exit(2)
}

let step = 0
const failures = []
const startedAt = Date.now()

function log(status, title, detail = '') {
  const icon = status === 'PASS' ? '✅' : status === 'FAIL' ? '❌' : 'ℹ️ '
  const ts = new Date().toISOString()
  console.log(`${icon} [${ts}] 步骤${String(step).padStart(2, '0')} ${status}  ${title}${detail ? `\n    ${detail}` : ''}`)
}

/**
 * 发起一次请求并按预期断言；失败时把"哪一步/URL/状态码/原因"全部记录下来
 */
async function checkRequest(title, path, { expectStatus = 200, expectMatch, method = 'GET', body, headers } = {}) {
  step += 1
  const url = path.startsWith('http') ? path : `${BASE_URL}${path}`
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS)
  let res, text, errorKind, errorDetail
  try {
    res = await fetch(url, {
      method,
      signal: controller.signal,
      headers: { Accept: '*/*', ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined
    })
    text = await res.text()
  } catch (err) {
    if (err.name === 'AbortError') {
      errorKind = '超时'
      errorDetail = `${TIMEOUT_MS}ms 内无响应（服务未启动 / 端口不通 / 后端不可达？）`
    } else if (err.cause?.code === 'ECONNREFUSED') {
      errorKind = '连接被拒绝'
      errorDetail = `${BASE_URL} 没有进程监听（容器未就绪 / 端口映射错误？）`
    } else if (err.cause?.code === 'ENOTFOUND') {
      errorKind = '域名解析失败'
      errorDetail = err.message
    } else {
      errorKind = '请求异常'
      errorDetail = `${err.name}: ${err.message}`
    }
    log('FAIL', `${method} ${path} —— ${title}`, `原因: ${errorKind}｜${errorDetail}`)
    failures.push({ title, reason: `${errorKind}: ${errorDetail}` })
    return null
  } finally {
    clearTimeout(timer)
  }

  const okStatus = res.status === expectStatus
  const okMatch = !expectMatch || expectMatch.test(text)
  const snippet = text.slice(0, 200).replace(/\s+/g, ' ').trim()

  if (okStatus && okMatch) {
    log('PASS', `${method} ${path} —— ${title}`, `HTTP ${res.status}${expectMatch ? '，响应内容匹配' : ''}`)
    return { res, text }
  }

  const reasons = []
  if (!okStatus) reasons.push(`状态码期望 ${expectStatus}，实际 ${res.status}`)
  if (!okMatch) reasons.push(`响应未匹配 ${expectMatch}`)
  log('FAIL', `${method} ${path} —— ${title}`, `原因: ${reasons.join('；')}｜响应前 200 字: ${snippet}`)
  failures.push({ title, reason: reasons.join('；') })
  return null
}

async function main() {
  console.log(`\n🚦 冒烟检查开始  目标: ${BASE_URL}\n`)

  // 1) 存活探针
  await checkRequest('存活探针 /healthz', '/healthz', { expectMatch: /ok/i })

  // 2) 首页
  const home = await checkRequest('首页 HTML', '/', { expectMatch: /<div id="app">/ })

  // 3) SPA 路由回退
  await checkRequest('SPA 路由回退（深链接返回 index.html）', '/news/some-spa-route', {
    expectMatch: /<div id="app">/
  })

  // 4) 版本文件：保证产物可追溯
  const version = await checkRequest('构建版本文件 /version.json', '/version.json', {
    headers: { Accept: 'application/json' }
  })
  if (version) {
    let parsed
    try {
      parsed = JSON.parse(version.text)
    } catch {
      /* handled below */
    }
    const required = ['version', 'commit', 'branch', 'builtAt']
    const missing = required.filter((k) => !parsed?.[k])
    if (missing.length) {
      step += 1
      log('FAIL', 'version.json 字段完整性', `缺少字段: ${missing.join(', ')}`)
      failures.push({ title: 'version.json 字段完整性', reason: `缺少 ${missing.join(',')}` })
    } else {
      step += 1
      log('PASS', 'version.json 字段完整', `version=${parsed.version} commit=${parsed.commit} branch=${parsed.branch}`)
    }
  }

  // 5) 首页引用的静态资源（JS/CSS）全部可达
  if (!process.env.SKIP_STATIC && home?.text) {
    const assets = [
      ...home.text.matchAll(/<script[^>]+src="([^"]+)"/g),
      ...home.text.matchAll(/<link[^>]+href="([^"]+)"/g)
    ]
      .map((m) => m[1])
      .filter((u) => u.startsWith('/') && !u.startsWith('//'))
    const unique = [...new Set(assets)]
    if (unique.length === 0) {
      step += 1
      log('FAIL', '首页静态资源引用', '首页中未解析到任何 JS/CSS 引用，构建产物可能异常')
      failures.push({ title: '静态资源', reason: '未解析到资源引用' })
    }
    for (const asset of unique) {
      await checkRequest(`静态资源 ${asset.split('/').pop()}`, asset)
    }
  }

  // 6) 接口检查（可选）。后端不通时能明确看到是哪一条接口、什么状态码
  const apiChecks = (process.env.API_CHECKS || '')
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean)
  if (apiChecks.length) {
    console.log(`\n🔌 接口检查（${apiChecks.length} 条，约定 code=0/200 为业务成功）`)
    for (const item of apiChecks) {
      const m = item.match(/^(GET|POST|PUT|DELETE|PATCH)\s+(\S+)(?:\s+(\{.*\}))?$/i)
      if (!m) {
        step += 1
        log('FAIL', `接口规则解析: "${item}"`, '格式应为 "METHOD PATH [JSON]"，例如 GET /api/news/list')
        failures.push({ title: item, reason: '规则格式错误' })
        continue
      }
      const [, method, pathWithQuery, jsonBody] = m
      const result = await checkRequest(`接口 ${method} ${pathWithQuery.split('?')[0]}`, pathWithQuery, {
        method: method.toUpperCase(),
        body: jsonBody ? JSON.parse(jsonBody) : undefined
      })
      // 进一步校验业务码：HTTP 200 不代表业务成功
      if (result) {
        let biz
        try {
          biz = JSON.parse(result.text)
        } catch {
          /* 非 JSON 响应（如 502 网关错误已在状态码处暴露） */
        }
        if (biz && biz.code !== undefined && biz.code !== 0 && biz.code !== 200) {
          step += 1
          log('FAIL', `业务码 ${method} ${pathWithQuery.split('?')[0]}`, `HTTP 虽为 200，但业务 code=${biz.code}，message=${biz.message || ''}`)
          failures.push({ title: `业务码 ${pathWithQuery}`, reason: `code=${biz.code}` })
        }
      }
    }
  } else {
    console.log('\nℹ️  未配置 API_CHECKS，跳过后端接口检查（纯前端默认；联调时用 API_CHECKS="GET /api/news/list" 开启）')
  }

  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(1)
  console.log(`\n──────────────────────────────────────`)
  if (failures.length === 0) {
    console.log(`✅ 全部检查通过（${step} 步，耗时 ${elapsed}s）  目标: ${BASE_URL}\n`)
    process.exit(0)
  }
  console.log(`❌ ${failures.length} 项失败（共 ${step} 步，耗时 ${elapsed}s）  目标: ${BASE_URL}`)
  for (const f of failures) console.log(`   - ${f.title}: ${f.reason}`)
  console.log('')
  process.exit(1)
}

main().catch((err) => {
  console.error('冒烟脚本自身异常:', err)
  process.exit(2)
})
