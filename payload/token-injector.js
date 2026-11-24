#!/usr/bin/env node
'use strict';
/*
 * dsh token injector -- a thin reverse proxy that sits in front of `dsh web`
 * inside the dsh-docker container. Ported from the host-side injector
 * (dsh-lan-fix/token-injector.js): systemd/journalctl are gone, so the launch
 * token comes from the URL file that entrypoint.sh captures from dsh's log,
 * and the cache invalidates on that file's mtime.
 *
 * dsh >= 0.2 authenticates browsers with a per-process launch token:
 * `GET /` without a `dsh-auth-*` cookie answers 401 until `?token=<launchToken>`
 * mints a signed cookie bound to the request authority. The launch token is
 * randomBytes() per process, so it changes on every restart and cannot be
 * hard-coded in nginx -- which is why every device used to need a manual
 * `?token=` visit.
 *
 * This proxy completes that exchange itself:
 *   - `GET /` with no session cookie  -> append the current launch token
 *   - `GET /` answered 401            -> retry once with the token (expired cookie)
 *   - everything else                 -> passed through byte for byte
 *
 * The original `Host` header is preserved so the minted cookie stays bound to
 * the public authority the reverse proxy forwards, and WebSocket upgrades are
 * tunnelled as raw TCP so dsh's live connection is unaffected.
 *
 * Environment:
 *   DSH_LISTEN_HOST/PORT   external listener (default 0.0.0.0:3081)
 *   DSH_LOCAL_HOST/PORT    loopback listener for dsh's OAuth loginOrigin
 *                          (default 127.0.0.1:3080)
 *   DSH_UPSTREAM_HOST/PORT dsh web itself (default 127.0.0.1:3080)
 *   DSH_URL_FILE           launch-url capture file (default /tmp/dsh-launch-url)
 */

const http = require('http');
const net = require('net');
const fs = require('fs');

const LISTEN_HOST = process.env.DSH_LISTEN_HOST || '0.0.0.0';
const LISTEN_PORT = Number(process.env.DSH_LISTEN_PORT || 3081);
// dsh's OAuth loginOrigin() only accepts http://localhost|127.0.0.1|[::1]:<port>,
// so the loopback listener exists purely to make that origin usable with the
// same automatic launch-token exchange.
const LOCAL_HOST = process.env.DSH_LOCAL_HOST || '127.0.0.1';
const LOCAL_PORT = Number(process.env.DSH_LOCAL_PORT || 3080);
const UPSTREAM_HOST = process.env.DSH_UPSTREAM_HOST || '127.0.0.1';
const UPSTREAM_PORT = Number(process.env.DSH_UPSTREAM_PORT || 3080);
const URL_FILE = process.env.DSH_URL_FILE || '/tmp/dsh-launch-url';

// Hop-by-hop headers must not be forwarded (RFC 7230 6.1).
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade',
]);

const log = (msg) => console.log(`[injector] ${msg}`);

/*
 * dsh 0.1.1 builds shipped a patched index.html that registered `/sw.js`
 * (our PWA patch, along with `initial-scale=0.75`). The official 0.2.2 dist has
 * no service worker, so the endpoint now answers 404 — and a 404 script makes
 * the browser's update fail, leaving the stale registration in place. That old
 * worker keeps serving pre-upgrade assets, which is what shows up as fonts and
 * viewport scaling that no longer match the settings. Answering a
 * self-unregistering worker instead lets every device clean itself up on its
 * next update check, without touching any official file.
 */
const KILL_SWITCH_SW = [
  "self.addEventListener('install', function () { self.skipWaiting(); });",
  "self.addEventListener('activate', function (event) {",
  "  event.waitUntil(self.registration.unregister().then(function () {",
  "    return self.clients.matchAll({ type: 'window' });",
  "  }).then(function (list) {",
  "    list.forEach(function (client) { client.navigate(client.url); });",
  "  }));",
  "});",
  "",
].join("\n");

function extractToken(text) {
  const matches = [...text.matchAll(/[?&]token=([A-Za-z0-9_-]{20,})/g)];
  return matches.length ? matches[matches.length - 1][1] : null;
}

let tokenCache = { value: null, mtime: -1 };

/** Current launch token, read from the capture file; re-read whenever it changes. */
function currentToken(force = false) {
  let mtime = -1;
  try { mtime = fs.statSync(URL_FILE).mtimeMs; } catch { /* not written yet */ }
  if (!force && tokenCache.value !== null && tokenCache.mtime === mtime) {
    return tokenCache.value;
  }

  let token = null;
  if (mtime >= 0) {
    try { token = extractToken(fs.readFileSync(URL_FILE, 'utf8')); } catch { /* transient */ }
  }

  if (token) {
    tokenCache = { value: token, mtime };
  } else {
    tokenCache = { value: null, mtime };
    log('WARN: launch token unavailable; requests will fall through unmodified');
  }
  return token;
}

function stripHopByHop(headers) {
  const out = { ...headers };
  for (const key of Object.keys(out)) {
    if (HOP_BY_HOP.has(key.toLowerCase())) delete out[key];
  }
  return out;
}

