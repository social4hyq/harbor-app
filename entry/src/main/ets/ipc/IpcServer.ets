// Harbor 回环 IPC：文本行协议，供 CLI (harbor) 查询/控制服务
// 协议：请求 "<CMD> [args]\n" -> 响应 "OK <json>\n" / "ERR <msg>\n"
import socket from '@ohos.net.socket';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import fileIo from '@ohos.file.fs';
import daemonBridge from 'libharbor_bridge.so';

const DOMAIN = 0x0000;
const TAG = 'HarborIpc';
const PORT = 19876;
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';
const IPC_CONF = '/storage/Users/currentUser/.config/harbor/ipc.conf';

// 读取 IPC token（由 CLI 生成写入 ipc.conf；HAP 只读，避免写宿主 .config 权限问题）
// 每次 handle 时重新读，CLI 生成 token 后下条命令即可通过
function readToken(): string {
  try {
    if (fileIo.accessSync(IPC_CONF)) {
      const text = fileIo.readTextSync(IPC_CONF);
      for (const line of text.split('\n')) {
        if (line.startsWith('token=')) return line.substring(6).trim();
      }
    }
  } catch (e) { /* 读不到，返回空 */ }
  return '';
}

// 与 Index.ets 保持一致的配置结构
interface AppEntry {
  name: string;
  enabled?: boolean;
  type?: string;
  unit?: string;
  bin?: string;
  args?: string[];
  log?: string;
  pidfile: string;
  env?: Record<string, string>;
}
interface AppsConfig { apps: AppEntry[]; }
interface SvcResult { bin: string; args: string[]; env: Record<string, string>; log: string; }

function tokenizeExecStart(line: string): string[] {
  const out: string[] = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let m: RegExpExecArray | null = re.exec(line);
  while (m !== null) {
    out.push(m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3]));
    m = re.exec(line);
  }
  return out;
}

function parseUnit(path: string): SvcResult {
  const text = fileIo.readTextSync(path);
  let bin = '', log = '';
  let args: string[] = [];
  const env: Record<string, string> = {} as Record<string, string>;
  let inService = false;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('[')) { inService = (line === '[Service]'); continue; }
    if (!inService || line.length === 0 || line.startsWith('#') || line.startsWith(';')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.substring(0, eq).trim();
    const val = line.substring(eq + 1).trim();
    if (key === 'ExecStart') {
      const t = tokenizeExecStart(val);
      if (t.length > 0) { bin = t[0]; args = t.slice(1); }
    } else if (key === 'Environment') {
      const re = /"([^"]*)"|(\S+)/g;
      let mm: RegExpExecArray | null = re.exec(val);
      while (mm !== null) {
        const item = mm[1] !== undefined ? mm[1] : mm[2];
        const e = item.indexOf('=');
        if (e > 0) env[item.substring(0, e)] = item.substring(e + 1);
        mm = re.exec(val);
      }
    } else if (key === 'StandardOutput' || key === 'StandardError') {
      if (val.startsWith('append:')) log = val.substring(7);
    }
  }
  return { bin: bin, args: args, env: env, log: log };
}

function readConfig(): AppsConfig {
  const text = fileIo.readTextSync(CONFIG_PATH);
  return JSON.parse(text) as AppsConfig;
}

function findApp(name: string): AppEntry | undefined {
  const cfg = readConfig();
  for (const app of cfg.apps) if (app.name === name) return app;
  return undefined;
}

// 启动单个服务，返回 'started' | 'already running' | 错误信息
function startService(app: AppEntry): string {
  let bin = app.bin ?? '';
  let args = app.args ?? [];
  let log = app.log ?? '';
  const env: Record<string, string> = app.env ?? ({} as Record<string, string>);
  if (app.type === 'unit' && app.unit) {
    let u: SvcResult;
    try {
      u = parseUnit(app.unit);
    } catch (e) {
      const msg: string = e instanceof Error && e.message.length > 0 ? e.message : JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'parseUnit %{public}s failed: %{public}s', app.unit, msg);
      return 'ERR cannot read unit: ' + msg;
    }
    bin = u.bin; args = u.args; log = u.log;
    for (const k of Object.keys(u.env)) env[k] = u.env[k];
  }
  if (bin.length === 0) return 'ERR no ExecStart/bin';
  const argsJson: string = JSON.stringify(args) as string;
  const envJson: string = JSON.stringify(env) as string;
  try {
    const r: number = daemonBridge.spawn(bin, argsJson, log, app.pidfile, envJson);
    return r === 0 ? 'already running' : 'started';
  } catch (e) {
    return 'ERR spawn failed: ' + JSON.stringify(e);
  }
}

function statusJson(): string {
  const cfg = readConfig();
  const out: string[] = [];
  for (const app of cfg.apps) {
    const pid: number = daemonBridge.pidFromPidfile(app.pidfile);
    const exists: number = daemonBridge.pidfileExists(app.pidfile);
    // 对齐 brew status_symbol：started/stopped/none/disabled/error
    let status: string = 'none';
    if (app.enabled === false) status = 'disabled';
    else if (pid > 0) status = 'started';
    else if (exists === 1) status = 'stopped';   // 有 pidfile 但进程已退
    // else none：从未启动过（无 pidfile）
    out.push('{"name":' + JSON.stringify(app.name) + ',"pid":' + pid + ',"status":"' + status + '"}');
  }
  return '[' + out.join(',') + ']';
}

