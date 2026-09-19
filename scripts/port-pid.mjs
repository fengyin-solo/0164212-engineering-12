#!/usr/bin/env node
/**
 * 端口 -> 监听该端口的进程 PID
 *
 * 解析 /proc/net/tcp 与 tcp6 找到 LISTEN 状态的 socket inode，
 * 再遍历各进程 fd 目录里的 socket 符号链接反查归属进程。
 *
 * 用法：node scripts/port-pid.mjs <port>
 * 找到输出 PID 并退出 0；未找到无输出、退出 1。
 */
import { readFileSync, readdirSync, readlinkSync } from 'node:fs'

const port = Number(process.argv[2])
if (!port) {
  console.error('用法: node scripts/port-pid.mjs <port>')
  process.exit(2)
}
const hexPort = port.toString(16).padStart(4, '0').toUpperCase()

function listeningInodes() {
  const inodes = new Set()
  for (const file of ['/proc/net/tcp', '/proc/net/tcp6']) {
    let content
    try {
      content = readFileSync(file, 'utf-8')
    } catch {
      continue
    }
    for (const line of content.split('\n').slice(1)) {
      // sl  local_address  rem_address   st  tx_queue:rx_queue  tr:tm->when  retrnsmt  uid  timeout  inode
      // 用正则提取，避免空白列数量差异导致索引错位
      const m = line.match(
        /^\s*\d+:\s+(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{32}):([0-9A-Fa-f]{4})\s+\S+\s+([0-9A-Fa-f]{2})\s+\S+\s+\S+\s+\S+\s+\d+\s+\d+\s+(\d+)/
      )
      if (!m) continue
      const [, localPortHex, state, inode] = m
      if (state === '0A' && localPortHex === hexPort && inode !== '0') {
        inodes.add(inode)
      }
    }
  }
  return inodes
}

const wanted = listeningInodes()
if (wanted.size === 0) process.exit(1)

for (const pid of readdirSync('/proc').filter((n) => /^\d+$/.test(n))) {
  let fds
  try {
    fds = readdirSync(`/proc/${pid}/fd`)
  } catch {
    continue // 无权限或进程已退出
  }
  for (const fd of fds) {
    let link
    try {
      link = readlinkSync(`/proc/${pid}/fd/${fd}`)
    } catch {
      continue
    }
    const m = link.match(/^socket:\[(\d+)]$/)
    if (m && wanted.has(m[1])) {
      console.log(pid)
      process.exit(0)
    }
  }
}
process.exit(1)