/**
 * Put exactly one `token` param on the path. Appending blindly stacks values
 * across retries, and dsh's authorizeIndex rejects the exchange unless
 * `tokens.length === 1` — so a stacked URL 401s forever.
 */
function withToken(path, token) {
  const cut = path.indexOf('?');
  const pathname = cut === -1 ? path : path.slice(0, cut);
  const query = cut === -1 ? '' : path.slice(cut + 1);
  const kept = query.split('&').filter((kv) => kv && !kv.startsWith('token='));
  kept.push(`token=${encodeURIComponent(token)}`);
  return `${pathname}?${kept.join('&')}`;
}

/** Forward one request; optionally retry a 401 on the index with a fresh token. */
function forward(req, res, targetPath, allowRetry, fallback404) {
  let activeUpstream = null;
  // Registered once: attaching this per retry stacks close listeners on the
  // same ServerResponse and trips MaxListenersExceededWarning.
  res.on('close', () => {
    if (activeUpstream) activeUpstream.destroy();
  });

  const attempt = (path, authRetries = 5, connectRetries = 8) => {
    const headers = stripHopByHop(req.headers);
    // Preserve the caller's Host: the cookie is bound to that authority.
    headers.host = req.headers.host || `${LISTEN_HOST}:${LISTEN_PORT}`;

    const upstream = http.request(
      {
        host: UPSTREAM_HOST,
        port: UPSTREAM_PORT,
        method: req.method,
        path,
        headers,
      },
      (upRes) => {
        // Only used when the upstream genuinely has no such file (404), so a
        // future official service worker keeps passing through untouched.
        if (fallback404 && upRes.statusCode === 404 && req.method === 'GET') {
          upRes.resume();
          res.writeHead(200, {
            'content-type': 'application/javascript; charset=utf-8',
            'cache-control': 'no-store',
          });
          res.end(fallback404);
          return;
        }
        const canRetry =
          allowRetry && upRes.statusCode === 401 && req.method === 'GET' && authRetries > 0;
        if (canRetry) {
          // force=true bypasses the cache: right after a restart the new launch
          // token has not reached the capture file yet, so a cached read returns
          // the previous process's token and the exchange 401s until it lands.
          const token = currentToken(true);
          if (token) {
            upRes.resume(); // drain the 401, it never reaches the browser
            log(`retrying ${req.method} ${path} with launch token (${authRetries - 1} left)`);
            return setTimeout(
              () => attempt(withToken(path, token), authRetries - 1, connectRetries),
              300,
            );
          }
        }
        if (!res.headersSent) {
          res.writeHead(upRes.statusCode, stripHopByHop(upRes.headers));
        }
        upRes.pipe(res);
      },
    );

    upstream.on('error', (err) => {
      // dsh restart window: the listener is briefly gone. A connect failure
      // means nothing reached the upstream, so retrying a bodyless GET is safe
      // and smooths over the boot gap instead of surfacing 502 to the browser.
      const connectFailure = err && (err.code === 'ECONNREFUSED' || err.code === 'ECONNRESET');
      const idempotent = req.method === 'GET' || req.method === 'HEAD';
      if (connectFailure && idempotent && connectRetries > 0) {
        log(`upstream not ready (${err.code}); retrying ${req.method} ${path}`);
        setTimeout(() => attempt(path, authRetries, connectRetries - 1), 400);
        return;
      }
      log(`upstream error on ${req.method} ${path}: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
        res.end(`token injector: upstream unreachable (${err.message})\n`);
      } else {
        res.destroy();
      }
    });

    activeUpstream = upstream;

    if (req.method === 'GET' || req.method === 'HEAD') upstream.end();
    else req.pipe(upstream);
  };

  attempt(targetPath);
}

function handleRequest(req, res) {
  let path = req.url;
  let isIndex = false;
  try {
    const url = new URL(req.url, 'http://placeholder');
    isIndex = req.method === 'GET' && (url.pathname === '/' || url.pathname === '');
    if (isIndex) {
      const hasCookie = (req.headers.cookie || '').includes('dsh-auth-');
      if (!hasCookie) {
        const token = currentToken();
        // No session yet: complete the launch-token exchange upstream.
        if (token) path = withToken(req.url, token);
      }
    }
  } catch { /* malformed target -- forward verbatim */ }

  let swFallback;
  try {
    const target = new URL(req.url, 'http://placeholder');
    if (req.method === 'GET' && target.pathname.endsWith('/sw.js')) swFallback = KILL_SWITCH_SW;
  } catch { /* malformed target — forward verbatim */ }

  forward(req, res, path, isIndex, swFallback);
}

const server = http.createServer(handleRequest);
const localServer = http.createServer(handleRequest);

// WebSocket / HTTP Upgrade: tunnel raw bytes so dsh's live channel is untouched.
function handleUpgrade(req, socket, head) {
  const upstream = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += '\r\n';
    upstream.write(raw);
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
}

server.on('upgrade', handleUpgrade);
localServer.on('upgrade', handleUpgrade);

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log(`listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
});
localServer.listen(LOCAL_PORT, LOCAL_HOST, () => {
  log(`loopback listening on ${LOCAL_HOST}:${LOCAL_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  log(`first launch token probe: ${currentToken() ? 'ok' : 'not yet available'}`);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    server.close();
    localServer.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