export class IpcServer {
  private server: socket.TCPSocketServer | undefined = undefined;

  start(): void {
    try {
      const srv = socket.constructTCPSocketServerInstance();
      this.server = srv;
      srv.on('connect', (conn: socket.TCPSocketConnection) => {
        let buffer = '';
        conn.on('message', (info: socket.SocketMessageInfo) => {
          const bytes = new Uint8Array(info.message);
          for (let i = 0; i < bytes.length; i++) buffer += String.fromCharCode(bytes[i]);
          // 逐行处理
          let nl = buffer.indexOf('\n');
          while (nl >= 0) {
            const line = buffer.substring(0, nl).trim();
            buffer = buffer.substring(nl + 1);
            if (line.length > 0) {
              const reply = this.handle(line);
              this.send(conn, reply);
            }
            nl = buffer.indexOf('\n');
          }
        });
        conn.on('error', (e: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'conn error: %{public}s', JSON.stringify(e));
        });
      });
      srv.on('error', (e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'server error: %{public}s', JSON.stringify(e));
      });
      srv.listen({ address: '127.0.0.1', port: PORT } as socket.NetAddress).then(() => {
        hilog.info(DOMAIN, TAG, 'listening on 127.0.0.1:%{public}d', PORT);
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'listen failed: %{public}s', JSON.stringify(e));
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'start threw: %{public}s', JSON.stringify(e));
    }
  }

  private send(conn: socket.TCPSocketConnection, text: string): void {
    const buf = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) buf[i] = text.charCodeAt(i);
    const opts: socket.TCPSendOptions = { data: buf.buffer };
    conn.send(opts).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'send failed: %{public}s', JSON.stringify(e));
    });
  }

  // 公开：重启服务（供 IPC RESTART 命令与定时调度器共用）
  restartService(name: string): string {
    try {
      const app = findApp(name);
      if (!app) return 'no such service';
      const pid: number = daemonBridge.pidFromPidfile(app.pidfile);
      if (pid > 0) {
        const r: number = daemonBridge.killAndWait(pid, 15, 2000);
        if (r !== 0) {
          const r2: number = daemonBridge.killAndWait(pid, 9, 1000);
          if (r2 !== 0) return 'old process will not die (pid ' + pid + ')';
        }
      }
      return startService(app);
    } catch (e) {
      return 'ERR restart failed: ' + JSON.stringify(e);
    }
  }

  private handle(line: string): string {
    const parts = line.split(/\s+/);
    // 鉴权：要求 AUTH <token> <cmd> [args]
    if (parts[0].toUpperCase() !== 'AUTH' || parts.length < 3) {
      hilog.warn(DOMAIN, TAG, 'unauthorized request (no AUTH)');
      return 'ERR unauthorized\n';
    }
    const token = readToken();
    if (token.length === 0 || parts[1] !== token) {
      hilog.warn(DOMAIN, TAG, 'unauthorized request (bad token)');
      return 'ERR unauthorized\n';
    }
    // 去掉 AUTH <token> 前缀，剩下的是真正的命令
    const rest = line.substring(parts[0].length + 1 + parts[1].length).trim();
    const cparts = rest.split(/\s+/);
    const cmd = cparts[0].toUpperCase();
    const args = cparts.slice(1);
    hilog.info(DOMAIN, TAG, 'cmd: %{public}s', rest);
    try {
      if (cmd === 'PING') return 'OK {"pong":' + Date.now() + '}\n';
      if (cmd === 'STATUS') return 'OK ' + statusJson() + '\n';
      if (cmd === 'START' && args[0]) {
        const app = findApp(args[0]);
        if (!app) return 'ERR no such service\n';
        return 'OK {"result":"' + startService(app) + '"}\n';
      }
      if (cmd === 'STOP' && args[0]) {
        const app = findApp(args[0]);
        if (!app) return 'ERR no such service\n';
        const pid: number = daemonBridge.pidFromPidfile(app.pidfile);
        if (pid <= 0) return 'OK {"result":"not running"}\n';
        const r: number = daemonBridge.killAndWait(pid, 15, 2000);  // SIGTERM 等退出
        if (r !== 0) daemonBridge.killAndWait(pid, 9, 1000);  // 超时强制 SIGKILL
        return 'OK {"result":"stopped","pid":' + pid + '}\n';
      }
      if (cmd === 'RESTART' && args[0]) {
        const result: string = this.restartService(args[0]);
        if (result.startsWith('no such') || result.startsWith('old process')) return 'ERR ' + result + '\n';
        if (result.startsWith('ERR ')) return 'ERR ' + result.substring(4) + '\n';
        return 'OK {"result":"' + result + '"}\n';
      }
      if (cmd === 'RELOAD') {
        // 重读配置由 STATUS/START 自然生效（每次都读文件），这里只是 ack
        return 'OK {"reloaded":true}\n';
      }
      return 'ERR unknown command\n';
    } catch (e) {
      return 'ERR ' + JSON.stringify(e) + '\n';
    }
  }
}
