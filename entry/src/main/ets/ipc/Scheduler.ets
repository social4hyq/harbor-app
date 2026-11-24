// 定时调度器：对齐 systemd timer 语义（OnCalendar / OnUnitActiveSec）
// 每 10 秒 tick，判断哪个服务到点，触发重启。
import hilog from '@ohos.hilog';
import fileIo from '@ohos.file.fs';
import daemonBridge from 'libharbor_bridge.so';
import { IpcServer } from './IpcServer';

const DOMAIN = 0x0000;
const TAG = 'HarborSched';
const CONFIG_PATH = '/storage/Users/currentUser/.config/harbor/apps.json';
const TICK_MS = 10000;

interface TimerSpec {
  type?: string;              // 'calendar' | 'interval'
  onCalendar?: string;        // systemd: "*-*-* 03:00:00" / "Sun *-*-* 00:00:00"
  onUnitActiveSec?: number;   // 秒
}
interface AppEntryWithTimer {
  name: string;
  enabled?: boolean;
  pidfile: string;
  bin?: string;
  args?: string[];
  log?: string;
  type?: string;
  unit?: string;
  env?: Record<string, string>;
  timer?: TimerSpec;
}
interface AppsConfigWithTimer { apps: AppEntryWithTimer[]; }

// 匹配 systemd OnCalendar 字段：* 或具体值（支持逗号列表）
function fieldMatch(expr: string, value: number): boolean {
  if (expr === '*') return true;
  for (const part of expr.split(',')) {
    if (parseInt(part, 10) === value) return true;
  }
  return false;
}

// 解析 "*-*-* 03:00:00" 或 "Sun *-*-* 00:00:00"
// 返回是否匹配当前时间（ minute/second 对齐，秒<10 窗口内触发一次）
function calendarDue(expr: string, now: Date): boolean {
  // 秒必须是 00~09 窗口（每 10 秒 tick，避免重复）
  if (now.getSeconds() >= 10) return false;
  const parts = expr.trim().split(/\s+/);
  if (parts.length < 2) return false;
  let datePart = '', timePart = '', weekday = '*';
  if (parts.length === 3) {
    weekday = parts[0];
    datePart = parts[1];
    timePart = parts[2];
  } else {
    datePart = parts[0];
    timePart = parts[1];
  }
  // 时间：HH:MM:SS
  const t = timePart.split(':');
  if (t.length < 2) return false;
  const hh = parseInt(t[0], 10), mm = parseInt(t[1], 10);
  const ss = t.length > 2 ? parseInt(t[2], 10) : 0;
  if (!fieldMatch(t[0], now.getHours())) return false;
  if (!fieldMatch(t[1], now.getMinutes())) return false;
  if (ss !== 0 && now.getSeconds() !== ss) return false;
  // 日期：YEAR-MONTH-DAY（通常 *-*-* 或 *-M-D）
  const d = datePart.split('-');
  if (d.length === 3) {
    if (!fieldMatch(d[0], now.getFullYear())) return false;
    if (!fieldMatch(d[1], now.getMonth() + 1)) return false;
    if (!fieldMatch(d[2], now.getDate())) return false;
  }
  // 星期：Sun/Mon/... 或 *
  const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  if (weekday !== '*') {
    if (WEEKDAYS[now.getDay()] !== weekday) return false;
  }
  return true;
}

export class Scheduler {
  private lastFired: Map<string, number> = new Map();
  private watchdogFails: Map<string, number> = new Map();
  private static readonly MAX_WATCHDOG_RETRIES = 3;
  private timerId: number = -1;
  private ipc: IpcServer;

  constructor(ipc: IpcServer) {
    this.ipc = ipc;
  }

  start(): void {
    // 功耗优化：有 timer 服务时 10 秒 tick（保证定时精度），否则 30 秒 tick（仅 watchdog）
    let tickMs = 30000;
    try {
      const cfg = JSON.parse(fileIo.readTextSync(CONFIG_PATH)) as AppsConfigWithTimer;
      for (const app of cfg.apps) {
        if (app.timer) { tickMs = TICK_MS; break; }
      }
    } catch (e) { /* 读不到配置用默认 30s */ }
    this.timerId = setInterval(() => { this.tick(); }, tickMs);
    hilog.info(DOMAIN, TAG, 'scheduler started (tick %{public}dms)', tickMs);
  }

  private readConfig(): AppsConfigWithTimer | undefined {
    try {
      return JSON.parse(fileIo.readTextSync(CONFIG_PATH)) as AppsConfigWithTimer;
    } catch (e) {
      return undefined;
    }
  }

  private tick(): void {
    const cfg = this.readConfig();
    if (!cfg) return;
    const now = new Date();
    const nowMs = now.getTime();
    for (const app of cfg.apps) {
      if (app.enabled === false) continue;
      // keep_alive watchdog：enabled 服务若曾运行（pidfile 存在）但进程已死 -> 自动拉起
      const pid: number = daemonBridge.pidFromPidfile(app.pidfile);
      const everRan: number = daemonBridge.pidfileExists(app.pidfile);
      if (pid > 0) {
        // 服务活着：清零 watchdog 失败计数（可能之前被限流）
        this.watchdogFails.delete(app.name);
      } else if (everRan === 1) {
        // 进程已死：带退避的自动重启（防反复失败的服务无限循环）
        const fails = this.watchdogFails.get(app.name) ?? 0;
        if (fails >= Scheduler.MAX_WATCHDOG_RETRIES) {
          if (fails === Scheduler.MAX_WATCHDOG_RETRIES) {
            hilog.warn(DOMAIN, TAG, 'watchdog: %{public}s gave up after %{public}d retries', app.name, fails);
            this.watchdogFails.set(app.name, fails + 1);
          }
          continue;
        }
        this.watchdogFails.set(app.name, fails + 1);
        hilog.info(DOMAIN, TAG, 'watchdog: %{public}s died, restarting (try %{public}d)', app.name, fails + 1);
        this.ipc.restartService(app.name);
        continue;
      }
      if (!app.timer) continue;
      const timer = app.timer;
      let due = false;
      if (timer.type === 'calendar' && timer.onCalendar) {
        due = calendarDue(timer.onCalendar, now);
      } else if (timer.type === 'interval' && timer.onUnitActiveSec && timer.onUnitActiveSec > 0) {
        const last = this.lastFired.get(app.name) ?? 0;
        due = (nowMs - last) >= timer.onUnitActiveSec * 1000;
      }
      if (!due) continue;
      // 防止同一分钟/周期重复触发
      const last = this.lastFired.get(app.name) ?? 0;
      const guardMs = timer.type === 'interval' ? timer.onUnitActiveSec! * 1000 : 60000;
      if (nowMs - last < guardMs) continue;
      this.lastFired.set(app.name, nowMs);
      hilog.info(DOMAIN, TAG, 'timer fired: %{public}s', app.name);
      this.restart(app);
    }
  }

  private restart(app: AppEntryWithTimer): void {
    // 复用 IpcServer 的 RESTART 逻辑（含 unit 解析 + spawn + 去重），避免重复实现
    try {
      const result: string = this.ipc.restartService(app.name);
      hilog.info(DOMAIN, TAG, 'timer restart %{public}s -> %{public}s', app.name, result);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'timer restart failed: %{public}s', JSON.stringify(e));
    }
  }
}
