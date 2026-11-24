import daemonBridge from 'libharbor_bridge.so';
import hilog from '@ohos.hilog';
import fileIo from '@ohos.file.fs';

const DOMAIN = 0x0000;
const TAG = 'Harbor';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';

// 统一的服务定义（unit 类型会在运行时从 .service 补全 bin/args/env/log）
interface AppEntry {
  name: string;
  enabled?: boolean;
  type?: string;              // 'unit' | 'exec'，默认 exec
  unit?: string;              // type=unit 时的 .service 路径
  bin?: string;
  args?: string[];
  log?: string;
  pidfile: string;
  env?: Record<string, string>;
}
interface AppsConfig {
  apps: AppEntry[];
}
interface AppState {
  name: string;
  status: string;
}
interface UnitResult {
  bin: string;
  args: string[];
  env: Record<string, string>;
  log: string;
}

// 把 ExecStart 按 systemd 引号规则拆成 token
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

// 解析 Environment=... （支持 "KEY=VAL" 与 KEY=VAL 形式，多个空格分隔）
function parseEnvironment(line: string): Record<string, string> {
  const env: Record<string, string> = {} as Record<string, string>;
  const re = /"([^"]*)"|(\S+)/g;
  let m: RegExpExecArray | null = re.exec(line);
  while (m !== null) {
    const item = m[1] !== undefined ? m[1] : m[2];
    const eq = item.indexOf('=');
    if (eq > 0) env[item.substring(0, eq)] = item.substring(eq + 1);
    m = re.exec(line);
  }
  return env;
}

// 解析 systemd .service 的 [Service] 段，返回 bin/args/env/log
function parseUnit(path: string): UnitResult {
  const text = fileIo.readTextSync(path);
  const lines = text.split('\n');
  let bin = '', log = '';
  let args: string[] = [];
  const env: Record<string, string> = {} as Record<string, string>;
  let inService = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (line.startsWith('[')) {
      inService = (line === '[Service]');
      continue;
    }
    if (!inService || line.length === 0 || line.startsWith('#') || line.startsWith(';')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.substring(0, eq).trim();
    const val = line.substring(eq + 1).trim();
    if (key === 'ExecStart') {
      const t = tokenizeExecStart(val);
      if (t.length > 0) { bin = t[0]; args = t.slice(1); }
    } else if (key === 'Environment') {
      const e = parseEnvironment(val);
      for (const k of Object.keys(e)) env[k] = e[k];
    } else if (key === 'StandardOutput' || key === 'StandardError') {
      if (val.startsWith('append:')) log = val.substring(7);
    }
  }
  return { bin: bin, args: args, env: env, log: log };
}

@Entry
@Component
struct Index {
  @State states: AppState[] = [];
  @State configInfo: string = '';

  loadAndStart(): void {
    const next: AppState[] = [];
    try {
      const text = fileIo.readTextSync(CONFIG_PATH);
      const cfg = JSON.parse(text) as AppsConfig;
      if (!cfg.apps || cfg.apps.length === 0) {
        this.configInfo = '配置中无 apps';
        this.states = [];
        return;
      }
      for (const app of cfg.apps) {
        if (app.enabled === false) {
          next.push({ name: app.name, status: 'disabled' });
          continue;
        }
        try {
          let bin = app.bin ?? '';
          let args = app.args ?? [];
          let log = app.log ?? '';
          const env: Record<string, string> = app.env ?? ({} as Record<string, string>);

          if (app.type === 'unit' && app.unit) {
            const u = parseUnit(app.unit);
            bin = u.bin; args = u.args; log = u.log;
            for (const k of Object.keys(u.env)) env[k] = u.env[k];
          }
          if (bin.length === 0) {
            next.push({ name: app.name, status: 'ERR: no ExecStart/bin' });
            continue;
          }

          const argsJson = JSON.stringify(args);
          const envJson = JSON.stringify(env);
          const r: number = daemonBridge.spawn(bin, argsJson, log, app.pidfile, envJson);
          const status = r === 0 ? 'already running' : 'started';
          next.push({ name: app.name, status: status });
          hilog.info(DOMAIN, TAG, '%{public}s: spawn=%{public}d', app.name, r);
        } catch (e) {
          next.push({ name: app.name, status: 'ERR: ' + JSON.stringify(e) });
          hilog.error(DOMAIN, TAG, '%{public}s spawn failed: %{public}s', app.name, JSON.stringify(e));
        }
      }
      this.configInfo = '配置: ' + CONFIG_PATH;
    } catch (err) {
      this.configInfo = '读取配置失败: ' + JSON.stringify(err);
      hilog.error(DOMAIN, TAG, 'read config failed: %{public}s', JSON.stringify(err));
    }
    this.states = next;
  }

  aboutToAppear(): void {
    setTimeout(() => { this.loadAndStart(); }, 1500);
  }

  build() {
    Column() {
      Text('Harbor').fontSize(22).padding(12)
      Text(this.configInfo).fontSize(11).fontColor(Color.Gray).padding(4)
      Text(this.formatStates()).fontSize(14).padding(8)
      Button('启动全部 / 重新加载').onClick(() => { this.loadAndStart(); })
    }
    .width('100%')
    .height('100%')
    .padding(8)
  }

  formatStates(): string {
    let out: string = '';
    for (const s of this.states) {
      out += s.name + '  ->  ' + s.status + '\n';
    }
    return out;
  }
}
