#!/usr/bin/env python3
"""
给 @ponydev/dsh-model-usage 打本地补丁（3 处），可重复执行、幂等。

背景（两个都是插件自身缺陷，非配置问题）：
  [1] 小米适配器写死账户余额接口 platform.xiaomimimo.com/api/v1/balance，
      而本机的 key 是 tp- 前缀的 Token Plan key → 必 401，
      且 index.js 的 catch 把错误码硬编码成 fetch-failed → 前端显示成「网络请求失败」。
  [2] ledger.js 回填用 zstdDecompressSync，而 dsh 会话日志是「多 frame 拼接的 zstd」，
      Node 只解第一帧（实测 189 / 1,111,948 字节）→ 历史一条都抓不到。

用法：
  python3 patch-dsh-model-usage.py          # 应用（幂等）
  python3 patch-dsh-model-usage.py --check  # 只检查状态，不改动
"""
import json
import os
import re
import shutil
import sys
import time

PKG = os.path.expanduser("~/.dsh/profiles/web/node_modules/@ponydev/dsh-model-usage")
MARK = "[dsh-lan-fix]"
CHECK_ONLY = "--check" in sys.argv

FILES = {
    "adapters": os.path.join(PKG, "lib/adapters.js"),
    "index": os.path.join(PKG, "lib/index.js"),
    "ledger": os.path.join(PKG, "lib/ledger.js"),
}

# ---------------------------------------------------------------- ① adapters.js
XIAOMI_OLD = """// Xiaomi MiMo 余额：GET https://platform.xiaomimimo.com/api/v1/balance  Bearer
const xiaomiBalance = {
  id: 'xiaomi-balance',
  refs: (cfg, route) => [cfg.credentials[route] || 'XIAOMI_API_KEY'],
  async read(env) {
    const key = await resolveKey(env)
    if (!key) return { status: 'needs-credential', credential: { refs: env.refs, configured: false } }
    const res = await fetchT('https://platform.xiaomimimo.com/api/v1/balance', { headers: { authorization: 'Bearer ' + key, accept: 'application/json' } }, 10000)
    if (res.status === 401 || res.status === 403) throw err('model-usage/unauthorized', 'HTTP ' + res.status + '\uff08Xiaomi Key \u65e0\u6548\uff09')
    if (!res.ok) throw err('model-usage/http', 'HTTP ' + res.status)
    const body = await res.json()
    const d = (body && (body.data || body.result)) || body || {}
    const val = [d.balance, d.remaining, d.available_balance, d.total_balance].map(Number).find((v) => Number.isFinite(v))
    if (val == null) return { status: 'unsupported', error: { code: 'model-usage/shape', message: 'Xiaomi \u672a\u8fd4\u56de\u4f59\u989d\u5b57\u6bb5' } }
    return {
      status: 'ok',
      fetchedAt: Date.now(),
      credential: { refs: env.refs, configured: true },
      balance: { currency: 'CNY', total: val.toFixed(2), toppedUp: '', granted: '', available: val > 0 },
    }
  },
}"""

