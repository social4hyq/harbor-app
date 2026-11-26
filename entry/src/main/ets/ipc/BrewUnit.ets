// brew 服务失效判据（单一来源，供 IpcServer 与 Index 共用）
// 对齐 brew services cleanup / systemd：以「后端 unit 文件是否还在磁盘」为权威信号，
// 仅 brew 管理的 opt/ 路径纳入，手工 unit（如 ~/.config/daemonbox/units/）一律跳过。
import fileIo from '@ohos.file.fs';

const BREW_OPT = '/storage/Users/currentUser/.harmonybrew/opt/';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';

// interface 只声明本模块访问的字段；JSON.parse 出的对象仍保留全部字段，
// 序列化时其他字段（bin/args/env/timer/pidfile 等）原样写回，不会丢失。
interface CleanAppEntry {
  name: string;
  type?: string;
  unit?: string;
  enabled?: boolean;
  bin?: string;
  args?: string[];
  log?: string;
  pidfile?: string;
  env?: Record<string, string>;
  timer?: Object;
}
interface CleanConfig {
  apps: CleanAppEntry[];
  autoHideOnLaunch?: boolean;
}
export interface CleanupResult {
  disabled: string[];
  removed: string[];
  error: string;
}

export function isBrewUnit(unit: string): boolean {
  return unit.startsWith(BREW_OPT) && unit.endsWith('.service');
}

// brew unit 文件是否已从磁盘消失（formula 已卸载）
export function brewUnitMissing(unit: string): boolean {
  if (!isBrewUnit(unit)) return false;
  try {
    return !fileIo.accessSync(unit);
  } catch (e) {
    return true;  // 读不到视为失效，与 CLI 的 os.path.exists=False 对齐
  }
}

// 原子写 apps.json：写同目录临时文件后 rename，避免与 CLI 并发读到半截内容
function saveConfig(cfg: CleanConfig): void {
  const text = JSON.stringify(cfg) as string;
  const tmp = CONFIG_PATH + '.hap-tmp';
  const f = fileIo.openSync(tmp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(f.fd, text);
  } finally {
    fileIo.closeSync(f);
  }
  try {
    fileIo.renameSync(tmp, CONFIG_PATH);
  } catch (e) {
    // hmdfs 上 rename 可能受限，退回直接覆写
    const g = fileIo.openSync(CONFIG_PATH, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(g.fd, text);
    } finally {
      fileIo.closeSync(g);
    }
    fileIo.unlinkSync(tmp);
  }
}

// 清理失效的 brew 服务，与 CLI `harbor cleanup` 语义一致：
// 默认软禁用（enabled:false，可逆）；prune=true 时从 apps.json 移除。
// name 为空则处理全部失效项；返回本次实际变更。
export function cleanupBrewApps(name: string, prune: boolean): CleanupResult {
  const result: CleanupResult = { disabled: [], removed: [], error: '' };
  try {
    const cfg = JSON.parse(fileIo.readTextSync(CONFIG_PATH)) as CleanConfig;
    const apps: CleanAppEntry[] = cfg.apps ?? [];
    const targets = apps.filter((a: CleanAppEntry) =>
      (name.length === 0 || a.name === name) &&
      a.type === 'unit' && a.unit !== undefined && brewUnitMissing(a.unit));
    if (targets.length === 0) return result;
    if (prune) {
      const names = targets.map((a: CleanAppEntry) => a.name);
      cfg.apps = apps.filter((a: CleanAppEntry) => !names.includes(a.name));
      result.removed = names;
    } else {
      for (const a of targets) {
        if (a.enabled !== false) {
          a.enabled = false;
          result.disabled.push(a.name);
        }
      }
      if (result.disabled.length === 0) return result;  // 无变更，不写盘
    }
    saveConfig(cfg);
  } catch (e) {
    result.error = JSON.stringify(e);
  }
  return result;
}
