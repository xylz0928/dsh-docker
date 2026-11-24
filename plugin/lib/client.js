// dsh-docker · 客户端半区
// 设置页最下方（order: 100，官方分区最大 order=20、第三方用量统计=25）的「Docker DSH」分区：
// 镜像版本 / 打包官方版本 / 运行中版本 / 信任的反代 / 开放端口 / 时区 / 当前时间，
// 以及「检查官方 DSH 版本」按钮（数据来自宿主 /docker-dsh/info、/docker-dsh/latest）。
window.__ModuleLoader__.load({
  id: 'dsh-docker',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const { useState, useEffect } = React

    const NS = 'dsh-docker'

    const zh = {
      nav: 'Docker DSH',
      title: 'Docker DSH',
      pack: '镜像版本',
      official: '打包官方 DSH',
      running: '运行中 DSH 版本',
      rev: '构建提交',
      publicUrl: '信任的反代',
      trusted: '受信 authority',
      ports: '开放的端口',
      tz: '当前时区',
      time: '当前时间',
      pending: '加载中…',
      na: '—',
      check: '检查官方 DSH 版本',
      checking: '检查中…',
      latest: '官方最新版',
      uptodate: '已是最新版',
      newer: '官方已发布新版本',
      fail: '检查失败',
    }
    const en = {
      nav: 'Docker DSH',
      title: 'Docker DSH',
      pack: 'Image version',
      official: 'Bundled official DSH',
      running: 'Running DSH version',
      rev: 'Build revision',
      publicUrl: 'Trusted reverse proxy',
      trusted: 'Trusted authorities',
      ports: 'Open ports',
      tz: 'Timezone',
      time: 'Current time',
      pending: 'Loading…',
      na: '—',
      check: 'Check official DSH version',
      checking: 'Checking…',
      latest: 'Latest official',
      uptodate: 'Up to date',
      newer: 'A newer official version exists',
      fail: 'Check failed',
    }

    // locale 变化时强制重渲染（与官方插件同一做法：apply 里订阅，组件里跟随）
    const TICK = { subs: [] }
    function useLocaleTick() {
      const [, force] = useState(0)
      useEffect(() => {
        const fn = () => force((n) => n + 1)
        TICK.subs.push(fn)
        return () => {
          const i = TICK.subs.indexOf(fn)
          if (i >= 0) TICK.subs.splice(i, 1)
        }
      }, [])
    }

    function trWith(t) {
      return (key) => {
        try {
          const s = t && t(key)
          if (s) return s
        } catch { /* 未注册或缺键 → 回落中文 */ }
        return zh[key] ?? key
      }
    }

    const CSS = [
      '.dsh-docker-box{display:flex;flex-direction:column;gap:0;max-width:640px}',
      '.dsh-docker-row{display:flex;justify-content:space-between;gap:16px;padding:9px 0;border-bottom:1px solid var(--dsw-alias-border-l1)}',
      '.dsh-docker-row .k{color:var(--dsw-alias-label-secondary);flex:none}',
      '.dsh-docker-row .v{color:var(--dsw-alias-label-primary);text-align:right;word-break:break-all;font-family:var(--ds-font-mono, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace);font-size:12px}',
      '.dsh-docker-actions{display:flex;gap:10px;align-items:center;margin-top:14px;flex-wrap:wrap}',
      '.dsh-docker-btn{padding:6px 14px;border-radius:8px;cursor:pointer;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-interactive-bg-hover);color:var(--dsw-alias-label-primary);font-size:13px}',
      '.dsh-docker-btn:disabled{opacity:.6;cursor:default}',
      '.dsh-docker-note{color:var(--dsw-alias-label-secondary);font-size:12px}',
      '.dsh-docker-err{color:var(--dsw-alias-status-danger, #e5484d);font-size:12px}',
      '.dsh-docker-ok{color:var(--dsw-alias-status-success, #46a758);font-size:12px}',
    ].join('\n')

    function Row({ label, value }) {
      return h('div', { className: 'dsh-docker-row' },
        h('span', { className: 'k' }, label),
        h('span', { className: 'v' }, value))
    }

    function Section(props) {
      useLocaleTick()
      const { api, t } = props
      const tr = trWith(t)

      const [info, setInfo] = useState(null)
      const [infoErr, setInfoErr] = useState(null)
      const [latest, setLatest] = useState(null)
      const [busy, setBusy] = useState(false)
      const [checkErr, setCheckErr] = useState(null)
      const [now, setNow] = useState(() => Date.now())
      const [offset, setOffset] = useState(0)

      useEffect(() => {
        let alive = true
        api.info().then((j) => {
          if (!alive) return
          if (j && j.ok) {
            setInfo(j.value)
            const server = Date.parse(j.value.serverTime)
            if (Number.isFinite(server)) setOffset(server - Date.now())
          } else {
            setInfoErr((j && j.error) || 'unavailable')
          }
        }).catch((e) => { if (alive) setInfoErr(String((e && e.message) || e)) })
        return () => { alive = false }
      }, [])

      // 容器时区的走秒时间：服务器瞬时 + 本地校正的偏移，用 Intl 按容器时区渲染
      useEffect(() => {
        const timer = setInterval(() => setNow(Date.now()), 1000)
        return () => clearInterval(timer)
      }, [])

      const check = async () => {
        setBusy(true)
        setCheckErr(null)
        try {
          const j = await api.latest()
          if (!j || !j.ok) throw new Error((j && j.error) || 'failed')
          setLatest(j.value)
        } catch (e) {
          setCheckErr(String((e && e.message) || e))
        } finally {
          setBusy(false)
        }
      }

      const running = (info && info.runningVersion) || api.runningVersion()
      const pack = (info && info.packVersion) || null
      const official = (info && info.officialVersion) || null

      let timeText = tr('pending')
      if (info) {
        try {
          const fmt = new Intl.DateTimeFormat('zh-CN', {
            timeZone: info.timezone || undefined,
            hour12: false,
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', second: '2-digit',
          })
          timeText = fmt.format(new Date(now + offset))
        } catch {
          timeText = new Date(now + offset).toLocaleString()
        }
      }

      let latestNote = null
      if (latest && latest.version) {
        const target = running || official
        latestNote = latest.version === target
          ? h('span', { className: 'dsh-docker-ok' }, `${tr('uptodate')}（${latest.version}）`)
          : h('span', { className: 'dsh-docker-note' }, `${tr('latest')}: ${latest.version}`)
      }

      const ports = info && info.ports
      const portsText = ports
        ? `web ${ports.web} · injector ${ports.injector}` + (ports.published ? `  ⇄  ${ports.published}` : '')
        : null

      const trusted = info && info.trustedHosts && info.trustedHosts.length
        ? info.trustedHosts.join(', ')
        : null

      return h('div', null,
        h('div', { style: { fontSize: 15, fontWeight: 600, margin: '0 0 10px' } }, tr('title')),
        infoErr
          ? h('div', { className: 'dsh-docker-err' }, `${tr('pending')}: ${infoErr}`)
          : h('div', { className: 'dsh-docker-box' },
              h(Row, { label: tr('pack'), value: pack ? `${pack}${info.gitRev ? ' · ' + info.gitRev.slice(0, 7) : ''}` : tr('na') }),
              h(Row, { label: tr('official'), value: official || tr('na') }),
              h(Row, { label: tr('running'), value: running || tr('na') }),
              h(Row, { label: tr('publicUrl'), value: (info && info.publicUrl) || tr('na') }),
              h(Row, { label: tr('trusted'), value: trusted || tr('na') }),
              h(Row, { label: tr('ports'), value: portsText || tr('na') }),
              h(Row, {
                label: tr('tz'),
                value: info
                  ? (info.timezone
                      ? info.timezone + (info.localtimeZone && info.localtimeZone !== info.timezone ? `（/etc/localtime: ${info.localtimeZone}）` : '')
                      : tr('na'))
                  : tr('pending'),
              }),
              h(Row, { label: tr('time'), value: timeText }),
              info && info.node ? h(Row, { label: 'Node', value: info.node }) : null),
        h('div', { className: 'dsh-docker-actions' },
          h('button', {
            type: 'button',
            className: 'dsh-docker-btn',
            onClick: check,
            disabled: busy || !info,
          }, busy ? tr('checking') : tr('check')),
          latestNote,
          checkErr ? h('span', { className: 'dsh-docker-err' }, `${tr('fail')}: ${checkErr}`) : null))
    }

    function makeApi(ctx) {
      const get = (path) => fetch(path, { headers: { accept: 'application/json' } }).then((r) => r.json())
      return {
        info: () => get('/docker-dsh/info'),
        latest: () => get('/docker-dsh/latest'),
        runningVersion: () => {
          try {
            const release = ctx.modules && ctx.modules.manifest && ctx.modules.manifest.release
            return (release && release.version) || null
          } catch { return null }
        },
      }
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'dsh-docker: locale')
        ctx.effect(() => {
          let off = null
          try {
            if (ctx.locale && typeof ctx.locale.subscribe === 'function') {
              off = ctx.locale.subscribe(() => { for (const fn of [...TICK.subs]) { try { fn() } catch { /* noop */ } } })
            }
          } catch { /* locale 服务不可用时忽略 */ }
          return () => { if (off) { try { off() } catch { /* noop */ } } }
        }, 'dsh-docker: locale-change')
        ctx.effect(() => {
          if (typeof document === 'undefined') return undefined
          const tag = document.createElement('style')
          tag.id = 'dsh-docker-style'
          tag.textContent = CSS
          document.head.appendChild(tag)
          return () => tag.remove()
        }, 'dsh-docker: styles')

        ctx.slots.inject('settings.section', () => ctx.slots.register({
          name: 'settings.section',
          id: 'dsh-docker',
          order: 100, // 官方分区最大 20，第三方用量统计 25 → 本分区永远在最下方
          label: () => { try { return ctx.locale.bind(NS)('nav') } catch { return zh.nav } },
          locale: NS,
          inject: () => ({ api: makeApi(ctx) }),
        }, Section))
      },
    }
  },
})