XIAOMI_NEW = """// %s Xiaomi MiMo：优先查 Token Plan（tp- key 唯一能打的端点），失败回退账户余额。
// 原文只打账户余额接口，tp- 前缀的 Token Plan key 必 401。
const xiaomiBalance = {
  id: 'xiaomi-balance',
  refs: (cfg, route) => [cfg.credentials[route] || 'XIAOMI_TOKEN_PLAN_API_KEY', 'XIAOMI_TOKEN_PLAN_CN_API_KEY', 'XIAOMI_API_KEY', 'MIMO_API_KEY'],
  async read(env) {
    const key = await resolveKey(env)
    if (!key) return { status: 'needs-credential', credential: { refs: env.refs, configured: false } }
    const headers = { authorization: 'Bearer ' + key, accept: 'application/json' }

    // (1) Token Plan 额度 -> 订阅窗口，前端渲染进度条 + 「剩 N%%」+ 重置时间
    try {
      const pres = await fetchT('https://token-plan-cn.xiaomimimo.com/v1/platform/token_plan', { headers }, 10000)
      if (pres.ok) {
        const pb = await pres.json()
        const q = (pb && pb.quota) || {}
        const total = Number(q.total_credits)
        const used = Number(q.used_credits)
        if (Number.isFinite(total) && total > 0 && Number.isFinite(used)) {
          const raw = pb.period && pb.period.end_at
          const endAt = raw ? Date.parse(String(raw).replace(' ', 'T')) : NaN
          return {
            status: 'ok',
            fetchedAt: Date.now(),
            credential: { refs: env.refs, configured: true },
            windows: [{
              key: 'token-plan',
              label: String(pb.plan_code || 'Token Plan'),
              usedPct: clampPct((used / total) * 100),
              resetAt: Number.isFinite(endAt) ? endAt : null,
            }],
          }
        }
      }
    } catch { /* 落到下面的余额接口 */ }

    // (2) 回退：账户余额（普通 XIAOMI_API_KEY 才有效）
    const res = await fetchT('https://platform.xiaomimimo.com/api/v1/balance', { headers }, 10000)
    if (res.status === 401 || res.status === 403) throw err('model-usage/unauthorized', 'HTTP ' + res.status + '\uff08Xiaomi Key \u65e0\u6548\uff09')
    if (!res.ok) throw err('model-usage/http', 'HTTP ' + res.status)
    const body = await res.json()
    const d = (body && (body.data || body.result)) || body || {}
    const val = [d.balance, d.remaining, d.available_balance, d.total_balance].map(Number).find((v) => Number.isFinite(v))
    if (val == null) return { status: 'unsupported', error: { code: 'model-usage/shape', message: 'Xiaomi \u672a\u8fd4\u56de\u4f59\u989d\u5b57\u6bb5' } }
    return {
      status: 'ok',
      fetchedAt: Date.now(),
      credential: { refs: env.refs, configured: true },
      balance: { currency: 'CNY', total: val.toFixed(2), toppedUp: '', granted: '', available: val > 0 },
    }
  },
}""" % MARK

# ---------------------------------------------------------------- ② index.js
ERR_OLD = "        const error = { code: 'model-usage/fetch-failed', message: safeMsg(e) }"
ERR_NEW = ("        const error = { code: (e && typeof e.code === 'string' && e.code) ? e.code : 'model-usage/fetch-failed', message: safeMsg(e) }  // %s \u4fdd\u7559\u539f\u59cb\u9519\u8bef\u7801\uff0c\u5426\u5219 401 \u88ab\u6539\u5199\u6210 fetch-failed \u663e\u793a\u6210\u300c\u7f51\u7edc\u8bf7\u6c42\u5931\u8d25\u300d" % MARK)

# ---------------------------------------------------------------- ③ ledger.js
LEDGER_CALL_OLD = "      text = zstdDecompressSync(buf).toString('utf8')"
LEDGER_CALL_NEW = "      text = dshLanFixDecompressAll(buf).toString('utf8')  // %s \u591a frame zstd" % MARK

