#!/usr/bin/env node
// 会话数据路径改写：/home/zed → /home/dsh（dsh 数据卷内执行，幂等）。
//
// 会话历史按工作区绝对路径索引，三处都要跟着改：
//   1. storages/*.json（workspace.json 的 path、session_projcache 的 identity.cwd 等）
//   2. sessions/ 下的目录名：encode(path) = '-' + path.replace(/[^A-Za-z0-9]/g,'-') + '-'
//   3. --headers：每个会话文件【首帧】记录里的 cwd（多 frame zstd 只解首帧，正文不动）
//
// 用法：node rewrite-paths.mjs <dsh-data 卷挂载点> [--headers]
//        只改 JSON 与目录名（默认）；加 --headers 才碰会话文件首帧。
import { readdirSync, readFileSync, writeFileSync, renameSync, statSync, existsSync } from 'node:fs'
import { join, basename } from 'node:path'
import zlib from 'node:zlib'

const ROOT = process.argv[2]
const DEEP_HEADERS = process.argv.includes('--headers')
const OLD = '/home/zed'
const NEW = '/home/dsh'
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])

if (!ROOT || !existsSync(ROOT)) {
  console.error('usage: node rewrite-paths.mjs <root> [--headers]')
  process.exit(2)
}

let jsonChanged = 0
let dirsRenamed = 0
let headersChanged = 0

// ---------------------------------------------------------------- 1. JSON 索引
function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    let st
    try { st = statSync(p) } catch { continue }
    if (st.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

const storages = join(ROOT, 'storages')
if (existsSync(storages)) {
  const re = /\/home\/zed(?=\/|")/g
  for (const file of walk(storages)) {
    if (!file.endsWith('.json')) continue
    const src = readFileSync(file, 'utf8')
    if (!re.test(src)) { re.lastIndex = 0; continue }
    re.lastIndex = 0
    const dst = src.replace(re, NEW)
    writeFileSync(file + '.rewrite-tmp', dst)
    renameSync(file + '.rewrite-tmp', file)
    jsonChanged++
  }
}

// ---------------------------------------------------------------- 2. 会话目录名
// encode(path) = '-' + path.replace(/[^A-Za-z0-9]/g,'-') + '-'，
// 故 /home/zed 前缀的目录名以 "--home-zed" 开头，边界字符必须是 '-'。
const sessions = join(ROOT, 'sessions')
if (existsSync(sessions)) {
  const prefix = '-' + OLD.replace(/[^A-Za-z0-9]/g, '-') // "--home-zed"
  const repl = '-' + NEW.replace(/[^A-Za-z0-9]/g, '-')   // "--home-dsh"
  for (const name of readdirSync(sessions)) {
    if (!name.startsWith(prefix)) continue
    const after = name[prefix.length]
    if (after !== '-' && name.length !== prefix.length) continue
    const from = join(sessions, name)
    if (!statSync(from).isDirectory()) continue
    const to = join(sessions, repl + name.slice(prefix.length))
    if (existsSync(to)) { console.error(`  skip（目标已存在）: ${name}`); continue }
    renameSync(from, to)
    dirsRenamed++
  }
}

// ---------------------------------------------------------------- 3. 会话首帧 cwd
function frameSpans(buf) {
  const spans = []
  let i = -1
  while ((i = buf.indexOf(MAGIC, i + 1)) !== -1) spans.push(i)
  return spans
}

function rewriteFirstFrame(file) {
  const buf = readFileSync(file)
  const spans = frameSpans(buf)
  if (spans.length === 0) return false
  const start = spans[0]
  const end = spans.length > 1 ? spans[1] : buf.length
  let text
  try { text = zlib.zstdDecompressSync(buf.subarray(start, end)).toString('utf8') } catch { return false }
  if (!text.includes(OLD)) return false
  const head = text.split(OLD).join(NEW)
  const recompressed = zlib.zstdCompressSync(Buffer.from(head, 'utf8'))
  writeFileSync(file + '.rewrite-tmp', Buffer.concat([buf.subarray(0, start), recompressed, buf.subarray(end)]))
  renameSync(file + '.rewrite-tmp', file)
  return true
}

if (DEEP_HEADERS && existsSync(sessions)) {
  for (const file of walk(sessions)) {
    if (!file.endsWith('.jsonl.zstd')) continue
    try {
      if (rewriteFirstFrame(file)) headersChanged++
    } catch (err) {
      console.error(`  !! ${file}: ${err.message}`)
    }
  }
}

console.log(`rewrite done: storages json=${jsonChanged}, session dirs=${dirsRenamed}, headers=${headersChanged}${DEEP_HEADERS ? '' : '（未加 --headers，会话首帧未处理）'}`)
