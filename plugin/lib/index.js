// dsh-docker · 服务端半区
// 设置页「Docker DSH」区块的数据接口（经 connection.admit 认证围栏）：
//   GET /docker-dsh/info    镜像/打包信息、受信反代、开放端口、时区与服务器时间
//   GET /docker-dsh/latest  npm 上 @deepseek-ai/dsh 的最新版本（10 分钟缓存）
// 镜像信息来自构建期写入的 /etc/dsh/image-info；运行期信息来自 entrypoint 导出的环境变量。
import { readFileSync, readlinkSync } from 'node:fs'

const name = 'dsh-docker'
const inject = ['webServer', 'connection']

const IMAGE_INFO = '/etc/dsh/image-info'
const DEFAULT_REGISTRY = 'https://registry.npmjs.org'
const LATEST_TTL_MS = 600_000

function readImageInfo() {
  const out = {}
  try {
    for (const line of readFileSync(IMAGE_INFO, 'utf8').split('\n')) {
      const m = /^([A-Z_]+)=(.*)$/.exec(line.trim())
      if (m) out[m[1]] = m[2]
    }
  } catch { /* 非容器环境运行时没有该文件，字段留空 */ }
  return out
}

/** /etc/localtime 指向的 zoneinfo 时区名；挂载为普通文件时读不到，返回 null。 */
function localtimeZone() {
  try {
    const target = readlinkSync('/etc/localtime')
    const idx = target.indexOf('zoneinfo/')
    if (idx >= 0) return target.slice(idx + 'zoneinfo/'.length)
  } catch { /* 不是符号链接（bind mount 文件）*/ }
  return null
}

let latestCache = { value: null, at: 0 }

function apply(ctx) {
  ctx.inject(['connection', 'webServer'], (scope) => {
    scope.effect(() => scope.webServer.register({
      kind: 'prefix',
      path: '/docker-dsh',
      handler: async (req, res) => {
        const admission = scope.connection.admit(req)
        if ('rejection' in admission) {
          res.writeHead(admission.rejection, { 'content-type': 'text/plain; charset=utf-8' })
          res.end(admission.rejection === 401 ? 'unauthorized' : 'forbidden')
          return
        }
        const json = (code, obj) => {
          res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
          res.end(JSON.stringify(obj))
        }
        const path = (req.url || '').split('?')[0]
        if (req.method !== 'GET') return json(405, { ok: false, error: 'method not allowed' })

        if (path === '/docker-dsh/info') {
          const image = readImageInfo()
          const env = process.env
          return json(200, {
            ok: true,
            value: {
              packVersion: image.DSH_PACK_VERSION || null,
              officialVersion: image.DSH_OFFICIAL_VERSION || null,
              gitRev: image.DSH_GIT_REV || null,
              runningVersion: process.env.DSH_RUNNING_VERSION || null,
              publicUrl: env.DSH_PUBLIC_URL || '',
              trustedHosts: (env.DSH_TRUSTED_HOSTS_EFFECTIVE || '').split(/\s+/).filter(Boolean),
              ports: {
                web: Number(env.DSH_WEB_PORT || 3080),
                injector: Number(env.DSH_INJECTOR_PORT || 3081),
                published: env.DSH_PUBLISHED_BIND || '',
              },
              bindHost: env.DSH_WEB_HOST || '',
              timezone: env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone || '',
              localtimeZone: localtimeZone(),
              serverTime: new Date().toISOString(),
              node: process.version,
            },
          })
        }

        if (path === '/docker-dsh/latest') {
          try {
            if (!latestCache.value || Date.now() - latestCache.at > LATEST_TTL_MS) {
              const registry = (process.env.DSH_NPM_REGISTRY || DEFAULT_REGISTRY).replace(/\/+$/, '')
              const res2 = await fetch(`${registry}/@deepseek-ai/dsh/latest`, {
                headers: { accept: 'application/json', 'user-agent': 'dsh-docker/1.0' },
                signal: AbortSignal.timeout(8000),
              })
              if (!res2.ok) throw new Error(`registry HTTP ${res2.status}`)
              const body = await res2.json()
              latestCache = {
                value: { version: body.version ?? null, modified: body.time?.modified ?? null },
                at: Date.now(),
              }
            }
            return json(200, { ok: true, value: latestCache.value, cachedAt: latestCache.at })
          } catch (err) {
            return json(200, { ok: false, error: String((err && err.message) || err) })
          }
        }

        return json(404, { ok: false, error: 'not found' })
      },
    }), 'dsh-docker: routes')
  })
}

export { apply, inject, name }