HELPER_ANCHOR = "/** \u4ece\u4f1a\u8bdd\u65e5\u5fd7\u56de\u586b"
HELPER = """// %s dsh \u4f1a\u8bdd\u65e5\u5fd7\u662f\u300c\u591a frame \u62fc\u63a5\u7684 zstd\u300d\uff08\u8ffd\u52a0\u5199\u5165\u4ea7\u751f\uff09\u3002
// Node \u7684 zstdDecompressSync \u53ea\u89e3\u7b2c\u4e00\u5e27\uff08\u5b9e\u6d4b 189 / 1,111,948 \u5b57\u8282\uff09\uff0c\u56de\u586b\u4e00\u6761\u90fd\u6293\u4e0d\u5230\u3002
// \u6309 frame magic \u5207\u5f00\u9010\u5e27\u89e3\uff0c\u7ed3\u679c\u4e0e zstd CLI \u5b8c\u5168\u4e00\u81f4\u3002
const DSH_LAN_FIX_ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
function dshLanFixDecompressAll(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 4) return zstdDecompressSync(buf)
  const starts = []
  let i = -1
  while ((i = buf.indexOf(DSH_LAN_FIX_ZSTD_MAGIC, i + 1)) !== -1) starts.push(i)
  if (starts.length <= 1) return zstdDecompressSync(buf)
  const parts = []
  for (let k = 0; k < starts.length; k++) {
    const from = starts[k]
    const to = k + 1 < starts.length ? starts[k + 1] : buf.length
    try { parts.push(zstdDecompressSync(buf.subarray(from, to))) } catch { /* \u5047\u9633\u6027 magic\uff0c\u8df3\u8fc7 */ }
  }
  return parts.length ? Buffer.concat(parts) : zstdDecompressSync(buf)
}

""" % MARK


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def apply_one(tag, path, old, new, anchor=None):
    src = read(path)
    if new.split("\n")[0][:60] in src or (MARK in src and old not in src):
        print("  [%s] 已打过补丁，跳过" % tag)
        return True
    if old not in src:
        print("  [%s] !! 锚点未找到 —— 插件版本可能变了，需要人工核对" % tag)
        return False
    if anchor and anchor not in src:
        print("  [%s] !! 插入锚点未找到" % tag)
        return False
    out = src.replace(old, new, 1)
    if anchor:
        out = out.replace(anchor, HELPER + anchor, 1)
    if CHECK_ONLY:
        print("  [%s] 待应用（--check 未写入）" % tag)
        return True
    write_atomic(path, out)
    # 复核
    ok = (new.split("\n")[0][:60]) in read(path)
    print("  [%s] %s" % (tag, "已写入并复核通过" if ok else "!! 写入后复核失败"))
    return ok


def reset_ledger_if_empty():
    """回填标记已置位但 days 为空 → 回填永不重跑。清掉它（先备份）让补丁生效后重新回填。"""
    led = os.path.expanduser("~/.dsh/model-usage/ledger.json")
    if not os.path.exists(led):
        print("  [ledger] 不存在，无需处理")
        return
    try:
        data = json.loads(read(led))
    except Exception as exc:
        print("  [ledger] 解析失败: %s" % exc)
        return
    if data.get("backfilled") and not (data.get("days") or {}):
        if CHECK_ONLY:
            print("  [ledger] backfilled=true 但 days 为空 → 需重置（--check 未执行）")
            return
        bak = led + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(led, bak)
        os.remove(led)
        print("  [ledger] 已重置（备份 %s）→ 下次启动重新回填" % os.path.basename(bak))
    else:
        print("  [ledger] 状态正常（days=%d 条）" % len(data.get("days") or {}))


def main():
    ver = None
    try:
        ver = json.loads(read(os.path.join(PKG, "package.json"))).get("version")
    except Exception:
        pass
    print("目标包: @ponydev/dsh-model-usage  版本=%s  %s" % (ver, "(--check)" if CHECK_ONLY else ""))
    if not os.path.isdir(PKG):
        print("!! 包不存在，先执行: dsh plugin --profile web add @ponydev/dsh-model-usage")
        return 1

    ok = True
    ok &= apply_one("adapters/xiaomi", FILES["adapters"], XIAOMI_OLD, XIAOMI_NEW)
    ok &= apply_one("index/error-code", FILES["index"], ERR_OLD, ERR_NEW)
    ok &= apply_one("ledger/zstd", FILES["ledger"], LEDGER_CALL_OLD, LEDGER_CALL_NEW, anchor=HELPER_ANCHOR)
    reset_ledger_if_empty()

    print("\n结果:", "全部成功" if ok else "存在失败项，需要人工核对")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
