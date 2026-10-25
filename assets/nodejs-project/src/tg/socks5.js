// 最小可用的 SOCKS5 HTTP/HTTPS Agent
// ============================================================
// 为什么自己写：项目里没有 `socks-proxy-agent`，但 `socks`（gramjs 的依赖）
// 已经在了 —— 直接用它建隧道，再套成 Node 的 Agent，就够 axios 用了。
//
// 支持：无认证 / 用户名密码认证、IPv4/IPv6/域名目标（socks 库自己解析）
import http from 'http';
import https from 'https';
import tls from 'tls';
import { SocksClient } from 'socks';

function connectVia(proxy, host, port, timeout) {
    return SocksClient.createConnection({
        proxy: {
            host: proxy.host,
            port: proxy.port,
            type: 5,
            userId: proxy.user || undefined,
            password: proxy.pass || undefined,
        },
        command: 'connect',
        destination: { host, port },
        timeout,
    }).then((r) => r.socket);
}

/** 走 socks5 的 http.Agent（目标为 http:// 时用；一般用不到） */
export class Socks5HttpAgent extends http.Agent {
    constructor(proxy, opts = {}) {
        super({ keepAlive: true, ...opts });
        this.proxy = proxy;
    }

    createConnection(options, cb) {
        connectVia(this.proxy, options.host, options.port, 15000)
            .then((s) => cb(null, s))
            .catch((e) => cb(e));
        return undefined; // 异步回调，不返回 socket
    }
}

/** 走 socks5 的 https.Agent：先建 socks 隧道，再在隧道上做 TLS */
export class Socks5HttpsAgent extends https.Agent {
    constructor(proxy, opts = {}) {
        super({ keepAlive: true, ...opts });
        this.proxy = proxy;
    }

    createConnection(options, cb) {
        connectVia(this.proxy, options.host, options.port, 15000)
            .then((raw) => {
                const socket = tls.connect({
                    socket: raw,
                    servername: options.servername || options.host,
                });
                socket.once('secureConnect', () => cb(null, socket));
                socket.once('error', (e) => cb(e));
            })
            .catch((e) => cb(e));
        return undefined;
    }
}
